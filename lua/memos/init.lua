local M = {}

M.config = {
	host = nil,
	token = nil,
	env_file = nil,
	username = nil,
	users = {},
	active_user = nil,
	page_size = 50,
	list_state = "NORMAL",
	list_order_by = "pinned desc, update_time desc",
	auto_save = false,
	window = {
		enable_float = true,
		width = 0.85,
		height = 0.85,
		border = "rounded",
	},
	keymaps = {
		start_memos = "<leader>mm",
		list = {
			add_memo = "a",
			edit_memo = "<CR>",
			refresh_list = "r",
			next_page = ".",
			quit = "q",
		},
		buffer = {
			save = "<leader>ms",
			back_to_list = "<Esc>",
		},
	},
}

local config_dir = vim.fn.stdpath("data") .. "/memos.nvim"
local config_file_path = config_dir .. "/memos_config.json"
local accounts = {
	users = {},
	active_user = nil,
}

local function is_non_empty(str)
	return type(str) == "string" and str ~= ""
end

local function normalize_host_value(host)
	local value = vim.trim(host or "")
	if value == "" then
		return ""
	end
	return value:gsub("/+$", "")
end

local function validate_host_value(host)
	if not is_non_empty(host) then
		return nil
	end
	if not host:match("^https?://") then
		return "Memos host must include http:// or https://: " .. host
	end
	return nil
end

local function unquote_env_value(value)
	local trimmed = vim.trim(value or "")
	local quote = trimmed:sub(1, 1)
	if (quote == '"' or quote == "'") and trimmed:sub(-1) == quote then
		trimmed = trimmed:sub(2, -2)
	end
	return trimmed
end

local function read_env_file(path)
	if not is_non_empty(path) then
		return {}, nil
	end
	if vim.fn.filereadable(path) ~= 1 then
		return nil, "Memos env_file is not readable: " .. path
	end

	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok or type(lines) ~= "table" then
		return nil, "Failed to read Memos env_file: " .. path
	end

	local out = {}
	for _, line in ipairs(lines) do
		local trimmed = vim.trim(line)
		if trimmed ~= "" and not trimmed:match("^#") then
			local key, value = trimmed:match("^([%w_]+)%s*=%s*(.*)$")
			if key == "MEMOS_HOST" or key == "MEMOS_TOKEN" then
				out[key] = unquote_env_value(value)
			end
		end
	end
	return out, nil
end

local function user_key(user)
	if not user or not user.username or not user.host then
		return nil
	end
	return user.username .. "@" .. normalize_host_value(user.host)
end

local function read_config_file()
	if vim.fn.filereadable(config_file_path) ~= 1 then
		return {}
	end
	local lines = vim.fn.readfile(config_file_path)
	if not lines or #lines == 0 or lines[1] == "" then
		return {}
	end
	local ok, decoded = pcall(vim.json.decode, lines[1])
	if ok and type(decoded) == "table" then
		return decoded
	end
	return {}
end

local function normalize_users(raw_users)
	if type(raw_users) ~= "table" then
		return {}
	end
	local normalized = {}
	local seen = {}
	for _, user in ipairs(raw_users) do
		if
			type(user) == "table"
			and is_non_empty(user.username)
			and is_non_empty(user.host)
			and is_non_empty(user.token)
		then
			local record = {
				username = user.username,
				host = normalize_host_value(user.host),
				token = user.token,
			}
			local key = user_key(record)
			if key and not seen[key] then
				table.insert(normalized, record)
				seen[key] = true
			end
		end
	end
	return normalized
end

local function resolve_active_user(raw_active_user, users)
	if not is_non_empty(raw_active_user) then
		return nil
	end
	local value = raw_active_user
	if raw_active_user:find("@") then
		local username, host = raw_active_user:match("^(.-)@(.+)$")
		if username and host then
			value = username .. "@" .. normalize_host_value(host)
		end
	end
	for _, user in ipairs(users) do
		if user_key(user) == value then
			return value
		end
	end
	for _, user in ipairs(users) do
		if user.username == raw_active_user then
			return user_key(user)
		end
	end
	return nil
end

