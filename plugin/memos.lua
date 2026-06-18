vim.api.nvim_create_user_command("Memos", function()
	require("memos").show_list()
end, {
	nargs = 0,
	desc = "Open the Memos list",
})

vim.api.nvim_create_user_command("MemosCreate", function()
	require("memos").create_memo()
end, {
	nargs = 0,
	desc = "Create a new memo",
})

vim.api.nvim_create_user_command("MemosSwitch", function()
	require("memos").switch_user_interactive()
end, {
	nargs = 0,
	desc = "Switch active Memos account",
})

vim.api.nvim_create_user_command("MemosUserAdd", function()
	require("memos").add_user_interactive()
end, {
	nargs = 0,
	desc = "Add a Memos account",
})

vim.api.nvim_create_user_command("MemosUserDelete", function()
	require("memos").delete_user_interactive()
end, {
	nargs = 0,
	desc = "Delete a saved Memos account",
})

vim.schedule(function()
	local ok, memos = pcall(require, "memos")
	if not ok then
		return
	end
	local key = memos.config.keymaps.start_memos
	if key and key ~= "" then
		vim.keymap.set("n", key, "<Cmd>Memos<CR>", {
			noremap = true,
			silent = true,
			desc = "Open Memos list",
		})
	end
end)
