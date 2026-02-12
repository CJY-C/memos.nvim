local api = require("memos.api")

local M = {}

local TEMPLATE_TAG = "#type/template"
local TEMPLATE_TAG_RAW = "type/template"

local function get_config()
	return require("memos").config
end

local function is_non_empty(str)
	return type(str) == "string" and str ~= ""
end

local function now_iso()
	return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function template_dir()
	return vim.fn.stdpath("data") .. "/memos.nvim"
end

local function template_file_path()
	return template_dir() .. "/memos_templates.json"
end

local function normalize_source(value)
	local source = string.lower(tostring(value or "online"))
	if source == "online" or source == "local" or source == "both" then
		return source
	end
	return "online"
end

local function strip_template_tag(content)
	local text = tostring(content or "")
	text = text:gsub("^%s*#type/template%s*\n?", "")
	text = text:gsub("\n%s*#type/template%s*\n?", "\n")
	text = text:gsub("%s+#type/template", " ")
	text = text:gsub("#type/template", "")
	return text
end

local function ensure_template_tag(content)
	local text = tostring(content or "")
	if text:find(TEMPLATE_TAG, 1, true) then
		return text
	end
	if text == "" then
		return TEMPLATE_TAG
	end
	if text:sub(-1) == "\n" then
		return text .. TEMPLATE_TAG
	end
	return text .. "\n" .. TEMPLATE_TAG
end

local function extract_title(content)
	local first_line = ""
	for line in tostring(content or ""):gmatch("[^\n]+") do
		if vim.trim(line) ~= "" then
			first_line = vim.trim(line)
			break
		end
	end
	if first_line == "" then
		return "(empty template)"
	end
	return first_line:gsub("[/\\]", "_"):sub(1, 60)
end

local function normalize_local_templates(raw_templates)
	local out = {}
	if type(raw_templates) ~= "table" then
		return out
	end
	for _, item in ipairs(raw_templates) do
		if type(item) == "table" and is_non_empty(item.id) then
			table.insert(out, {
				id = item.id,
				content = type(item.content) == "string" and item.content or "",
				updated_at = type(item.updated_at) == "string" and item.updated_at or "",
			})
		end
	end
	return out
end

local function read_local_templates()
	local path = template_file_path()
	if vim.fn.filereadable(path) ~= 1 then
		return { templates = {} }
	end
	local lines = vim.fn.readfile(path)
	if not lines or #lines == 0 then
		return { templates = {} }
	end
	local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
	if not ok or type(decoded) ~= "table" then
		return { templates = {} }
	end
	return {
		templates = normalize_local_templates(decoded.templates),
	}
end

local function write_local_templates(templates)
	local ok_mkdir = pcall(vim.fn.mkdir, template_dir(), "p")
	if not ok_mkdir then
		return false
	end
	local payload = { templates = normalize_local_templates(templates) }
	local ok_write = pcall(vim.fn.writefile, { vim.json.encode(payload) }, template_file_path())
	return ok_write
end

local function generate_template_id()
	local uv = vim.uv or vim.loop
	local suffix = uv and uv.hrtime and uv.hrtime() or os.time()
	return "tpl_" .. vim.fn.strftime("%Y%m%d%H%M%S") .. "_" .. tostring(suffix)
end

local function format_template_item(item)
	local title = item.title or "(untitled)"
	local stamp = is_non_empty(item.updated_at) and (" [" .. item.updated_at .. "]") or ""
	return title .. stamp
end

local function build_template_buffer_name(source, key, content)
	local source_value = source == "local" and "local" or "online"
	local id_part = tostring(key or "new"):gsub("[^%w_%-]", "_")
	local title = extract_title(content):gsub("[^%w_%-]", "_")
	return string.format("memos/template_%s_%s_%s.md", source_value, id_part:sub(1, 40), title:sub(1, 40))
end

