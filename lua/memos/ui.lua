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
local selected_memos = {}
local list_items = {}
local list_line_count = 0
local relations_cache = {}
local relations_expanded = {}
local relation_title_cache = {}
local relation_title_inflight = {}
local extract_memo_title
local clip_title
local ensure_relations_loaded
local invalidate_relations_cache

local function is_selected(memo)
	return memo and memo.name and selected_memos[memo.name] == true
end

local function toggle_selected(memo)
	if not memo or not memo.name then
		return false
	end
	if selected_memos[memo.name] then
		selected_memos[memo.name] = nil
		return false
	end
	selected_memos[memo.name] = true
	return true
end

local function clear_selection()
	selected_memos = {}
end

local function reset_relations_state()
	relations_cache = {}
	relations_expanded = {}
	relation_title_cache = {}
	relation_title_inflight = {}
end

local function selected_list()
	local out = {}
	for _, memo in ipairs(memos_cache) do
		if memo and memo.name and selected_memos[memo.name] then
			table.insert(out, memo.name)
		end
	end
	return out
end

function M.on_account_switched()
	current_user = nil
	current_page_token = nil
	memos_cache = {}
	current_order_by = nil
	current_sort_index = nil
	current_state = nil
	clear_selection()
	reset_relations_state()

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
		list_items = {}
		list_line_count = 0
		local function add_line(text, item)
			table.insert(lines, text)
			list_line_count = list_line_count + 1
			if item then
				list_items[list_line_count] = item
			end
		end
		local incoming_map = {}
		local relations_mode = (config.list_relations_mode or "both"):lower()
		local show_out = relations_mode == "both" or relations_mode == "out"
		local show_in = relations_mode == "both" or relations_mode == "in"
		local show_any = show_out or show_in
		for idx, memo in ipairs(memos_cache) do
			local rel_cache = memo and memo.name and relations_cache[memo.name] or nil
			if rel_cache and rel_cache.status == "loaded" and rel_cache.source ~= "v1" and type(rel_cache.out_items) == "table" then
				for _, entry in ipairs(rel_cache.out_items) do
					if entry and entry.id then
						local bucket = incoming_map[entry.id] or {}
						table.insert(bucket, { memo_index = idx, type = entry.type or "TYPE_UNSPECIFIED" })
						incoming_map[entry.id] = bucket
					end
				end
			end
		end
		local k = config.keymaps.list
		if #memos_cache == 0 then
			local help = string.format(
				"No memos found. Press '%s' to refresh, '%s' to add, or '%s' to quit.",
				k.refresh_list,
				k.add_memo,
				k.quit
			)
			add_line(help, { kind = "empty" })
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
				local selected_marker = is_selected(memo) and "[x] " or "[ ] "
				local ref_suffix = ""
				local rel_cache = memo.name and relations_cache[memo.name] or nil
				local out_count = 0
				local in_count = 0
				local out_more = false
				local in_more = false
				if rel_cache and rel_cache.out_total ~= nil then
					out_count = rel_cache.out_total
					local out_trunc = tonumber(rel_cache.truncated_out) or 0
					local in_trunc = tonumber(rel_cache.truncated_in) or 0
					out_more = rel_cache.out_more == true or out_trunc > 0
					in_more = rel_cache.in_more == true or in_trunc > 0
					if rel_cache.source == "v1" then
						in_count = rel_cache.in_total or 0
					else
						local incoming = memo.name and incoming_map[memo.name] or nil
						in_count = incoming and #incoming or 0
					end
				else
					if type(memo.relations) == "table" then
						out_count = #memo.relations
					end
					local incoming = memo.name and incoming_map[memo.name] or nil
					in_count = incoming and #incoming or 0
				end
				if not show_out then
					out_count = 0
					out_more = false
				end
				if not show_in then
					in_count = 0
					in_more = false
				end
				if out_count > 0 or in_count > 0 or out_more or in_more then
					local out_mark = out_more and (tostring(out_count) .. "+") or tostring(out_count)
					local in_mark = in_more and (tostring(in_count) .. "+") or tostring(in_count)
					ref_suffix = string.format(" .. <\226\134\146%s><\226\134\144%s>", out_mark, in_mark)
				end
				add_line(
					string.format("%s%d. [%s] %s%s%s", selected_marker, i, display_time, badge_text, first_line, ref_suffix),
					{ kind = "memo", memo_index = i }
				)

				local expanded = relations_expanded[memo.name]
				if expanded == nil and show_any and config.list_relations_auto_expand then
					if out_count > 0 or in_count > 0 or out_more or in_more then
						relations_expanded[memo.name] = true
						expanded = true
					end
				end

				if expanded and show_any then
					local cache = relations_cache[memo.name]
					if not cache then
						ensure_relations_loaded(memo)
						add_line("   `-- (loading relations...)", { kind = "relation_status", parent_index = i })
					elseif cache.status == "error" then
						add_line("   `-- (failed to load relations)", { kind = "relation_status", parent_index = i })
					else
						if cache.source ~= "v1" then
							local incoming = memo.name and incoming_map[memo.name] or nil
							cache.in_items = {}
							cache.in_total = incoming and #incoming or 0
							cache.truncated_in = 0
							cache.in_more = false
							local in_limit = tonumber(config.list_relations_limit) or 20
							if incoming and #incoming > 0 then
								local total = #incoming
								local take = in_limit > 0 and math.min(in_limit, total) or total
								for idx = 1, take do
									local ref = incoming[idx]
									local ref_memo = ref and memos_cache[ref.memo_index] or nil
									local title = ref_memo and clip_title(extract_memo_title(ref_memo), config.metadata_title_max_len) or "(missing)"
									table.insert(cache.in_items, {
										id = ref_memo and ref_memo.name or "",
										title = title,
										type = ref.type or "REFERENCE",
									})
								end
								if in_limit > 0 and total > in_limit then
									cache.truncated_in = total - in_limit
								end
							end
						end

						local out_more = cache.out_more == true or (tonumber(cache.truncated_out) or 0) > 0
						local in_more = cache.in_more == true or (tonumber(cache.truncated_in) or 0) > 0
						local out_status = cache.out_status or cache.status
						local in_status = cache.in_status or cache.status
						local show_type = cache.source ~= "v1"

						local lines_added = 0
						local function add_simple_lines(direction, items, status, more, truncated)
							local arrow = direction == "out" and "\226\134\146" or "\226\134\144"
							if status == "error" then
								add_line(
									string.format("   %s (failed to load relations)", arrow),
									{ kind = "relation_status", parent_index = i }
								)
								lines_added = lines_added + 1
								return
							end
							if not items or #items == 0 then
								if status == "loading" then
									add_line(string.format("   %s (loading...)", arrow), {
										kind = "relation_status",
										parent_index = i,
									})
									lines_added = lines_added + 1
								end
								return
							end

							local unresolved = 0
							local visible = {}
							for _, entry in ipairs(items) do
								if entry.title == "(loading...)" then
									unresolved = unresolved + 1
								else
									table.insert(visible, entry)
								end
							end
							if #visible == 0 and unresolved > 0 then
								add_line(string.format("   %s (loading...)", arrow), {
									kind = "relation_status",
									parent_index = i,
								})
								lines_added = lines_added + 1
								return
							end

							local has_more = more or unresolved > 0
							for _, entry in ipairs(visible) do
								local title = entry.title or ""
								add_line(string.format("   %s %s", arrow, title), {
									kind = "relation",
									parent_index = i,
									related_name = entry.id,
									rel_type = entry.type,
									direction = direction,
								})
								lines_added = lines_added + 1
							end
							if unresolved > 0 then
								add_line(string.format("   %s (loading...)", arrow), {
									kind = "relation_status",
									parent_index = i,
								})
								lines_added = lines_added + 1
							end
							if truncated and truncated > 0 then
								add_line(string.format("   %s ... +%d more", arrow, truncated), {
									kind = "relation_truncated",
									parent_index = i,
									section = direction,
								})
								lines_added = lines_added + 1
							end
						end

						if show_out then
							add_simple_lines("out", cache.out_items, out_status, out_more, cache.truncated_out)
						end
						if show_in then
							add_simple_lines("in", cache.in_items, in_status, in_more, cache.truncated_in)
						end
					end
				end
			end
		end
		if current_page_token ~= "" then
			add_line("...", { kind = "load_more" })
			add_line(string.format("(Press '%s' to load more)", k.next_page), { kind = "load_more_hint" })
		end
		vim.api.nvim_buf_set_option(buf_id, "modifiable", true)
		vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, lines)
		vim.api.nvim_buf_set_option(buf_id, "modifiable", false)

		if show_any then
			for _, memo in ipairs(memos_cache) do
				ensure_relations_loaded(memo)
			end
		end
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

