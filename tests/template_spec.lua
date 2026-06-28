local template = require("memos.template")

describe("memos.template", function()
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
	end)

	describe("template_create", function()
		it("should open template buffers through the ui edit buffer helper", function()
			local original_ui = package.loaded["memos.ui"]
			local opened = false
			local setup = false
			local buf = vim.api.nvim_create_buf(false, true)

			package.loaded["memos.ui"] = {
				open_edit_buffer = function(content, open_cmd)
					opened = content == "" and open_cmd == "enew"
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
end)
