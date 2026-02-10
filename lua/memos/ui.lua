local api = require("memos.api")
local config = require("memos").config

local M = {}

local function get_capabilities()
	return api.get_capabilities()
end

local memos_cache = {}
local buf_id = nil
local current_page_token = nil
local current_user = nil
local current_filter = nil
local current_order_by = nil
local current_sort_index = nil
local current_state = nil
local last_float_buf_id = nil

function M.on_account_switched()
	current_user = nil
	current_page_token = nil
	memos_cache = {}
	current_order_by = nil
	current_sort_index = nil
	current_state = nil

	if buf_id and vim.api.nvim_buf_is_valid(buf_id) and vim.fn.bufwinid(buf_id) ~= -1 then
		M.show_memos_list(current_filter)
	end
end

local create_float_window

local function is_float_window(win)
	local cfg = vim.api.nvim_win_get_config(win)
	return cfg and cfg.relative and cfg.relative ~= ""
end

local function find_memos_float_window()
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		local ok, v = pcall(vim.api.nvim_win_get_var, w, "memos_window")
		if ok and v == true and vim.api.nvim_win_is_valid(w) then
			return w
		end
	end
	return nil
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

local function switch_away_and_wipe(current_buf)
	local alt = vim.fn.bufnr("#")
	if alt > 0 and vim.api.nvim_buf_is_valid(alt) and alt ~= current_buf then
		vim.api.nvim_set_current_buf(alt)
	else
		vim.cmd("enew")
	end

	if vim.api.nvim_buf_is_valid(current_buf) then
		vim.api.nvim_buf_delete(current_buf, { force = true })
	end
	if buf_id == current_buf then
		buf_id = nil
	end
end

function M.quit_memos_list()
	local current_win = vim.api.nvim_get_current_win()
	local current_buf = vim.api.nvim_get_current_buf()
	local is_memos_float = false

	local ok, win_var = pcall(vim.api.nvim_win_get_var, current_win, "memos_window")
	if ok and win_var == true then
		is_memos_float = true
	end

	-- Floating mode should close the float window itself.
	if is_memos_float then
		local ok_close = pcall(vim.api.nvim_win_close, current_win, true)
		if not ok_close then
			switch_away_and_wipe(current_buf)
		end
		return
	end

	-- In non-floating mode, only close this window when there are multiple normal windows.
	if count_normal_windows() > 1 then
		local ok_close = pcall(vim.api.nvim_win_close, current_win, true)
		if not ok_close then
			switch_away_and_wipe(current_buf)
		end
		return
	end

	-- Last normal window: switch away first, then wipe the memos buffer.
	switch_away_and_wipe(current_buf)
	current_order_by = nil
	current_sort_index = nil
	current_state = nil
end

function M.render_memos(data, append)
	vim.schedule(function()
		if not buf_id or not vim.api.nvim_buf_is_valid(buf_id) then
			return
		end
		if not data then
			vim.notify("API returned no data.", vim.log.levels.WARN)
			return
		end
		local new_memos = data.memos or {}
		current_page_token = data.nextPageToken or ""
		if append then
			memos_cache = vim.list_extend(memos_cache, new_memos)
		else
			memos_cache = new_memos
		end
		local lines = {}
		local k = config.keymaps.list
		if #memos_cache == 0 then
			local help = string.format(
				"No memos found. Press '%s' to refresh, '%s' to add, or '%s' to quit.",
				k.refresh_list,
				k.add_memo,
				k.quit
			)
			table.insert(lines, help)
		else
			for i, memo in ipairs(memos_cache) do
				local content = type(memo.content) == "string" and memo.content or ""
				local first_line = content:match("^[^\n]*") or ""
				local display_time = type(memo.displayTime) == "string" and memo.displayTime or ""
				if display_time == "" then
					display_time = "unknown"
				else
					display_time = display_time:sub(1, 10)
				end
				local badges = {}
				if memo.pinned == true then
					table.insert(badges, "P")
				end
				if memo.state == "ARCHIVED" then
					table.insert(badges, "A")
				end
				local badge_text = ""
				if #badges > 0 then
					badge_text = "[" .. table.concat(badges, "") .. "] "
				end
				table.insert(lines, string.format("%d. [%s] %s%s", i, display_time, badge_text, first_line))
			end
		end
		if current_page_token ~= "" then
			table.insert(lines, "...")
			table.insert(lines, string.format("(Press '%s' to load more)", k.next_page))
		end
		vim.api.nvim_buf_set_option(buf_id, "modifiable", true)
		vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, lines)
		vim.api.nvim_buf_set_option(buf_id, "modifiable", false)
	end)
end

function M.return_to_list()
	local current_edit_buf = vim.api.nvim_get_current_buf()

	-- Try switching first; this respects user 'hidden' policy.
	local ok, err = pcall(M.show_memos_list, current_filter, { force_refresh = true, reason = "return" })
	if not ok then
		vim.notify("Could not leave memo buffer: " .. tostring(err), vim.log.levels.WARN)
		return
	end

	if not vim.api.nvim_buf_is_valid(current_edit_buf) then
		return
	end

	-- Never force-delete a modified memo buffer.
	if vim.bo[current_edit_buf].modified then
		return
	end

	-- Clean up unchanged transient buffers.
	pcall(vim.api.nvim_buf_delete, current_edit_buf, { force = false })
	if buf_id == current_edit_buf then
		buf_id = nil
	end
end

