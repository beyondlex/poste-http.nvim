-- dev/deps.lua — Poste dev dependencies
--
-- Extra plugins needed for testing Poste.
-- Poste itself is loaded automatically from source by setup.sh.
-- Edit, then run dev/setup.sh to sync.
--
-- Examples:
--   { "beyondlex/finder" }
--   { "ellisonleao/gruvbox.nvim", priority = 1000 }
--   { "nvim-treesitter/nvim-treesitter", build = ":TSUpdate" }

return {
  {
    "saghen/blink.cmp",
    branch = "v1",
    dependencies = { "saghen/blink.lib" },
  },
  {
    "stevearc/dressing.nvim",
  },
  {"beyondlex/finder",},

  -- {
  --   "folke/snacks.nvim",
  --   priority = 1000,
  --   lazy = false,
  --   opts = {
  --     -- your configuration comes here
  --     -- or leave it empty to use the default settings
  --     -- refer to the configuration section below
  --     -- bigfile = { enabled = false },
  --     dashboard = { enabled = true },
  --     explorer = { enabled = true },
  --     -- indent = { enabled = false },
  --     -- input = { enabled = false },
  --     picker = { enabled = true },
  --     -- notifier = { enabled = false },
  --     -- quickfile = { enabled = false },
  --     -- scope = { enabled = false },
  --     -- scroll = { enabled = false },
  --     -- statuscolumn = { enabled = false },
  --     -- words = { enabled = false },
  --   },
  -- },
  -- {
  --   "folke/which-key.nvim",
  --   event = "VeryLazy",
  --   opts = {
  --     -- your configuration comes here
  --     -- or leave it empty to use the default settings
  --     -- refer to the configuration section below
  --   },
  --   keys = {
  --     {
  --       "<leader>?",
  --       function()
  --         require("which-key").show({ global = false })
  --       end,
  --       desc = "Buffer Local Keymaps (which-key)",
  --     },
  --   },
  -- }
}
