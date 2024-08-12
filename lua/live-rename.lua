local lsp_methods = require("vim.lsp.protocol").Methods

local M = {}

local extmark_ns = vim.api.nvim_create_namespace("user.util.input.extmark")
local win_hl_ns = vim.api.nvim_create_namespace("user.util.input.win_hl")
local buf_hl_ns = vim.api.nvim_create_namespace("user.util.input.buf_hl")

local cfg = {
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
    request_timeout = 1500,
    hl = {
        current = "CurSearch",
        others = "Search",
    },
}

--- session context
local C = {}

function M.setup(user_cfg)
    cfg = vim.tbl_deep_extend("force", cfg, user_cfg or {})
end

function M.map(opts)
    return function()
        M.rename(opts)
    end
end

--- slightly modified from `vim.lsp.client.lua`
---@param client vim.lsp.Client
---@param method string
---@param params lsp.TextDocumentPositionParams
---@param bufnr integer
---@return table<string,any>?
local function lsp_request_sync(client, method, params, bufnr)
    local request_result = nil
    local function sync_handler(err, result, context, config)
        request_result = {
            err = err,
            result = result,
            context = context,
            config = config
        }
    end

    local success, request_id = client.request(method, params, sync_handler, bufnr)
    if not success then
        return nil
    end

    local wait_result = vim.wait(cfg.request_timeout, function()
        return request_result ~= nil
    end, 5)

    if not wait_result then
        if request_id then
            client.cancel_request(request_id)
        end
        return nil
    end
    return request_result
end


local function rename_refs_handler(transaction_id)
    ---@param err string?
    ---@param result lsp.WorkspaceEdit?
    return function(err, result)
        -- check if the user is still in the same renaming session
        if C.ref_transaction_id == nil or C.ref_transaction_id ~= transaction_id then
            return
        end

        if err or result == nil then
            vim.notify(string.format("[LSP] rename, error getting references: `%s`", err))
            return
        end

        local document_edits
        if result.changes then
            for uri, edits in pairs(result.changes) do
                if vim.uri_to_bufnr(uri) == C.doc_buf then
                    document_edits = edits
                    break
                end
            end
        elseif result.documentChanges then
            for _, change in ipairs(result.documentChanges) do
                if change.edits and change.textDocument and vim.uri_to_bufnr(change.textDocument.uri) == C.doc_buf then
                    document_edits = change.edits
                    break
                end
            end
        end
        if not document_edits then
            return
        end

        ---@type lsp.Range[]
        local editing_ranges = {}
        ---@type lsp.Position
        local pos = C.rename_params.position
        local win_offset = 0
        for _, edit in ipairs(document_edits) do
            local range = edit.range
            assert(range.start.line == range["end"].line)
            if range.start.line ~= pos.line then
                -- on other line
                table.insert(editing_ranges, range)
            elseif pos.character < range.start.character or pos.character >= range["end"].character then
                -- on same line but not inside the character range
                if pos.character >= range["end"].character then
                    local len = range["end"].character - range.start.character
                    win_offset = win_offset + len
                end
                table.insert(editing_ranges, range)
            end
        end

        -- update window position
        if win_offset > 0 then
            local win_opts = {
                -- relative to buffer text
                relative = "win",
                win = C.doc_win,
                bufpos = { C.line, C.col },
                row = 0,
                -- correct for extmarks on the same line
                col = -win_offset
            }
            vim.api.nvim_win_set_config(C.win, win_opts)
        end

        -- also show edit in other occurrences
        C.editing_ranges = {}
        for _, range in ipairs(editing_ranges) do
            local line = range.start.line
            local start_col = vim.lsp.util._get_line_byte_from_position(C.doc_buf, range.start,
                C.client.offset_encoding)
            local end_col = vim.lsp.util._get_line_byte_from_position(C.doc_buf, range["end"],
                C.client.offset_encoding)

            local extmark_id = vim.api.nvim_buf_set_extmark(C.doc_buf, extmark_ns, line, start_col, {
                end_col = end_col,
                virt_text_pos = "inline",
                virt_text = { { C.new_text, cfg.hl.others } },
                conceal = "",
            })

            table.insert(C.editing_ranges, {
                extmark_id = extmark_id,
                line = line,
                start_col = start_col,
                end_col = end_col,
            })
        end
    end
end

