local lsp_methods = require("vim.lsp.protocol").Methods

local M = {}

local extmark_ns = vim.api.nvim_create_namespace("user.util.input.extmark")
local win_hl_ns = vim.api.nvim_create_namespace("user.util.input.win_hl")
local buf_hl_ns = vim.api.nvim_create_namespace("user.util.input.buf_hl")

local request_timeout = 1500
local hl = {
    current = "CurSearch",
    others = "Search",
}

function M.rename(opts)
    local cword = vim.fn.expand("<cword>")
    local text = opts.text or cword or ""
    local text_width = vim.fn.strdisplaywidth(text)

    M.doc_buf = vim.api.nvim_get_current_buf()
    M.doc_win = vim.api.nvim_get_current_win()

    -- get word start
    local old_pos = vim.api.nvim_win_get_cursor(M.doc_win)
    M.line = old_pos[1] - 1
    vim.fn.search(cword, "bc")
    local new_pos = vim.api.nvim_win_get_cursor(M.doc_win)
    vim.api.nvim_win_set_cursor(0, old_pos)
    M.col = old_pos[2]
    M.end_col = M.col
    if new_pos[1] == old_pos[1] then
        M.col = new_pos[2]
        M.end_col = M.col + #cword
    end

    local clients = vim.lsp.get_clients({
        bufnr = M.doc_buf,
        method = lsp_methods.rename,
    })
    if #clients == 0 then
        vim.notify("[LSP] rename, no matching server attached")
        return
    end

    ---@type lsp.Range[]?
    local editing_ranges = nil
    local on_same_line = 0
    for _, client in ipairs(clients) do
        if client.supports_method(lsp_methods.textDocument_references) then
            local params = vim.lsp.util.make_position_params(M.doc_win, client.offset_encoding)
            params.context = { includeDeclaration = true }
            local resp = client.request_sync(lsp_methods.textDocument_references, params, request_timeout, M.doc_buf)
            if resp and resp.err == nil and resp.result then
                ---@type lsp.Location[]
                local locations = resp.result
                editing_ranges = {}
                for _, loc in ipairs(locations) do
                    if vim.uri_to_bufnr(loc.uri) == M.doc_buf then
                        local range = loc.range
                        local pos = params.position
                        if range.start.line ~= pos.line or range["end"].line ~= pos.line then
                            table.insert(editing_ranges, loc.range)
                        elseif pos.character >= range.start.character and pos.character < range["end"].character then
                            -- ignore the range that is edited directly
                        else
                            if pos.character >= range["end"].character then
                                on_same_line = on_same_line + 1
                            end
                            table.insert(editing_ranges, loc.range)
                        end
                    end
                end
                M.client = client
                M.pos_params = params
                break
            end
        end
    end

    -- conceal word in document with spaces, requires at least concealleval=2
    M.prev_conceallevel = vim.wo[M.doc_win].conceallevel
    vim.wo[M.doc_win].conceallevel = 2

    M.extmark_id = vim.api.nvim_buf_set_extmark(M.doc_buf, extmark_ns, M.line, M.col, {
        end_col = M.end_col,
        virt_text_pos = "inline",
        virt_text = { { string.rep(" ", text_width), hl.current } },
        conceal = "",
    })

    -- also show edit in other occurrences
    if editing_ranges then
        M.editing_ranges = {}
        for _, range in ipairs(editing_ranges) do
            local line = range.start.line
            local start_col = vim.lsp.util._get_line_byte_from_position(M.doc_buf, range.start, M.client.offset_encoding)
            local end_col = vim.lsp.util._get_line_byte_from_position(M.doc_buf, range["end"], M.client.offset_encoding)

            local extmark_id = vim.api.nvim_buf_set_extmark(M.doc_buf, extmark_ns, line, start_col, {
                end_col = end_col,
                virt_text_pos = "inline",
                virt_text = { { text, hl.others } },
                conceal = "",
            })

            table.insert(M.editing_ranges, {
                extmark_id = extmark_id,
                line = line,
                start_col = start_col,
                end_col = end_col,
            })
        end
    end

    -- create buf
    M.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(M.buf, "lsp:rename")
    vim.api.nvim_buf_set_lines(M.buf, 0, 1, false, { text })

    -- create win
    local win_opts = {
        -- relative to buffer text
        relative = "win",
        win = M.doc_win,
        bufpos = { M.line, M.col },
        row = 0,
        -- correct for extmarks on the same line
        col = -on_same_line * #text,

        width = text_width + 2,
        height = 1,
        style = "minimal",
        border = "none",
    }
    M.win = vim.api.nvim_open_win(M.buf, false, win_opts)
    vim.wo[M.win].wrap = true

    -- highlights and transparency
    vim.api.nvim_set_option_value("winblend", 100, {
        scope = "local",
        win = M.win,
    })
    vim.api.nvim_set_hl(win_hl_ns, "Normal", { fg = nil, bg = nil })
    vim.api.nvim_win_set_hl_ns(M.win, win_hl_ns)

    -- key mappings
    vim.api.nvim_buf_set_keymap(M.buf, "n", "<cr>", "", { callback = M.submit, noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(M.buf, "v", "<cr>", "", { callback = M.submit, noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(M.buf, "i", "<cr>", "", { callback = M.submit, noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(M.buf, "n", "<esc>", "", { callback = M.hide, noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(M.buf, "n", "q", "", { callback = M.hide, noremap = true, silent = true })

    -- update when input changes
    local group = vim.api.nvim_create_augroup("user.util.input", {})
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP", "CursorMoved" }, {
        group = group,
        buffer = M.buf,
        callback = M.update,
    })

    -- focus and enter insert mode
    vim.api.nvim_set_current_win(M.win)
    if opts.insert then
        vim.cmd.startinsert()
        vim.api.nvim_win_set_cursor(M.win, { 1, text_width })
    end
end

function M.update()
    local new_text = vim.api.nvim_buf_get_lines(M.buf, 0, 1, false)[1]
    local text_width = vim.fn.strdisplaywidth(new_text)

    vim.api.nvim_buf_set_extmark(M.doc_buf, extmark_ns, M.line, M.col, {
        id = M.extmark_id,
        end_col = M.end_col,
        virt_text_pos = "inline",
        virt_text = { { string.rep(" ", text_width), hl.current } },
        conceal = "",
    })

    -- also show edit in other occurrences
    if M.editing_ranges then
        for _, e in ipairs(M.editing_ranges) do
            vim.api.nvim_buf_set_extmark(M.doc_buf, extmark_ns, e.line, e.start_col, {
                id = e.extmark_id,
                end_col = e.end_col,
                virt_text_pos = "inline",
                virt_text = { { new_text, hl.others } },
                conceal = "",
            })
        end
    end

    vim.api.nvim_buf_clear_namespace(M.buf, buf_hl_ns, 0, -1)
    vim.api.nvim_buf_add_highlight(M.buf, buf_hl_ns, hl.current, 0, 0, -1)

    -- avoid line wrapping due to the window being to small
    vim.api.nvim_win_set_width(M.win, text_width + 2)
end

--- slightly modified from `vim.lsp.client.lua`
---@param client vim.lsp.Client
---@param method string
---@param params lsp.TextDocumentPositionParams
---@param timeout_ms integer
---@param bufnr integer
---@return table<string,any>?
local function lsp_request_sync(client, method, params, timeout_ms, bufnr)
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

    local wait_result = vim.wait(timeout_ms, function()
        return request_result ~= nil
    end, 10)

    if not wait_result then
        if request_id then
            client.cancel_request(request_id)
        end
        return nil
    end
    return request_result
end

function M.submit()
    local new_text = vim.api.nvim_buf_get_lines(M.buf, 0, 1, false)[1]
    local mode = vim.api.nvim_get_mode().mode;
    if mode == "i" then
        vim.cmd.stopinsert()
    end

    -- do a sync request to avoid flicker when deleting extmarks
    local params = {
        textDocument = M.pos_params.textDocument,
        position = M.pos_params.position,
        newName = new_text,
    }
    local resp = lsp_request_sync(M.client, lsp_methods.textDocument_rename, params, request_timeout, M.doc_buf)
    if resp then
        local handler = M.client.handlers[lsp_methods.textDocument_rename]
            or vim.lsp.handlers[lsp_methods.textDocument_rename]
        handler(resp.err, resp.result, resp.context, resp.config)
    end

    M.hide()
end

function M.hide()
    vim.wo[M.doc_win].conceallevel = M.prev_conceallevel
    vim.api.nvim_buf_clear_namespace(M.doc_buf, extmark_ns, 0, -1)

    if M.win and vim.api.nvim_win_is_valid(M.win) then
        vim.api.nvim_win_close(M.win, false)
    end
    M.win = nil

    if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
        vim.api.nvim_buf_delete(M.buf, {})
    end
    M.buf = nil

    M.editing_ranges = nil
end

return M
