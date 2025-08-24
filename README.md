# live-rename.nvim
A neovim plugin to live preview lsp renames.

https://github.com/user-attachments/assets/7cc03f60-3c59-45f5-b8e7-e53e324ce56b

## Installation
[__lazy.nvim__](https://github.com/folke/lazy.nvim)
```lua
{ "saecki/live-rename.nvim" }
```

[__vim-plug__](https://github.com/junegunn/vim-plug)
```
Plug 'saecki/live-rename.nvim'
```

## Setup (optional)
```lua
-- default config
require("live-rename").setup({
    -- Send a `textDocument/prepareRename` request to the server to
    -- determine the word to be renamed, can be slow on some servers.
    -- Otherwise fallback to using `<cword>`.
    prepare_rename = true,
    --- The timeout for the `textDocument/prepareRename` request and final
    --- `textDocument/rename` request when submitting.
    request_timeout = 1500,
    -- Make an initial `textDocument/rename` request to gather other
    -- occurences which are edited and use these ranges to preview.
    -- If disabled only the word under the cursor will have a preview.
    show_other_ocurrences = true,
    -- Try to infer patterns from the initial `textDocument/rename` request
    -- and use these to show hopefully better edit previews.
    use_patterns = true,
    -- The register which is used to temporarily record a macro into. This
    -- macro can then be executed on other symbols using the `macrorepeat`
    -- rename option.
    scratch_register = "l",
    keys = {
        submit = {
            { "n", "<cr>" },
            { "v", "<cr>" },
            { "i", "<cr>" },
        },
        cancel = {
            { "n", "<esc>" },
            { "n", "q" },
        },
    },
    hl = {
        current = "CurSearch",
        others = "Search",
    },
})
```

## Usage

```lua
-- Start in normal mode and maintain cursor position.
require("live-rename").rename()

-- Start in normal mode and jump to the start of the word.
require("live-rename").rename({ cursorpos = 0 })

-- Start in insert mode and jump to the end of the word
require("live-rename").rename({ insert = true, cursorpos = -1 })

-- Start in insert mode with an empty word
require("live-rename").rename({ text = "", insert = true })

-- The actions that happened in the previous rename window are recorded as a macro.
-- This macro is executed on the new word and the lsp rename is commited without
-- any further confirmation.
require("live-rename").rename({ macrorepeat = true, noconfirm = true })

-- Without `noconfirm` additional actions can be appended to the macro.
require("live-rename").rename({ macrorepeat = true })
```

live-rename includes a `map` function to make creating key mappings more ergonomic.  
The options accepted are the same as for `rename`.
```lua
local live_rename = require("live-rename")

-- the following are equivalent
vim.keymap.set("n", "<leader>r", live_rename.rename, { desc = "LSP rename" })
vim.keymap.set("n", "<leader>r", live_rename.map(), { desc = "LSP rename" })
vim.keymap.set("n", "<leader>r", live_rename.map({}), { desc = "LSP rename" })

-- the following are equivalent
vim.keymap.set("n", "<leader>R", live_rename.map({ text = "", insert = true }), { desc = "LSP rename" })
vim.keymap.set("n", "<leader>R", function() live_rename.rename({ text = "", insert = true }) end, { desc = "LSP rename" })
```

## Related
- [inc-rename.nvim](https://github.com/smjonas/inc-rename.nvim) is a similar plugin that implements the live preview using
  `inccommand`, while `live-rename.nvim` does so using extmarks and a floating window. The latter approach allows modal editing
  as if directly inside the buffer.
