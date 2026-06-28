local M = {}

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

function M.current_list_item(session)
	local line = vim.api.nvim_win_get_cursor(0)[1]
	return session.list_items[line]
end

function M.get_memo_from_item(session, item)
	if not item then
		return nil
	end
	if item.kind == "memo" then
		return session.memos_cache[item.index]
	elseif item.kind == "relation" then
		return item.memo
	end
	return nil
end

function M.remove_memo_from_cache(session, memo_name)
	for idx, memo in ipairs(session.memos_cache) do
		if memo.name == memo_name then
			table.remove(session.memos_cache, idx)
			session:mark_relation_index_dirty()
			break
		end
	end
	session.relation_details_cache[memo_name] = nil
	session.expanded_outgoing[memo_name] = nil
	session.expanded_incoming[memo_name] = nil
end

function M.edit_selected_memo_with(session, ctx, open_cmd)
	local item = session:current_list_item()
	if not item then
		return
	end
	if item.kind == "load_more" then
		session:load_next_page()
		return
	end
	local memo = session:get_memo_from_item(item)
	if memo then
		if session.current_list_state == "TEMPLATES" then
			ctx.template_edit_selected(memo, open_cmd)
		else
			ctx.open_memo_for_edit(memo, open_cmd)
		end
	end
end

function M.copy_selected_memo_id(session)
	local item = session:current_list_item()
	local memo = session:get_memo_from_item(item)
	if not memo or not memo.name or memo.name == "" then
		vim.notify("No memo ID on the current line.", vim.log.levels.INFO)
		return
	end
	local register = copy_text(memo.name)
	vim.notify("Copied memo ID to " .. register .. ": " .. memo.name)
end

function M.remove_cached_memo_at(session, index)
	if type(index) == "number" and session.memos_cache[index] then
		table.remove(session.memos_cache, index)
		session:render_cached_memos()
	end
end

return M
