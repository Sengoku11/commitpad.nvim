---@type CommitPadConfig
local Config = require("commitpad.config")
---@type CommitPadUtils
local Utils = require("commitpad.utils")
---@type CommitPadBuf
local Buf = require("commitpad.buf")
---@type CommitPadGit
local Git = require("commitpad.git")
---@type CommitPadFS
local FS = require("commitpad.fs")
---@type CommitPadStatusPaneModule
local StatusPane = require("commitpad.status_pane")
---@type CommitPadHints
local Hints = require("commitpad.hints")

---@class CommitPadInstance
---@field layout NuiLayout
---@field title_popup NuiPopup
---@field desc_popup NuiPopup
---@field footer_popup? NuiPopup
---@field status_popup? NuiPopup
---@field backdrop_win integer
---@field backdrop_buf integer
---@field augroup? integer

---@class CommitPadUI
---@field open fun(opts?: CommitPadOpenOpts)
---@field amend fun()
local M = {}

---@class CommitPadOpenOpts
---@field amend? boolean Whether to open in amend mode

---@type CommitPadInstance|nil
M.instance = nil

-- Conventional Commit Structure: <type>[optional scope][optional !]: <description>
local cc_regex =
	vim.regex([[^\(feat\|fix\|docs\|style\|refactor\|perf\|test\|build\|ci\|chore\|revert\)\%(([^)]\+)\)\?!\?: .]])

