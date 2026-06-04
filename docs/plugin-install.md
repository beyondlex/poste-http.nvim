# Poste Neovim Plugin

A Neovim plugin for executing HTTP requests from `.http` files.

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "yourusername/poste",
  config = function()
    require("poste").setup()
  end,
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "yourusername/poste",
  config = function()
    require("poste").setup()
  end,
}
```

### Using [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'yourusername/poste'
```

Then add to your init.vim:
```vim
lua require("poste").setup()
```

## Usage

### Commands

- `:PosteRun` - Execute the request at the current cursor position
- `:PosteEnv` - Show the current environment
- `:PosteEnv <name>` - Switch to the specified environment

### Keymaps (in .http files)

- `<leader>rr` - Run request at cursor
- `]]` - Jump to next request separator (`###`)
- `[[` - Jump to previous request separator (`###`)

### Response Buffer

- Responses open in a vertical split (default 80 columns)
- Press `q` in the response buffer to close it
- All normal Vim operations work (yank, visual select, search, etc.)

## Configuration

```lua
require("poste").setup({
  poste_binary = "", -- Path to poste binary (auto-detects if empty)
  default_env = "dev", -- Default environment
  split_direction = "vertical", -- "vertical" or "horizontal"
  split_size = 80, -- Split size (columns for vertical, rows for horizontal)
})
```

## Status Line Integration

Add to your status line configuration:

```lua
-- For lualine.nvim
require('lualine').setup({
  sections = {
    lualine_c = { 'filename', 'v:lua.poste_status()' }
  }
})

-- Or use in your custom status line
vim.o.statusline = vim.o.statusline .. " %{v:lua.poste_status()}"
```

## Requirements

- Neovim 0.7.0 or later
- `poste` CLI tool built and available in PATH or in `./target/debug/poste`

## License

MIT
