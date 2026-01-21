---@class CommitPadUI
---@field config CommitPadOptions
---@field setup fun(opts?: CommitPadOptions)
---@field open fun(opts?: CommitPadOpenOpts)
---@field amend fun()
local M = {}

---@class CommitPadOptions
---@field footer? boolean Show the footer buffer (default: false)
---@field stage_files? boolean Show staged files sidebar (default: false)
---@field command? string Command name (default: "CommitPad")
---@field amend_command? string Amend command name (default: "CommitPadAmend")

-- Defaults
M.config = {
	footer = false,
	stage_files = false,
}

---@class CommitPadOpenOpts
---@field amend? boolean Whether to open in amend mode

--- Setup the UI configuration
---@param opts? CommitPadOptions
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
	local cwd = vim.uv.cwd()
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

-- Get status tags (M/A/D/R) for staged buffer
local function get_staged_files(root)
	local out, _ = git_out({ "git", "diff", "--name-status", "--cached" }, root)
	if not out or out == "" then
		return {}
	end

	-- Parse "M path" into objects
	local results = {}
	for _, line in ipairs(vim.split(out, "\n")) do
		local status, path = line:match("^(%S+)%s+(.*)$")
		if status and path then
			-- Handle rename "R100" -> "R"
			table.insert(results, { status = status:sub(1, 1), path = path })
		end
	end
	return results
end

local function ensure_dir(path)
	vim.fn.mkdir(path, "p")
end

-- Return distinct files for body, title, and footer
local function draft_paths_for_worktree(is_amend)
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

	local prefix = is_amend and "amend" or "draft"
	return dir .. "/" .. prefix .. ".md", dir .. "/" .. prefix .. ".title", dir .. "/" .. prefix .. ".footer", root
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

function M.amend()
	M.open({ amend = true })
end

