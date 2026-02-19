---@class CommitPadStatusPaneModule
local M = {}
local Config = require("commitpad.config")
local Utils = require("commitpad.utils")

---@class CommitPadStatusLineMeta
---@field full_line string
---@field full_path? string
---@field section? "staged"|"unstaged"
---@field partial? boolean
---@field show_hover boolean

---@class CommitPadStatusPane
---@field popup NuiPopup|nil
---@field line_meta table<integer, CommitPadStatusLineMeta>
---@field hover_buf integer|nil
---@field hover_win integer|nil
local StatusPane = {}
StatusPane.__index = StatusPane

---Create a status-pane helper object.
---@param popup NuiPopup|nil
---@return CommitPadStatusPane
function M.new(popup)
	return setmetatable({
		popup = popup,
		-- PERF: Store full-row metadata once during status render so hover expansion is O(1) (no git/fs refetch).
		line_meta = {},
		hover_buf = nil,
		hover_win = nil,
	}, StatusPane)
end

function StatusPane:clear_hover()
	if self.hover_win and vim.api.nvim_win_is_valid(self.hover_win) then
		pcall(vim.api.nvim_win_close, self.hover_win, true)
	end
	self.hover_win = nil
end

---@return integer
function StatusPane:ensure_hover_buf()
	if self.hover_buf and vim.api.nvim_buf_is_valid(self.hover_buf) then
		return self.hover_buf
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = false
	self.hover_buf = buf
	return buf
end

---Render full-path hover expansion as an overlay on the current row.
---This is intentionally drawn as an overlay window so text can exceed the status pane width.
function StatusPane:render_hover()
	if not self.popup then
		self:clear_hover()
		return
	end

	local s_buf = self.popup.bufnr
	local s_win = self.popup.winid
	if not vim.api.nvim_buf_is_valid(s_buf) or not s_win or not vim.api.nvim_win_is_valid(s_win) then
		self:clear_hover()
		return
	end

	if vim.api.nvim_get_current_buf() ~= s_buf then
		self:clear_hover()
		return
	end

	local row = vim.api.nvim_win_get_cursor(s_win)[1]
	local meta = self.line_meta[row]
	if not meta or not meta.show_hover then
		self:clear_hover()
		return
	end

	local hover_buf = self:ensure_hover_buf()
	vim.bo[hover_buf].modifiable = true
	vim.api.nvim_buf_set_lines(hover_buf, 0, -1, false, { meta.full_line })
	vim.bo[hover_buf].modifiable = false

	local config = {
		relative = "win",
		win = s_win,
		row = row - 1,
		col = 0,
		width = math.max(1, math.min(vim.o.columns, vim.fn.strdisplaywidth(meta.full_line))),
		height = 1,
		style = "minimal",
		focusable = false,
		zindex = 200,
	}

	if self.hover_win and vim.api.nvim_win_is_valid(self.hover_win) then
		vim.api.nvim_win_set_buf(self.hover_win, hover_buf)
		vim.api.nvim_win_set_config(self.hover_win, config)
	else
		self.hover_win = vim.api.nvim_open_win(hover_buf, false, config)
	end

	pcall(vim.api.nvim_set_option_value, "wrap", false, { win = self.hover_win })
	pcall(vim.api.nvim_set_option_value, "winhighlight", "Normal:Comment,FloatBorder:Comment", { win = self.hover_win })
	pcall(vim.api.nvim_set_option_value, "number", false, { win = self.hover_win })
	pcall(vim.api.nvim_set_option_value, "relativenumber", false, { win = self.hover_win })
	pcall(vim.api.nvim_set_option_value, "signcolumn", "no", { win = self.hover_win })
	pcall(vim.api.nvim_set_option_value, "foldcolumn", "0", { win = self.hover_win })
end