local function migrate_legacy_config(data)
	local users = normalize_users(data.users)
	local active_user = data.active_user
	local migrated = false

	if #users == 0 and is_non_empty(data.host) and is_non_empty(data.token) then
		users = {
			{
				username = data.username or "default",
				host = normalize_host_value(data.host),
				token = data.token,
			},
		}
		active_user = user_key(users[1])
		migrated = true
	end

	local resolved = resolve_active_user(active_user, users)
	if not resolved and #users > 0 then
		resolved = user_key(users[1])
	end

	return {
		users = users,
		active_user = resolved,
		migrated = migrated,
	}
end

local function save_accounts()
	local ok_mkdir = pcall(vim.fn.mkdir, config_dir, "p")
	if not ok_mkdir then
		return false
	end
	local ok_write = pcall(vim.fn.writefile, {
		vim.json.encode({
			active_user = accounts.active_user,
			users = accounts.users,
		}),
	}, config_file_path)
	return ok_write == true
end

local function find_user(key)
	for _, user in ipairs(accounts.users) do
		if user_key(user) == key then
			return user
		end
	end
	return nil
end

local function apply_active_user_to_config(cfg)
	local user = find_user(accounts.active_user)
	if not user then
		return false
	end
	cfg.active_user = accounts.active_user
	cfg.username = user.username
	cfg.host = user.host
	cfg.token = user.token
	return true
end

function M.is_env_locked()
	return is_non_empty(M.config.env_file)
		or is_non_empty(os.getenv("MEMOS_HOST"))
		or is_non_empty(os.getenv("MEMOS_TOKEN"))
end

function M.list_users()
	return vim.deepcopy(accounts.users)
end

function M.switch_user(user_identifier)
	if not is_non_empty(user_identifier) then
		vim.notify("User identifier is required.", vim.log.levels.ERROR)
		return false
	end
	if M.is_env_locked() then
		vim.notify("Cannot switch account while MEMOS_HOST or MEMOS_TOKEN is set.", vim.log.levels.WARN)
		return false
	end

	local key = resolve_active_user(user_identifier, accounts.users)
	local user = key and find_user(key) or nil
	if not user then
		vim.notify("Memos user not found: " .. user_identifier, vim.log.levels.ERROR)
		return false
	end

	accounts.active_user = key
	if not save_accounts() then
		vim.notify("Failed to persist active Memos account.", vim.log.levels.WARN)
	end
	apply_active_user_to_config(M.config)
	pcall(function()
		require("memos.ui").on_account_switched()
	end)
	vim.notify("Switched Memos account to " .. user.username .. " (" .. user.host .. ").", vim.log.levels.INFO)
	return true
end

function M.switch_user_interactive()
	if #accounts.users == 0 then
		vim.notify("No saved Memos accounts. Use :MemosUserAdd first.", vim.log.levels.WARN)
		return
	end
	local items = {}
	for _, user in ipairs(accounts.users) do
		table.insert(items, {
			key = user_key(user),
			label = user.username .. " (" .. user.host .. ")",
		})
	end
	vim.ui.select(items, {
		prompt = "Select Memos account:",
		format_item = function(item)
			return item.label
		end,
	}, function(choice)
		if choice then
			M.switch_user(choice.key)
		end
	end)
end

local function add_user_record(user)
	local record = {
		username = user.username,
		host = normalize_host_value(user.host),
		token = user.token,
	}
	local key = user_key(record)
	if find_user(key) then
		return false, "Memos account already exists: " .. key
	end
	table.insert(accounts.users, record)
	if not accounts.active_user then
		accounts.active_user = key
	end
	if not save_accounts() then
		vim.notify("Failed to persist Memos account.", vim.log.levels.WARN)
	end
	return true, key
end

function M.add_user(user, switch_now)
	local ok, key_or_err = add_user_record(user)
	if not ok then
		vim.notify(key_or_err, vim.log.levels.ERROR)
		return false
	end
	if switch_now or not is_non_empty(M.config.host) or not is_non_empty(M.config.token) then
		M.switch_user(key_or_err)
	end
	return true
end

local function prompt_for_new_user(callback)
	vim.ui.input({ prompt = "Memos username:" }, function(username)
		if not is_non_empty(username) then
			vim.notify("No username entered.", vim.log.levels.ERROR)
			return
		end
		vim.ui.input({ prompt = "Memos host URL:" }, function(host)
			if not is_non_empty(host) then
				vim.notify("No host entered.", vim.log.levels.ERROR)
				return
			end
			vim.ui.input({ prompt = "Memos access token:", hide = true }, function(token)
				if not is_non_empty(token) then
					vim.notify("No token entered.", vim.log.levels.ERROR)
					return
				end
				callback({
					username = username,
					host = host,
					token = token,
				})
			end)
		end)
	end)
