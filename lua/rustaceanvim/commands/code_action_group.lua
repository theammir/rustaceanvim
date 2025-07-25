local M = {}

local ui = require('rustaceanvim.ui')
local config = require('rustaceanvim.config.internal')
local _M = {}

local confirm_keys = config.tools.code_actions.keys.confirm
local quit_keys = config.tools.code_actions.keys.quit
confirm_keys = type(confirm_keys) == 'table' and confirm_keys or { confirm_keys }
quit_keys = type(quit_keys) == 'table' and quit_keys or { quit_keys }

---@class rustaceanvim.RACodeAction
---@field kind string
---@field group? string
---@field edit? table
---@field command? { command: string } | string
---@field idx? integer

---@class rustaceanvim.RACommand
---@field title string
---@field group? string
---@field command string
---@field arguments? any[]
---@field idx? integer

---@param action rustaceanvim.RACodeAction | rustaceanvim.RACommand
---@param client vim.lsp.Client
---@param ctx lsp.HandlerContext
function _M.apply_action(action, client, ctx)
  if action.edit then
    vim.lsp.util.apply_workspace_edit(action.edit, client.offset_encoding or 'utf-8')
  end
  if action.command then
    local command = type(action.command) == 'table' and action.command or action
    local fn = vim.lsp.commands[command.command]
    if fn then
      fn(command, ctx)
    end
  end
end

---@class rustaceanvim.CodeActionItem
---@field action rustaceanvim.RACodeAction|rustaceanvim.RACommand
---@field ctx lsp.HandlerContext

---@param action_item rustaceanvim.CodeActionItem | nil
function _M.on_user_choice(action_item)
  if not action_item then
    return
  end
  local ctx = action_item.ctx
  local client = vim.lsp.get_client_by_id(ctx.client_id)
  local action = action_item.action
  local code_action_provider = client and client.server_capabilities.codeActionProvider
  if not client then
    return
  end
  if not action.edit and type(code_action_provider) == 'table' and code_action_provider.resolveProvider then
    client:request('codeAction/resolve', action, function(err, resolved_action)
      ---@cast resolved_action rustaceanvim.RACodeAction|rustaceanvim.RACommand
      if err then
        vim.notify(err.code .. ': ' .. err.message, vim.log.levels.ERROR)
        return
      end
      _M.apply_action(resolved_action, client, ctx)
    end, 0)
  else
    _M.apply_action(action, client, ctx)
  end
end

---@class rustaceanvim.CodeActionWindowGeometry
---@field width integer

---@param action_items rustaceanvim.CodeActionItem[]
---@param is_group boolean
---@return rustaceanvim.CodeActionWindowGeometry
local function compute_width(action_items, is_group)
  local width = 0

  for _, value in pairs(action_items) do
    local action = value.action
    local text = action.title

    if is_group and action.group then
      text = action.group .. config.tools.code_actions.group_icon
    end
    local len = string.len(text)
    if len > width then
      width = len
    end
  end

  return { width = width + 5 }
end

local function on_primary_enter_press()
  if _M.state.secondary.winnr then
    vim.api.nvim_set_current_win(_M.state.secondary.winnr)
    return
  end

  local line = vim.api.nvim_win_get_cursor(_M.state.secondary.winnr or 0)[1]

  for _, value in ipairs(_M.state.actions.ungrouped) do
    if value.action.idx == line then
      _M.on_user_choice(value)
    end
  end

  _M.cleanup()
end

local function on_primary_quit()
  _M.cleanup()
end

---@class rustaceanvim.RACodeActionResult
---@field result? rustaceanvim.RACodeAction[] | rustaceanvim.RACommand[]

