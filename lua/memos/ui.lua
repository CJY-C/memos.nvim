local api = require("memos.api").new(function() return require("memos").config end)
local buffer_utils = require("memos.ui.buffers")
local relation_utils = require("memos.ui.relations")
local config = setmetatable({}, {
	__index = function(_, k)
		return require("memos").config[k]
	end,
})

local M = {}

local list_buf = nil
local last_float_buf = nil
local sessions = {}

local ns_id = vim.api.nvim_create_namespace("memos_list_highlights")

vim.api.nvim_set_hl(0, "MemosOutgoingLink", { link = "Label", default = true })
vim.api.nvim_set_hl(0, "MemosIncomingLink", { link = "Special", default = true })

local ListSession = {}
ListSession.__index = ListSession

function ListSession.new(bufnr)
	return setmetatable({
		buf = bufnr,
		memos_cache = {},
		list_items = {},
		current_page_token = nil,
		current_filter = "",
		current_list_state = config.list_state or "NORMAL",
		list_refresh_state = "idle",
		last_refresh_at = nil,
		last_refresh_error = nil,
		caches = {
			NORMAL = { memos = {}, page_token = nil, filter = "", last_refresh_at = nil, page_history = {} },
			ARCHIVED = { memos = {}, page_token = nil, filter = "", last_refresh_at = nil, page_history = {} },
			TEMPLATES = { memos = {}, page_token = nil, filter = "", last_refresh_at = nil, page_history = {} },
		},
		expanded_outgoing = {},
		expanded_incoming = {},
		relation_details_cache = {},
		relation_index_dirty = true,
		relation_index = relation_utils.empty_index(),
		in_flight_relations = {},
		main_list_fetching = false,
		page_history = {},
	}, ListSession)
end

local function get_active_session()
	local bufnr = vim.api.nvim_get_current_buf()
	if sessions[bufnr] then
		return sessions[bufnr]
	end
	if bufnr == list_buf then
		sessions[bufnr] = ListSession.new(bufnr)
		return sessions[bufnr]
	end
	return nil
end

local function redraw_status()
	vim.schedule(function()
		pcall(vim.cmd, "redrawstatus")
	end)
end

function ListSession:save_current_state_cache()
	local state = self.current_list_state
	self.caches[state] = {
		memos = vim.deepcopy(self.memos_cache),
		page_token = self.current_page_token,
		filter = self.current_filter,
		last_refresh_at = self.last_refresh_at,
		page_history = vim.deepcopy(self.page_history or {}),
	}
end

function ListSession:load_state_cache(state)
	self.current_list_state = state
	local c = self.caches[state] or { memos = {}, page_token = nil, filter = "", last_refresh_at = nil, page_history = {} }
	self.memos_cache = vim.deepcopy(c.memos)
	self.current_page_token = c.page_token
	self.current_filter = c.filter
	self.last_refresh_at = c.last_refresh_at
	self.page_history = vim.deepcopy(c.page_history or {})
	self.relation_index_dirty = true
end

local function has_active_fetches(self)
	if self.main_list_fetching then
		return true
	end
	for _, _ in pairs(self.in_flight_relations or {}) do
		return true
	end
	return false
end

function ListSession:set_refresh_state(state, err)
	local target_state = state or "idle"
	if target_state == "idle" and has_active_fetches(self) then
		target_state = "refreshing"
	end
	self.list_refresh_state = target_state
	if self.list_refresh_state == "failed" then
		self.last_refresh_error = tostring(err or "Unknown error")
	elseif self.list_refresh_state == "idle" then
		self.last_refresh_error = nil
	end
	redraw_status()
end

function ListSession:mark_refresh_success()
	self.last_refresh_at = os.time()
	self:set_refresh_state("idle")
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

	sessions[list_buf] = ListSession.new(list_buf)

	vim.api.nvim_create_autocmd("BufEnter", {
		buffer = list_buf,
		callback = function()
			local s = sessions[list_buf]
			if s then
				s:bind_list_keymaps()
			end
		end,
	})
	return list_buf
end

local function focus_list_buf()
	local buf = ensure_list_buf()
	local win = vim.fn.bufwinid(buf)
	if win ~= -1 then
		vim.api.nvim_set_current_win(win)
	else
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

	local active_win = vim.fn.bufwinid(buf)
	if active_win ~= -1 then
		vim.wo[active_win].wrap = false
		vim.wo[active_win].number = false
		vim.wo[active_win].relativenumber = false
		vim.wo[active_win].signcolumn = "no"
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

function ListSession:set_list_lines(lines)
	local buf = self.buf
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false
	end
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

function ListSession:mark_relation_index_dirty()
	self.relation_index_dirty = true
end

function ListSession:rebuild_relation_index()
	self.relation_index = relation_utils.build_index(self.memos_cache)
	self.relation_index_dirty = false
end

function ListSession:ensure_relation_index()
	if self.relation_index_dirty or not self.relation_index then
		self:rebuild_relation_index()
	end
	return self.relation_index
end

function ListSession:get_indexed_relation_names(direction, memo)
	local index = self:ensure_relation_index()
	return relation_utils.get_indexed_relation_names(index, direction, memo)
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
	local clean_title = title:gsub("[/\\]", "_")
	return "memos/" .. memo.name:gsub("^memos/", "") .. "/" .. vim.fn.strcharpart(clean_title, 0, 50) .. ".md"
end

local function set_keymap(buf, key, rhs)
	if type(key) ~= "string" or key == "" then
		return
	end
	vim.api.nvim_buf_set_keymap(buf, "n", key, rhs, { noremap = true, silent = true })
end

