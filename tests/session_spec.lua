local memos = require("memos")
local ui = require("memos.ui")

describe("memos.ui ListSession encapsulation", function()
	local buf1, buf2

	before_each(function()
		buf1 = vim.api.nvim_create_buf(false, true)
		buf2 = vim.api.nvim_create_buf(false, true)
		memos.setup({
			host = "http://localhost:5230",
			token = "fake-token",
		})
	end)

	after_each(function()
		if vim.api.nvim_buf_is_valid(buf1) then
			vim.api.nvim_buf_delete(buf1, { force = true })
		end
		if vim.api.nvim_buf_is_valid(buf2) then
			vim.api.nvim_buf_delete(buf2, { force = true })
		end
	end)

	it("should allocate distinct sessions and isolate state", function()
		ui.bind_list_keymaps(buf1)
		ui.bind_list_keymaps(buf2)

		local s1 = ui.get_session(buf1)
		local s2 = ui.get_session(buf2)

		assert.is_not_nil(s1)
		assert.is_not_nil(s2)
		assert.is_not_equal(s1, s2)

		-- Populate cache in s1 and verify s2 is empty
		s1.memos_cache = { { name = "memo-1", content = "hello" } }
		s2.memos_cache = {}

		assert.are_not.same(s1.memos_cache, s2.memos_cache)
		assert.are.same(1, #s1.memos_cache)
		assert.are.same(0, #s2.memos_cache)
	end)

	it("should select correct active session based on current buffer context", function()
		ui.bind_list_keymaps(buf1)
		ui.bind_list_keymaps(buf2)

		local s1 = ui.get_session(buf1)

		-- Switch context to buf1
		vim.api.nvim_set_current_buf(buf1)
		s1.memos_cache = { { name = "memo-1", content = "hello" } }

		-- Trigger UI remove action (which operates on active session)
		ui.remove_cached_memo_at(1)

		assert.are.same(0, #s1.memos_cache)
	end)

	it("should run show_memos_list and trigger api:list_memos successfully", function()
		local list_called = false
		local api_mod = require("memos.api")
		local original_list_memos = api_mod.Client.list_memos
		
		api_mod.Client.list_memos = function(self, opts, callback)
			list_called = true
			callback({
				memos = {
					{ name = "memo-1", content = "test memo content" }
				},
				next_page_token = ""
			}, nil)
		end

		ui.show_memos_list()

		local s = ui.get_session(vim.api.nvim_get_current_buf())
		vim.wait(1000, function()
			return #s.memos_cache > 0
		end)

		assert.is_true(list_called, "API list_memos was not invoked")
		assert.are.same(1, #s.memos_cache)

		-- Restore original
		api_mod.Client.list_memos = original_list_memos
	end)

	it("should open edit buffer via pure Lua split/vsplit window API without vim.cmd split", function()
		local original_open_win = vim.api.nvim_open_win
		local open_win_opts = nil
		
		vim.api.nvim_open_win = function(buf, enter, opts)
			open_win_opts = opts
			return original_open_win(buf, enter, opts)
		end

		local buf = ui.open_edit_buffer("test text content", "vsplit")
		
		assert.is_not_nil(open_win_opts)
		assert.are.same("right", open_win_opts.split)
		
		-- Delete the created buffer
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
		
		-- Restore
		vim.api.nvim_open_win = original_open_win
	end)

	it("should track pagination history and allow returning to previous page view", function()
		ui.bind_list_keymaps(buf1)
		local s = ui.get_session(buf1)
		s.memos_cache = { { name = "memos/1", content = "one" } }
		s.current_page_token = "token-1"

		local api_mod = require("memos.api")
		local original_list_memos = api_mod.Client.list_memos
		
		api_mod.Client.list_memos = function(self, opts, callback)
			callback({
				memos = {
					{ name = "memos/2", content = "two" }
				},
				next_page_token = "token-2"
			}, nil)
		end

		s:fetch_memos({ append = true, page_token = "token-1" })
		
		vim.wait(1000, function()
			return #s.memos_cache == 2
		end)
		
		assert.are.same(2, #s.memos_cache)
		assert.are.same("token-2", s.current_page_token)
		assert.are.same(1, #s.page_history)
		assert.are.same(1, s.page_history[1].memos_count)
		assert.are.same("token-1", s.page_history[1].page_token)

		-- Go back to previous page
		s:load_prev_page()

		assert.are.same(1, #s.memos_cache)
		assert.are.same("memos/1", s.memos_cache[1].name)
		assert.are.same("token-1", s.current_page_token)
		assert.are.same(0, #s.page_history)

		api_mod.Client.list_memos = original_list_memos
	end)
end)
