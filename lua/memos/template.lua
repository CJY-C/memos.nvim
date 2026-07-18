local api = require("memos.api").new(function() return require("memos").config end)

local M = {}

local function template_tag()
	return "#" .. (require("memos").config.template_tag or "type/template")
end

local function is_tag_byte(byte)
	return byte and (byte >= 128 or (byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 90)
		or (byte >= 97 and byte <= 122) or byte == 45 or byte == 47 or byte == 95)
end

function M.strip_template_tag(content)
	local text = tostring(content or "")
	local marker = template_tag()
	local from = 1
	while true do
		local start_pos, end_pos = text:find(marker, from, true)
		if not start_pos then
			break
		end
		if not is_tag_byte(text:byte(end_pos + 1)) then
			text = text:sub(1, start_pos - 1) .. text:sub(end_pos + 1)
			from = start_pos
		else
			from = end_pos + 1
		end
	end
	text = text:gsub("[ \t]+\n", "\n")
	text = text:gsub("\n[ \t]+", "\n")
	text = text:gsub("[ \t][ \t]+", " ")
	return vim.trim(text)
end

local function ensure_template_tag(content)
	local text = tostring(content or "")
	local marker = template_tag()
	if M.strip_template_tag(text) ~= vim.trim(text) then
		return text
	end
	if text == "" then
		return marker
	end
	if text:sub(-1) == "\n" then
		return text .. marker
	end
	return text .. "\n" .. marker
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
	local title = first_line:gsub("[/\\]", "_")
	return vim.fn.strcharpart(title, 0, 40)
end

local function build_template_buffer_name(memo_name, content)
	local id_part = tostring(memo_name or "new"):gsub("[^%w_%-]", "_")
	local title = extract_title(content):gsub("[^%w_%-]", "_")
	return string.format("memos/template_%s_%s.md", id_part:sub(1, 40), title)
end

function M.template_create()
	vim.schedule(function()
		local ui = require("memos.ui")
		local bufnr = ui.open_edit_buffer("", require("memos").config.window.default_open or "vsplit")
		vim.b[bufnr].memos_template_mode = true
		vim.b[bufnr].memos_template_name = nil
		pcall(vim.api.nvim_buf_set_name, bufnr, "memos/template_new.md")
		ui.setup_buffer_for_editing()
	end)
end

function M.template_edit_selected(memo, open_cmd)
	if not memo or not memo.name then
		return
	end
	vim.schedule(function()
		local ui = require("memos.ui")
		local bufnr = ui.open_edit_buffer(memo.content or "", open_cmd or require("memos").config.window.default_open or "vsplit")
		vim.b[bufnr].memos_template_mode = true
		vim.b[bufnr].memos_template_name = memo.name
		local buf_name = build_template_buffer_name(memo.name, memo.content)
		pcall(vim.api.nvim_buf_set_name, bufnr, buf_name)
		ui.setup_buffer_for_editing()
	end)
end

function M.template_delete_selected(memo, index)
	if not memo or not memo.name then
		return
	end
	vim.ui.select({ "Cancel", "Delete" }, {
		prompt = "Delete template: " .. extract_title(memo.content) .. "?",
		kind = "memos_delete",
	}, function(confirmation)
		if confirmation ~= "Delete" then
			return
		end
		api:delete_memo(memo.name, function(success, err)
			vim.schedule(function()
				if success then
					local ui = require("memos.ui")
					ui.remove_cached_memo_at(index)
					vim.notify("Template deleted.")
					ui.refresh_list_silently()
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
		api:update_memo(memo_name, tagged_content, function(success, err, response)
			vim.schedule(function()
				if not success then
					callback(false, nil, err)
					return
				end
				callback(true, {
					name = memo_name,
					buffer_name = build_template_buffer_name(memo_name, content),
				}, nil)
			end)
		end)
	else
		-- Create new template
		api:create_memo(tagged_content, function(new_memo, err, response)
			if not new_memo or not new_memo.name then
				vim.schedule(function()
					callback(false, nil, err or "Failed to create template memo on server")
				end)
				return
			end

			api:update_memo_state(new_memo.name, "ARCHIVED", function(success, archive_err)
				vim.schedule(function()
					if not success then
						callback(false, nil, archive_err or "Failed to archive template memo on server")
						return
					end

					callback(true, {
						name = new_memo.name,
						buffer_name = build_template_buffer_name(new_memo.name, content),
					}, nil)
				end)
			end)
		end)
	end
end

return M
