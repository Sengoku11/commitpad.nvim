---@class CommitPadControlHintsOpts
---@field is_amend boolean
---@field map_commit string
---@field map_commit_and_push string
---@field map_clear_or_reset string
---@field available_width integer
---@field strdisplaywidth? fun(text: string): integer

---@class CommitPadControlHintsResult
---@field text string
---@field align string

---@class CommitPadHints
---@field pick_control_hint fun(opts: CommitPadControlHintsOpts): CommitPadControlHintsResult
local M = {}

---Select the most descriptive control hint string that fits the available width.
---@param opts CommitPadControlHintsOpts
---@return CommitPadControlHintsResult
function M.pick_control_hint(opts)
	local display_width = opts.strdisplaywidth or vim.fn.strdisplaywidth

	local hint_clear = opts.is_amend and "Reset" or "Clear"
	local hint_commit = opts.is_amend and "Amend" or "Commit"
	local hint_push = opts.is_amend and "Amend & Push" or "Commit & Push"
	local hint_push_compact = opts.is_amend and "A&P" or "C&P"

	local variants = {
		{
			text = string.format(
				" [%s] %s   [%s] %s   [%s] %s ",
				opts.map_commit,
				hint_commit,
				opts.map_commit_and_push,
				hint_push,
				opts.map_clear_or_reset,
				hint_clear
			),
			align = "center",
		},
		{
			text = string.format(
				" [%s] %s  [%s] %s  [%s] %s ",
				opts.map_commit,
				hint_commit,
				opts.map_commit_and_push,
				hint_push_compact,
				opts.map_clear_or_reset,
				hint_clear
			),
			align = "center",
		},
		{
			text = string.format(
				" %s:%s  %s:%s  %s:%s ",
				opts.map_commit,
				hint_commit,
				opts.map_commit_and_push,
				hint_push_compact,
				opts.map_clear_or_reset,
				hint_clear
			),
			align = "left",
		},
		{
			text = string.format(" %s  %s  %s ", opts.map_commit, opts.map_commit_and_push, opts.map_clear_or_reset),
			align = "left",
		},
		{
			text = string.format(" %s ", opts.map_commit),
			align = "left",
		},
	}

	for _, variant in ipairs(variants) do
		if display_width(variant.text) <= opts.available_width then
			return variant
		end
	end

	return {
		text = "",
		align = "left",
	}
end

return M