--- Extract content from buffers.
---@param title_buf integer
---@param desc_buf integer
---@param footer_buf? integer
---@return string title
---@return string[] desc
---@return string[] footer
local function get_commit_content(title_buf, desc_buf, footer_buf)
	local title = Utils.trim((Buf.get_lines(title_buf)[1] or ""))
	local desc = Buf.get_lines(desc_buf)
	while #desc > 0 and Utils.trim(desc[#desc]) == "" do
		table.remove(desc, #desc)
	end

	local footer = {}
	if footer_buf then
		footer = Buf.get_lines(footer_buf)
		-- Remove leading/trailing empty lines from footer for cleaner append
		while #footer > 0 and Utils.trim(footer[1]) == "" do
			table.remove(footer, 1)
		end
		while #footer > 0 and Utils.trim(footer[#footer]) == "" do
			table.remove(footer, #footer)
		end
	end

	return title, desc, footer
end

--- Open CommitPad in amend mode.
function M.amend()
	M.open({ amend = true })
end

--- Open the CommitPad UI.
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

	-- Remember where user was, so closing returns there
	local prev_win = vim.api.nvim_get_current_win()

	local body_path, title_path, footer_path, root = FS.draft_paths_for_worktree(is_amend)
	if not body_path or not title_path or not footer_path or not root then
		Utils.notify("Not inside a git worktree.", vim.log.levels.ERROR)
		return
	end

	local title_buf = Buf.load_file(title_path, "gitcommit")
	-- Without this, Neovim forces a gitcommit newline at char 73, which breaks the single-line layout.
	vim.bo[title_buf].textwidth = 0

	local desc_buf = Buf.load_file(body_path, "markdown")

	-- Footer buffer is only loaded if enabled
	local footer_buf = nil
	if Config.options.footer then
		footer_buf = Buf.load_file(footer_path, "markdown")
	end

	local function load_head_to_buffers()
		local out, _ = Git.out({ "git", "log", "-1", "--pretty=%B" }, root)
		if not out then
			return
		end

		local lines = vim.split(out, "\n")
		local title = table.remove(lines, 1) or ""
		while #lines > 0 and Utils.trim(lines[1]) == "" do
			table.remove(lines, 1)
		end
		Buf.set_lines(title_buf, { title })
		Buf.set_lines(desc_buf, lines)
	end

	-- If amend buffers are effectively empty (whitespace only), pull HEAD
	if is_amend then
		local t_lines = Buf.get_lines(title_buf)
		local d_lines = Buf.get_lines(desc_buf)

		-- Checks if buffer content is effectively empty
		local function is_buf_empty(lines)
			return Utils.trim(table.concat(lines, "")) == ""
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
	if Config.options.footer and footer_buf then
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

	local status_popup = nil
	if Config.options.stage_files then
		local status_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(status_buf, 0, -1, false, { " Loading status..." })
		vim.bo[status_buf].filetype = "text"
		vim.bo[status_buf].modifiable = false

		status_popup = Popup({
			border = { style = "rounded", text = { top = " Status ", top_align = "left" } },
			enter = false,
			focusable = true, -- Must be focusable for scrolling/navigation
			bufnr = status_buf,
			win_options = {
				winhighlight = "Normal:Comment,FloatBorder:Comment,FloatTitle:Comment",
				wrap = false, -- Enable horizontal scroll by disabling wrap
			},
		})
	end

	local status = StatusPane.new(status_popup)

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
			Buf.set_lines(title_buf, { joined })
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
	if Config.options.footer and footer_popup then
		table.insert(layout_boxes, Layout.Box(footer_popup, { size = "20%" }))
	end

	local main_box = nil
	if status_popup then
		main_box = Layout.Box({
			Layout.Box(layout_boxes, { dir = "col", grow = 1 }),
			Layout.Box(status_popup, { size = "30%" }),
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

	-- Define a pure black highlight for the backdrop
	vim.api.nvim_set_hl(0, "CommitPadBackdrop", { bg = "#000000", default = true })

	-- Create Backdrop
	local backdrop_buf = vim.api.nvim_create_buf(false, true)
	local backdrop_win = vim.api.nvim_open_win(backdrop_buf, false, {
		relative = "editor",
		width = vim.o.columns,
		height = vim.o.lines,
		row = 0,
		col = 0,
		style = "minimal",
		focusable = false,
		zindex = 40, -- Lower than Nui (default 50)
	})
	vim.api.nvim_set_option_value("winblend", 40, { win = backdrop_win }) -- Darker backdrop (0=opaque, 100=trans)
	vim.api.nvim_set_option_value("winhighlight", "Normal:CommitPadBackdrop", { win = backdrop_win })
	vim.bo[backdrop_buf].buftype = "nofile"
	vim.bo[backdrop_buf].filetype = "commitpad_backdrop"

	M.instance = {
		layout = layout,
		title_popup = title_popup,
		desc_popup = desc_popup,
		footer_popup = footer_popup,
		status_popup = status_popup,
		backdrop_win = backdrop_win,
		backdrop_buf = backdrop_buf,
		augroup = nil, -- Will be set after mount
	}

	local function restore_prev_window()
		if prev_win and vim.api.nvim_win_is_valid(prev_win) then
			pcall(vim.api.nvim_set_current_win, prev_win)
		end
	end

	-- Logic for closing the layout and optionally restoring focus
	local function close(skip_restore)
		if M.instance then
			status:clear_hover()
			-- Clean up backdrop and augroup
			if M.instance.augroup then
				pcall(vim.api.nvim_del_augroup_by_id, M.instance.augroup)
			end
			if M.instance.backdrop_win and vim.api.nvim_win_is_valid(M.instance.backdrop_win) then
				vim.api.nvim_win_close(M.instance.backdrop_win, true)
			end
			if M.instance.backdrop_buf and vim.api.nvim_buf_is_valid(M.instance.backdrop_buf) then
				vim.api.nvim_buf_delete(M.instance.backdrop_buf, { force = true })
			end
			M.instance.layout:unmount()
			M.instance = nil
		end
		-- Only jump back to original window if we are NOT skipping it.
		-- (skip_restore is true when we are closing because focus moved to another popup)
		if not skip_restore then
			restore_prev_window()
		end
	end

	local function save_snapshot()
		-- Simply trigger a save on the buffers. Neovim handles the file write and undo sync.
		-- Using 'write' instead of 'update' ensures disk state is synced even if modified flag is stale.
		Buf.save(title_buf)
		Buf.save(desc_buf)
		if footer_buf then
			Buf.save(footer_buf)
		end
	end

	local function close_with_save(skip_restore)
		save_snapshot()
		close(skip_restore)
	end

	local function focus_popup(popup)
		if popup and popup.winid and vim.api.nvim_win_is_valid(popup.winid) then
			vim.api.nvim_set_current_win(popup.winid)
		end
	end

  -- stylua: ignore start
	local function focus_title() focus_popup(title_popup) end
	local function focus_desc() focus_popup(desc_popup) end
	local function focus_footer() focus_popup(footer_popup) end
	local function focus_status() focus_popup(status_popup) end
	-- stylua: ignore end

	-- Precalculate cycle to avoid table allocation on every keypress (Upvalue)
	-- NOTE: order matters
	local focus_cycle = { title_popup, desc_popup }
	if footer_popup then
		table.insert(focus_cycle, footer_popup)
	end
	if status_popup then
		table.insert(focus_cycle, status_popup)
	end

	local function toggle_focus()
		-- ensure we end up in Normal mode even if Tab is pressed from Insert
		vim.cmd("stopinsert")

		local cur = vim.api.nvim_get_current_win()

		for i, popup in ipairs(focus_cycle) do
			if popup.winid == cur then
				local next_idx = (i % #focus_cycle) + 1
				focus_popup(focus_cycle[next_idx])
				return
			end
		end

		-- Fallback: If focus is lost or outside the cycle (e.g., backdrop), reset to title
		focus_title()
	end

	-- Helpers for cross-pane navigation
	local last_input_win = nil

	local function jump_to_status()
		vim.cmd("stopinsert")
		last_input_win = vim.api.nvim_get_current_win()
		focus_status()
		status:render_hover()
	end

	local function jump_from_status()
		status:clear_hover()
		if last_input_win and vim.api.nvim_win_is_valid(last_input_win) then
			vim.api.nvim_set_current_win(last_input_win)
		else
			focus_title()
		end
	end

	local function clear_all()
		Buf.set_lines(title_buf, { "" })
		Buf.set_lines(desc_buf, { "" })
		-- Explicitly NOT clearing footer_buf
		Utils.notify("Cleared Title and Body.")
	end

	local function do_reset_amend()
		load_head_to_buffers()
		Utils.notify("Reset to HEAD.")
	end

	local function do_commit(push_after)
		-- 1) Collect and validate message parts from current buffers.
		local title, desc, footer = get_commit_content(title_buf, desc_buf, footer_buf)
		if title == "" then
			Utils.notify("Title is empty (first -m).", vim.log.levels.WARN)
			return
		end

		-- 2) Execute git commit/amend synchronously; stop early on failure.
		local short_hash, res = Git.commit_message(root, title, desc, footer, is_amend)
		if res and res.code == 0 then
			if short_hash then
				Utils.notify(string.format("Committed `%s`: %s", short_hash, title))
			else
				Utils.notify(string.format("Committed: %s", title))
			end

			if push_after then
				-- 3) Optional async push step; commit stays successful even if push fails.
				local full_hash, branch = Git.resolve_push_target(root)
				if full_hash and branch then
					local shown_hash = short_hash or full_hash:sub(1, 7)
					Utils.notify(string.format("Pushing `%s` to `%s`...", shown_hash, branch))

					Git.push_head_async(root, {
						branch = branch,
						full_hash = full_hash,
						force_with_lease = is_amend,
					}, function(push_res)
						vim.schedule(function()
							if push_res and push_res.code == 0 then
								Utils.notify(string.format("Pushed `%s` to `%s`.", shown_hash, branch))
							else
								local err = (push_res and Utils.trim(push_res.stderr or "")) or ""
								if err == "" then
									err = (push_res and Utils.trim(push_res.stdout or "")) or ""
								end
								-- stylua: ignore
								Utils.notify(
									string.format("Push failed for `%s`: %s", shown_hash, err ~= "" and err or "Push failed."),
									vim.log.levels.ERROR
								)
							end
						end)
					end)
				else
					Utils.notify("Committed, but failed to resolve hash/branch for push.", vim.log.levels.ERROR)
				end
			end

			-- 4) Commit succeeded: clear input drafts, keep footer, then close UI.
			Buf.set_lines(title_buf, { "" })
			Buf.set_lines(desc_buf, { "" })
			save_snapshot()

			if not is_amend then
				FS.clear_amend_drafts()
			end

			close()
		else
			-- Commit failed: keep draft buffers intact for retry/edit.
			local err = (res and res.stderr and Utils.trim(res.stderr) ~= "" and res.stderr) or "Commit failed."
			Utils.notify(err, vim.log.levels.ERROR)
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

	-- PERF: Defer status calculation to non-blocking callback to allow instant window mounting.
	if Config.options.stage_files and status_popup then
		status:refresh_async(Git, root, total_width)
	end

	-- Auto-close on focus lost
	local close_augroup = vim.api.nvim_create_augroup("commitpad_autoclose", { clear = true })
	M.instance.augroup = close_augroup
	vim.api.nvim_create_autocmd("WinLeave", {
		group = close_augroup,
		callback = function()
			vim.schedule(function()
				if not M.instance then
					return
				end
				local cur = vim.api.nvim_get_current_win()
				local is_internal = (cur == M.instance.title_popup.winid)
					or (cur == M.instance.desc_popup.winid)
					or (M.instance.footer_popup and cur == M.instance.footer_popup.winid)
					or (M.instance.status_popup and cur == M.instance.status_popup.winid)

				if not is_internal then
					-- Pass true to skip restoring the previous window, preventing the new popup from being buried
					close_with_save(true)
				end
			end)
		end,
	})
	if status_popup then
		status:setup_autocmds(close_augroup)
	end

	local function apply_win_opts(win)
		-- Inherit from global vim.go.spell
		pcall(vim.api.nvim_set_option_value, "spell", vim.go.spell, { win = win })
	end

	apply_win_opts(title_popup.winid)
	apply_win_opts(desc_popup.winid)
	if footer_popup then
		apply_win_opts(footer_popup.winid)
	end
	if status_popup then
		status:apply_highlights()
	end

	local is_clean = Utils.trim((Buf.get_lines(title_buf)[1] or "")) == ""
	local mappings = Config.options.mappings
	local map_commit = mappings.commit
	local map_commit_and_push = mappings.commit_and_push
	local map_clear_or_reset = mappings.clear_or_reset
	local map_jump_to_status = mappings.jump_to_status
	local map_jump_to_input = mappings.jump_to_input
	local map_stage_toggle = mappings.stage_toggle

	local function render_control_hints()
		if not Config.options.hints.controls then
			title_popup.border:set_text("bottom", "", "left")
			return
		end
		if not title_popup.winid or not vim.api.nvim_win_is_valid(title_popup.winid) then
			return
		end

		local available = math.max(0, vim.api.nvim_win_get_width(title_popup.winid) - 2)
		local hint = Hints.pick_control_hint({
			is_amend = is_amend,
			map_commit = map_commit,
			map_commit_and_push = map_commit_and_push,
			map_clear_or_reset = map_clear_or_reset,
			available_width = available,
		})
		title_popup.border:set_text("bottom", hint.text, hint.align)
	end

	render_control_hints()
	vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
		group = close_augroup,
		callback = function()
			vim.schedule(render_control_hints)
		end,
	})

	local function map(buf, modes, lhs, rhs, desc, map_opts)
		vim.keymap.set(
			modes,
			lhs,
			rhs,
			vim.tbl_extend("force", { buffer = buf, silent = true, nowait = true, desc = desc }, map_opts or {})
		)
	end

	-- Apply shared mappings to all active buffers
	local active_buffers = { title_buf, desc_buf }
	if footer_buf then
		table.insert(active_buffers, footer_buf)
	end

	-- stylua: ignore
	for _, b in ipairs(active_buffers) do
		map(b, "n", "q", close_with_save, "Close (Auto-Save)")
		map(b, "n", "<Esc>", close_with_save, "Close (Auto-Save)")

		-- Prevents jump out of the CommitPad popup
		map(b, "n", "<C-w><C-l>", close_with_save, "Close (Auto-Save)")
		map(b, "n", "<C-w><C-h>", close_with_save, "Close (Auto-Save)")

		if is_amend then
			map(b, { "n", "i" }, map_clear_or_reset, do_reset_amend, "Reset to HEAD")
		else
			map(b, { "n", "i" }, map_clear_or_reset, clear_all, "Clear Body/Title")
		end

		map(b, { "n" }, map_commit, function() do_commit(false) end, "Commit")
		map(b, { "n" }, map_commit_and_push, function() do_commit(true) end, "Commit and Push")
		map(b, { "n" }, "<Tab>", toggle_focus, "Toggle focus")

		if status_popup then
			-- Jump to the Status box
			map(b, { "n" }, map_jump_to_status, jump_to_status, "Jump to Status")
			map(b, { "n" }, "]]", jump_to_status, "Jump to Status")
		end
	end

	-- Mappings for Status Popup
	-- stylua: ignore
	if status_popup then
		map(status_popup.bufnr, "n", "q", close_with_save, "Close")
		map(status_popup.bufnr, "n", "<Esc>", close_with_save, "Close")
		map(status_popup.bufnr, "n", map_jump_to_input, jump_from_status, "Jump to Input")
		map(status_popup.bufnr, "n", "[[", jump_from_status, "Jump to Input")
		map(status_popup.bufnr, "n", "<Tab>", toggle_focus, "Toggle focus")
		map(
			status_popup.bufnr,
			"n",
			map_stage_toggle,
			function() status:toggle_stage_under_cursor(Git, root, total_width) end,
			"Toggle Stage"
		)
		map(status_popup.bufnr, "n", "yy", function() status:yank_line() end, "Yank Full Status Line")
	end

	-- Specific navigation
	-- stylua: ignore
	local nav_map = function(buf, down_func, up_func)
		if down_func then map(buf, { "n", "i" }, "<C-j>", down_func, "Focus Down") end
		if up_func then map(buf, { "n", "i" }, "<C-k>", up_func, "Focus Up") end
	end

	nav_map(title_buf, focus_desc, nil)
	if Config.options.footer and footer_popup then
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

	-- Smart h/l navigation between input buffers and status box
	local function smart_l()
		if not status_popup then
			vim.cmd("normal! l")
			return
		end

		local line = vim.api.nvim_get_current_line()
		local col = vim.api.nvim_win_get_cursor(0)[2]

		-- If line is empty or cursor is at the last character, jump to status
		if #line == 0 or col >= #line - 1 then
			jump_to_status()
		else
			vim.cmd("normal! l")
		end
	end

	local function smart_h()
		local col = vim.api.nvim_win_get_cursor(0)[2]
		-- If cursor is at the first character of the status buffer, jump back
		if col == 0 then
			jump_from_status()
		else
			vim.cmd("normal! h")
		end
	end

	-- Apply smart navigation to all buffers
	for _, b in ipairs(active_buffers) do
		map(b, "n", "j", smart_j, "Smart Down")
		map(b, "n", "k", smart_k, "Smart Up")
		map(b, "n", "<Down>", smart_j, "Smart Down")
		map(b, "n", "<Up>", smart_k, "Smart Up")

		if status_popup then
			map(b, "n", "l", smart_l, "Smart Right")
			map(b, "n", "<Right>", smart_l, "Smart Right")
		end
	end

	-- Apply smart_h to status buffer
	if status_popup then
		map(status_popup.bufnr, "n", "h", smart_h, "Smart Left")
		map(status_popup.bufnr, "n", "<Left>", smart_h, "Smart Left")
	end

	local function allow_completion_or_toggle(key)
		return function()
			if vim.fn.pumvisible() == 1 then
				return key
			end
			vim.schedule(function()
				toggle_focus()
			end)
			return ""
		end
	end

	-- QoL navigation using the fact that Title is always one-liner.
	map(title_buf, "i", "<CR>", allow_completion_or_toggle("<CR>"), "Jump to body", { expr = true })
	map(title_buf, "i", "<Tab>", allow_completion_or_toggle("<Tab>"), "Jump to body", { expr = true })
	map(title_buf, "i", "<Down>", toggle_focus, "Jump to body")
	map(title_buf, "i", "<C-j>", toggle_focus, "Jump to body")
	map(title_buf, "n", "o", toggle_focus, "Jump to body")
	map(title_buf, "n", "O", toggle_focus, "Jump to body")

	update_title()

	focus_title()
	if is_clean then
		vim.cmd("startinsert")
	end
end

return M
