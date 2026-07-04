local api = require("memos.api")

describe("memos.api client", function()
	it("should instantiate with static config", function()
		local client = api.new({ host = "http://test.com", token = "123", timeout = 15 })
		assert.are.same("http://test.com", client:get_host())
		assert.are.same("123", client:get_token())
		assert.are.same(15, client:get_timeout())
	end)

	it("should fallback to default timeout of 10 if unspecified", function()
		local client = api.new({ host = "http://test.com", token = "123" })
		assert.are.same(10, client:get_timeout())
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

	it("should create memos with the backward-compatible content-only body", function()
		local client = api.new({ host = "http://test.com", token = "123" })
		local captured_args = nil
		client.run_curl = function(_, args, callback)
			captured_args = args
			callback({ ok = true, status = 200, body = '{"name":"memos/1","content":"hello"}' })
		end

		local created = nil
		client:create_memo("hello", function(memo)
			created = memo
		end)

		assert.are.same("POST", captured_args[2])
		assert.are.same("http://test.com/api/v1/memos", captured_args[3])
		assert.are.same("Content-Type: application/json", captured_args[5])
		assert.are.same({ content = "hello" }, vim.json.decode(captured_args[7]))
		assert.are.same("memos/1", created.name)
	end)

	it("should send memo content updates through the shared PATCH shape", function()
		local client = api.new({ host = "http://test.com", token = "123" })
		local captured_args = nil
		client.run_curl = function(_, args, callback)
			captured_args = args
			callback({ ok = true, status = 200, body = "{}" })
		end

		local success = nil
		client:update_memo("memos/1", "hello", function(ok)
			success = ok
		end)

		assert.is_true(success)
		assert.are.same("PATCH", captured_args[2])
		assert.are.same("http://test.com/api/v1/memos/1?updateMask=content,update_time", captured_args[3])
		assert.are.same("Content-Type: application/json", captured_args[5])

		local body = vim.json.decode(captured_args[7])
		assert.are.same("memos/1", body.name)
		assert.are.same("hello", body.content)
		assert.is_string(body.update_time)
	end)

	it("should preserve single-field memo PATCH update masks", function()
		local client = api.new({ host = "http://test.com", token = "123" })
		local calls = {}
		client.run_curl = function(_, args, callback)
			table.insert(calls, {
				url = args[3],
				body = vim.json.decode(args[7]),
			})
			callback({ ok = true, status = 200, body = "{}" })
		end

		client:update_memo_pinned("memos/1", true, function() end)
		client:update_memo_state("memos/1", "ARCHIVED", function() end)
		client:update_memo_visibility("memos/1", "PUBLIC", function() end)
		client:update_memo_create_time("memos/1", "2026-06-28T00:00:00Z", function() end)
		client:update_memo_update_time("memos/1", "2026-06-28T00:00:00Z", function() end)

		assert.are.same("http://test.com/api/v1/memos/1?updateMask=pinned", calls[1].url)
		assert.are.same(true, calls[1].body.pinned)
		assert.are.same("memos/1", calls[1].body.name)
		assert.are.same("http://test.com/api/v1/memos/1?updateMask=state", calls[2].url)
		assert.are.same("ARCHIVED", calls[2].body.state)
		assert.are.same("http://test.com/api/v1/memos/1?updateMask=visibility", calls[3].url)
		assert.are.same("PUBLIC", calls[3].body.visibility)
		assert.are.same("http://test.com/api/v1/memos/1?updateMask=create_time", calls[4].url)
		assert.are.same("2026-06-28T00:00:00Z", calls[4].body.create_time)
		assert.are.same("http://test.com/api/v1/memos/1?updateMask=update_time", calls[5].url)
		assert.are.same("2026-06-28T00:00:00Z", calls[5].body.update_time)
	end)
end)
