local M = {}

-- Defaults
M.config = {
	footer = false,
}

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

-- State tracking
M.instance = nil

-- Structure: <type>[optional scope][optional !]: <description>
local cc_regex =
	vim.regex([[^\(feat\|fix\|docs\|style\|refactor\|perf\|test\|build\|ci\|chore\|revert\)\%(([^)]\+)\)\?!\?: .]])

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

-- Return distinct files for body, title, and footer
local function draft_paths_for_worktree()
	local root = worktree_root()
	if not root then
		return nil, nil, nil, nil
	end
	local gitdir = worktree_gitdir(root)
	if not gitdir then
		return nil, nil, nil, nil
	end
	local dir = gitdir .. "/commitpad"
	ensure_dir(dir)
	return dir .. "/draft.md", dir .. "/draft.title", dir .. "/draft.footer", root
end

local function buf_lines(buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return {}
	end
	return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function set_lines(buf, lines)
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	end
end

local function get_commit_content(title_buf, desc_buf, footer_buf)
	local title = trim((buf_lines(title_buf)[1] or ""))
	local desc = buf_lines(desc_buf)
	while #desc > 0 and trim(desc[#desc]) == "" do
		table.remove(desc, #desc)
	end

	local footer = {}
	if footer_buf then
		footer = buf_lines(footer_buf)
		-- Remove leading/trailing empty lines from footer for cleaner append
		while #footer > 0 and trim(footer[1]) == "" do
			table.remove(footer, 1)
		end
		while #footer > 0 and trim(footer[#footer]) == "" do
			table.remove(footer, #footer)
		end
	end

	return title, desc, footer
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
	-- Check validity of the window.
	-- If the user closed the window manually (e.g. :q), M.instance is stale.
	if M.instance and M.instance.title_popup and M.instance.title_popup.winid then
		if vim.api.nvim_win_is_valid(M.instance.title_popup.winid) then
			vim.api.nvim_set_current_win(M.instance.title_popup.winid)
			return
		else
			-- State was stale, reset it and continue to open new window
			M.instance = nil
		end
	end

	local Popup = require("nui.popup")
	local Layout = require("nui.layout")

	-- remember where user was, so closing returns there (not "first window")
	local prev_win = vim.api.nvim_get_current_win()

	local body_path, title_path, footer_path, root = draft_paths_for_worktree()
	if not body_path or not root then
		notify("Not inside a git worktree.", vim.log.levels.ERROR)
		return
	end

	-- Prepare the spell settings before window creation.
	-- This ignores local overrides in the current window (e.g. NvimTree)
	local function prepare_spell(buf)
		local lang = vim.go.spelllang
		local spellfile = vim.go.spellfile

		-- Safety fallback if global lang is empty
		if lang == "" or not lang then
			lang = "en"
		end

		pcall(vim.api.nvim_set_option_value, "spelllang", lang, { buf = buf })
		pcall(vim.api.nvim_set_option_value, "spellfile", spellfile, { buf = buf })
		pcall(vim.api.nvim_set_option_value, "spelloptions", vim.go.spelloptions, { buf = buf })
	end

	-- Use bufadd/bufload to attach buffers to specific files for persistent undo
	local function load_file_buffer(path, ft)
		local buf = vim.fn.bufadd(path)
		vim.fn.bufload(buf)
		vim.bo[buf].buftype = "" -- Must be empty (normal file) for undofile to work
		vim.bo[buf].swapfile = false
		vim.bo[buf].filetype = ft
		vim.bo[buf].undofile = true
		prepare_spell(buf)
		return buf
	end

	local title_buf = load_file_buffer(title_path, "gitcommit")
	-- Without this, Neovim forces a gitcommit newline at char 73, which breaks the single-line layout.
	vim.bo[title_buf].textwidth = 0

	local desc_buf = load_file_buffer(body_path, "markdown")

	-- Footer buffer is only loaded if enabled
	local footer_buf = nil
	if M.config.footer then
		footer_buf = load_file_buffer(footer_path, "markdown")
	end

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

	local footer_popup = nil
	if M.config.footer and footer_buf then
		footer_popup = Popup({
			border = { style = "rounded", text = { top = " Footer (Persistent)", top_align = "left" } },
			enter = false,
			focusable = true,
			bufnr = footer_buf,
		})
	end

	-- Setup namespaces
	local ns_id = vim.api.nvim_create_namespace("commitpad_counter")
	local lint_ns = vim.api.nvim_create_namespace("commitpad_lint")

	-- Combined logic: Enforce single-line title + Update Char Counter + Lint
	-- Triggers on every change to keep UI in sync
	local function update_title()
		if not vim.api.nvim_buf_is_valid(title_buf) then
			return
		end

		local lines = vim.api.nvim_buf_get_lines(title_buf, 0, -1, false)

		-- 1. Enforce single line
		if #lines > 1 then
			local joined = table.concat(lines, " ")
			set_lines(title_buf, { joined })
			-- If in insert mode, put cursor at end of line to avoid jumping to start
			if vim.api.nvim_get_mode().mode == "i" then
				vim.api.nvim_win_set_cursor(0, { 1, #joined })
			end
			-- Update local var so counter uses the corrected text
			lines = { joined }
		end

		local line = lines[1] or ""

		-- 2. Char Counter logic
		local count = vim.fn.strchars(line)
		local limit_soft = 50
		local limit_hard = 72

		local hl = "Comment" -- Default
		if count > limit_hard then
			hl = "ErrorMsg" -- Red
		elseif count > limit_soft then
			hl = "WarningMsg" -- Yellow
		end

		vim.api.nvim_buf_clear_namespace(title_buf, ns_id, 0, -1)
		vim.api.nvim_buf_set_extmark(title_buf, ns_id, 0, 0, {
			virt_text = { { string.format(" [%d/%d]", count, limit_hard), hl } },
			virt_text_pos = "right_align",
			hl_mode = "combine",
		})

		-- 3. Conventional Commit Lint
		vim.api.nvim_buf_clear_namespace(title_buf, lint_ns, 0, -1)
		if #line > 0 then
			local is_valid = cc_regex:match_str(line)

			if not is_valid then
				-- Check if the first word is a valid type
				local first_word = line:match("^(%w+)")
				local valid_types = {
					feat = 1,
					fix = 1,
					chore = 1,
					docs = 1,
					refactor = 1,
					style = 1,
					test = 1,
					perf = 1,
					ci = 1,
					build = 1,
					revert = 1,
				}

				local end_col = #line
				if first_word and not valid_types[first_word] then
					end_col = #first_word
				end

				vim.api.nvim_buf_set_extmark(title_buf, lint_ns, 0, 0, {
					end_col = end_col,
					hl_group = "DiagnosticUnderlineWarn",
				})
			end
		end
	end

	vim.api.nvim_clear_autocmds({ buffer = title_buf, event = { "TextChanged", "TextChangedI" } })
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = title_buf,
		callback = update_title,
	})

	-- Construct layout boxes dynamically based on config
	local layout_boxes = {
		Layout.Box(title_popup, { size = 3 }),
		Layout.Box(desc_popup, { grow = 1 }),
	}
	if M.config.footer and footer_popup then
		table.insert(layout_boxes, Layout.Box(footer_popup, { size = "20%" }))
	end

	local layout = Layout({
		relative = "editor",
		position = "50%",
		size = {
			width = math.max(60, math.floor(vim.o.columns * 0.70)),
			height = math.max(14, math.floor(vim.o.lines * 0.65)),
		},
	}, Layout.Box(layout_boxes, { dir = "col" }))

	M.instance = {
		layout = layout,
		title_popup = title_popup,
		desc_popup = desc_popup,
		footer_popup = footer_popup,
	}

	local function restore_prev_window()
		if prev_win and vim.api.nvim_win_is_valid(prev_win) then
			pcall(vim.api.nvim_set_current_win, prev_win)
		end
	end

	local function close()
		if M.instance then
			M.instance.layout:unmount()
			M.instance = nil
		end
		-- jump back to where user was
		restore_prev_window()
	end

	local function save_snapshot()
		-- Simply trigger a save on the buffers. Neovim handles the file write and undo sync.
		vim.api.nvim_buf_call(title_buf, function()
			vim.cmd("silent! update")
		end)
		vim.api.nvim_buf_call(desc_buf, function()
			vim.cmd("silent! update")
		end)
		if footer_buf then
			vim.api.nvim_buf_call(footer_buf, function()
				vim.cmd("silent! update")
			end)
		end
	end

	local function close_with_save()
		save_snapshot()
		close()
	end

	local function focus_title()
		if title_popup.winid and vim.api.nvim_win_is_valid(title_popup.winid) then
			vim.api.nvim_set_current_win(title_popup.winid)
		end
	end

	local function focus_desc()
		if desc_popup.winid and vim.api.nvim_win_is_valid(desc_popup.winid) then
			vim.api.nvim_set_current_win(desc_popup.winid)
		end
	end

	local function focus_footer()
		if footer_popup and footer_popup.winid and vim.api.nvim_win_is_valid(footer_popup.winid) then
			vim.api.nvim_set_current_win(footer_popup.winid)
		end
	end

	local function toggle_focus()
		-- ensure we end up in Normal mode even if Tab is pressed from Insert
		vim.cmd("stopinsert")

		local cur = vim.api.nvim_get_current_win()
		if cur == title_popup.winid then
			focus_desc()
		elseif cur == desc_popup.winid then
			if M.config.footer and footer_popup then
				focus_footer()
			else
				focus_title()
			end
		else
			focus_title()
		end
	end

	local function clear_all()
		set_lines(title_buf, { "" })
		set_lines(desc_buf, { "" })
		-- Explicitly NOT clearing footer_buf
		notify("Cleared Title and Body (Footer preserved).")
	end

	local function do_commit()
		local title, desc, footer = get_commit_content(title_buf, desc_buf, footer_buf)
		if title == "" then
			notify("Title is empty (first -m).", vim.log.levels.WARN)
			return
		end

		local args = { "git", "commit", "-m", title }

		if #desc > 0 then
			table.insert(args, "-m")
			table.insert(args, table.concat(desc, "\n"))
		end

		if #footer > 0 then
			table.insert(args, "-m")
			table.insert(args, table.concat(footer, "\n"))
		end

		local _, res = git_out(args, root)
		if res and res.code == 0 then
			-- best-effort: confirm hash (works even if git output parsing fails)
			local hash = extract_commit_hash(res.stdout, res.stderr)
			if not hash then
				local h2 = git_out({ "git", "rev-parse", "--short", "HEAD" }, root)
				if h2 and h2 ~= "" then
					hash = h2
				end
			end

			if hash then
				notify(string.format("Committed `%s`: %s", hash, title))
			else
				notify(string.format("Committed: %s", title))
			end

			-- Clear text and save immediately.
			set_lines(title_buf, { "" })
			set_lines(desc_buf, { "" })
			-- Footer is preserved intentionally
			save_snapshot()

			close()
		else
			local err = (res and res.stderr and trim(res.stderr) ~= "" and res.stderr) or "Commit failed."
			notify(err, vim.log.levels.ERROR)
			-- keep draft intact on failure
		end
	end

	-- Autosave on exit
	local group = vim.api.nvim_create_augroup("commitpad_autosave", { clear = true })
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = save_snapshot,
	})

	layout:mount()

	local function apply_win_opts(win)
		-- Inherit from global vim.go.spell
		pcall(vim.api.nvim_set_option_value, "spell", vim.go.spell, { win = win })
	end

	apply_win_opts(title_popup.winid)
	apply_win_opts(desc_popup.winid)
	if footer_popup then
		apply_win_opts(footer_popup.winid)
	end

	local is_clean = trim((buf_lines(title_buf)[1] or "")) == ""

	title_popup.border:set_text(
		"bottom",
		"  [Tab] switch  [Leader+Enter] commit  [Ctrl+L] clear  [q/Esc] save and close  ",
		"center"
	)

	local function map(buf, modes, lhs, rhs, desc)
		vim.keymap.set(modes, lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = desc })
	end

	-- Apply shared mappings to all active buffers
	local active_buffers = { title_buf, desc_buf }
	if footer_buf then
		table.insert(active_buffers, footer_buf)
	end

	for _, b in ipairs(active_buffers) do
		map(b, "n", "q", close_with_save, "Close (Auto-Save)")
		map(b, "n", "<Esc>", close_with_save, "Close (Auto-Save)")
		map(b, { "n", "i" }, "<C-l>", clear_all, "Clear Body/Title")
		map(b, { "n" }, "<leader><CR>", do_commit, "Commit")

		map(b, { "n" }, "<Tab>", toggle_focus, "Toggle focus")
	end

	-- Specific navigation
	local nav_map = function(buf, down_func, up_func)
		if down_func then
			map(buf, { "n", "i" }, "<C-j>", down_func, "Focus Down")
		end
		if up_func then
			map(buf, { "n", "i" }, "<C-k>", up_func, "Focus Up")
		end
	end

	nav_map(title_buf, focus_desc, nil)
	if M.config.footer and footer_popup then
		nav_map(desc_buf, focus_footer, focus_title)
		nav_map(footer_buf, nil, focus_desc)
	else
		nav_map(desc_buf, nil, focus_title)
	end

	map(title_buf, "i", "<CR>", toggle_focus, "Jump to body")
	map(title_buf, "i", "<Tab>", toggle_focus, "Jump to body")

	update_title()

	focus_title()
	if is_clean then
		vim.cmd("startinsert")
	end
end

return M
