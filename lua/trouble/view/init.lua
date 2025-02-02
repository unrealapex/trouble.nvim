local Main = require("trouble.view.main")
local Preview = require("trouble.view.preview")
local Render = require("trouble.view.render")
local Section = require("trouble.view.section")
local Spec = require("trouble.spec")
local Text = require("trouble.view.text")
local Util = require("trouble.util")
local Window = require("trouble.view.window")

---@class trouble.View
---@field win trouble.Window
---@field preview_win? trouble.Window
---@field opts trouble.Mode
---@field sections trouble.Section[]
---@field renderer trouble.Render
---@field first_render? boolean
---@field moving uv_timer_t
---@field opening? boolean
---@field state table<string,any>
---@field _waiting (fun())[]
---@field private _main? trouble.Main
local M = {}
M.__index = M
local _idx = 0
---@type table<trouble.View, number>
M._views = setmetatable({}, { __mode = "k" })

---@type table<string, trouble.Render.Location>
M._last = {}

M.MOVING_DELAY = 4000

---@param opts trouble.Mode
function M.new(opts)
  local self = setmetatable({}, M)
  _idx = _idx + 1
  M._views[self] = _idx
  self.state = {}
  self.opts = opts or {}
  self._waiting = {}
  self.first_render = true
  self.opts.win = self.opts.win or {}
  self.opts.win.on_mount = function()
    self:on_mount()
  end
  self.opts.win.on_close = function()
    M._last[self.opts.mode or ""] = self:at()
  end

  self.sections = {}
  for _, s in ipairs(Spec.sections(self.opts)) do
    local section = Section.new(s, self.opts)
    section.on_update = function()
      self:update()
    end
    table.insert(self.sections, section)
  end

  self.win = Window.new(self.opts.win)
  self.opts.win = self.win.opts

  self.preview_win = Window.new(self.opts.preview) or nil

  self.renderer = Render.new(self.opts, {
    padding = vim.tbl_get(self.opts.win, "padding", "left") or 0,
    multiline = self.opts.multiline,
  })
  self.update = Util.throttle(M.update, Util.throttle_opts(self.opts.throttle.update, { ms = 10 }))
  self.render = Util.throttle(M.render, Util.throttle_opts(self.opts.throttle.render, { ms = 10 }))
  self.follow = Util.throttle(M.follow, Util.throttle_opts(self.opts.throttle.follow, { ms = 100 }))

  if self.opts.auto_open then
    self:listen()
    self:refresh()
  end
  self.moving = vim.uv.new_timer()
  return self
end

---@alias trouble.View.filter {debug?: boolean, open?:boolean, mode?: string}

---@param filter? trouble.View.filter
function M.get(filter)
  filter = filter or {}
  ---@type {idx:number, mode?: string, view: trouble.View, is_open: boolean}[]
  local ret = {}
  for view, idx in pairs(M._views) do
    local is_open = view.win:valid()
    local ok = is_open or view.opts.auto_open or view.opening
    ok = ok and (not filter.mode or filter.mode == view.opts.mode)
    ok = ok and (not filter.open or is_open)
    if ok then
      ret[#ret + 1] = {
        idx = idx,
        mode = view.opts.mode,
        view = not filter.debug and view or {},
        is_open = is_open,
      }
    end
  end
  table.sort(ret, function(a, b)
    return a.idx < b.idx
  end)
  return ret
end

---@param filter trouble.Filter
function M:filter(filter)
  for _, section in ipairs(self.sections) do
    section.filter = filter
  end
  self:refresh()
end

