# CommitPad

![commitpad.nvim](docs/showcase.png)

A lightweight popup for writing Git commit messages directly within Neovim.

It solves four common pains:
- the command line is too cramped for long messages,
- switching to a terminal is annoying,
- you want linters and autocompletion while typing,
- and you often need a per-worktree draft “stash” before you’re ready to commit.

If you prioritize detailed, descriptive commit messages (like [Mitchell Hashimoto's](https://x.com/mitchellh/status/1867314498723594247)), this tool is for you.

## Features

* **Home Court Advantage:** The input field is a standard markdown buffer (`filetype=markdown`). This means your existing formatters, linters, and LSP configs kick in automatically.
* **Smart Drafts:** Automatically saves one draft per repository/worktree.
* **Clean & Simple:** Just open the popup, write, and decide whether to **save**, **clear**, or **commit**.

## Requirements

- Neovim **0.10+** (uses `vim.system`)
- [`MunifTanjim/nui.nvim`](https://github.com/MunifTanjim/nui.nvim)

## lazy.nvim

```lua
{
  "Sengoku11/commitpad.nvim",
  dependencies = { "MunifTanjim/nui.nvim" },
  cmd = { "CommitPad" },
  keys = {
    { "<leader>gc", "<cmd>CommitPad<cr>", desc = "CommitPad" },
  },
  config = function()
    require("commitpad").setup()
  end,
}

