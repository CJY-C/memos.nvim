local memos = require("memos")
local ui = require("memos.ui")

describe("memos.ui relations", function()
	local buf
	local original_getreg

	before_each(function()
		original_getreg = vim.fn.getreg
		vim.fn.getreg = function()
			return ""
		end
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
		vim.fn.getreg = original_getreg
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

	it("should index relation names across schemas without duplicate or nil id matches", function()
		ui.bind_list_keymaps(buf)
		local s = ui.get_session(buf)
		assert.is_not_nil(s)

		s.memos_cache = {
			{
				name = "memos/1",
				content = "Parent memo",
				relations = {
					{ memo = { name = "memos/1" }, relatedMemo = { name = "memos/2" }, type = "REFERENCE" },
					{ memo = "memos/1", relatedMemo = "memos/2", type = "REFERENCE" },
				}
			},
			{
				name = "memos/2",
				content = "Child memo",
				relations = {
					{ memo = { name = "memos/3" }, relatedMemo = { name = "memos/2" }, type = "REFERENCE" },
				}
			},
			{
				name = "memos/3",
				content = "Sibling memo",
			}
		}
		s:mark_relation_index_dirty()

		local outgoing = s:get_outgoing_relation_names(s.memos_cache[1])
		local incoming = s:get_incoming_relation_names(s.memos_cache[2])
		local formatted = s:format_memo_line(3, s.memos_cache[3])

		assert.are.same({ "memos/2" }, outgoing)
		assert.are.same({ "memos/1", "memos/3" }, incoming)
		assert.is_nil(formatted:match("←"))
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

	it("should parse clipboard registry, display selection menu, and update cache via api:set_memo_relations", function()
		local api = require("memos.api")
		local old_getreg = vim.fn.getreg
		local old_select = vim.ui.select
		local old_set_memo_relations = api.Client.set_memo_relations

		ui.bind_list_keymaps(buf)
		local s = ui.get_session(buf)

		-- Setup memo cache with relations
		s.memos_cache = {
			{
				name = "memos/1",
				id = 1,
				content = "Memo 1",
				relations = {
					{ memo = "memos/1", relatedMemo = "memos/2", type = "REFERENCE" }
				}
			}
		}

		vim.api.nvim_set_current_buf(buf)
		s:render_cached_memos()
		vim.wait(500, function()
			return s.list_items[2] ~= nil
		end)
		vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- Select Memo 1

		local select_called = false
		local set_relations_called = false
		local api_relations_arg = nil

		-- Mock vim.fn.getreg to return a memo ID
		vim.fn.getreg = function(reg)
			if reg == "+" then
				return "memos/3"
			end
			return ""
		end

		-- Mock vim.ui.select to choose clipboard option
		vim.ui.select = function(items, opts, on_choice)
			select_called = true
			assert.are.same("Select memo to relate (or input ID):", opts.prompt)
			assert.are.same("[Use Clipboard: memos/3]", items[1])
			on_choice("[Use Clipboard: memos/3]")
		end

		-- Mock api:set_memo_relations
		api.Client.set_memo_relations = function(self_api, memo_name, relations, callback)
			assert.are.same("memos/1", memo_name)
			set_relations_called = true
			api_relations_arg = relations
			callback(true, nil)
		end

		-- Mock refresh_list_silently
		local refresh_called = false
		s.refresh_list_silently = function()
			refresh_called = true
		end

		-- Invoke add_relation
		s:add_relation()

		vim.wait(500, function()
			return refresh_called
		end)

		-- Restore mocks
		vim.fn.getreg = old_getreg
		vim.ui.select = old_select
		api.Client.set_memo_relations = old_set_memo_relations

		-- Assertions
		assert.is_true(select_called)
		assert.is_true(set_relations_called)
		assert.is_true(refresh_called)

		-- Relations should contain the old relation to memos/2 AND the new relation to memos/3
		assert.are.same(2, #api_relations_arg)
		assert.are.same("memos/1", api_relations_arg[1].memo.name)
		assert.are.same("memos/2", api_relations_arg[1].relatedMemo.name)
		assert.are.same("memos/1", api_relations_arg[2].memo.name)
		assert.are.same("memos/3", api_relations_arg[2].relatedMemo.name)

		-- Verify local cache is updated immediately
		assert.are.same(2, #s.memos_cache[1].relations)
		assert.are.same("memos/3", s.memos_cache[1].relations[2].relatedMemo.name)
	end)

	it("should show refreshing status while fetch_missing_relations is loading in background", function()
		local api = require("memos.api")
		local old_get_memo = api.Client.get_memo

		ui.bind_list_keymaps(buf)
		local s = ui.get_session(buf)
		s.memos_cache = {}

		local get_memo_callback = nil
		api.Client.get_memo = function(self_api, name, callback)
			get_memo_callback = callback
		end

		-- Verify initial state
		assert.are.same("idle", s.list_refresh_state)

		-- Trigger fetching a missing relation
		s:fetch_missing_relations({ "memos/99" })

		-- Verify it transitions to refreshing status
		assert.are.same("refreshing", s.list_refresh_state)
		assert.is_not_nil(get_memo_callback)

		-- Resolve the fetch
		get_memo_callback({
			name = "memos/99",
			content = "Resolved Memo Content",
			state = "NORMAL"
		}, nil)

		-- Allow scheduled code to run
		vim.wait(500, function()
			return s.list_refresh_state == "idle"
		end)

		-- Restore mocks
		api.Client.get_memo = old_get_memo

		-- Verify final state
		assert.are.same("idle", s.list_refresh_state)
		assert.are.same("Resolved Memo Content", s.relation_details_cache["memos/99"].content)
	end)

	it("should unlink selected relation when D is pressed on relation line", function()
		local api = require("memos.api")
		local old_select = vim.ui.select
		local old_set_memo_relations = api.Client.set_memo_relations

		ui.bind_list_keymaps(buf)
		local s = ui.get_session(buf)

		-- Setup memo cache with a parent and relation
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
				content = "Child memo"
			}
		}

		s.expanded_outgoing["memos/1"] = true
		s.relation_details_cache["memos/2"] = s.memos_cache[2]

		vim.api.nvim_set_current_buf(buf)
		s:render_cached_memos()
		vim.wait(500, function()
			return s.list_items[3] ~= nil
		end)

		-- Cursor at line 3 (the relation child: memos/2)
		vim.api.nvim_win_set_cursor(0, { 3, 0 })

		local select_called = false
		local select_prompt = nil
		local set_relations_called = false
		local api_relations_arg = nil

		-- Mock vim.ui.select to simulate selecting "Unlink"
		vim.ui.select = function(items, opts, on_choice)
			select_called = true
			select_prompt = opts.prompt
			on_choice("Unlink")
		end

		-- Mock api:set_memo_relations
		api.Client.set_memo_relations = function(self_api, memo_name, relations, callback)
			assert.are.same("memos/1", memo_name)
			set_relations_called = true
			api_relations_arg = relations
			callback(true, nil)
		end

		-- Mock refresh_list_silently
		local refresh_called = false
		s.refresh_list_silently = function()
			refresh_called = true
		end

		-- Invoke delete_selected_memo on relation line
		s:delete_selected_memo()

		vim.wait(500, function()
			return refresh_called
		end)

		-- Restore mocks
		vim.ui.select = old_select
		api.Client.set_memo_relations = old_set_memo_relations

		-- Assertions
		assert.is_true(select_called)
		assert.are.same("Unlink relation: memos/1 -> memos/2?", select_prompt)
		assert.is_true(set_relations_called)
		assert.is_true(refresh_called)

		-- Remaining relations should be empty
		assert.are.same(0, #api_relations_arg)
		assert.are.same(0, #s.memos_cache[1].relations)
	end)

	it("should allow fuzzy selecting a cached memo option directly", function()
		local api = require("memos.api")
		local old_select = vim.ui.select
		local old_set_memo_relations = api.Client.set_memo_relations

		ui.bind_list_keymaps(buf)
		local s = ui.get_session(buf)

		-- Setup memo cache with a parent and another memo
		s.memos_cache = {
			{
				name = "memos/1",
				id = 1,
				content = "Parent memo",
				relations = {}
			},
			{
				name = "memos/2",
				id = 2,
				content = "Fuzzy target memo"
			}
		}

		vim.api.nvim_set_current_buf(buf)
		s:render_cached_memos()
		vim.wait(500, function()
			return s.list_items[2] ~= nil
		end)
		vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- Select Memo 1

		local select_called = false
		local set_relations_called = false
		local api_relations_arg = nil

		-- Mock vim.ui.select to choose the cached memo choice
		vim.ui.select = function(items, opts, on_choice)
			select_called = true
			-- The second memo in cache should be formatted as a choice
			local expected_choice = "memos/2 - Fuzzy target memo"
			local found = false
			for _, item in ipairs(items) do
				if item == expected_choice then
					found = true
				end
			end
			assert.is_true(found)
			on_choice(expected_choice)
		end

		-- Mock api:set_memo_relations
		api.Client.set_memo_relations = function(self_api, memo_name, relations, callback)
			assert.are.same("memos/1", memo_name)
			set_relations_called = true
			api_relations_arg = relations
			callback(true, nil)
		end

		local refresh_called = false
		s.refresh_list_silently = function()
			refresh_called = true
		end

		s:add_relation()

		vim.wait(500, function()
			return refresh_called
		end)

		vim.ui.select = old_select
		api.Client.set_memo_relations = old_set_memo_relations

		assert.is_true(select_called)
		assert.is_true(set_relations_called)
		assert.is_true(refresh_called)
		assert.are.same(1, #api_relations_arg)
		assert.are.same("memos/2", api_relations_arg[1].relatedMemo.name)
	end)

	it("should ignore pinned priority when ordering relation picker candidates", function()
		local old_select = vim.ui.select

		ui.bind_list_keymaps(buf)
		local s = ui.get_session(buf)

		s.memos_cache = {
			{
				name = "memos/1",
				content = "Current memo",
				update_time = "2026-06-21T10:00:00Z",
				relations = {}
			},
			{
				name = "memos/2",
				content = "Pinned older memo",
				pinned = true,
				update_time = "2026-06-20T10:00:00Z",
				create_time = "2026-06-19T10:00:00Z"
			},
			{
				name = "memos/3",
				content = "Unpinned newer memo",
				pinned = false,
				update_time = "2026-06-22T10:00:00Z",
				create_time = "2026-06-21T10:00:00Z"
			},
			{
				name = "memos/4",
				content = "Same update newer create",
				pinned = false,
				update_time = "2026-06-20T10:00:00Z",
				create_time = "2026-06-20T10:00:00Z"
			}
		}

		vim.fn.getreg = function(reg)
			if reg == "+" then
				return "memos/99"
			end
			return ""
		end

		vim.api.nvim_set_current_buf(buf)
		s:render_cached_memos()
		vim.wait(500, function()
			return s.list_items[2] ~= nil
		end)
		vim.api.nvim_win_set_cursor(0, { 2, 0 })

		local select_called = false
		vim.ui.select = function(items, opts, on_choice)
			select_called = true
			assert.are.same("memos_relation", opts.kind)
			assert.are.same("[Use Clipboard: memos/99]", items[1])
			assert.are.same("memos/3 - Unpinned newer memo", items[2])
			assert.are.same("memos/4 - Same update newer create", items[3])
			assert.are.same("memos/2 - Pinned older memo", items[4])
			assert.are.same("[Input memo ID manually]", items[#items])
			on_choice(nil)
		end

		s:add_relation()

		vim.ui.select = old_select

		assert.is_true(select_called)
	end)

	it("should fallback to manual input prompt if manual choice is selected", function()
		local api = require("memos.api")
		local old_select = vim.ui.select
		local old_input = vim.fn.input
		local old_set_memo_relations = api.Client.set_memo_relations

		ui.bind_list_keymaps(buf)
		local s = ui.get_session(buf)

		s.memos_cache = {
			{
				name = "memos/1",
				id = 1,
				content = "Parent memo",
				relations = {}
			}
		}

		vim.api.nvim_set_current_buf(buf)
		s:render_cached_memos()
		vim.wait(500, function()
			return s.list_items[2] ~= nil
		end)
		vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- Select Memo 1

		local select_called = false
		local input_called = false
		local set_relations_called = false
		local api_relations_arg = nil

		vim.ui.select = function(items, opts, on_choice)
			select_called = true
			-- Manual input should be at the bottom
			assert.are.same("[Input memo ID manually]", items[#items])
			on_choice("[Input memo ID manually]")
		end

		vim.fn.input = function(prompt, default)
			input_called = true
			assert.are.same("Add relation to target memo ID: ", prompt)
			return "memos/99"
		end

		api.Client.set_memo_relations = function(self_api, memo_name, relations, callback)
			set_relations_called = true
			api_relations_arg = relations
			callback(true, nil)
		end

		local refresh_called = false
		s.refresh_list_silently = function()
			refresh_called = true
		end

		s:add_relation()

		vim.wait(500, function()
			return refresh_called
		end)

		vim.ui.select = old_select
		vim.fn.input = old_input
		api.Client.set_memo_relations = old_set_memo_relations

		assert.is_true(select_called)
		assert.is_true(input_called)
		assert.is_true(set_relations_called)
		assert.is_true(refresh_called)
		assert.are.same(1, #api_relations_arg)
		assert.are.same("memos/99", api_relations_arg[1].relatedMemo.name)
	end)

	it("should support multi-selection linking using Telescope", function()
		local api = require("memos.api")
		local old_set_memo_relations = api.Client.set_memo_relations

		ui.bind_list_keymaps(buf)
		local s = ui.get_session(buf)

		s.memos_cache = {
			{
				name = "memos/1",
				id = 1,
				content = "Memo 1",
				relations = {}
			},
			{
				name = "memos/2",
				id = 2,
				content = "Memo 2",
				relations = {}
			},
			{
				name = "memos/3",
				id = 3,
				content = "Memo 3",
				relations = {}
			}
		}

		vim.api.nvim_set_current_buf(buf)
		s:render_cached_memos()
		vim.wait(500, function()
			return s.list_items[2] ~= nil
		end)
		vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- Select Memo 1

		local mock_selections = {
			{ value = "memos/2 - Memo 2" },
			{ value = "memos/3 - Memo 3" }
		}

		package.loaded["telescope"] = {}
		package.loaded["telescope.pickers"] = {
			new = function(t, opts)
				return {
					find = function()
						local map_fn = function() end
						opts.attach_mappings(1, map_fn)
					end
				}
			end
		}
		package.loaded["telescope.finders"] = {
			new_table = function(opts) return opts end
		}
		package.loaded["telescope.config"] = {
			values = {
				generic_sorter = function() return {} end
			}
		}
		package.loaded["telescope.actions"] = {
			select_default = {
				replace = function(self_act, callback)
					callback()
				end
			},
			close = function(prompt_bufnr) end
		}
		package.loaded["telescope.actions.state"] = {
			get_current_picker = function(prompt_bufnr)
				return {
					get_multi_selection = function()
						return mock_selections
					end
				}
			end,
			get_selected_entry = function()
				return nil
			end
		}

		local set_relations_called = false
		local api_relations_arg = nil
		api.Client.set_memo_relations = function(self_api, memo_name, relations, callback)
			set_relations_called = true
			api_relations_arg = relations
			callback(true, nil)
		end

		local refresh_called = false
		s.refresh_list_silently = function()
			refresh_called = true
		end

		s:add_relation()

		vim.wait(500, function()
			return refresh_called
		end)

		-- Cleanup
		package.loaded["telescope"] = nil
		package.loaded["telescope.pickers"] = nil
		package.loaded["telescope.finders"] = nil
		package.loaded["telescope.config"] = nil
		package.loaded["telescope.actions"] = nil
		package.loaded["telescope.actions.state"] = nil
		api.Client.set_memo_relations = old_set_memo_relations

		assert.is_true(set_relations_called)
		assert.is_true(refresh_called)
		assert.are.same(2, #api_relations_arg)
		assert.are.same("memos/2", api_relations_arg[1].relatedMemo.name)
		assert.are.same("memos/3", api_relations_arg[2].relatedMemo.name)
	end)

	it("should fallback to single selection in Telescope if no items are marked", function()
		local api = require("memos.api")
		local old_set_memo_relations = api.Client.set_memo_relations

		ui.bind_list_keymaps(buf)
		local s = ui.get_session(buf)

		s.memos_cache = {
			{
				name = "memos/1",
				id = 1,
				content = "Memo 1",
				relations = {}
			},
			{
				name = "memos/2",
				id = 2,
				content = "Memo 2",
				relations = {}
			}
		}

		vim.api.nvim_set_current_buf(buf)
		s:render_cached_memos()
		vim.wait(500, function()
			return s.list_items[2] ~= nil
		end)
		vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- Select Memo 1

		local mock_selections = {}
		local mock_selected_entry = { value = "memos/2 - Memo 2" }

		package.loaded["telescope"] = {}
		package.loaded["telescope.pickers"] = {
			new = function(t, opts)
				return {
					find = function()
						local map_fn = function() end
						opts.attach_mappings(1, map_fn)
					end
				}
			end
		}
		package.loaded["telescope.finders"] = {
			new_table = function(opts) return opts end
		}
		package.loaded["telescope.config"] = {
			values = {
				generic_sorter = function() return {} end
			}
		}
		package.loaded["telescope.actions"] = {
			select_default = {
				replace = function(self_act, callback)
					callback()
				end
			},
			close = function(prompt_bufnr) end
		}
		package.loaded["telescope.actions.state"] = {
			get_current_picker = function(prompt_bufnr)
				return {
					get_multi_selection = function()
						return mock_selections
					end
				}
			end,
			get_selected_entry = function()
				return mock_selected_entry
			end
		}

		local set_relations_called = false
		local api_relations_arg = nil
		api.Client.set_memo_relations = function(self_api, memo_name, relations, callback)
			set_relations_called = true
			api_relations_arg = relations
			callback(true, nil)
		end

		local refresh_called = false
		s.refresh_list_silently = function()
			refresh_called = true
		end

		s:add_relation()

		vim.wait(500, function()
			return refresh_called
		end)

		-- Cleanup
		package.loaded["telescope"] = nil
		package.loaded["telescope.pickers"] = nil
		package.loaded["telescope.finders"] = nil
		package.loaded["telescope.config"] = nil
		package.loaded["telescope.actions"] = nil
		package.loaded["telescope.actions.state"] = nil
		api.Client.set_memo_relations = old_set_memo_relations

		assert.is_true(set_relations_called)
		assert.is_true(refresh_called)
		assert.are.same(1, #api_relations_arg)
		assert.are.same("memos/2", api_relations_arg[1].relatedMemo.name)
	end)

	it("should reject self-link additions without calling the api", function()
		local api = require("memos.api")
		local old_notify = vim.notify
		local old_set_memo_relations = api.Client.set_memo_relations

		ui.bind_list_keymaps(buf)
		local s = ui.get_session(buf)
		local memo = {
			name = "memos/1",
			id = 1,
			content = "Parent memo",
			relations = {},
		}

		local api_called = false
		local notified = nil
		api.Client.set_memo_relations = function()
			api_called = true
		end
		vim.notify = function(message, level)
			notified = message
		end

		s:add_multiple_relations(memo, { "memos/1" })

		vim.notify = old_notify
		api.Client.set_memo_relations = old_set_memo_relations

		assert.is_false(api_called)
		assert.are.same("Cannot create a relation to the same memo.", notified)
		assert.are.same(0, #memo.relations)
	end)

	it("should skip duplicate relation additions without calling the api", function()
		local api = require("memos.api")
		local old_notify = vim.notify
		local old_set_memo_relations = api.Client.set_memo_relations

		ui.bind_list_keymaps(buf)
		local s = ui.get_session(buf)
		local memo = {
			name = "memos/1",
			content = "Parent memo",
			relations = {
				{ memo = "memos/1", relatedMemo = "memos/2", type = "REFERENCE" },
			},
		}

		local api_called = false
		local notified = nil
		api.Client.set_memo_relations = function()
			api_called = true
		end
		vim.notify = function(message, level)
			notified = message
		end

		s:add_multiple_relations(memo, { "memos/2" })

		vim.notify = old_notify
		api.Client.set_memo_relations = old_set_memo_relations

		assert.is_false(api_called)
		assert.are.same("Relation(s) already exist.", notified)
		assert.are.same(1, #memo.relations)
	end)

	it("should unlink incoming loading relations from the source memo", function()
		local api = require("memos.api")
		local old_select = vim.ui.select
		local old_set_memo_relations = api.Client.set_memo_relations

		ui.bind_list_keymaps(buf)
		local s = ui.get_session(buf)
		s.memos_cache = {
			{
				name = "memos/1",
				content = "Parent memo",
			},
		}
		s.relation_details_cache["memos/9"] = {
			name = "memos/9",
			content = "Source memo",
			relations = {
				{ memo = "memos/9", relatedMemo = "memos/1", type = "REFERENCE" },
			},
		}

		local select_prompt = nil
		vim.ui.select = function(items, opts, on_choice)
			select_prompt = opts.prompt
			on_choice("Unlink")
		end

		local set_relations_called = false
		local api_relations_arg = nil
		api.Client.set_memo_relations = function(self_api, memo_name, relations, callback)
			assert.are.same("memos/9", memo_name)
			set_relations_called = true
			api_relations_arg = relations
			callback(true, nil)
		end

		local refresh_called = false
		s.refresh_list_silently = function()
			refresh_called = true
		end

		s:delete_selected_relation({
			kind = "relation_loading",
			parent_index = 1,
			relation_name = "memos/9",
			relation_type = "incoming",
		})

		vim.wait(500, function()
			return refresh_called
		end)

		vim.ui.select = old_select
		api.Client.set_memo_relations = old_set_memo_relations

		assert.are.same("Unlink relation: memos/9 -> memos/1?", select_prompt)
		assert.is_true(set_relations_called)
		assert.are.same(0, #api_relations_arg)
		assert.are.same(0, #s.relation_details_cache["memos/9"].relations)
	end)

	it("should not expand memo rows without relation names", function()
		ui.bind_list_keymaps(buf)
		local s = ui.get_session(buf)
		s.memos_cache = {
			{
				name = "memos/1",
				content = "Lonely memo",
				relations = {},
			},
		}
		s:mark_relation_index_dirty()
		s.list_items = {
			{ kind = "header" },
			{ kind = "memo", index = 1 },
		}
		vim.api.nvim_set_current_buf(buf)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "header", "memo" })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })

		s:toggle_expand_outgoing()
		s:toggle_expand_incoming()

		assert.is_nil(s.expanded_outgoing["memos/1"])
		assert.is_nil(s.expanded_incoming["memos/1"])
	end)

	it("should skip fetching relation details that are already cached", function()
		local api = require("memos.api")
		local old_get_memo = api.Client.get_memo

		ui.bind_list_keymaps(buf)
		local s = ui.get_session(buf)
		s.relation_details_cache["memos/99"] = {
			name = "memos/99",
			content = "Cached memo",
		}

		local called = false
		api.Client.get_memo = function()
			called = true
		end

		s:fetch_missing_relations({ "memos/99" })

		api.Client.get_memo = old_get_memo

		assert.is_false(called)
		assert.are.same("idle", s.list_refresh_state)
	end)

	it("should skip duplicate in-flight relation detail fetches", function()
		local api = require("memos.api")
		local old_get_memo = api.Client.get_memo

		ui.bind_list_keymaps(buf)
		local s = ui.get_session(buf)
		s.in_flight_relations["memos/99"] = true

		local called = false
		api.Client.get_memo = function()
			called = true
		end

		s:fetch_missing_relations({ "memos/99" })

		api.Client.get_memo = old_get_memo

		assert.is_false(called)
		assert.is_true(s.in_flight_relations["memos/99"])
	end)

	it("should limit queued relation detail fetch concurrency", function()
		local api = require("memos.api")
		local old_get_memo = api.Client.get_memo

		ui.bind_list_keymaps(buf)
		local s = ui.get_session(buf)
		local started = {}
		local callbacks = {}

		api.Client.get_memo = function(self_api, name, callback)
			table.insert(started, name)
			callbacks[name] = callback
		end

		s:fetch_missing_relations({ "memos/1", "memos/2", "memos/3", "memos/4", "memos/5" })

		assert.are.same({ "memos/1", "memos/2", "memos/3" }, started)
		assert.are.same(3, s.active_relation_fetches)
		assert.are.same(2, #s.pending_relations)
		assert.is_true(s.queued_relations["memos/4"])
		assert.is_true(s.queued_relations["memos/5"])
		assert.are.same("refreshing", s.list_refresh_state)

		callbacks["memos/1"]({
			name = "memos/1",
			content = "Relation 1",
			state = "NORMAL"
		}, nil)
		vim.wait(500, function()
			return #started == 4
		end)

		assert.are.same({ "memos/1", "memos/2", "memos/3", "memos/4" }, started)
		assert.are.same(3, s.active_relation_fetches)
		assert.are.same(1, #s.pending_relations)
		assert.are.same("refreshing", s.list_refresh_state)
		assert.are.same("Relation 1", s.relation_details_cache["memos/1"].content)

		callbacks["memos/2"]({ name = "memos/2", content = "Relation 2", state = "NORMAL" }, nil)
		callbacks["memos/3"]({ name = "memos/3", content = "Relation 3", state = "NORMAL" }, nil)
		callbacks["memos/4"]({ name = "memos/4", content = "Relation 4", state = "NORMAL" }, nil)
		vim.wait(500, function()
			return #started == 5 and callbacks["memos/5"] ~= nil
		end)
		callbacks["memos/5"]({ name = "memos/5", content = "Relation 5", state = "NORMAL" }, nil)
		vim.wait(500, function()
			return s.list_refresh_state == "idle"
		end)

		api.Client.get_memo = old_get_memo

		assert.are.same(0, s.active_relation_fetches)
		assert.are.same(0, #s.pending_relations)
		assert.are.same("Relation 5", s.relation_details_cache["memos/5"].content)
	end)

	it("should not queue duplicate relation detail fetches", function()
		local api = require("memos.api")
		local old_get_memo = api.Client.get_memo

		ui.bind_list_keymaps(buf)
		local s = ui.get_session(buf)
		s.relation_details_cache["memos/cached"] = {
			name = "memos/cached",
			content = "Cached memo",
		}
		s.in_flight_relations["memos/active"] = true

		local started = {}
		api.Client.get_memo = function(self_api, name, callback)
			table.insert(started, name)
		end

		s:fetch_missing_relations({
			"memos/cached",
			"memos/active",
			"memos/new",
			"memos/new",
			"memos/other",
		})

		api.Client.get_memo = old_get_memo

		assert.are.same({ "memos/new", "memos/other" }, started)
		assert.is_true(s.in_flight_relations["memos/active"])
		assert.is_true(s.in_flight_relations["memos/new"])
		assert.is_true(s.in_flight_relations["memos/other"])
	end)

	it("should cache a fallback relation memo when detail fetch fails", function()
		local api = require("memos.api")
		local old_get_memo = api.Client.get_memo

		ui.bind_list_keymaps(buf)
		local s = ui.get_session(buf)

		local render_called = false
		s.render_cached_memos = function()
			render_called = true
		end

		api.Client.get_memo = function(self_api, name, callback)
			callback(nil, "network down")
		end

		s:fetch_missing_relations({ "memos/99" })
		vim.wait(500, function()
			return render_called
		end)

		api.Client.get_memo = old_get_memo

		assert.is_nil(s.in_flight_relations["memos/99"])
		assert.are.same("idle", s.list_refresh_state)
		assert.are.same("Failed to load relation: network down", s.relation_details_cache["memos/99"].content)
	end)
end)