local function resolve_relation_title(related_name, callback)
	if not related_name or related_name == "" then
		callback(nil)
		return
	end
	local cached = relation_title_cache[related_name]
	if cached then
		callback(cached)
		return
	end
	if relation_title_inflight[related_name] then
		return
	end
	relation_title_inflight[related_name] = true
	api.get_memo(related_name, function(memo, err)
		relation_title_inflight[related_name] = nil
		local title = "(missing)"
		if memo then
			title = clip_title(extract_memo_title(memo), config.metadata_title_max_len)
		else
			if err then
				vim.schedule(function()
					vim.notify("Failed to load related memo: " .. tostring(err), vim.log.levels.WARN)
				end)
			end
		end
		relation_title_cache[related_name] = title
		callback(title)
	end)
end

local function build_relation_entries(relations, mode)
	local entries = {}
	if type(relations) ~= "table" then
		return entries
	end
	for _, rel in ipairs(relations) do
		if mode == "v0.21" then
			local related_id = rel and (rel.relatedMemoID or rel.relatedMemoId)
			local related_name = related_id and ("memos/" .. tostring(related_id)) or nil
			if related_name then
				table.insert(entries, {
					id = related_name,
					type = rel.type or "REFERENCE",
				})
			end
		else
			local related = rel and rel.relatedMemo or nil
			local related_name = related and (related.name or related.id) or nil
			if related_name then
				table.insert(entries, {
					id = related_name,
					type = rel.type or "TYPE_UNSPECIFIED",
				})
			end
		end
	end
	return entries
end

