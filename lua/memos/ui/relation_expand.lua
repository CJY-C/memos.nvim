local M = {}

local RELATION_FETCH_CONCURRENCY = 3

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

local function cache_relation_result(session, name, memo_data, err)
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
end

local function drain_relation_queue(session, ctx)
	while (session.active_relation_fetches or 0) < RELATION_FETCH_CONCURRENCY do
		local name = table.remove(session.pending_relations, 1)
		if not name then
			return
		end

		session.queued_relations[name] = nil
		if not session:get_cached_relation_memo(name) and not session.in_flight_relations[name] then
			session.in_flight_relations[name] = true
			session.active_relation_fetches = (session.active_relation_fetches or 0) + 1
			session:set_refresh_state("refreshing")
			ctx.api:get_memo(name, function(memo_data, err)
				vim.schedule(function()
					session.in_flight_relations[name] = nil
					session.active_relation_fetches = math.max((session.active_relation_fetches or 1) - 1, 0)
					cache_relation_result(session, name, memo_data, err)
					drain_relation_queue(session, ctx)
					session:set_refresh_state("idle")
					session:render_cached_memos()
				end)
			end)
		end
	end
end

function M.fetch_missing_relations(session, ctx, names)
	session.pending_relations = session.pending_relations or {}
	session.queued_relations = session.queued_relations or {}
	session.active_relation_fetches = session.active_relation_fetches or 0

	local queued = false
	for _, name in ipairs(names) do
		if not session:get_cached_relation_memo(name) and not session.in_flight_relations[name] and not session.queued_relations[name] then
			table.insert(session.pending_relations, name)
			session.queued_relations[name] = true
			queued = true
		end
	end
	if queued then
		session:set_refresh_state("refreshing")
	end
	drain_relation_queue(session, ctx)
end

return M