end

function M.add_user_interactive(on_done)
	prompt_for_new_user(function(user)
		if M.add_user(user, true) and on_done then
			on_done()
		end
	end)
end

function M.delete_user_interactive()
	if #accounts.users == 0 then
		vim.notify("No saved Memos accounts.", vim.log.levels.WARN)
		return
	end
	local items = {}
	for _, user in ipairs(accounts.users) do
		table.insert(items, {
			key = user_key(user),
			label = user.username .. " (" .. user.host .. ")",
		})
	end
	vim.ui.select(items, {
		prompt = "Delete Memos account:",
		format_item = function(item)
			return item.label
		end,
	}, function(choice)
		if not choice then
			return
		end
		if vim.fn.confirm("Delete " .. choice.label .. "?", "&Yes\n&No", 2) ~= 1 then
			return
		end
		local kept = {}
		for _, user in ipairs(accounts.users) do
			if user_key(user) ~= choice.key then
				table.insert(kept, user)
			end
		end
		accounts.users = kept
		if accounts.active_user == choice.key then
			accounts.active_user = accounts.users[1] and user_key(accounts.users[1]) or nil
		end
		save_accounts()
		if not M.is_env_locked() then
			if accounts.active_user then
				apply_active_user_to_config(M.config)
			else
				M.config.host = nil
				M.config.token = nil
				M.config.username = nil
				M.config.active_user = nil
			end
		end
		pcall(function()
			require("memos.ui").on_account_switched()
		end)
	end)
end

local function prompt_for_config(on_ready)
	if #accounts.users == 0 then
		M.add_user_interactive(on_ready)
		return
	end
	if apply_active_user_to_config(M.config) then
		on_ready()
		return
	end
	vim.notify("Memos credentials are not ready. Use :MemosUserAdd.", vim.log.levels.ERROR)
end

local function ensure_config(callback)
	if is_non_empty(M.config.host) and is_non_empty(M.config.token) then
		callback()
	else
		prompt_for_config(callback)
	end
end

function M.setup(opts)
	local final_config = vim.deepcopy(M.config)
	local file_data = read_config_file()
	local migrated = migrate_legacy_config(file_data)

	accounts.users = migrated.users
	accounts.active_user = migrated.active_user

	final_config.users = vim.deepcopy(accounts.users)
	final_config.active_user = accounts.active_user
	final_config = vim.tbl_deep_extend("force", final_config, opts or {})

	accounts.users = normalize_users(final_config.users)
	accounts.active_user = resolve_active_user(final_config.active_user, accounts.users)
	if not accounts.active_user and #accounts.users > 0 then
		accounts.active_user = user_key(accounts.users[1])
	end

	apply_active_user_to_config(final_config)
	local host_from_env = os.getenv("MEMOS_HOST")
	if is_non_empty(host_from_env) then
		final_config.host = normalize_host_value(host_from_env)
	end
	local token_from_env = os.getenv("MEMOS_TOKEN")
	if is_non_empty(token_from_env) then
		final_config.token = token_from_env
	end

	local env_values, env_err = read_env_file(final_config.env_file)
	if env_err then
		vim.notify(env_err, vim.log.levels.WARN)
	elseif env_values then
		if is_non_empty(env_values.MEMOS_HOST) then
			final_config.host = normalize_host_value(env_values.MEMOS_HOST)
		end
		if is_non_empty(env_values.MEMOS_TOKEN) then
			final_config.token = env_values.MEMOS_TOKEN
		end
	end

	if opts then
		if is_non_empty(opts.host) then
			final_config.host = normalize_host_value(opts.host)
		end
		if is_non_empty(opts.token) then
			final_config.token = opts.token
		end
	end

	final_config.users = vim.deepcopy(accounts.users)
	final_config.active_user = accounts.active_user
	final_config.page_size = tonumber(final_config.page_size) or 50
	local host_err = validate_host_value(final_config.host)
	if host_err then
		vim.notify(host_err, vim.log.levels.WARN)
	end
	M.config = final_config

	if migrated.migrated then
		save_accounts()
	end
end

function M.create_memo()
	ensure_config(function()
		require("memos.ui").create_memo_in_buffer()
	end)
end

function M.show_list()
	ensure_config(function()
		require("memos.ui").toggle_memos_list()
	end)
end

return M
