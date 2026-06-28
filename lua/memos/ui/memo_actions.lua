local M = {}

function M.toggle_pin(session, ctx)
	if session.current_list_state == "TEMPLATES" then
		vim.notify("Pinning is not supported for templates.", vim.log.levels.WARN)
		return
	end
	local item = session:current_list_item()
	local memo = session:get_memo_from_item(item)
	if not memo or not memo.name or memo.name == "" then
		vim.notify("No memo on the current line.", vim.log.levels.INFO)
		return
	end

	local next_pinned = memo.pinned ~= true
	ctx.api:update_memo_pinned(memo.name, next_pinned, function(success, err)
		vim.schedule(function()
			if success then
				memo.pinned = next_pinned
				session:render_cached_memos()
				vim.notify(next_pinned and "Memo pinned." or "Memo unpinned.")
				session:refresh_list_silently()
			else
				vim.notify("Failed to update memo pin: " .. tostring(err), vim.log.levels.ERROR)
			end
		end)
	end)
end

function M.archive(session, ctx)
	if session.current_list_state == "TEMPLATES" then
		vim.notify("Archiving is not supported for templates.", vim.log.levels.WARN)
		return
	end
	local item = session:current_list_item()
	local memo = session:get_memo_from_item(item)
	if not memo or not memo.name or memo.name == "" then
		vim.notify("No memo on the current line.", vim.log.levels.INFO)
		return
	end

	local next_state = session.current_list_state == "ARCHIVED" and "NORMAL" or "ARCHIVED"
	ctx.api:update_memo_state(memo.name, next_state, function(success, err)
		vim.schedule(function()
			if success then
				session:remove_memo_from_cache(memo.name)
				session:render_cached_memos()
				vim.notify(next_state == "ARCHIVED" and "Memo archived." or "Memo restored.")
				session:refresh_list_silently()
			else
				vim.notify("Failed to update memo state: " .. tostring(err), vim.log.levels.ERROR)
			end
		end)
	end)
end

function M.delete(session, ctx)
	local item = session:current_list_item()
	if not item then
		return
	end

	if item.kind == "relation" or item.kind == "relation_loading" then
		session:delete_selected_relation(item)
		return
	end

	local memo = session:get_memo_from_item(item)
	if not memo or not memo.name or memo.name == "" then
		vim.notify("Select a memo line to delete.", vim.log.levels.INFO)
		return
	end

	if session.current_list_state == "TEMPLATES" then
		ctx.template_delete_selected(memo, item.index)
		return
	end

	local title = ctx.memo_title(memo)
	vim.ui.select({ "Cancel", "Delete" }, {
		prompt = "Delete memo: " .. title,
		kind = "memos_delete",
	}, function(choice)
		if choice ~= "Delete" then
			return
		end

		ctx.api:delete_memo(memo.name, function(success, err)
			vim.schedule(function()
				if success then
					session:remove_memo_from_cache(memo.name)
					session:render_cached_memos()
					vim.notify("Memo deleted.")
					session:refresh_list_silently()
				else
					vim.notify("Failed to delete memo: " .. tostring(err), vim.log.levels.ERROR)
				end
			end)
		end)
	end)
end

function M.edit_visibility(session, ctx)
	if session.current_list_state == "TEMPLATES" then
		vim.notify("Visibility editing is not supported for templates.", vim.log.levels.WARN)
		return
	end
	local item = session:current_list_item()
	local memo = session:get_memo_from_item(item)
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
		ctx.api:update_memo_visibility(memo.name, choice, function(success, err)
			vim.schedule(function()
				if success then
					memo.visibility = choice
					session:render_cached_memos()
					vim.notify("Memo visibility set to " .. choice .. ".")
					session:refresh_list_silently()
				else
					vim.notify("Failed to update memo visibility: " .. tostring(err), vim.log.levels.ERROR)
				end
			end)
		end)
	end)
end

function M.edit_create_time(session, ctx)
	if session.current_list_state == "TEMPLATES" then
		vim.notify("Create time editing is not supported for templates.", vim.log.levels.WARN)
		return
	end
	local item = session:current_list_item()
	local memo = session:get_memo_from_item(item)
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
		ctx.api:update_memo_create_time(memo.name, next_create_time, function(success, err)
			vim.schedule(function()
				if success then
					memo.create_time = next_create_time
					session:render_cached_memos()
					vim.notify("Memo create_time updated.")
					session:refresh_list_silently()
				else
					vim.notify("Failed to update memo create_time: " .. tostring(err), vim.log.levels.ERROR)
				end
			end)
		end)
	end)
end

return M
