local M = {}

-- opts:
--   command = "CommitPad" (default)
function M.setup(opts)
	opts = opts or {}
	local cmd = opts.command or "CommitPad"

	vim.api.nvim_create_user_command(cmd, function()
		require("commitpad.ui").open()
	end, {})
end

return M
