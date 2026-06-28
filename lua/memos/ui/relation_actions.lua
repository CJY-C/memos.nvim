local relation_utils = require("memos.ui.relations")

local M = {}

local function get_clipboard_memo_id()
	for _, reg in ipairs({ "+", "*", '"' }) do
		local content = vim.trim(vim.fn.getreg(reg) or "")
		if content ~= "" then
			if content:match("^memos/[%w%-_]+$") then
				return content
			elseif content:match("^[%w%-_]+$") and not content:match("^%d+$") then
				return "memos/" .. content
			elseif content:match("^%d+$") then
				return "memos/" .. content
			end
		end
	end
	return ""
end

local function memo_choice_label(memo)
	local title = memo.content:match("^([^\n]*)") or ""
	title = vim.trim(title)
	if title == "" then
		title = memo.snippet or ""
	end
	if title == "" then
		title = "(No Content)"
	end
	return string.format("%s - %s", memo.name, vim.fn.strcharpart(title, 0, 60))
end

local function build_relation_choices(session, memo)
	local choices = {}
	local choice_map = {}

	local clipboard_id = get_clipboard_memo_id()
	if clipboard_id ~= "" then
		local clip_label = string.format("[Use Clipboard: %s]", clipboard_id)
		table.insert(choices, clip_label)
		choice_map[clip_label] = { type = "clipboard", value = clipboard_id }
	end

	for _, m in ipairs(session.memos_cache) do
		if not relation_utils.is_same_memo(m, memo) then
			local label = memo_choice_label(m)
			table.insert(choices, label)
			choice_map[label] = { type = "memo", value = m.name }
		end
	end

	local manual_label = "[Input memo ID manually]"
	table.insert(choices, manual_label)
	choice_map[manual_label] = { type = "manual" }

	return choices, choice_map
end

local function prompt_manual_target()
	local target_input = vim.fn.input("Add relation to target memo ID: ", "")
	print(" ")
	target_input = vim.trim(target_input or "")
	return target_input
end

local function resolve_selection_targets(choice_map, selections)
	local target_names = {}
	for _, sel in ipairs(selections) do
		local info = choice_map[sel.value or sel]
		if info then
			if info.type == "manual" then
				local target_input = prompt_manual_target()
				if target_input ~= "" then
					table.insert(target_names, target_input)
				end
			else
				table.insert(target_names, info.value)
			end
		end
	end
	return target_names
end

function M.add_multiple_relations(session, ctx, memo, target_names)
	if not target_names or #target_names == 0 then
		return
	end

	local relations = {}
	local existing_targets = {}
	if type(memo.relations) == "table" then
		for _, r in ipairs(memo.relations) do
			local m_name = relation_utils.get_name_from_relation_field(r.memo or r.memoName)
			local r_name = relation_utils.get_name_from_relation_field(r.relatedMemo or r.related_memo or r.relatedMemoName)
			if m_name ~= "" and r_name ~= "" then
				table.insert(relations, {
					memo = { name = m_name },
					relatedMemo = { name = r_name },
					type = r.type or "REFERENCE",
				})
				if m_name == memo.name then
					existing_targets[r_name] = true
				end
			end
		end
	end

	local new_relations_to_add = {}
	local added_count = 0
	local self_link_attempt = false
	local already_exists_count = 0

	for _, target_name in ipairs(target_names) do
		target_name = vim.trim(target_name)
		if target_name ~= "" then
			if not target_name:match("^memos/") then
				target_name = "memos/" .. target_name
			end

			if relation_utils.match_memo_id_or_name(memo, target_name) then
				self_link_attempt = true
			elseif existing_targets[target_name] then
				already_exists_count = already_exists_count + 1
			else
				local new_rel = {
					memo = { name = memo.name },
					relatedMemo = { name = target_name },
					type = "REFERENCE",
				}
				table.insert(relations, new_rel)
				table.insert(new_relations_to_add, new_rel)
				existing_targets[target_name] = true
				added_count = added_count + 1
			end
		end
	end

	if self_link_attempt and added_count == 0 then
		vim.notify("Cannot create a relation to the same memo.", vim.log.levels.ERROR)
		return
	end

	if added_count == 0 then
		if already_exists_count > 0 then
			vim.notify("Relation(s) already exist.", vim.log.levels.INFO)
		end
		return
	end

	ctx.api:set_memo_relations(memo.name, relations, function(success, err)
		vim.schedule(function()
			if success then
				if not memo.relations then
					memo.relations = {}
				end
				for _, new_rel in ipairs(new_relations_to_add) do
					table.insert(memo.relations, new_rel)
				end
				session:mark_relation_index_dirty()
				session:render_cached_memos()
				if added_count == 1 then
					vim.notify("Relation added successfully.")
				else
					vim.notify(string.format("%d relations added successfully.", added_count))
				end
				session:refresh_list_silently()
			else
				vim.notify("Failed to add relation: " .. tostring(err), vim.log.levels.ERROR)
			end
		end)
	end)
