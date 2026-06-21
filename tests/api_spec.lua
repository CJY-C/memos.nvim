local api = require("memos.api")

describe("memos.api client", function()
	it("should instantiate with static config", function()
		local client = api.new({ host = "http://test.com", token = "123" })
		assert.are.same("http://test.com", client:get_host())
		assert.are.same("123", client:get_token())
	end)

	it("should instantiate with dynamic config getter", function()
		local cfg = { host = "http://init.com", token = "abc" }
		local client = api.new(function()
			return cfg
		end)
		assert.are.same("http://init.com", client:get_host())

		cfg.host = "http://updated.com"
		assert.are.same("http://updated.com", client:get_host())
	end)
end)
