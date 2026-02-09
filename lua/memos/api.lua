local Job = require("plenary.job")

local M = {}
local fallback_notified = false
local auto_mode_by_host = {}

local function get_config()
	return require("memos").config
end

local function url_encode(str)
	if str then
		str = string.gsub(str, "\n", "\r\n")
		str = string.gsub(str, "([^%w %-%_%.%~])", function(c)
			return string.format("%%%02X", string.byte(c))
		end)
		str = string.gsub(str, " ", "%%20")
	end
	return str
end

local function decode_json(str)
	if not str or str == "" then
		return nil
	end
	local ok, data = pcall(vim.json.decode, str)
	if ok then
		return data
	end
	return nil
end

local function parse_http_output(output)
	local marker = "__MEMOS_HTTP_STATUS__:"
	local status = tonumber(output:match(marker .. "(%d+)$"))
	local body = output:gsub("\n?" .. marker .. "%d+$", "")
	return status, body
end

local function run_curl(args, callback)
	local cfg = get_config()
	local full_args = vim.deepcopy(args)

	table.insert(full_args, "-H")
	table.insert(full_args, "Authorization: Bearer " .. cfg.token)
	table.insert(full_args, "-sS")
	table.insert(full_args, "-w")
	table.insert(full_args, "\n__MEMOS_HTTP_STATUS__:%{http_code}")

	Job:new({
		command = "curl",
		args = full_args,
		on_exit = function(job, return_val)
			local output = table.concat(job:result(), "\n")
			local status, body = parse_http_output(output)
			local stderr = table.concat(job:stderr_result(), "\n")

			callback({
				ok = status and status >= 200 and status < 300,
				status = status or 0,
				body = body or "",
				curl_ok = return_val == 0,
				stderr = stderr,
			})
		end,
	}):start()
end

local function parse_api_error(response)
	local parts = {}
	local payload = decode_json(response.body)

	if response.status and response.status > 0 then
		table.insert(parts, "HTTP " .. tostring(response.status))
	end
	if payload and payload.message then
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

local function normalize_user(data)
	if type(data) ~= "table" then
		return nil
	end
	local user = data.user
	if type(user) ~= "table" then
		user = data
	end

	local name = user.name or user.id
	if not name then
		return nil
	end
	return vim.tbl_extend("keep", { name = name }, user)
end

local function normalize_memo(memo)
	if type(memo) ~= "table" then
		return nil
	end
	local normalized = vim.deepcopy(memo)
	normalized.name = normalized.name or normalized.id or ""
	normalized.content = type(normalized.content) == "string" and normalized.content or ""
	normalized.displayTime = normalized.displayTime or normalized.updateTime or normalized.createTime or ""
	return normalized
end

local function normalize_list_response(data)
	if type(data) ~= "table" then
		return { memos = {}, nextPageToken = "" }
	end
	local memos = {}
	local source = data.memos or {}
	for _, memo in ipairs(source) do
		local normalized = normalize_memo(memo)
		if normalized then
			table.insert(memos, normalized)
		end
	end
	return {
		memos = memos,
		nextPageToken = data.nextPageToken or data.next_page_token or "",
	}
end

local function get_modes()
	local cfg = get_config()
	local api_version = cfg.api_version or "auto"
	if api_version == "modern" then
		return { "modern" }
	end
	if api_version == "legacy" then
		return { "legacy" }
	end
	local pinned_mode = auto_mode_by_host[cfg.host]
	if pinned_mode == "modern" or pinned_mode == "legacy" then
		return { pinned_mode }
	end
	return { "modern", "legacy" }
end

local function can_try_fallback(mode, response)
	if mode ~= "modern" then
		return false
	end
	if (get_config().api_version or "auto") ~= "auto" then
		return false
	end
	local code = response.status or 0
	return code == 400 or code == 404 or code == 405 or code == 422
end

