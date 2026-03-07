local M = {}

M.config = {
	host = nil,
	token = nil,
	username = nil,
	users = {},
	active_user = nil,
	auto_save = false,
	confirm_copy = false,
	metadata_title_max_len = 50,
	list_relations_limit = 20,
	list_relations_mode = "both", -- "out" | "in" | "both" | "none"
	list_relations_auto_expand = true,
	list_attachments_limit = 20,
	list_attachments_auto_expand = false,
	page_size = 50,
	api_version = "auto", -- "auto" | "v0.26" | "v0.25" | "v0.21"
	template_source = "online", -- "online" | "local" | "both"
	list_sort_default = "pinned desc, display_time desc",
	list_sort_presets = {
		"pinned desc, display_time desc",
		"display_time desc",
		"create_time desc",
	},
	list_state_default = "NORMAL",
	window = {
		enable_float = true,
		width = 0.85,
		height = 0.85,
		border = "rounded",
	},
	keymaps = {
		start_memos = "<leader>mm",
		create_from_template = "<leader>mt",
		list = {
			add_memo = "a",
			create_from_template = "t",
			copy_memo_id = "y",
			delete_memo = "d",
			delete_memo_visual = "dd",
			smart_delete = "D",
			edit_memo = "<CR>",
			vsplit_edit_memo = "<C-v>",
			split_edit_memo = "<C-s>",
			toggle_select_next = "<Tab>",
			toggle_select_prev = "<S-Tab>",
			multi_edit_metadata = "<S-m>",
			clear_selection = "c",
			toggle_relations = "gr",
			toggle_relations_all = "gR",
			toggle_attachments = "ga",
			toggle_attachments_all = "gA",
			edit_metadata = "m",
			paste_memo = "p",
			search_memos = { "s", "f" },
			search_fuzzy = "<S-f>",
			refresh_list = "r",
			next_page = ".",
			quit = "q",
			toggle_sort = "<S-s>",
			toggle_state = "<S-a>",
		},
		buffer = {
			save = "<leader>ms",
			back_to_list = "<Esc>",
			edit_metadata = "<leader>me",
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

local function read_config_file()
	if vim.fn.filereadable(config_file_path) ~= 1 then
		return {}
	end
	local lines = vim.fn.readfile(config_file_path)
	if not lines or #lines == 0 or lines[1] == "" then
		return {}
	end
	local ok, decoded = pcall(vim.json.decode, lines[1])
	if not ok or type(decoded) ~= "table" then
		return {}
	end
	return decoded
end

local function normalize_host_value(host)
	local value = vim.trim(host or "")
	if value == "" then
		return ""
	end
	value = value:gsub("/+$", "")
	return value
end

local function user_key(user)
	if not user or not user.username or not user.host then
		return nil
	end
	return user.username .. "@" .. normalize_host_value(user.host)
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
			local host = normalize_host_value(user.host)
			local key = user.username .. "@" .. host
			if not seen[key] then
				table.insert(normalized, {
					username = user.username,
					host = host,
					token = user.token,
				})
				seen[key] = true
			end
		end
	end
	return normalized
end

local function resolve_active_user(raw_active_user, users)
	if not is_non_empty(raw_active_user) then
		return nil, nil
	end
	if raw_active_user:find("@") then
		local uname, host = raw_active_user:match("^(.-)@(.+)$")
		if uname and host then
			local normalized_key = uname .. "@" .. normalize_host_value(host)
			for _, user in ipairs(users) do
				if user_key(user) == normalized_key then
					return normalized_key, nil
				end
			end
		end
	end
	local matches = {}
	for _, user in ipairs(users) do
		if user.username == raw_active_user then
			table.insert(matches, user)
		end
	end
	if #matches == 0 then
		return nil, nil
	end
	local warning = nil
	if #matches > 1 then
		warning = string.format(
			"Multiple accounts share username '%s'; picked %s.",
			raw_active_user,
			user_key(matches[1])
		)
	end
	return user_key(matches[1]), warning
end

local function migrate_legacy_config(data)
	local migrated = false
	local users = normalize_users(data.users)
	local active_user = data.active_user
	local warning = nil

	if #users == 0 and is_non_empty(data.host) and is_non_empty(data.token) then
		users = {
			{
				username = "default",
				host = normalize_host_value(data.host),
				token = data.token,
			},
		}
		active_user = user_key(users[1])
		migrated = true
	end

	local resolved, resolved_warning = resolve_active_user(active_user, users)
	if resolved_warning then
		warning = resolved_warning
		migrated = true
	end
	if not resolved and #users > 0 then
		resolved = user_key(users[1])
	end
	active_user = resolved

	return {
		users = users,
		active_user = active_user,
		migrated = migrated,
		warning = warning,
	}
end

local function save_accounts()
	local ok_mkdir = pcall(vim.fn.mkdir, config_dir, "p")
	if not ok_mkdir then
		return false
	end

	local to_save = {
		active_user = accounts.active_user,
		users = accounts.users,
	}
	local ok_write = pcall(vim.fn.writefile, { vim.json.encode(to_save) }, config_file_path)
	if not ok_write then
		return false
	end
	return true
end

local function find_user(key)
	for _, user in ipairs(accounts.users) do
		if user_key(user) == key then
			return user
		end
	end
	return nil
end

function M.is_env_locked()
	return is_non_empty(os.getenv("MEMOS_HOST")) or is_non_empty(os.getenv("MEMOS_TOKEN"))
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

function M.list_users()
	return vim.deepcopy(accounts.users)
end

function M.switch_user(user_identifier)
	if not is_non_empty(user_identifier) then
		vim.notify("User identifier is required.", vim.log.levels.ERROR)
		return false
	end
	local key = user_identifier
	if user_identifier:find("@") then
		local uname, host = user_identifier:match("^(.-)@(.+)$")
		if uname and host then
			key = uname .. "@" .. normalize_host_value(host)
		end
	end
	local user = find_user(key)
	if not user then
		local matches = {}
		for _, candidate in ipairs(accounts.users) do
			if candidate.username == user_identifier then
				table.insert(matches, candidate)
			end
		end
		if #matches == 1 then
			user = matches[1]
			key = user_key(user)
		elseif #matches > 1 then
			vim.notify("Multiple accounts named '" .. user_identifier .. "'. Use :MemosSwitch.", vim.log.levels.ERROR)
			return false
		else
			vim.notify("User '" .. user_identifier .. "' not found.", vim.log.levels.ERROR)
			return false
		end
	end
	if M.is_env_locked() then
		vim.notify("Cannot switch account while MEMOS_HOST/MEMOS_TOKEN is set.", vim.log.levels.WARN)
		return false
	end
	if accounts.active_user == key then
		vim.notify("Already using account '" .. user.username .. " (" .. user.host .. ")'.", vim.log.levels.INFO)
		return true
	end

	accounts.active_user = key
	if not save_accounts() then
		vim.notify("Failed to persist active account.", vim.log.levels.WARN)
	end
	apply_active_user_to_config(M.config)
	pcall(function()
		require("memos.ui").on_account_switched()
	end)
	vim.notify("Switched Memos account to '" .. user.username .. " (" .. user.host .. ")'.", vim.log.levels.INFO)
	return true
end

function M.switch_user_interactive()
	if #accounts.users == 0 then
		vim.notify("No saved users. Use :MemosUserAdd first.", vim.log.levels.WARN)
		return
	end
	local items = {}
	for _, user in ipairs(accounts.users) do
		table.insert(items, {
			key = user_key(user),
			username = user.username,
			host = user.host,
		})
	end
	vim.ui.select(items, {
		prompt = "Select Memos user:",
		format_item = function(item)
			return string.format("%s (%s)", item.username, item.host)
		end,
	}, function(choice)
		if not choice then
			return
		end
		M.switch_user(choice.key)
	end)
end

function M.delete_user_interactive()
	if #accounts.users == 0 then
		vim.notify("No saved users. Use :MemosUserAdd first.", vim.log.levels.WARN)
		return
	end
	local items = {}
	for _, user in ipairs(accounts.users) do
		table.insert(items, {
			key = user_key(user),
			username = user.username,
			host = user.host,
		})
	end
	vim.ui.select(items, {
		prompt = "Delete Memos user:",
		format_item = function(item)
			return string.format("%s (%s)", item.username, item.host)
		end,
	}, function(choice)
		if not choice then
			return
		end
		local confirm = vim.fn.confirm(
			string.format("Delete user '%s (%s)'?", choice.username, choice.host),
			"&Yes\n&No",
			2
		)
		if confirm ~= 1 then
			return
		end
		local new_users = {}
		local removed = false
		for _, user in ipairs(accounts.users) do
			if user_key(user) ~= choice.key then
				table.insert(new_users, user)
			else
				removed = true
			end
		end
		if not removed then
			return
		end
		accounts.users = new_users
		local active_changed = false
		if accounts.active_user == choice.key then
			if #accounts.users > 0 then
				accounts.active_user = user_key(accounts.users[1])
			else
				accounts.active_user = nil
			end
			active_changed = true
		end
		if not save_accounts() then
			vim.notify("Failed to persist users config.", vim.log.levels.WARN)
		end
		if active_changed then
			if not M.is_env_locked() then
				if accounts.active_user then
					apply_active_user_to_config(M.config)
				else
					M.config.active_user = nil
					M.config.username = nil
					M.config.host = nil
					M.config.token = nil
				end
			else
				M.config.active_user = accounts.active_user
			end
			pcall(function()
				require("memos.ui").on_account_switched()
			end)
		end
		vim.notify("Deleted Memos user '" .. choice.username .. " (" .. choice.host .. ")'.", vim.log.levels.INFO)
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
		return false, "User '" .. record.username .. " (" .. record.host .. ")' already exists."
	end
	table.insert(accounts.users, record)
	if not is_non_empty(accounts.active_user) then
		accounts.active_user = key
	end
	if not save_accounts() then
		vim.notify("Failed to persist users config.", vim.log.levels.WARN)
	end
	return true
end

function M.add_user(user, switch_now)
	local ok, err = add_user_record(user)
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
		return false
	end
	local host = normalize_host_value(user.host)
	vim.notify("Added Memos user '" .. user.username .. " (" .. host .. ")'.", vim.log.levels.INFO)
	if switch_now then
		M.switch_user(user.username .. "@" .. host)
	elseif not is_non_empty(M.config.host) and not is_non_empty(M.config.token) and not M.is_env_locked() then
		apply_active_user_to_config(M.config)
	end
	return true
end

local function prompt_for_new_user(callback)
	vim.ui.input({ prompt = "Memos Username:" }, function(username)
		if not is_non_empty(username) then
			vim.notify("No username entered.", vim.log.levels.ERROR)
			return
		end
		vim.ui.input({ prompt = "Memos Host URL (e.g., http://127.0.0.1:5230):" }, function(host)
			if not is_non_empty(host) then
				vim.notify("No host entered.", vim.log.levels.ERROR)
				return
			end
			local normalized_host = normalize_host_value(host)
			local key = username .. "@" .. normalized_host
			if find_user(key) then
				vim.notify("User '" .. username .. " (" .. normalized_host .. ")' already exists.", vim.log.levels.ERROR)
				return
			end
			vim.ui.input({ prompt = "Memos Access Token:", hide = true }, function(token)
				if not is_non_empty(token) then
					vim.notify("No token entered.", vim.log.levels.ERROR)
					return
				end
				callback({
					username = username,
					host = normalized_host,
					token = token,
				})
			end)
		end)
	end)
end

function M.add_user_interactive(on_done)
	prompt_for_new_user(function(new_user)
		local added = M.add_user(new_user, false)
		if not added then
			return
		end
		local choice = vim.fn.confirm("Switch to '" .. new_user.username .. "' now?", "&Yes\n&No", 1)
		if choice == 1 then
			M.switch_user(user_key(new_user))
		end
		if on_done then
			on_done()
		end
	end)
end

local function prompt_for_config(on_ready)
	if #accounts.users == 0 then
		M.add_user_interactive(function()
			if is_non_empty(M.config.host) and is_non_empty(M.config.token) then
				on_ready()
			end
		end)
		return
	end

	if not M.is_env_locked() and apply_active_user_to_config(M.config) then
		on_ready()
	else
		vim.notify("Memos credentials are not ready. Use :MemosSwitch or :MemosUserAdd.", vim.log.levels.ERROR)
	end
end

local function normalize_api_version(value)
	if value == nil or value == "" then
		return "auto"
	end
	local raw = tostring(value)
	local lowered = string.lower(raw)
	if lowered == "auto" then
		return "auto"
	end
	if lowered == "modern" then
		return "v0.26", "modern"
	end
	if lowered == "legacy" then
		return "v0.25", "legacy"
	end
	if lowered:match("^%d") then
		lowered = "v" .. lowered
	end
	local major, minor = lowered:match("^v(%d+)%.(%d+)")
	if major and minor then
		return string.format("v%d.%d", tonumber(major), tonumber(minor))
	end
	return nil
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
	local resolved_active, _ = resolve_active_user(final_config.active_user, accounts.users)
	if not resolved_active and #accounts.users > 0 then
		resolved_active = user_key(accounts.users[1])
	end
	accounts.active_user = resolved_active
	if #accounts.users > 0 and not find_user(accounts.active_user) then
		accounts.active_user = user_key(accounts.users[1])
	end

	local uses_direct_credentials = opts and (is_non_empty(opts.host) or is_non_empty(opts.token))
	if not uses_direct_credentials then
		apply_active_user_to_config(final_config)
	end

	local host_from_env = os.getenv("MEMOS_HOST")
	if is_non_empty(host_from_env) then
		final_config.host = host_from_env
	end
	local token_from_env = os.getenv("MEMOS_TOKEN")
	if is_non_empty(token_from_env) then
		final_config.token = token_from_env
	end

	final_config.users = vim.deepcopy(accounts.users)
	final_config.active_user = accounts.active_user

	local normalized_api_version, alias = normalize_api_version(final_config.api_version)
	local valid_api_versions = {
		auto = true,
		["v0.26"] = true,
		["v0.25"] = true,
		["v0.21"] = true,
	}
	if not normalized_api_version or not valid_api_versions[normalized_api_version] then
		vim.notify(
			string.format("Invalid api_version '%s', fallback to 'auto'.", tostring(final_config.api_version)),
			vim.log.levels.WARN
		)
		final_config.api_version = "auto"
	else
		final_config.api_version = normalized_api_version
		if alias then
			vim.notify(
				string.format("api_version '%s' is deprecated; use '%s' instead.", alias, normalized_api_version),
				vim.log.levels.WARN
			)
		end
	end

	local template_source = string.lower(tostring(final_config.template_source or "online"))
	if template_source ~= "online" and template_source ~= "local" and template_source ~= "both" then
		vim.notify(
			string.format("Invalid template_source '%s', fallback to 'online'.", tostring(final_config.template_source)),
			vim.log.levels.WARN
		)
		template_source = "online"
	end
	final_config.template_source = template_source

	M.config = final_config

	if migrated.migrated then
		save_accounts()
	end
	if migrated.warning then
		vim.notify(migrated.warning, vim.log.levels.WARN)
	end
end

local function ensure_config(callback)
	if is_non_empty(M.config.host) and is_non_empty(M.config.token) then
		callback()
	else
		prompt_for_config(callback)
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

function M.modify_meta()
	ensure_config(function()
		require("memos.ui").modify_current_memo_metadata()
	end)
end

local function run_template_action(action)
	require("memos.template").resolve_source(function(source)
		if not source then
			return
		end
		local function run()
			require("memos.template")[action](source)
		end
		if source == "online" then
			ensure_config(run)
		else
			run()
		end
	end)
end

function M.template_create()
	run_template_action("template_create")
end

function M.template_edit()
	run_template_action("template_edit")
end

function M.template_delete()
	run_template_action("template_delete")
end

function M.create_memo_from_template()
	run_template_action("create_memo_from_template")
end

return M
