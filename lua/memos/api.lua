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

local function iso_from_unix(ts)
	if not ts then
		return ""
	end
	local num = tonumber(ts)
	if not num or num <= 0 then
		return ""
	end
	return os.date("!%Y-%m-%dT%H:%M:%SZ", num)
end

local function iso_to_unix(value)
	if type(value) ~= "string" then
		return nil
	end
	local trimmed = vim.trim(value)
	if trimmed == "" then
		return nil
	end
	if trimmed:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d$") then
		trimmed = trimmed .. "Z"
	end
	local ok, ts = pcall(vim.fn.strptime, "%Y-%m-%dT%H:%M:%SZ", trimmed)
	if not ok then
		return nil
	end
	local num = tonumber(ts)
	if not num or num <= 0 then
		return nil
	end
	return num
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

local function parse_memo_id(memo_name)
	if not memo_name then
		return nil
	end
	local raw = tostring(memo_name)
	local id = raw:match("^memos/(%d+)$") or raw:match("^(%d+)$")
	return id
end

local function extract_v021_query(filter)
	local raw = vim.trim(filter or "")
	if raw == "" then
		return { content = nil, tag = nil }
	end
	local tag = raw:match("#([%w_/%-]+)") or raw:match('"([^"]+)"%s+in%s+tags')
	local content = raw:match('content%.contains%("([^"]+)"%)')
	if not content then
		local cleaned = raw:gsub("#[%w_/%-]+", " ")
		cleaned = cleaned:gsub('"[^"]+"%s+in%s+tags', " ")
		cleaned = vim.trim(cleaned)
		if cleaned ~= "" then
			content = cleaned
		end
	end
	return { content = content, tag = tag }
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

	local name = user.name or user.username or user.id
	if not name then
		return nil
	end
	return vim.tbl_extend("keep", { name = name }, user)
end

local function normalize_memo(memo, mode)
	if type(memo) ~= "table" then
		return nil
	end
	if mode == "v0.21" then
		local id = memo.id or memo.memoId
		local name = id and ("memos/" .. tostring(id)) or memo.uid or memo.name or ""
		local created = iso_from_unix(memo.createdTs)
		local updated = iso_from_unix(memo.updatedTs)
		local display = updated ~= "" and updated or created
		local state = memo.rowStatus or memo.state
		if state ~= "ARCHIVED" then
			state = "NORMAL"
		end
		return {
			name = name,
			content = type(memo.content) == "string" and memo.content or "",
			displayTime = display or "",
			updateTime = updated or "",
			createTime = created or "",
			pinned = memo.pinned == true,
			state = state,
			visibility = memo.visibility,
		}
	end
	local normalized = vim.deepcopy(memo)
	normalized.name = normalized.name or normalized.id or ""
	normalized.content = type(normalized.content) == "string" and normalized.content or ""
	normalized.displayTime = normalized.displayTime or normalized.updateTime or normalized.createTime or ""
	return normalized
end

local function normalize_list_response(data, mode, meta)
	if type(data) ~= "table" then
		return { memos = {}, nextPageToken = "" }
	end
	if mode == "v0.21" then
		local memos = {}
		for _, memo in ipairs(data) do
			local normalized = normalize_memo(memo, mode)
			if normalized then
				table.insert(memos, normalized)
			end
		end
		local next_token = ""
		local limit = meta and meta.limit or 0
		local offset = meta and meta.offset or 0
		if limit > 0 and #data >= limit then
			next_token = tostring(offset + limit)
		end
		return {
			memos = memos,
			nextPageToken = next_token,
		}
	end
	local memos = {}
	local source = data.memos or {}
	for _, memo in ipairs(source) do
		local normalized = normalize_memo(memo, mode)
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
	if api_version ~= "auto" then
		return { api_version }
	end
	local pinned_mode = auto_mode_by_host[cfg.host]
	if pinned_mode then
		return { pinned_mode }
	end
	return { "v0.26", "v0.25", "v0.21" }
end

local function can_try_fallback(mode, response)
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
				"Memos API auto-fallback used for %s. Set api_version to 'v0.26', 'v0.25', or 'v0.21' to lock behavior.",
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
				callback(parser(response.body, mode), nil)
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