local function buffer_context()
	return {
		api = api,
		config = config,
		set_keymap = set_keymap,
		is_float_window = is_float_window,
		find_memos_float_window = find_memos_float_window,
		create_float_window = create_float_window,
		build_memo_buffer_name = build_memo_buffer_name,
		show_memos_list = M.show_memos_list,
		refresh_list_silently = M.refresh_list_silently,
	}
end

function ListSession:bind_list_keymaps()
	local buf = self.buf
	local keys = config.keymaps.list

	-- Clear previously bound keys to prevent ghost mappings
	if vim.b[buf].memos_bound_keys then
		for _, key in ipairs(vim.b[buf].memos_bound_keys) do
			pcall(vim.api.nvim_buf_del_keymap, buf, "n", key)
		end
	end

	local bound = {}
	local function set_map(key, lhs)
		if type(key) == "string" and key ~= "" then
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
	set_map(keys.add_relation or "c", '<Cmd>lua require("memos.ui").add_relation_command()<CR>')
	set_map(keys.toggle_pin, '<Cmd>lua require("memos.ui").toggle_selected_memo_pin()<CR>')
	set_map(keys.delete_memo, '<Cmd>lua require("memos.ui").delete_selected_memo()<CR>')
	set_map(keys.archive_memo, '<Cmd>lua require("memos.ui").archive_selected_memo()<CR>')
	set_map(keys.toggle_archive_view, '<Cmd>lua require("memos.ui").toggle_archive_view()<CR>')
	set_map(keys.toggle_template_view, '<Cmd>lua require("memos.ui").toggle_template_view()<CR>')
	set_map(keys.edit_visibility, '<Cmd>lua require("memos.ui").edit_selected_memo_visibility()<CR>')
	set_map(keys.edit_create_time, '<Cmd>lua require("memos.ui").edit_selected_memo_create_time()<CR>')
	set_map(keys.refresh_list, '<Cmd>lua require("memos.ui").refresh_list_command()<CR>')
	set_map(keys.next_page, '<Cmd>lua require("memos.ui").load_next_page()<CR>')
	set_map(keys.prev_page, '<Cmd>lua require("memos.ui").load_prev_page()<CR>')
	set_map(keys.quit, '<Cmd>lua require("memos.ui").quit_memos_list()<CR>')

	set_map(keys.toggle_expand or "<Tab>", '<Cmd>lua require("memos.ui").toggle_expand_selected()<CR>')
	set_map(keys.toggle_expand_incoming or "<S-Tab>", '<Cmd>lua require("memos.ui").toggle_expand_incoming_selected()<CR>')
	set_map(keys.fold_outgoing or "zo", '<Cmd>lua require("memos.ui").toggle_expand_selected()<CR>')
	set_map(keys.fold_incoming or "zi", '<Cmd>lua require("memos.ui").toggle_expand_incoming_selected()<CR>')
	set_map(keys.fold_all or "zM", '<Cmd>lua require("memos.ui").collapse_all()<CR>')

	vim.b[buf].memos_bound_keys = bound
end

function M.bind_list_keymaps(buf)
	local s = sessions[buf]
	if not s then
		s = ListSession.new(buf)
		sessions[buf] = s
	end
	s:bind_list_keymaps()
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

function ListSession:list_status_line()
	local refreshed = format_time(self.last_refresh_at, true)
	if self.list_refresh_state == "refreshing" then
		return "Refreshing..."
	end
	if self.list_refresh_state == "failed" then
		return "Refresh failed"
	end
	if refreshed then
		return "Updated " .. refreshed
	end
	return nil
end

function ListSession:list_header_line()
	local left = "View: " .. self.current_list_state
	local right = self:list_status_line()
	if not right then
		return left
	end

	local width = vim.o.columns
	local win = self.buf and vim.fn.bufwinid(self.buf) or -1
	if win ~= -1 and vim.api.nvim_win_is_valid(win) then
		width = vim.api.nvim_win_get_width(win)
	end

	local gap = width - #left - #right
	if gap > 1 then
		return left .. string.rep(" ", gap) .. right
	end
	return left .. " " .. right
end

function ListSession:collect_missing_relation_names()
	local names = {}
	local seen = {}
	local function add_missing(target_name)
		if target_name == "" or seen[target_name] then
			return
		end
		if self:get_cached_relation_memo(target_name) or self.in_flight_relations[target_name] then
			return
		end
		seen[target_name] = true
		table.insert(names, target_name)
	end

	for _, memo in ipairs(self.memos_cache) do
		if self.expanded_outgoing[memo.name] then
			for _, target_name in ipairs(self:get_outgoing_relation_names(memo)) do
				add_missing(target_name)
			end
		end
		if self.expanded_incoming[memo.name] then
			for _, target_name in ipairs(self:get_incoming_relation_names(memo)) do
				add_missing(target_name)
			end
		end
	end
	return names
end