---@param opts? CommitPadOpenOpts
function M.open(opts)
	opts = opts or {}
	local is_amend = opts.amend or false

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

	local body_path, title_path, footer_path, root = draft_paths_for_worktree(is_amend)
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
		-- Sync with disk to ensure is_empty checks are accurate
		vim.api.nvim_buf_call(buf, function()
			vim.cmd("checktime")
		end)
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

	local function load_head_to_buffers()
		local out, r = git_out({ "git", "log", "-1", "--pretty=%B" }, root)
		if not out or r.code ~= 0 then
			return
		end

		local lines = vim.split(out, "\n")
		local title = table.remove(lines, 1) or ""
		while #lines > 0 and trim(lines[1]) == "" do
			table.remove(lines, 1)
		end
		set_lines(title_buf, { title })
		set_lines(desc_buf, lines)
	end

	-- If amend buffers are effectively empty (whitespace only), pull HEAD
	if is_amend then
		local t_lines = buf_lines(title_buf)
		local d_lines = buf_lines(desc_buf)

		-- Helper to check if buffer content is effectively empty
		local function is_buf_empty(lines)
			return trim(table.concat(lines, "")) == ""
		end

		if is_buf_empty(t_lines) and is_buf_empty(d_lines) then
			load_head_to_buffers()
			vim.cmd("silent! wall") -- Save immediately
		end
	end

	local border_top = " Title"
	if is_amend then
		border_top = " Title [Amend] "
	end

	local title_popup = Popup({
		border = { style = "rounded", text = { top = border_top, top_align = "left" } },
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

	-- Calculate total dimensions early for percentage math
	local total_width = math.max(60, math.floor(vim.o.columns * 0.70))
	local total_height = math.max(14, math.floor(vim.o.lines * 0.65))

	local staged_popup = nil
	if M.config.stage_files then
		local staged_files = get_staged_files(root)

		-- Smart path formatting (Start truncation + Smart folding)
		local formatted_lines = {}
		local by_name = {}

		-- Group by filename to detect collisions
		for _, f in ipairs(staged_files) do
			local name = vim.fn.fnamemodify(f.path, ":t")
			by_name[name] = by_name[name] or {}
			table.insert(by_name[name], f)
		end

		local staged_box_width = math.floor(total_width * 0.3)
		-- Effective text width: box width - 2 (borders) - 3 (status "M: ")
		local max_len = math.max(5, staged_box_width - 5)

		for _, f in ipairs(staged_files) do
			local name = vim.fn.fnamemodify(f.path, ":t")
			local path_text = name

			-- If collision exists, show full path (simplest "smart fold")
			if #by_name[name] > 1 then
				path_text = f.path
			end

			-- Truncate path if too long
			if vim.fn.strchars(path_text) > max_len then
				local parts = vim.split(path_text, "/")
				-- Only attempt to shorten if we actually have directories to strip
				if #parts > 1 then
					local built = parts[#parts] -- Always preserve the filename

					-- Try to add parents from right-to-left
					for i = #parts - 1, 1, -1 do
						local candidate = parts[i] .. "/" .. built
						-- Check if adding this parent keeps us under width (inc. "…/")
						if vim.fn.strchars("…/" .. candidate) <= max_len then
							built = candidate
						else
							break
						end
					end

					-- Apply the shortening with ellipsis
					path_text = "…/" .. built
				end
				-- If it was just a long filename (#parts == 1), we do nothing
				-- and let it overflow naturally.
			end

			table.insert(formatted_lines, string.format("%s: %s", f.status, path_text))
		end

		local staged_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(staged_buf, 0, -1, false, formatted_lines)
		vim.bo[staged_buf].filetype = "text"
		vim.bo[staged_buf].modifiable = false

		staged_popup = Popup({
			border = { style = "rounded", text = { top = " Staged ", top_align = "left" } },
			enter = false,
			focusable = true, -- Must be focusable for scrolling/navigation
			bufnr = staged_buf,
			win_options = {
				winhighlight = "Normal:Comment,FloatBorder:Comment,FloatTitle:Comment",
				wrap = false, -- Enable horizontal scroll by disabling wrap
			},
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

	local main_box = nil
	if staged_popup then
		main_box = Layout.Box({
			Layout.Box(layout_boxes, { dir = "col", grow = 1 }),
			Layout.Box(staged_popup, { size = "30%" }),
		}, { dir = "row" })
	else
		main_box = Layout.Box(layout_boxes, { dir = "col" })
	end

	local layout = Layout({
		relative = "editor",
		position = "50%",
		size = {
			width = total_width,
			height = total_height,
		},
	}, main_box)

	M.instance = {
		layout = layout,
		title_popup = title_popup,
		desc_popup = desc_popup,
		footer_popup = footer_popup,
		staged_popup = staged_popup,
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
		-- Using 'write' instead of 'update' ensures disk state is synced even if modified flag is stale.
		vim.api.nvim_buf_call(title_buf, function()
			vim.cmd("silent! write")
		end)
		vim.api.nvim_buf_call(desc_buf, function()
			vim.cmd("silent! write")
		end)
		if footer_buf then
			vim.api.nvim_buf_call(footer_buf, function()
				vim.cmd("silent! write")
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

	local function focus_staged()
		if staged_popup and staged_popup.winid and vim.api.nvim_win_is_valid(staged_popup.winid) then
			vim.api.nvim_set_current_win(staged_popup.winid)
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
			elseif staged_popup then
				focus_staged()
			else
				focus_title()
			end
		elseif footer_popup and cur == footer_popup.winid then
			if staged_popup then
				focus_staged()
			else
				focus_title()
			end
		elseif staged_popup and cur == staged_popup.winid then
			focus_title()
		else
			focus_title()
		end
	end

	-- Helpers for cross-pane navigation
	local last_input_win = nil

	local function jump_to_staged()
		vim.cmd("stopinsert")
		last_input_win = vim.api.nvim_get_current_win()
		focus_staged()
	end

	local function jump_from_staged()
		if last_input_win and vim.api.nvim_win_is_valid(last_input_win) then
			vim.api.nvim_set_current_win(last_input_win)
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

	local function do_reset_amend()
		load_head_to_buffers()
		notify("Reset to HEAD.")
	end

	local function do_commit()
		local title, desc, footer = get_commit_content(title_buf, desc_buf, footer_buf)
		if title == "" then
			notify("Title is empty (first -m).", vim.log.levels.WARN)
			return
		end

		local args = { "git", "commit" }
		if is_amend then
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
	if staged_popup then
		-- Apply syntax highlighting explicitly after mount
		if vim.api.nvim_win_is_valid(staged_popup.winid) then
			vim.api.nvim_win_call(staged_popup.winid, function()
				vim.fn.matchadd("String", "^A:") -- Green (Added)
				vim.fn.matchadd("Function", "^M:") -- Blue (Modified)
				vim.fn.matchadd("ErrorMsg", "^D:") -- Red (Deleted)
				vim.fn.matchadd("WarningMsg", "^R:") -- Orange (Renamed)
			end)
		end
	end

	local is_clean = trim((buf_lines(title_buf)[1] or "")) == ""

	local hint_l = is_amend and "reset" or "clear"
	local hint_cr = is_amend and "amend" or "commit"

	title_popup.border:set_text(
		"bottom",
		string.format("  [Tab] switch  [Leader+Enter] %s  [Ctrl+L] %s  [q/Esc] save and close  ", hint_cr, hint_l),
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

		-- Prevents jump out of the CommitPad popup
		map(b, "n", "<C-w><C-l>", close_with_save, "Close (Auto-Save)")
		map(b, "n", "<C-w><C-h>", close_with_save, "Close (Auto-Save)")

		if is_amend then
			map(b, { "n", "i" }, "<C-l>", do_reset_amend, "Reset to HEAD")
		else
			map(b, { "n", "i" }, "<C-l>", clear_all, "Clear Body/Title")
		end

		map(b, { "n" }, "<leader><CR>", do_commit, "Commit")
		map(b, { "n" }, "<Tab>", toggle_focus, "Toggle focus")

		if staged_popup then
			-- Jump to the Staged box
			map(b, { "n" }, "<leader>l", jump_to_staged, "Jump to Staged")
			map(b, { "n" }, "]]", jump_to_staged, "Jump to Staged")
		end
	end

	-- Mappings for Staged Popup
	if staged_popup then
		map(staged_popup.bufnr, "n", "q", close_with_save, "Close")
		map(staged_popup.bufnr, "n", "<Esc>", close_with_save, "Close")
		map(staged_popup.bufnr, "n", "<leader>h", jump_from_staged, "Jump to Input")
		map(staged_popup.bufnr, "n", "[[", jump_from_staged, "Jump to Input")
		map(staged_popup.bufnr, "n", "<Tab>", toggle_focus, "Toggle focus")
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

	-- QoL j/k navigation (conditional buffer jumping)
	local function smart_j()
		local cur = vim.api.nvim_get_current_buf()
		local line = vim.api.nvim_win_get_cursor(0)[1]
		local count = vim.api.nvim_buf_line_count(cur)

		if cur == title_buf then
			focus_desc()
			vim.cmd("normal! gg")
		elseif cur == desc_buf then
			if line == count then
				if footer_popup then
					focus_footer()
				else
					focus_title()
				end
				vim.cmd("normal! gg")
			else
				vim.cmd("normal! j")
			end
		elseif footer_popup and cur == footer_buf then
			if line == count then
				focus_title()
				vim.cmd("normal! gg")
			else
				vim.cmd("normal! j")
			end
		end
	end

	local function smart_k()
		local cur = vim.api.nvim_get_current_buf()
		local line = vim.api.nvim_win_get_cursor(0)[1]

		if cur == title_buf then
			if footer_popup then
				focus_footer()
			else
				focus_desc()
			end
			vim.cmd("normal! G")
		elseif cur == desc_buf then
			if line == 1 then
				focus_title()
				-- Title is always 1 line, no need to move cursor
			else
				vim.cmd("normal! k")
			end
		elseif footer_popup and cur == footer_buf then
			if line == 1 then
				focus_desc()
				vim.cmd("normal! G")
			else
				vim.cmd("normal! k")
			end
		end
	end

	-- Smart h/l navigation between input buffers and staged files
	local function smart_l()
		if not staged_popup then
			vim.cmd("normal! l")
			return
		end

		local line = vim.api.nvim_get_current_line()
		local col = vim.api.nvim_win_get_cursor(0)[2]

		-- If line is empty or cursor is at the last character, jump to staged
		if #line == 0 or col >= #line - 1 then
			jump_to_staged()
		else
			vim.cmd("normal! l")
		end
	end

	local function smart_h()
		local col = vim.api.nvim_win_get_cursor(0)[2]
		-- If cursor is at the first character of the staged buffer, jump back
		if col == 0 then
			jump_from_staged()
		else
			vim.cmd("normal! h")
		end
	end

	-- Apply smart navigation to all buffers
	for _, b in ipairs(active_buffers) do
		map(b, "n", "j", smart_j, "Smart Down")
		map(b, "n", "k", smart_k, "Smart Up")
		if staged_popup then
			map(b, "n", "l", smart_l, "Smart Right")
		end
	end

	-- Apply smart_h to staged buffer
	if staged_popup then
		map(staged_popup.bufnr, "n", "h", smart_h, "Smart Left")
	end

	-- QoL navigation using the fact that Title is always one-liner.
	map(title_buf, "i", "<CR>", toggle_focus, "Jump to body")
	map(title_buf, "i", "<Tab>", toggle_focus, "Jump to body")
	map(title_buf, "i", "<Down>", toggle_focus, "Jump to body")
	map(title_buf, "i", "<C-j>", toggle_focus, "Jump to body")
	map(title_buf, "n", "o", toggle_focus, "Jump to body")
	map(title_buf, "n", "O", toggle_focus, "Jump to body")
	map(title_buf, "n", "<Down>", toggle_focus, "Jump to body")

	update_title()

	focus_title()
	if is_clean then
		vim.cmd("startinsert")
	end
end

return M