function M.setup_buffer_for_editing()
	vim.bo.buftype = "acwrite"
	vim.bo.bufhidden = "hide"
	vim.bo.swapfile = false
	vim.bo.buflisted = false
	vim.bo.filetype = "markdown"

	vim.b.memos_original_content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
	-- Initial content load should not be treated as an unsaved user edit.
	vim.bo.modified = false
	vim.b.memos_save_inflight = false
	vim.b.memos_save_pending = false

	local save_key_string = ""
	if config.keymaps.buffer.save and config.keymaps.buffer.save ~= "" then
		save_key_string = string.format(" or %s", config.keymaps.buffer.save)
	end

	if vim.b.memos_memo_name then
		vim.notify("Editing memo. Use :MemosSave" .. save_key_string .. " to save.")
	else
		vim.notify("📝 New memo. Use :MemosSave" .. save_key_string .. " to create.")
	end

	vim.api.nvim_buf_create_user_command(0, "MemosSave", 'lua require("memos.ui").save_or_create_dispatcher()', {})
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = 0,
		callback = function()
			M.save_or_create_dispatcher()
		end,
	})
	if config.keymaps.buffer.save and config.keymaps.buffer.save ~= "" then
		vim.api.nvim_buf_set_keymap(
			0,
			"n",
			config.keymaps.buffer.save,
			"<Cmd>MemosSave<CR>",
			{ noremap = true, silent = true }
		)
		-- 【新增】绑定返回列表快捷键
		if config.keymaps.buffer.back_to_list and config.keymaps.buffer.back_to_list ~= "" then
			vim.api.nvim_buf_set_keymap(
				0,
				"n",
				config.keymaps.buffer.back_to_list,
				'<Cmd>lua require("memos.ui").return_to_list()<CR>',
				{ noremap = true, silent = true }
			)
		end
	end

	if config.keymaps.buffer.edit_metadata and config.keymaps.buffer.edit_metadata ~= "" then
		vim.api.nvim_buf_set_keymap(
			0,
			"n",
			config.keymaps.buffer.edit_metadata,
			'<Cmd>lua require("memos.ui").modify_current_memo_metadata()<CR>',
			{ noremap = true, silent = true }
		)
	end

	if config.auto_save then
		local group = vim.api.nvim_create_augroup("MemosAutoSave", { clear = true })
		vim.api.nvim_create_autocmd("InsertLeave", {
			group = group,
			buffer = 0,
			callback = function()
				M.check_and_auto_save()
			end,
		})
		vim.api.nvim_create_autocmd("CursorHold", {
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
	local content = type(memo.content) == "string" and memo.content or ""
	local first_line = content:match("^[^\n]*") or "memo"
	local buffer_name = "memos/"
		.. memo.name:gsub("memos/", "")
		.. "/"
		.. first_line:gsub("[/\\]", "_"):sub(1, 50)
		.. ".md"
	local existing_bufnr = vim.fn.bufnr(buffer_name)

	if existing_bufnr ~= -1 and vim.api.nvim_buf_is_loaded(existing_bufnr) then
		local win_id = vim.fn.bufwinid(existing_bufnr)
		if win_id ~= -1 then
			vim.api.nvim_set_current_win(win_id)
		else
			if config.window and config.window.enable_float then
				local float_win = find_memos_float_window()
				if float_win then
					vim.api.nvim_set_current_win(float_win)
				end
			end
			vim.api.nvim_set_current_buf(existing_bufnr)
		end
	else
		local used_float = false
		if config.window and config.window.enable_float then
			local float_win = find_memos_float_window()
			if float_win then
				vim.api.nvim_set_current_win(float_win)
				vim.cmd("enew")
				used_float = true
			end
		end
		if not used_float then
			vim.cmd(open_cmd)
		end
		vim.api.nvim_buf_set_name(0, buffer_name)
		vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(content, "\n"))
		vim.b.memos_memo_name = memo.name
		M.setup_buffer_for_editing()
	end
	if config.window and config.window.enable_float then
		local current_win = vim.api.nvim_get_current_win()
		local ok, is_memos_window = pcall(vim.api.nvim_win_get_var, current_win, "memos_window")
		if ok and is_memos_window == true then
			last_float_buf_id = vim.api.nvim_get_current_buf()
		end
	end
end

function M.check_and_auto_save()
	if vim.b.memos_original_content == nil then
		return
	end
	local current_content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
	if vim.b.memos_original_content ~= current_content then
		M.save_or_create_dispatcher()
	end
end

function M.save_or_create_dispatcher()
	local bufnr_to_save = vim.api.nvim_get_current_buf()
	if vim.b[bufnr_to_save].memos_save_inflight then
		vim.b[bufnr_to_save].memos_save_pending = true
		return
	end
	vim.b[bufnr_to_save].memos_save_inflight = true
	local memo_name = vim.b.memos_memo_name
	local content = table.concat(vim.api.nvim_buf_get_lines(bufnr_to_save, 0, -1, false), "\n")

	if content == "" then
		vim.notify("Memo is empty, not sending.", vim.log.levels.WARN)
		vim.b[bufnr_to_save].memos_save_inflight = false
		return
	end

	local function finalize_save()
		if not vim.api.nvim_buf_is_valid(bufnr_to_save) then
			return
		end
		vim.b[bufnr_to_save].memos_save_inflight = false
		if vim.b[bufnr_to_save].memos_save_pending then
			vim.b[bufnr_to_save].memos_save_pending = false
			local current_content = table.concat(vim.api.nvim_buf_get_lines(bufnr_to_save, 0, -1, false), "\n")
			if vim.b[bufnr_to_save].memos_original_content ~= current_content then
				vim.schedule(function()
					if vim.api.nvim_buf_is_valid(bufnr_to_save) then
						M.save_or_create_dispatcher()
					end
				end)
			end
		end
	end

	if memo_name then
		-- 更新逻辑 (保持不变，工作正常)
		api.update_memo(memo_name, content, function(success)
			if success then
				vim.schedule(function()
					vim.notify("✅ Memo updated successfully!")
					if vim.api.nvim_buf_is_valid(bufnr_to_save) then
						vim.b[bufnr_to_save].memos_original_content = content
						vim.bo[bufnr_to_save].modified = false
					end
					finalize_save()
				end)
				M.refresh_list_silently()
			else
				vim.schedule(function()
					finalize_save()
				end)
			end
		end)
	else
		api.create_memo(content, function(new_memo)
			if new_memo and new_memo.name then
				vim.schedule(function()
					vim.notify("✅ Memo created successfully!")
					if vim.api.nvim_buf_is_valid(bufnr_to_save) then
						vim.b[bufnr_to_save].memos_memo_name = new_memo.name
						vim.b[bufnr_to_save].memos_original_content = content
						vim.bo[bufnr_to_save].modified = false
					end
					M.show_memos_list(current_filter)
					-- 立即重新打开刚刚创建的 memo，进入编辑模式
					vim.schedule(function()
						M.open_memo_for_edit(new_memo, "enew")
					end)
					finalize_save()
				end)
			else
				vim.schedule(function()
					vim.notify("❌ Failed to create memo.", vim.log.levels.ERROR)
					finalize_save()
				end)
			end
		end)
	end
end

function M.refresh_list_silently()
	if not current_user or not current_user.name then
		return
	end
	api.list_memos(current_user.name, current_filter, config.page_size, nil, current_order_by, current_state, function(data)
		M.render_memos(data, false)
	end)
end

function M.create_memo_in_buffer()
	local used_float = false
	if config.window and config.window.enable_float then
		local float_win = find_memos_float_window()
		if float_win then
			vim.api.nvim_set_current_win(float_win)
			vim.cmd("enew")
			used_float = true
		else
			local new_buf = vim.api.nvim_create_buf(false, true)
			create_float_window(new_buf)
			vim.api.nvim_set_current_buf(new_buf)
			used_float = true
		end
	end
	if not used_float then
		vim.cmd("enew")
	end
	vim.b.memos_memo_name = nil
	-- 使用一个带时间戳的、独一无二的临时名字，防止冲突
	vim.api.nvim_buf_set_name(0, "memos/new_memo_" .. vim.fn.strftime("%s"))
	M.setup_buffer_for_editing()
	if config.window and config.window.enable_float then
		local current_win = vim.api.nvim_get_current_win()
		local ok, is_memos_window = pcall(vim.api.nvim_win_get_var, current_win, "memos_window")
		if ok and is_memos_window == true then
			last_float_buf_id = vim.api.nvim_get_current_buf()
		end
	end
end

function M.create_memo_from_content(content)
	vim.cmd("enew")
	vim.b.memos_memo_name = nil
	vim.api.nvim_buf_set_name(0, "memos/new_memo_" .. vim.fn.strftime("%s"))
	vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(content or "", "\n"))
	M.setup_buffer_for_editing()
