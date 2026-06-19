local api = require("memos.api")
local config = require("memos").config

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
	if list_refresh_state == "refreshing" then
		return "Refreshing..."
	end
	if list_refresh_state == "failed" then
		return "Refresh failed"
	end
	local refreshed = format_time(last_refresh_at, true)
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
	api.list_memos({
		page_size = config.page_size,
		page_token = opts.page_token,
		state = current_list_state,
		order_by = config.list_order_by,
		filter = current_filter,
	}, function(data, err)
		if not data then
			vim.schedule(function()
				set_refresh_state("failed", err)
				if #memos_cache > 0 then
					render_cached_memos()
				end
				vim.notify("Failed to fetch memos: " .. tostring(err), vim.log.levels.ERROR)
			end)
			return
		end
		if not opts.append then
			mark_refresh_success()
		end
		M.render_memos(data, opts.append == true)
	end)
end

function M.show_memos_list(opts)
	opts = opts or {}
	focus_list_buf()
	if #memos_cache == 0 then
		set_refresh_state("refreshing")
		set_list_lines({ "Loading memos..." })
		fetch_memos({ append = false })
	else
		set_refresh_state("refreshing")
		render_cached_memos()
		fetch_memos({ append = false })
	end

	local buf = ensure_list_buf()
	if not vim.b[buf].memos_list_keymaps then
		local keys = config.keymaps.list
		set_keymap(buf, keys.edit_memo, '<Cmd>lua require("memos.ui").edit_selected_memo()<CR>')
		set_keymap(buf, keys.edit_memo_split, '<Cmd>lua require("memos.ui").edit_selected_memo_split()<CR>')
		set_keymap(buf, keys.edit_memo_vsplit, '<Cmd>lua require("memos.ui").edit_selected_memo_vsplit()<CR>')
		set_keymap(buf, keys.add_memo, '<Cmd>lua require("memos.ui").create_memo_in_buffer()<CR>')
		set_keymap(buf, keys.search_memos, '<Cmd>lua require("memos.ui").search_memos()<CR>')
		set_keymap(buf, keys.copy_memo_id, '<Cmd>lua require("memos.ui").copy_selected_memo_id()<CR>')
		set_keymap(buf, keys.toggle_pin, '<Cmd>lua require("memos.ui").toggle_selected_memo_pin()<CR>')
		set_keymap(buf, keys.archive_memo, '<Cmd>lua require("memos.ui").archive_selected_memo()<CR>')
		set_keymap(buf, keys.toggle_archive_view, '<Cmd>lua require("memos.ui").toggle_archive_view()<CR>')
		set_keymap(buf, keys.refresh_list, '<Cmd>lua require("memos.ui").show_memos_list({ force_refresh = true })<CR>')
		set_keymap(buf, keys.next_page, '<Cmd>lua require("memos.ui").load_next_page()<CR>')
		set_keymap(buf, keys.quit, '<Cmd>lua require("memos.ui").quit_memos_list()<CR>')
		vim.b[buf].memos_list_keymaps = true
	end
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
		set_list_lines({ next_filter == "" and "Loading memos..." or "Loading filtered memos..." })
		if next_filter == "" then
			vim.notify("Memos search cleared.")
		else
			vim.notify("Memos search filter applied.")
		end
		fetch_memos({ append = false })
	end)
end

function M.toggle_archive_view()
	current_list_state = current_list_state == "ARCHIVED" and "NORMAL" or "ARCHIVED"
	memos_cache = {}
	list_items = {}
	current_page_token = nil
	set_refresh_state("refreshing")
	focus_list_buf()
	set_list_lines({ "Loading " .. current_list_state:lower() .. " memos..." })
	fetch_memos({ append = false })
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
			M.show_memos_list({ force_refresh = true })
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

function M.create_memo_in_buffer()
	M.open_edit_buffer("", "enew")
	vim.b.memos_memo_name = nil
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
		M.open_memo_for_edit(memo, open_cmd)
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
	local item = current_list_item()
	local memo = item and item.kind == "memo" and memos_cache[item.index] or nil
	if not memo or not memo.name or memo.name == "" then
		vim.notify("No memo on the current line.", vim.log.levels.INFO)
		return
	end

	local next_pinned = memo.pinned ~= true
	api.update_memo_pinned(memo.name, next_pinned, function(success, err)
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
	local item = current_list_item()
	local memo = item and item.kind == "memo" and memos_cache[item.index] or nil
	if not memo or not memo.name or memo.name == "" then
		vim.notify("No memo on the current line.", vim.log.levels.INFO)
		return
	end

	local next_state = current_list_state == "ARCHIVED" and "NORMAL" or "ARCHIVED"
	api.update_memo_state(memo.name, next_state, function(success, err)
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
	M.show_memos_list({ force_refresh = true })
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

	if memo_name then
		api.update_memo(memo_name, content, function(success, err)
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

	api.create_memo(content, function(new_memo, err)
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
					M.show_memos_list({ force_refresh = true })
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
	if list_refresh_state == "refreshing" then
		return "Memos refreshing"
	end
	if list_refresh_state == "failed" then
		return "Memos failed"
	end
	local refreshed = format_time(last_refresh_at, with_seconds)
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

return M
