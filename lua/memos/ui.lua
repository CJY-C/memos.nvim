local api = require("memos.api").new(function() return require("memos").config end)
local buffer_utils = require("memos.ui.buffers")
local memo_actions = require("memos.ui.memo_actions")
local relation_actions = require("memos.ui.relation_actions")
local render_utils = require("memos.ui.render")
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

local function format_time(value, with_seconds)
	if not value then
		return nil
	end
	return os.date(with_seconds and "%H:%M:%S" or "%H:%M", value)
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

function M.format_memo_line(index, memo)
	local line = render_utils.format_memo_line({
		buf = nil,
		current_list_state = config.list_state or "NORMAL",
		get_outgoing_relation_names = function()
			return {}
		end,
		get_incoming_relation_names = function()
			return {}
		end,
	}, config, index, memo)
	return line
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

local function relation_action_context()
	return {
		api = api,
	}
end

local function memo_action_context()
	return {
		api = api,
		memo_title = memo_title,
		template_delete_selected = function(memo, index)
			return require("memos.template").template_delete_selected(memo, index)
		end,
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
	return render_utils.status_line(self)
end

function ListSession:list_header_line()
	return render_utils.header_line(self)
end

function ListSession:collect_missing_relation_names()
	return render_utils.collect_missing_relation_names(self)
end

function ListSession:render_cached_memos()
	vim.schedule(function()
		local rendered = render_utils.build(self, config)
		self.list_items = rendered.list_items
		self:set_list_lines(rendered.lines)

		-- Apply namespace highlights
		if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
			vim.api.nvim_buf_clear_namespace(self.buf, ns_id, 0, -1)
			for line_num, hls in pairs(rendered.line_hls) do
				for _, hl in ipairs(hls) do
					vim.api.nvim_buf_add_highlight(self.buf, ns_id, hl.hl_group, line_num - 1, hl.start_col, hl.end_col)
				end
			end
		end

		if #rendered.missing_relation_names > 0 then
			self:fetch_missing_relations(rendered.missing_relation_names)
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
	return render_utils.format_memo_line(self, config, index, memo)
end

function ListSession:get_cached_relation_memo(name)
	local index = self:ensure_relation_index()
	return relation_utils.get_cached_relation_memo(index, self.relation_details_cache, name)
end

function ListSession:format_incoming_relation_line(parent_idx, rel_idx, rel_memo)
	return render_utils.format_incoming_relation_line(config, parent_idx, rel_idx, rel_memo)
end

function ListSession:format_outgoing_relation_line(parent_idx, rel_idx, rel_memo)
	return render_utils.format_outgoing_relation_line(config, parent_idx, rel_idx, rel_memo)
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
	return relation_actions.add_multiple_relations(self, relation_action_context(), memo, target_names)
end

function ListSession:add_relation()
	return relation_actions.add_relation(self, relation_action_context())
end

function ListSession:toggle_selected_memo_pin()
	return memo_actions.toggle_pin(self, memo_action_context())
end

function ListSession:archive_selected_memo()
	return memo_actions.archive(self, memo_action_context())
end

function ListSession:delete_selected_memo()
	return memo_actions.delete(self, memo_action_context())
end

function ListSession:delete_selected_relation(item)
	return relation_actions.delete_selected_relation(self, relation_action_context(), item)
end

function ListSession:edit_selected_memo_visibility()
	return memo_actions.edit_visibility(self, memo_action_context())
end

function ListSession:edit_selected_memo_create_time()
	return memo_actions.edit_create_time(self, memo_action_context())
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
