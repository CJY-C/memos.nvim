local M = {}

M.config = {
	host = nil,
	token = nil,
	username = nil,
	users = {},
	active_user = nil,
	auto_save = false,
	page_size = 50,
	api_version = "auto", -- "auto" | "modern" | "legacy"
	list_sort_default = "pinned desc, display_time desc",
	list_sort_presets = {
		"pinned desc, display_time desc",
		"display_time desc",
		"create_time desc",
	},
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
			copy_memo_id = "y",
			delete_memo = "d",
			delete_memo_visual = "dd",
			edit_memo = "<CR>",
			vsplit_edit_memo = "<Tab>",
			edit_metadata = "m",
			paste_memo = "p",
			search_memos = "s",
			refresh_list = "r",
			next_page = ".",
			quit = "q",
			toggle_sort = "<S-s>",
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
			if not seen[user.username] then
				table.insert(normalized, {
					username = user.username,
					host = user.host,
					token = user.token,
				})
				seen[user.username] = true
			end
		end
	end
	return normalized
end

local function migrate_legacy_config(data)
	local migrated = false
	local users = normalize_users(data.users)
	local active_user = data.active_user

	if #users == 0 and is_non_empty(data.host) and is_non_empty(data.token) then
		users = {
			{
				username = "default",
				host = data.host,
				token = data.token,
			},
		}
		active_user = "default"
		migrated = true
	end

	if #users > 0 and (not is_non_empty(active_user)) then
		active_user = users[1].username
	end

	return {
		users = users,
		active_user = active_user,
		migrated = migrated,
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

local function find_user(username)
	for _, user in ipairs(accounts.users) do
		if user.username == username then
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
	cfg.active_user = user.username
	cfg.username = user.username
	cfg.host = user.host
	cfg.token = user.token
	return true
end

function M.list_users()
	return vim.deepcopy(accounts.users)
end

function M.switch_user(username)
	if not is_non_empty(username) then
		vim.notify("Username is required.", vim.log.levels.ERROR)
		return false
	end
	local user = find_user(username)
	if not user then
		vim.notify("User '" .. username .. "' not found.", vim.log.levels.ERROR)
		return false
	end
	if M.is_env_locked() then
		vim.notify("Cannot switch account while MEMOS_HOST/MEMOS_TOKEN is set.", vim.log.levels.WARN)
		return false
	end
	if accounts.active_user == username then
		vim.notify("Already using account '" .. username .. "'.", vim.log.levels.INFO)
		return true
	end

	accounts.active_user = username
	if not save_accounts() then
		vim.notify("Failed to persist active account.", vim.log.levels.WARN)
	end
	apply_active_user_to_config(M.config)
	pcall(function()
		require("memos.ui").on_account_switched()
	end)
	vim.notify("Switched Memos account to '" .. username .. "'.", vim.log.levels.INFO)
	return true
end

function M.switch_user_interactive()
	if #accounts.users == 0 then
		vim.notify("No saved users. Use :MemosAddUser first.", vim.log.levels.WARN)
		return
	end
	local items = {}
	for _, user in ipairs(accounts.users) do
		table.insert(items, {
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
		M.switch_user(choice.username)
	end)
end

local function add_user_record(user)
	if find_user(user.username) then
		return false, "User '" .. user.username .. "' already exists."
	end
	table.insert(accounts.users, user)
	if not is_non_empty(accounts.active_user) then
		accounts.active_user = user.username
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
	vim.notify("Added Memos user '" .. user.username .. "'.", vim.log.levels.INFO)
	if switch_now then
		M.switch_user(user.username)
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
		if find_user(username) then
			vim.notify("User '" .. username .. "' already exists.", vim.log.levels.ERROR)
			return
		end
		vim.ui.input({ prompt = "Memos Host URL (e.g., http://127.0.0.1:5230):" }, function(host)
			if not is_non_empty(host) then
				vim.notify("No host entered.", vim.log.levels.ERROR)
				return
			end
			vim.ui.input({ prompt = "Memos Access Token:", hide = true }, function(token)
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
	prompt_for_new_user(function(new_user)
		local added = M.add_user(new_user, false)
		if not added then
			return
		end
		local choice = vim.fn.confirm("Switch to '" .. new_user.username .. "' now?", "&Yes\n&No", 1)
		if choice == 1 then
			M.switch_user(new_user.username)
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
		vim.notify("Memos credentials are not ready. Use :MemosSwitch or :MemosAddUser.", vim.log.levels.ERROR)
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
	accounts.active_user = final_config.active_user
	if #accounts.users > 0 and not find_user(accounts.active_user) then
		accounts.active_user = accounts.users[1].username
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

	local valid_api_versions = {
		auto = true,
		modern = true,
		legacy = true,
	}
	if not valid_api_versions[final_config.api_version] then
		vim.notify(
			string.format("Invalid api_version '%s', fallback to 'auto'.", tostring(final_config.api_version)),
			vim.log.levels.WARN
		)
		final_config.api_version = "auto"
	end

	M.config = final_config

	if migrated.migrated then
		save_accounts()
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

return M