function ListSession:render_cached_memos()
	vim.schedule(function()
		self.list_items = {}

		local lines = {}
		local line_hls = {}
		local keys = config.keymaps.list

		local function add_line(content, item_meta, hls)
			table.insert(lines, content)
			self.list_items[#lines] = item_meta
			if hls and #hls > 0 then
				line_hls[#lines] = hls
			end
		end

		add_line(self:list_header_line(), { kind = "header" })
		if self.current_filter ~= "" then
			add_line("Filter: " .. self.current_filter, { kind = "filter" })
		end

		if #self.memos_cache == 0 then
			local message = self.current_filter == "" and "No memos." or "No memos match the current filter."
			add_line(
				string.format("%s Press '%s' to refresh, '%s' to add, '%s' to quit.", message, keys.refresh_list, keys.add_memo, keys.quit),
				{ kind = "empty" }
			)
		else
			for index, memo in ipairs(self.memos_cache) do
				-- A. Render incoming relations above (expand up)
				if self.expanded_incoming[memo.name] then
					local incoming_names = self:get_incoming_relation_names(memo)
					for rel_idx, target_name in ipairs(incoming_names) do
						local rel_memo = self:get_cached_relation_memo(target_name)
						if rel_memo then
							local line_str, hls = self:format_incoming_relation_line(index, rel_idx, rel_memo)
							add_line(line_str, {
								kind = "relation",
								parent_index = index,
								relation_index = rel_idx,
								relation_type = "incoming",
								memo = rel_memo
							}, hls)
						else
							local line_str = string.format("   ┌── %d.i%d. Loading %s...", index, rel_idx, target_name)
							local prefix = "   ┌── "
							local highlight_len = #prefix + #tostring(index) + 2 + #tostring(rel_idx) + 2
							add_line(line_str, {
								kind = "relation_loading",
								parent_index = index,
								relation_name = target_name,
								relation_type = "incoming"
							}, {
								{
									hl_group = "MemosIncomingLink",
									start_col = 0,
									end_col = highlight_len
								}
							})
						end
					end
				end

				-- B. Render parent memo line
				local parent_str, parent_hls = self:format_memo_line(index, memo)
				add_line(parent_str, { kind = "memo", index = index }, parent_hls)

				-- C. Render outgoing relations below (expand down)
				if self.expanded_outgoing[memo.name] then
					local outgoing_names = self:get_outgoing_relation_names(memo)
					for rel_idx, target_name in ipairs(outgoing_names) do
						local rel_memo = self:get_cached_relation_memo(target_name)
						if rel_memo then
							local line_str, hls = self:format_outgoing_relation_line(index, rel_idx, rel_memo)
							add_line(line_str, {
								kind = "relation",
								parent_index = index,
								relation_index = rel_idx,
								relation_type = "outgoing",
								memo = rel_memo
							}, hls)
						else
							local line_str = string.format("   └── %d.o%d. Loading %s...", index, rel_idx, target_name)
							local prefix = "   └── "
							local highlight_len = #prefix + #tostring(index) + 2 + #tostring(rel_idx) + 2
							add_line(line_str, {
								kind = "relation_loading",
								parent_index = index,
								relation_name = target_name,
								relation_type = "outgoing"
							}, {
								{
									hl_group = "MemosOutgoingLink",
									start_col = 0,
									end_col = highlight_len
								}
							})
						end
					end
				end
			end
		end

		if self.current_page_token ~= "" then
			add_line("...", { kind = "load_more" })
			add_line(string.format("Press '%s' to load more", keys.next_page), { kind = "load_more" })
		end

		self:set_list_lines(lines)

		-- Apply namespace highlights
		if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
			vim.api.nvim_buf_clear_namespace(self.buf, ns_id, 0, -1)
			for line_num, hls in pairs(line_hls) do
				for _, hl in ipairs(hls) do
					vim.api.nvim_buf_add_highlight(self.buf, ns_id, hl.hl_group, line_num - 1, hl.start_col, hl.end_col)
				end
			end
		end

		local missing_relation_names = self:collect_missing_relation_names()
		if #missing_relation_names > 0 then
			self:fetch_missing_relations(missing_relation_names)
		end
	end)
end

function ListSession:render_memos(data, append)
	if not data then
		vim.notify("API returned no data.", vim.log.levels.WARN)
		return
	end
	if append then
		vim.list_extend(self.memos_cache, data.memos or {})
	else
		self.memos_cache = data.memos or {}
	end
	self:mark_relation_index_dirty()
	self.current_page_token = data.next_page_token or ""
	self:render_cached_memos()
end

function ListSession:fetch_memos(opts)
	opts = opts or {}
	local req_state = self.current_list_state
	local state_param = req_state
	local filter_param = self.current_filter

	if req_state == "TEMPLATES" then
		state_param = "ARCHIVED"
		if self.current_filter and self.current_filter ~= "" then
			filter_param = "content.contains('#type/template') && (" .. self.current_filter .. ")"
		else
			filter_param = "content.contains('#type/template')"
		end
	end

	if opts.append then
		table.insert(self.page_history, {
			memos_count = #self.memos_cache,
			page_token = self.current_page_token,
		})
	else
		self.page_history = {}
	end

	self.main_list_fetching = true
	self:set_refresh_state("refreshing")

	api:list_memos({
		page_size = config.page_size,
		page_token = opts.page_token,
		state = state_param,
		order_by = config.list_order_by,
		filter = filter_param,
	}, function(data, err)
		vim.schedule(function()
			self.main_list_fetching = false
			if not data then
				if self.current_list_state == req_state then
					self:set_refresh_state("failed", err)
					if opts.append then
						table.remove(self.page_history)
					end
					if #self.memos_cache > 0 then
						self:render_cached_memos()
					end
				end
				vim.notify("Failed to fetch memos: " .. tostring(err), vim.log.levels.ERROR)
				return
			end

			local is_append = opts.append == true
			if self.current_list_state == req_state then
				self:mark_refresh_success()
				self:render_memos(data, is_append)
			else
				-- Update the background cache slot directly
				local c = self.caches[req_state]
				if not is_append then
					c.memos = data.memos or {}
					c.last_refresh_at = os.time()
					c.page_history = {}
				else
					c.memos = c.memos or {}
					vim.list_extend(c.memos, data.memos or {})
				end
				c.page_token = data.next_page_token or ""
			end
		end)
	end)
end

function ListSession:format_memo_line(index, memo)
	if self.current_list_state == "TEMPLATES" then
		local title = memo_title(memo)
		title = require("memos.template").strip_template_tag(title)
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

	local outgoing_count = #self:get_outgoing_relation_names(memo)
	local incoming_count = #self:get_incoming_relation_names(memo)

	-- 2. Build indicator and highlights
	local hls = {}
	local full_line = line_without_indicator

	if outgoing_count > 0 or incoming_count > 0 then
		local link_indicator = ""
		local width = vim.o.columns
		local win = self.buf and vim.fn.bufwinid(self.buf) or -1
		if win ~= -1 and vim.api.nvim_win_is_valid(win) then
			width = vim.api.nvim_win_get_width(win)
		end
		local target_width = width - 3
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
				end_offset = current_len + #out_str
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
				end_offset = current_len + #in_str
			})
			current_len = current_len + #in_str
		end

		table.insert(parts, "]")
		link_indicator = table.concat(parts, "")

		local gap = target_width - vim.fn.strdisplaywidth(line_without_indicator) - vim.fn.strdisplaywidth(link_indicator)
		local gap_str = ""

		if gap > 0 then
			gap_str = string.rep(" ", gap)
		else
			gap_str = " "
		end

		full_line = line_without_indicator .. gap_str .. link_indicator

		local offset_shift = #line_without_indicator + #gap_str
		for _, hl in ipairs(hls) do
			hl.start_col = hl.start_offset + offset_shift
			hl.end_col = hl.end_offset + offset_shift
		end
	end

	return full_line, hls