local function build_list_url(mode, parent, filter, page_size, pageToken, order_by, state)
	local cfg = get_config()
	local params = {}
	if mode == "v0.25" and parent and parent ~= "" then
		table.insert(params, "parent=" .. url_encode(parent))
	end

	if mode == "v0.26" then
		table.insert(params, "pageSize=" .. tostring(page_size))
	else
		table.insert(params, "page_size=" .. tostring(page_size))
	end

	if pageToken and pageToken ~= "" then
		table.insert(params, "pageToken=" .. url_encode(pageToken))
	end
	if filter and filter ~= "" then
		local is_cel = false
		if filter:find("content%.contains%(") then
			is_cel = true
		elseif filter:find(" in tags") or filter:find("tags") then
			is_cel = true
		elseif filter:find("&&") or filter:find("||") then
			is_cel = true
		elseif filter:find("==") or filter:find("~=") or filter:find(">=") or filter:find("<=") then
			is_cel = true
		elseif filter:find("%(") or filter:find("%)") then
			is_cel = true
		end
		local raw_filter
		if is_cel then
			raw_filter = filter
		else
			raw_filter = 'content.contains("' .. vim.fn.escape(filter, '"') .. '")'
		end
		table.insert(params, "filter=" .. url_encode(raw_filter))
	end
	if mode == "v0.26" and state and state ~= "" then
		table.insert(params, "state=" .. url_encode(state))
	end
	if mode == "v0.26" and order_by and order_by ~= "" then
		table.insert(params, "orderBy=" .. url_encode(order_by))
	end

	return cfg.host .. "/api/v1/memos?" .. table.concat(params, "&")
end

local function build_list_url_v021(creator, filter, page_size, pageToken, state)
	local cfg = get_config()
	local params = {}
	if creator and creator ~= "" then
		table.insert(params, "creatorUsername=" .. url_encode(creator))
	end
	if state and state ~= "" then
		table.insert(params, "rowStatus=" .. url_encode(state))
	end
	local query = extract_v021_query(filter)
	if query.tag and query.tag ~= "" then
		table.insert(params, "tag=" .. url_encode(query.tag))
	end
	if query.content and query.content ~= "" then
		table.insert(params, "content=" .. url_encode(query.content))
	end
	local limit = tonumber(page_size) or 50
	local offset = tonumber(pageToken) or 0
	table.insert(params, "limit=" .. tostring(limit))
	table.insert(params, "offset=" .. tostring(offset))
	return cfg.host .. "/api/v1/memo?" .. table.concat(params, "&"), offset, limit
end