---Refresh status contents and cached full-row metadata asynchronously.
---@param git CommitPadGit
---@param root string
---@param total_width integer
---@param focus_path? string
---@param focus_section? "staged"|"unstaged"
function StatusPane:refresh_async(git, root, total_width, focus_path, focus_section)
	if not self.popup then
		return
	end

	local s_buf = self.popup.bufnr
	local s_win = self.popup.winid
	git.get_status_files_async(
		root,
		vim.schedule_wrap(function(staged_list, unstaged_list, totals)
			if not vim.api.nvim_buf_is_valid(s_buf) then
				return
			end

			self:clear_hover()
			local formatted_lines = {}
			local by_name = {}
			self.line_meta = {}
			local show_diff_counts = Config.options.hints.diff_counts ~= false
			local staged_totals = (totals and totals.staged) or { added = 0, deleted = 0 }
			local unstaged_totals = (totals and totals.unstaged) or { added = 0, deleted = 0 }

			local function map_files(list)
				for _, f in ipairs(list) do
					local name = vim.fn.fnamemodify(f.path, ":t")
					by_name[name] = by_name[name] or {}
					table.insert(by_name[name], f)
				end
			end
			map_files(staged_list)
			map_files(unstaged_list)

			local status_box_width = math.floor(total_width * 0.3)
			if s_win and vim.api.nvim_win_is_valid(s_win) then
				status_box_width = vim.api.nvim_win_get_width(s_win)
			end
			-- Effective text width: box width - 2 (borders).
			local content_width = math.max(5, status_box_width - 2)
			-- Effective text width: content width - 3 (status "M ").
			local max_len = math.max(5, content_width - 3)
			local branch_max_len = content_width

			---@param section_name string
			---@param count integer
			---@param section_totals GitLineTotals
			---@return string
			local function format_section_header(section_name, count, section_totals)
				local label = string.format("%s (%d)", section_name, count)
				if not show_diff_counts then
					if vim.fn.strchars(label) > content_width then
						return vim.fn.strcharpart(label, 0, math.max(1, content_width - 1)) .. "…"
					end
					return label
				end

				local summary = string.format("+%d -%d", section_totals.added, section_totals.deleted)
				local summary_len = vim.fn.strchars(summary)
				local max_label_len = math.max(1, content_width - summary_len - 1)
				if vim.fn.strchars(label) > max_label_len then
					label = vim.fn.strcharpart(label, 0, math.max(1, max_label_len - 1)) .. "…"
				end

				local spaces = math.max(1, content_width - vim.fn.strchars(label) - summary_len)
				return label .. string.rep(" ", spaces) .. summary
			end

			local branch_name = git.current_branch(root)
			if not branch_name then
				local short_head = git.out({ "git", "rev-parse", "--short", "HEAD" }, root)
				if short_head and short_head ~= "" then
					branch_name = "detached@" .. short_head
				else
					branch_name = "(unknown)"
				end
			end

			local branch_text = branch_name
			local branch_over_limit = vim.fn.strchars(branch_text) > branch_max_len
			if branch_over_limit then
				branch_text = vim.fn.strcharpart(branch_text, 0, math.max(1, branch_max_len - 1)) .. "…"
			end

			local branch_display_line = branch_text
			local branch_full_line = branch_name
			table.insert(formatted_lines, branch_display_line)
			self.line_meta[#formatted_lines] = {
				full_line = branch_full_line,
				show_hover = branch_display_line ~= branch_full_line or branch_over_limit,
			}

			local has_changes = (#staged_list > 0) or (#unstaged_list > 0)
			if has_changes then
				table.insert(formatted_lines, "")
			end

			local function format_and_append(list, section)
				for _, f in ipairs(list) do
					local name = vim.fn.fnamemodify(f.path, ":t")
					local path_text = name
					local over_limit_before_trunc = false

					-- If collision exists, show full path (simplest "smart fold")
					if #by_name[name] > 1 then
						path_text = f.path
					end

					-- Truncate path if too long
					over_limit_before_trunc = vim.fn.strchars(path_text) > max_len
					if over_limit_before_trunc then
						local parts = vim.split(path_text, "/")
						if #parts > 1 then
							local built = parts[#parts]
							for i = #parts - 1, 1, -1 do
								local candidate = parts[i] .. "/" .. built
								if vim.fn.strchars("…/" .. candidate) <= max_len then
									built = candidate
								else
									break
								end
							end
							path_text = "…/" .. built
						end
					end

					local mark = f.status
					if f.partial then
						mark = mark .. "*"
					end

					local display_line = string.format("%-2s %s", mark, path_text)
					local full_line = string.format("%-2s %s", mark, f.path)
					table.insert(formatted_lines, display_line)
					self.line_meta[#formatted_lines] = {
						full_line = full_line,
						full_path = f.path,
						section = section,
						partial = f.partial,
						show_hover = (display_line ~= full_line) or over_limit_before_trunc,
					}
				end
			end

			if #staged_list > 0 then
				table.insert(formatted_lines, format_section_header("Staged", #staged_list, staged_totals))
				format_and_append(staged_list, "staged")
			end

			if #unstaged_list > 0 then
				if #staged_list > 0 then
					table.insert(formatted_lines, "")
				end
				table.insert(formatted_lines, format_section_header("Unstaged", #unstaged_list, unstaged_totals))
				format_and_append(unstaged_list, "unstaged")
			end

			if not has_changes then
				table.insert(formatted_lines, "")
				table.insert(formatted_lines, "No changes.")
			end

			vim.bo[s_buf].modifiable = true
			vim.api.nvim_buf_set_lines(s_buf, 0, -1, false, formatted_lines)
			vim.bo[s_buf].modifiable = false
			if focus_path and s_win and vim.api.nvim_win_is_valid(s_win) then
				local fallback_row = nil
				for row, meta in ipairs(self.line_meta) do
					if meta.full_path == focus_path then
						if not fallback_row then
							fallback_row = row
						end
						if focus_section == nil or meta.section == focus_section then
							fallback_row = row
							break
						end
					end
				end
				if fallback_row then
					pcall(vim.api.nvim_win_set_cursor, s_win, { fallback_row, 0 })
				end
			end
			self:render_hover()
		end)
	)
end

---@param result table|nil
---@param fallback string
---@return string
local function format_action_error(result, fallback)
	local err = ""
	if result then
		err = Utils.trim(result.stderr or "")
		if err == "" then
			err = Utils.trim(result.stdout or "")
		end
	end
	if err == "" then
		return fallback
	end
	return err
end

---@class CommitPadStatusCursorActionOpts
---@field execute fun(git: CommitPadGit, root: string, path: string, callback: fun(result: table|nil))
---@field verb string
---@field error_fallback string

---Run a stage/unstage-like action against the file under cursor.
---@param self CommitPadStatusPane
---@param git CommitPadGit
---@param root string
---@param total_width integer
---@param meta CommitPadStatusLineMeta
---@param opts CommitPadStatusCursorActionOpts
local function run_file_action(self, git, root, total_width, meta, opts)
	local path = meta.full_path
	if not path then
		Utils.notify("No file under cursor.", vim.log.levels.WARN)
		return
	end

	local section = meta.section
	opts.execute(git, root, path, function(result)
		vim.schedule(function()
			if result and result.code == 0 then
				self:refresh_async(git, root, total_width, path, section)
				return
			end
			Utils.notify(
				string.format(
					"Failed to %s `%s`: %s",
					opts.verb,
					path,
					format_action_error(result, opts.error_fallback)
				),
				vim.log.levels.ERROR
			)
		end)
	end)
end

---@return CommitPadStatusLineMeta|nil
function StatusPane:file_under_cursor()
	if not self.popup then
		return nil
	end

	local s_win = self.popup.winid
	if not s_win or not vim.api.nvim_win_is_valid(s_win) then
		return nil
	end

	local row = vim.api.nvim_win_get_cursor(s_win)[1]
	local meta = self.line_meta[row]
	if not meta or not meta.full_path then
		return nil
	end

	return meta
end

---Toggle stage/unstage for file under cursor in status pane and refresh status view.
---@param git CommitPadGit
---@param root string
---@param total_width integer
function StatusPane:toggle_stage_under_cursor(git, root, total_width)
	local meta = self:file_under_cursor()
	if not meta then
		Utils.notify("No file under cursor.", vim.log.levels.WARN)
		return
	end

	local opts = nil
	if meta.section == "staged" then
		opts = {
			execute = function(git_mod, cwd, path, callback)
				git_mod.unstage_file_async(cwd, path, callback)
			end,
			verb = "unstage",
			error_fallback = "git unstage failed.",
		}
	elseif meta.section == "unstaged" then
		opts = {
			execute = function(git_mod, cwd, path, callback)
				git_mod.stage_file_async(cwd, path, callback)
			end,
			verb = "stage",
			error_fallback = "git add failed.",
		}
	else
		Utils.notify("No actionable file under cursor.", vim.log.levels.WARN)
		return
	end

	run_file_action(self, git, root, total_width, meta, opts)
end

---Attach status hover autocmds to a shared lifecycle augroup.
---@param augroup integer
function StatusPane:setup_autocmds(augroup)
	if not self.popup then
		return
	end

	vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
		group = augroup,
		buffer = self.popup.bufnr,
		callback = function()
			self:render_hover()
		end,
	})
	vim.api.nvim_create_autocmd("BufLeave", {
		group = augroup,
		buffer = self.popup.bufnr,
		callback = function()
			self:clear_hover()
		end,
	})
end

---Apply syntax highlights for status marks and section headers.
function StatusPane:apply_highlights()
	if not self.popup or not self.popup.winid or not vim.api.nvim_win_is_valid(self.popup.winid) then
		return
	end

	local function pick_hl(primary, fallback)
		if vim.fn.hlexists(primary) == 1 then
			return primary
		end
		return fallback
	end

	local branch_hl = pick_hl("fugitiveHeader", "Label")
	local staged_heading_hl = pick_hl("fugitiveStagedHeading", "Include")
	local unstaged_heading_hl = pick_hl("fugitiveUnstagedHeading", "Macro")
	local count_hl = pick_hl("fugitiveCount", "Number")

	-- Apply status-pane match highlights in the popup window context.
	vim.api.nvim_win_call(self.popup.winid, function()
		-- Branch line (row 1): match fugitive's "Head:" label color.
		vim.fn.matchaddpos(branch_hl, { { 1 } }, 15)
		-- STRICT regex: ^Char then optional * then whitespace.
		vim.fn.matchadd("String", [[\v^A\*?\s]]) -- Green (Added)
		vim.fn.matchadd("Function", [[\v^M\*?\s]]) -- Blue (Modified)
		vim.fn.matchadd("ErrorMsg", [[\v^D\*?\s]]) -- Red (Deleted)
		vim.fn.matchadd("WarningMsg", [[\v^R\*?\s]]) -- Orange (Renamed)
		vim.fn.matchadd("WarningMsg", [[\v^\?\*?\s]]) -- Orange/Warn (Untracked)
		-- Highlight star specifically with high priority
		vim.fn.matchadd("Special", [[\v^.\zs\*\ze\s]], 20)
		-- Headers
		vim.fn.matchadd(staged_heading_hl, [[^Staged\ze (\d\+)]])
		vim.fn.matchadd(unstaged_heading_hl, [[^Unstaged\ze (\d\+)]])
		vim.fn.matchadd(count_hl, [[\v^Staged \(\zs\d+\ze\)]])
		vim.fn.matchadd(count_hl, [[\v^Unstaged \(\zs\d+\ze\)]])
		vim.fn.matchadd("String", [[\v^(Staged|Unstaged) \(\d+\)\s+\zs\+\d+]])
		vim.fn.matchadd("ErrorMsg", [[\v^(Staged|Unstaged) \(\d+\)\s+\+\d+\s+\zs-\d+]])
	end)
end

---Yank canonical value from status line(s), excluding status prefixes like "M " for file rows.
function StatusPane:yank_line()
	if not self.popup then
		return
	end

	local s_buf = self.popup.bufnr
	local s_win = self.popup.winid
	if not s_win or not vim.api.nvim_win_is_valid(s_win) then
		return
	end

	local line_count = vim.api.nvim_buf_line_count(s_buf)
	local start_row = vim.api.nvim_win_get_cursor(s_win)[1]
	local end_row = math.min(line_count, start_row + vim.v.count1 - 1)
	local yanked = {}

	for row = start_row, end_row do
		local meta = self.line_meta[row]
		if meta then
			if meta.full_path then
				table.insert(yanked, meta.full_path)
			else
				table.insert(yanked, meta.full_line)
			end
		else
			local text = vim.api.nvim_buf_get_lines(s_buf, row - 1, row, false)[1] or ""
			table.insert(yanked, text)
		end
	end

	local payload = table.concat(yanked, "\n") .. "\n"
	local reg = vim.v.register
	if reg == "" then
		reg = '"'
	end
	if reg == "_" then
		return
	end

	vim.fn.setreg(reg, payload, "V")
	if reg ~= '"' then
		vim.fn.setreg('"', payload, "V")
	end
	vim.fn.setreg("0", payload, "V")
end

return M