local function notify_fallback_once(operation)
	if fallback_notified then
		return
	end
	fallback_notified = true
	vim.schedule(function()
		vim.notify(
			string.format(
				"Memos API auto-fallback used for %s. Set api_version='legacy' or 'modern' in setup() to lock behavior.",
				operation
			),
			vim.log.levels.WARN
		)
	end)
end

local function execute(operation, builders, parser, callback)
	local modes = get_modes()

	local function attempt(index, first_error)
		local mode = modes[index]
		local build = builders[mode]
		if not build then
			callback(nil, "No request builder for mode: " .. mode)
			return
		end

		run_curl(build(), function(response)
			if response.ok then
				local cfg = get_config()
				if (cfg.api_version or "auto") == "auto" and cfg.host and cfg.host ~= "" then
					auto_mode_by_host[cfg.host] = mode
				end
				if first_error then
					notify_fallback_once(operation)
				end
				callback(parser(response.body), nil)
				return
			end

			if index < #modes and can_try_fallback(mode, response) then
				attempt(index + 1, first_error or response)
				return
			end

			callback(nil, parse_api_error(response))
		end)
	end

	attempt(1, nil)
end

local function build_list_url(mode, parent, filter, page_size, pageToken, order_by)
	local cfg = get_config()
	local params = {}
	if mode == "legacy" and parent and parent ~= "" then
		table.insert(params, "parent=" .. url_encode(parent))
	end

	if mode == "modern" then
		table.insert(params, "pageSize=" .. tostring(page_size))
	else
		table.insert(params, "page_size=" .. tostring(page_size))
	end

	if pageToken and pageToken ~= "" then
		table.insert(params, "pageToken=" .. url_encode(pageToken))
	end
	if filter and filter ~= "" then
		local raw_filter = 'content.contains("' .. vim.fn.escape(filter, '"') .. '")'
		table.insert(params, "filter=" .. url_encode(raw_filter))
	end
	if mode == "modern" and order_by and order_by ~= "" then
		table.insert(params, "orderBy=" .. url_encode(order_by))
	end

	return cfg.host .. "/api/v1/memos?" .. table.concat(params, "&")
end

function M.get_current_user(callback)
	local cfg = get_config()
	execute("get current user", {
		modern = function()
			return { "-X", "GET", cfg.host .. "/api/v1/auth/me" }
		end,
		legacy = function()
			return { "-X", "POST", cfg.host .. "/api/v1/auth/status" }
		end,
	}, function(body)
		return normalize_user(decode_json(body))
	end, function(user, err)
		if user then
			callback(user)
		else
			vim.schedule(function()
				vim.notify("Failed to get user info: " .. tostring(err), vim.log.levels.ERROR)
			end)
			callback(nil)
		end
	end)
end

function M.list_memos(parent, filter, page_size, pageToken, order_by, callback)
	execute("list memos", {
		modern = function()
			return { "-X", "GET", build_list_url("modern", parent, filter, page_size, pageToken, order_by) }
		end,
		legacy = function()
			return { "-X", "GET", build_list_url("legacy", parent, filter, page_size, pageToken, order_by) }
		end,
	}, function(body)
		return normalize_list_response(decode_json(body))
	end, function(data, err)
		if data then
			callback(data)
		else
			vim.schedule(function()
				vim.notify("Failed to fetch memos: " .. tostring(err), vim.log.levels.ERROR)
			end)
			callback(nil)
		end
	end)
end

function M.create_memo(content, callback)
	local cfg = get_config()
	local json_data = vim.json.encode({ content = content })

	execute("create memo", {
		modern = function()
			return {
				"-X",
				"POST",
				cfg.host .. "/api/v1/memos",
				"-H",
				"Content-Type: application/json",
				"--data",
				json_data,
			}
		end,
		legacy = function()
			return {
				"-X",
				"POST",
				cfg.host .. "/api/v1/memos",
				"-H",
				"Content-Type: application/json",
				"--data",
				json_data,
			}
		end,
	}, function(body)
		return normalize_memo(decode_json(body))
	end, function(new_memo, _)
		callback(new_memo)
	end)