end

-- 【新增】创建居中浮动窗口的辅助函数
create_float_window = function(buf)
	local width = math.floor(vim.o.columns * (config.window.width or 0.8))
	local height = math.floor(vim.o.lines * (config.window.height or 0.8))

	-- 计算居中位置
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local opts = {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = config.window.border or "rounded",
		title = " Memos ",
		title_pos = "center",
	}

	local win = vim.api.nvim_open_win(buf, true, opts)
	-- 关键：标记这个窗口是 Memos 的专用窗口
	vim.api.nvim_win_set_var(win, "memos_window", true)
	last_float_buf_id = buf
	return win
end

local function get_sort_presets()
	local presets = config.list_sort_presets
	if type(presets) ~= "table" or #presets == 0 then
		return { config.list_sort_default }
	end
	return presets
end

local function resolve_sort_index(order_by)
	local presets = get_sort_presets()
	for i, preset in ipairs(presets) do
		if preset == order_by then
			return i
		end
	end
	return 1
end

local function prompt_select_sort()
	local cap = get_capabilities()
	if cap and not cap.supports_sort then
		vim.notify("Sorting is not supported by this Memos API version.", vim.log.levels.WARN)
		return
	end
	local presets = get_sort_presets()
	if #presets == 0 then
		return
	end
	local items = {}
	for _, preset in ipairs(presets) do
		table.insert(items, { value = preset })
	end
	local default_value = current_order_by or config.list_sort_default
	vim.schedule(function()
		vim.ui.select(items, {
			prompt = "Select sort order:",
			format_item = function(item)
				return item.value
			end,
		}, function(choice)
			if not choice then
				return
			end
			current_order_by = choice.value
			current_sort_index = resolve_sort_index(current_order_by)
			current_page_token = nil
			vim.notify("Sort: " .. tostring(current_order_by))
			M.show_memos_list(current_filter, { force_refresh = true, reason = "sort" })
		end)
	end)
end

function M.cycle_sort()
	prompt_select_sort()
end

function M.toggle_state()
	local cap = get_capabilities()
	if cap and not cap.supports_state then
		vim.notify("State filtering is not supported by this Memos API version.", vim.log.levels.WARN)
		return
	end
	if current_state == "ARCHIVED" then
		current_state = "NORMAL"
	else
		current_state = "ARCHIVED"
	end
	current_page_token = nil
	vim.notify("State: " .. tostring(current_state))
	M.show_memos_list(current_filter, { force_refresh = true, reason = "state" })
end

local function render_cached_list()
	M.render_memos({
		memos = memos_cache,
		nextPageToken = current_page_token or "",
	}, false)
end

function M.toggle_memos_list()
	if config.window and config.window.enable_float then
		local existing = find_memos_float_window()
		if existing then
			pcall(vim.api.nvim_win_close, existing, true)
			return
		end
		if last_float_buf_id and vim.api.nvim_buf_is_valid(last_float_buf_id) then
			create_float_window(last_float_buf_id)
			return
		end
	end
	if not (config.window and config.window.enable_float) then
		if buf_id and vim.api.nvim_buf_is_valid(buf_id) then
			local win_id = vim.fn.bufwinid(buf_id)
			if win_id ~= -1 then
				pcall(vim.api.nvim_win_close, win_id, true)
				return
			end
		end
	end
	M.show_memos_list(nil, { force_refresh = false, reason = "toggle" })
end

