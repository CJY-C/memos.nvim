local api = require("memos.api").new(function() return require("memos").config end)
local config = setmetatable({}, {
	__index = function(_, k)
		return require("memos").config[k]
	end,
})

local M = {}

local list_buf = nil
local last_float_buf = nil
local memos_cache = {}
local list_items = {}
local current_page_token = nil
local current_filter = ""
local current_list_state = config.list_state or "NORMAL"
local list_refresh_state = "idle"
local last_refresh_at = nil
local last_refresh_error = nil

local caches = {
	NORMAL = { memos = {}, page_token = nil, filter = "", last_refresh_at = nil },
	ARCHIVED = { memos = {}, page_token = nil, filter = "", last_refresh_at = nil },
	TEMPLATES = { memos = {}, page_token = nil, filter = "", last_refresh_at = nil },
}

local function save_current_state_cache()
	local state = current_list_state
	caches[state] = {
		memos = vim.deepcopy(memos_cache),
		page_token = current_page_token,
		filter = current_filter,
		last_refresh_at = last_refresh_at,
	}
end

local function load_state_cache(state)
	current_list_state = state
	local c = caches[state] or { memos = {}, page_token = nil, filter = "", last_refresh_at = nil }
	memos_cache = vim.deepcopy(c.memos)
	current_page_token = c.page_token
	current_filter = c.filter
	last_refresh_at = c.last_refresh_at
end

local function redraw_status()
	vim.schedule(function()
		pcall(vim.cmd, "redrawstatus")
	end)
end

local function set_refresh_state(state, err)
	list_refresh_state = state or "idle"
	if list_refresh_state == "failed" then
		last_refresh_error = tostring(err or "Unknown error")
	elseif list_refresh_state == "idle" then
		last_refresh_error = nil
	end
	redraw_status()
end

local function mark_refresh_success()
	list_refresh_state = "idle"
	last_refresh_error = nil
	last_refresh_at = os.time()
	redraw_status()
end

local function format_time(value, with_seconds)
	if not value then
		return nil
	end
	return os.date(with_seconds and "%H:%M:%S" or "%H:%M", value)
end

local function is_float_window(win)
	local cfg = vim.api.nvim_win_get_config(win)
	return cfg and cfg.relative and cfg.relative ~= ""
end

local function find_memos_float_window()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local ok, value = pcall(vim.api.nvim_win_get_var, win, "memos_window")
		if ok and value == true and vim.api.nvim_win_is_valid(win) then
			return win
		end
	end
	return nil
end

local function create_float_window(buf)
	local width = math.floor(vim.o.columns * (config.window.width or 0.85))
	local height = math.floor(vim.o.lines * (config.window.height or 0.85))
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = config.window.border or "rounded",
		title = " Memos ",
		title_pos = "center",
	})
	vim.api.nvim_win_set_var(win, "memos_window", true)
	last_float_buf = buf
	return win
end

local function ensure_list_buf()
	if list_buf and vim.api.nvim_buf_is_valid(list_buf) then
		return list_buf
	end
	list_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(list_buf, "MemosList")
	vim.bo[list_buf].buftype = "nofile"
	vim.bo[list_buf].bufhidden = "hide"
	vim.bo[list_buf].buflisted = false
	vim.bo[list_buf].filetype = "memos_list"
	vim.bo[list_buf].modifiable = false
	vim.bo[list_buf].swapfile = false

	vim.api.nvim_create_autocmd("BufEnter", {
		buffer = list_buf,
		callback = function()
			M.bind_list_keymaps(list_buf)
		end,
	})
	return list_buf
end

local function focus_list_buf()
	local buf = ensure_list_buf()
	local win = vim.fn.bufwinid(buf)
	if win ~= -1 then
		vim.api.nvim_set_current_win(win)
		return
	end
	if config.window and config.window.enable_float then
		local float_win = find_memos_float_window()
		if float_win then
			vim.api.nvim_set_current_win(float_win)
			vim.api.nvim_set_current_buf(buf)
		else
			create_float_window(buf)
		end
	else
		vim.api.nvim_set_current_buf(buf)
	end
end

local function count_normal_windows()
	local count = 0
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_is_valid(win) and not is_float_window(win) then
			count = count + 1
		end
	end
	return count
end

