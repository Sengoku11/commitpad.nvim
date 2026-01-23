---@class CommitPadUtils
local M = {}

--- Trim leading and trailing whitespace from a string.
---@param s string
---@return string
function M.trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Send a notification with the plugin title.
---@param msg string
---@param level? integer vim.log.levels constant (default: INFO)
function M.notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "commitpad" })
end

return M
