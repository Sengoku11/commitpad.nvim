---@class CommitPadBuf
local M = {}

--- Get all lines from a buffer.
---@param buf integer
---@return string[]
function M.get_lines(buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return {}
	end
	return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- Set lines in a buffer.
---@param buf integer
---@param lines string[]
function M.set_lines(buf, lines)
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	end
end

--- Apply spelling options to a buffer based on global settings.
---@param buf integer
function M.prepare_spell(buf)
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

--- Load a file into a buffer with specific settings.
---@param path string
---@param ft string
---@return integer buf
function M.load_file(path, ft)
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
	M.prepare_spell(buf)
	return buf
end

--- Save a buffer to disk.
---@param buf integer Buffer handle
function M.save(buf)
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_call(buf, function()
			vim.cmd("silent! write")
		end)
	end
end

return M