ensure_relations_loaded = function(memo)
	if not memo or not memo.name or memo.name == "" then
		return
	end
	local relations_mode = (config.list_relations_mode or "both"):lower()
	local show_out = relations_mode == "both" or relations_mode == "out"
	local show_in = relations_mode == "both" or relations_mode == "in"
	if not show_out and not show_in then
		return
	end
	local existing = relations_cache[memo.name]
	if existing and (existing.status == "loading" or existing.status == "loaded" or existing.status == "error") then
		return
	end

	relations_cache[memo.name] = {
		status = "loading",
		out_items = {},
		in_items = {},
		truncated_out = 0,
		truncated_in = 0,
		out_total = 0,
		in_total = 0,
		out_status = "loading",
		in_status = "loading",
		out_more = false,
		in_more = false,
		source = nil,
		has_more = false,
	}
	local cache = relations_cache[memo.name]
	local cap = get_capabilities()
	local mode = cap and cap.mode or "v0.26"

	local function update_cache()
		if cache.out_status == "error" and cache.in_status == "error" then
			cache.status = "error"
		elseif cache.out_status == "loading" or cache.in_status == "loading" then
			cache.status = "loading"
		else
			cache.status = "loaded"
		end
		relations_cache[memo.name] = cache
		render_cached_list()
	end

	local function handle_relations(relations)
		local entries = build_relation_entries(relations, mode)
		local total = #entries
		local limit = tonumber(config.list_relations_limit) or 20
		local truncated = 0
		if limit > 0 and #entries > limit then
			truncated = #entries - limit
			local sliced = {}
			for i = 1, limit do
				table.insert(sliced, entries[i])
			end
			entries = sliced
		end
		for _, entry in ipairs(entries) do
			local cached = relation_title_cache[entry.id]
			entry.title = cached or "(loading...)"
		end
		cache.status = "loaded"
		cache.out_items = entries
		cache.in_items = {}
		cache.truncated_out = truncated
		cache.truncated_in = 0
		cache.out_total = total
		cache.in_total = 0
		cache.out_status = "loaded"
		cache.in_status = "loaded"
		cache.out_more = truncated > 0
		cache.in_more = false
		cache.source = "legacy"
		cache.has_more = false
		update_cache()
		for _, entry in ipairs(entries) do
			if not relation_title_cache[entry.id] then
				resolve_relation_title(entry.id, function(title)
					if title then
						entry.title = title
						render_cached_list()
					end
				end)
			end
		end
	end

	local function handle_error(err)
		cache.status = "error"
		cache.out_items = {}
		cache.in_items = {}
		cache.truncated_out = 0
		cache.truncated_in = 0
		cache.out_total = 0
		cache.in_total = 0
		cache.out_status = "error"
		cache.in_status = "error"
		cache.out_more = false
		cache.in_more = false
		cache.error = err
		cache.source = "error"
		cache.has_more = false
		update_cache()
	end

	if mode == "v0.21" then
		if not show_out then
			cache.out_items = {}
			cache.in_items = {}
			cache.out_total = 0
			cache.in_total = 0
			cache.truncated_out = 0
			cache.truncated_in = 0
			cache.out_more = false
			cache.in_more = false
			cache.out_status = "loaded"
			cache.in_status = "loaded"
			cache.source = "legacy"
			update_cache()
			return
		end
		api.list_memo_relations(memo.name, function(relations, err)
			if not relations then
				handle_error(err)
				return
			end
			handle_relations(relations)
		end)
		return
	end

	cache.source = "v1"

	local function apply_out_from_memo(source_memo)
		if not show_out then
			cache.out_items = {}
			cache.out_total = 0
			cache.truncated_out = 0
			cache.out_more = false
			cache.out_status = "loaded"
			update_cache()
			return
		end
		local relations = type(source_memo.relations) == "table" and source_memo.relations or {}
		local entries = {}
		local total_out = 0
		for _, rel in ipairs(relations) do
			local memo_side = rel and rel.memo or nil
			if memo_side and memo_side.name and memo_side.name ~= memo.name then
				goto continue
			end
			local related = rel and rel.relatedMemo or nil
			local related_name = related and (related.name or related.id) or nil
			if not related_name then
				local related_id = rel and (rel.relatedMemoId or rel.relatedMemoID) or nil
				if related_id then
					related_name = "memos/" .. tostring(related_id)
				end
			end
			if related_name then
				total_out = total_out + 1
				local snippet = related and type(related.snippet) == "string" and related.snippet or ""
				local title = snippet ~= "" and clip_title(snippet, config.metadata_title_max_len) or "(loading...)"
				table.insert(entries, {
					id = related_name,
					type = rel and rel.type or "REFERENCE",
					title = title,
				})
			end
			::continue::
		end
		local limit = tonumber(config.list_relations_limit) or 20
		local truncated = 0
		if limit > 0 and #entries > limit then
			truncated = #entries - limit
			local sliced = {}
			for i = 1, limit do
				table.insert(sliced, entries[i])
			end
			entries = sliced
		end
		cache.out_items = entries
		cache.out_total = total_out
		cache.truncated_out = truncated
		cache.out_more = truncated > 0
		cache.out_status = "loaded"
		update_cache()
		for _, entry in ipairs(entries) do
			if entry.id and entry.title == "(loading...)" and not relation_title_cache[entry.id] then
				resolve_relation_title(entry.id, function(title)
					if title then
						entry.title = title
						render_cached_list()
					end
				end)
			end
		end
	end

	if type(memo.relations) == "table" then
		apply_out_from_memo(memo)
	else
		if show_out then
			api.get_memo(memo.name, function(full_memo, fallback_err)
				if not full_memo then
					cache.out_status = "error"
					cache.out_error = fallback_err
					update_cache()
					return
				end
				apply_out_from_memo(full_memo)
			end)
		else
			apply_out_from_memo(memo)
		end
	end

	if show_in then
		api.list_memo_relations_v1(memo.name, config.list_relations_limit, nil, function(resp, err)
			if not resp then
				cache.in_status = "error"
				cache.in_error = err
				cache.in_items = {}
				cache.in_total = 0
				cache.in_more = false
				update_cache()
				return
			end
			local relations = type(resp.relations) == "table" and resp.relations or {}
			local in_items = {}
			local total_in = 0
			for _, rel in ipairs(relations) do
				local memo_side = rel and rel.memo or nil
				local related_side = rel and rel.relatedMemo or nil
				if related_side and related_side.name == memo.name and memo_side and memo_side.name then
					total_in = total_in + 1
					local snippet = type(memo_side.snippet) == "string" and memo_side.snippet or ""
					local title = snippet ~= "" and clip_title(snippet, config.metadata_title_max_len) or "(missing)"
					table.insert(in_items, {
						id = memo_side.name,
						type = rel and rel.type or "REFERENCE",
						title = title,
					})
				end
			end
			local limit = tonumber(config.list_relations_limit) or 20
			local truncated = 0
			if limit > 0 and #in_items > limit then
				truncated = #in_items - limit
				local sliced = {}
				for i = 1, limit do
					table.insert(sliced, in_items[i])
				end
				in_items = sliced
			end
			cache.in_items = in_items
			cache.in_total = total_in
			cache.truncated_in = truncated
			cache.in_more = (resp.nextPageToken and resp.nextPageToken ~= "") or truncated > 0
			cache.in_status = "loaded"
			update_cache()
		end)
	else
		cache.in_items = {}
		cache.in_total = 0
		cache.truncated_in = 0
		cache.in_more = false
		cache.in_status = "loaded"
		update_cache()
	end
