local memos = require("memos")
local ui = require("memos.ui")

describe("memos.ui dynamic keymaps", function()
	local buf

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

		local maps = vim.api.nvim_buf_get_keymap(buf, "n")
		local quit_mapped = false
		for _, map in ipairs(maps) do
			if map.lhs == "q" then
				quit_mapped = true
			end
		end
		assert.is_true(quit_mapped)
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

		local maps = vim.api.nvim_buf_get_keymap(buf, "n")
		local old_quit_mapped = false
		local new_quit_mapped = false
		for _, map in ipairs(maps) do
			if map.lhs == "q" then
				old_quit_mapped = true
			elseif map.lhs == "x" then
				new_quit_mapped = true
			end
		end

		assert.is_false(old_quit_mapped, "Old keymap 'q' was not cleared")
		assert.is_true(new_quit_mapped, "New keymap 'x' was not registered")
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

		local maps = vim.api.nvim_buf_get_keymap(buf, "n")
		local quit_mapped = false
		local refresh_mapped = false
		for _, map in ipairs(maps) do
			if map.lhs == "q" then
				quit_mapped = true
			elseif map.lhs == "r" then
				refresh_mapped = true
			end
		end

		assert.is_false(quit_mapped, "Keymap set to false should not be bound")
		assert.is_true(refresh_mapped, "Other valid keymaps should still be bound")
	end)
end)
