local memos = require("memos")
local ui = require("memos.ui")
local keymaps = require("memos.ui.keymaps")

describe("memos.ui dynamic keymaps", function()
	local buf

	local function has_map(lhs)
		for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
			if map.lhs == lhs then
				return true
			end
		end
		return false
	end

	before_each(function()
		buf = vim.api.nvim_create_buf(false, true)
		-- Setup initial config
		memos.setup({
			keymaps = {
				list = {
					quit = "q",
					refresh_list = "r",
				},
			},
		})
	end)

	after_each(function()
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
	end)

	it("should bind keymaps based on config", function()
		ui.bind_list_keymaps(buf)

		assert.is_true(has_map("q"))
	end)

	it("should clean old keymaps and bind new ones when config updates", function()
		ui.bind_list_keymaps(buf)

		-- Update keymap config dynamically
		memos.setup({
			keymaps = {
				list = {
					quit = "x", -- Change quit key from q to x
					refresh_list = "r",
				},
			},
		})

		-- Re-bind
		ui.bind_list_keymaps(buf)

		assert.is_false(has_map("q"), "Old keymap 'q' was not cleared")
		assert.is_true(has_map("x"), "New keymap 'x' was not registered")
	end)

	it("should skip binding keymaps that are set to false in config", function()
		memos.setup({
			keymaps = {
				list = {
					quit = false, -- Disable quit key
					refresh_list = "r",
				},
			},
		})

		ui.bind_list_keymaps(buf)

		assert.is_false(has_map("q"), "Keymap set to false should not be bound")
		assert.is_true(has_map("r"), "Other valid keymaps should still be bound")
	end)

	it("should bind fallback list keys when optional mappings are unset", function()
		keymaps.bind_list_keymaps(buf, {})

		assert.is_true(has_map("n"))
		assert.is_true(has_map("c"))
		assert.is_true(has_map("<Tab>"))
		assert.is_true(has_map("<S-Tab>"))
		assert.is_true(has_map("zo"))
		assert.is_true(has_map("zi"))
		assert.is_true(has_map("zM"))
	end)

	it("should skip empty string mappings and omit them from the bound registry", function()
		memos.setup({
			keymaps = {
				list = {
					quit = "",
					refresh_list = "r",
				},
			},
		})

		ui.bind_list_keymaps(buf)

		assert.is_false(has_map(""))
		for _, key in ipairs(vim.b[buf].memos_bound_keys or {}) do
			assert.are_not.same("", key)
		end
		assert.is_true(has_map("r"))
	end)
end)
