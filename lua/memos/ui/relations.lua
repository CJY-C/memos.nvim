local M = {}

function M.match_memo_id_or_name(memo, val)
	if not memo or not val or val == "" then
		return false
	end
	if memo.name == val then
		return true
	end
	if memo.id and tostring(memo.id) == val then
		return true
	end
	return false
end

function M.is_same_memo(memo1, memo2)
	if not memo1 or not memo2 then
		return false
	end
	if memo1.name == memo2.name and memo1.name ~= "" then
		return true
	end
	if memo1.id and memo2.id and tostring(memo1.id) == tostring(memo2.id) then
		return true
	end
	return false
end

function M.get_name_from_relation_field(field)
	if type(field) == "string" then
		return field
	elseif type(field) == "table" then
		return field.name or field.memo_name or ""
	end
	return ""
end

local function memo_aliases(memo)
	local aliases = {}
	local seen = {}
	local function add(value)
		if type(value) == "string" and value ~= "" and not seen[value] then
			seen[value] = true
			table.insert(aliases, value)
		end
	end
	add(memo and memo.name)
	if memo and memo.id ~= nil then
		add(tostring(memo.id))
	end
	return aliases
end

local function add_relation_name(bucket, key, value)
	if key == "" or value == "" then
		return
	end
	local entry = bucket[key]
	if not entry then
		entry = { names = {}, seen = {} }
		bucket[key] = entry
	end
	if not entry.seen[value] then
		entry.seen[value] = true
		table.insert(entry.names, value)
	end
end

function M.empty_index()
	return {
		memo_by_name = {},
		outgoing_by_name = {},
		incoming_by_name = {},
	}
end

function M.build_index(memos)
	local index = M.empty_index()

	for _, memo in ipairs(memos or {}) do
		for _, alias in ipairs(memo_aliases(memo)) do
			index.memo_by_name[alias] = memo
		end
	end

	for _, memo in ipairs(memos or {}) do
		if type(memo.relations) == "table" then
			for _, rel in ipairs(memo.relations) do
				local source = M.get_name_from_relation_field(rel.memo or rel.memoName)
				local target = M.get_name_from_relation_field(rel.relatedMemo or rel.related_memo or rel.relatedMemoName)
				if source ~= "" and target ~= "" then
					add_relation_name(index.outgoing_by_name, source, target)
					add_relation_name(index.incoming_by_name, target, source)
				end
			end
		end
	end

	return index
end

function M.get_indexed_relation_names(index, direction, memo)
	local bucket = direction == "incoming" and index.incoming_by_name or index.outgoing_by_name
	local names = {}
	local seen = {}
	for _, alias in ipairs(memo_aliases(memo)) do
		local entry = bucket[alias]
		if entry then
			for _, name in ipairs(entry.names) do
				if not seen[name] then
					seen[name] = true
					table.insert(names, name)
				end
			end
		end
	end
	return names
end

function M.get_cached_relation_memo(index, relation_details_cache, name)
	if index.memo_by_name[name] then
		return index.memo_by_name[name]
	end
	return relation_details_cache and relation_details_cache[name] or nil
end

return M
