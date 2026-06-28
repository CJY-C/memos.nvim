local M = {}

local function get_current_memo(session)
	local item = session:current_list_item()
	if not item or item.kind ~= "memo" then
		return nil
	end
	return session.memos_cache[item.index]
end

function M.toggle_outgoing(session)
	local memo = get_current_memo(session)
	if not memo then
		return
	end
	local outgoing_names = session:get_outgoing_relation_names(memo)
	if #outgoing_names == 0 then
		vim.notify("No outgoing relations to expand.", vim.log.levels.INFO)
		return
	end

	if session.expanded_outgoing[memo.name] then
		session.expanded_outgoing[memo.name] = nil
	else
		session.expanded_outgoing[memo.name] = true
		session:fetch_missing_relations(outgoing_names)
	end
	session:render_cached_memos()
end

function M.toggle_incoming(session)
	local memo = get_current_memo(session)
	if not memo then
		return
	end
	local incoming_names = session:get_incoming_relation_names(memo)
	if #incoming_names == 0 then
		vim.notify("No incoming relations to expand.", vim.log.levels.INFO)
		return
	end

	if session.expanded_incoming[memo.name] then
		session.expanded_incoming[memo.name] = nil
	else
		session.expanded_incoming[memo.name] = true
		session:fetch_missing_relations(incoming_names)
	end
	session:render_cached_memos()
end

function M.collapse_all(session)
	session.expanded_outgoing = {}
	session.expanded_incoming = {}
	session:render_cached_memos()
	vim.notify("Collapsed all memo expansions.")
end

function M.fetch_missing_relations(session, ctx, names)
	for _, name in ipairs(names) do
		if not session:get_cached_relation_memo(name) and not session.in_flight_relations[name] then
			session.in_flight_relations[name] = true
			session:set_refresh_state("refreshing")
			ctx.api:get_memo(name, function(memo_data, err)
				vim.schedule(function()
					session.in_flight_relations[name] = nil
					if memo_data then
						session.relation_details_cache[name] = memo_data
					else
						session.relation_details_cache[name] = {
							name = name,
							content = "Failed to load relation: " .. tostring(err),
							state = "NORMAL",
							create_time = "",
							update_time = "",
						}
					end
					session:set_refresh_state("idle")
					session:render_cached_memos()
				end)
			end)
		end
	end
end

return M
