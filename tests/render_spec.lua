local render = require("memos.ui.render")

local function test_config()
	return {
		list_style = "default",
		keymaps = {
			list = {
				refresh_list = "r",
				add_memo = "i",
				quit = "q",
				next_page = "]",
			},
		},
	}
end

local function test_session(overrides)
	local session = vim.tbl_extend("force", {
		buf = nil,
		current_list_state = "NORMAL",
		current_filter = "",
		current_page_token = "",
		list_refresh_state = "idle",
		last_refresh_at = nil,
		memos_cache = {},
		expanded_incoming = {},
		expanded_outgoing = {},
		in_flight_relations = {},
		relation_details_cache = {},
		outgoing = {},
		incoming = {},
	}, overrides or {})

	function session:get_outgoing_relation_names(memo)
		return self.outgoing[memo.name] or {}
	end

	function session:get_incoming_relation_names(memo)
		return self.incoming[memo.name] or {}
	end

	function session:get_cached_relation_memo(name)
		return self.relation_details_cache[name]
	end

	return session
end

describe("memos.ui.render", function()
	it("should build relation loading lines with item metadata and highlights", function()
		local session = test_session({
			memos_cache = {
				{ name = "memos/1", content = "Parent memo", update_time = "2026-06-21T10:00:00Z" },
			},
			expanded_outgoing = {
				["memos/1"] = true,
			},
			outgoing = {
				["memos/1"] = { "memos/2" },
			},
		})

		local rendered = render.build(session, test_config())

		assert.are.same("memo", rendered.list_items[2].kind)
		assert.are.same("relation_loading", rendered.list_items[3].kind)
		assert.are.same("outgoing", rendered.list_items[3].relation_type)
		assert.are.same("memos/2", rendered.list_items[3].relation_name)
		assert.is_true(rendered.lines[3]:match("Loading memos/2") ~= nil)
		assert.are.same("MemosOutgoingLink", rendered.line_hls[3][1].hl_group)
		assert.are.same({ "memos/2" }, rendered.missing_relation_names)
	end)

	it("should strip template tags in template view memo lines", function()
		local session = test_session({
			current_list_state = "TEMPLATES",
		})

		local line = render.format_memo_line(session, test_config(), 1, {
			name = "memos/1",
			content = "#type/template\nWeekly note",
		})

		assert.are.same("1. [T] Weekly note", line)
	end)

	it("should render templates using the configured Unicode tag", function()
		local memos = require("memos")
		memos.setup({ template_tag = "类型/模板" })
		local session = test_session({ current_list_state = "TEMPLATES" })
		local line = render.format_memo_line(session, test_config(), 1, {
			name = "memos/1",
			content = "#类型/模板\n每周回顾",
		})
		memos.setup({ template_tag = "type/template" })
		assert.are.same("1. [T] 每周回顾", line)
	end)

	it("should align relation indicators using display width for CJK titles", function()
		local old_columns = vim.o.columns
		vim.o.columns = 50

		local session = test_session({
			memos_cache = {
				{ name = "memos/1", content = "你好 memo", update_time = "2026-06-21T10:00:00Z" },
			},
			outgoing = {
				["memos/1"] = { "memos/2" },
			},
		})

		local line = render.format_memo_line(session, test_config(), 1, session.memos_cache[1])
		local before_indicator = line:match("^(.*)%[→ 1%]$")

		vim.o.columns = old_columns

		assert.is_not_nil(before_indicator)
		assert.are.same(42, vim.fn.strdisplaywidth(before_indicator))
	end)
end)
