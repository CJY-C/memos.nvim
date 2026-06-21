local api = require("memos.api")

local M = {}

local TEMPLATE_TAG = "#type/template"

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

function M.strip_template_tag(content)
	local text = tostring(content or "")
	text = text:gsub("^%s*#type/template%s*\n?", "")
	text = text:gsub("\n%s*#type/template%s*\n?", "\n")
	text = text:gsub("%s+#type/template", " ")
	text = text:gsub("#type/template", "")
	return vim.trim(text)
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
	local clean = M.strip_template_tag(content)
	local first_line = ""
	for line in clean:gmatch("[^\n]+") do
		if vim.trim(line) ~= "" then
			first_line = vim.trim(line)
			break
		end
	end
	if first_line == "" then
		return "untitled"
	end
	return first_line:gsub("[/\\]", "_"):sub(1, 40)
end

local function build_template_buffer_name(memo_name, content)
	local id_part = tostring(memo_name or "new"):gsub("[^%w_%-]", "_")
	local title = extract_title(content):gsub("[^%w_%-]", "_")
	return string.format("memos/template_%s_%s.md", id_part:sub(1, 40), title)
end

function M.normalize_templates(raw)
	local out = {}
	if type(raw) ~= "table" then
		return out
	end
	for _, item in ipairs(raw) do
		if type(item) == "table" and type(item.name) == "string" and item.name ~= "" then
			table.insert(out, {
				name = item.name,
				content = type(item.content) == "string" and item.content or "",
				updated_at = type(item.updated_at) == "string" and item.updated_at or "",
			})
		end
	end
	return out
end

function M.read_local_templates()
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
		templates = M.normalize_templates(decoded.templates),
	}
end

function M.write_local_templates(data)
	local ok_mkdir = pcall(vim.fn.mkdir, template_dir(), "p")
	if not ok_mkdir then
		return false
	end
	local payload = { templates = M.normalize_templates(data.templates) }
	local ok_write = pcall(vim.fn.writefile, { vim.json.encode(payload) }, template_file_path())
	return ok_write
end

function M.sync_templates(callback)
	local ok, err = pcall(function()
		api.list_memos({
			state = "ARCHIVED",
			filter = "content.contains('#type/template')",
			page_size = 100,
		}, function(data, err, response)
			vim.schedule(function()
				if not data then
					if callback then
						callback(false, err)
					else
						vim.notify("Failed to sync templates: " .. tostring(err), vim.log.levels.ERROR)
					end
					return
				end
				local templates = {}
				for _, memo in ipairs(data.memos or {}) do
					if memo.name and memo.name ~= "" then
						table.insert(templates, {
							name = memo.name,
							content = memo.content or "",
							updated_at = memo.update_time or memo.create_time or "",
						})
					end
				end
				local data_to_write = { templates = templates }
				if M.write_local_templates(data_to_write) then
					if callback then
						callback(true, templates)
					else
						vim.notify("Memos templates synced successfully. Total: " .. #templates)
					end
				else
					if callback then
						callback(false, "Failed to write local templates file")
					else
						vim.notify("Failed to save synced templates locally.", vim.log.levels.ERROR)
					end
				end
			end)
		end)
	end)
	if not ok then
		if callback then
			callback(false, tostring(err))
		else
			vim.notify("Error starting template sync: " .. tostring(err), vim.log.levels.ERROR)
		end
	end
end

function M.filter_templates(templates, filter)
	if not filter or filter == "" then
		return templates
	end
	local query = string.lower(filter)
	local out = {}
	for _, tpl in ipairs(templates) do
		local content = string.lower(tpl.content or "")
		if content:find(query, 1, true) then
			table.insert(out, tpl)
		end
	end
	return out
end

function M.template_create()
	vim.schedule(function()
		vim.cmd("enew")
		local bufnr = vim.api.nvim_get_current_buf()
		vim.b[bufnr].memos_template_mode = true
		vim.b[bufnr].memos_template_name = nil
		pcall(vim.api.nvim_buf_set_name, bufnr, "memos/template_new.md")
		require("memos.ui").setup_buffer_for_editing()
	end)
end

function M.template_edit_selected(memo)
	if not memo or not memo.name then
		return
	end
	vim.schedule(function()
		vim.cmd("enew")
		local bufnr = vim.api.nvim_get_current_buf()
		vim.b[bufnr].memos_template_mode = true
		vim.b[bufnr].memos_template_name = memo.name
		local buf_name = build_template_buffer_name(memo.name, memo.content)
		pcall(vim.api.nvim_buf_set_name, bufnr, buf_name)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(memo.content or "", "\n"))
		require("memos.ui").setup_buffer_for_editing()
	end)