function M.show_memos_list(filter, opts)
	opts = opts or {}
	local new_filter = filter
	local filter_changed = false
	if new_filter == nil then
		new_filter = current_filter
	end
	if current_filter ~= new_filter then
		filter_changed = true
	end
	current_filter = new_filter
	local cap = get_capabilities()
	local supports_sort = cap and cap.supports_sort
	local supports_state = cap and cap.supports_state
	if not current_order_by or current_order_by == "" then
		current_order_by = config.list_sort_default
	end
	current_sort_index = resolve_sort_index(current_order_by)
	if not current_state or current_state == "" then
		current_state = config.list_state_default or "NORMAL"
	end

	-- Ensure list buffer exists.
	if buf_id and vim.api.nvim_buf_is_valid(buf_id) then
		-- keep existing
	else
		buf_id = vim.api.nvim_create_buf(false, true) -- 改为 false, true (unlisted, scratch)
		vim.api.nvim_buf_set_name(buf_id, "MemosList")
		vim.bo[buf_id].buftype = "nofile"
		vim.bo[buf_id].swapfile = false
		vim.bo[buf_id].filetype = "memos_list"
		vim.bo[buf_id].modifiable = false
		vim.bo[buf_id].buflisted = false
		vim.bo[buf_id].bufhidden = "hide"
	end

	-- Focus existing window if buffer is already visible.
	local win_id = vim.fn.bufwinid(buf_id)
	if win_id ~= -1 then
		vim.api.nvim_set_current_win(win_id)
	else
		if config.window and config.window.enable_float then
			local found_win = find_memos_float_window()
			if found_win then
				vim.api.nvim_set_current_win(found_win)
				vim.api.nvim_set_current_buf(buf_id)
				last_float_buf_id = buf_id
			else
				create_float_window(buf_id)
			end
		else
			vim.api.nvim_set_current_buf(buf_id)
		end
	end
	if config.window and config.window.enable_float then
		local current_win = vim.api.nvim_get_current_win()
		local ok, is_memos_window = pcall(vim.api.nvim_win_get_var, current_win, "memos_window")
		if ok and is_memos_window == true then
			last_float_buf_id = buf_id
		end
	end

	if memos_cache and #memos_cache > 0 then
		render_cached_list()
	end

	local need_fetch = false
	if opts.force_refresh then
		need_fetch = true
	elseif filter_changed then
		need_fetch = true
	elseif not memos_cache or #memos_cache == 0 then
		need_fetch = true
	end

	if need_fetch then
		vim.schedule(function()
			vim.notify("Getting user info...")
		end)
		api.get_current_user(function(user)
			if user and user.name then
				current_user = user
				vim.schedule(function()
					vim.notify("Fetching memos for " .. user.name .. "...")
				end)
				api.list_memos(user.name, current_filter, config.page_size, nil, current_order_by, current_state, function(data)
					M.render_memos(data, false)
				end)
			else
				vim.schedule(function()
					vim.notify("Could not get user, aborting fetch.", vim.log.levels.ERROR)
				end)
			end
		end)
	end

	-- 【修改】这个函数现在可以处理单个按键（字符串）或多个按键（table）
	local function set_keymap(keys, command)
		if not keys then
			return
		end

		if type(keys) == "table" then
			-- 如果是 table，就为里面的每个按键都设置映射
			for _, key in ipairs(keys) do
				if key and key ~= "" then
					vim.api.nvim_buf_set_keymap(buf_id, "n", key, command, { noremap = true, silent = true })
				end
			end
		else
			-- 如果只是字符串，就按原来的方式设置
			if keys and keys ~= "" then
				vim.api.nvim_buf_set_keymap(buf_id, "n", keys, command, { noremap = true, silent = true })
			end
		end
	end

	if config.keymaps and config.keymaps.list and not vim.b[buf_id].memos_list_keymaps then
		local list_keymaps = config.keymaps.list
		set_keymap(list_keymaps.edit_memo, '<Cmd>lua require("memos.ui").edit_selected_memo()<CR>')
		set_keymap(list_keymaps.vsplit_edit_memo, '<Cmd>lua require("memos.ui").edit_selected_memo_in_vsplit()<CR>')
		set_keymap(list_keymaps.edit_metadata, '<Cmd>lua require("memos.ui").edit_selected_memo_metadata()<CR>')
		set_keymap(list_keymaps.quit, '<Cmd>lua require("memos.ui").quit_memos_list()<CR>')
		set_keymap(list_keymaps.search_memos, '<Cmd>lua require("memos.ui").search_memos()<CR>')
		set_keymap(list_keymaps.search_fuzzy, '<Cmd>lua require("memos.ui").search_memos_fuzzy()<CR>')
		set_keymap(
			list_keymaps.refresh_list,
			'<Cmd>lua require("memos.ui").show_memos_list(nil, { force_refresh = true })<CR>'
		)
		set_keymap(list_keymaps.next_page, '<Cmd>lua require("memos.ui").load_next_page()<CR>')
		set_keymap(list_keymaps.add_memo, '<Cmd>lua require("memos.ui").create_memo_in_buffer()<CR>')
		set_keymap(list_keymaps.copy_memo_id, '<Cmd>lua require("memos.ui").copy_selected_memo_id()<CR>')
		set_keymap(list_keymaps.paste_memo, '<Cmd>lua require("memos.ui").paste_memo_from_clipboard()<CR>')
		set_keymap(list_keymaps.delete_memo, '<Cmd>lua require("memos.ui").confirm_delete_memo()<CR>')
		set_keymap(list_keymaps.delete_memo_visual, '<Cmd>lua require("memos.ui").confirm_delete_memo()<CR>')
		set_keymap(list_keymaps.toggle_sort, '<Cmd>lua require("memos.ui").cycle_sort()<CR>')
		set_keymap(list_keymaps.toggle_state, '<Cmd>lua require("memos.ui").toggle_state()<CR>')
		vim.b[buf_id].memos_list_keymaps = true
	end
end

function M.load_next_page()
	if not current_page_token or current_page_token == "" then
		vim.notify("No more pages to load.", vim.log.levels.INFO)
		return
	end
	if not current_user or not current_user.name then
		vim.notify("User info not available.", vim.log.levels.WARN)
		return
	end
	vim.schedule(function()
		vim.notify("Loading next page...")
	end)
	api.list_memos(
		current_user.name,
		current_filter,
		config.page_size,
		current_page_token,
		current_order_by,
		current_state,
		function(data)
		M.render_memos(data, true)
	end)
end

function M.edit_selected_memo()
	local line_num = vim.api.nvim_win_get_cursor(0)[1]
	local selected_memo = memos_cache[line_num]
	if selected_memo then
		M.open_memo_for_edit(selected_memo, "enew")
	end
end

function M.edit_selected_memo_in_vsplit()
	local line_num = vim.api.nvim_win_get_cursor(0)[1]
	local selected_memo = memos_cache[line_num]
	if selected_memo then
		local current_win = vim.api.nvim_get_current_win()
		local ok, is_memos_window = pcall(vim.api.nvim_win_get_var, current_win, "memos_window")
		if ok and is_memos_window == true then
			pcall(vim.api.nvim_win_close, current_win, true)
		end
		M.open_memo_for_edit(selected_memo, "vsplit | enew")
	end
end