---@param results { [number]: rustaceanvim.RACodeActionResult }
---@param ctx lsp.HandlerContext
local function on_code_action_results(results, ctx)
  local cur_win = vim.api.nvim_get_current_win()

  ---@type rustaceanvim.CodeActionItem[]
  local action_items = {}
  for _, result in pairs(results) do
    for _, action in ipairs(result.result or {}) do
      table.insert(action_items, { action = action, ctx = ctx })
    end
  end
  if #action_items == 0 then
    vim.notify('No code actions available', vim.log.levels.INFO)
    return
  end

  _M.state.primary.geometry = compute_width(action_items, true)
  ---@alias grouped_actions_tbl { actions: rustaceanvim.CodeActionItem[], idx: integer | nil }
  ---@class rustaceanvim.PartitionedActions
  _M.state.actions = {
    ---@type table<string, grouped_actions_tbl>
    grouped = {},
    ---@type rustaceanvim.CodeActionItem[]
    ungrouped = {},
  }

  for _, value in ipairs(action_items) do
    local action = value.action
    -- Some clippy lints may have newlines in them
    action.title = string.gsub(action.title, '[\n\r]+', ' ')
    if action.group then
      if not _M.state.actions.grouped[action.group] then
        _M.state.actions.grouped[action.group] = { actions = {}, idx = nil }
      end
      table.insert(_M.state.actions.grouped[action.group].actions, value)
    else
      table.insert(_M.state.actions.ungrouped, value)
    end
  end

  if vim.tbl_count(_M.state.actions.grouped) == 0 and config.tools.code_actions.ui_select_fallback then
    ---@param item rustaceanvim.CodeActionItem
    local function format_item(item)
      local title = item.action.title:gsub('\r\n', '\\r\\n')
      return title:gsub('\n', '\\n')
    end
    local select_opts = {
      prompt = 'Code actions:',
      kind = 'codeaction',
      format_item = format_item,
    }
    vim.ui.select(_M.state.actions.ungrouped, select_opts, _M.on_user_choice)
    return
  end

  _M.state.primary.bufnr = vim.api.nvim_create_buf(false, true)
  local primary_winnr = vim.api.nvim_open_win(_M.state.primary.bufnr, true, {
    relative = 'cursor',
    width = _M.state.primary.geometry.width,
    height = vim.tbl_count(_M.state.actions.grouped) + vim.tbl_count(_M.state.actions.ungrouped),
    focusable = true,
    border = config.tools.float_win_config.border,
    row = 1,
    col = 0,
  })
  vim.wo[primary_winnr].signcolumn = 'no'
  vim.wo[primary_winnr].foldcolumn = '0'
  _M.state.primary.winnr = primary_winnr

  local idx = 1
  for key, value in pairs(_M.state.actions.grouped) do
    value.idx = idx
    vim.api.nvim_buf_set_lines(_M.state.primary.bufnr, -1, -1, false, { key .. config.tools.code_actions.group_icon })
    idx = idx + 1
  end

  for _, value in pairs(_M.state.actions.ungrouped) do
    local action = value.action
    action.idx = idx
    vim.api.nvim_buf_set_lines(_M.state.primary.bufnr, -1, -1, false, { action.title })
    idx = idx + 1
  end

  vim.api.nvim_buf_set_lines(_M.state.primary.bufnr, 0, 1, false, {})

  vim.iter(confirm_keys):each(function(key)
    vim.keymap.set('n', key, on_primary_enter_press, { buffer = _M.state.primary.bufnr, noremap = true, silent = true })
  end)
  vim.iter(quit_keys):each(function(key)
    vim.keymap.set('n', key, on_primary_quit, { buffer = _M.state.primary.bufnr, noremap = true, silent = true })
  end)

  _M.codeactionify_window_buffer(_M.state.primary.winnr, _M.state.primary.bufnr)

  vim.api.nvim_buf_attach(_M.state.primary.bufnr, false, {
    on_detach = function(_, _)
      _M.state.primary.clear()
      vim.schedule(function()
        _M.cleanup()
        pcall(vim.api.nvim_set_current_win, cur_win)
      end)
    end,
  })

  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = _M.state.primary.bufnr,
    callback = _M.on_cursor_move,
  })

  vim.cmd.redraw()
end

function _M.codeactionify_window_buffer(winnr, bufnr)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].bufhidden = 'delete'
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].ft = 'markdown'

  vim.wo[winnr].nu = true
  vim.wo[winnr].rnu = false
  vim.wo[winnr].cul = true
end

local function on_secondary_enter_press()
  local line = vim.api.nvim_win_get_cursor(_M.state.secondary.winnr)[1]
  ---@type grouped_actions_tbl | nil
  local active_group = nil

  for _, value in pairs(_M.state.actions.grouped) do
    if value.idx == _M.state.active_group_index then
      active_group = value
      break
    end
  end

  if active_group then
    for _, value in pairs(active_group.actions) do
      if value.action.idx == line then
        _M.on_user_choice(value)
      end
    end
  end

  _M.cleanup()
end

local function on_secondary_quit()
  local winnr = _M.state.secondary.winnr
  -- we clear first because if we close the window first, the cursor moved
  -- autocmd of the first buffer gets called which then sees that
  -- M.state.secondary.winnr exists (when it shouldnt because it is closed)
  -- and errors out
  _M.state.secondary.clear()

  ui.close_win(winnr)
end

