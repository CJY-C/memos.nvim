local M = {}

function M.is_float_window(win)
	local cfg = vim.api.nvim_win_get_config(win)
	return cfg and cfg.relative and cfg.relative ~= ""
end

function M.find_memos_float_window()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local ok, value = pcall(vim.api.nvim_win_get_var, win, "memos_window")
		if ok and value == true and vim.api.nvim_win_is_valid(win) then
			return win
		end
	end
	return nil
end

function M.create_float_window(ctx, buf)
	local width = math.floor(vim.o.columns * (ctx.config.window.width or 0.85))
	local height = math.floor(vim.o.lines * (ctx.config.window.height or 0.85))
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = ctx.config.window.border or "rounded",
		title = " Memos ",
		title_pos = "center",
	})
	vim.api.nvim_win_set_var(win, "memos_window", true)
	ctx.set_last_float_buf(buf)
	return win
end

function M.ensure_list_buf(ctx)
	local list_buf = ctx.get_list_buf()
	if list_buf and vim.api.nvim_buf_is_valid(list_buf) then
		return list_buf
	end

	list_buf = vim.api.nvim_create_buf(false, true)
	ctx.set_list_buf(list_buf)
	vim.api.nvim_buf_set_name(list_buf, "MemosList")
	vim.bo[list_buf].buftype = "nofile"
	vim.bo[list_buf].bufhidden = "hide"
	vim.bo[list_buf].buflisted = false
	vim.bo[list_buf].filetype = "memos_list"
	vim.bo[list_buf].modifiable = false
	vim.bo[list_buf].swapfile = false

	ctx.sessions[list_buf] = ctx.new_session(list_buf)

	vim.api.nvim_create_autocmd("BufEnter", {
		buffer = list_buf,
		callback = function()
			local s = ctx.sessions[list_buf]
			if s then
				s:bind_list_keymaps()
			end
		end,
	})
	return list_buf
end

function M.focus_list_buf(ctx)
	local buf = M.ensure_list_buf(ctx)
	local win = vim.fn.bufwinid(buf)
	if win ~= -1 then
		vim.api.nvim_set_current_win(win)
	else
		if ctx.config.window and ctx.config.window.enable_float then
			local float_win = M.find_memos_float_window()
			if float_win then
				vim.api.nvim_set_current_win(float_win)
				vim.api.nvim_set_current_buf(buf)
			else
				M.create_float_window(ctx, buf)
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

function M.count_normal_windows()
	local count = 0
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_is_valid(win) and not M.is_float_window(win) then
			count = count + 1
		end
	end
	return count
end

function M.show_memos_list(ctx, opts)
	opts = opts or {}
	local buf = M.ensure_list_buf(ctx)
	local s = ctx.sessions[buf]
	if not s then
		return
	end

	M.focus_list_buf(ctx)
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

function M.toggle_memos_list(ctx)
	if ctx.config.window and ctx.config.window.enable_float then
		local existing = M.find_memos_float_window()
		if existing then
			pcall(vim.api.nvim_win_close, existing, true)
			return
		end
		local last_float_buf = ctx.get_last_float_buf()
		if last_float_buf and vim.api.nvim_buf_is_valid(last_float_buf) then
			M.create_float_window(ctx, last_float_buf)
			M.show_memos_list(ctx)
			return
		end
	end
	M.show_memos_list(ctx)
end

function M.quit_memos_list(ctx)
	local current_win = vim.api.nvim_get_current_win()
	local current_buf = vim.api.nvim_get_current_buf()
	local ok, is_memos_window = pcall(vim.api.nvim_win_get_var, current_win, "memos_window")
	if ok and is_memos_window == true then
		pcall(vim.api.nvim_win_close, current_win, true)
		return
	end
	if M.count_normal_windows() > 1 then
		pcall(vim.api.nvim_win_close, current_win, true)
		return
	end
	if current_buf == ctx.get_list_buf() then
		local new_buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_win_set_buf(0, new_buf)
	end
end

function M.show_templates_list(ctx)
	local buf = M.ensure_list_buf(ctx)
	local s = ctx.sessions[buf]
	if s then
		s:save_current_state_cache()
		s:load_state_cache("TEMPLATES")
	end
	ctx.redraw_status()
	M.focus_list_buf(ctx)
	M.show_memos_list(ctx)
end

return M