function M:on_mount()
  vim.w[self.win.win].trouble = {
    mode = self.opts.mode,
    type = self.opts.win.type,
    relative = self.opts.win.relative,
    position = self.opts.win.position,
  }

  self:listen()
  self.win:on("WinLeave", function()
    Preview.close()
  end)

  local _self = Util.weak(self)

  local preview = Util.throttle(
    M.preview,
    Util.throttle_opts(self.opts.throttle.preview, {
      ms = 100,
      debounce = true,
    })
  )

  self.win:on("CursorMoved", function()
    local this = _self()
    if not this then
      return true
    end
    M._last[self.opts.mode or ""] = self:at()
    if this.opts.auto_preview then
      local loc = this:at()
      if loc and loc.item then
        preview(this, loc.item)
      end
    end
  end)

  if self.opts.follow then
    -- tracking of the current item
    self.win:on("CursorMoved", function()
      local this = _self()
      if not this then
        return true
      end
      if this.win:valid() then
        this:follow()
      end
    end, { buffer = false })
  end

  self.win:on("OptionSet", function()
    local this = _self()
    if not this then
      return true
    end
    if this.win:valid() then
      local foldlevel = vim.wo[this.win.win].foldlevel
      if foldlevel ~= this.renderer.foldlevel then
        this:fold_level({ level = foldlevel })
      end
    end
  end, { pattern = "foldlevel", buffer = false })

  for k, v in pairs(self.opts.keys) do
    self:map(k, v)
  end

  self.opening = false
end

---@param node? trouble.Node
---@param opts? trouble.Render.fold_opts
function M:fold(node, opts)
  node = node or self:at().node
  if node then
    self.renderer:fold(node, opts)
    self:render()
  end
end

---@param opts {level?:number, add?:number}
function M:fold_level(opts)
  self.renderer:fold_level(opts)
  self:render()
end

---@param item? trouble.Item
---@param opts? {split?: boolean, vsplit?:boolean}
function M:jump(item, opts)
  opts = opts or {}
  item = item or self:at().item
  Preview.close()
  if not item then
    return Util.warn("No item to jump to")
  end

  if not (item.buf or item.filename) then
    Util.warn("No buffer or filename for item")
    return
  end

  item.buf = item.buf or vim.fn.bufadd(item.filename)

  if not vim.api.nvim_buf_is_loaded(item.buf) then
    vim.fn.bufload(item.buf)
  end
  if not vim.bo[item.buf].buflisted then
    vim.bo[item.buf].buflisted = true
  end
  local main = self:main()
  local win = main and main.win or 0

  vim.api.nvim_win_call(win, function()
    -- save position in jump list
    vim.cmd("normal! m'")
  end)

  if opts.split then
    vim.api.nvim_win_call(win, function()
      vim.cmd("split")
      win = vim.api.nvim_get_current_win()
    end)
  elseif opts.vsplit then
    vim.api.nvim_win_call(win, function()
      vim.cmd("vsplit")
      win = vim.api.nvim_get_current_win()
    end)
  end

  vim.api.nvim_win_set_buf(win, item.buf)
  -- order of the below seems important with splitkeep=screen
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, item.pos)
  vim.api.nvim_win_call(win, function()
    vim.cmd("norm! zzzv")
  end)
  return item
end

function M:wait(fn)
  if self.opening then
    table.insert(self._waiting, fn)
  else
    fn()
  end
end

---@param item? trouble.Item
function M:preview(item)
  item = item or self:at().item
  if not item then
    return Util.warn("No item to preview")
  end

  return Preview.open(self, item, { scratch = self.opts.preview.scratch })
end

function M:main()
  self._main = Main.get(self.opts.pinned and self._main or nil)
  return self._main
end

function M:goto_main()
  local main = self:main()
  if main then
    vim.api.nvim_set_current_win(main.win)
  end
end

function M:listen()
  local _self = Util.weak(self)
  self:main()

  for _, section in ipairs(self.sections) do
    section:listen()
  end
end

---@param cursor? number[]
function M:at(cursor)
  if not vim.api.nvim_buf_is_valid(self.win.buf) then
    return {}
  end
  cursor = cursor or vim.api.nvim_win_get_cursor(self.win.win)
  return self.renderer:at(cursor[1])
end

---@param key string
---@param action trouble.Action|string
function M:map(key, action)
  local desc ---@type string?
  if type(action) == "string" then
    desc = action:gsub("_", " ")
    action = require("trouble.config.actions")[action]
  end
  ---@type trouble.ActionFn
  local fn
  if type(action) == "function" then
    fn = action
  else
    fn = action.action
    desc = action.desc or desc
  end
  local _self = Util.weak(self)
  self.win:map(key, function()
    local this = _self()
    if this then
      this:action(fn)
    end
  end, desc)