end

function M.update_memo(memo_name, content, callback)
	local cfg = get_config()
	local json_data = vim.json.encode({ content = content })

	execute("update memo", {
		modern = function()
			return {
				"-X",
				"PATCH",
				cfg.host .. "/api/v1/" .. memo_name .. "?updateMask=content",
				"-H",
				"Content-Type: application/json",
				"--data",
				json_data,
			}
		end,
		legacy = function()
			return {
				"-X",
				"PATCH",
				cfg.host .. "/api/v1/" .. memo_name,
				"-H",
				"Content-Type: application/json",
				"--data",
				json_data,
			}
		end,
	}, function(_)
		return true
	end, function(success, err)
		if not success then
			vim.schedule(function()
				vim.notify("Failed to update memo: " .. tostring(err), vim.log.levels.ERROR)
			end)
		end
		callback(success == true)
	end)
end

function M.get_memo(memo_name, callback)
	local cfg = get_config()
	if not memo_name or memo_name == "" then
		callback(nil)
		return
	end

	execute("get memo", {
		modern = function()
			return { "-X", "GET", cfg.host .. "/api/v1/" .. memo_name }
		end,
		legacy = function()
			return { "-X", "GET", cfg.host .. "/api/v1/" .. memo_name }
		end,
	}, function(body)
		return normalize_memo(decode_json(body))
	end, function(memo, err)
		if memo then
			callback(memo)
		else
			vim.schedule(function()
				vim.notify("Failed to fetch memo: " .. tostring(err), vim.log.levels.ERROR)
			end)
			callback(nil)
		end
	end)
end

function M.update_memo_metadata(memo_name, fields, update_mask, callback)
	local cfg = get_config()
	local json_data = vim.json.encode(fields or {})
	local update_mask_value = update_mask or ""

	execute("update memo metadata", {
		modern = function()
			local url = cfg.host .. "/api/v1/" .. memo_name
			if update_mask_value ~= "" then
				url = url .. "?updateMask=" .. url_encode(update_mask_value)
			end
			return {
				"-X",
				"PATCH",
				url,
				"-H",
				"Content-Type: application/json",
				"--data",
				json_data,
			}
		end,
		legacy = function()
			return {
				"-X",
				"PATCH",
				cfg.host .. "/api/v1/" .. memo_name,
				"-H",
				"Content-Type: application/json",
				"--data",
				json_data,
			}
		end,
	}, function(_)
		return true
	end, function(success, err)
		if not success then
			vim.schedule(function()
				vim.notify("Failed to update memo metadata: " .. tostring(err), vim.log.levels.ERROR)
			end)
		end
		callback(success == true)
	end)
end

function M.delete_memo(memo_name, callback)
	local cfg = get_config()

	execute("delete memo", {
		modern = function()
			return { "-X", "DELETE", cfg.host .. "/api/v1/" .. memo_name }
		end,
		legacy = function()
			return { "-X", "DELETE", cfg.host .. "/api/v1/" .. memo_name }
		end,
	}, function(_)
		return true
	end, function(success, err)
		if not success then
			vim.schedule(function()
				vim.notify("Failed to delete memo: " .. tostring(err), vim.log.levels.ERROR)
			end)
		end
		callback(success == true)
	end)
end

function M.get_memo(memo_name, callback)
	if not memo_name or memo_name == "" then
		callback(nil, "Missing memo id")
		return
	end
	local cfg = get_config()
	execute("get memo", {
		modern = function()
			return { "-X", "GET", cfg.host .. "/api/v1/" .. memo_name }
		end,
		legacy = function()
			return { "-X", "GET", cfg.host .. "/api/v1/" .. memo_name }
		end,
	}, function(body)
		return normalize_memo(decode_json(body))
	end, function(memo, err)
		if not memo then
			callback(nil, err)
			return
		end
		callback(memo, nil)
	end)
end

return M
