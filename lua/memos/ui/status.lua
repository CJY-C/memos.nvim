local M = {}

local function format_time(value, with_seconds)
	if not value then
		return nil
	end
	return os.date(with_seconds and "%H:%M:%S" or "%H:%M", value)
end

local function has_active_fetches(session)
	if session.main_list_fetching then
		return true
	end
	for _, _ in pairs(session.in_flight_relations or {}) do
		return true
	end
	if (session.active_relation_fetches or 0) > 0 then
		return true
	end
	if #(session.pending_relations or {}) > 0 then
		return true
	end
	return false
end

function M.redraw()
	vim.schedule(function()
		pcall(vim.cmd, "redrawstatus")
	end)
end

function M.set_refresh_state(session, state, err)
	local target_state = state or "idle"
	if target_state == "idle" and has_active_fetches(session) then
		target_state = "refreshing"
	end
	session.list_refresh_state = target_state
	if session.list_refresh_state == "failed" then
		session.last_refresh_error = tostring(err or "Unknown error")
	elseif session.list_refresh_state == "idle" then
		session.last_refresh_error = nil
	end
	M.redraw()
end

function M.mark_refresh_success(session)
	session.last_refresh_at = os.time()
	M.set_refresh_state(session, "idle")
end

function M.public_text(session, with_seconds)
	if not session then
		return ""
	end
	local refreshed = format_time(session.last_refresh_at, with_seconds)
	if session.list_refresh_state == "refreshing" then
		return "Memos refreshing"
	end
	if session.list_refresh_state == "failed" then
		return "Memos failed"
	end
	if refreshed then
		return "Memos updated " .. refreshed
	end
	return ""
end

function M.public_status(session)
	if not session then
		return {
			state = "idle",
			text = "",
			last_refresh_at = nil,
			last_error = nil,
		}
	end
	return {
		state = session.list_refresh_state,
		text = M.public_text(session, true),
		last_refresh_at = session.last_refresh_at,
		last_error = session.last_refresh_error,
	}
end

function M.list_text(session)
	local refreshed = format_time(session.last_refresh_at, true)
	if session.list_refresh_state == "refreshing" then
		return "Refreshing..."
	end
	if session.list_refresh_state == "failed" then
		return "Refresh failed"
	end
	if refreshed then
		return "Updated " .. refreshed
	end
	return nil
end

return M
