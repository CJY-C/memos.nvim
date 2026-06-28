local M = {}

local function first_line(content)
	if type(content) ~= "string" then
		return ""
	end
	return vim.trim(content:match("^[^\n]*") or "")
end

local function format_time(value, with_seconds)
	if not value then
		return nil
	end
	return os.date(with_seconds and "%H:%M:%S" or "%H:%M", value)
end

local function display_date(memo)
	local value = memo.update_time or memo.create_time or ""
	if value == "" then
		return "unknown"
	end
	return value:sub(1, 10)
end

local function memo_badges(memo)
	local badges = {}
	if memo.pinned then
		table.insert(badges, "P")
	end
	if memo.state == "ARCHIVED" then
		table.insert(badges, "A")
	end
	return badges
end

local function memo_title(memo)
	local title = first_line(memo.content)
	if title ~= "" then
		return title
	end
	if type(memo.snippet) == "string" and memo.snippet ~= "" then
		return memo.snippet
	end
	return "(empty)"
end

local function window_width(buf)
	local width = vim.o.columns
	local win = buf and vim.fn.bufwinid(buf) or -1
	if win ~= -1 and vim.api.nvim_win_is_valid(win) then
		width = vim.api.nvim_win_get_width(win)
	end
	return width
end

function M.status_line(session)
	local refreshed = format_time(session.last_refresh_at, true)
	if session.list_refresh_state == "refreshing" then
		return "Refreshing..."
	end
	if session.list_refresh_state == "failed" then
		return "Refresh failed"
	end
	if refreshed then
		return "Updated " .. refreshed
	end
	return nil
end

function M.header_line(session)
	local left = "View: " .. session.current_list_state
	local right = M.status_line(session)
	if not right then
		return left
	end

	local gap = window_width(session.buf) - #left - #right
	if gap > 1 then
		return left .. string.rep(" ", gap) .. right
	end
	return left .. " " .. right
end

function M.collect_missing_relation_names(session)
	local names = {}
	local seen = {}
	local function add_missing(target_name)
		if target_name == "" or seen[target_name] then
			return
		end
		if session:get_cached_relation_memo(target_name) or session.in_flight_relations[target_name] then
			return
		end
		seen[target_name] = true
		table.insert(names, target_name)
	end

	for _, memo in ipairs(session.memos_cache) do
		if session.expanded_outgoing[memo.name] then
			for _, target_name in ipairs(session:get_outgoing_relation_names(memo)) do
				add_missing(target_name)
			end
		end
		if session.expanded_incoming[memo.name] then
			for _, target_name in ipairs(session:get_incoming_relation_names(memo)) do
				add_missing(target_name)
			end
		end
	end
	return names
end

function M.format_memo_line(session, config, index, memo)
	if session.current_list_state == "TEMPLATES" then
		local clean_content = require("memos.template").strip_template_tag(memo.content or "")
		local title = first_line(clean_content)
		if title == "" and type(memo.snippet) == "string" and memo.snippet ~= "" then
			title = require("memos.template").strip_template_tag(memo.snippet)
		end
		if title == "" then
			title = "(empty)"
		end
		return string.format("%d. [T] %s", index, title), {}
	end

	local date = display_date(memo)
	local badges = memo_badges(memo)
	local title = memo_title(memo)

	local badge_str = ""
	if #badges > 0 then
		badge_str = "[" .. table.concat(badges, ",") .. "] "
	end

	local line_without_indicator
	if config.list_style == "compact" then
		line_without_indicator = string.format("%d. %s%s", index, badge_str, title)
	else
		line_without_indicator = string.format("%d. [%s] %s%s", index, date, badge_str, title)
	end

	local outgoing_count = #session:get_outgoing_relation_names(memo)
	local incoming_count = #session:get_incoming_relation_names(memo)
	local hls = {}
	local full_line = line_without_indicator

	if outgoing_count > 0 or incoming_count > 0 then
		local target_width = window_width(session.buf) - 3
		if target_width < 40 then
			target_width = 40
		end

		local parts = {}
		table.insert(parts, "[")
		local current_len = 1

		if outgoing_count > 0 then
			local out_str = string.format("→ %d", outgoing_count)
			table.insert(parts, out_str)
			table.insert(hls, {
				hl_group = "MemosOutgoingLink",
				start_offset = current_len,
				end_offset = current_len + #out_str,
			})
			current_len = current_len + #out_str
		end

		if outgoing_count > 0 and incoming_count > 0 then
			table.insert(parts, ", ")
			current_len = current_len + 2
		end

		if incoming_count > 0 then
			local in_str = string.format("← %d", incoming_count)
			table.insert(parts, in_str)
			table.insert(hls, {
				hl_group = "MemosIncomingLink",
				start_offset = current_len,
				end_offset = current_len + #in_str,
			})
			current_len = current_len + #in_str
		end

		table.insert(parts, "]")
		local link_indicator = table.concat(parts, "")
		local gap = target_width - vim.fn.strdisplaywidth(line_without_indicator) - vim.fn.strdisplaywidth(link_indicator)
		local gap_str = gap > 0 and string.rep(" ", gap) or " "

		full_line = line_without_indicator .. gap_str .. link_indicator

		local offset_shift = #line_without_indicator + #gap_str
		for _, hl in ipairs(hls) do
			hl.start_col = hl.start_offset + offset_shift
			hl.end_col = hl.end_offset + offset_shift
		end
	end

	return full_line, hls
