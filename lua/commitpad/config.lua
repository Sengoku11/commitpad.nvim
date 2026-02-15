---@class CommitPadConfig
---@field options CommitPadResolvedOptions
---@field setup fun(opts?: CommitPadOptions)
local M = {}

---@class CommitPadResolvedMappingsOptions
---@field commit string Commit/amend action
---@field commit_and_push string Commit/amend and push action
---@field clear_or_reset string Clear title/body or reset amend from HEAD
---@field jump_to_status string Jump from input to status pane
---@field jump_to_input string Jump from status pane to input
---@field stage_toggle string Toggle stage/unstage for file under cursor in status pane

---@type CommitPadResolvedMappingsOptions
local DEFAULT_MAPPINGS = {
	commit = "<leader><CR>",
	commit_and_push = "<leader>gp",
	clear_or_reset = "<C-l>",
	jump_to_status = "<leader>l",
	jump_to_input = "<leader>h",
	stage_toggle = "s",
}

---@class CommitPadResolvedHintsOptions
---@field controls boolean Display control hints in the input popup border

---@class CommitPadResolvedOptions
---@field footer boolean Show the footer buffer
---@field stage_files boolean Show staged files sidebar
---@field hints CommitPadResolvedHintsOptions Hint display options
---@field mappings CommitPadResolvedMappingsOptions CommitPad-local mappings
---@field command? string Command name
---@field amend_command? string Amend command name

---@type CommitPadResolvedOptions
local DEFAULT_OPTIONS = {
	footer = false,
	stage_files = false,
	hints = {
		controls = true,
	},
	mappings = DEFAULT_MAPPINGS,
}

---@class CommitPadHintsOptions
---@field controls? boolean Display control hints in the input popup border (default: true)

---@class CommitPadMappingsOptions
---@field commit? string Commit/amend action override (default: "<leader><CR>")
---@field commit_and_push? string Commit/amend and push action override (default: "<leader>gp")
---@field clear_or_reset? string Clear title/body or reset amend from HEAD override (default: "<C-l>")
---@field jump_to_status? string Jump from input to status pane override (default: "<leader>l")
---@field jump_to_input? string Jump from status pane to input override (default: "<leader>h")
---@field stage_toggle? string Toggle stage/unstage for file under cursor in status pane override (default: "s")

---@class CommitPadOptions
---@field footer? boolean Show the footer buffer (default: false)
---@field stage_files? boolean Show staged files sidebar (default: false)
---@field hints? CommitPadHintsOptions Hint display options (default: { controls = true })
---@field mappings? CommitPadMappingsOptions CommitPad-local mappings
---@field command? string Command name (default: "CommitPad")
---@field amend_command? string Amend command name (default: "CommitPadAmend")

---@type CommitPadResolvedOptions
M.options = vim.deepcopy(DEFAULT_OPTIONS)

local mapping_keys = {
	"commit",
	"commit_and_push",
	"clear_or_reset",
	"jump_to_status",
	"jump_to_input",
	"stage_toggle",
}

---@return CommitPadMappingsOptions
local function default_mappings_override()
	return {
		commit = DEFAULT_MAPPINGS.commit,
		commit_and_push = DEFAULT_MAPPINGS.commit_and_push,
		clear_or_reset = DEFAULT_MAPPINGS.clear_or_reset,
		jump_to_status = DEFAULT_MAPPINGS.jump_to_status,
		jump_to_input = DEFAULT_MAPPINGS.jump_to_input,
		stage_toggle = DEFAULT_MAPPINGS.stage_toggle,
	}
end

---@param opts CommitPadOptions
--- Validate mapping overrides and coerce invalid values back to defaults.
local function normalize_mappings(opts)
	if opts.mappings == nil then
		return
	end

	if type(opts.mappings) ~= "table" then
		vim.notify("commitpad.nvim: `mappings` must be a table; using defaults.", vim.log.levels.ERROR)
		opts.mappings = default_mappings_override()
		return
	end

	for _, key in ipairs(mapping_keys) do
		local value = opts.mappings[key]
		if value ~= nil and (type(value) ~= "string" or vim.trim(value) == "") then
			vim.notify(
				string.format(
					"commitpad.nvim: `mappings.%s` must be a non-empty string; using default `%s`.",
					key,
					DEFAULT_MAPPINGS[key]
				),
				vim.log.levels.ERROR
			)
			opts.mappings[key] = DEFAULT_MAPPINGS[key]
		end
	end
end

---@param mappings CommitPadResolvedMappingsOptions
---@param override_mappings? CommitPadMappingsOptions
--- Resolve duplicate mapping lhs values deterministically at setup time.
--- Keeps one action per key and resets conflicting actions back to defaults.
local function normalize_mapping_conflicts(mappings, override_mappings)
	local overridden = {}
	for _, key in ipairs(mapping_keys) do
		overridden[key] = override_mappings ~= nil and override_mappings[key] ~= nil
	end

	local max_iterations = #mapping_keys
	local iteration = 0
	while true do
		iteration = iteration + 1
		if iteration > max_iterations then
			vim.notify(
				"commitpad.nvim: conflict normalization exceeded iteration limit; keeping current mappings.",
				vim.log.levels.ERROR
			)
			break
		end

		local seen_lhs = {}
		local conflict_lhs, conflict_keys = nil, nil
		for _, key in ipairs(mapping_keys) do
			local lhs = mappings[key]
			if seen_lhs[lhs] then
				conflict_lhs = lhs
				conflict_keys = seen_lhs[lhs]
				table.insert(conflict_keys, key)
				break
			else
				seen_lhs[lhs] = { key }
			end
		end
		if not conflict_lhs or not conflict_keys then
			break
		end

		local reset_key = nil
		local overridden_conflicts = {}
		for _, key in ipairs(conflict_keys) do
			if overridden[key] and mappings[key] ~= DEFAULT_MAPPINGS[key] then
				table.insert(overridden_conflicts, key)
			end
		end
		if #overridden_conflicts == 1 then
			reset_key = overridden_conflicts[1]
		elseif #overridden_conflicts > 1 then
			-- If multiple override keys conflict, keep earlier precedence and reset the later one.
			reset_key = overridden_conflicts[#overridden_conflicts]
		else
			local non_default_conflicts = {}
			for _, key in ipairs(conflict_keys) do
				if mappings[key] ~= DEFAULT_MAPPINGS[key] then
					table.insert(non_default_conflicts, key)
				end
			end
			if #non_default_conflicts > 0 then
				reset_key = non_default_conflicts[#non_default_conflicts]
			end
		end
		if not reset_key then
			break
		end

		vim.notify(
			string.format(
				"commitpad.nvim: `mappings.%s` conflicts with `%s`; using default `%s`.",
				reset_key,
				conflict_lhs,
				DEFAULT_MAPPINGS[reset_key]
			),
			vim.log.levels.ERROR
		)
		mappings[reset_key] = DEFAULT_MAPPINGS[reset_key]
		overridden[reset_key] = false
	end
end

--- Setup the configuration options.
---@param opts? CommitPadOptions
function M.setup(opts)
	local normalized_opts = vim.deepcopy(opts or {})
	normalize_mappings(normalized_opts)
	---@type CommitPadResolvedOptions
	local next_options = vim.tbl_deep_extend("force", M.options, normalized_opts)
	normalize_mapping_conflicts(next_options.mappings, normalized_opts.mappings)
	M.options = next_options
end

return M
