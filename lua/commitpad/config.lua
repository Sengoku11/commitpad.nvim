---@class CommitPadConfig
---@field options CommitPadOptions
---@field setup fun(opts?: CommitPadOptions)
local M = {}

---@class CommitPadOptions
---@field footer? boolean Show the footer buffer (default: false)
---@field stage_files? boolean Show staged files sidebar (default: false)
---@field command? string Command name (default: "CommitPad")
---@field amend_command? string Amend command name (default: "CommitPadAmend")

---@type CommitPadOptions
M.options = {
	footer = false,
	stage_files = false,
}

--- Setup the configuration options.
---@param opts? CommitPadOptions
function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", M.options, opts or {})
end

return M