end

function M.format_incoming_relation_line(config, parent_idx, rel_idx, rel_memo)
	local prefix = "   ┌── "
	local idx_str = string.format("%d.i%d", parent_idx, rel_idx)
	local date = display_date(rel_memo)
	local badges = memo_badges(rel_memo)
	local title = memo_title(rel_memo)
	local badge_str = #badges > 0 and ("[" .. table.concat(badges, ",") .. "] ") or ""
	local line
	if config.list_style == "compact" then
		line = string.format("%s%s. %s%s", prefix, idx_str, badge_str, title)
	else
		line = string.format("%s%s. [%s] %s%s", prefix, idx_str, date, badge_str, title)
	end
	local highlight_len = #prefix + #idx_str + 2
	return line, {
		{
			hl_group = "MemosIncomingLink",
			start_col = 0,
			end_col = highlight_len,
		},
	}
end

function M.format_outgoing_relation_line(config, parent_idx, rel_idx, rel_memo)
	local prefix = "   └── "
	local idx_str = string.format("%d.o%d", parent_idx, rel_idx)
	local date = display_date(rel_memo)
	local badges = memo_badges(rel_memo)
	local title = memo_title(rel_memo)
	local badge_str = #badges > 0 and ("[" .. table.concat(badges, ",") .. "] ") or ""
	local line
	if config.list_style == "compact" then
		line = string.format("%s%s. %s%s", prefix, idx_str, badge_str, title)
	else
		line = string.format("%s%s. [%s] %s%s", prefix, idx_str, date, badge_str, title)
	end
	local highlight_len = #prefix + #idx_str + 2
	return line, {
		{
			hl_group = "MemosOutgoingLink",
			start_col = 0,
			end_col = highlight_len,
		},
	}
end

local function format_loading_relation_line(parent_idx, rel_idx, relation_type, target_name)
	local is_incoming = relation_type == "incoming"
	local prefix = is_incoming and "   ┌── " or "   └── "
	local marker = is_incoming and "i" or "o"
	local line = string.format("%s%d.%s%d. Loading %s...", prefix, parent_idx, marker, rel_idx, target_name)
	local highlight_len = #prefix + #tostring(parent_idx) + 2 + #tostring(rel_idx) + 2
	return line, {
		{
			hl_group = is_incoming and "MemosIncomingLink" or "MemosOutgoingLink",
			start_col = 0,
			end_col = highlight_len,
		},
	}
end

function M.build(session, config)
	local lines = {}
	local list_items = {}
	local line_hls = {}
	local keys = config.keymaps.list

	local function add_line(content, item_meta, hls)
		table.insert(lines, content)
		list_items[#lines] = item_meta
		if hls and #hls > 0 then
			line_hls[#lines] = hls
		end
	end

	add_line(M.header_line(session), { kind = "header" })
	if session.current_filter ~= "" then
		add_line("Filter: " .. session.current_filter, { kind = "filter" })
	end

	if #session.memos_cache == 0 then
		local message = session.current_filter == "" and "No memos." or "No memos match the current filter."
		add_line(
			string.format("%s Press '%s' to refresh, '%s' to add, '%s' to quit.", message, keys.refresh_list, keys.add_memo, keys.quit),
			{ kind = "empty" }
		)
	else
		for index, memo in ipairs(session.memos_cache) do
			if session.expanded_incoming[memo.name] then
				for rel_idx, target_name in ipairs(session:get_incoming_relation_names(memo)) do
					local rel_memo = session:get_cached_relation_memo(target_name)
					if rel_memo then
						local line_str, hls = M.format_incoming_relation_line(config, index, rel_idx, rel_memo)
						add_line(line_str, {
							kind = "relation",
							parent_index = index,
							relation_index = rel_idx,
							relation_type = "incoming",
							memo = rel_memo,
						}, hls)
					else
						local line_str, hls = format_loading_relation_line(index, rel_idx, "incoming", target_name)
						add_line(line_str, {
							kind = "relation_loading",
							parent_index = index,
							relation_name = target_name,
							relation_type = "incoming",
						}, hls)
					end
				end
			end

			local parent_str, parent_hls = M.format_memo_line(session, config, index, memo)
			add_line(parent_str, { kind = "memo", index = index }, parent_hls)

			if session.expanded_outgoing[memo.name] then
				for rel_idx, target_name in ipairs(session:get_outgoing_relation_names(memo)) do
					local rel_memo = session:get_cached_relation_memo(target_name)
					if rel_memo then
						local line_str, hls = M.format_outgoing_relation_line(config, index, rel_idx, rel_memo)
						add_line(line_str, {
							kind = "relation",
							parent_index = index,
							relation_index = rel_idx,
							relation_type = "outgoing",
							memo = rel_memo,
						}, hls)
					else
						local line_str, hls = format_loading_relation_line(index, rel_idx, "outgoing", target_name)
						add_line(line_str, {
							kind = "relation_loading",
							parent_index = index,
							relation_name = target_name,
							relation_type = "outgoing",
						}, hls)
					end
				end
			end
		end
	end

	if session.current_page_token ~= "" then
		add_line("...", { kind = "load_more" })
		add_line(string.format("Press '%s' to load more", keys.next_page), { kind = "load_more" })
	end

	return {
		lines = lines,
		list_items = list_items,
		line_hls = line_hls,
		missing_relation_names = M.collect_missing_relation_names(session),
	}
end

return M
