local M = {}

local workspace = {
	layout = "list",
	focus_role = "list",
	edit_buf = nil,
}

function M.is_float_window(win)
	local cfg = vim.api.nvim_win_get_config(win)
	return cfg and cfg.relative and cfg.relative ~= ""
end

local function memo_window_role(win)
	local ok, value = pcall(vim.api.nvim_win_get_var, win, "memos_role")
	return ok and value or nil
end

local function memos_float_windows()
	local wins = {}
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local ok, value = pcall(vim.api.nvim_win_get_var, win, "memos_window")
		if ok and value == true and vim.api.nvim_win_is_valid(win) then
			table.insert(wins, win)
		end
	end
	return wins
end

function M.find_memos_float_window(role)
	for _, win in ipairs(memos_float_windows()) do
		if not role or memo_window_role(win) == role then
			return win
		end
	end
	return nil
end

local function float_area(ctx)
	local width = math.floor(vim.o.columns * (ctx.config.window.width or 0.85))
	local height = math.floor(vim.o.lines * (ctx.config.window.height or 0.85))
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)
	return {
		width = math.max(width, 20),
		height = math.max(height, 8),
		row = math.max(row, 0),
		col = math.max(col, 0),
	}
end

local function close_memos_float_windows()
	local current = vim.api.nvim_get_current_win()
	for _, win in ipairs(memos_float_windows()) do
		if win == current then
			workspace.focus_role = memo_window_role(win) or workspace.focus_role
		end
		pcall(vim.api.nvim_win_close, win, true)
	end
end

local function open_pane(ctx, buf, role, opts)
	local win = vim.api.nvim_open_win(buf, opts.enter == true, {
		relative = "editor",
		row = opts.row,
		col = opts.col,
		width = opts.width,
		height = opts.height,
		style = "minimal",
		border = ctx.config.window.border or "rounded",
		title = role == "list" and " Memos " or " Memo ",
		title_pos = "center",
	})
	vim.api.nvim_win_set_var(win, "memos_window", true)
	vim.api.nvim_win_set_var(win, "memos_role", role)
	vim.wo[win].wrap = role ~= "list"
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	return win
end

local function open_workspace(ctx, layout, edit_buf, focus_role)
	close_memos_float_windows()
	local area = float_area(ctx)
	local list_buf = ctx.get_list_buf()
	local target_focus = focus_role or workspace.focus_role or "list"

	workspace.layout = layout
	workspace.focus_role = target_focus
	workspace.edit_buf = edit_buf

	if layout == "vsplit" and edit_buf and vim.api.nvim_buf_is_valid(edit_buf) then
		local list_width = math.max(math.floor(area.width * 0.4), 20)
		local edit_width = math.max(area.width - list_width, 20)
		open_pane(ctx, list_buf, "list", {
			row = area.row,
			col = area.col,
			width = list_width,
			height = area.height,
			enter = target_focus ~= "edit",
		})
		open_pane(ctx, edit_buf, "edit", {
			row = area.row,
			col = area.col + list_width,
			width = edit_width,
			height = area.height,
			enter = target_focus == "edit",
		})
	elseif layout == "split" and edit_buf and vim.api.nvim_buf_is_valid(edit_buf) then
		local list_height = math.max(math.floor(area.height * 0.4), 5)
		local edit_height = math.max(area.height - list_height, 5)
		open_pane(ctx, list_buf, "list", {
			row = area.row,
			col = area.col,
			width = area.width,
			height = list_height,
			enter = target_focus ~= "edit",
		})
		open_pane(ctx, edit_buf, "edit", {
			row = area.row + list_height,
			col = area.col,
			width = area.width,
			height = edit_height,
			enter = target_focus == "edit",
		})
	else
		local role = edit_buf and vim.api.nvim_buf_is_valid(edit_buf) and "edit" or "list"
		local buf = role == "edit" and edit_buf or list_buf
		workspace.layout = role
		workspace.focus_role = role
		open_pane(ctx, buf, role, {
			row = area.row,
			col = area.col,
			width = area.width,
			height = area.height,
			enter = true,
		})
	end
	ctx.set_last_float_buf(vim.api.nvim_get_current_buf())
end

function M.refresh_list_contents(ctx, opts)
	opts = opts or {}
	local buf = M.ensure_list_buf(ctx)
	local s = ctx.sessions[buf]
	if not s then
		return
	end

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

function M.render_list_contents(ctx)
	local buf = M.ensure_list_buf(ctx)
	local s = ctx.sessions[buf]
	if not s then
		return
	end
	if #s.memos_cache > 0 then
		s:render_cached_memos()
	end
	s:bind_list_keymaps()
end

function M.create_float_window(ctx, buf)
	local role = buf == ctx.get_list_buf() and "list" or "edit"
	open_workspace(ctx, role, role == "edit" and buf or nil, role)
	return M.find_memos_float_window(role)
end

function M.open_float_edit_window(ctx, buf, open_cmd)
	local layout = open_cmd == "vsplit" and "vsplit" or open_cmd == "split" and "split" or "edit"
	if layout == "vsplit" or layout == "split" then
		M.ensure_list_buf(ctx)
		open_workspace(ctx, layout, buf, "edit")
		M.render_list_contents(ctx)
	else
		open_workspace(ctx, "edit", buf, "edit")
	end
end

function M.return_to_float_list(ctx, edit_buf)
	if not (ctx.config.window and ctx.config.window.enable_float) or #memos_float_windows() == 0 then
		return false
	end
	local modified = vim.api.nvim_buf_is_valid(edit_buf) and vim.bo[edit_buf].modified
	if modified then
		if workspace.layout ~= "vsplit" and workspace.layout ~= "split" then
			open_workspace(ctx, "vsplit", edit_buf, "list")
		else
			local list_win = M.find_memos_float_window("list")
			if list_win then
				vim.api.nvim_set_current_win(list_win)
				workspace.focus_role = "list"
			end
		end
	else
		workspace.edit_buf = nil
		open_workspace(ctx, "list", nil, "list")
	end
	M.refresh_list_contents(ctx)
	return true
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
			local float_win = M.find_memos_float_window("list")
			if float_win then
				vim.api.nvim_set_current_win(float_win)
				vim.api.nvim_set_current_buf(buf)
			else
				open_workspace(ctx, "list", nil, "list")
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
	M.refresh_list_contents(ctx, opts)
end

function M.toggle_memos_list(ctx)
	if ctx.config.window and ctx.config.window.enable_float then
		if #memos_float_windows() > 0 then
			close_memos_float_windows()
			return
		end
		if workspace.edit_buf and vim.api.nvim_buf_is_valid(workspace.edit_buf) then
			open_workspace(ctx, workspace.layout, workspace.edit_buf, workspace.focus_role)
			if workspace.layout == "split" or workspace.layout == "vsplit" then
				M.refresh_list_contents(ctx)
			end
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
		close_memos_float_windows()
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
