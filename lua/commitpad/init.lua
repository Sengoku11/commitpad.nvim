local M = {}

--- Setup the CommitPad plugin.
---@param opts? CommitPadOptions
function M.setup(opts)
	opts = opts or {}
	local cmd = opts.command or "CommitPad"
	local amend_cmd = opts.amend_command or "CommitPadAmend"

	require("commitpad.config").setup(opts)

	---@type CommitPadUI
	local mod = require("commitpad.ui")

	-- New commit pad command
	vim.api.nvim_create_user_command(cmd, function()
		mod.open()
	end, {})

	-- Amend commit pad command
	vim.api.nvim_create_user_command(amend_cmd, function()
		mod.amend()
	end, {})
end

return M