function M.rename(opts)
    opts = opts or {}

    local cword = vim.fn.expand("<cword>")
    local text = opts.text or cword or ""
    local text_width = vim.fn.strdisplaywidth(text)

    C.new_text = text
    C.doc_buf = vim.api.nvim_get_current_buf()
    C.doc_win = vim.api.nvim_get_current_win()

    -- get word start
    local old_pos = vim.api.nvim_win_get_cursor(C.doc_win)
    C.line = old_pos[1] - 1
    vim.fn.search(cword, "bc")
    local new_pos = vim.api.nvim_win_get_cursor(C.doc_win)
    vim.api.nvim_win_set_cursor(0, old_pos)
    C.col = old_pos[2]
    C.end_col = C.col
    if new_pos[1] == old_pos[1] then
        C.col = new_pos[2]
        C.end_col = C.col + #cword
    end

    local clients = vim.lsp.get_clients({
        bufnr = C.doc_buf,
        method = lsp_methods.rename,
    })
    local client = clients[1]
    if not client then
        vim.notify("[LSP] rename, no matching server attached")
        return
    end
    C.rename_params = vim.lsp.util.make_position_params(C.doc_win, client.offset_encoding)
    C.rename_params.newName = cword
    C.client = client

    -- make initial request to receive edit ranges
    local transaction_id = math.random()
    local handler = rename_refs_handler(transaction_id)
    C.client.request(lsp_methods.textDocument_rename, C.rename_params, handler, C.doc_buf)
    C.ref_transaction_id = transaction_id

    -- conceal word in document with spaces, requires at least concealleval=2
    C.prev_conceallevel = vim.wo[C.doc_win].conceallevel
    vim.wo[C.doc_win].conceallevel = 2

    C.extmark_id = vim.api.nvim_buf_set_extmark(C.doc_buf, extmark_ns, C.line, C.col, {
        end_col = C.end_col,
        virt_text_pos = "inline",
        virt_text = { { string.rep(" ", text_width), cfg.hl.current } },
        conceal = "",
    })

    -- create buf
    C.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(C.buf, "lsp:rename")
    vim.api.nvim_buf_set_lines(C.buf, 0, 1, false, { text })

    -- create win
    local win_opts = {
        -- relative to buffer text
        relative = "win",
        win = C.doc_win,
        bufpos = { C.line, C.col },
        row = 0,
        col = 0,

        width = text_width + 2,
        height = 1,
        style = "minimal",
        border = "none",
    }
    C.win = vim.api.nvim_open_win(C.buf, false, win_opts)
    vim.wo[C.win].wrap = true

    -- highlights and transparency
    vim.api.nvim_set_option_value("winblend", 100, {
        scope = "local",
        win = C.win,
    })
    vim.api.nvim_set_hl(win_hl_ns, "Normal", { fg = nil, bg = nil })
    vim.api.nvim_win_set_hl_ns(C.win, win_hl_ns)

    -- key mappings
    for _, k in ipairs(cfg.keys.submit) do
        vim.keymap.set(k[1], k[2], M.submit, { buffer = C.buf, desc = "Submit rename" })
    end
    for _, k in ipairs(cfg.keys.cancel) do
        vim.keymap.set(k[1], k[2], M.hide, { buffer = C.buf, desc = "Cancel rename" })
    end

    local group = vim.api.nvim_create_augroup("live-rename", {})
    -- update when input changes
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP", "CursorMoved" }, {
        group = group,
        buffer = C.buf,
        callback = M.update,
    })
    -- cleanup when window is closed
    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        buffer = C.buf,
        callback = M.hide,
        once = true,
    })

    -- focus and enter insert mode
    vim.api.nvim_set_current_win(C.win)
    if opts.insert then
        vim.cmd.startinsert()
        vim.api.nvim_win_set_cursor(C.win, { 1, text_width })
    end
end

function M.update()
    C.new_text = vim.api.nvim_buf_get_lines(C.buf, 0, 1, false)[1]
    local text_width = vim.fn.strdisplaywidth(C.new_text)

    vim.api.nvim_buf_set_extmark(C.doc_buf, extmark_ns, C.line, C.col, {
        id = C.extmark_id,
        end_col = C.end_col,
        virt_text_pos = "inline",
        virt_text = { { string.rep(" ", text_width), cfg.hl.current } },
        conceal = "",
    })

    -- also show edit in other occurrences
    if C.editing_ranges then
        for _, e in ipairs(C.editing_ranges) do
            vim.api.nvim_buf_set_extmark(C.doc_buf, extmark_ns, e.line, e.start_col, {
                id = e.extmark_id,
                end_col = e.end_col,
                virt_text_pos = "inline",
                virt_text = { { C.new_text, cfg.hl.others } },
                conceal = "",
            })
        end
    end

    vim.api.nvim_buf_clear_namespace(C.buf, buf_hl_ns, 0, -1)
    vim.api.nvim_buf_add_highlight(C.buf, buf_hl_ns, cfg.hl.current, 0, 0, -1)

    -- avoid line wrapping due to the window being to small
    vim.api.nvim_win_set_width(C.win, text_width + 2)
end

function M.submit()
    local mode = vim.api.nvim_get_mode().mode;
    if mode == "i" then
        vim.cmd.stopinsert()
    end

    -- do a sync request to avoid flicker when deleting extmarks
    C.rename_params.newName = C.new_text
    local resp = lsp_request_sync(C.client, lsp_methods.textDocument_rename, C.rename_params, C.doc_buf)
    if resp then
        local handler = C.client.handlers[lsp_methods.textDocument_rename]
            or vim.lsp.handlers[lsp_methods.textDocument_rename]
        handler(resp.err, resp.result, resp.context, resp.config)
    end

    M.hide()
end

function M.hide()
    vim.wo[C.doc_win].conceallevel = C.prev_conceallevel
    vim.api.nvim_buf_clear_namespace(C.doc_buf, extmark_ns, 0, -1)

    if C.win and vim.api.nvim_win_is_valid(C.win) then
        vim.api.nvim_win_close(C.win, false)
    end

    if C.buf and vim.api.nvim_buf_is_valid(C.buf) then
        vim.api.nvim_buf_delete(C.buf, {})
    end

    -- reset context
    C = {}
end

return M