end

function ListSession:get_cached_relation_memo(name)
	local index = self:ensure_relation_index()
	return relation_utils.get_cached_relation_memo(index, self.relation_details_cache, name)
end

function ListSession:format_incoming_relation_line(parent_idx, rel_idx, rel_memo)
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
	local prefix_len = #prefix
	local highlight_len = prefix_len + #idx_str + 2
	local hls = {
		{
			hl_group = "MemosIncomingLink",
			start_col = 0,
			end_col = highlight_len
		}
	}
	return line, hls
end

function ListSession:format_outgoing_relation_line(parent_idx, rel_idx, rel_memo)
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
	local prefix_len = #prefix
	local highlight_len = prefix_len + #idx_str + 2
	local hls = {
		{
			hl_group = "MemosOutgoingLink",
			start_col = 0,
			end_col = highlight_len
		}
	}
	return line, hls
end

function ListSession:get_outgoing_relation_names(memo)
	return self:get_indexed_relation_names("outgoing", memo)
end

function ListSession:get_incoming_relation_names(memo)
	return self:get_indexed_relation_names("incoming", memo)
end

function ListSession:toggle_expand_outgoing()
	local item = self:current_list_item()
	if not item or item.kind ~= "memo" then
		return
	end
	local memo = self.memos_cache[item.index]
	if not memo then
		return
	end
	local outgoing_names = self:get_outgoing_relation_names(memo)
	if #outgoing_names == 0 then
		vim.notify("No outgoing relations to expand.", vim.log.levels.INFO)
		return
	end

	if self.expanded_outgoing[memo.name] then
		self.expanded_outgoing[memo.name] = nil
	else
		self.expanded_outgoing[memo.name] = true
		self:fetch_missing_relations(outgoing_names)
	end
	self:render_cached_memos()
end

function ListSession:toggle_expand_incoming()
	local item = self:current_list_item()
	if not item or item.kind ~= "memo" then
		return
	end
	local memo = self.memos_cache[item.index]
	if not memo then
		return
	end
	local incoming_names = self:get_incoming_relation_names(memo)
	if #incoming_names == 0 then
		vim.notify("No incoming relations to expand.", vim.log.levels.INFO)
		return
	end

	if self.expanded_incoming[memo.name] then
		self.expanded_incoming[memo.name] = nil
	else
		self.expanded_incoming[memo.name] = true
		self:fetch_missing_relations(incoming_names)
	end
	self:render_cached_memos()
end

function ListSession:collapse_all()
	self.expanded_outgoing = {}
	self.expanded_incoming = {}
	self:render_cached_memos()
	vim.notify("Collapsed all memo expansions.")
end

function ListSession:fetch_missing_relations(names)
	for _, name in ipairs(names) do
		if not self:get_cached_relation_memo(name) then
			if not self.in_flight_relations[name] then
				self.in_flight_relations[name] = true
				self:set_refresh_state("refreshing")
				api:get_memo(name, function(memo_data, err)
					vim.schedule(function()
						self.in_flight_relations[name] = nil
						if memo_data then
							self.relation_details_cache[name] = memo_data
						else
							self.relation_details_cache[name] = {
								name = name,
								content = "Failed to load relation: " .. tostring(err),
								state = "NORMAL",
								create_time = "",
								update_time = "",
							}
						end
						self:set_refresh_state("idle")
						self:render_cached_memos()
					end)
				end)
			end
		end
	end
end

function M.show_memos_list(opts)
	opts = opts or {}
	local buf = ensure_list_buf()
	local s = sessions[buf]
	if not s then
		return
	end

	focus_list_buf()
	if #s.memos_cache == 0 or opts.force_refresh then
		s:set_refresh_state("refreshing")
		local loading_text = "Loading " .. s.current_list_state:lower() .. "..."
		s:set_list_lines({ loading_text })
		s:fetch_memos({ append = false })
	else
		s:set_refresh_state("refreshing")
		s:render_cached_memos()
		s:fetch_memos({ append = false })
	end

	s:bind_list_keymaps()
end

