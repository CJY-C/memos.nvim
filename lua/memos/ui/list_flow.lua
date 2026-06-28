local M = {}

local function template_filter(filter)
	if filter and filter ~= "" then
		return "content.contains('#type/template') && (" .. filter .. ")"
	end
	return "content.contains('#type/template')"
end

function M.save_current_state_cache(session)
	local state = session.current_list_state
	session.caches[state] = {
		memos = vim.deepcopy(session.memos_cache),
		page_token = session.current_page_token,
		filter = session.current_filter,
		last_refresh_at = session.last_refresh_at,
		page_history = vim.deepcopy(session.page_history or {}),
	}
end

function M.load_state_cache(session, state)
	session.current_list_state = state
	local c = session.caches[state] or { memos = {}, page_token = nil, filter = "", last_refresh_at = nil, page_history = {} }
	session.memos_cache = vim.deepcopy(c.memos)
	session.current_page_token = c.page_token
	session.current_filter = c.filter
	session.last_refresh_at = c.last_refresh_at
	session.page_history = vim.deepcopy(c.page_history or {})
	session.relation_index_dirty = true
end

function M.render_memos(session, data, append)
	if not data then
		vim.notify("API returned no data.", vim.log.levels.WARN)
		return
	end
	if append then
		vim.list_extend(session.memos_cache, data.memos or {})
	else
		session.memos_cache = data.memos or {}
	end
	session:mark_relation_index_dirty()
	session.current_page_token = data.next_page_token or ""
	session:render_cached_memos()
end

function M.fetch_memos(session, ctx, opts)
	opts = opts or {}
	local req_state = session.current_list_state
	local state_param = req_state
	local filter_param = session.current_filter

	if req_state == "TEMPLATES" then
		state_param = "ARCHIVED"
		filter_param = template_filter(session.current_filter)
	end

	if opts.append then
		table.insert(session.page_history, {
			memos_count = #session.memos_cache,
			page_token = session.current_page_token,
		})
	else
		session.page_history = {}
	end

	session.main_list_fetching = true
	session:set_refresh_state("refreshing")

	ctx.api:list_memos({
		page_size = ctx.config.page_size,
		page_token = opts.page_token,
		state = state_param,
		order_by = ctx.config.list_order_by,
		filter = filter_param,
	}, function(data, err)
		vim.schedule(function()
			session.main_list_fetching = false
			if not data then
				if session.current_list_state == req_state then
					session:set_refresh_state("failed", err)
					if opts.append then
						table.remove(session.page_history)
					end
					if #session.memos_cache > 0 then
						session:render_cached_memos()
					end
				end
				vim.notify("Failed to fetch memos: " .. tostring(err), vim.log.levels.ERROR)
				return
			end

			local is_append = opts.append == true
			if session.current_list_state == req_state then
				session:mark_refresh_success()
				M.render_memos(session, data, is_append)
			else
				local c = session.caches[req_state]
				if not is_append then
					c.memos = data.memos or {}
					c.last_refresh_at = os.time()
					c.page_history = {}
				else
					c.memos = c.memos or {}
					vim.list_extend(c.memos, data.memos or {})
				end
				c.page_token = data.next_page_token or ""
			end
		end)
	end)
end

function M.search_memos(session, ctx)
	vim.ui.input({ prompt = "Search memos (empty clears): " }, function(input)
		if input == nil then
			return
		end

		local next_filter = ctx.build_search_filter(input)
		session.current_filter = next_filter
		session.memos_cache = {}
		session.list_items = {}
		session.current_page_token = nil
		session:mark_relation_index_dirty()
		session.list_refresh_state = "idle"
		session.last_refresh_error = nil
		ctx.redraw_status()
		ctx.focus_list_buf()

		local entity_name = session.current_list_state == "TEMPLATES" and "templates" or "memos"
		local loading_text = next_filter == "" and ("Loading " .. entity_name .. "...") or ("Loading filtered " .. entity_name .. "...")
		session:set_list_lines({ loading_text })

		if next_filter == "" then
			vim.notify(session.current_list_state == "TEMPLATES" and "Templates search cleared." or "Memos search cleared.")
		else
			vim.notify(session.current_list_state == "TEMPLATES" and "Templates search filter applied." or "Memos search filter applied.")
		end
		M.fetch_memos(session, ctx, { append = false })
	end)
end

function M.toggle_archive_view(session, ctx)
	M.save_current_state_cache(session)
	local next_state = session.current_list_state == "ARCHIVED" and "NORMAL" or "ARCHIVED"
	M.load_state_cache(session, next_state)
	ctx.redraw_status()
	ctx.focus_list_buf()
	ctx.show_memos_list()
end

function M.load_next_page(session)
	if not session.current_page_token or session.current_page_token == "" then
		vim.notify("No more pages to load.", vim.log.levels.INFO)
		return
	end
	session:fetch_memos({
		page_token = session.current_page_token,
		append = true,
	})
end

function M.load_prev_page(session)
	if not session.page_history or #session.page_history == 0 then
		vim.notify("Already at the first page.", vim.log.levels.INFO)
		return
	end
	local prev = table.remove(session.page_history)
	while #session.memos_cache > prev.memos_count do
		table.remove(session.memos_cache)
	end
	session.current_page_token = prev.page_token
	session:mark_relation_index_dirty()
	session:set_refresh_state("idle")
	session:render_cached_memos()
	vim.notify("Returned to previous page view.")
end

return M