local function set_list_lines(lines)
	local buf = ensure_list_buf()
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
end

local function first_line(content)
	if type(content) ~= "string" then
		return ""
	end
	return vim.trim(content:match("^[^\n]*") or "")
end

local function cel_string(value)
	value = tostring(value or "")
	value = value:gsub("\\", "\\\\")
	value = value:gsub('"', '\\"')
	value = value:gsub("\n", "\\n")
	return '"' .. value .. '"'
end

local function looks_like_cel_filter(input)
	return input:match("content%.contains%s*%(")
		or input:match("%f[%w]tags%f[%W]")
		or input:match("%s+in%s+tags")
		or input:match("&&")
		or input:match("%|%|")
		or input:match("[<>=!]=")
end

function M.build_search_filter(input)
	local trimmed = vim.trim(input or "")
	if trimmed == "" then
		return ""
	end
	if looks_like_cel_filter(trimmed) then
		return trimmed
	end

	local tags = {}
	local text_terms = {}
	for token in trimmed:gmatch("%S+") do
		if token:sub(1, 1) == "#" and #token > 1 then
			table.insert(tags, token:sub(2))
		else
			table.insert(text_terms, token)
		end
	end

	local parts = {}
	local text = table.concat(text_terms, " ")
	if text ~= "" then
		table.insert(parts, "content.contains(" .. cel_string(text) .. ")")
	end
	for _, tag in ipairs(tags) do
		table.insert(parts, cel_string(tag) .. " in tags")
	end
	return table.concat(parts, " && ")
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

function M.format_memo_line(index, memo)
	if current_list_state == "TEMPLATES" then
		local title = memo_title(memo)
		title = require("memos.template").strip_template_tag(title)
		return string.format("%d. [T] %s", index, title)
	end
	local badges = memo_badges(memo)
	local badge_text = #badges > 0 and ("[" .. table.concat(badges, "") .. "] ") or ""
	local title = memo_title(memo)
	if config.list_style == "compact" then
		return string.format("%d. %s%s", index, badge_text, title)
	end
	return string.format("%d. [%s] %s%s", index, display_date(memo), badge_text, title)
end

local function build_memo_buffer_name(memo, content)
	if not memo or not memo.name or memo.name == "" then
		return nil
	end
	local title = first_line(content)
	if title == "" then
		title = "memo"
	end
	return "memos/" .. memo.name:gsub("^memos/", "") .. "/" .. title:gsub("[/\\]", "_"):sub(1, 50) .. ".md"
end

local function set_keymap(buf, key, rhs)
	if type(key) ~= "string" or key == "" then
		return
	end
	vim.api.nvim_buf_set_keymap(buf, "n", key, rhs, { noremap = true, silent = true })
end

function M.bind_list_keymaps(buf)
	local keys = config.keymaps.list

	-- Clear previously bound keys to prevent ghost mappings
	if vim.b[buf].memos_bound_keys then
		for _, key in ipairs(vim.b[buf].memos_bound_keys) do
			pcall(vim.api.nvim_buf_del_keymap, buf, "n", key)
		end
	end

	local bound = {}
	local function set_map(key, lhs)
		if key and key ~= "" then
			set_keymap(buf, key, lhs)
			table.insert(bound, key)
		end
	end

	set_map(keys.edit_memo, '<Cmd>lua require("memos.ui").edit_selected_memo()<CR>')
	set_map("e", '<Cmd>lua require("memos.ui").edit_selected_memo()<CR>')
	set_map(keys.edit_memo_split, '<Cmd>lua require("memos.ui").edit_selected_memo_split()<CR>')
	set_map(keys.edit_memo_vsplit, '<Cmd>lua require("memos.ui").edit_selected_memo_vsplit()<CR>')
	set_map(keys.add_memo, '<Cmd>lua require("memos.ui").add_memo_command()<CR>')
	set_map("i", '<Cmd>lua require("memos.ui").add_memo_command()<CR>')
	set_map(keys.new_memo or "n", '<Cmd>lua require("memos.ui").new_memo_or_template_command()<CR>')
	set_map(keys.search_memos, '<Cmd>lua require("memos.ui").search_memos()<CR>')
	set_map(keys.copy_memo_id, '<Cmd>lua require("memos.ui").copy_selected_memo_id()<CR>')
	set_map(keys.toggle_pin, '<Cmd>lua require("memos.ui").toggle_selected_memo_pin()<CR>')
	set_map(keys.delete_memo, '<Cmd>lua require("memos.ui").delete_selected_memo()<CR>')
	set_map(keys.archive_memo, '<Cmd>lua require("memos.ui").archive_selected_memo()<CR>')
	set_map(keys.toggle_archive_view, '<Cmd>lua require("memos.ui").toggle_archive_view()<CR>')
	set_map(keys.toggle_template_view, '<Cmd>lua require("memos.ui").toggle_template_view()<CR>')
	set_map(keys.edit_visibility, '<Cmd>lua require("memos.ui").edit_selected_memo_visibility()<CR>')
	set_map(keys.edit_create_time, '<Cmd>lua require("memos.ui").edit_selected_memo_create_time()<CR>')
	set_map(keys.refresh_list, '<Cmd>lua require("memos.ui").refresh_list_command()<CR>')
	set_map(keys.next_page, '<Cmd>lua require("memos.ui").load_next_page()<CR>')
	set_map(keys.quit, '<Cmd>lua require("memos.ui").quit_memos_list()<CR>')

	vim.b[buf].memos_bound_keys = bound
