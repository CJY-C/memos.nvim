local Job = require("plenary.job")

local M = {}

local stats = {
	requests = 0,
}

local Client = {}
Client.__index = Client

function Client.new(config_or_fn)
	return setmetatable({
		_config = config_or_fn or {},
	}, Client)
end

function Client:get_host()
	local cfg = type(self._config) == "function" and self._config() or self._config
	local host = cfg and cfg.host or ""
	if type(host) == "string" then
		return host:gsub("/+$", "")
	end
	return ""
end

function Client:get_token()
	local cfg = type(self._config) == "function" and self._config() or self._config
	return cfg and cfg.token or ""
end

function Client:get_timeout()
	local cfg = type(self._config) == "function" and self._config() or self._config
	return cfg and tonumber(cfg.timeout) or 10
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

function Client:run_curl(args, callback)
	local token = self:get_token()
	local timeout = self:get_timeout()
	local full_args = vim.deepcopy(args)

	stats.requests = stats.requests + 1

	table.insert(full_args, "-H")
	table.insert(full_args, "Authorization: Bearer " .. token)
	table.insert(full_args, "--max-time")
	table.insert(full_args, tostring(timeout))
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

local function build_list_url(host, opts)
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

	local url = host .. "/api/v1/memos"
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

function Client:get_current_user(callback)
	local host = self:get_host()
	self:run_curl({ "-X", "GET", host .. "/api/v1/auth/me" }, function(response)
		if not response.ok then
			callback(nil, parse_api_error(response), response)
			return
		end
		local payload = decode_json(response.body)
		local user = type(payload) == "table" and (payload.user or payload) or nil
		callback(user, nil, response)
	end)
end

function Client:list_memos(opts, callback)
	local host = self:get_host()
	self:run_curl({ "-X", "GET", build_list_url(host, opts) }, function(response)
		if not response.ok then
			callback(nil, parse_api_error(response), response)
			return
		end
		callback(normalize_list_response(decode_json(response.body)), nil, response)
	end)
end

function Client:get_memo(memo_name, callback)
	local host = self:get_host()
	self:run_curl({
		"-X",
		"GET",
		host .. "/api/v1/" .. memo_name,
	}, function(response)
		if not response.ok then
			callback(nil, parse_api_error(response), response)
			return
		end
		callback(normalize_memo(decode_json(response.body)), nil, response)
	end)
end

local function build_create_memo_payload(content)
	return {
		content = content,
	}
end

function Client:create_memo(content, callback)
	local host = self:get_host()
	local json_data = vim.json.encode(build_create_memo_payload(content))

	self:run_curl({
		"-X",
		"POST",
		host .. "/api/v1/memos",
		"-H",
		"Content-Type: application/json",
		"--data",
		json_data,
	}, function(response)
		if not response.ok then
			if callback then
				callback(nil, parse_api_error(response), response)
			end
			return
		end
		if callback then
			callback(normalize_memo(decode_json(response.body)), nil, response)
		end
	end)
end

function Client:patch_memo(memo_name, body, update_mask, callback)
	local host = self:get_host()
	local payload = vim.tbl_extend("force", { name = memo_name }, body or {})
	local json_data = vim.json.encode(payload)

	self:run_curl({
		"-X",
		"PATCH",
		host .. "/api/v1/" .. memo_name .. "?updateMask=" .. update_mask,
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

function Client:update_memo(memo_name, content, callback)
	local update_time = os.date("!%Y-%m-%dT%H:%M:%SZ")
	self:patch_memo(memo_name, {
		content = content,
		update_time = update_time,
	}, "content,update_time", callback)
end

function Client:update_memo_pinned(memo_name, pinned, callback)
	self:patch_memo(memo_name, {
		pinned = pinned == true,
	}, "pinned", callback)
end

function Client:update_memo_state(memo_name, state, callback)
	self:patch_memo(memo_name, {
		state = state,
	}, "state", callback)
end

function Client:update_memo_visibility(memo_name, visibility, callback)
	self:patch_memo(memo_name, {
		visibility = visibility,
	}, "visibility", callback)
end

function Client:update_memo_create_time(memo_name, create_time, callback)
	self:patch_memo(memo_name, {
		create_time = create_time,
	}, "create_time", callback)
end

function Client:update_memo_update_time(memo_name, update_time, callback)
	self:patch_memo(memo_name, {
		update_time = update_time,
	}, "update_time", callback)
end

function Client:delete_memo(memo_name, callback)
	local host = self:get_host()
	self:run_curl({
		"-X",
		"DELETE",
		host .. "/api/v1/" .. memo_name,
	}, function(response)
		if not response.ok then
			callback(false, parse_api_error(response), response)
			return
		end
		callback(true, nil, response)
	end)
end

function Client:set_memo_relations(memo_name, relations, callback)
	local host = self:get_host()
	local json_data = vim.json.encode({
		relations = relations,
	})

	self:run_curl({
		"-X",
		"PATCH",
		host .. "/api/v1/" .. memo_name .. "/relations",
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

M.Client = Client

function M.new(config_or_fn)
	return Client.new(config_or_fn)
end

-- Backward compatibility proxy
local default_client = nil
local last_cfg_host = nil
local last_cfg_token = nil

local function get_default_client()
	local cfg = require("memos").config or {}
	if not default_client or cfg.host ~= last_cfg_host or cfg.token ~= last_cfg_token then
		last_cfg_host = cfg.host
		last_cfg_token = cfg.token
		default_client = Client.new(cfg)
	end
	return default_client
end

setmetatable(M, {
	__index = function(t, key)
		local val = Client[key]
		if type(val) == "function" then
			return function(...)
				return val(get_default_client(), ...)
			end
		end
		return val
	end,
})

return M
