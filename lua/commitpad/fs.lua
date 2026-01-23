---@type CommitPadGit
local Git = require("commitpad.git")

---@class CommitPadFS
local M = {}

--- Create directory if it doesn't exist.
---@param path string
function M.ensure_dir(path)
	vim.fn.mkdir(path, "p")
end

--- Return distinct files for body, title, and footer for the current worktree.
---@param is_amend boolean
---@return string|nil body_path
---@return string|nil title_path
---@return string|nil footer_path
---@return string|nil root
function M.draft_paths_for_worktree(is_amend)
	local root = Git.worktree_root()
	if not root then
		return nil, nil, nil, nil
	end
	local gitdir = Git.worktree_gitdir(root)
	if not gitdir then
		return nil, nil, nil, nil
	end
	local dir = gitdir .. "/commitpad"
	M.ensure_dir(dir)

	local prefix = is_amend and "amend" or "draft"
	return dir .. "/" .. prefix .. ".md", dir .. "/" .. prefix .. ".title", dir .. "/" .. prefix .. ".footer", root
end

return M
