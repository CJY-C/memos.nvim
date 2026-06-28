local M = {}

function M.set_keymap(buf, key, rhs)
	if type(key) ~= "string" or key == "" then
		return false
	end
	vim.api.nvim_buf_set_keymap(buf, "n", key, rhs, { noremap = true, silent = true })
	return true
end

local function set_map(buf, bound, key, rhs)
	if M.set_keymap(buf, key, rhs) then
		table.insert(bound, key)
	end
end

function M.bind_list_keymaps(buf, keys)
	keys = keys or {}

	if vim.b[buf].memos_bound_keys then
		for _, key in ipairs(vim.b[buf].memos_bound_keys) do
			pcall(vim.api.nvim_buf_del_keymap, buf, "n", key)
		end
	end

	local bound = {}
	set_map(buf, bound, keys.edit_memo, '<Cmd>lua require("memos.ui").edit_selected_memo()<CR>')
	set_map(buf, bound, "e", '<Cmd>lua require("memos.ui").edit_selected_memo()<CR>')
	set_map(buf, bound, keys.edit_memo_split, '<Cmd>lua require("memos.ui").edit_selected_memo_split()<CR>')
	set_map(buf, bound, keys.edit_memo_vsplit, '<Cmd>lua require("memos.ui").edit_selected_memo_vsplit()<CR>')
	set_map(buf, bound, keys.add_memo, '<Cmd>lua require("memos.ui").add_memo_command()<CR>')
	set_map(buf, bound, "i", '<Cmd>lua require("memos.ui").add_memo_command()<CR>')
	set_map(buf, bound, keys.new_memo or "n", '<Cmd>lua require("memos.ui").new_memo_or_template_command()<CR>')
	set_map(buf, bound, keys.search_memos, '<Cmd>lua require("memos.ui").search_memos()<CR>')
	set_map(buf, bound, keys.copy_memo_id, '<Cmd>lua require("memos.ui").copy_selected_memo_id()<CR>')
	set_map(buf, bound, keys.add_relation or "c", '<Cmd>lua require("memos.ui").add_relation_command()<CR>')
	set_map(buf, bound, keys.toggle_pin, '<Cmd>lua require("memos.ui").toggle_selected_memo_pin()<CR>')
	set_map(buf, bound, keys.delete_memo, '<Cmd>lua require("memos.ui").delete_selected_memo()<CR>')
	set_map(buf, bound, keys.archive_memo, '<Cmd>lua require("memos.ui").archive_selected_memo()<CR>')
	set_map(buf, bound, keys.toggle_archive_view, '<Cmd>lua require("memos.ui").toggle_archive_view()<CR>')
	set_map(buf, bound, keys.toggle_template_view, '<Cmd>lua require("memos.ui").toggle_template_view()<CR>')
	set_map(buf, bound, keys.edit_visibility, '<Cmd>lua require("memos.ui").edit_selected_memo_visibility()<CR>')
	set_map(buf, bound, keys.edit_create_time, '<Cmd>lua require("memos.ui").edit_selected_memo_create_time()<CR>')
	set_map(buf, bound, keys.refresh_list, '<Cmd>lua require("memos.ui").refresh_list_command()<CR>')
	set_map(buf, bound, keys.next_page, '<Cmd>lua require("memos.ui").load_next_page()<CR>')
	set_map(buf, bound, keys.prev_page, '<Cmd>lua require("memos.ui").load_prev_page()<CR>')
	set_map(buf, bound, keys.quit, '<Cmd>lua require("memos.ui").quit_memos_list()<CR>')

	set_map(buf, bound, keys.toggle_expand or "<Tab>", '<Cmd>lua require("memos.ui").toggle_expand_selected()<CR>')
	set_map(buf, bound, keys.toggle_expand_incoming or "<S-Tab>", '<Cmd>lua require("memos.ui").toggle_expand_incoming_selected()<CR>')
	set_map(buf, bound, keys.fold_outgoing or "zo", '<Cmd>lua require("memos.ui").toggle_expand_selected()<CR>')
	set_map(buf, bound, keys.fold_incoming or "zi", '<Cmd>lua require("memos.ui").toggle_expand_incoming_selected()<CR>')
	set_map(buf, bound, keys.fold_all or "zM", '<Cmd>lua require("memos.ui").collapse_all()<CR>')

	vim.b[buf].memos_bound_keys = bound
	return bound
end

return M