end

function M.template_delete_selected(memo, index)
	if not memo or not memo.name then
		return
	end
	vim.ui.select({ "Cancel", "Delete" }, {
		prompt = "Delete template: " .. extract_title(memo.content) .. "?",
	}, function(confirmation)
		if confirmation ~= "Delete" then
			return
		end
		api.delete_memo(memo.name, function(success, err)
			vim.schedule(function()
				if success then
					local data = M.read_local_templates()
					local templates = M.normalize_templates(data.templates)
					local remaining = {}
					for _, tpl in ipairs(templates) do
						if tpl.name ~= memo.name then
							table.insert(remaining, tpl)
						end
					end
					M.write_local_templates({ templates = remaining })
					
					-- Remove from UI list cache as well
					local ui = require("memos.ui")
					ui.remove_cached_memo_at(index)
					vim.notify("Template deleted.")
				else
					vim.notify("Failed to delete template from server: " .. tostring(err), vim.log.levels.ERROR)
				end
			end)
		end)
	end)
end

function M.save_template_buffer(bufnr, content, callback)
	local memo_name = vim.b[bufnr].memos_template_name
	local tagged_content = ensure_template_tag(content)

	if memo_name and memo_name ~= "" then
		-- Update existing template
		api.update_memo(memo_name, tagged_content, function(success, err, response)
			vim.schedule(function()
				if not success then
					callback(false, nil, err)
					return
				end
				-- Update local JSON file
				local data = M.read_local_templates()
				local templates = M.normalize_templates(data.templates)
				local found = false
				local now = now_iso()
				for _, tpl in ipairs(templates) do
					if tpl.name == memo_name then
						tpl.content = tagged_content
						tpl.updated_at = now
						found = true
						break
					end
				end
				if not found then
					table.insert(templates, {
						name = memo_name,
						content = tagged_content,
						updated_at = now,
					})
				end
				M.write_local_templates({ templates = templates })
				callback(true, {
					name = memo_name,
					buffer_name = build_template_buffer_name(memo_name, content),
				}, nil)
			end)
		end)
	else
		-- Create new template
		api.create_memo(tagged_content, function(new_memo, err, response)
			vim.schedule(function()
				if not new_memo or not new_memo.name then
					callback(false, nil, err or "Failed to create template memo on server")
					return
				end

				-- Now archive it!
				api.update_memo_state(new_memo.name, "ARCHIVED", function(state_success, state_err)
					vim.schedule(function()
						if not state_success then
							-- Delete the leaked normal memo to stay clean
							api.delete_memo(new_memo.name, function() end)
							callback(false, nil, state_err or "Failed to archive template memo on server")
							return
						end

						-- Save local
						local data = M.read_local_templates()
						local templates = M.normalize_templates(data.templates)
						table.insert(templates, {
							name = new_memo.name,
							content = tagged_content,
							updated_at = new_memo.update_time or new_memo.create_time or now_iso(),
						})
						M.write_local_templates({ templates = templates })
						callback(true, {
							name = new_memo.name,
							buffer_name = build_template_buffer_name(new_memo.name, content),
						}, nil)
					end)
				end)
			end)
		end)
	end
end

return M
