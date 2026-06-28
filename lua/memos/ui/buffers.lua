local M = {}

function M.open_edit_buffer(ctx, content, open_cmd)
	if open_cmd == "split" or open_cmd == "vsplit" then
		local source_win = vim.api.nvim_get_current_win()
		local close_source_float = false
		local ok, is_memos_window = pcall(vim.api.nvim_win_get_var, source_win, "memos_window")
		if ok and is_memos_window == true and ctx.is_float_window(source_win) then
			close_source_float = true
		end
		local alternate_win = vim.fn.win_getid(vim.fn.winnr("#"))
		if alternate_win ~= 0 and vim.api.nvim_win_is_valid(alternate_win) and not ctx.is_float_window(alternate_win) then
			vim.api.nvim_set_current_win(alternate_win)
		end
		if close_source_float and vim.api.nvim_win_is_valid(source_win) then
			pcall(vim.api.nvim_win_close, source_win, true)
		end

		local buf = vim.api.nvim_create_buf(false, true)
		local split_dir = open_cmd == "vsplit" and "right" or "below"
		vim.api.nvim_open_win(buf, true, {
			split = split_dir,
		})

		if type(content) == "string" then
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n"))
		end
		return buf
	end

	local buf = vim.api.nvim_create_buf(false, true)
	local used_float = false
	if ctx.config.window and ctx.config.window.enable_float then
		local float_win = ctx.find_memos_float_window()
		if float_win then
			vim.api.nvim_set_current_win(float_win)
			vim.api.nvim_win_set_buf(float_win, buf)
			used_float = true
		else
			ctx.create_float_window(buf)
			vim.api.nvim_set_current_buf(buf)
			used_float = true
		end
	end
	if not used_float then
		local split_dir = (open_cmd == "vsplit" and "right") or (open_cmd == "split" and "below") or nil
		if split_dir then
			vim.api.nvim_open_win(buf, true, {
				split = split_dir,
			})
		else
			vim.api.nvim_win_set_buf(0, buf)
		end
	end
	if type(content) == "string" then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n"))
	end
	return buf
end

function M.setup_buffer_for_editing(ctx)
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
		M.save_or_create_dispatcher(ctx)
	end, {})
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = 0,
		callback = function(ev)
			M.save_or_create_dispatcher(ctx, { post_save_ui = false, bufnr = ev.buf })
		end,
	})

	local keys = ctx.config.keymaps.buffer
	ctx.set_keymap(0, keys.save, "<Cmd>MemosSave<CR>")
	ctx.set_keymap(0, keys.back_to_list, '<Cmd>lua require("memos.ui").return_to_list()<CR>')

	if ctx.config.auto_save then
		local group = vim.api.nvim_create_augroup("MemosAutoSave", { clear = false })
		vim.api.nvim_create_autocmd({ "InsertLeave", "CursorHold" }, {
			group = group,
			buffer = 0,
			callback = function(ev)
				M.check_and_auto_save(ctx, ev.buf)
			end,
		})
	end
end

function M.open_memo_for_edit(ctx, memo, open_cmd)
	if not memo or not memo.name or memo.name == "" then
		vim.notify("Selected memo has no valid identifier.", vim.log.levels.ERROR)
		return
	end
	local content = memo.content or ""
	local buffer_name = ctx.build_memo_buffer_name(memo, content)
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

	M.open_edit_buffer(ctx, content, open_cmd or "enew")
	if buffer_name then
		vim.api.nvim_buf_set_name(0, buffer_name)
	end
	vim.b.memos_memo_name = memo.name
	M.setup_buffer_for_editing(ctx)
end

function M.create_memo_in_buffer(ctx, content)
	M.open_edit_buffer(ctx, content or "", "enew")
	vim.b.memos_memo_name = nil
	vim.b.memos_template_mode = nil
	vim.b.memos_template_name = nil
	vim.api.nvim_buf_set_name(0, "memos/new_memo_" .. vim.fn.strftime("%s"))
	M.setup_buffer_for_editing(ctx)
end

function M.return_to_list(ctx)
	local current_buf = vim.api.nvim_get_current_buf()
	ctx.show_memos_list()
	if vim.api.nvim_buf_is_valid(current_buf) and not vim.bo[current_buf].modified then
		pcall(vim.api.nvim_buf_delete, current_buf, { force = false })
	end
end

function M.check_and_auto_save(ctx, buf)
	buf = buf or vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	if vim.b[buf].memos_original_content == nil then
		return
	end
	local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	if content ~= vim.b[buf].memos_original_content then
		M.save_or_create_dispatcher(ctx, { bufnr = buf })
	end
end

function M.save_or_create_dispatcher(ctx, opts)
	opts = opts or {}
	local post_save_ui = opts.post_save_ui ~= false
	local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
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
						M.save_or_create_dispatcher(ctx, opts)
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
					ctx.refresh_list_silently()
				else
					vim.notify("Failed to save template: " .. tostring(err), vim.log.levels.ERROR)
				end
				finish()
			end)
		end)
		return
	end

	if memo_name then
		ctx.api:update_memo(memo_name, content, function(success, err)
			vim.schedule(function()
				if success then
					vim.b[bufnr].memos_original_content = content
					vim.bo[bufnr].modified = false
					vim.notify("Memo saved.")
					ctx.refresh_list_silently()
				else
					vim.notify("Failed to save memo: " .. tostring(err), vim.log.levels.ERROR)
				end
				finish()
			end)
		end)
		return
	end

	ctx.api:create_memo(content, function(new_memo, err)
		vim.schedule(function()
			if new_memo and new_memo.name then
				vim.b[bufnr].memos_memo_name = new_memo.name
				vim.b[bufnr].memos_original_content = content
				vim.bo[bufnr].modified = false
				local new_name = ctx.build_memo_buffer_name(new_memo, content)
				if new_name then
					pcall(vim.api.nvim_buf_set_name, bufnr, new_name)
				end
				vim.notify("Memo created.")
				if post_save_ui then
					ctx.show_memos_list()
				else
					ctx.refresh_list_silently()
				end
			else
				vim.notify("Failed to create memo: " .. tostring(err), vim.log.levels.ERROR)
			end
			finish()
		end)
	end)
end

return M
