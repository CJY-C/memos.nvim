local M = {}

M.config = {
	host = nil,
	token = nil,
	env_file = nil,
	page_size = 50,
	list_state = "NORMAL",
	list_order_by = "pinned desc, update_time desc",
	list_style = "default",
	auto_save = false,
	window = {
		enable_float = true,
		width = 0.85,
		height = 0.85,
		border = "rounded",
	},
	keymaps = {
		list = {
			add_memo = "a",
			edit_memo = "<CR>",
			edit_memo_split = "o",
			edit_memo_vsplit = "v",
			search_memos = "s",
			copy_memo_id = "y",
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

local function apply_env_file(cfg)
	local env_values, env_err = read_env_file(cfg.env_file)
	if env_err then
		vim.notify(env_err, vim.log.levels.WARN)
		return
	end
	if not env_values then
		return
	end
	if is_non_empty(env_values.MEMOS_HOST) then
		cfg.host = normalize_host_value(env_values.MEMOS_HOST)
	end
	if is_non_empty(env_values.MEMOS_TOKEN) then
		cfg.token = env_values.MEMOS_TOKEN
	end
end

local function apply_process_env(cfg)
	local host_from_env = os.getenv("MEMOS_HOST")
	if is_non_empty(host_from_env) then
		cfg.host = normalize_host_value(host_from_env)
	end
	local token_from_env = os.getenv("MEMOS_TOKEN")
	if is_non_empty(token_from_env) then
		cfg.token = token_from_env
	end
end

local function apply_explicit_credentials(cfg, opts)
	if not opts then
		return
	end
	if is_non_empty(opts.host) then
		cfg.host = normalize_host_value(opts.host)
	end
	if is_non_empty(opts.token) then
		cfg.token = opts.token
	end
end

function M.has_credentials()
	return is_non_empty(M.config.host) and is_non_empty(M.config.token)
end

function M.setup(opts)
	opts = opts or {}
	local final_config = vim.tbl_deep_extend("force", vim.deepcopy(M.config), opts)

	apply_process_env(final_config)
	apply_env_file(final_config)
	apply_explicit_credentials(final_config, opts)

	final_config.page_size = tonumber(final_config.page_size) or 50
	local host_err = validate_host_value(final_config.host)
	if host_err then
		vim.notify(host_err, vim.log.levels.WARN)
	end
	M.config = final_config
end

local function ensure_config(callback)
	if M.has_credentials() then
		callback()
		return
	end
	vim.notify(
		"Memos credentials are not configured. Use setup({ env_file = ... }), setup({ host = ..., token = ... }), or MEMOS_HOST/MEMOS_TOKEN.",
		vim.log.levels.ERROR
	)
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

function M.status()
	local ok, ui = pcall(require, "memos.ui")
	if not ok or not ui.status then
		return {
			state = "idle",
			text = "",
			last_refresh_at = nil,
			last_error = nil,
		}
	end
	return ui.status()
end

function M.statusline()
	local ok, ui = pcall(require, "memos.ui")
	if not ok or not ui.statusline then
		return ""
	end
	return ui.statusline()
end

return M