function M.get_current_user(callback)
	local cfg = get_config()
	execute("get current user", {
		["v0.26"] = function()
			return { "-X", "GET", cfg.host .. "/api/v1/auth/me" }
		end,
		["v0.25"] = function()
			return { "-X", "POST", cfg.host .. "/api/v1/auth/status" }
		end,
		["v0.21"] = function()
			return { "-X", "GET", cfg.host .. "/api/v1/user/me" }
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

function M.list_memos(parent, filter, page_size, pageToken, order_by, state, callback)
	local v021_meta = nil
	execute("list memos", {
		["v0.26"] = function()
			return { "-X", "GET", build_list_url("v0.26", parent, filter, page_size, pageToken, order_by, state) }
		end,
		["v0.25"] = function()
			return { "-X", "GET", build_list_url("v0.25", parent, filter, page_size, pageToken, order_by, state) }
		end,
		["v0.21"] = function()
			local url, offset, limit = build_list_url_v021(parent, filter, page_size, pageToken, state)
			v021_meta = { offset = offset, limit = limit }
			return { "-X", "GET", url }
		end,
	}, function(body, mode)
		return normalize_list_response(decode_json(body), mode, v021_meta)
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
		["v0.26"] = function()
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
		["v0.25"] = function()
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
		["v0.21"] = function()
			return {
				"-X",
				"POST",
				cfg.host .. "/api/v1/memo",
				"-H",
				"Content-Type: application/json",
				"--data",
				json_data,
			}
		end,
	}, function(body, mode)
		return normalize_memo(decode_json(body), mode)
	end, function(new_memo, _)
		callback(new_memo)
	end)
end

function M.update_memo(memo_name, content, callback)
	local cfg = get_config()
	local mode = M.get_active_version() or (cfg.api_version or "auto")
	if mode == "v0.21" then
		local id = parse_memo_id(memo_name) or memo_name or ""
		if not tostring(id):match("^%d+$") then
			vim.schedule(function()
				vim.notify("Failed to update memo: memo id is not numeric. Refresh the list and reopen.", vim.log.levels.ERROR)
			end)
			callback(false)
			return
		end
	end
	local json_data = vim.json.encode({ content = content })

	execute("update memo", {
		["v0.26"] = function()
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
		["v0.25"] = function()
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
		["v0.21"] = function()
			local id = parse_memo_id(memo_name) or memo_name or ""
			return {
				"-X",
				"PATCH",
				cfg.host .. "/api/v1/memo/" .. id,
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
		["v0.26"] = function()
			return { "-X", "GET", cfg.host .. "/api/v1/" .. memo_name }
		end,
		["v0.25"] = function()
			return { "-X", "GET", cfg.host .. "/api/v1/" .. memo_name }
		end,
		["v0.21"] = function()
			local id = parse_memo_id(memo_name) or memo_name or ""
			return { "-X", "GET", cfg.host .. "/api/v1/memo/" .. id }
		end,
	}, function(body, mode)
		local decoded = decode_json(body)
		if mode == "v0.21" and type(decoded) == "table" and decoded[1] then
			return normalize_memo(decoded[1], mode)
		end
		return normalize_memo(decoded, mode)
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
	local update_mask_value = update_mask or ""
	local base_fields = fields or {}
	local json_data = vim.json.encode(base_fields)
	local v021_id = parse_memo_id(memo_name) or memo_name or ""
	local mode = M.get_active_version() or (cfg.api_version or "auto")
	if mode == "v0.21" and not tostring(v021_id):match("^%d+$") then
		vim.schedule(function()
			vim.notify("Failed to update memo metadata: memo id is not numeric. Refresh the list and reopen.", vim.log.levels.ERROR)
		end)
		callback(false)
		return
	end

	local function build_v021_payload()
		local payload = {}
		if base_fields.content ~= nil then
			payload.content = base_fields.content
		end
		if base_fields.visibility ~= nil then
			payload.visibility = base_fields.visibility
		end
		if base_fields.rowStatus ~= nil then
			payload.rowStatus = base_fields.rowStatus
		elseif base_fields.state ~= nil then
			payload.rowStatus = base_fields.state
		end
		if base_fields.createdTs ~= nil then
			payload.createdTs = base_fields.createdTs
		elseif base_fields.createTime ~= nil then
			local ts = iso_to_unix(base_fields.createTime)
			if ts then
				payload.createdTs = ts
			end
		end
		if base_fields.updatedTs ~= nil then
			payload.updatedTs = base_fields.updatedTs
		end
		return payload
	end

	execute("update memo metadata", {
		["v0.26"] = function()
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
		["v0.25"] = function()
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
		["v0.21"] = function()
			if update_mask_value == "pinned" then
				local pinned = base_fields.pinned == true
				return {
					"-X",
					"POST",
					cfg.host .. "/api/v1/memo/" .. v021_id .. "/organizer",
					"-H",
					"Content-Type: application/json",
					"--data",
					vim.json.encode({ pinned = pinned }),
				}
			end
			local payload = build_v021_payload()
			return {
				"-X",
				"PATCH",
				cfg.host .. "/api/v1/memo/" .. v021_id,
				"-H",
				"Content-Type: application/json",
				"--data",
				vim.json.encode(payload),
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
		["v0.26"] = function()
			return { "-X", "DELETE", cfg.host .. "/api/v1/" .. memo_name }
		end,
		["v0.25"] = function()
			return { "-X", "DELETE", cfg.host .. "/api/v1/" .. memo_name }
		end,
		["v0.21"] = function()
			local id = parse_memo_id(memo_name) or memo_name or ""
			return { "-X", "DELETE", cfg.host .. "/api/v1/memo/" .. id }
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

function M.get_active_version()
	local cfg = get_config()
	local api_version = cfg.api_version or "auto"
	if api_version ~= "auto" then
		return api_version
	end
	local host = cfg.host
	if host and auto_mode_by_host[host] then
		return auto_mode_by_host[host]
	end
	return nil
end

function M.get_capabilities()
	local cfg = get_config()
	local mode = M.get_active_version()
	if not mode then
		if cfg.api_version and cfg.api_version ~= "auto" then
			mode = cfg.api_version
		else
			mode = "v0.26"
		end
	end
	return {
		mode = mode,
		supports_sort = mode == "v0.26",
		supports_state = mode == "v0.26" or mode == "v0.21",
		search_mode = mode == "v0.21" and "simple" or "cel",
		supports_display_time = mode ~= "v0.21",
		supports_relations_api = mode == "v0.21",
	}
end

local function ensure_v021(callback, operation)
	local mode = M.get_active_version() or (get_config().api_version or "auto")
	if mode ~= "v0.21" then
		if callback then
			callback(nil, string.format("%s is only supported in v0.21 mode.", operation))
		end
		return false
	end
	return true
end

function M.list_memo_relations(memo_name, callback)
	if not ensure_v021(callback, "Relations") then
		return
	end
	local cfg = get_config()
	local id = parse_memo_id(memo_name) or memo_name or ""
	run_curl({ "-X", "GET", cfg.host .. "/api/v1/memo/" .. id .. "/relation" }, function(response)
		if response.ok then
			callback(decode_json(response.body) or {}, nil)
		else
			callback(nil, parse_api_error(response))
		end
	end)
end

function M.create_memo_relation(memo_name, related_memo_name, relation_type, callback)
	if not ensure_v021(callback, "Relations") then
		return
	end
	local cfg = get_config()
	local id = parse_memo_id(memo_name) or memo_name or ""
	local related_id = parse_memo_id(related_memo_name) or related_memo_name or ""
	local related_num = tonumber(related_id)
	if not related_num then
		callback(false, "Invalid related memo id.")
		return
	end
	local body = {
		relatedMemoId = related_num,
		type = relation_type or "REFERENCE",
	}
	run_curl({
		"-X",
		"POST",
		cfg.host .. "/api/v1/memo/" .. id .. "/relation",
		"-H",
		"Content-Type: application/json",
		"--data",
		vim.json.encode(body),
	}, function(response)
		if response.ok then
			callback(true, nil)
		else
			callback(false, parse_api_error(response))
		end
	end)
end

function M.delete_memo_relation(memo_name, related_memo_name, relation_type, callback)
	if not ensure_v021(callback, "Relations") then
		return
	end
	local cfg = get_config()
	local id = parse_memo_id(memo_name) or memo_name or ""
	local related_id = parse_memo_id(related_memo_name) or related_memo_name or ""
	if related_id == "" then
		callback(false, "Invalid related memo id.")
		return
	end
	local rel_type = relation_type or "REFERENCE"
	run_curl({
		"-X",
		"DELETE",
		cfg.host .. "/api/v1/memo/" .. id .. "/relation/" .. related_id .. "/type/" .. rel_type,
	}, function(response)
		if response.ok then
			callback(true, nil)
		else
			callback(false, parse_api_error(response))
		end
	end)
end

function M.get_memo(memo_name, callback)
	if not memo_name or memo_name == "" then
		callback(nil, "Missing memo id")
		return
	end
	local cfg = get_config()
	execute("get memo", {
		["v0.26"] = function()
			return { "-X", "GET", cfg.host .. "/api/v1/" .. memo_name }
		end,
		["v0.25"] = function()
			return { "-X", "GET", cfg.host .. "/api/v1/" .. memo_name }
		end,
		["v0.21"] = function()
			local id = parse_memo_id(memo_name) or memo_name or ""
			return { "-X", "GET", cfg.host .. "/api/v1/memo/" .. id }
		end,
	}, function(body, mode)
		local decoded = decode_json(body)
		if mode == "v0.21" and type(decoded) == "table" and decoded[1] then
			return normalize_memo(decoded[1], mode)
		end
		return normalize_memo(decoded, mode)
	end, function(memo, err)
		if not memo then
			callback(nil, err)
			return
		end
		callback(memo, nil)
	end)
end

return M