function M.copy_selected_memo_id()
	local line_num = vim.api.nvim_win_get_cursor(0)[1]
	local selected_memo = memos_cache[line_num]
	if not selected_memo or not selected_memo.name or selected_memo.name == "" then
		vim.notify("Selected memo has no valid identifier.", vim.log.levels.WARN)
		return
	end

	local preview = (type(selected_memo.content) == "string" and selected_memo.content or ""):sub(1, 50)
	local choice = vim.fn.confirm("Copy this memo ID?\n[" .. preview .. "...]", "&Yes\n&No", 2)
	if choice ~= 1 then
		return
	end

	vim.fn.setreg("+", selected_memo.name)
	vim.notify("📋 Memo ID copied to clipboard.")
end

local function normalize_memo_name(raw)
	if type(raw) ~= "string" then
		return nil
	end
	local trimmed = vim.trim(raw)
	if trimmed == "" then
		return nil
	end
	if trimmed:match("^memos/") then
		return trimmed
	end
	if trimmed:match("^%d+$") then
		return "memos/" .. trimmed
	end
	return nil
end

function M.paste_memo_from_clipboard()
	local raw = vim.fn.getreg("+")
	local memo_name = normalize_memo_name(raw)
	if not memo_name then
		vim.notify("Clipboard does not contain a valid memo id.", vim.log.levels.WARN)
		return
	end

	api.get_memo(memo_name, function(memo, err)
		if not memo then
			vim.schedule(function()
				vim.notify("Failed to fetch memo: " .. tostring(err), vim.log.levels.ERROR)
			end)
			return
		end
		vim.schedule(function()
			M.create_memo_from_content(type(memo.content) == "string" and memo.content or "")
		end)
	end)
end

function M.confirm_delete_memo()
	local line_num = vim.api.nvim_win_get_cursor(0)[1]
	local selected_memo = memos_cache[line_num]
	if not selected_memo or not selected_memo.name or selected_memo.name == "" then
		return
	end
	local preview = (type(selected_memo.content) == "string" and selected_memo.content or ""):sub(1, 50)
	local choice = vim.fn.confirm("Delete this memo?\n[" .. preview .. "...]", "&Yes\n&No", 2)
	if choice == 1 then
		api.delete_memo(selected_memo.name, function(success)
			if success then
				vim.schedule(function()
					vim.notify("✅ Memo deleted.")
					M.show_memos_list(current_filter, { force_refresh = true, reason = "delete" })
				end)
			else
				vim.schedule(function()
					vim.notify("❌ Failed to delete memo.", vim.log.levels.ERROR)
				end)
			end
		end)
	end
end

function M.search_memos()
	local cap = get_capabilities()
	if cap and cap.search_mode == "simple" then
		vim.ui.input({
			prompt = "Search (text or #tag): ",
		}, function(input)
			M.show_memos_list(vim.trim(input or ""), { force_refresh = true })
		end)
		return
	end
	local function looks_like_cel(expr)
		if expr:find("content%.contains%(") then
			return true
		end
		if expr:find(" in tags") or expr:find("tags") then
			return true
		end
		if expr:find("&&") or expr:find("||") then
			return true
		end
		if expr:find("==") or expr:find("~=") or expr:find(">=") or expr:find("<=") then
			return true
		end
		if expr:find("%(") or expr:find("%)") then
			return true
		end
		if expr:find('".+"') and (expr:find("&&") or expr:find("||") or expr:find(" in ")) then
			return true
		end
		return false
	end

	local function build_filter_from_input(raw)
		local input = vim.trim(raw or "")
		if input == "" then
			return ""
		end
		if looks_like_cel(input) then
			return input
		end

		local clauses = {}
		local remaining = input

		for tag in input:gmatch("#([%w_/%-]+)") do
			local escaped = vim.fn.escape(tag, '"')
			table.insert(clauses, string.format('"%s" in tags', escaped))
		end

		remaining = remaining:gsub("#[%w_/%-]+", " ")
		remaining = vim.trim(remaining)
		if remaining ~= "" then
			local tokens = {}
			local rest = remaining
			while true do
				local start_q, end_q = rest:find('"(.-)"')
				if not start_q then
					break
				end
				local before = vim.trim(rest:sub(1, start_q - 1))
				if before ~= "" then
					for _, word in ipairs(vim.split(before, "%s+")) do
						if word ~= "" then
							table.insert(tokens, word)
						end
					end
				end
				local quoted = rest:sub(start_q + 1, end_q - 1)
				if quoted ~= "" then
					table.insert(tokens, quoted)
				end
				rest = rest:sub(end_q + 1)
			end
			rest = vim.trim(rest)
			if rest ~= "" then
				for _, word in ipairs(vim.split(rest, "%s+")) do
					if word ~= "" then
						table.insert(tokens, word)
					end
				end
			end
			for _, token in ipairs(tokens) do
				local escaped = vim.fn.escape(token, '"')
				table.insert(clauses, string.format('content.contains("%s")', escaped))
			end
		end
		return table.concat(clauses, " && ")
	end

	vim.ui.input({
		prompt = 'Search (text or CEL): foo bar | "foo bar" | #area/work #todo | content.contains("foo") && "work" in tags: ',
	}, function(input)
		M.show_memos_list(build_filter_from_input(input), { force_refresh = true })
	end)
end