function ListSession:search_memos()
	vim.ui.input({ prompt = "Search memos (empty clears): " }, function(input)
		if input == nil then
			return
		end

		local next_filter = M.build_search_filter(input)
		self.current_filter = next_filter
		self.memos_cache = {}
		self.list_items = {}
		self.current_page_token = nil
		self:mark_relation_index_dirty()
		self.list_refresh_state = "idle"
		self.last_refresh_error = nil
		redraw_status()
		focus_list_buf()

		local entity_name = self.current_list_state == "TEMPLATES" and "templates" or "memos"
		local loading_text = next_filter == "" and ("Loading " .. entity_name .. "...") or ("Loading filtered " .. entity_name .. "...")
		self:set_list_lines({ loading_text })

		if next_filter == "" then
			vim.notify(self.current_list_state == "TEMPLATES" and "Templates search cleared." or "Memos search cleared.")
		else
			vim.notify(self.current_list_state == "TEMPLATES" and "Templates search filter applied." or "Memos search filter applied.")
		end
		self:fetch_memos({ append = false })
	end)
end

function ListSession:toggle_archive_view()
	self:save_current_state_cache()
	local next_state = self.current_list_state == "ARCHIVED" and "NORMAL" or "ARCHIVED"
	self:load_state_cache(next_state)
	redraw_status()
	focus_list_buf()
	M.show_memos_list()
end

function ListSession:load_next_page()
	if not self.current_page_token or self.current_page_token == "" then
		vim.notify("No more pages to load.", vim.log.levels.INFO)
		return
	end
	self:fetch_memos({
		page_token = self.current_page_token,
		append = true,
	})
end

function ListSession:load_prev_page()
	if not self.page_history or #self.page_history == 0 then
		vim.notify("Already at the first page.", vim.log.levels.INFO)
		return
	end
	local prev = table.remove(self.page_history)
	while #self.memos_cache > prev.memos_count do
		table.remove(self.memos_cache)
	end
	self.current_page_token = prev.page_token
	self:mark_relation_index_dirty()
	self:set_refresh_state("idle")
	self:render_cached_memos()
	vim.notify("Returned to previous page view.")
end

function M.search_memos()
	local s = get_active_session()
	if s then
		s:search_memos()
	end
end

function M.toggle_archive_view()
	local s = get_active_session()
	if s then
		s:toggle_archive_view()
	end
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
		local new_buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_win_set_buf(0, new_buf)
	end
end

function M.load_next_page()
	local s = get_active_session()
	if s then
		s:load_next_page()
	end
end

function M.load_prev_page()
	local s = get_active_session()
	if s then
		s:load_prev_page()
	end
end

function M.open_edit_buffer(content, open_cmd)
	return buffer_utils.open_edit_buffer(buffer_context(), content, open_cmd)
end

function M.setup_buffer_for_editing()
	return buffer_utils.setup_buffer_for_editing(buffer_context())
end

function M.open_memo_for_edit(memo, open_cmd)
	return buffer_utils.open_memo_for_edit(buffer_context(), memo, open_cmd)
end

function M.create_memo_in_buffer(content)
	return buffer_utils.create_memo_in_buffer(buffer_context(), content)
end

function ListSession:current_list_item()
	local line = vim.api.nvim_win_get_cursor(0)[1]
	return self.list_items[line]
end

function ListSession:get_memo_from_item(item)
	if not item then
		return nil
	end
	if item.kind == "memo" then
		return self.memos_cache[item.index]
	elseif item.kind == "relation" then
		return item.memo
	end
	return nil
end

function ListSession:remove_memo_from_cache(memo_name)
	for idx, m in ipairs(self.memos_cache) do
		if m.name == memo_name then
			table.remove(self.memos_cache, idx)
			self:mark_relation_index_dirty()
			break
		end
	end
	self.relation_details_cache[memo_name] = nil
	self.expanded_outgoing[memo_name] = nil
	self.expanded_incoming[memo_name] = nil
end

function ListSession:edit_selected_memo_with(open_cmd)
	local item = self:current_list_item()
	if not item then
		return
	end
	if item.kind == "load_more" then
		self:load_next_page()
		return
	end
	local memo = self:get_memo_from_item(item)
	if memo then
		if self.current_list_state == "TEMPLATES" then
			require("memos.template").template_edit_selected(memo, open_cmd)
		else
			M.open_memo_for_edit(memo, open_cmd)
		end
	end
end

function ListSession:copy_selected_memo_id()
	local item = self:current_list_item()
	local memo = self:get_memo_from_item(item)
	if not memo or not memo.name or memo.name == "" then
		vim.notify("No memo ID on the current line.", vim.log.levels.INFO)
		return
	end
	local register = copy_text(memo.name)
	vim.notify("Copied memo ID to " .. register .. ": " .. memo.name)
end

function ListSession:add_multiple_relations(memo, target_names)
	if not target_names or #target_names == 0 then
		return
	end

	local relations = {}
	local existing_targets = {}
	if type(memo.relations) == "table" then
		for _, r in ipairs(memo.relations) do
			local m_name = relation_utils.get_name_from_relation_field(r.memo or r.memoName)
			local r_name = relation_utils.get_name_from_relation_field(r.relatedMemo or r.related_memo or r.relatedMemoName)
			if m_name ~= "" and r_name ~= "" then
				table.insert(relations, {
					memo = { name = m_name },
					relatedMemo = { name = r_name },
					type = r.type or "REFERENCE"
				})
				if m_name == memo.name then
					existing_targets[r_name] = true
				end
			end
		end
	end

	local new_relations_to_add = {}
	local added_count = 0
	local self_link_attempt = false
	local already_exists_count = 0

	for _, target_name in ipairs(target_names) do
		target_name = vim.trim(target_name)
		if target_name ~= "" then
			if not target_name:match("^memos/") then
				target_name = "memos/" .. target_name
			end

			if relation_utils.match_memo_id_or_name(memo, target_name) then
				self_link_attempt = true
			elseif existing_targets[target_name] then
				already_exists_count = already_exists_count + 1
			else
				local new_rel = {
					memo = { name = memo.name },
					relatedMemo = { name = target_name },
					type = "REFERENCE"
				}
				table.insert(relations, new_rel)
				table.insert(new_relations_to_add, new_rel)
				existing_targets[target_name] = true
				added_count = added_count + 1
			end
		end
	end

	if self_link_attempt and added_count == 0 then
		vim.notify("Cannot create a relation to the same memo.", vim.log.levels.ERROR)
		return
	end

	if added_count == 0 then
		if already_exists_count > 0 then
			vim.notify("Relation(s) already exist.", vim.log.levels.INFO)
		end
		return
	end

	api:set_memo_relations(memo.name, relations, function(success, err)
		vim.schedule(function()
			if success then
				if not memo.relations then
					memo.relations = {}
				end
				for _, new_rel in ipairs(new_relations_to_add) do
					table.insert(memo.relations, new_rel)
				end
				self:mark_relation_index_dirty()
				self:render_cached_memos()
				if added_count == 1 then
					vim.notify("Relation added successfully.")
				else
					vim.notify(string.format("%d relations added successfully.", added_count))
				end
				self:refresh_list_silently()
			else
				vim.notify("Failed to add relation: " .. tostring(err), vim.log.levels.ERROR)
			end
		end)
	end)
