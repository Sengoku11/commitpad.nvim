---@class CommitPadStatusPaneModule
local M = {}

---@class CommitPadStatusLineMeta
---@field full_line string
---@field full_path string
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
function StatusPane:refresh_async(git, root, total_width)
	if not self.popup then
		return
	end

	local s_buf = self.popup.bufnr
	git.get_status_files_async(
		root,
		vim.schedule_wrap(function(staged_list, unstaged_list)
			if not vim.api.nvim_buf_is_valid(s_buf) then
				return
			end

			self:clear_hover()
			local formatted_lines = {}
			local by_name = {}
			self.line_meta = {}

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
			-- Effective text width: box width - 2 (borders) - 3 (status "M: ")
			local max_len = math.max(5, status_box_width - 5)

			local function format_and_append(list)
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

					local display_line = string.format("%s: %s", mark, path_text)
					local full_line = string.format("%s: %s", mark, f.path)
					table.insert(formatted_lines, display_line)
					self.line_meta[#formatted_lines] = {
						full_line = full_line,
						full_path = f.path,
						show_hover = (display_line ~= full_line) or over_limit_before_trunc,
					}
				end
			end

			if #staged_list > 0 then
				table.insert(formatted_lines, "Staged:")
				format_and_append(staged_list)
			end

			if #unstaged_list > 0 then
				if #formatted_lines > 0 then
					table.insert(formatted_lines, "")
				end
				table.insert(formatted_lines, "Unstaged:")
				format_and_append(unstaged_list)
			end

			if #formatted_lines == 0 then
				table.insert(formatted_lines, " No changes.")
			end

			vim.bo[s_buf].modifiable = true
			vim.api.nvim_buf_set_lines(s_buf, 0, -1, false, formatted_lines)
			vim.bo[s_buf].modifiable = false
			self:render_hover()
		end)
	)
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

	vim.api.nvim_win_call(self.popup.winid, function()
		-- STRICT regex: ^Char then optional * then :
		vim.fn.matchadd("String", [[^A\*\?:]]) -- Green (Added)
		vim.fn.matchadd("Function", [[^M\*\?:]]) -- Blue (Modified)
		vim.fn.matchadd("ErrorMsg", [[^D\*\?:]]) -- Red (Deleted)
		vim.fn.matchadd("WarningMsg", [[^R\*\?:]]) -- Orange (Renamed)
		vim.fn.matchadd("WarningMsg", [[^?\*\?:]]) -- Orange/Warn (Untracked)
		-- Highlight star specifically with high priority
		vim.fn.matchadd("Special", [[^.\zs\*\ze:]], 20)
		-- Headers
		vim.fn.matchadd("Title", "^Staged:$")
		vim.fn.matchadd("Title", "^Unstaged:$")
	end)
end

---Yank full filepath from status line(s), excluding status prefixes like "M:".
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
		if meta and meta.full_path then
			table.insert(yanked, meta.full_path)
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