end

function M.add_relation(session, ctx)
	if session.current_list_state == "TEMPLATES" then
		vim.notify("Relations are not supported for templates.", vim.log.levels.WARN)
		return
	end
	local item = session:current_list_item()
	local memo = session:get_memo_from_item(item)
	if not memo or not memo.name or memo.name == "" then
		vim.notify("No memo on the current line.", vim.log.levels.INFO)
		return
	end

	local choices, choice_map = build_relation_choices(session, memo)

	local has_telescope = pcall(require, "telescope")
	if has_telescope then
		local pickers = require("telescope.pickers")
		local finders = require("telescope.finders")
		local conf = require("telescope.config").values
		local actions = require("telescope.actions")
		local action_state = require("telescope.actions.state")

		pickers.new({}, {
			prompt_title = "Select memo(s) to relate:",
			finder = finders.new_table {
				results = choices,
				entry_maker = function(entry)
					return {
						value = entry,
						display = entry,
						ordinal = entry,
					}
				end,
			},
			sorter = conf.generic_sorter({}),
			previewer = false,
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local picker = action_state.get_current_picker(prompt_bufnr)
					local selections = picker:get_multi_selection()
					if vim.tbl_isempty(selections) then
						local entry = action_state.get_selected_entry()
						if entry then
							selections = { entry }
						else
							selections = {}
						end
					end
					actions.close(prompt_bufnr)

					M.add_multiple_relations(session, ctx, memo, resolve_selection_targets(choice_map, selections))
				end)
				return true
			end,
		}):find()
		return
	end

	vim.ui.select(choices, {
		prompt = "Select memo to relate (or input ID):",
		kind = "memos_relation",
	}, function(choice)
		if not choice then
			return
		end
		local info = choice_map[choice]
		if not info then
			return
		end

		local target_name = ""
		if info.type == "manual" then
			target_name = prompt_manual_target()
			if target_name == "" then
				vim.notify("Relation addition cancelled.", vim.log.levels.INFO)
				return
			end
		else
			target_name = info.value
		end

		M.add_multiple_relations(session, ctx, memo, { target_name })
	end)
end

function M.delete_selected_relation(session, ctx, item)
	local parent_memo = session.memos_cache[item.parent_index]
	if not parent_memo then
		vim.notify("Parent memo not found.", vim.log.levels.ERROR)
		return
	end

	local target_name = ""
	if item.kind == "relation" then
		target_name = item.memo.name
	elseif item.kind == "relation_loading" then
		target_name = item.relation_name
	end

	if target_name == "" then
		vim.notify("Related memo name not found.", vim.log.levels.ERROR)
		return
	end

	local source_memo_name
	local target_memo_name
	if item.relation_type == "outgoing" then
		source_memo_name = parent_memo.name
		target_memo_name = target_name
	else
		source_memo_name = target_name
		target_memo_name = parent_memo.name
	end

	local source_memo
	if source_memo_name == parent_memo.name then
		source_memo = parent_memo
	else
		source_memo = session:get_cached_relation_memo(source_memo_name)
	end

	if not source_memo or not source_memo.relations then
		vim.notify("Relation source memo not loaded.", vim.log.levels.WARN)
		return
	end

	local prompt_msg = string.format("Unlink relation: %s -> %s?", source_memo_name, target_memo_name)
	vim.ui.select({ "Cancel", "Unlink" }, {
		prompt = prompt_msg,
		kind = "memos_unlink",
	}, function(choice)
		if choice ~= "Unlink" then
			return
		end

		local new_relations = {}
		for _, r in ipairs(source_memo.relations) do
			local m_name = relation_utils.get_name_from_relation_field(r.memo or r.memoName)
			local r_name = relation_utils.get_name_from_relation_field(r.relatedMemo or r.related_memo or r.relatedMemoName)
			if m_name ~= "" and r_name ~= "" then
				if not (m_name == source_memo_name and r_name == target_memo_name) then
					table.insert(new_relations, {
						memo = { name = m_name },
						relatedMemo = { name = r_name },
						type = r.type or "REFERENCE",
					})
				end
			end
		end

		ctx.api:set_memo_relations(source_memo_name, new_relations, function(success, err)
			vim.schedule(function()
				if success then
					source_memo.relations = {}
					for _, r in ipairs(new_relations) do
						table.insert(source_memo.relations, r)
					end
					session:mark_relation_index_dirty()
					session:render_cached_memos()
					vim.notify("Relation unlinked.")
					session:refresh_list_silently()
				else
					vim.notify("Failed to unlink relation: " .. tostring(err), vim.log.levels.ERROR)
				end
			end)
		end)
	end)
end

return M