end

function ListSession:add_relation()
	if self.current_list_state == "TEMPLATES" then
		vim.notify("Relations are not supported for templates.", vim.log.levels.WARN)
		return
	end
	local item = self:current_list_item()
	local memo = self:get_memo_from_item(item)
	if not memo or not memo.name or memo.name == "" then
		vim.notify("No memo on the current line.", vim.log.levels.INFO)
		return
	end

	local function get_clipboard_memo_id()
		for _, reg in ipairs({ "+", "*", '"' }) do
			local content = vim.trim(vim.fn.getreg(reg) or "")
			if content ~= "" then
				if content:match("^memos/[%w%-_]+$") then
					return content
				elseif content:match("^[%w%-_]+$") and not content:match("^%d+$") then
					return "memos/" .. content
				elseif content:match("^%d+$") then
					return "memos/" .. content
				end
			end
		end
		return ""
	end

	local choices = {}
	local choice_map = {}

	local clipboard_id = get_clipboard_memo_id()
	if clipboard_id ~= "" then
		local clip_label = string.format("[Use Clipboard: %s]", clipboard_id)
		table.insert(choices, clip_label)
		choice_map[clip_label] = { type = "clipboard", value = clipboard_id }
	end

	for _, m in ipairs(self.memos_cache) do
		if not relation_utils.is_same_memo(m, memo) then
			local title = m.content:match("^([^\n]*)") or ""
			title = vim.trim(title)
			if title == "" then
				title = m.snippet or ""
			end
			if title == "" then
				title = "(No Content)"
			end
			local label = string.format("%s - %s", m.name, vim.fn.strcharpart(title, 0, 60))
			table.insert(choices, label)
			choice_map[label] = { type = "memo", value = m.name }
		end
	end

	local manual_label = "[Input memo ID manually]"
	table.insert(choices, manual_label)
	choice_map[manual_label] = { type = "manual" }

	local has_telescope, telescope = pcall(require, "telescope")
	if has_telescope then
		local pickers = require("telescope.pickers")
		local finders = require("telescope.finders")
		local conf = require("telescope.config").values
		local actions = require("telescope.actions")
		local action_state = require("telescope.actions.state")

		pickers.new({}, {
			prompt_title = "Select memo(s) to relate:",
			finder = finders.new_table {
				results = choices,
				entry_maker = function(entry)
					return {
						value = entry,
						display = entry,
						ordinal = entry,
					}
				end
			},
			sorter = conf.generic_sorter({}),
			previewer = false,
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local picker = action_state.get_current_picker(prompt_bufnr)
					local selections = picker:get_multi_selection()
					if vim.tbl_isempty(selections) then
						local entry = action_state.get_selected_entry()
						if entry then
							selections = { entry }
						else
							selections = {}
						end
					end
					actions.close(prompt_bufnr)

					local target_names = {}
					for _, sel in ipairs(selections) do
						local info = choice_map[sel.value]
						if info then
							if info.type == "manual" then
								local target_input = vim.fn.input("Add relation to target memo ID: ", "")
								print(" ")
								target_input = vim.trim(target_input or "")
								if target_input ~= "" then
									table.insert(target_names, target_input)
								end
							else
								table.insert(target_names, info.value)
							end
						end
					end

					self:add_multiple_relations(memo, target_names)
				end)
				return true
			end
		}):find()
		return
	end

	vim.ui.select(choices, {
		prompt = "Select memo to relate (or input ID):",
		kind = "memos_relation",
	}, function(choice)
		if not choice then
			return
		end
		local info = choice_map[choice]
		if not info then
			return
		end

		local target_name = ""
		if info.type == "manual" then
			local target_input = vim.fn.input("Add relation to target memo ID: ", "")
			print(" ")
			target_input = vim.trim(target_input or "")
			if target_input == "" then
				vim.notify("Relation addition cancelled.", vim.log.levels.INFO)
				return
			end
			target_name = target_input
		else
			target_name = info.value
		end

		self:add_multiple_relations(memo, { target_name })
	end)
end

function ListSession:toggle_selected_memo_pin()
	if self.current_list_state == "TEMPLATES" then
		vim.notify("Pinning is not supported for templates.", vim.log.levels.WARN)
		return
	end
	local item = self:current_list_item()
	local memo = self:get_memo_from_item(item)
	if not memo or not memo.name or memo.name == "" then
		vim.notify("No memo on the current line.", vim.log.levels.INFO)
		return
	end

	local next_pinned = memo.pinned ~= true
	api:update_memo_pinned(memo.name, next_pinned, function(success, err)
		vim.schedule(function()
			if success then
				memo.pinned = next_pinned
				self:render_cached_memos()
				vim.notify(next_pinned and "Memo pinned." or "Memo unpinned.")
				self:refresh_list_silently()
			else
				vim.notify("Failed to update memo pin: " .. tostring(err), vim.log.levels.ERROR)
			end
		end)
	end)
