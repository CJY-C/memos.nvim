local memos = require("memos")
local ui = require("memos.ui")

describe("memos.ui ListSession encapsulation", function()
	local buf1, buf2

	local function close_memos_floats()
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			local ok, value = pcall(vim.api.nvim_win_get_var, win, "memos_window")
			if ok and value == true and vim.api.nvim_win_is_valid(win) then
				pcall(vim.api.nvim_win_close, win, true)
			end
		end
	end

	before_each(function()
		buf1 = vim.api.nvim_create_buf(false, true)
		buf2 = vim.api.nvim_create_buf(false, true)
		memos.setup({
			host = "http://localhost:5230",
			token = "fake-token",
			template_tag = "type/template",
		})
	end)

	after_each(function()
		close_memos_floats()
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].memos_edit_buffer == true then
				pcall(vim.api.nvim_buf_delete, buf, { force = true })
			end
		end
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

	it("should resolve the current list item from the cursor line", function()
		ui.bind_list_keymaps(buf1)
		local s = ui.get_session(buf1)
		s.list_items = {
			{ kind = "header" },
			{ kind = "memo", index = 1 },
		}
		vim.api.nvim_set_current_buf(buf1)
		vim.api.nvim_buf_set_lines(buf1, 0, -1, false, { "header", "memo" })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })

		assert.are.same({ kind = "memo", index = 1 }, s:current_list_item())
	end)

	it("should resolve memo and relation items to memo objects", function()
		ui.bind_list_keymaps(buf1)
		local s = ui.get_session(buf1)
		local memo = { name = "memos/1", content = "memo" }
		local relation_memo = { name = "memos/2", content = "relation" }
		s.memos_cache = { memo }

		assert.are.same(memo, s:get_memo_from_item({ kind = "memo", index = 1 }))
		assert.are.same(relation_memo, s:get_memo_from_item({ kind = "relation", memo = relation_memo }))
		assert.is_nil(s:get_memo_from_item({ kind = "header" }))
		assert.is_nil(s:get_memo_from_item(nil))
	end)

	it("should remove a memo from cache and clear related selection state", function()
		ui.bind_list_keymaps(buf1)
		local s = ui.get_session(buf1)
		s.memos_cache = {
			{ name = "memos/1", content = "one" },
			{ name = "memos/2", content = "two" },
		}
		s.relation_details_cache["memos/1"] = { name = "memos/1" }
		s.expanded_outgoing["memos/1"] = true
		s.expanded_incoming["memos/1"] = true
		s.relation_index_dirty = false

		s:remove_memo_from_cache("memos/1")

		assert.are.same(1, #s.memos_cache)
		assert.are.same("memos/2", s.memos_cache[1].name)
		assert.is_nil(s.relation_details_cache["memos/1"])
		assert.is_nil(s.expanded_outgoing["memos/1"])
		assert.is_nil(s.expanded_incoming["memos/1"])
		assert.is_true(s.relation_index_dirty)
	end)

	it("should load the next page when editing the load-more list item", function()
		ui.bind_list_keymaps(buf1)
		local s = ui.get_session(buf1)
		s.list_items = {
			{ kind = "header" },
			{ kind = "load_more" },
		}
		vim.api.nvim_set_current_buf(buf1)
		vim.api.nvim_buf_set_lines(buf1, 0, -1, false, { "header", "..." })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })

		local loaded = false
		s.load_next_page = function()
			loaded = true
		end

		s:edit_selected_memo_with("enew")

		assert.is_true(loaded)
	end)

	it("should notify when copying a selected item without a memo id", function()
		ui.bind_list_keymaps(buf1)
		local s = ui.get_session(buf1)
		s.memos_cache = {
			{ content = "no id" },
		}
		s.list_items = {
			{ kind = "header" },
			{ kind = "memo", index = 1 },
		}
		vim.api.nvim_set_current_buf(buf1)
		vim.api.nvim_buf_set_lines(buf1, 0, -1, false, { "header", "memo" })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })

		local old_notify = vim.notify
		local notified = nil
		vim.notify = function(message, level)
			notified = { message = message, level = level }
		end

		s:copy_selected_memo_id()

		vim.notify = old_notify

		assert.are.same("No memo ID on the current line.", notified.message)
		assert.are.same(vim.log.levels.INFO, notified.level)
	end)

	it("should render cached memos into buffer lines and list item metadata", function()
		ui.bind_list_keymaps(buf1)
		local s = ui.get_session(buf1)
		s.memos_cache = {
			{ name = "memos/1", content = "Rendered memo", update_time = "2026-06-21T10:00:00Z" },
		}

		s:render_cached_memos()

		vim.wait(1000, function()
			return s.list_items[2] ~= nil
		end)

		local lines = vim.api.nvim_buf_get_lines(buf1, 0, -1, false)
		assert.are.same("View: NORMAL", lines[1])
		assert.is_true(lines[2]:match("Rendered memo") ~= nil)
		assert.are.same("memo", s.list_items[2].kind)
		assert.are.same(1, s.list_items[2].index)
	end)

	it("should trigger missing relation fetches after rendering cached memos", function()
		ui.bind_list_keymaps(buf1)
		local s = ui.get_session(buf1)
		s.memos_cache = {
			{
				name = "memos/1",
				content = "Parent memo",
				relations = {
					{ memo = "memos/1", relatedMemo = "memos/2", type = "REFERENCE" },
				},
			},
		}
		s.expanded_outgoing["memos/1"] = true
		s:mark_relation_index_dirty()

		local fetched = nil
		s.fetch_missing_relations = function(self_session, names)
			fetched = names
		end

		s:render_cached_memos()

		vim.wait(1000, function()
			return fetched ~= nil
		end)

		assert.are.same({ "memos/2" }, fetched)
	end)

	it("should skip setting list lines when the buffer is invalid", function()
		ui.bind_list_keymaps(buf1)
		local s = ui.get_session(buf1)
		vim.api.nvim_buf_delete(buf1, { force = true })

		assert.has_no.errors(function()
			s:set_list_lines({ "safe" })
		end)
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

	local function count_memos_float_roles()
		local counts = {}
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			local ok, value = pcall(vim.api.nvim_win_get_var, win, "memos_window")
			if ok and value == true and vim.api.nvim_win_is_valid(win) then
				local role_ok, role = pcall(vim.api.nvim_win_get_var, win, "memos_role")
				counts[role_ok and role or "unknown"] = (counts[role_ok and role or "unknown"] or 0) + 1
			end
		end
		return counts
	end

	local function stub_list_memos()
		local api_mod = require("memos.api")
		local original_list_memos = api_mod.Client.list_memos
		local calls = 0
		api_mod.Client.list_memos = function(self_api, opts, callback)
			calls = calls + 1
			callback({ memos = {}, next_page_token = "" }, nil)
		end
		return function()
			api_mod.Client.list_memos = original_list_memos
		end, function()
			return calls
		end
	end

	it("should open edit buffer via pure Lua split/vsplit window API without vim.cmd split when floats are disabled", function()
		memos.setup({
			window = {
				enable_float = false,
			},
		})
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

	it("should open vsplit edit panes inside the Memos float workspace", function()
		memos.setup({
			window = {
				enable_float = true,
				width = 0.7,
				height = 0.7,
				border = "rounded",
			},
		})
		local restore_list, list_calls = stub_list_memos()

		local buf = ui.open_edit_buffer("test text content", "vsplit")
		local counts = count_memos_float_roles()

		restore_list()

		assert.is_true(vim.api.nvim_buf_is_valid(buf))
		assert.are.same(1, counts.list)
		assert.are.same(1, counts.edit)
		assert.are.same(0, list_calls())
	end)

	it("should open split edit panes inside the Memos float workspace", function()
		memos.setup({
			window = {
				enable_float = true,
				width = 0.7,
				height = 0.7,
				border = "rounded",
			},
		})
		local restore_list = stub_list_memos()

		local buf = ui.open_edit_buffer("test text content", "split")
		local counts = count_memos_float_roles()

		restore_list()

		assert.is_true(vim.api.nvim_buf_is_valid(buf))
		assert.are.same(1, counts.list)
		assert.are.same(1, counts.edit)
	end)

	it("should keep Ctrl-W navigation inside the floating split workspace", function()
		memos.setup({ window = { enable_float = true, width = 0.7, height = 0.7 } })
		local restore_list = stub_list_memos()

		ui.open_edit_buffer("test text content", "vsplit")
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-w>h", true, false, true), "x", false)
		local list_win = vim.api.nvim_get_current_win()
		local ok, role = pcall(vim.api.nvim_win_get_var, list_win, "memos_role")
		assert.is_true(ok)
		assert.are.same("list", role)

		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-w>j", true, false, true), "x", false)
		assert.are.same(list_win, vim.api.nvim_get_current_win())
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-w>w", true, false, true), "x", false)
		local _, edit_role = pcall(vim.api.nvim_win_get_var, vim.api.nvim_get_current_win(), "memos_role")
		assert.are.same("edit", edit_role)

		restore_list()
	end)

	it("should open a selected memo in a vertical floating split by default", function()
		memos.setup({ window = { enable_float = true, width = 0.7, height = 0.7 } })
		local restore_list = stub_list_memos()

		ui.open_memo_for_edit({ name = "memos/1", content = "test memo" })
		local counts = count_memos_float_roles()

		assert.are.same(1, counts.list)
		assert.are.same(1, counts.edit)
		restore_list()
	end)

	it("should navigate only opened Memos buffers through local history", function()
		memos.setup({ window = { enable_float = true, width = 0.7, height = 0.7 } })
		local restore_list = stub_list_memos()

		local first = ui.open_edit_buffer("first", "vsplit")
		ui.setup_buffer_for_editing()
		local second = ui.open_edit_buffer("second", "vsplit")
		ui.setup_buffer_for_editing()

		ui.navigate_memo_history(-1)
		assert.are.same(first, vim.api.nvim_get_current_buf())
		ui.navigate_memo_history(1)
		assert.are.same(second, vim.api.nvim_get_current_buf())

		restore_list()
	end)

	it("should show open and dirty memo status in floating chrome and the list header", function()
		memos.setup({ window = { enable_float = true, width = 0.7, height = 0.7 } })
		local restore_list = stub_list_memos()

		local first = ui.open_edit_buffer("first", "vsplit")
		ui.setup_buffer_for_editing()
		local second = ui.open_edit_buffer("second", "vsplit")
		ui.setup_buffer_for_editing()
		local list_win = nil
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			local ok, role = pcall(vim.api.nvim_win_get_var, win, "memos_role")
			if ok and role == "list" then
				list_win = win
				break
			end
		end
		local list_buf = vim.api.nvim_win_get_buf(list_win)
		local s = ui.get_session(list_buf)
		s.memos_cache = { { name = "memos/1", content = "cached memo" } }
		s:render_cached_memos()
		vim.wait(1000, function()
			return s.list_items[1] and s.list_items[1].kind == "header"
		end)

		vim.api.nvim_buf_set_lines(first, 0, -1, false, { "dirty memo" })
		vim.wait(1000, function()
			return vim.api.nvim_buf_get_lines(list_buf, 0, 1, false)[1]:find("Unsaved: 1", 1, true) ~= nil
		end)

		local title = vim.api.nvim_win_get_config(list_win).title
		if type(title) == "table" then
			title = title[1][1]
		end
		assert.is_true(title:find("2 open", 1, true) ~= nil)
		assert.is_true(title:find("1 unsaved", 1, true) ~= nil)
		assert.is_true(vim.api.nvim_buf_get_lines(list_buf, 0, 1, false)[1]:find("Dirty:", 1, true) ~= nil)

		local api_mod = require("memos.api")
		local original_update_memo = api_mod.Client.update_memo
		api_mod.Client.update_memo = function(_, _, _, callback)
			callback(true)
		end
		vim.b[first].memos_memo_name = "memos/1"
		ui.save_or_create_dispatcher({ bufnr = first, post_save_ui = false })
		assert.is_true(vim.wait(1000, function()
			return vim.api.nvim_buf_get_lines(list_buf, 0, 1, false)[1]:find("Unsaved: 0", 1, true) ~= nil
		end))
		api_mod.Client.update_memo = original_update_memo

		restore_list()
	end)

	it("should restore the previous float split layout when toggling the Memos window", function()
		memos.setup({
			window = {
				enable_float = true,
				width = 0.7,
				height = 0.7,
				border = "rounded",
			},
		})
		local restore_list = stub_list_memos()

		ui.open_edit_buffer("test text content", "vsplit")
		ui.toggle_memos_list()
		assert.are.same(nil, next(count_memos_float_roles()))

		ui.toggle_memos_list()
		local counts = count_memos_float_roles()

		restore_list()

		assert.are.same(1, counts.list)
		assert.are.same(1, counts.edit)
	end)

	it("should close an unmodified float edit pane when returning to the list", function()
		memos.setup({
			window = {
				enable_float = true,
				width = 0.7,
				height = 0.7,
				border = "rounded",
			},
		})
		local restore_list = stub_list_memos()

		local edit_buf = ui.open_edit_buffer("test text content", "vsplit")
		ui.setup_buffer_for_editing()
		ui.return_to_list()
		local counts = count_memos_float_roles()

		restore_list()

		assert.is_false(vim.api.nvim_buf_is_valid(edit_buf))
		assert.are.same(1, counts.list)
		assert.is_nil(counts.edit)
	end)

	it("should keep a modified float edit pane when returning to the list", function()
		memos.setup({
			window = {
				enable_float = true,
				width = 0.7,
				height = 0.7,
				border = "rounded",
			},
		})
		local restore_list = stub_list_memos()

		local edit_buf = ui.open_edit_buffer("test text content", "enew")
		ui.setup_buffer_for_editing()
		vim.bo[edit_buf].modified = true
		ui.return_to_list()
		local counts = count_memos_float_roles()

		restore_list()

		assert.is_true(vim.api.nvim_buf_is_valid(edit_buf))
		assert.are.same(1, counts.list)
		assert.are.same(1, counts.edit)
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

	it("should map template list fetches to archived state with template filter", function()
		ui.bind_list_keymaps(buf1)
		local s = ui.get_session(buf1)
		s.current_list_state = "TEMPLATES"
		s.current_filter = "content.contains(\"work\")"

		local api_mod = require("memos.api")
		local original_list_memos = api_mod.Client.list_memos
		local list_opts = nil

		api_mod.Client.list_memos = function(self_api, opts, callback)
			list_opts = opts
			callback({
				memos = {},
				next_page_token = "",
			}, nil)
		end

		s:fetch_memos({ append = false })

		vim.wait(1000, function()
			return list_opts ~= nil and s.list_refresh_state == "idle"
		end)

		api_mod.Client.list_memos = original_list_memos

		assert.are.same("ARCHIVED", list_opts.state)
		assert.are.same('"type/template" in tags && (content.contains("work"))', list_opts.filter)
	end)

	it("should use the configured template tag for exact tag filtering", function()
		memos.setup({ template_tag = "类型/模板" })
		ui.bind_list_keymaps(buf1)
		local s = ui.get_session(buf1)
		s.current_list_state = "TEMPLATES"

		local api_mod = require("memos.api")
		local original_list_memos = api_mod.Client.list_memos
		local list_opts = nil
		api_mod.Client.list_memos = function(self_api, opts, callback)
			list_opts = opts
			callback({ memos = {}, next_page_token = "" }, nil)
		end

		s:fetch_memos({ append = false })
		vim.wait(1000, function() return list_opts ~= nil end)
		api_mod.Client.list_memos = original_list_memos

		assert.are.same('"类型/模板" in tags', list_opts.filter)
	end)

	it("should update background cache when fetch returns after state changes", function()
		ui.bind_list_keymaps(buf1)
		local s = ui.get_session(buf1)
		s.current_list_state = "NORMAL"
		s.memos_cache = { { name = "memos/current", content = "current" } }

		local api_mod = require("memos.api")
		local original_list_memos = api_mod.Client.list_memos
		local list_callback = nil

		api_mod.Client.list_memos = function(self_api, opts, callback)
			list_callback = callback
		end

		s:fetch_memos({ append = false })
		assert.is_not_nil(list_callback)

		s.current_list_state = "ARCHIVED"
		list_callback({
			memos = {
				{ name = "memos/background", content = "background" },
			},
			next_page_token = "next-normal",
		}, nil)

		vim.wait(1000, function()
			return s.caches.NORMAL.page_token == "next-normal"
		end)

		api_mod.Client.list_memos = original_list_memos

		assert.are.same("memos/current", s.memos_cache[1].name)
		assert.are.same("memos/background", s.caches.NORMAL.memos[1].name)
		assert.are.same("next-normal", s.caches.NORMAL.page_token)
	end)

	it("should rollback append pagination history on fetch failure", function()
		ui.bind_list_keymaps(buf1)
		local s = ui.get_session(buf1)
		s.memos_cache = { { name = "memos/1", content = "one" } }
		s.current_page_token = "token-1"

		local api_mod = require("memos.api")
		local original_list_memos = api_mod.Client.list_memos

		api_mod.Client.list_memos = function(self_api, opts, callback)
			callback(nil, "network down")
		end

		s:fetch_memos({ append = true, page_token = "token-1" })

		vim.wait(1000, function()
			return s.list_refresh_state == "failed"
		end)

		api_mod.Client.list_memos = original_list_memos

		assert.are.same(0, #s.page_history)
		assert.are.same(1, #s.memos_cache)
		assert.are.same("memos/1", s.memos_cache[1].name)
	end)

	it("should clear search filter, reset cache, and fetch fresh data", function()
		local old_input = vim.ui.input
		local api_mod = require("memos.api")
		local original_list_memos = api_mod.Client.list_memos

		ui.bind_list_keymaps(buf1)
		local s = ui.get_session(buf1)
		s.current_filter = "content.contains(\"old\")"
		s.memos_cache = { { name = "memos/old", content = "old" } }
		s.current_page_token = "old-token"

		vim.ui.input = function(opts, on_confirm)
			assert.are.same("Search memos (empty clears): ", opts.prompt)
			on_confirm("")
		end

		local list_opts = nil
		api_mod.Client.list_memos = function(self_api, opts, callback)
			list_opts = opts
			callback({
				memos = {
					{ name = "memos/new", content = "new" },
				},
				next_page_token = "",
			}, nil)
		end

		s:search_memos()

		vim.wait(1000, function()
			return s.memos_cache[1] and s.memos_cache[1].name == "memos/new"
		end)

		vim.ui.input = old_input
		api_mod.Client.list_memos = original_list_memos

		assert.are.same("", s.current_filter)
		assert.is_nil(list_opts.page_token)
		assert.are.same("", list_opts.filter)
	end)

	it("should create the MemosList buffer and bind list keymaps on force refresh", function()
		local api_mod = require("memos.api")
		local original_list_memos = api_mod.Client.list_memos
		local list_called = false

		api_mod.Client.list_memos = function(self_api, opts, callback)
			list_called = true
			callback({
				memos = {
					{ name = "memos/1", content = "one" },
				},
				next_page_token = "",
			}, nil)
		end

		ui.show_memos_list({ force_refresh = true })

		local list_buf = vim.api.nvim_get_current_buf()
		local s = ui.get_session(list_buf)
		vim.wait(1000, function()
			return list_called and s and #s.memos_cache == 1
		end)

		api_mod.Client.list_memos = original_list_memos

		assert.are.same("MemosList", vim.api.nvim_buf_get_name(list_buf):match("MemosList$"))
		assert.is_not_nil(s)
		assert.is_true(list_called)
		local maps = vim.api.nvim_buf_get_keymap(list_buf, "n")
		local has_quit = false
		for _, map in ipairs(maps) do
			if map.lhs == "q" then
				has_quit = true
			end
		end
		assert.is_true(has_quit)
	end)

	it("should render stale cache before background list refresh", function()
		local api_mod = require("memos.api")
		local original_list_memos = api_mod.Client.list_memos

		api_mod.Client.list_memos = function(self_api, opts, callback)
			callback({
				memos = {
					{ name = "memos/1", content = "one" },
				},
				next_page_token = "",
			}, nil)
		end

		ui.show_memos_list({ force_refresh = true })
		local s = ui.get_session(vim.api.nvim_get_current_buf())
		vim.wait(1000, function()
			return s and #s.memos_cache == 1
		end)

		local render_called = false
		local fetch_called = false
		s.render_cached_memos = function()
			render_called = true
		end
		api_mod.Client.list_memos = function(self_api, opts, callback)
			fetch_called = true
			callback({
				memos = {
					{ name = "memos/2", content = "two" },
				},
				next_page_token = "",
			}, nil)
		end

		ui.show_memos_list()

		vim.wait(1000, function()
			return render_called and fetch_called
		end)

		api_mod.Client.list_memos = original_list_memos

		assert.is_true(render_called)
		assert.is_true(fetch_called)
	end)

	it("should close an existing memos float when toggling the list", function()
		memos.setup({
			window = {
				enable_float = true,
				width = 0.5,
				height = 0.5,
				border = "rounded",
			},
		})
		vim.api.nvim_set_current_buf(buf1)

		local api_mod = require("memos.api")
		local original_list_memos = api_mod.Client.list_memos
		api_mod.Client.list_memos = function(self_api, opts, callback)
			callback({ memos = {}, next_page_token = "" }, nil)
		end

		ui.show_memos_list({ force_refresh = true })
		local float_win = vim.api.nvim_get_current_win()
		local ok, value = pcall(vim.api.nvim_win_get_var, float_win, "memos_window")
		assert.is_true(ok)
		assert.is_true(value)

		ui.toggle_memos_list()

		api_mod.Client.list_memos = original_list_memos

		assert.is_false(vim.api.nvim_win_is_valid(float_win))
	end)

	it("should close the current memos float when quitting the list", function()
		memos.setup({
			window = {
				enable_float = true,
				width = 0.5,
				height = 0.5,
				border = "rounded",
			},
		})
		vim.api.nvim_set_current_buf(buf1)

		local api_mod = require("memos.api")
		local original_list_memos = api_mod.Client.list_memos
		api_mod.Client.list_memos = function(self_api, opts, callback)
			callback({ memos = {}, next_page_token = "" }, nil)
		end

		ui.show_memos_list({ force_refresh = true })
		local float_win = vim.api.nvim_get_current_win()

		ui.quit_memos_list()

		api_mod.Client.list_memos = original_list_memos

		assert.is_false(vim.api.nvim_win_is_valid(float_win))
	end)

	it("should switch to templates view while preserving the previous state cache", function()
		memos.setup({
			window = {
				enable_float = false,
			},
		})
		local api_mod = require("memos.api")
		local original_list_memos = api_mod.Client.list_memos

		api_mod.Client.list_memos = function(self_api, opts, callback)
			callback({
				memos = {
					{ name = "memos/initial", content = "initial" },
				},
				next_page_token = "",
			}, nil)
		end

		ui.show_memos_list({ force_refresh = true })
		local s = ui.get_session(vim.api.nvim_get_current_buf())
		vim.wait(1000, function()
			return s and s.memos_cache[1] and s.memos_cache[1].name == "memos/initial"
		end)

		s.current_list_state = "NORMAL"
		s.memos_cache = { { name = "memos/normal", content = "normal" } }
		s.current_page_token = "normal-token"

		api_mod.Client.list_memos = function(self_api, opts, callback)
			callback({
				memos = {
					{ name = "memos/template", content = "#type/template\nTemplate" },
				},
				next_page_token = "",
			}, nil)
		end

		ui.show_templates_list()

		vim.wait(1000, function()
			return s.current_list_state == "TEMPLATES" and s.memos_cache[1] and s.memos_cache[1].name == "memos/template"
		end)

		api_mod.Client.list_memos = original_list_memos

		assert.are.same("memos/normal", s.caches.NORMAL.memos[1].name)
		assert.are.same("normal-token", s.caches.NORMAL.page_token)
		assert.are.same("TEMPLATES", s.current_list_state)
	end)
end)