end

local function copy_text(text)
	if vim.fn.has("clipboard") == 1 then
		local ok = pcall(vim.fn.setreg, "+", text)
		if ok then
			return "+"
		end
	end
	vim.fn.setreg('"', text)
	return '"'
end

local function list_status_line()
	local refreshed = format_time(last_refresh_at, true)
	if list_refresh_state == "refreshing" then
		if refreshed then
			return "Updated " .. refreshed .. " (Refreshing...)"
		else
			return "Refreshing..."
		end
	end
	if list_refresh_state == "failed" then
		if refreshed then
			return "Updated " .. refreshed .. " (Refresh failed)"
		else
			return "Refresh failed"
		end
	end
	if refreshed then
		return "Updated " .. refreshed
	end
	return nil
end

local function list_header_line()
	local left = "View: " .. current_list_state
	local right = list_status_line()
	if not right then
		return left
	end

	local width = vim.o.columns
	local win = list_buf and vim.fn.bufwinid(list_buf) or -1
	if win ~= -1 and vim.api.nvim_win_is_valid(win) then
		width = vim.api.nvim_win_get_width(win)
	end

	local gap = width - #left - #right
	if gap > 1 then
		return left .. string.rep(" ", gap) .. right
	end
	return left .. " " .. right
end

local function render_cached_memos()
	vim.schedule(function()
		list_items = {}

		local lines = {}
		local keys = config.keymaps.list
		table.insert(lines, list_header_line())
		list_items[#lines] = { kind = "header" }
		if current_filter ~= "" then
			table.insert(lines, "Filter: " .. current_filter)
			list_items[#lines] = { kind = "filter" }
		end
		if #memos_cache == 0 then
			local message = current_filter == "" and "No memos." or "No memos match the current filter."
			table.insert(lines, string.format("%s Press '%s' to refresh, '%s' to add, '%s' to quit.", message, keys.refresh_list, keys.add_memo, keys.quit))
			list_items[#lines] = { kind = "empty" }
		else
			for index, memo in ipairs(memos_cache) do
				table.insert(lines, M.format_memo_line(index, memo))
				list_items[#lines] = { kind = "memo", index = index }
			end
		end
		if current_page_token ~= "" then
			table.insert(lines, "...")
			list_items[#lines] = { kind = "load_more" }
			table.insert(lines, string.format("Press '%s' to load more", keys.next_page))
			list_items[#lines] = { kind = "load_more" }
		end
		set_list_lines(lines)
	end)
end

function M.render_memos(data, append)
	if not data then
		vim.notify("API returned no data.", vim.log.levels.WARN)
		return
	end
	if append then
		vim.list_extend(memos_cache, data.memos or {})
	else
		memos_cache = data.memos or {}
	end
	current_page_token = data.next_page_token or ""
	render_cached_memos()
end

local function fetch_memos(opts)
	opts = opts or {}
	local req_state = current_list_state
	local state_param = req_state
	local filter_param = current_filter

	if req_state == "TEMPLATES" then
		state_param = "ARCHIVED"
		if current_filter and current_filter ~= "" then
			filter_param = "content.contains('#type/template') && (" .. current_filter .. ")"
		else
			filter_param = "content.contains('#type/template')"
		end
	end

	api:list_memos({
		page_size = config.page_size,
		page_token = opts.page_token,
		state = state_param,
		order_by = config.list_order_by,
		filter = filter_param,
	}, function(data, err)
		vim.schedule(function()
			if not data then
				if current_list_state == req_state then
					set_refresh_state("failed", err)
					if #memos_cache > 0 then
						render_cached_memos()
					end
				end
				vim.notify("Failed to fetch memos: " .. tostring(err), vim.log.levels.ERROR)
				return
			end

			local is_append = opts.append == true
			if current_list_state == req_state then
				if not opts.append then
					mark_refresh_success()
				end
				M.render_memos(data, is_append)
			else
				-- Update the background cache slot directly
				local c = caches[req_state]
				if not is_append then
					c.memos = data.memos or {}
					c.last_refresh_at = os.time()
				else
					c.memos = c.memos or {}
					vim.list_extend(c.memos, data.memos or {})
				end
				c.page_token = data.next_page_token or ""
			end
		end)
	end)
end

function M.show_memos_list(opts)
	opts = opts or {}
	focus_list_buf()
	if #memos_cache == 0 or opts.force_refresh then
		set_refresh_state("refreshing")
		local loading_text = "Loading " .. current_list_state:lower() .. "..."
		set_list_lines({ loading_text })
		fetch_memos({ append = false })
	else
		set_refresh_state("refreshing")
		render_cached_memos()
		fetch_memos({ append = false })
	end

	local buf = ensure_list_buf()
	M.bind_list_keymaps(buf)
end

function M.search_memos()
	vim.ui.input({ prompt = "Search memos (empty clears): " }, function(input)
		if input == nil then
			return
		end

		local next_filter = M.build_search_filter(input)
		current_filter = next_filter
		memos_cache = {}
		list_items = {}
		current_page_token = nil
		list_refresh_state = "idle"
		last_refresh_error = nil
		redraw_status()
		focus_list_buf()

		local entity_name = current_list_state == "TEMPLATES" and "templates" or "memos"
		local loading_text = next_filter == "" and ("Loading " .. entity_name .. "...") or ("Loading filtered " .. entity_name .. "...")
		set_list_lines({ loading_text })

		if next_filter == "" then
			vim.notify(current_list_state == "TEMPLATES" and "Templates search cleared." or "Memos search cleared.")
		else
			vim.notify(current_list_state == "TEMPLATES" and "Templates search filter applied." or "Memos search filter applied.")
		end
		fetch_memos({ append = false })
	end)
end

function M.toggle_archive_view()
	save_current_state_cache()
	local next_state = current_list_state == "ARCHIVED" and "NORMAL" or "ARCHIVED"
	load_state_cache(next_state)
	redraw_status()
	focus_list_buf()
	M.show_memos_list()
end

function M.toggle_memos_list()
	if config.window and config.window.enable_float then
		local existing = find_memos_float_window()
		if existing then
			pcall(vim.api.nvim_win_close, existing, true)
			return
		end
		if last_float_buf and vim.api.nvim_buf_is_valid(last_float_buf) then
			create_float_window(last_float_buf)
			M.show_memos_list()
			return
		end
	end
	M.show_memos_list()
end

function M.quit_memos_list()
	local current_win = vim.api.nvim_get_current_win()
	local current_buf = vim.api.nvim_get_current_buf()
	local ok, is_memos_window = pcall(vim.api.nvim_win_get_var, current_win, "memos_window")
	if ok and is_memos_window == true then
		pcall(vim.api.nvim_win_close, current_win, true)
		return
	end
	if count_normal_windows() > 1 then
		pcall(vim.api.nvim_win_close, current_win, true)
		return
	end
	if current_buf == list_buf then
		vim.cmd("enew")
	end
end

function M.load_next_page()
	if not current_page_token or current_page_token == "" then
		vim.notify("No more pages to load.", vim.log.levels.INFO)
		return
	end
	fetch_memos({
		page_token = current_page_token,
		append = true,
	})
end

function M.open_edit_buffer(content, open_cmd)
	if open_cmd == "split" or open_cmd == "vsplit" then
		local source_win = vim.api.nvim_get_current_win()
		local close_source_float = false
		local ok, is_memos_window = pcall(vim.api.nvim_win_get_var, source_win, "memos_window")
		if ok and is_memos_window == true and is_float_window(source_win) then
			close_source_float = true
		end
		local alternate_win = vim.fn.win_getid(vim.fn.winnr("#"))
		if alternate_win ~= 0 and vim.api.nvim_win_is_valid(alternate_win) and not is_float_window(alternate_win) then
			vim.api.nvim_set_current_win(alternate_win)
		end
		if close_source_float and vim.api.nvim_win_is_valid(source_win) then
			pcall(vim.api.nvim_win_close, source_win, true)
		end
		vim.cmd(open_cmd)
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(buf)
		if type(content) == "string" then
			vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(content, "\n"))
		end
		return vim.api.nvim_get_current_buf()
	end

	local used_float = false
	if config.window and config.window.enable_float then
		local float_win = find_memos_float_window()
		if float_win then
			vim.api.nvim_set_current_win(float_win)
			vim.cmd("enew")
			used_float = true
		else
			local buf = vim.api.nvim_create_buf(false, true)
			create_float_window(buf)
			vim.api.nvim_set_current_buf(buf)
			used_float = true
		end
	end
	if not used_float then
		vim.cmd(open_cmd or "enew")
	end
	if type(content) == "string" then
		vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(content, "\n"))
	end
	return vim.api.nvim_get_current_buf()
end

function M.setup_buffer_for_editing()
	vim.bo.buftype = "acwrite"
	vim.bo.bufhidden = "hide"
	vim.bo.buflisted = false
	vim.bo.filetype = "markdown"
	vim.bo.swapfile = false
	vim.b.memos_original_content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
	vim.b.memos_save_inflight = false
	vim.b.memos_save_pending = false
	vim.bo.modified = false

	vim.api.nvim_buf_create_user_command(0, "MemosSave", function()
		M.save_or_create_dispatcher()
	end, {})
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = 0,
		callback = function()
			M.save_or_create_dispatcher({ post_save_ui = false })
		end,
	})

	local keys = config.keymaps.buffer
	set_keymap(0, keys.save, "<Cmd>MemosSave<CR>")
	set_keymap(0, keys.back_to_list, '<Cmd>lua require("memos.ui").return_to_list()<CR>')

	if config.auto_save then
		local group = vim.api.nvim_create_augroup("MemosAutoSave", { clear = false })
		vim.api.nvim_create_autocmd({ "InsertLeave", "CursorHold" }, {
			group = group,
			buffer = 0,
			callback = function()
				M.check_and_auto_save()
			end,
		})
	end
end

function M.open_memo_for_edit(memo, open_cmd)
	if not memo or not memo.name or memo.name == "" then
		vim.notify("Selected memo has no valid identifier.", vim.log.levels.ERROR)
		return
	end
	local content = memo.content or ""
	local buffer_name = build_memo_buffer_name(memo, content)
	local existing = buffer_name and vim.fn.bufnr(buffer_name) or -1
	if existing ~= -1 and vim.api.nvim_buf_is_loaded(existing) then
		local win = vim.fn.bufwinid(existing)
		if win ~= -1 then
			vim.api.nvim_set_current_win(win)
		else
			vim.api.nvim_set_current_buf(existing)
		end
		return
	end

	M.open_edit_buffer(content, open_cmd or "enew")
	if buffer_name then
		vim.api.nvim_buf_set_name(0, buffer_name)
	end
	vim.b.memos_memo_name = memo.name
	M.setup_buffer_for_editing()
end

function M.create_memo_in_buffer(content)
	M.open_edit_buffer(content or "", "enew")
	vim.b.memos_memo_name = nil
	vim.b.memos_template_mode = nil
	vim.b.memos_template_name = nil
	vim.api.nvim_buf_set_name(0, "memos/new_memo_" .. vim.fn.strftime("%s"))
	M.setup_buffer_for_editing()
end

local function current_list_item()
	local line = vim.api.nvim_win_get_cursor(0)[1]
	return list_items[line]
end

local function edit_selected_memo_with(open_cmd)
	local item = current_list_item()
	if not item then
		return
	end
	if item.kind == "load_more" then
		M.load_next_page()
		return
	end
	local memo = item.kind == "memo" and memos_cache[item.index] or nil
	if memo then
		if current_list_state == "TEMPLATES" then
			require("memos.template").template_edit_selected(memo, open_cmd)
		else
			M.open_memo_for_edit(memo, open_cmd)
		end
	end
end

function M.edit_selected_memo()
	edit_selected_memo_with("enew")
end

function M.edit_selected_memo_split()
	edit_selected_memo_with("split")
end

function M.edit_selected_memo_vsplit()
	edit_selected_memo_with("vsplit")
end

function M.copy_selected_memo_id()
	local item = current_list_item()
	local memo = item and item.kind == "memo" and memos_cache[item.index] or nil
	if not memo or not memo.name or memo.name == "" then
		vim.notify("No memo ID on the current line.", vim.log.levels.INFO)
		return
	end
	local register = copy_text(memo.name)
	vim.notify("Copied memo ID to " .. register .. ": " .. memo.name)
end

function M.toggle_selected_memo_pin()
	if current_list_state == "TEMPLATES" then
		vim.notify("Pinning is not supported for templates.", vim.log.levels.WARN)
		return
	end
	local item = current_list_item()
	local memo = item and item.kind == "memo" and memos_cache[item.index] or nil
	if not memo or not memo.name or memo.name == "" then
		vim.notify("No memo on the current line.", vim.log.levels.INFO)
		return
	end

	local next_pinned = memo.pinned ~= true
	api:update_memo_pinned(memo.name, next_pinned, function(success, err)
		vim.schedule(function()
			if success then
				memo.pinned = next_pinned
				render_cached_memos()
				vim.notify(next_pinned and "Memo pinned." or "Memo unpinned.")
				M.refresh_list_silently()
			else
				vim.notify("Failed to update memo pin: " .. tostring(err), vim.log.levels.ERROR)
			end
		end)
	end)
end

function M.archive_selected_memo()
	if current_list_state == "TEMPLATES" then
		vim.notify("Archiving is not supported for templates.", vim.log.levels.WARN)
		return
	end
	local item = current_list_item()
	local memo = item and item.kind == "memo" and memos_cache[item.index] or nil
	if not memo or not memo.name or memo.name == "" then
		vim.notify("No memo on the current line.", vim.log.levels.INFO)
		return
	end

	local next_state = current_list_state == "ARCHIVED" and "NORMAL" or "ARCHIVED"
	api:update_memo_state(memo.name, next_state, function(success, err)
		vim.schedule(function()
			if success then
				table.remove(memos_cache, item.index)
				render_cached_memos()
				vim.notify(next_state == "ARCHIVED" and "Memo archived." or "Memo restored.")
				M.refresh_list_silently()
			else
				vim.notify("Failed to update memo state: " .. tostring(err), vim.log.levels.ERROR)
			end
		end)
	end)
end

function M.delete_selected_memo()
	local item = current_list_item()
	local memo = item and item.kind == "memo" and memos_cache[item.index] or nil
	if not memo or not memo.name or memo.name == "" then
		vim.notify("Select a memo line to delete.", vim.log.levels.INFO)
		return
	end

	if current_list_state == "TEMPLATES" then
		require("memos.template").template_delete_selected(memo, item.index)
		return
	end

	local title = memo_title(memo)
	vim.ui.select({ "Cancel", "Delete" }, {
		prompt = "Delete memo: " .. title,
	}, function(choice)
		if choice ~= "Delete" then
			return
		end

		api:delete_memo(memo.name, function(success, err)
			vim.schedule(function()
				if success then
					table.remove(memos_cache, item.index)
					render_cached_memos()
					vim.notify("Memo deleted.")
					M.refresh_list_silently()
				else
					vim.notify("Failed to delete memo: " .. tostring(err), vim.log.levels.ERROR)
				end
			end)
		end)
	end)
end

function M.remove_cached_memo_at(index)
	if type(index) == "number" and memos_cache[index] then
		table.remove(memos_cache, index)
		render_cached_memos()
	end
end

function M.edit_selected_memo_visibility()
	if current_list_state == "TEMPLATES" then
		vim.notify("Visibility editing is not supported for templates.", vim.log.levels.WARN)
		return
	end
	local item = current_list_item()
	local memo = item and item.kind == "memo" and memos_cache[item.index] or nil
	if not memo or not memo.name or memo.name == "" then
		vim.notify("No memo on the current line.", vim.log.levels.INFO)
		return
	end

	vim.ui.select({ "PRIVATE", "PROTECTED", "PUBLIC" }, {
		prompt = "Memo visibility:",
	}, function(choice)
		if not choice then
			return
		end
		api:update_memo_visibility(memo.name, choice, function(success, err)
			vim.schedule(function()
				if success then
					memo.visibility = choice
					render_cached_memos()
					vim.notify("Memo visibility set to " .. choice .. ".")
					M.refresh_list_silently()
				else
					vim.notify("Failed to update memo visibility: " .. tostring(err), vim.log.levels.ERROR)
				end
			end)
		end)
	end)
end

function M.edit_selected_memo_create_time()
	if current_list_state == "TEMPLATES" then
		vim.notify("Create time editing is not supported for templates.", vim.log.levels.WARN)
		return
	end
	local item = current_list_item()
	local memo = item and item.kind == "memo" and memos_cache[item.index] or nil
	if not memo or not memo.name or memo.name == "" then
		vim.notify("No memo on the current line.", vim.log.levels.INFO)
		return
	end

	vim.ui.input({
		prompt = "Memo create_time:",
		default = memo.create_time or "",
	}, function(input)
		if input == nil then
			return
		end
		local next_create_time = vim.trim(input)
		if next_create_time == "" then
			vim.notify("Memo create_time is empty, not sending.", vim.log.levels.WARN)
			return
		end
		api:update_memo_create_time(memo.name, next_create_time, function(success, err)
			vim.schedule(function()
				if success then
					memo.create_time = next_create_time
					render_cached_memos()
					vim.notify("Memo create_time updated.")
					M.refresh_list_silently()
				else
					vim.notify("Failed to update memo create_time: " .. tostring(err), vim.log.levels.ERROR)
				end
			end)
		end)
	end)
end

function M.refresh_list_silently()
	if list_buf and vim.api.nvim_buf_is_valid(list_buf) then
		set_refresh_state("refreshing")
		if #memos_cache > 0 then
			render_cached_memos()
		end
		fetch_memos({ append = false })
	end
end

function M.return_to_list()
	local current_buf = vim.api.nvim_get_current_buf()
	M.show_memos_list()
	if vim.api.nvim_buf_is_valid(current_buf) and not vim.bo[current_buf].modified then
		pcall(vim.api.nvim_buf_delete, current_buf, { force = false })
	end
end

function M.check_and_auto_save()
	if vim.b.memos_original_content == nil then
		return
	end
	local content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
	if content ~= vim.b.memos_original_content then
		M.save_or_create_dispatcher()
	end
end

function M.save_or_create_dispatcher(opts)
	opts = opts or {}
	local post_save_ui = opts.post_save_ui ~= false
	local bufnr = vim.api.nvim_get_current_buf()
	if vim.b[bufnr].memos_save_inflight then
		vim.b[bufnr].memos_save_pending = true
		return
	end
	vim.b[bufnr].memos_save_inflight = true

	local memo_name = vim.b[bufnr].memos_memo_name
	local content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

	local function finish()
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		vim.b[bufnr].memos_save_inflight = false
		if vim.b[bufnr].memos_save_pending then
			vim.b[bufnr].memos_save_pending = false
			local latest = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
			if latest ~= vim.b[bufnr].memos_original_content then
				vim.schedule(function()
					if vim.api.nvim_buf_is_valid(bufnr) then
						M.save_or_create_dispatcher(opts)
					end
				end)
			end
		end
	end

	if content == "" then
		vim.notify("Memo is empty, not sending.", vim.log.levels.WARN)
		finish()
		return
	end

	if vim.b[bufnr].memos_template_mode then
		require("memos.template").save_template_buffer(bufnr, content, function(success, new_tpl, err)
			vim.schedule(function()
				if not vim.api.nvim_buf_is_valid(bufnr) then
					return
				end
				if success and new_tpl then
					vim.b[bufnr].memos_template_name = new_tpl.name
					vim.b[bufnr].memos_original_content = content
					vim.bo[bufnr].modified = false
					if new_tpl.buffer_name then
						pcall(vim.api.nvim_buf_set_name, bufnr, new_tpl.buffer_name)
					end
					vim.notify("Template saved.")
					M.refresh_list_silently()
				else
					vim.notify("Failed to save template: " .. tostring(err), vim.log.levels.ERROR)
				end
				finish()
			end)
		end)
		return
	end

	if memo_name then
		api:update_memo(memo_name, content, function(success, err)
			vim.schedule(function()
				if success then
					vim.b[bufnr].memos_original_content = content
					vim.bo[bufnr].modified = false
					vim.notify("Memo saved.")
					M.refresh_list_silently()
				else
					vim.notify("Failed to save memo: " .. tostring(err), vim.log.levels.ERROR)
				end
				finish()
			end)
		end)
		return
	end

	api:create_memo(content, function(new_memo, err)
		vim.schedule(function()
			if new_memo and new_memo.name then
				vim.b[bufnr].memos_memo_name = new_memo.name
				vim.b[bufnr].memos_original_content = content
				vim.bo[bufnr].modified = false
				local new_name = build_memo_buffer_name(new_memo, content)
				if new_name then
					pcall(vim.api.nvim_buf_set_name, bufnr, new_name)
				end
				vim.notify("Memo created.")
				if post_save_ui then
					M.show_memos_list()
				else
					M.refresh_list_silently()
				end
			else
				vim.notify("Failed to create memo: " .. tostring(err), vim.log.levels.ERROR)
			end
			finish()
		end)
	end)
end

function M.on_account_switched()
	caches = {
		NORMAL = { memos = {}, page_token = nil, filter = "", last_refresh_at = nil },
		ARCHIVED = { memos = {}, page_token = nil, filter = "", last_refresh_at = nil },
		TEMPLATES = { memos = {}, page_token = nil, filter = "", last_refresh_at = nil },
	}
	memos_cache = {}
	list_items = {}
	current_page_token = nil
	current_filter = ""
	current_list_state = config.list_state or "NORMAL"
	list_refresh_state = "idle"
	last_refresh_at = nil
	last_refresh_error = nil
	if list_buf and vim.api.nvim_buf_is_valid(list_buf) and vim.fn.bufwinid(list_buf) ~= -1 then
		M.show_memos_list({ force_refresh = true })
	end
end

local function status_text(with_seconds)
	local refreshed = format_time(last_refresh_at, with_seconds)
	if list_refresh_state == "refreshing" then
		if refreshed then
			return "Memos refreshing (Updated " .. refreshed .. ")"
		else
			return "Memos refreshing"
		end
	end
	if list_refresh_state == "failed" then
		if refreshed then
			return "Memos failed (Updated " .. refreshed .. ")"
		else
			return "Memos failed"
		end
	end
	if refreshed then
		return "Memos updated " .. refreshed
	end
	return ""
end

function M.status()
	return {
		state = list_refresh_state,
		text = status_text(true),
		last_refresh_at = last_refresh_at,
		last_error = last_refresh_error,
	}
end

function M.statusline()
	return status_text(false)
end

function M.toggle_template_view()
	save_current_state_cache()
	local next_state = current_list_state == "TEMPLATES" and "NORMAL" or "TEMPLATES"
	load_state_cache(next_state)
	redraw_status()
	focus_list_buf()
	M.show_memos_list()
end

function M.add_memo_command()
	if current_list_state == "TEMPLATES" then
		local item = current_list_item()
		local tpl = item and item.kind == "memo" and memos_cache[item.index] or nil
		if tpl then
			local content = require("memos.template").strip_template_tag(tpl.content or "")
			M.create_memo_in_buffer(content)
		else
			vim.notify("Select a template first.", vim.log.levels.INFO)
		end
	else
		M.create_memo_in_buffer()
	end
end

function M.new_memo_or_template_command()
	if current_list_state == "TEMPLATES" then
		require("memos.template").template_create()
	else
		M.create_memo_in_buffer()
	end
end

function M.refresh_list_command()
	M.show_memos_list({ force_refresh = true })
end

function M.show_templates_list()
	save_current_state_cache()
	load_state_cache("TEMPLATES")
	redraw_status()
	focus_list_buf()
	M.show_memos_list()
end

return M
