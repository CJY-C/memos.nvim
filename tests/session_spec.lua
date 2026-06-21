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
end)
