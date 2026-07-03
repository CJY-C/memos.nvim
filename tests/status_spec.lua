local status = require("memos.ui.status")

local function session(overrides)
	return vim.tbl_extend("force", {
		list_refresh_state = "idle",
		last_refresh_at = nil,
		last_refresh_error = nil,
		main_list_fetching = false,
		in_flight_relations = {},
	}, overrides or {})
end

describe("memos.ui.status", function()
	it("should return idle public status when no session is active", function()
		assert.are.same({
			state = "idle",
			text = "",
			last_refresh_at = nil,
			last_error = nil,
		}, status.public_status(nil))
		assert.are.same("", status.public_text(nil, false))
	end)

	it("should set refreshing state and public/list text", function()
		local s = session()

		status.set_refresh_state(s, "refreshing")

		assert.are.same("refreshing", s.list_refresh_state)
		assert.are.same("Memos refreshing", status.public_text(s, false))
		assert.are.same("Refreshing...", status.list_text(s))
	end)

	it("should keep refreshing while main list fetch is active", function()
		local s = session({
			main_list_fetching = true,
			list_refresh_state = "refreshing",
		})

		status.set_refresh_state(s, "idle")

		assert.are.same("refreshing", s.list_refresh_state)
	end)

	it("should keep refreshing while relation fetches are active", function()
		local s = session({
			in_flight_relations = {
				["memos/2"] = true,
			},
			list_refresh_state = "refreshing",
		})

		status.set_refresh_state(s, "idle")

		assert.are.same("refreshing", s.list_refresh_state)
	end)

	it("should keep refreshing while relation fetches are queued", function()
		local s = session({
			pending_relations = { "memos/2" },
			list_refresh_state = "refreshing",
		})

		status.set_refresh_state(s, "idle")

		assert.are.same("refreshing", s.list_refresh_state)
	end)

	it("should store failed errors and clear them on idle", function()
		local s = session()

		status.set_refresh_state(s, "failed", "network down")
		assert.are.same("failed", s.list_refresh_state)
		assert.are.same("network down", s.last_refresh_error)
		assert.are.same("Memos failed", status.public_text(s, false))
		assert.are.same("Refresh failed", status.list_text(s))

		status.set_refresh_state(s, "idle")
		assert.are.same("idle", s.list_refresh_state)
		assert.is_nil(s.last_refresh_error)
	end)

	it("should format public and list updated text", function()
		local value = 3600
		local hh_mm = os.date("%H:%M", value)
		local hh_mm_ss = os.date("%H:%M:%S", value)
		local s = session({
			last_refresh_at = value,
		})

		assert.are.same("Memos updated " .. hh_mm, status.public_text(s, false))
		assert.are.same("Memos updated " .. hh_mm_ss, status.public_text(s, true))
		assert.are.same("Updated " .. hh_mm_ss, status.list_text(s))
	end)

	it("should mark refresh success and keep active fetch coordination", function()
		local s = session({
			main_list_fetching = true,
			list_refresh_state = "refreshing",
		})

		status.mark_refresh_success(s)

		assert.is_not_nil(s.last_refresh_at)
		assert.are.same("refreshing", s.list_refresh_state)
	end)
end)
