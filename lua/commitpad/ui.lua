local M = {}

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "commitpad" })
end

local function git_out(args, cwd)
	local r = vim.system(args, { text = true, cwd = cwd }):wait()
	if r.code ~= 0 then
		return nil, r
	end
	return trim(r.stdout or ""), r
end

local function worktree_root()
	local cwd = vim.loop.cwd()
	local out = git_out({ "git", "rev-parse", "--show-toplevel" }, cwd)
	if not out or out == "" then
		return nil
	end
	return out
end

local function worktree_gitdir(root)
	local out = git_out({ "git", "rev-parse", "--absolute-git-dir" }, root)
	if not out or out == "" then
		return nil
	end
	return out
end

local function ensure_dir(path)
	vim.fn.mkdir(path, "p")
end

local function read_file(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local s = f:read("*a")
	f:close()
	return s
end

local function write_file(path, s)
	local f = io.open(path, "w")
	if not f then
		return false
	end
	f:write(s)
	f:close()
	return true
end

local function delete_file(path)
	os.remove(path)
end

local function yaml_quote_single(s)
	s = s or ""
	return "'" .. s:gsub("'", "''") .. "'"
end

local function draft_path_for_worktree()
	local root = worktree_root()
	if not root then
		return nil, nil
	end
	local gitdir = worktree_gitdir(root)
	if not gitdir then
		return nil, nil
	end
	local dir = gitdir .. "/commitpad"
	ensure_dir(dir)
	return dir .. "/draft.md", root
end

local function buf_lines(buf)
	return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function set_lines(buf, lines)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

local function get_title_desc(title_buf, desc_buf)
	local title = trim((buf_lines(title_buf)[1] or ""))
	local desc = buf_lines(desc_buf)
	while #desc > 0 and trim(desc[#desc]) == "" do
		table.remove(desc, #desc)
	end
	return title, desc
end

local function serialize_draft(title, desc_lines)
	local t = {}
	table.insert(t, "---")
	table.insert(t, "title: " .. yaml_quote_single(title or ""))
	table.insert(t, "---")
	if desc_lines and #desc_lines > 0 then
		for _, line in ipairs(desc_lines) do
			table.insert(t, line)
		end
	end
	return table.concat(t, "\n") .. "\n"
end

local function parse_draft(md)
	if not md or md == "" then
		return "", { "" }
	end

	local lines = {}
	for line in md:gmatch("([^\n]*)\n?") do
		table.insert(lines, line)
	end
	if #lines > 0 and lines[#lines] == "" then
		table.remove(lines, #lines)
	end

	local title = ""
	local body_start = 1

	if lines[1] == "---" then
		local fm_end = nil
		for i = 2, #lines do
			if lines[i] == "---" then
				fm_end = i
				break
			end
			local k, v = lines[i]:match("^([%w_%-]+)%s*:%s*(.*)$")
			if k == "title" and v then
				v = trim(v)
				local sq = v:match("^'(.*)'$")
				if sq ~= nil then
					title = sq:gsub("''", "'")
				else
					title = v
				end
			end
		end
		if fm_end then
			body_start = fm_end + 1
			if lines[body_start] == "" then
				body_start = body_start + 1
			end
		end
	end

	local desc = {}
	for i = body_start, #lines do
		table.insert(desc, lines[i])
	end
	if #desc == 0 then
		desc = { "" }
	end
	return title, desc
end

local function bufnr_by_name(name)
	local b = vim.fn.bufnr(name, false)
	if type(b) == "number" and b > 0 then
		return b
	end
	return nil
end

local function extract_commit_hash(stdout, stderr)
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

function M.open()
	local Popup = require("nui.popup")
	local Layout = require("nui.layout")

	-- remember where user was, so closing returns there (not "first window")
	local prev_win = vim.api.nvim_get_current_win()

	local draft_path, root = draft_path_for_worktree()
	if not draft_path or not root then
		notify("Not inside a git worktree.", vim.log.levels.ERROR)
		return
	end

	-- Title buffer is scratch and always created for the popup
	local title_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[title_buf].buftype = "nofile"
	vim.bo[title_buf].swapfile = false
	vim.bo[title_buf].bufhidden = "wipe"
	vim.bo[title_buf].filetype = "gitcommit"

	-- Body buffer: reuse if already exists with the same name, otherwise create+name it.
	local existed_desc_buf = bufnr_by_name(draft_path) ~= nil
	local desc_buf = bufnr_by_name(draft_path)
	local created_desc_buf = false

	if not desc_buf then
		desc_buf = vim.api.nvim_create_buf(false, false)
		created_desc_buf = true
		vim.api.nvim_buf_set_name(desc_buf, draft_path)
	end

	vim.bo[desc_buf].buftype = ""
	vim.bo[desc_buf].swapfile = false
	vim.bo[desc_buf].bufhidden = "hide" -- don't auto-wipe buffers you didn't create
	vim.bo[desc_buf].filetype = "markdown"

	local title_popup = Popup({
		border = { style = "rounded", text = { top = " Title", top_align = "left" } },
		enter = true,
		focusable = true,
		bufnr = title_buf,
	})

	local desc_popup = Popup({
		border = { style = "rounded", text = { top = " Body", top_align = "left" } },
		enter = false,
		focusable = true,
		bufnr = desc_buf,
	})

	-- Make title “single-line”
	vim.api.nvim_create_autocmd("TextChangedI", {
		buffer = title_buf,
		callback = function()
			local line = (vim.api.nvim_buf_get_lines(title_buf, 0, 1, false)[1] or "")
			set_lines(title_buf, { (line:gsub("\n", "")) })
		end,
	})

	local layout = Layout(
		{
			relative = "editor",
			position = "50%",
			size = {
				width = math.max(60, math.floor(vim.o.columns * 0.70)),
				height = math.max(14, math.floor(vim.o.lines * 0.55)),
			},
		},
		Layout.Box({
			Layout.Box(title_popup, { size = 3 }),
			Layout.Box(desc_popup, { grow = 1 }),
		}, { dir = "col" })
	)

	local function restore_prev_window()
		if prev_win and vim.api.nvim_win_is_valid(prev_win) then
			pcall(vim.api.nvim_set_current_win, prev_win)
		end
	end

	local function close()
		layout:unmount()

		-- Title buffer: always safe to delete (scratch)
		if vim.api.nvim_buf_is_valid(title_buf) then
			pcall(vim.api.nvim_buf_delete, title_buf, { force = true })
		end

		-- Body buffer: delete ONLY if we created it for this popup.
		-- If the user already had it open elsewhere, don't touch it.
		if created_desc_buf and vim.api.nvim_buf_is_valid(desc_buf) then
			pcall(vim.api.nvim_buf_delete, desc_buf, { force = true })
		end

		-- jump back to where user was
		restore_prev_window()
	end

	local function focus_title()
		vim.api.nvim_set_current_win(title_popup.winid)
		vim.cmd("startinsert")
	end

	local function focus_desc()
		vim.api.nvim_set_current_win(desc_popup.winid)
		vim.cmd("startinsert")
	end

	local function toggle_focus()
		local cur = vim.api.nvim_get_current_win()
		if cur == title_popup.winid then
			focus_desc()
		else
			focus_title()
		end
	end

	local function save_draft()
		local title, desc = get_title_desc(title_buf, desc_buf)
		local ok = write_file(draft_path, serialize_draft(title, desc))
		if not ok then
			notify("Failed to write draft: " .. draft_path, vim.log.levels.ERROR)
			return
		end
		close()
		notify("Draft saved: " .. draft_path)
	end

	local function clear_all()
		set_lines(title_buf, { "" })
		set_lines(desc_buf, { "" })
		delete_file(draft_path)
		notify("Cleared (draft deleted).")
	end

	local function do_commit()
		local title, desc = get_title_desc(title_buf, desc_buf)
		if title == "" then
			notify("Title is empty (first -m).", vim.log.levels.WARN)
			return
		end

		local args = { "git", "commit", "-m", title }
		if #desc > 0 then
			table.insert(args, "-m")
			table.insert(args, table.concat(desc, "\n"))
		end

		local _, res = git_out(args, root)
		if res and res.code == 0 then
			delete_file(draft_path)

			-- best-effort: confirm hash (works even if git output parsing fails)
			local hash = extract_commit_hash(res.stdout, res.stderr)
			if not hash then
				local h2 = git_out({ "git", "rev-parse", "--short", "HEAD" }, root)
				if h2 and h2 ~= "" then
					hash = h2
				end
			end

			close()

			if hash then
				notify(string.format("Committed `%s`: %s", hash, title))
			else
				notify(string.format("Committed: %s", title))
			end
		else
			local err = (res and res.stderr and trim(res.stderr) ~= "" and res.stderr) or "Commit failed."
			notify(err, vim.log.levels.ERROR)
			-- keep draft intact on failure
		end
	end

	layout:mount()

	-- Load draft file into buffers.
	-- If desc_buf existed before and is modified, don't clobber it.
	local md = read_file(draft_path)
	if md and md ~= "" then
		local t, d = parse_draft(md)
		set_lines(title_buf, { t })
		if not existed_desc_buf or not vim.bo[desc_buf].modified then
			set_lines(desc_buf, d)
		end
	else
		set_lines(title_buf, { "" })
		if not existed_desc_buf or not vim.bo[desc_buf].modified then
			set_lines(desc_buf, { "" })
		end
	end

	title_popup.border:set_text(
		"bottom",
		"  [Tab] switch  [Ctrl+S] draft  [Ctrl+Enter] commit  [Ctrl+L] clear  [q/Esc] close  ",
		"center"
	)

	local function map(buf, modes, lhs, rhs, desc)
		vim.keymap.set(modes, lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = desc })
	end

	for _, b in ipairs({ title_buf, desc_buf }) do
		map(b, "n", "q", close, "Close")
		map(b, "n", "<Esc>", close, "Close")
		map(b, { "n", "i" }, "<C-s>", save_draft, "Save draft")
		map(b, { "n", "i" }, "<C-l>", clear_all, "Clear")
		map(b, { "n", "i" }, "<C-CR>", do_commit, "Commit")

		map(b, { "n", "i" }, "<Tab>", toggle_focus, "Toggle focus")
		map(b, { "n", "i" }, "<S-Tab>", toggle_focus, "Toggle focus")
		map(b, { "n", "i" }, "<C-j>", focus_desc, "Focus body")
		map(b, { "n", "i" }, "<C-k>", focus_title, "Focus title")
	end

	focus_title()
end

return M
