local memos = require("memos")
local ui = require("memos.ui")

describe("memos.ui memo actions", function()
	local buf

	local function setup_session(memo, state)
		ui.bind_list_keymaps(buf)
		local s = ui.get_session(buf)
		s.current_list_state = state or "NORMAL"
		s.memos_cache = { memo }
		s.list_items = {
			{ kind = "header" },
			{ kind = "memo", index = 1 },
		}
		vim.api.nvim_set_current_buf(buf)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "header", "memo" })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		return s
	end

	before_each(function()
		buf = vim.api.nvim_create_buf(false, true)
		memos.setup({
			host = "http://localhost:5230",
			token = "fake-token",
		})
	end)

	after_each(function()
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
	end)

	it("should toggle pin and refresh the list", function()
		local api = require("memos.api")
		local old_update = api.Client.update_memo_pinned
		local memo = { name = "memos/1", content = "Pinned memo", pinned = false }
		local s = setup_session(memo)

		api.Client.update_memo_pinned = function(self_api, memo_name, pinned, callback)
			assert.are.same("memos/1", memo_name)
			assert.is_true(pinned)
			callback(true, nil)
		end

		local refreshed = false
		s.refresh_list_silently = function()
			refreshed = true
		end

		s:toggle_selected_memo_pin()

		vim.wait(500, function()
			return refreshed
		end)

		api.Client.update_memo_pinned = old_update

		assert.is_true(memo.pinned)
		assert.is_true(refreshed)
	end)

	it("should archive selected memos by removing them from the active cache", function()
		local api = require("memos.api")
		local old_update = api.Client.update_memo_state
		local memo = { name = "memos/1", content = "Archive memo" }
		local s = setup_session(memo)

		api.Client.update_memo_state = function(self_api, memo_name, state, callback)
			assert.are.same("memos/1", memo_name)
			assert.are.same("ARCHIVED", state)
			callback(true, nil)
		end

		local refreshed = false
		s.refresh_list_silently = function()
			refreshed = true
		end

		s:archive_selected_memo()

		vim.wait(500, function()
			return refreshed
		end)

		api.Client.update_memo_state = old_update

		assert.are.same(0, #s.memos_cache)
		assert.is_true(refreshed)
	end)

	it("should delete selected memos after confirmation", function()
		local api = require("memos.api")
		local old_select = vim.ui.select
		local old_delete = api.Client.delete_memo
		local memo = { name = "memos/1", content = "Delete title\nbody" }
		local s = setup_session(memo)

		vim.ui.select = function(items, opts, on_choice)
			assert.are.same("memos_delete", opts.kind)
			assert.are.same("Delete memo: Delete title", opts.prompt)
			on_choice("Delete")
		end
		api.Client.delete_memo = function(self_api, memo_name, callback)
			assert.are.same("memos/1", memo_name)
			callback(true, nil)
		end

		local refreshed = false
		s.refresh_list_silently = function()
			refreshed = true
		end

		s:delete_selected_memo()

		vim.wait(500, function()
			return refreshed
		end)

		vim.ui.select = old_select
		api.Client.delete_memo = old_delete

		assert.are.same(0, #s.memos_cache)
		assert.is_true(refreshed)
	end)

	it("should edit memo visibility after selection", function()
		local api = require("memos.api")
		local old_select = vim.ui.select
		local old_update = api.Client.update_memo_visibility
		local memo = { name = "memos/1", content = "Visibility memo", visibility = "PRIVATE" }
		local s = setup_session(memo)

		vim.ui.select = function(items, opts, on_choice)
			assert.are.same("memos_visibility", opts.kind)
			on_choice("PUBLIC")
		end
		api.Client.update_memo_visibility = function(self_api, memo_name, visibility, callback)
			assert.are.same("memos/1", memo_name)
			assert.are.same("PUBLIC", visibility)
			callback(true, nil)
		end

		local refreshed = false
		s.refresh_list_silently = function()
			refreshed = true
		end

		s:edit_selected_memo_visibility()

		vim.wait(500, function()
			return refreshed
		end)

		vim.ui.select = old_select
		api.Client.update_memo_visibility = old_update

		assert.are.same("PUBLIC", memo.visibility)
		assert.is_true(refreshed)
	end)

	it("should not send empty create_time updates", function()
		local api = require("memos.api")
		local old_input = vim.ui.input
		local old_update = api.Client.update_memo_create_time
		local memo = { name = "memos/1", content = "Time memo", create_time = "2026-06-28T00:00:00Z" }
		local s = setup_session(memo)

		vim.ui.input = function(opts, on_confirm)
			assert.are.same("Memo create_time:", opts.prompt)
			on_confirm("  ")
		end
		local api_called = false
		api.Client.update_memo_create_time = function()
			api_called = true
		end

		s:edit_selected_memo_create_time()

		vim.ui.input = old_input
		api.Client.update_memo_create_time = old_update

		assert.is_false(api_called)
		assert.are.same("2026-06-28T00:00:00Z", memo.create_time)
	end)

	it("should update create_time after valid input", function()
		local api = require("memos.api")
		local old_input = vim.ui.input
		local old_update = api.Client.update_memo_create_time
		local memo = { name = "memos/1", content = "Time memo", create_time = "2026-06-28T00:00:00Z" }
		local s = setup_session(memo)
		local next_time = "2026-06-29T01:02:03Z"

		vim.ui.input = function(opts, on_confirm)
			assert.are.same(memo.create_time, opts.default)
			on_confirm(next_time)
		end
		api.Client.update_memo_create_time = function(self_api, memo_name, create_time, callback)
			assert.are.same("memos/1", memo_name)
			assert.are.same(next_time, create_time)
			callback(true, nil)
		end

		local refreshed = false
		s.refresh_list_silently = function()
			refreshed = true
		end

		s:edit_selected_memo_create_time()

		vim.wait(500, function()
			return refreshed
		end)

		vim.ui.input = old_input
		api.Client.update_memo_create_time = old_update

		assert.are.same(next_time, memo.create_time)
		assert.is_true(refreshed)
	end)

	it("should block ordinary memo requests in template view", function()
		local api = require("memos.api")
		local old_update = api.Client.update_memo_pinned
		local memo = { name = "memos/1", content = "#type/template\nTemplate" }
		local s = setup_session(memo, "TEMPLATES")

		local api_called = false
		api.Client.update_memo_pinned = function()
			api_called = true
		end

		s:toggle_selected_memo_pin()

		api.Client.update_memo_pinned = old_update

		assert.is_false(api_called)
	end)
end)
