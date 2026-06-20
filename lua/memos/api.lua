local Job = require("plenary.job")

local M = {}

local stats = {
	requests = 0,
}

local function get_config()
	return require("memos").config
end

local function url_encode(str)
	local value = tostring(str or "")
	value = value:gsub("\n", "\r\n")
	value = value:gsub("([^%w %-%_%.%~])", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
	return value:gsub(" ", "%%20")
end

local function decode_json(str)
	if type(str) ~= "string" or str == "" then
		return nil
	end
	local ok, data = pcall(vim.json.decode, str)
	if ok then
		return data
	end
	return nil
end

local function parse_http_output(output)
	local marker = "__MEMOS_CURL_META__:"
	local meta_text = output:match("\n?" .. marker .. "([^\n]*)$")
	local body = output:gsub("\n?" .. marker .. "[^\n]*$", "")
	local timing = {}

	if meta_text then
		local fields = vim.split(meta_text, "|", { plain = true })
		timing = {
			http_code = tonumber(fields[1]) or 0,
			time_namelookup = tonumber(fields[2]) or 0,
			time_connect = tonumber(fields[3]) or 0,
			time_appconnect = tonumber(fields[4]) or 0,
			time_pretransfer = tonumber(fields[5]) or 0,
			time_starttransfer = tonumber(fields[6]) or 0,
			time_total = tonumber(fields[7]) or 0,
			remote_ip = fields[8] or "",
		}
	end

	return timing.http_code or 0, body, timing
end

local function parse_api_error(response)
	local parts = {}
	local payload = decode_json(response.body)

	if response.status and response.status > 0 then
		table.insert(parts, "HTTP " .. tostring(response.status))
	end
	if type(payload) == "table" and payload.message then
		table.insert(parts, payload.message)
	elseif response.stderr and response.stderr ~= "" then
		table.insert(parts, response.stderr)
	elseif response.body and response.body ~= "" then
		table.insert(parts, response.body)
	end

	if #parts == 0 then
		return "Unknown error"
	end
	return table.concat(parts, " - ")
end

local function run_curl(args, callback)
	local cfg = get_config()
	local full_args = vim.deepcopy(args)

	stats.requests = stats.requests + 1

	table.insert(full_args, "-H")
	table.insert(full_args, "Authorization: Bearer " .. cfg.token)
	table.insert(full_args, "-sS")
	table.insert(full_args, "-w")
	table.insert(
		full_args,
		"\n__MEMOS_CURL_META__:%{http_code}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_pretransfer}|%{time_starttransfer}|%{time_total}|%{remote_ip}"
	)

	Job:new({
		command = "curl",
		args = full_args,
		on_exit = function(job, return_val)
			local output = table.concat(job:result(), "\n")
			local status, body, timing = parse_http_output(output)
			local stderr = table.concat(job:stderr_result(), "\n")

			callback({
				ok = status and status >= 200 and status < 300,
				status = status or 0,
				body = body or "",
				curl_ok = return_val == 0,
				stderr = stderr,
				timing = timing,
			})
		end,
	}):start()
end

local function normalize_memo(memo)
	if type(memo) ~= "table" then
		return nil
	end
	local normalized = vim.deepcopy(memo)
	normalized.name = normalized.name or normalized.id or ""
	normalized.content = type(normalized.content) == "string" and normalized.content or ""
	normalized.create_time = normalized.create_time or normalized.createTime or ""
	normalized.update_time = normalized.update_time or normalized.updateTime or ""
	normalized.state = normalized.state or "NORMAL"
	normalized.pinned = normalized.pinned == true
	normalized.visibility = type(normalized.visibility) == "string" and normalized.visibility or ""
	normalized.snippet = type(normalized.snippet) == "string" and normalized.snippet or ""
	return normalized
end

local function normalize_list_response(data)
	if type(data) ~= "table" then
		return { memos = {}, next_page_token = "" }
	end

	local memos = {}
	for _, memo in ipairs(data.memos or {}) do
		local normalized = normalize_memo(memo)
		if normalized then
			table.insert(memos, normalized)
		end
	end

	return {
		memos = memos,
		next_page_token = data.next_page_token or data.nextPageToken or "",
	}
end

local function build_list_url(opts)
	local cfg = get_config()
	local params = {}
	opts = opts or {}

	if opts.page_size then
		table.insert(params, "pageSize=" .. tostring(opts.page_size))
	end
	if opts.page_token and opts.page_token ~= "" then
		table.insert(params, "pageToken=" .. url_encode(opts.page_token))
	end
	if opts.state and opts.state ~= "" then
		table.insert(params, "state=" .. url_encode(opts.state))
	end
	if opts.order_by and opts.order_by ~= "" then
		table.insert(params, "orderBy=" .. url_encode(opts.order_by))
	end
	if opts.filter and opts.filter ~= "" then
		table.insert(params, "filter=" .. url_encode(opts.filter))
	end

	local url = cfg.host .. "/api/v1/memos"
	if #params > 0 then
		url = url .. "?" .. table.concat(params, "&")
	end
	return url
end

function M.reset_stats()
	stats.requests = 0
end

function M.get_stats()
	return vim.deepcopy(stats)
end

function M.get_current_user(callback)
	local cfg = get_config()
	run_curl({ "-X", "GET", cfg.host .. "/api/v1/auth/me" }, function(response)
		if not response.ok then
			callback(nil, parse_api_error(response), response)
			return
		end
		local payload = decode_json(response.body)
		local user = type(payload) == "table" and (payload.user or payload) or nil
		callback(user, nil, response)
	end)
end

function M.list_memos(opts, callback)
	run_curl({ "-X", "GET", build_list_url(opts) }, function(response)
		if not response.ok then
			callback(nil, parse_api_error(response), response)
			return
		end
		callback(normalize_list_response(decode_json(response.body)), nil, response)
	end)
end

function M.create_memo(content, callback)
	local cfg = get_config()
	local json_data = vim.json.encode({
		content = content,
	})

	run_curl({
		"-X",
		"POST",
		cfg.host .. "/api/v1/memos",
		"-H",
		"Content-Type: application/json",
		"--data",
		json_data,
	}, function(response)
		if not response.ok then
			callback(nil, parse_api_error(response), response)
			return
		end
		callback(normalize_memo(decode_json(response.body)), nil, response)
	end)
end

function M.update_memo(memo_name, content, callback)
	local cfg = get_config()
	local json_data = vim.json.encode({
		name = memo_name,
		content = content,
	})

	run_curl({
		"-X",
		"PATCH",
		cfg.host .. "/api/v1/" .. memo_name .. "?updateMask=content",
		"-H",
		"Content-Type: application/json",
		"--data",
		json_data,
	}, function(response)
		if not response.ok then
			callback(false, parse_api_error(response), response)
			return
		end
		callback(true, nil, response)
	end)
end

function M.update_memo_pinned(memo_name, pinned, callback)
	local cfg = get_config()
	local json_data = vim.json.encode({
		name = memo_name,
		pinned = pinned == true,
	})

	run_curl({
		"-X",
		"PATCH",
		cfg.host .. "/api/v1/" .. memo_name .. "?updateMask=pinned",
		"-H",
		"Content-Type: application/json",
		"--data",
		json_data,
	}, function(response)
		if not response.ok then
			callback(false, parse_api_error(response), response)
			return
		end
		callback(true, nil, response)
	end)
end

function M.update_memo_state(memo_name, state, callback)
	local cfg = get_config()
	local json_data = vim.json.encode({
		name = memo_name,
		state = state,
	})

	run_curl({
		"-X",
		"PATCH",
		cfg.host .. "/api/v1/" .. memo_name .. "?updateMask=state",
		"-H",
		"Content-Type: application/json",
		"--data",
		json_data,
	}, function(response)
		if not response.ok then
			callback(false, parse_api_error(response), response)
			return
		end
		callback(true, nil, response)
	end)
end

function M.update_memo_visibility(memo_name, visibility, callback)
	local cfg = get_config()
	local json_data = vim.json.encode({
		name = memo_name,
		visibility = visibility,
	})

	run_curl({
		"-X",
		"PATCH",
		cfg.host .. "/api/v1/" .. memo_name .. "?updateMask=visibility",
		"-H",
		"Content-Type: application/json",
		"--data",
		json_data,
	}, function(response)
		if not response.ok then
			callback(false, parse_api_error(response), response)
			return
		end
		callback(true, nil, response)
	end)
end

return M