end

function M.clear_selection()
	clear_selection()
	render_cached_list()
end

local function selected_memo_objects()
	local out = {}
	for _, memo in ipairs(memos_cache) do
		if memo and memo.name and selected_memos[memo.name] then
			table.insert(out, memo)
		end
	end
	return out
end

local function current_list_item()
	local line_num = vim.api.nvim_win_get_cursor(0)[1]
	return list_items[line_num]
end

local function memo_from_item(item)
	if not item then
		return nil
	end
	if item.kind == "memo" then
		return memos_cache[item.memo_index]
	end
	if item.kind == "relation" then
		return memos_cache[item.parent_index]
	end
	if item.parent_index then
		return memos_cache[item.parent_index]
	end
	return nil
end

local function resolve_relation_edge(item)
	if not item or item.kind ~= "relation" then
		return nil
	end
	local parent = memos_cache[item.parent_index]
	local parent_name = parent and parent.name or nil
	local related_name = item.related_name
	if not parent_name or not related_name or related_name == "" then
		return nil
	end
	local direction = item.direction or "out"
	local source_name = parent_name
	local target_name = related_name
	if direction == "in" then
		source_name = related_name
		target_name = parent_name
	end
	return {
		source = source_name,
		related = target_name,
		parent = parent_name,
		rel_type = item.rel_type,
	}
end

local function find_next_memo_line(start_line, direction)
	local line = (start_line or 0) + direction
	while line >= 1 and line <= list_line_count do
		local item = list_items[line]
		if item and item.kind == "memo" then
			return line
		end
		line = line + direction
	end
	return nil
end

local function move_cursor_to(line_num)
	if line_num and line_num > 0 then
		pcall(vim.api.nvim_win_set_cursor, 0, { line_num, 0 })
	end
end

extract_memo_title = function(memo)
	local content = memo and memo.content or ""
	local first_line = type(content) == "string" and (content:match("^[^\n]*") or "") or ""
	first_line = vim.trim(first_line)
	if first_line ~= "" then
		return first_line
	end
	if memo and memo.name and memo.name ~= "" then
		return memo.name
	end
	return "untitled"
end

clip_title = function(title, max_len)
	if type(title) ~= "string" then
		return ""
	end
	local limit = tonumber(max_len) or 50
	if limit <= 0 then
		return ""
	end
	if #title <= limit then
		return title
	end
	if limit <= 3 then
		return title:sub(1, limit)
	end
	return title:sub(1, limit - 3) .. "..."
end

function M.toggle_select_next()
	if not memos_cache or #memos_cache == 0 then
		return
	end
	local line_num = vim.api.nvim_win_get_cursor(0)[1]
	local item = list_items[line_num]
	local selected_memo = item and item.kind == "memo" and memos_cache[item.memo_index] or nil
	if selected_memo then
		toggle_selected(selected_memo)
		render_cached_list()
	end
	local target = find_next_memo_line(line_num, 1)
	if target then
		move_cursor_to(target)
	end
end

function M.toggle_select_prev()
	if not memos_cache or #memos_cache == 0 then
		return
	end
	local line_num = vim.api.nvim_win_get_cursor(0)[1]
	local item = list_items[line_num]
	local selected_memo = item and item.kind == "memo" and memos_cache[item.memo_index] or nil
	if selected_memo then
		toggle_selected(selected_memo)
		render_cached_list()
	end
	local target = find_next_memo_line(line_num, -1)
	if target then
		move_cursor_to(target)
	end
end

function M.toggle_relations_tree()
	local item = current_list_item()
	if not item then
		return
	end
	local memo = memo_from_item(item)
	if not memo or not memo.name then
		return
	end
	relations_expanded[memo.name] = not relations_expanded[memo.name]
	ensure_relations_loaded(memo)
	render_cached_list()
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
	if opts.force_refresh or filter_changed or opts.reason == "sort" or opts.reason == "state" then
		clear_selection()
		reset_relations_state()
	end
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
		set_keymap(list_keymaps.split_edit_memo, '<Cmd>lua require("memos.ui").edit_selected_memo_in_split()<CR>')
		set_keymap(list_keymaps.vsplit_edit_memo, '<Cmd>lua require("memos.ui").edit_selected_memo_in_vsplit()<CR>')
		set_keymap(list_keymaps.edit_metadata, '<Cmd>lua require("memos.ui").edit_selected_memo_metadata()<CR>')
		set_keymap(list_keymaps.multi_edit_metadata, '<Cmd>lua require("memos.ui").edit_selected_memo_metadata_multi()<CR>')
		set_keymap(list_keymaps.clear_selection, '<Cmd>lua require("memos.ui").clear_selection()<CR>')
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
		set_keymap(list_keymaps.delete_relation_source, '<Cmd>lua require("memos.ui").confirm_delete_relation_source()<CR>')
		set_keymap(list_keymaps.toggle_sort, '<Cmd>lua require("memos.ui").cycle_sort()<CR>')
		set_keymap(list_keymaps.toggle_state, '<Cmd>lua require("memos.ui").toggle_state()<CR>')
		set_keymap(list_keymaps.toggle_select_next, '<Cmd>lua require("memos.ui").toggle_select_next()<CR>')
		set_keymap(list_keymaps.toggle_select_prev, '<Cmd>lua require("memos.ui").toggle_select_prev()<CR>')
		set_keymap(list_keymaps.toggle_relations, '<Cmd>lua require("memos.ui").toggle_relations_tree()<CR>')
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

