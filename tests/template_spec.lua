local template = require("memos.template")

describe("memos.template", function()
	before_each(function()
		require("memos").setup({ template_tag = "type/template" })
	end)

	describe("strip_template_tag", function()
		it("should strip tags from the beginning", function()
			local input = "#type/template\nHello World"
			local output = template.strip_template_tag(input)
			assert.are.same("Hello World", output)
		end)

		it("should strip tags from the end", function()
			local input = "Hello World\n#type/template"
			local output = template.strip_template_tag(input)
			assert.are.same("Hello World", output)
		end)

		it("should strip inline tags", function()
			local input = "Hello #type/template World"
			local output = template.strip_template_tag(input)
			assert.are.same("Hello World", output)
		end)

		it("should strip a configured Unicode tag without stripping prefixed tags", function()
			require("memos").setup({ template_tag = "类型/模板" })
			assert.are.same("标题", template.strip_template_tag("#类型/模板\n标题"))
			assert.are.same("#类型/模板化\n标题", template.strip_template_tag("#类型/模板化\n标题"))
		end)
	end)

	describe("template_create", function()
		it("should open template buffers through the ui edit buffer helper", function()
			local original_ui = package.loaded["memos.ui"]
			local opened = false
			local setup = false
			local buf = vim.api.nvim_create_buf(false, true)

			package.loaded["memos.ui"] = {
				open_edit_buffer = function(content, open_cmd)
					opened = content == "" and open_cmd == "vsplit"
					vim.api.nvim_set_current_buf(buf)
					return buf
				end,
				setup_buffer_for_editing = function()
					setup = true
				end,
			}

			template.template_create()

			vim.wait(1000, function()
				return opened and setup
			end)

			assert.is_true(opened)
			assert.is_true(setup)
			assert.is_true(vim.b[buf].memos_template_mode)
			assert.is_nil(vim.b[buf].memos_template_name)

			package.loaded["memos.ui"] = original_ui
			if vim.api.nvim_buf_is_valid(buf) then
				vim.api.nvim_buf_delete(buf, { force = true })
			end
		end)
	end)

	describe("save_template_buffer", function()
		it("should create templates with the configured tag", function()
			require("memos").setup({ template_tag = "类型/模板" })
			local api_mod = require("memos.api")
			local old_create_memo = api_mod.Client.create_memo
			local old_update_state = api_mod.Client.update_memo_state
			local buf = vim.api.nvim_create_buf(false, true)
			local created_content = nil
			api_mod.Client.create_memo = function(self_api, content, callback)
				created_content = content
				callback({ name = "memos/unicode-template" }, nil, {})
			end
			api_mod.Client.update_memo_state = function(self_api, memo_name, state, callback)
				callback(true, nil, {})
			end

			local done = false
			template.save_template_buffer(buf, "每周", function(success) done = success end)
			vim.wait(1000, function() return done end)

			api_mod.Client.create_memo = old_create_memo
			api_mod.Client.update_memo_state = old_update_state
			vim.api.nvim_buf_delete(buf, { force = true })
			assert.are.same("每周\n#类型/模板", created_content)
		end)

		it("should create templates then archive them", function()
			local api_mod = require("memos.api")
			local old_create_memo = api_mod.Client.create_memo
			local old_update_state = api_mod.Client.update_memo_state
			local buf = vim.api.nvim_create_buf(false, true)
			vim.b[buf].memos_template_mode = true
			vim.b[buf].memos_template_name = nil

			local create_args = nil
			local update_args = nil
			api_mod.Client.create_memo = function(self_api, content, callback)
				create_args = { content = content }
				callback({ name = "memos/template-1", content = content, state = "NORMAL" }, nil, {})
			end
			api_mod.Client.update_memo_state = function(self_api, memo_name, state, callback)
				update_args = { memo_name = memo_name, state = state }
				callback(true, nil, {})
			end

			local result = nil
			template.save_template_buffer(buf, "Weekly", function(success, new_tpl, err)
				result = { success = success, new_tpl = new_tpl, err = err }
			end)

			vim.wait(1000, function()
				return result ~= nil
			end)

			api_mod.Client.create_memo = old_create_memo
			api_mod.Client.update_memo_state = old_update_state
			if vim.api.nvim_buf_is_valid(buf) then
				vim.api.nvim_buf_delete(buf, { force = true })
			end

			assert.are.same("Weekly\n#type/template", create_args.content)
			assert.are.same("memos/template-1", update_args.memo_name)
			assert.are.same("ARCHIVED", update_args.state)
			assert.is_true(result.success)
			assert.are.same("memos/template-1", result.new_tpl.name)
		end)

		it("should not archive or delete a memo when template create fails", function()
			local api_mod = require("memos.api")
			local old_create_memo = api_mod.Client.create_memo
			local old_update_state = api_mod.Client.update_memo_state
			local old_delete_memo = api_mod.Client.delete_memo
			local buf = vim.api.nvim_create_buf(false, true)
			vim.b[buf].memos_template_mode = true
			vim.b[buf].memos_template_name = nil

			local update_state_called = false
			local delete_called = false
			api_mod.Client.create_memo = function(self_api, content, callback)
				callback(nil, "create failed", {})
			end
			api_mod.Client.update_memo_state = function()
				update_state_called = true
			end
			api_mod.Client.delete_memo = function()
				delete_called = true
			end

			local result = nil
			template.save_template_buffer(buf, "Weekly", function(success, new_tpl, err)
				result = { success = success, new_tpl = new_tpl, err = err }
			end)

			vim.wait(1000, function()
				return result ~= nil
			end)

			api_mod.Client.create_memo = old_create_memo
			api_mod.Client.update_memo_state = old_update_state
			api_mod.Client.delete_memo = old_delete_memo
			if vim.api.nvim_buf_is_valid(buf) then
				vim.api.nvim_buf_delete(buf, { force = true })
			end

			assert.is_false(update_state_called)
			assert.is_false(delete_called)
			assert.is_false(result.success)
			assert.are.same("create failed", result.err)
		end)

		it("should not delete a created memo when template archive fails", function()
			local api_mod = require("memos.api")
			local old_create_memo = api_mod.Client.create_memo
			local old_update_state = api_mod.Client.update_memo_state
			local old_delete_memo = api_mod.Client.delete_memo
			local buf = vim.api.nvim_create_buf(false, true)
			vim.b[buf].memos_template_mode = true
			vim.b[buf].memos_template_name = nil

			local delete_called = false
			api_mod.Client.create_memo = function(self_api, content, callback)
				callback({ name = "memos/template-1", content = content }, nil, {})
			end
			api_mod.Client.update_memo_state = function(self_api, memo_name, state, callback)
				callback(false, "archive failed", {})
			end
			api_mod.Client.delete_memo = function()
				delete_called = true
			end

			local result = nil
			template.save_template_buffer(buf, "Weekly", function(success, new_tpl, err)
				result = { success = success, new_tpl = new_tpl, err = err }
			end)

			vim.wait(1000, function()
				return result ~= nil
			end)

			api_mod.Client.create_memo = old_create_memo
			api_mod.Client.update_memo_state = old_update_state
			api_mod.Client.delete_memo = old_delete_memo
			if vim.api.nvim_buf_is_valid(buf) then
				vim.api.nvim_buf_delete(buf, { force = true })
			end

			assert.is_false(delete_called)
			assert.is_false(result.success)
			assert.are.same("archive failed", result.err)
		end)
	end)
end)