end

function ListSession:archive_selected_memo()
	if self.current_list_state == "TEMPLATES" then
		vim.notify("Archiving is not supported for templates.", vim.log.levels.WARN)
		return
	end
	local item = self:current_list_item()
	local memo = self:get_memo_from_item(item)
	if not memo or not memo.name or memo.name == "" then
		vim.notify("No memo on the current line.", vim.log.levels.INFO)
		return
	end

	local next_state = self.current_list_state == "ARCHIVED" and "NORMAL" or "ARCHIVED"
	api:update_memo_state(memo.name, next_state, function(success, err)
		vim.schedule(function()
			if success then
				self:remove_memo_from_cache(memo.name)
				self:render_cached_memos()
				vim.notify(next_state == "ARCHIVED" and "Memo archived." or "Memo restored.")
				self:refresh_list_silently()
			else
				vim.notify("Failed to update memo state: " .. tostring(err), vim.log.levels.ERROR)
			end
		end)
	end)
end

function ListSession:delete_selected_memo()
	local item = self:current_list_item()
	if not item then
		return
	end

	if item.kind == "relation" or item.kind == "relation_loading" then
		self:delete_selected_relation(item)
		return
	end

	local memo = self:get_memo_from_item(item)
	if not memo or not memo.name or memo.name == "" then
		vim.notify("Select a memo line to delete.", vim.log.levels.INFO)
		return
	end

	if self.current_list_state == "TEMPLATES" then
		require("memos.template").template_delete_selected(memo, item.index)
		return
	end

	local title = memo_title(memo)
	vim.ui.select({ "Cancel", "Delete" }, {
		prompt = "Delete memo: " .. title,
		kind = "memos_delete",
	}, function(choice)
		if choice ~= "Delete" then
			return
		end

		api:delete_memo(memo.name, function(success, err)
			vim.schedule(function()
				if success then
					self:remove_memo_from_cache(memo.name)
					self:render_cached_memos()
					vim.notify("Memo deleted.")
					self:refresh_list_silently()
				else
					vim.notify("Failed to delete memo: " .. tostring(err), vim.log.levels.ERROR)
				end
			end)
		end)
	end)
end

function ListSession:delete_selected_relation(item)
	local parent_memo = self.memos_cache[item.parent_index]
	if not parent_memo then
		vim.notify("Parent memo not found.", vim.log.levels.ERROR)
		return
	end

	local target_name = ""
	if item.kind == "relation" then
		target_name = item.memo.name
	elseif item.kind == "relation_loading" then
		target_name = item.relation_name
	end

	if target_name == "" then
		vim.notify("Related memo name not found.", vim.log.levels.ERROR)
		return
	end

	local source_memo_name
	local target_memo_name
	if item.relation_type == "outgoing" then
		source_memo_name = parent_memo.name
		target_memo_name = target_name
	else
		source_memo_name = target_name
		target_memo_name = parent_memo.name
	end

	local source_memo
	if source_memo_name == parent_memo.name then
		source_memo = parent_memo
	else
		source_memo = self:get_cached_relation_memo(source_memo_name)
	end

	if not source_memo or not source_memo.relations then
		vim.notify("Relation source memo not loaded.", vim.log.levels.WARN)
		return
	end

	local prompt_msg = string.format("Unlink relation: %s -> %s?", source_memo_name, target_memo_name)
	vim.ui.select({ "Cancel", "Unlink" }, {
		prompt = prompt_msg,
		kind = "memos_unlink",
	}, function(choice)
		if choice ~= "Unlink" then
			return
		end

		local new_relations = {}
		for _, r in ipairs(source_memo.relations) do
			local m_name = relation_utils.get_name_from_relation_field(r.memo or r.memoName)
			local r_name = relation_utils.get_name_from_relation_field(r.relatedMemo or r.related_memo or r.relatedMemoName)
			if m_name ~= "" and r_name ~= "" then
				if not (m_name == source_memo_name and r_name == target_memo_name) then
					table.insert(new_relations, {
						memo = { name = m_name },
						relatedMemo = { name = r_name },
						type = r.type or "REFERENCE"
					})
				end
			end
		end

		api:set_memo_relations(source_memo_name, new_relations, function(success, err)
			vim.schedule(function()
				if success then
					source_memo.relations = {}
					for _, r in ipairs(new_relations) do
						table.insert(source_memo.relations, r)
					end
					self:mark_relation_index_dirty()
					self:render_cached_memos()
					vim.notify("Relation unlinked.")
					self:refresh_list_silently()
				else
					vim.notify("Failed to unlink relation: " .. tostring(err), vim.log.levels.ERROR)
				end
			end)
		end)
	end)
end

function ListSession:edit_selected_memo_visibility()
	if self.current_list_state == "TEMPLATES" then
		vim.notify("Visibility editing is not supported for templates.", vim.log.levels.WARN)
		return
	end
	local item = self:current_list_item()
	local memo = self:get_memo_from_item(item)
	if not memo or not memo.name or memo.name == "" then
		vim.notify("No memo on the current line.", vim.log.levels.INFO)
		return
	end

	vim.ui.select({ "PRIVATE", "PROTECTED", "PUBLIC" }, {
		prompt = "Memo visibility:",
		kind = "memos_visibility",
	}, function(choice)
		if not choice then
			return
		end
		api:update_memo_visibility(memo.name, choice, function(success, err)
			vim.schedule(function()
				if success then
					memo.visibility = choice
					self:render_cached_memos()
					vim.notify("Memo visibility set to " .. choice .. ".")
					self:refresh_list_silently()
				else
					vim.notify("Failed to update memo visibility: " .. tostring(err), vim.log.levels.ERROR)
				end
			end)
		end)
	end)