local function open_related_memo(related_name, open_cmd)
	if not related_name or related_name == "" then
		vim.notify("Related memo ID is missing.", vim.log.levels.WARN)
		return
	end
	api.get_memo(related_name, function(memo, err)
		if not memo then
			vim.schedule(function()
				vim.notify("Failed to load related memo: " .. tostring(err), vim.log.levels.ERROR)
			end)
			return
		end
		vim.schedule(function()
			M.open_memo_for_edit(memo, open_cmd or "enew")
		end)
	end)
end

function M.edit_selected_memo()
	local item = current_list_item()
	if not item then
		return
	end
	if item.kind == "relation" then
		open_related_memo(item.related_name, "enew")
		return
	end
	local selected_memo = item.kind == "memo" and memos_cache[item.memo_index] or nil
	if selected_memo then
		M.open_memo_for_edit(selected_memo, "enew")
	end
end

function M.edit_selected_memo_in_vsplit()
	local item = current_list_item()
	if not item then
		return
	end
	local current_win = vim.api.nvim_get_current_win()
	local ok, is_memos_window = pcall(vim.api.nvim_win_get_var, current_win, "memos_window")
	if ok and is_memos_window == true then
		pcall(vim.api.nvim_win_close, current_win, true)
	end
	if item.kind == "relation" then
		open_related_memo(item.related_name, "vsplit | enew")
		return
	end
	local selected_memo = item.kind == "memo" and memos_cache[item.memo_index] or nil
	if selected_memo then
		M.open_memo_for_edit(selected_memo, "vsplit | enew")
	end
end

function M.edit_selected_memo_in_split()
	local item = current_list_item()
	if not item then
		return
	end
	local current_win = vim.api.nvim_get_current_win()
	local ok, is_memos_window = pcall(vim.api.nvim_win_get_var, current_win, "memos_window")
	if ok and is_memos_window == true then
		pcall(vim.api.nvim_win_close, current_win, true)
	end
	if item.kind == "relation" then
		open_related_memo(item.related_name, "split | enew")
		return
	end
	local selected_memo = item.kind == "memo" and memos_cache[item.memo_index] or nil
	if selected_memo then
		M.open_memo_for_edit(selected_memo, "split | enew")
	end
end