function M.search_memos_fuzzy()
	local cap = get_capabilities()
	if cap and cap.search_mode == "simple" then
		vim.notify("Fuzzy search requires CEL (v0.25/v0.26).", vim.log.levels.WARN)
		return
	end

	local function tokenize(input)
		local tokens = {}
		local i = 1
		local len = #input
		while i <= len do
			local ch = input:sub(i, i)
			if ch:match("%s") then
				i = i + 1
			elseif ch == "(" then
				table.insert(tokens, { type = "LPAREN" })
				i = i + 1
			elseif ch == ")" then
				table.insert(tokens, { type = "RPAREN" })
				i = i + 1
			elseif ch == "," then
				table.insert(tokens, { type = "OR" })
				i = i + 1
			elseif ch == "&" and input:sub(i, i + 1) == "&&" then
				table.insert(tokens, { type = "AND" })
				i = i + 2
			elseif ch == "|" and input:sub(i, i + 1) == "||" then
				table.insert(tokens, { type = "OR" })
				i = i + 2
			elseif ch == '"' then
				local j = i + 1
				while j <= len and input:sub(j, j) ~= '"' do
					j = j + 1
				end
				if j > len then
					return nil, "Unterminated string."
				end
				local value = input:sub(i + 1, j - 1)
				table.insert(tokens, { type = "TERM", kind = "content", value = value })
				i = j + 1
			elseif ch == "#" then
				local j = i + 1
				while j <= len and input:sub(j, j):match("[%w_/%-]") do
					j = j + 1
				end
				local value = input:sub(i + 1, j - 1)
				if value == "" then
					return nil, "Invalid tag."
				end
				table.insert(tokens, { type = "TERM", kind = "tag", value = value })
				i = j
			else
				local j = i
				while j <= len do
					local c = input:sub(j, j)
					if c:match("%s") or c == "(" or c == ")" or c == "," then
						break
					end
					if c == "&" and input:sub(j, j + 1) == "&&" then
						break
					end
					if c == "|" and input:sub(j, j + 1) == "||" then
						break
					end
					j = j + 1
				end
				local value = input:sub(i, j - 1)
				if value ~= "" then
					table.insert(tokens, { type = "TERM", kind = "content", value = value })
				end
				i = j
			end
		end
		return tokens, nil
	end

	local function insert_implicit_and(tokens)
		local out = {}
		local function is_term_like(tok)
			return tok.type == "TERM" or tok.type == "RPAREN"
		end
		local function is_start_like(tok)
			return tok.type == "TERM" or tok.type == "LPAREN"
		end
		for idx, tok in ipairs(tokens) do
			local prev = out[#out]
			if prev and is_term_like(prev) and is_start_like(tok) then
				table.insert(out, { type = "AND" })
			end
			table.insert(out, tok)
		end
		return out
	end

	local function term_to_cel(term)
		local escaped = vim.fn.escape(term.value, '"')
		if term.kind == "tag" then
			return string.format(
				'("%s" in tags || tags.exists(t, t.startsWith("%s/")) || tags.exists(t, t.endsWith("/%s")))',
				escaped,
				escaped,
				escaped
			)
		end
		return string.format('content.contains("%s")', escaped)
	end

	local function parse(tokens)
		local idx = 1
		local parse_or

		local function parse_primary()
			local tok = tokens[idx]
			if not tok then
				return nil, "Unexpected end of input."
			end
			if tok.type == "TERM" then
				idx = idx + 1
				return term_to_cel(tok)
			end
			if tok.type == "LPAREN" then
				idx = idx + 1
				local expr, err = parse_or()
				if not expr then
					return nil, err
				end
				if not tokens[idx] or tokens[idx].type ~= "RPAREN" then
					return nil, "Missing ')'."
				end
				idx = idx + 1
				return "(" .. expr .. ")"
			end
			return nil, "Unexpected token."
		end

		local function parse_and()
			local left, err = parse_primary()
			if not left then
				return nil, err
			end
			while tokens[idx] and tokens[idx].type == "AND" do
				idx = idx + 1
				local right, err2 = parse_primary()
				if not right then
					return nil, err2
				end
				left = left .. " && " .. right
			end
			return left
		end

		parse_or = function()
			local left, err = parse_and()
			if not left then
				return nil, err
			end
			while tokens[idx] and tokens[idx].type == "OR" do
				idx = idx + 1
				local right, err2 = parse_and()
				if not right then
					return nil, err2
				end
				left = left .. " || " .. right
			end
			return left
		end

		local expr, err = parse_or()
		if not expr then
			return nil, err
		end
		if tokens[idx] then
			return nil, "Unexpected token."
		end
		return expr
	end

	vim.ui.input({
		prompt = 'Fuzzy search (pseudo-CEL): "foo bar" #tag, #tag2',
	}, function(input)
		local raw = vim.trim(input or "")
		if raw == "" then
			M.show_memos_list("", { force_refresh = true })
			return
		end
		local tokens, err = tokenize(raw)
		if not tokens then
			vim.notify("Fuzzy search parse error: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		tokens = insert_implicit_and(tokens)
		local expr, err2 = parse(tokens)
		if not expr then
			vim.notify("Fuzzy search parse error: " .. tostring(err2), vim.log.levels.ERROR)
			return
		end
		M.show_memos_list(expr, { force_refresh = true })
	end)
end

local function prompt_select_field(capabilities, callback)
	local items = {}
	table.insert(items, { key = "visibility", label = "Visibility" })
	table.insert(items, { key = "pinned", label = "Pinned" })
	if not (capabilities and capabilities.mode == "v0.21") then
		table.insert(items, { key = "displayTime", label = "Display time" })
	end
	table.insert(items, { key = "createTime", label = "Create time" })
	table.insert(items, { key = "relations", label = "Relations" })
	table.insert(items, { key = "state", label = "State" })
	vim.schedule(function()
		vim.ui.select(items, {
			prompt = "Edit memo metadata:",
			format_item = function(item)
				return item.label
			end,
		}, function(choice)
			if not choice then
				callback(nil)
				return
			end
			callback(choice.key)
		end)
	end)
end

local function prompt_select_enum(prompt, choices, callback)
	local items = {}
	for _, value in ipairs(choices) do
		table.insert(items, { value = value })
	end
	vim.schedule(function()
		vim.ui.select(items, {
			prompt = prompt,
			format_item = function(item)
				return item.value
			end,
		}, function(choice)
			if not choice then
				callback(nil)
				return
			end
			callback(choice.value)
		end)
	end)
end

local function prompt_select_boolean(prompt, callback)
	local items = { { value = true, label = "true" }, { value = false, label = "false" } }
	vim.schedule(function()
		vim.ui.select(items, {
			prompt = prompt,
			format_item = function(item)
				return item.label
			end,
		}, function(choice)
			if not choice then
				callback(nil)
				return
			end
			callback(choice.value)
		end)
	end)
end

local function normalize_iso_time(input)
	local value = vim.trim(input or "")
	if value == "" then
		return value
	end
	if value:match("Z$") or value:match("[%+%-]%d%d:%d%d$") then
		return value
	end
	if value:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d$") then
		return value .. "Z"
	end
	return value
end

local function iso_to_unix_time(value)
	local normalized = normalize_iso_time(value or "")
	if normalized == "" then
		return nil
	end
	local ok, ts = pcall(vim.fn.strptime, "%Y-%m-%dT%H:%M:%SZ", normalized)
	if not ok then
		return nil
	end
	local num = tonumber(ts)
	if not num or num <= 0 then
		return nil
	end
	return num
end

local function prompt_iso_time(prompt, default_value, callback)
	vim.schedule(function()
		vim.ui.input({
			prompt = prompt .. " (ISO 8601, e.g. 2025-02-07T12:34:56Z): ",
			default = default_value or "",
		}, function(input)
			if not input or input == "" then
				callback(nil)
				return
			end
			callback(normalize_iso_time(input))
		end)
	end)
end

local function is_time_field(field)
	return field == "displayTime" or field == "createTime"
end

local function normalize_memo_name(raw)
	if type(raw) ~= "string" then
		return nil
	end
	local trimmed = vim.trim(raw)
	if trimmed == "" then
		return nil
	end
	if trimmed:match("^memos/") then
		return trimmed
	end
	if trimmed:match("^%d+$") then
		return "memos/" .. trimmed
	end
	return nil
end

local function get_default_relation_memo_name(memo)
	local relations = memo and memo.relations or nil
	if type(relations) ~= "table" or #relations == 0 then
		return ""
	end
	local first = relations[1]
	local related = first and first.relatedMemo or nil
	if related and related.name and related.name ~= "" then
		return related.name
	end
	return ""
end

local function get_default_relation_type(memo)
	local relations = memo and memo.relations or nil
	if type(relations) ~= "table" or #relations == 0 then
		return "TYPE_UNSPECIFIED"
	end
	local first = relations[1]
	local rel_type = first and first.type or nil
	if type(rel_type) == "string" and rel_type ~= "" then
		return rel_type
	end
	return "TYPE_UNSPECIFIED"
end

local function relation_name_from_id(id)
	if not id then
		return ""
	end
	return "memos/" .. tostring(id)
end

local function get_default_relation_name_v021(relations)
	if type(relations) ~= "table" or #relations == 0 then
		return ""
	end
	local first = relations[1]
	local related = first and (first.relatedMemoID or first.relatedMemoId)
	if related then
		return relation_name_from_id(related)
	end
	return ""
end

local function get_default_relation_type_v021(relations)
	if type(relations) ~= "table" or #relations == 0 then
		return "REFERENCE"
	end
	local first = relations[1]
	local rel_type = first and first.type or nil
	if type(rel_type) == "string" and rel_type ~= "" then
		return rel_type
	end
	return "REFERENCE"
end

local function to_snake_mask(field)
	if field == "displayTime" then
		return "display_time"
	end
	if field == "createTime" then
		return "create_time"
	end
	return field
end

local function notify_metadata_success()
	vim.schedule(function()
		vim.notify("✅ Memo metadata updated.")
		M.refresh_list_silently()
	end)
end

local function notify_metadata_unchanged()
	vim.schedule(function()
		vim.notify("⚠️ Memo metadata was not applied by server.", vim.log.levels.WARN)
		M.refresh_list_silently()
	end)
end

local function edit_relations_v021(memo)
	if not memo or not memo.name or memo.name == "" then
		return
	end
	api.list_memo_relations(memo.name, function(relations, err)
		if not relations then
			vim.schedule(function()
				vim.notify("Failed to fetch memo relations: " .. tostring(err), vim.log.levels.ERROR)
			end)
			return
		end
		vim.schedule(function()
			local clipboard_name = normalize_memo_name(vim.fn.getreg("+") or "")
			local default_relation = clipboard_name or get_default_relation_name_v021(relations)
			vim.ui.input({
				prompt = "Related memo id (memos/<id>): ",
				default = default_relation,
			}, function(input)
				if input == nil then
					return
				end
				local normalized = normalize_memo_name(input or "")
				if not normalized or normalized == "" then
					local choice = vim.fn.confirm("Clear all relations?", "&Yes\n&No", 2)
					if choice ~= 1 then
						return
					end
					if type(relations) ~= "table" or #relations == 0 then
						vim.notify("No relations to clear.", vim.log.levels.INFO)
						return
					end
					local pending = #relations
					local failed = false
					for _, rel in ipairs(relations) do
						local related_id = rel and (rel.relatedMemoID or rel.relatedMemoId)
						local rel_type = rel and rel.type or "REFERENCE"
						if related_id then
							api.delete_memo_relation(memo.name, relation_name_from_id(related_id), rel_type, function(ok, _)
								if not ok then
									failed = true
								end
								pending = pending - 1
								if pending == 0 then
									vim.schedule(function()
										if failed then
											vim.notify("❌ Failed to clear some relations.", vim.log.levels.ERROR)
										else
											vim.notify("✅ Memo relations cleared.")
										end
										M.refresh_list_silently()
									end)
								end
							end)
						else
							pending = pending - 1
						end
					end
					return
				end

				local default_type = get_default_relation_type_v021(relations)
				vim.ui.input({
					prompt = "Relation type: ",
					default = default_type,
				}, function(type_input)
					if not type_input or type_input == "" then
						return
					end
					api.create_memo_relation(memo.name, normalized, type_input, function(ok, relation_err)
						vim.schedule(function()
							if ok then
								vim.notify("✅ Memo relations updated.")
							else
								vim.notify("❌ Failed to update relations: " .. tostring(relation_err), vim.log.levels.ERROR)
							end
							M.refresh_list_silently()
						end)
					end)
				end)
			end)
		end)
	end)
end

local function update_metadata_field(memo, field, value)
	if not memo or not memo.name or memo.name == "" then
		return
	end
	local cap = get_capabilities()
	if cap and cap.mode == "v0.21" then
		if field == "relations" then
			edit_relations_v021(memo)
			return
		end
		local fields = {
			content = memo.content or "",
		}
		local update_mask = field
		if field == "createTime" then
			local ts = iso_to_unix_time(value)
			if not ts then
				vim.notify("Invalid time format for create time.", vim.log.levels.ERROR)
				return
			end
			fields.createdTs = ts
			update_mask = "createdTs"
		elseif field == "state" then
			fields.rowStatus = value
			update_mask = "rowStatus"
		elseif field == "visibility" then
			fields.visibility = value
		elseif field == "pinned" then
			fields.pinned = value
		else
			vim.notify("This metadata field is not supported in v0.21.", vim.log.levels.WARN)
			return
		end
		api.update_memo_metadata(memo.name, fields, update_mask, function(success)
			if success then
				notify_metadata_success()
			end
		end)
		return
	end
	local fields = {
		content = memo.content or "",
	}
	fields[field] = value

	if not is_time_field(field) then
		api.update_memo_metadata(memo.name, fields, field, function(success)
			if success then
				notify_metadata_success()
			end
		end)
		return
	end

	local function attempt(update_mask, tried_retry)
		api.update_memo_metadata(memo.name, fields, update_mask, function(success)
			if not success then
				return
			end
			api.get_memo(memo.name, function(updated)
				if not updated then
					return
				end
				if updated[field] == value then
					notify_metadata_success()
					return
				end
				if not tried_retry then
					local snake = to_snake_mask(field)
					if snake ~= update_mask then
						attempt(snake, true)
						return
					end
				end
				notify_metadata_unchanged()
			end)
		end)
	end

	attempt(field, false)
end

local function edit_metadata_flow(memo)
	if not memo or not memo.name or memo.name == "" then
		return
	end
	local cap = get_capabilities()
	prompt_select_field(cap, function(field)
		if not field then
			return
		end
		if field == "visibility" then
			prompt_select_enum("Visibility", { "PRIVATE", "PROTECTED", "PUBLIC" }, function(value)
				if value then
					update_metadata_field(memo, "visibility", value)
				end
			end)
			return
		end
		if field == "pinned" then
			prompt_select_boolean("Pinned", function(value)
				if value ~= nil then
					update_metadata_field(memo, "pinned", value)
				end
			end)
			return
		end
		if field == "displayTime" then
			prompt_iso_time("Display time", memo.displayTime, function(value)
				if value then
					update_metadata_field(memo, "displayTime", value)
				end
			end)
			return
		end
		if field == "createTime" then
			prompt_iso_time("Create time", memo.createTime, function(value)
				if value then
					update_metadata_field(memo, "createTime", value)
				end
			end)
			return
		end
		if field == "relations" then
			if cap and cap.mode == "v0.21" then
				edit_relations_v021(memo)
				return
			end
			local clipboard_name = normalize_memo_name(vim.fn.getreg("+") or "")
			local default_relation = clipboard_name or get_default_relation_memo_name(memo)
			vim.schedule(function()
				vim.ui.input({
					prompt = "Related memo id (memos/<id>): ",
					default = default_relation,
				}, function(input)
					if input == nil then
						return
					end
					local normalized = normalize_memo_name(input or "")
					if not normalized or normalized == "" then
						local choice = vim.fn.confirm("Clear all relations?", "&Yes\n&No", 2)
						if choice ~= 1 then
							return
						end
						local fields = {
							content = memo.content or "",
							relations = {},
						}
						api.update_memo_metadata(memo.name, fields, "relations", function(success)
							if success then
								vim.schedule(function()
									vim.notify("✅ Memo relations cleared.")
									M.refresh_list_silently()
								end)
							end
						end)
						return
					end

					local default_type = get_default_relation_type(memo)
					vim.ui.input({
						prompt = "Relation type: ",
						default = default_type,
					}, function(type_input)
						if not type_input or type_input == "" then
							return
						end
						local fields = {
							content = memo.content or "",
							relations = {
								{
									memo = { name = memo.name },
									relatedMemo = { name = normalized },
									type = type_input,
								},
							},
						}
						api.update_memo_metadata(memo.name, fields, "relations", function(success)
							if success then
								vim.schedule(function()
									vim.notify("✅ Memo relations updated.")
									M.refresh_list_silently()
								end)
							end
						end)
					end)
				end)
			end)
			return
		end
		if field == "state" then
			prompt_select_enum("State", { "NORMAL", "ARCHIVED" }, function(value)
				if value then
					update_metadata_field(memo, "state", value)
				end
			end)
			return
		end
	end)
end

function M.edit_selected_memo_metadata()
	local line_num = vim.api.nvim_win_get_cursor(0)[1]
	local selected_memo = memos_cache[line_num]
	if not selected_memo or not selected_memo.name or selected_memo.name == "" then
		vim.notify("No memo selected.", vim.log.levels.WARN)
		return
	end
	local cap = get_capabilities()
	if cap and cap.mode == "v0.21" then
		edit_metadata_flow(selected_memo)
		return
	end
	api.get_memo(selected_memo.name, function(memo, err)
		if not memo then
			vim.schedule(function()
				vim.notify("Failed to load memo metadata: " .. tostring(err), vim.log.levels.ERROR)
			end)
			return
		end
		edit_metadata_flow(memo)
	end)
end

function M.modify_current_memo_metadata()
	local memo_name = vim.b.memos_memo_name
	if memo_name and memo_name ~= "" then
		api.get_memo(memo_name, function(memo, err)
			if not memo then
				vim.schedule(function()
					vim.notify("Failed to load memo metadata: " .. tostring(err), vim.log.levels.ERROR)
				end)
				return
			end
			edit_metadata_flow(memo)
		end)
		return
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	if content == "" then
		vim.notify("Memo is empty, not sending.", vim.log.levels.WARN)
		return
	end

	api.create_memo(content, function(new_memo)
		if not new_memo or not new_memo.name then
			vim.schedule(function()
				vim.notify("❌ Failed to create memo.", vim.log.levels.ERROR)
			end)
			return
		end
		local cap = get_capabilities()
		vim.schedule(function()
			if vim.api.nvim_buf_is_valid(bufnr) then
				vim.b[bufnr].memos_memo_name = new_memo.name
				vim.b[bufnr].memos_original_content = content
				vim.bo[bufnr].modified = false
			end
		end)
		if cap and cap.mode == "v0.21" then
			edit_metadata_flow(new_memo)
			return
		end
		api.get_memo(new_memo.name, function(memo, err)
			if not memo then
				vim.schedule(function()
					vim.notify("Failed to load memo metadata: " .. tostring(err), vim.log.levels.ERROR)
				end)
				return
			end
			edit_metadata_flow(memo)
		end)
	end)
end

return M