end

function ListSession:edit_selected_memo_create_time()
	if self.current_list_state == "TEMPLATES" then
		vim.notify("Create time editing is not supported for templates.", vim.log.levels.WARN)
		return
	end
	local item = self:current_list_item()
	local memo = self:get_memo_from_item(item)
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
					self:render_cached_memos()
					vim.notify("Memo create_time updated.")
					self:refresh_list_silently()
				else
					vim.notify("Failed to update memo create_time: " .. tostring(err), vim.log.levels.ERROR)
				end
			end)
		end)
	end)
end

function ListSession:refresh_list_silently()
	if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
		self:set_refresh_state("refreshing")
		if #self.memos_cache > 0 then
			self:render_cached_memos()
		end
		self:fetch_memos({ append = false })
	end
end

function M.toggle_expand_selected()
	local s = get_active_session()
	if s then
		s:toggle_expand_outgoing()
	end
end

function M.toggle_expand_incoming_selected()
	local s = get_active_session()
	if s then
		s:toggle_expand_incoming()
	end
end

function M.collapse_all()
	local s = get_active_session()
	if s then
		s:collapse_all()
	end
end

function M.edit_selected_memo()
	local s = get_active_session()
	if s then
		s:edit_selected_memo_with("enew")
	end
end

function M.edit_selected_memo_split()
	local s = get_active_session()
	if s then
		s:edit_selected_memo_with("split")
	end
end

function M.edit_selected_memo_vsplit()
	local s = get_active_session()
	if s then
		s:edit_selected_memo_with("vsplit")
	end
end

function M.copy_selected_memo_id()
	local s = get_active_session()
	if s then
		s:copy_selected_memo_id()
	end
end

function M.add_relation_command()
	local s = get_active_session()
	if s then
		s:add_relation()
	end
end

function M.toggle_selected_memo_pin()
	local s = get_active_session()
	if s then
		s:toggle_selected_memo_pin()
	end
end

function M.archive_selected_memo()
	local s = get_active_session()
	if s then
		s:archive_selected_memo()
	end
end

function M.delete_selected_memo()
	local s = get_active_session()
	if s then
		s:delete_selected_memo()
	end
end

function M.remove_cached_memo_at(index)
	local s = get_active_session()
	if s and type(index) == "number" and s.memos_cache[index] then
		table.remove(s.memos_cache, index)
		s:render_cached_memos()
	end
end

function M.edit_selected_memo_visibility()
	local s = get_active_session()
	if s then
		s:edit_selected_memo_visibility()
	end
end

function M.edit_selected_memo_create_time()
	local s = get_active_session()
	if s then
		s:edit_selected_memo_create_time()
	end
end

function M.refresh_list_silently()
	local s = get_active_session()
	if s then
		s:refresh_list_silently()
	end
end

function M.return_to_list()
	return buffer_utils.return_to_list(buffer_context())
end

function M.check_and_auto_save(buf)
	return buffer_utils.check_and_auto_save(buffer_context(), buf)
end

function M.save_or_create_dispatcher(opts)
	return buffer_utils.save_or_create_dispatcher(buffer_context(), opts)
end

function ListSession:toggle_template_view()
	self:save_current_state_cache()
	local next_state = self.current_list_state == "TEMPLATES" and "NORMAL" or "TEMPLATES"
	self:load_state_cache(next_state)
	redraw_status()
	focus_list_buf()
	M.show_memos_list()
end

function M.on_account_switched()
	sessions = {}
	if list_buf and vim.api.nvim_buf_is_valid(list_buf) and vim.fn.bufwinid(list_buf) ~= -1 then
		sessions[list_buf] = ListSession.new(list_buf)
		M.show_memos_list({ force_refresh = true })
	end
end

local function status_text(s, with_seconds)
	if not s then
		return ""
	end
	local refreshed = format_time(s.last_refresh_at, with_seconds)
	if s.list_refresh_state == "refreshing" then
		return "Memos refreshing"
	end
	if s.list_refresh_state == "failed" then
		return "Memos failed"
	end
	if refreshed then
		return "Memos updated " .. refreshed
	end
	return ""
end

function M.status()
	local s = get_active_session()
	if not s then
		return {
			state = "idle",
			text = "",
			last_refresh_at = nil,
			last_error = nil,
		}
	end
	return {
		state = s.list_refresh_state,
		text = status_text(s, true),
		last_refresh_at = s.last_refresh_at,
		last_error = s.last_refresh_error,
	}
end

function M.statusline()
	local s = get_active_session()
	return status_text(s, false)
end

function M.toggle_template_view()
	local s = get_active_session()
	if s then
		s:toggle_template_view()
	end
end

function M.add_memo_command()
	local s = get_active_session()
	if s and s.current_list_state == "TEMPLATES" then
		local item = s:current_list_item()
		local tpl = item and item.kind == "memo" and s.memos_cache[item.index] or nil
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
	local s = get_active_session()
	if s and s.current_list_state == "TEMPLATES" then
		require("memos.template").template_create()
	else
		M.create_memo_in_buffer()
	end
end

function M.refresh_list_command()
	M.show_memos_list({ force_refresh = true })
end

function M.show_templates_list()
	local buf = ensure_list_buf()
	local s = sessions[buf]
	if s then
		s:save_current_state_cache()
		s:load_state_cache("TEMPLATES")
	end
	redraw_status()
	focus_list_buf()
	M.show_memos_list()
end

function M.get_session(bufnr)
	return sessions[bufnr]
end

return M
