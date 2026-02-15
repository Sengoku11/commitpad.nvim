---@type CommitPadGit
local Git = require("commitpad.git")

---@class CommitPadFS
local M = {}

-- PERF: Memoize path resolution to eliminate process spawning overhead (~10-30ms) on repeated toggles.
local cache = {}

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
	local cwd = vim.uv.cwd()
	local key = cwd .. "|" .. tostring(is_amend)

	if cache[key] then
		local res = cache[key]
		return res[1], res[2], res[3], res[4]
	end

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
	local result = {
		dir .. "/" .. prefix .. ".md",
		dir .. "/" .. prefix .. ".title",
		dir .. "/" .. prefix .. ".footer",
		root,
	}

	cache[key] = result
	return result[1], result[2], result[3], result[4]
end

--- Clear amend title/body drafts while preserving amend footer.
function M.clear_amend_drafts()
	local amend_body, amend_title = M.draft_paths_for_worktree(true)

	local function wipe(path)
		if not path then
			return
		end

		local b = vim.fn.bufnr(path)
		if b ~= -1 and vim.api.nvim_buf_is_valid(b) then
			vim.api.nvim_buf_set_lines(b, 0, -1, false, {})
			vim.api.nvim_buf_call(b, function()
				vim.cmd("silent! write")
			end)
		else
			vim.fn.writefile({}, path)
		end
	end

	wipe(amend_body)
	wipe(amend_title)
end

return M
