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
end)
