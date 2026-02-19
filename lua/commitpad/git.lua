local Utils = require("commitpad.utils")

---@class CommitPadGit
local M = {}

---@class GitStatusFile
---@field status string The status code (e.g. "M", "A", "?")
---@field path string The file path
---@field partial boolean Whether the file is partially staged

---@class GitLineTotals
---@field added integer
---@field deleted integer

---@class GitStatusTotals
---@field staged GitLineTotals
---@field unstaged GitLineTotals

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

--- Build `git commit` arguments from structured message parts.
---@param title string
---@param desc string[]
---@param footer string[]
---@param amend boolean
---@return string[]
function M.build_commit_args(title, desc, footer, amend)
	local args = { "git", "commit" }
	if amend then
		table.insert(args, "--amend")
	end

	table.insert(args, "-m")
	table.insert(args, title)

	if #desc > 0 then
		table.insert(args, "-m")
		table.insert(args, table.concat(desc, "\n"))
	end

	if #footer > 0 then
		table.insert(args, "-m")
		table.insert(args, table.concat(footer, "\n"))
	end

	return args
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

--- Parse git status output.
---@param out string
---@return GitStatusFile[] staged
---@return GitStatusFile[] unstaged
local function parse_status_output(out)
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

---@return GitStatusTotals
local function empty_status_totals()
	return {
		staged = { added = 0, deleted = 0 },
		unstaged = { added = 0, deleted = 0 },
	}
end

--- Parse `git diff --numstat` output into total added/deleted counters.
---@param out string
---@return GitLineTotals
local function parse_numstat_totals(out)
	local totals = { added = 0, deleted = 0 }
	for _, line in ipairs(vim.split(out, "\n")) do
		local added_raw, deleted_raw = line:match("^(%S+)%s+(%S+)%s+")
		if added_raw and deleted_raw then
			-- Binary diffs emit "-" for both columns; skip those from line totals.
			local added = tonumber(added_raw)
			local deleted = tonumber(deleted_raw)
			if added then
				totals.added = totals.added + added
			end
			if deleted then
				totals.deleted = totals.deleted + deleted
			end
		end
	end
	return totals
end

--- Collect line-change totals for staged and unstaged tracked changes.
---@param root string
---@param callback fun(totals: GitStatusTotals)
local function get_status_totals_async(root, callback)
	local opts = { text = true, cwd = root }
	vim.system({ "git", "diff", "--cached", "--numstat" }, opts, function(staged_obj)
		local totals = empty_status_totals()
		if staged_obj.code == 0 then
			totals.staged = parse_numstat_totals(staged_obj.stdout or "")
		end

		vim.system({ "git", "diff", "--numstat" }, opts, function(unstaged_obj)
			if unstaged_obj.code == 0 then
				totals.unstaged = parse_numstat_totals(unstaged_obj.stdout or "")
			end
			callback(totals)
		end)
	end)
end

--- Get status lists for staged and unstaged files (Async).
---@param root string
---@param callback fun(staged: GitStatusFile[], unstaged: GitStatusFile[], totals: GitStatusTotals)
function M.get_status_files_async(root, callback)
	-- PERF: Async execution prevents blocking the main thread during heavy git status scans.
	vim.system({ "git", "status", "--porcelain", "-u" }, { text = true, cwd = root }, function(obj)
		if obj.code ~= 0 then
			callback({}, {}, empty_status_totals())
			return
		end
		local staged, unstaged = parse_status_output(obj.stdout or "")
		get_status_totals_async(root, function(totals)
			callback(staged, unstaged, totals)
		end)
	end)
end

--- Stage a file asynchronously.
---@param root string
---@param path string
---@param callback fun(result: table)
function M.stage_file_async(root, path, callback)
	vim.system({ "git", "add", "--", path }, { text = true, cwd = root }, callback)
end

--- Unstage a file asynchronously.
--- Uses `git restore --staged` and falls back to `git reset HEAD --` for older Git.
---@param root string
---@param path string
---@param callback fun(result: table)
function M.unstage_file_async(root, path, callback)
	vim.system({ "git", "restore", "--staged", "--", path }, { text = true, cwd = root }, function(obj)
		if obj.code == 0 then
			callback(obj)
			return
		end

		vim.system({ "git", "reset", "HEAD", "--", path }, { text = true, cwd = root }, callback)
	end)
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

--- Commit current index with provided message parts.
---@param root string
---@param title string
---@param desc string[]
---@param footer string[]
---@param amend boolean
---@return string|nil short_hash
---@return table|nil result
function M.commit_message(root, title, desc, footer, amend)
	local args = M.build_commit_args(title, desc, footer, amend)
	local _, res = M.out(args, root)
	if not res or res.code ~= 0 then
		return nil, res
	end

	-- Best-effort hash detection even if commit output format differs.
	local short_hash = M.extract_commit_hash(res.stdout, res.stderr)
	if not short_hash then
		local h2 = M.out({ "git", "rev-parse", "--short", "HEAD" }, root)
		if h2 and h2 ~= "" then
			short_hash = h2
		end
	end

	return short_hash, res
end

--- Resolve current branch in a way that avoids detached HEAD.
---@param root string
---@return string|nil
function M.current_branch(root)
	local branch = M.out({ "git", "branch", "--show-current" }, root)
	if not branch or branch == "" or branch == "HEAD" then
		branch = M.out({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, root)
	end

	if not branch or branch == "" or branch == "HEAD" then
		return nil
	end

	return branch
end

--- Resolve commit hash + branch used for explicit HEAD push refspec.
---@param root string
---@return string|nil full_hash
---@return string|nil branch
function M.resolve_push_target(root)
	local full_hash = M.out({ "git", "rev-parse", "HEAD" }, root)
	local branch = M.current_branch(root)
	if not full_hash or full_hash == "" or not branch then
		return nil, nil
	end
	return full_hash, branch
end

---@class CommitPadPushOpts
---@field branch string
---@field full_hash string
---@field force_with_lease boolean

--- Push explicit commit hash to origin/<branch> asynchronously.
---@param root string
---@param opts CommitPadPushOpts
---@param callback fun(result: table)
function M.push_head_async(root, opts, callback)
	local push_args = { "git", "push" }
	if opts.force_with_lease then
		table.insert(push_args, "--force-with-lease")
	end
	table.insert(push_args, "origin")
	table.insert(push_args, string.format("%s:refs/heads/%s", opts.full_hash, opts.branch))
	vim.system(push_args, { text = true, cwd = root }, callback)
end

return M