function M.copy_selected_memo_id()
	local selected_ids = selected_list()
	if #selected_ids > 0 then
		if config.confirm_copy then
			local prompt = string.format("Copy %d memo IDs to clipboard?", #selected_ids)
			local choice = vim.fn.confirm(prompt, "&Yes\n&No", 2)
			if choice ~= 1 then
				return
			end
		end
		vim.fn.setreg("+", table.concat(selected_ids, ","))
		vim.notify(string.format("Copied %d memo IDs to clipboard.", #selected_ids))
		return
	end
	local item = current_list_item()
	if not item then
		vim.notify("Select a memo line to copy.", vim.log.levels.WARN)
		return
	end
	local selected_id = nil
	local preview = nil
	if item.kind == "relation" then
		selected_id = item.related_name
		preview = relation_title_cache[selected_id]
	elseif item.kind == "memo" then
		local selected_memo = memos_cache[item.memo_index]
		selected_id = selected_memo and selected_memo.name or nil
		preview = selected_memo and (type(selected_memo.content) == "string" and selected_memo.content or ""):sub(1, 50) or nil
	end
	if not selected_id or selected_id == "" then
		vim.notify("Selected memo has no valid identifier.", vim.log.levels.WARN)
		return
	end

	if config.confirm_copy then
		local preview_text = preview or selected_id
		local choice = vim.fn.confirm("Copy this memo ID?\n[" .. preview_text .. "...]", "&Yes\n&No", 2)
		if choice ~= 1 then
			return
		end
	end

	vim.fn.setreg("+", selected_id)
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

local function parse_relation_ids(raw)
	local text = vim.trim(raw or "")
	if text == "" then
		return {}
	end
	local out = {}
	local seen = {}
	for token in text:gmatch("[^,%s]+") do
		local normalized = normalize_memo_name(token)
		if normalized and normalized ~= "" and not seen[normalized] then
			table.insert(out, normalized)
			seen[normalized] = true
		end
	end
	return out
end

local function prompt_relation_op(callback)
	local items = {
		{ value = "append", label = "Append" },
		{ value = "delete", label = "Delete" },
		{ value = "replace", label = "Replace" },
	}
	vim.schedule(function()
		vim.ui.select(items, {
			prompt = "Relation operation:",
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

local function prompt_relation_ids(default_raw, callback)
	vim.schedule(function()
		local default_value = default_raw or ""
		if type(default_value) ~= "string" then
			default_value = tostring(default_value)
		end
		default_value = default_value:gsub("[\r\n]+", " ")
		vim.ui.input({
			prompt = "Related memo ids (comma-separated, memos/<id>): ",
			default = default_value,
		}, function(input)
			if input == nil then
				callback(nil, nil)
				return
			end
			callback(parse_relation_ids(input), input)
		end)
	end)
end

function M.paste_memo_from_clipboard()
	local selected_ids = selected_list()
	if #selected_ids > 0 then
		vim.notify("Multi-select paste is not supported yet. Pasted the first memo only.", vim.log.levels.WARN)
	end
	local raw = vim.fn.getreg("+")
	local memo_name = nil
	if #selected_ids > 0 then
		local ids = parse_relation_ids(raw)
		memo_name = ids[1]
	else
		memo_name = normalize_memo_name(raw)
	end
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

local function delete_relation_edge(item)
	local edge = resolve_relation_edge(item)
	if not edge then
		vim.notify("Select a relation line to delete.", vim.log.levels.WARN)
		return
	end
	local preview = relation_title_cache[edge.related] or edge.related
	local choice = vim.fn.confirm(
		string.format("Delete relation?\n%s -> %s", edge.source or "(source)", preview or "(target)"),
		"&Yes\n&No",
		2
	)
	if choice ~= 1 then
		return
	end
	local cap = get_capabilities()
	if cap and cap.mode == "v0.21" then
		local rel_type = edge.rel_type or "REFERENCE"
		api.delete_memo_relation(edge.source, edge.related, rel_type, function(ok, err)
			vim.schedule(function()
				if ok then
					vim.notify("✅ Relation deleted.")
					invalidate_relations_cache({ edge.source, edge.related, edge.parent })
					M.refresh_list_silently()
				else
					vim.notify("❌ Failed to delete relation: " .. tostring(err), vim.log.levels.ERROR)
				end
			end)
		end)
		return
	end

	api.get_memo(edge.source, function(source_memo, err)
		if not source_memo then
			vim.schedule(function()
				vim.notify("Failed to load relation source: " .. tostring(err), vim.log.levels.ERROR)
			end)
			return
		end
		local relations = type(source_memo.relations) == "table" and source_memo.relations or {}
		local updated = {}
		local removed = 0
		local target_type = edge.rel_type
		if target_type == "" then
			target_type = nil
		end
		for _, rel in ipairs(relations) do
			local rel_related = rel and rel.relatedMemo and rel.relatedMemo.name or nil
			if not rel_related then
				local rel_id = rel and (rel.relatedMemoId or rel.relatedMemoID) or nil
				if rel_id then
					rel_related = "memos/" .. tostring(rel_id)
				end
			end
			local rel_type = rel and rel.type or "TYPE_UNSPECIFIED"
			if rel_related == edge.related and (not target_type or rel_type == target_type) then
				removed = removed + 1
			else
				table.insert(updated, rel)
			end
		end
		if removed == 0 then
			vim.schedule(function()
				vim.notify("No matching relation found to delete.", vim.log.levels.WARN)
			end)
			return
		end
		local fields = {
			content = source_memo.content or "",
			relations = updated,
		}
		api.update_memo_metadata(edge.source, fields, "relations", function(success)
			vim.schedule(function()
				if success then
					vim.notify("✅ Relation deleted.")
					invalidate_relations_cache({ edge.source, edge.related, edge.parent })
					M.refresh_list_silently()
				else
					vim.notify("❌ Failed to delete relation.", vim.log.levels.ERROR)
				end
			end)
		end)
	end)
end

function M.confirm_delete_relation_source()
	local item = current_list_item()
	if not item or item.kind ~= "relation" then
		vim.notify("Select a relation line to delete the referenced memo.", vim.log.levels.WARN)
		return
	end
	local related_name = item.related_name
	if not related_name or related_name == "" then
		vim.notify("Related memo ID is missing.", vim.log.levels.WARN)
		return
	end
	local preview = relation_title_cache[related_name] or related_name
	local choice = vim.fn.confirm("Delete referenced memo?\n[" .. preview .. "]", "&Yes\n&No", 2)
	if choice ~= 1 then
		return
	end
	api.delete_memo(related_name, function(success)
		vim.schedule(function()
			if success then
				vim.notify("✅ Memo deleted.")
				local parent = memos_cache[item.parent_index]
				local parent_name = parent and parent.name or nil
				invalidate_relations_cache({ related_name, parent_name })
				M.refresh_list_silently()
			else
				vim.notify("❌ Failed to delete memo.", vim.log.levels.ERROR)
			end
		end)
	end)
end

function M.confirm_delete_memo()
	local item = current_list_item()
	if not item then
		vim.notify("Select a memo line to delete.", vim.log.levels.WARN)
		return
	end
	if item.kind == "relation" then
		delete_relation_edge(item)
		return
	end
	local selected_memo = memos_cache[item.memo_index]
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

local function prompt_select_field(capabilities, callback, opts)
	opts = opts or {}
	local allow_relations = opts.allow_relations ~= false
	local prompt = opts.prompt or "Edit memo metadata:"
	local items = {}
	table.insert(items, { key = "visibility", label = "Visibility" })
	table.insert(items, { key = "pinned", label = "Pinned" })
	if not (capabilities and capabilities.mode == "v0.21") then
		table.insert(items, { key = "displayTime", label = "Display time" })
	end
	table.insert(items, { key = "createTime", label = "Create time" })
	if allow_relations then
		table.insert(items, { key = "relations", label = "Relations" })
	end
	table.insert(items, { key = "state", label = "State" })
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

local function prompt_metadata_value(field, memo, callback)
	if field == "visibility" then
		prompt_select_enum("Visibility", { "PRIVATE", "PROTECTED", "PUBLIC" }, callback)
		return
	end
	if field == "pinned" then
		prompt_select_boolean("Pinned", callback)
		return
	end
	if field == "displayTime" then
		prompt_iso_time("Display time", memo and memo.displayTime or nil, callback)
		return
	end
	if field == "createTime" then
		prompt_iso_time("Create time", memo and memo.createTime or nil, callback)
		return
	end
	if field == "state" then
		prompt_select_enum("State", { "NORMAL", "ARCHIVED" }, callback)
		return
	end
	callback(nil)
end

local function prompt_non_relation_metadata(capabilities, memo, callback, prompt)
	prompt_select_field(capabilities, function(field)
		if not field then
			callback(nil, nil)
			return
		end
		if field == "relations" then
			vim.notify("Relations are not supported in multi-edit mode.", vim.log.levels.WARN)
			callback(nil, nil)
			return
		end
		prompt_metadata_value(field, memo, function(value)
			if value == nil then
				callback(nil, nil)
				return
			end
			callback(field, value)
		end)
	end, { allow_relations = false, prompt = prompt })
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

local function collect_relation_names(relations)
	local names = {}
	if type(relations) ~= "table" then
		return names
	end
	for _, rel in ipairs(relations) do
		local related = rel and rel.relatedMemo or nil
		local related_name = related and related.name or nil
		if not related_name then
			local related_id = rel and (rel.relatedMemoId or rel.relatedMemoID) or nil
			if related_id then
				related_name = relation_name_from_id(related_id)
			end
		end
		if related_name and related_name ~= "" then
			table.insert(names, related_name)
		end
	end
	return names
end

invalidate_relations_cache = function(names)
	if type(names) ~= "table" then
		return
	end
	local seen = {}
	for _, name in ipairs(names) do
		if type(name) == "string" and name ~= "" and not seen[name] then
			relations_cache[name] = nil
			seen[name] = true
		end
	end
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
		local existing_names = collect_relation_names(relations)
		local function clear_all_relations(silent, callback)
			if type(relations) ~= "table" or #relations == 0 then
				if not silent then
					vim.notify("No relations to clear.", vim.log.levels.INFO)
				end
				if callback then
					callback(true)
				end
				return
			end
			local function finalize(failed)
				vim.schedule(function()
					if not silent then
						if failed then
							vim.notify("❌ Failed to clear some relations.", vim.log.levels.ERROR)
						else
							vim.notify("✅ Memo relations cleared.")
						end
						invalidate_relations_cache(vim.list_extend({ memo.name }, existing_names))
						M.refresh_list_silently()
					end
				end)
				if callback then
					callback(not failed)
				end
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
							finalize(failed)
						end
					end)
				else
					pending = pending - 1
					if pending == 0 then
						finalize(failed)
					end
				end
			end
		end

		prompt_relation_op(function(op)
			if not op then
				return
			end
			local clipboard_raw = vim.fn.getreg("+") or ""
			prompt_relation_ids(clipboard_raw, function(ids, _)
				if ids == nil then
					return
				end
				if op == "delete" then
					if #ids == 0 then
						clear_all_relations(false, nil)
						return
					end
					local wanted = {}
					for _, id in ipairs(ids) do
						wanted[id] = true
					end
					local targets = {}
					for _, rel in ipairs(relations) do
						local related_id = rel and (rel.relatedMemoID or rel.relatedMemoId)
						local rel_type = rel and rel.type or "REFERENCE"
						local related_name = related_id and relation_name_from_id(related_id) or nil
						if related_name and wanted[related_name] then
							table.insert(targets, { id = related_id, rel_type = rel_type })
						end
					end
					if #targets == 0 then
						vim.notify("No matching relations found for provided IDs.", vim.log.levels.WARN)
						return
					end
					local pending = #targets
					local failed = false
					for _, target in ipairs(targets) do
						api.delete_memo_relation(
							memo.name,
							relation_name_from_id(target.id),
							target.rel_type,
							function(ok, _)
								if not ok then
									failed = true
								end
								pending = pending - 1
								if pending == 0 then
									vim.schedule(function()
										if failed then
											vim.notify("❌ Failed to update relations.", vim.log.levels.ERROR)
										else
											vim.notify("✅ Memo relations updated.")
										end
										invalidate_relations_cache(vim.list_extend({ memo.name }, ids))
										M.refresh_list_silently()
									end)
								end
							end
						)
					end
					return
				end

				if #ids == 0 then
					if op == "replace" then
						clear_all_relations(false, nil)
					else
						vim.notify("No valid memo IDs provided.", vim.log.levels.WARN)
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
					local existing = {}
					for _, rel in ipairs(relations) do
						local related_id = rel and (rel.relatedMemoID or rel.relatedMemoId)
						local rel_type = rel and rel.type or "REFERENCE"
						if related_id then
							existing[relation_name_from_id(related_id) .. "|" .. rel_type] = true
						end
					end

					local function apply_append()
						local to_create = {}
						for _, id in ipairs(ids) do
							local key = id .. "|" .. type_input
							if not existing[key] then
								table.insert(to_create, id)
							end
						end
						if #to_create == 0 then
							vim.notify("No new relations to add.", vim.log.levels.INFO)
							return
						end
						local pending = #to_create
						local failed = false
						for _, id in ipairs(to_create) do
							api.create_memo_relation(memo.name, id, type_input, function(ok, relation_err)
								if not ok then
									failed = true
									vim.notify("❌ Failed to update relations: " .. tostring(relation_err), vim.log.levels.ERROR)
								end
								pending = pending - 1
								if pending == 0 then
									vim.schedule(function()
										if not failed then
											vim.notify("✅ Memo relations updated.")
										end
										local targets = vim.list_extend({ memo.name }, ids)
										if op == "replace" then
											targets = vim.list_extend(targets, existing_names)
										end
										invalidate_relations_cache(targets)
										M.refresh_list_silently()
									end)
								end
							end)
						end
					end

					if op == "replace" then
						clear_all_relations(true, function(ok)
							if not ok then
								return
							end
							apply_append()
						end)
					else
						apply_append()
					end
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
	local title = clip_title(extract_memo_title(memo), config.metadata_title_max_len)
	local prompt = string.format("Edit memo metadata: %s", title)
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
			prompt_relation_op(function(op)
				if not op then
					return
				end
				local clipboard_raw = vim.fn.getreg("+") or ""
				prompt_relation_ids(clipboard_raw, function(ids, _)
					if ids == nil then
						return
					end
					local existing = memo.relations or {}
					local existing_names = collect_relation_names(existing)
					if op == "delete" then
						if #ids == 0 then
							local fields = {
								content = memo.content or "",
								relations = {},
							}
							api.update_memo_metadata(memo.name, fields, "relations", function(success)
								if success then
									vim.schedule(function()
										vim.notify("✅ Memo relations cleared.")
										invalidate_relations_cache(vim.list_extend({ memo.name }, existing_names))
										M.refresh_list_silently()
									end)
								end
							end)
							return
						end
						local wanted = {}
						for _, id in ipairs(ids) do
							wanted[id] = true
						end
						local updated = {}
						local removed = 0
						for _, rel in ipairs(existing) do
							local related_name = rel and rel.relatedMemo and rel.relatedMemo.name or nil
							if related_name and wanted[related_name] then
								removed = removed + 1
							else
								table.insert(updated, rel)
							end
						end
						if removed == 0 then
							vim.notify("No matching relations found for provided IDs.", vim.log.levels.WARN)
							return
						end
						local fields = {
							content = memo.content or "",
							relations = updated,
						}
						api.update_memo_metadata(memo.name, fields, "relations", function(success)
							if success then
								vim.schedule(function()
									vim.notify("✅ Memo relations updated.")
									invalidate_relations_cache(vim.list_extend({ memo.name }, ids))
									M.refresh_list_silently()
								end)
							end
						end)
						return
					end

					if #ids == 0 then
						if op == "replace" then
							local fields = {
								content = memo.content or "",
								relations = {},
							}
							api.update_memo_metadata(memo.name, fields, "relations", function(success)
								if success then
									vim.schedule(function()
										vim.notify("✅ Memo relations cleared.")
										invalidate_relations_cache(vim.list_extend({ memo.name }, existing_names))
										M.refresh_list_silently()
									end)
								end
							end)
						else
							vim.notify("No valid memo IDs provided.", vim.log.levels.WARN)
						end
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
						local updated = {}
						local existing_map = {}
						for _, rel in ipairs(existing) do
							table.insert(updated, rel)
							local related_name = rel and rel.relatedMemo and rel.relatedMemo.name or nil
							local rel_type = rel and rel.type or "TYPE_UNSPECIFIED"
							if related_name and related_name ~= "" then
								existing_map[related_name .. "|" .. rel_type] = true
							end
						end
						if op == "replace" then
							updated = {}
							existing_map = {}
						end
						local added = 0
						for _, id in ipairs(ids) do
							local key = id .. "|" .. type_input
							if not existing_map[key] then
								table.insert(updated, {
									memo = { name = memo.name },
									relatedMemo = { name = id },
									type = type_input,
								})
								added = added + 1
							end
						end
						if added == 0 and op == "append" then
							vim.notify("No new relations to add.", vim.log.levels.INFO)
							return
						end
						local fields = {
							content = memo.content or "",
							relations = updated,
						}
						api.update_memo_metadata(memo.name, fields, "relations", function(success)
							if success then
								vim.schedule(function()
									vim.notify("✅ Memo relations updated.")
									local targets = vim.list_extend({ memo.name }, ids)
									if op == "replace" then
										targets = vim.list_extend(targets, existing_names)
									end
									invalidate_relations_cache(targets)
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
	end, { prompt = prompt })
end

function M.edit_selected_memo_metadata()
	local item = current_list_item()
	if not item or item.kind ~= "memo" then
		vim.notify("Select a memo line to edit metadata.", vim.log.levels.WARN)
		return
	end
	local selected_memo = memos_cache[item.memo_index]
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

function M.edit_selected_memo_metadata_multi()
	local selected = selected_memo_objects()
	if #selected == 0 then
		M.edit_selected_memo_metadata()
		return
	end

	local items = {
		{ value = "all", label = "Apply to all" },
		{ value = "per", label = "Repeat per memo" },
	}
	vim.schedule(function()
		vim.ui.select(items, {
			prompt = string.format("Edit metadata (%d selected):", #selected),
			format_item = function(item)
				return item.label
			end,
		}, function(choice)
			if not choice then
				return
			end
			local cap = get_capabilities()
			if choice.value == "all" then
				api.get_memo(selected[1].name, function(first_memo, err)
					if not first_memo then
						vim.schedule(function()
							vim.notify("Failed to load memo metadata: " .. tostring(err), vim.log.levels.ERROR)
						end)
						return
					end
					local prompt = string.format("Edit metadata (%d selected):", #selected)
					prompt_non_relation_metadata(cap, first_memo, function(field, value)
						if not field then
							return
						end
						for _, memo in ipairs(selected) do
							api.get_memo(memo.name, function(full_memo, load_err)
								if not full_memo then
									vim.schedule(function()
										vim.notify("Failed to load memo metadata: " .. tostring(load_err), vim.log.levels.ERROR)
									end)
									return
								end
								update_metadata_field(full_memo, field, value)
							end)
						end
						clear_selection()
						render_cached_list()
					end, prompt)
				end)
				return
			end

			local function process_idx(idx)
				local memo = selected[idx]
				if not memo then
					clear_selection()
					render_cached_list()
					return
				end
				api.get_memo(memo.name, function(full_memo, err)
					if not full_memo then
						vim.schedule(function()
							vim.notify("Failed to load memo metadata: " .. tostring(err), vim.log.levels.ERROR)
						end)
						process_idx(idx + 1)
						return
					end
					local title = clip_title(extract_memo_title(full_memo), config.metadata_title_max_len)
					local prompt = string.format("Edit memo metadata: %s", title)
					prompt_non_relation_metadata(cap, full_memo, function(field, value)
						if not field then
							clear_selection()
							render_cached_list()
							return
						end
						update_metadata_field(full_memo, field, value)
						process_idx(idx + 1)
					end, prompt)
				end)
			end

			process_idx(1)
		end)
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