end

---@param opts? {idx?: number, up?:number, down?:number, jump?:boolean}
function M:move(opts)
  -- start the moving timer. Will stop any previous timers,
  -- so this acts as a debounce.
  -- This is needed to prevent `follow` from being called
  self.moving:start(M.MOVING_DELAY, 0, function() end)

  opts = opts or {}
  local cursor = vim.api.nvim_win_get_cursor(self.win.win)
  local from = 1
  local to = vim.api.nvim_buf_line_count(self.win.buf)
  local todo = opts.idx or opts.up or opts.down or 0

  if opts.idx and opts.idx < 0 then
    from, to = to, 1
    todo = math.abs(todo)
  elseif opts.down then
    from = cursor[1] + 1
  elseif opts.up then
    from = cursor[1] - 1
    to = 1
  end

  for row = from, to, from > to and -1 or 1 do
    local info = self.renderer:at(row)
    if info.item and info.first_line then
      todo = todo - 1
      if todo == 0 then
        vim.api.nvim_win_set_cursor(self.win.win, { row, cursor[2] })
        if opts.jump then
          self:jump(info.item)
        end
        break
      end
    end
  end
end

---@param action trouble.Action
---@param opts? table
function M:action(action, opts)
  self:wait(function()
    local at = self:at() or {}
    action(self, {
      item = at.item,
      node = at.node,
      opts = type(opts) == "table" and opts or {},
    })
  end)
end

function M:refresh()
  if not (self.opening or self.win:valid() or self.opts.auto_open) then
    return
  end
  for _, section in ipairs(self.sections) do
    section:refresh()
  end
end

function M:help()
  local text = Text.new({ padding = 1 })

  text:nl():append("# Help ", "Title"):nl()
  text:append("Press ", "Comment"):append("<q>", "Special"):append(" to close", "Comment"):nl():nl()
  text:append("# Keymaps ", "Title"):nl():nl()
  ---@type string[]
  local keys = vim.tbl_keys(self.win.keys)
  table.sort(keys, function(a, b)
    local lowa = string.lower(a)
    local lowb = string.lower(b)
    if lowa == lowb then
      return a > b -- Preserve original order for equal strings
    else
      return lowa < lowb
    end
  end)
  for _, key in ipairs(keys) do
    local desc = self.win.keys[key]
    text:append("  - ", "@punctuation.special.markdown")
    text:append(key, "Special"):append(" "):append(desc):nl()
  end
  text:trim()

  local win = Window.new({
    type = "float",
    size = { width = text:width(), height = text:height() },
    border = "rounded",
    wo = { cursorline = false },
  })
  win:open():focus()
  text:render(win.buf)
  vim.bo[win.buf].modifiable = false

  win:map("<esc>", win.close)
  win:map("q", win.close)
end

function M:open()
  if self.win:valid() then
    return self
  end
  self.opening = true
  -- self.win:open()
  self:refresh()
  return self
end

function M:close()
  self.opening = false
  self:goto_main()
  Preview.close()
  self.win:close()
  return self
end

function M:count()
  local count = 0
  for _, section in ipairs(self.sections) do
    if section.node then
      count = count + section.node:count()
    end
  end
  return count
end

function M:flatten()
  local ret = {}
  for _, section in ipairs(self.sections) do
    section.node:flatten(ret)
  end
  return ret
end

