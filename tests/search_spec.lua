local search = require("memos.ui.search")
local ui = require("memos.ui")

describe("memos.ui.search", function()
	it("should build empty filters from empty input", function()
		assert.are.same("", search.build_filter(nil))
		assert.are.same("", search.build_filter(""))
		assert.are.same("", search.build_filter("   "))
	end)

	it("should convert plain text to content contains filters", function()
		assert.are.same('content.contains("weekly note")', search.build_filter("weekly note"))
	end)

	it("should convert tags to tag filters", function()
		assert.are.same('"work" in tags', search.build_filter("#work"))
	end)

	it("should combine text and tags in stable order", function()
		assert.are.same(
			'content.contains("weekly note") && "work" in tags && "review" in tags',
			search.build_filter("weekly #work note #review")
		)
	end)

	it("should pass raw CEL filters through", function()
		local filter = 'content.contains("work") && "todo" in tags'
		assert.are.same(filter, search.build_filter(filter))
	end)

	it("should escape CEL string content", function()
		assert.are.same('content.contains("quote\\" slash\\\\")', search.build_filter('quote" slash\\'))
	end)

	it("should normalize multiline text using the existing tokenized search behavior", function()
		assert.are.same('content.contains("line break")', search.build_filter("line\nbreak"))
	end)

	it("should keep the ui compatibility wrapper", function()
		assert.are.same(search.build_filter("#work weekly"), ui.build_search_filter("#work weekly"))
	end)
end)