local function open_template_buffer(content, meta)
	vim.cmd("enew")
	vim.b.memos_memo_name = nil
	vim.b.memos_template_mode = true
	vim.b.memos_template_source = meta.source
	vim.b.memos_template_id = meta.id
	vim.b.memos_template_memo_name = meta.memo_name
	local buf_name = build_template_buffer_name(meta.source, meta.id or meta.memo_name, content)
	vim.api.nvim_buf_set_name(0, buf_name)
	vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(content or "", "\n"))
	require("memos.ui").setup_buffer_for_editing()
end

local function list_local_templates(callback)
	local templates = read_local_templates().templates
	local items = {}
	for _, item in ipairs(templates) do
		table.insert(items, {
			id = item.id,
			source = "local",
			content = item.content,
			title = extract_title(item.content),
			updated_at = item.updated_at,
		})
	end
	table.sort(items, function(a, b)
		return tostring(a.updated_at or "") > tostring(b.updated_at or "")
	end)
	callback(items, nil)
end

local function list_online_templates(callback)
	api.get_current_user(function(user)
		if not user or not user.name then
			callback(nil, "Failed to get current user.")
			return
		end
		local cfg = get_config()
		api.fetch_all_template_memos(user.name, TEMPLATE_TAG_RAW, cfg.page_size, function(memos, err)
			if not memos then
				callback(nil, err or "Failed to fetch online templates.")
				return
			end
			local items = {}
			for _, memo in ipairs(memos) do
				local memo_name = memo and memo.name or nil
				if memo_name then
					local raw_content = type(memo.content) == "string" and memo.content or ""
					table.insert(items, {
						id = memo_name,
						memo_name = memo_name,
						source = "online",
						content = strip_template_tag(raw_content),
						title = extract_title(strip_template_tag(raw_content)),
						updated_at = memo.updateTime or memo.displayTime or memo.createTime or "",
					})
				end
			end
			callback(items, nil)
		end)
	end)
end

local function select_template(source, prompt, callback)
	local loader = source == "local" and list_local_templates or list_online_templates
	loader(function(items, err)
		if not items then
			vim.notify(err or "Failed to load templates.", vim.log.levels.ERROR)
			callback(nil)
			return
		end
		if #items == 0 then
			vim.notify("No templates found.", vim.log.levels.INFO)
			callback(nil)
			return
		end
		vim.schedule(function()
			vim.ui.select(items, {
				prompt = prompt,
				format_item = function(item)
					return format_template_item(item)
				end,
			}, function(choice)
				callback(choice)
			end)
		end)
	end)
end

local function upsert_local_template(template_id, content, callback)
	local data = read_local_templates()
	local templates = data.templates
	local id = template_id
	local updated = false
	if is_non_empty(id) then
		for _, item in ipairs(templates) do
			if item.id == id then
				item.content = content
				item.updated_at = now_iso()
				updated = true
				break
			end
		end
	end
	if not updated then
		id = generate_template_id()
		table.insert(templates, {
			id = id,
			content = content,
			updated_at = now_iso(),
		})
	end
	if not write_local_templates(templates) then
		callback(nil, "Failed to save local templates file.")
		return
	end
	callback({
		id = id,
		content = content,
		updated_at = now_iso(),
	}, nil)
end

local function delete_local_template(template_id, callback)
	local data = read_local_templates()
	local templates = data.templates
	local out = {}
	local removed = false
	for _, item in ipairs(templates) do
		if item.id == template_id then
			removed = true
		else
			table.insert(out, item)
		end
	end
	if not removed then
		callback(false, "Template not found.")
		return
	end
	if not write_local_templates(out) then
		callback(false, "Failed to save local templates file.")
		return
	end
	callback(true, nil)
end

local function ensure_online_archived(memo_name, callback)
	api.update_memo_metadata(memo_name, { state = "ARCHIVED" }, "state", function(success)
		if success then
			callback(true, nil)
		else
			callback(false, "Failed to archive template memo.")
		end
	end)
end

