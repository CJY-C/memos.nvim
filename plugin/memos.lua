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

vim.api.nvim_create_user_command("MemosTemplate", function()
	require("memos").show_templates()
end, {
	nargs = 0,
	desc = "Open the Memos template list",
})