-- called when results are updated
function M:update()
  local is_open = self.win:valid()
  self.opening = self.opening and not is_open
  local count = self:count()

  local did_first_update = true
  for _, section in ipairs(self.sections) do
    if not section.first_update then
      did_first_update = false
      break
    end
  end

  if count == 0 then
    if self.opening and not self.opts.open_no_results then
      if did_first_update and self.opts.warn_no_results then
        Util.warn("No results for **" .. self.opts.mode .. "**")
      end
      self.opening = not did_first_update
      return
    end

    if is_open and self.opts.auto_close then
      return self:close()
    end
  end

  if self.opening and did_first_update then
    if self.opts.auto_jump and count == 1 then
      self.opening = false
      self:jump(self:flatten()[1])
      return self:close()
    end
  end

  if self.opts.auto_open and not is_open and count > 0 then
    self.win:open()
    is_open = true
  end

  if self.opening then
    self.win:open()
    is_open = true
  end

  if not (self.opening or is_open) then
    return
  end

  self:render()

  while #self._waiting > 0 do
    Util.try(table.remove(self._waiting, 1))
  end
end

-- render the results
function M:render()
  if not self.win:valid() then
    return
  end

  local loc = self:at()
  local restore_loc = self.opts.restore and self.first_render and M._last[self.opts.mode or ""]
  if restore_loc then
    loc = restore_loc
    self.first_render = false
  end

  -- render sections
  self.renderer:clear()
  self.renderer:nl()
  for _ = 1, vim.tbl_get(self.opts.win, "padding", "top") or 0 do
    self.renderer:nl()
  end
  self.renderer:sections(self.sections)
  self.renderer:trim()

  -- calculate initial folds
  if self.renderer.foldlevel == nil then
    local level = vim.wo[self.win.win].foldlevel
    if level < self.renderer.max_depth then
      self.renderer:fold_level({ level = level })
      -- render again to apply folds
      return self:render()
    end
  end

  -- render extmarks and restore window view
  local view = vim.api.nvim_win_call(self.win.win, vim.fn.winsaveview)
  self.renderer:render(self.win.buf)
  vim.api.nvim_win_call(self.win.win, function()
    vim.fn.winrestview(view)
  end)

  if self.opts.follow and self:follow() then
    return
  end

  -- when window is at top, dont move cursor
  if not restore_loc and view.topline == 1 then
    return
  end

  -- fast exit when cursor is already on the right item
  local new_loc = self:at()
  if new_loc.node and loc.node and new_loc.node.id == loc.node.id then
    return
  end

  -- Move cursor to the same item
  local cursor = vim.api.nvim_win_get_cursor(self.win.win)
  local item_row ---@type number?
  if loc.node then
    for row, l in pairs(self.renderer._locations) do
      if loc.node:is(l.node) then
        item_row = row
        break
      end
    end
  end

  -- Move cursor to the actual item when found
  if item_row and item_row ~= cursor[1] then
    vim.api.nvim_win_set_cursor(self.win.win, { item_row, cursor[2] })
    return
  end
end

-- When not in the trouble window, try to show the range
function M:follow()
  if not self.win:valid() then -- trouble is closed
    return
  end
  if self.moving:is_active() then -- dont follow when moving
    return
  end
  local current_win = vim.api.nvim_get_current_win()
  if current_win == self.win.win then -- inside the trouble window
    return
  end
  local Filter = require("trouble.filter")
  local ctx = { opts = self.opts, main = self:main() }
  local fname = vim.api.nvim_buf_get_name(ctx.main.buf or 0)
  local loc = self:at()

  -- check if we're already in the file group
  local in_group = loc.node and loc.node.item and loc.node.item.filename == fname

  ---@type number[]|nil
  local cursor_item = nil
  local cursor_group = cursor_item

  for row, l in pairs(self.renderer._locations) do
    -- only return the group if we're not yet in the group
    -- and the group's filename matches the current file
    local is_group = not in_group and l.node and l.node.group and l.node.item and l.node.item.filename == fname
    if is_group then
      cursor_group = { row, 1 }
    end

    -- prefer a full match
    local is_current = l.item and Filter.is(l.item, { range = true }, ctx)
    if is_current then
      cursor_item = { row, 1 }
    end
  end

  local cursor = cursor_item or cursor_group
  if cursor then
    -- make sure the cursorline is visible
    vim.wo[self.win.win].cursorline = true
    vim.api.nvim_win_set_cursor(self.win.win, cursor)
    return true
  end
end

return M
