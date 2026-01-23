local Utils = require("commitpad.utils")

---@class CommitPadGit
local M = {}

---@class GitStatusFile
---@field status string The status code (e.g. "M", "A", "?")
---@field path string The file path
---@field partial boolean Whether the file is partially staged

--- Execute a git command.
---@param args string[] Arguments for the git command
---@param cwd? string Working directory
---@param raw? boolean If true, returns raw output without trimming
---@return string|nil stdout The output or nil if failed
---@return table|nil result The full vim.system result
function M.out(args, cwd, raw)
	local r = vim.system(args, { text = true, cwd = cwd }):wait()
	if r.code ~= 0 then
		return nil, r
	end
	if raw then
		return r.stdout or "", r
	end
	return Utils.trim(r.stdout or ""), r
end

--- Get the root of the current git worktree.
---@return string|nil
function M.worktree_root()
	local cwd = vim.uv.cwd()
	local out = M.out({ "git", "rev-parse", "--show-toplevel" }, cwd)
	if not out or out == "" then
		return nil
	end
	return out
end

--- Get the absolute git directory (handles worktrees/submodules).
---@param root string
---@return string|nil
function M.worktree_gitdir(root)
	local out = M.out({ "git", "rev-parse", "--absolute-git-dir" }, root)
	if not out or out == "" then
		return nil
	end
	return out
end

--- Get status lists for staged and unstaged files.
---@param root string
---@return GitStatusFile[] staged
---@return GitStatusFile[] unstaged
function M.get_status_files(root)
	local out, _ = M.out({ "git", "status", "--porcelain", "-u" }, root, true)
	if not out or out == "" then
		return {}, {}
	end

	local staged = {}
	local unstaged = {}

	for _, line in ipairs(vim.split(out, "\n")) do
		if #line > 3 then
			local x = line:sub(1, 1)
			local y = line:sub(2, 2)
			local path = line:sub(4)

			-- Handle rename output "R: from -> to"
			local arrow = path:find(" -> ", 1, true)
			if arrow then
				path = path:sub(arrow + 4)
			end
			-- Remove quotes if git output added them
			path = path:gsub('^"', ""):gsub('"$', "")

			-- Check if file is partially staged (exists in both index and worktree)
			-- Exclude untracked (?) from this check
			local is_partial = (x ~= " " and x ~= "?") and (y ~= " ")

			if x ~= " " and x ~= "?" then
				table.insert(staged, { status = x, path = path, partial = is_partial })
			end
			-- y ~= " " covers modified worktree
			-- x == "?" and y == "?" covers untracked
			if y ~= " " or (x == "?" and y == "?") then
				local s = (x == "?" and y == "?") and "?" or y
				if s ~= " " then
					table.insert(unstaged, { status = s, path = path, partial = is_partial })
				end
			end
		end
	end
	return staged, unstaged
end

--- Extract commit hash from git output.
---@param stdout string|nil
---@param stderr string|nil
---@return string|nil hash
function M.extract_commit_hash(stdout, stderr)
	local s = (stdout or "") .. "\n" .. (stderr or "")
	-- Common output contains: "[branch abcdef1] message"
	local h = s:match("%[.-%s+([0-9a-fA-F]+)%]")
	if h and #h >= 7 then
		return h
	end
	-- Fallback: look for a 7...40 hex token
	h = s:match("(%f[%x][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]+%f[^%x])")
	if h and #h >= 7 then
		return h
	end
	return nil
end

return M
