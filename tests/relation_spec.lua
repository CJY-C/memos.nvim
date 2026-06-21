local memos = require("memos")
local ui = require("memos.ui")

describe("memos.ui relations", function()
	local buf

	before_each(function()
		buf = vim.api.nvim_create_buf(false, true)
		memos.setup({
			host = "http://localhost:5230",
			token = "fake-token",
			keymaps = {
				list = {
					toggle_expand = "<Tab>",
					toggle_expand_incoming = "<S-Tab>",
				}
			}
		})
	end)

	after_each(function()
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
	end)

	it("should calculate incoming and outgoing counts and right align indicators", function()
		ui.bind_list_keymaps(buf)
		local s = ui.get_session(buf)
		assert.is_not_nil(s)

		-- Setup memo cache with relations
		s.memos_cache = {
			{
				name = "memos/1",
				id = 1,
				content = "Parent memo",
				update_time = "2026-06-21T10:00:00Z",
				relations = {
					{ memo = "memos/1", relatedMemo = "memos/2", type = "REFERENCE" },
					{ memo = "memos/3", relatedMemo = "memos/1", type = "REFERENCE" }
				}
			},
			{
				name = "memos/2",
				id = 2,
				content = "Child memo",
				update_time = "2026-06-21T10:00:00Z"
			}
		}

		-- Outgoing should be 1 (memos/2), Incoming should be 1 (memos/3)
		local formatted, hls = s:format_memo_line(1, s.memos_cache[1])
		assert.is_true(formatted:match("%[→ 1, ← 1%]") ~= nil)
		assert.are.same(2, #hls)

		-- Verify outgoing highlight group matches
		assert.are.same("MemosOutgoingLink", hls[1].hl_group)
		assert.are.same("MemosIncomingLink", hls[2].hl_group)
	end)

	it("should toggle outgoing and incoming expansion and render child items", function()
		ui.bind_list_keymaps(buf)
		local s = ui.get_session(buf)

		s.memos_cache = {
			{
				name = "memos/1",
				id = 1,
				content = "Parent memo",
				relations = {
					{ memo = "memos/1", relatedMemo = "memos/2", type = "REFERENCE" }
				}
			},
			{
				name = "memos/2",
				id = 2,
				content = "Child memo",
				relations = {}
			}
		}

		-- Initially not expanded
		assert.is_nil(s.expanded_outgoing["memos/1"])
		assert.is_nil(s.expanded_incoming["memos/1"])

		-- Set current buffer to test cursor positioning
		vim.api.nvim_set_current_buf(buf)
		s:render_cached_memos()
		vim.wait(500, function()
			return s.list_items[2] ~= nil
		end)

		-- Verify item mapping for memo
		local first_item = s.list_items[2] -- Line 1 is header, Line 2 is memo
		assert.is_not_nil(first_item)
		assert.are.same("memo", first_item.kind)
		assert.are.same(1, first_item.index)

		-- Set cursor to line 2 (the parent memo)
		vim.api.nvim_win_set_cursor(0, { 2, 0 })

		-- Toggle outgoing expansion
		s:toggle_expand_outgoing()
		assert.is_true(s.expanded_outgoing["memos/1"])

		-- Re-render and check that child memo line is drawn below
		s:render_cached_memos()
		vim.wait(500, function()
			return s.list_items[3] and s.list_items[3].kind == "relation"
		end)

		-- Verify list_items map shows the relation below it (Line 3)
		local rel_item = s.list_items[3]
		assert.is_not_nil(rel_item)
		assert.are.same("relation", rel_item.kind)
		assert.are.same("outgoing", rel_item.relation_type)
		assert.are.same("memos/2", rel_item.memo.name)

		-- Verify get_memo_from_item resolves correctly
		local resolved = s:get_memo_from_item(rel_item)
		assert.is_not_nil(resolved)
		assert.are.same("memos/2", resolved.name)
	end)
end)
