# CommitPad

![commitpad.nvim](docs/showcase.png)

A lightweight popup for writing Git commit messages directly within Neovim.

It facilitates a descriptive commit style (e.g. [Mitchell Hashimoto](https://x.com/mitchellh/status/1867314498723594247)) by providing a dedicated writing environment.

## Features

* **Full Editor Power:** The input field is a standard `markdown` buffer. Unlike the CLI, you get your **formatters, linters, spell checkers, and LSP completion** while you type.
* **Worktree-Isolated Drafts:** Drafts are saved to `$(git rev-parse --absolute-git-dir)/commitpad/draft.md`. They persist between sessions, don't clutter your working directory (`git status` is clean), and handle `git worktree` contexts automatically.
* **Simple Workflow:** Open the popup, write your message, then choose to **save** (draft), **clear**, or **commit**.

## Requirements

- Neovim **0.10+** (uses `vim.system`)
- [`MunifTanjim/nui.nvim`](https://github.com/MunifTanjim/nui.nvim)

## Installation (lazy.nvim)

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