local function save_online_template(memo_name, content, callback)
	local tagged_content = ensure_template_tag(content)
	local function finalize(name)
		ensure_online_archived(name, function(ok, err)
			if not ok then
				callback(nil, err)
				return
			end
			callback({
				id = name,
				memo_name = name,
				content = content,
				updated_at = now_iso(),
			}, nil)
		end)
	end

	if is_non_empty(memo_name) then
		api.update_memo(memo_name, tagged_content, function(success)
			if not success then
				callback(nil, "Failed to update online template.")
				return
			end
			finalize(memo_name)
		end)
		return
	end

	api.create_memo(tagged_content, function(new_memo)
		if not new_memo or not new_memo.name then
			callback(nil, "Failed to create online template.")
			return
		end
		finalize(new_memo.name)
	end)
end

local function delete_online_template(memo_name, callback)
	if not is_non_empty(memo_name) then
		callback(false, "Invalid template memo id.")
		return
	end
	api.delete_memo(memo_name, function(success)
		if success then
			callback(true, nil)
		else
			callback(false, "Failed to delete online template.")
		end
	end)
end

function M.resolve_source(callback)
	local source = normalize_source(get_config().template_source)
	if source ~= "both" then
		callback(source)
		return
	end
	local items = {
		{ value = "online", label = "online" },
		{ value = "local", label = "local" },
	}
	vim.ui.select(items, {
		prompt = "Select template source:",
		format_item = function(item)
			return item.label
		end,
	}, function(choice)
		callback(choice and choice.value or nil)
	end)
end

function M.template_create(source)
	open_template_buffer("", {
		source = source,
		id = nil,
		memo_name = nil,
	})
end

function M.template_edit(source)
	select_template(source, "Select template to edit:", function(choice)
		if not choice then
			return
		end
		open_template_buffer(choice.content or "", {
			source = source,
			id = choice.id,
			memo_name = choice.memo_name,
		})
	end)
end

function M.template_delete(source)
	select_template(source, "Select template to delete:", function(choice)
		if not choice then
			return
		end
		local confirm = vim.fn.confirm("Delete template?\n[" .. (choice.title or "") .. "]", "&Yes\n&No", 2)
		if confirm ~= 1 then
			return
		end
		if source == "local" then
			delete_local_template(choice.id, function(ok, err)
				if ok then
					vim.notify("✅ Local template deleted.")
				else
					vim.notify("❌ " .. tostring(err), vim.log.levels.ERROR)
				end
			end)
		else
			delete_online_template(choice.memo_name or choice.id, function(ok, err)
				if ok then
					vim.notify("✅ Online template deleted.")
				else
					vim.notify("❌ " .. tostring(err), vim.log.levels.ERROR)
				end
			end)
		end
	end)
end

function M.create_memo_from_template(source)
	select_template(source, "Select template:", function(choice)
		if not choice then
			return
		end
		local content = strip_template_tag(choice.content or "")
		require("memos.ui").create_memo_from_content(content)
	end)
end

function M.save_template_buffer(bufnr, content, callback)
	local source = normalize_source(vim.b[bufnr].memos_template_source)
	if source ~= "local" and source ~= "online" then
		callback(false, nil, "Invalid template source.")
		return
	end
	if source == "local" then
		upsert_local_template(vim.b[bufnr].memos_template_id, content, function(saved, err)
			if not saved then
				callback(false, nil, err)
				return
			end
			callback(true, {
				source = "local",
				id = saved.id,
				content = content,
				buffer_name = build_template_buffer_name("local", saved.id, content),
			}, nil)
		end)
		return
	end

	save_online_template(vim.b[bufnr].memos_template_memo_name, content, function(saved, err)
		if not saved then
			callback(false, nil, err)
			return
		end
		callback(true, {
			source = "online",
			id = saved.id,
			memo_name = saved.memo_name,
			content = content,
			buffer_name = build_template_buffer_name("online", saved.memo_name, content),
		}, nil)
	end)
end

return M
