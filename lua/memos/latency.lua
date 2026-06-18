local api = require("memos.api")

local M = {}

local function now_ms()
	return vim.loop.hrtime() / 1000000
end

local function env_bool(name)
	local value = os.getenv(name)
	if not value then
		return false
	end
	value = value:lower()
	return value == "1" or value == "true" or value == "yes"
end

local function seconds_to_ms(value)
	return (tonumber(value) or 0) * 1000
end

local function wait_for_async(start_fn)
	local done = false
	local result = nil
	local err = nil
	local response = nil
	local started = now_ms()

	start_fn(function(value, value_err, value_response)
		result = value
		err = value_err
		response = value_response
		done = true
	end)

	local ok = vim.wait(30000, function()
		return done
	end, 20)

	return ok and result or nil, ok and err or "timed out", now_ms() - started, response
end

local function timing_detail(response, extra)
	local timing = response and response.timing or {}
	local parts = {}
	if extra and extra ~= "" then
		table.insert(parts, extra)
	end
	if timing.remote_ip and timing.remote_ip ~= "" then
		table.insert(parts, "ip=" .. timing.remote_ip)
	end
	if timing.time_total then
		table.insert(parts, string.format("curl_total=%.1fms", seconds_to_ms(timing.time_total)))
	end
	if timing.time_connect then
		table.insert(parts, string.format("connect=%.1fms", seconds_to_ms(timing.time_connect)))
	end
	if timing.time_appconnect and timing.time_appconnect > 0 then
		table.insert(parts, string.format("tls=%.1fms", seconds_to_ms(timing.time_appconnect)))
	end
	if timing.time_starttransfer then
		table.insert(parts, string.format("ttfb=%.1fms", seconds_to_ms(timing.time_starttransfer)))
	end
	if response and response.status and response.status > 0 then
		table.insert(parts, "http=" .. tostring(response.status))
	end
	return table.concat(parts, " ")
end

local function print_step(name, elapsed, ok, response, detail)
	local status = ok and "ok" or "failed"
	local suffix = timing_detail(response, detail)
	if suffix ~= "" then
		print(string.format("%-12s %8.1f ms  %s  %s", name, elapsed, status, suffix))
	else
		print(string.format("%-12s %8.1f ms  %s", name, elapsed, status))
	end
end

local function add_sample(samples, key, elapsed)
	samples[key] = samples[key] or {}
	table.insert(samples[key], elapsed)
end

local function summarize_samples(samples)
	for _, key in ipairs({ "list", "create", "update" }) do
		local values = samples[key] or {}
		if #values > 0 then
			local min = values[1]
			local max = values[1]
			local total = 0
			for _, value in ipairs(values) do
				min = math.min(min, value)
				max = math.max(max, value)
				total = total + value
			end
			print(string.format("%-12s avg=%8.1f ms  min=%8.1f ms  max=%8.1f ms", key .. "_summary", total / #values, min, max))
		end
	end
end

local function run_warmup()
	local _, err, elapsed, response = wait_for_async(function(done)
		api.get_current_user(done)
	end)
	local ok = response and response.ok == true
	print_step("warmup", elapsed, ok, response, ok and "auth/me" or tostring(err))
end

local function run_once(opts, run_index)
	local samples = opts.samples
	local failures = 0
	local page_size = tonumber(opts.page_size) or require("memos").config.page_size or 50
	local order_by = opts.order_by or require("memos").config.list_order_by

	if opts.runs > 1 then
		print(string.format("run %d/%d", run_index, opts.runs))
	end

	local list, list_err, list_ms, list_response = wait_for_async(function(done)
		api.list_memos({
			page_size = page_size,
			state = require("memos").config.list_state,
			order_by = order_by,
		}, done)
	end)
	print_step(
		"list",
		list_ms,
		list ~= nil,
		list_response,
		list and ("items=" .. tostring(#(list.memos or {}))) or tostring(list_err)
	)
	if list then
		add_sample(samples, "list", list_ms)
	else
		failures = failures + 1
	end

	if opts.skip_write == true then
		return failures
	end
	if not list then
		print_step("create", 0, false, nil, "skipped because list failed")
		return failures
	end

	local stamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
	local content = "memos.nvim latency test " .. stamp
	local created, create_err, create_ms, create_response = wait_for_async(function(done)
		api.create_memo(content, done)
	end)
	print_step("create", create_ms, created ~= nil, create_response, created and created.name or tostring(create_err))
	if created then
		add_sample(samples, "create", create_ms)
	else
		failures = failures + 1
		return failures
	end

	local updated, update_err, update_ms, update_response = wait_for_async(function(done)
		api.update_memo(created.name, content .. "\nupdated", done)
	end)
	print_step("update", update_ms, updated == true, update_response, updated and created.name or tostring(update_err))
	if updated == true then
		add_sample(samples, "update", update_ms)
	else
		failures = failures + 1
	end

	return failures
end

function M.run(opts)
	opts = opts or {}
	opts.runs = tonumber(opts.runs or os.getenv("MEMOS_LATENCY_RUNS")) or 1
	opts.page_size = tonumber(opts.page_size or os.getenv("MEMOS_LATENCY_PAGE_SIZE"))
	opts.order_by = opts.order_by or os.getenv("MEMOS_LATENCY_ORDER_BY")
	opts.skip_write = opts.skip_write == true or env_bool("MEMOS_LATENCY_SKIP_WRITE")
	opts.warmup = opts.warmup == true or env_bool("MEMOS_LATENCY_WARMUP")
	opts.samples = {}

	local cfg = require("memos").config
	if not cfg.host or cfg.host == "" or not cfg.token or cfg.token == "" then
		error("Memos credentials are required: use setup({ host, token }), setup({ env_file }), or MEMOS_HOST/MEMOS_TOKEN")
	end
	if not cfg.host:match("^https?://") then
		error("Memos host must include http:// or https://: " .. cfg.host)
	end

	print("memos.nvim latency baseline")
	print("host: " .. cfg.host)
	print("page_size: " .. tostring(opts.page_size or cfg.page_size or 50))
	print("order_by: " .. tostring(opts.order_by or cfg.list_order_by or ""))
	print("runs: " .. tostring(opts.runs))
	if opts.skip_write then
		print("write: skipped")
	end

	if opts.warmup then
		run_warmup()
	end

	api.reset_stats()
	local total_start = now_ms()
	local failures = 0
	for run_index = 1, opts.runs do
		failures = failures + run_once(opts, run_index)
	end

	local stats = api.get_stats()
	print(string.format("requests     %8d", stats.requests or 0))
	print(string.format("total        %8.1f ms", now_ms() - total_start))
	summarize_samples(opts.samples)

	if failures > 0 then
		error(string.format("%d latency step(s) failed", failures))
	end
end

return M
