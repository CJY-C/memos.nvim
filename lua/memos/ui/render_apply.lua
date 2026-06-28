local render_utils = require("memos.ui.render")

local M = {}

local ns_id = vim.api.nvim_create_namespace("memos_list_highlights")

function M.set_list_lines(session, lines)
	local buf = session.buf
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false
	end
end

local function apply_highlights(buf, line_hls)
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
		for line_num, hls in pairs(line_hls) do
			for _, hl in ipairs(hls) do
				vim.api.nvim_buf_add_highlight(buf, ns_id, hl.hl_group, line_num - 1, hl.start_col, hl.end_col)
			end
		end
	end
end

function M.render_cached_memos(session, config)
	vim.schedule(function()
		local rendered = render_utils.build(session, config)
		session.list_items = rendered.list_items
		M.set_list_lines(session, rendered.lines)
		apply_highlights(session.buf, rendered.line_hls)

		if #rendered.missing_relation_names > 0 then
			session:fetch_missing_relations(rendered.missing_relation_names)
		end
	end)
end

return M