function _M.cleanup()
  if _M.state.primary.winnr then
    ui.close_win(_M.state.primary.winnr)
    _M.state.primary.clear()
  end

  if _M.state.secondary.winnr then
    ui.close_win(_M.state.secondary.winnr)
    _M.state.secondary.clear()
  end

  ---@diagnostic disable-next-line missing-fields
  _M.state.actions = {}
  _M.state.active_group_index = nil
end

function _M.on_cursor_move()
  local line = vim.api.nvim_win_get_cursor(_M.state.primary.winnr)[1]

  for _, value in pairs(_M.state.actions.grouped) do
    if value.idx == line then
      _M.state.active_group_index = line

      if _M.state.secondary.winnr then
        ui.close_win(_M.state.secondary.winnr)
        _M.state.secondary.clear()
      end

      _M.state.secondary.geometry = compute_width(value.actions, false)

      _M.state.secondary.bufnr = vim.api.nvim_create_buf(false, true)
      local secondary_winnr = vim.api.nvim_open_win(_M.state.secondary.bufnr, false, {
        relative = 'win',
        win = _M.state.primary.winnr,
        width = _M.state.secondary.geometry.width,
        height = #value.actions,
        focusable = true,
        border = config.tools.float_win_config.border,
        row = line - 2,
        col = _M.state.primary.geometry.width + 1,
      })
      _M.state.secondary.winnr = secondary_winnr
      vim.wo[secondary_winnr].signcolumn = 'no'

      local idx = 1
      for _, inner_value in pairs(value.actions) do
        local action = inner_value.action
        action.idx = idx
        vim.api.nvim_buf_set_lines(_M.state.secondary.bufnr, -1, -1, false, { action.title })
        idx = idx + 1
      end

      vim.api.nvim_buf_set_lines(_M.state.secondary.bufnr, 0, 1, false, {})

      _M.codeactionify_window_buffer(_M.state.secondary.winnr, _M.state.secondary.bufnr)
      vim.iter(confirm_keys):each(function(key)
        vim.keymap.set('n', key, on_secondary_enter_press, { buffer = _M.state.secondary.bufnr })
      end)
      vim.iter(quit_keys):each(function(key)
        vim.keymap.set('n', key, on_secondary_quit, { buffer = _M.state.secondary.bufnr })
      end)

      return
    end

    if _M.state.secondary.winnr then
      ui.close_win(_M.state.secondary.winnr)
      _M.state.secondary.clear()
    end
  end
end

---@class rustaceanvim.CodeActionWindowState
---@field bufnr integer | nil
---@field winnr integer | nil
---@field geometry rustaceanvim.CodeActionWindowGeometry | nil
---@field clear fun()

---@class rustaceanvim.CodeActionInternalState
_M.state = {
  ---@type rustaceanvim.PartitionedActions
  actions = {
    ---@type grouped_actions_tbl[]
    grouped = {},
    ---@type rustaceanvim.CodeActionItem[]
    ungrouped = {},
  },
  ---@type number | nil
  active_group_index = nil,
  ---@type rustaceanvim.CodeActionWindowState
  primary = {
    bufnr = nil,
    winnr = nil,
    geometry = nil,
    clear = function()
      _M.state.primary.geometry = nil
      _M.state.primary.bufnr = nil
      _M.state.primary.winnr = nil
    end,
  },
  ---@type rustaceanvim.CodeActionWindowState
  secondary = {
    bufnr = nil,
    winnr = nil,
    geometry = nil,
    clear = function()
      _M.state.secondary.geometry = nil
      _M.state.secondary.bufnr = nil
      _M.state.secondary.winnr = nil
    end,
  },
}

---@param make_range_params fun(bufnr: integer, offset_encoding: string):{ range: table }
_M.code_action_group = function(make_range_params)
  local context = {
    diagnostics = vim.lsp.diagnostic.from(vim.diagnostic.get(0, {
      lnum = vim.api.nvim_win_get_cursor(0)[1] - 1,
    })),
  }
  local clients = vim.lsp.get_clients { bufnr = 0 }
  if #clients == 0 then
    return
  end

  local params = make_range_params(0, clients[1].offset_encoding)

  ---@diagnostic disable-next-line: inject-field
  params.context = context

  vim.lsp.buf_request_all(0, 'textDocument/codeAction', params, function(results, ctx)
    on_code_action_results(results, ctx)
  end)
end

function M.code_action_group()
  _M.code_action_group(vim.lsp.util.make_range_params)
end

function M.code_action_group_visual()
  _M.code_action_group(function(winnr, offset_encoding)
    return vim.lsp.util.make_given_range_params(nil, nil, winnr, offset_encoding or 'utf-8')
  end)
end

return M
