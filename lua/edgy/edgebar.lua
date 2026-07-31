local Config = require("edgy.config")
local Editor = require("edgy.editor")
local Util = require("edgy.util")
local View = require("edgy.view")

---@class Edgy.Edgebar.Opts
---@field views (Edgy.View.Opts|string)[]
---@field size? number
---@field wo? vim.wo

local wincmds = {
  bottom = "J",
  top = "K",
  right = "L",
  left = "H",
}

---@class Edgy.Edgebar
---@field pos Edgy.Pos
---@field views Edgy.View[]
---@field wins Edgy.Window[]
---@field size integer|fun():integer
---@field default_size integer|fun():integer
---@field vertical boolean
---@field wo? vim.wo
---@field dirty boolean
---@field visible number
---@field stop boolean
---@field bounds {width:number, height:number}
local M = {}
M.__index = M

---@class Edgy.Size
---@field width? number
---@field height? number

---@param size number | fun(): number
---@param max number
function M.size(size, max)
  if type(size) == "function" then
    size = size()
  end
  return math.max(size < 1 and math.floor(max * size) or size, 1)
end

---@param pos Edgy.Pos
---@param opts Edgy.Edgebar.Opts
---@return Edgy.Edgebar
function M.new(pos, opts)
  local vertical = pos == "left" or pos == "right"
  local self = setmetatable({}, M)
  self.pos = pos
  self.views = {}
  self.size = opts.size or vertical and 30 or 10
  self.default_size = self.size
  self.vertical = vertical
  self.wins = {}
  self.visible = 0
  self.wo = opts.wo
  self.dirty = true
  self.bounds = { width = 0, height = 0 }
  for _, v in ipairs(opts.views) do
    v = type(v) == "string" and { ft = v } or v
    ---@cast v Edgy.View.Opts
    table.insert(self.views, View.new(v, self))
  end
  self:on_win_enter()
  return self
end

function M:on_win_enter()
  vim.api.nvim_create_autocmd("WinEnter", {
    group = vim.api.nvim_create_augroup("edgy_edgebar_" .. self.pos, { clear = true }),
    callback = function()
      vim.schedule(function()
        local win = vim.api.nvim_get_current_win()
        for _, w in ipairs(self.wins) do
          if w.win == win then
            if not w.visible then
              w:show()
            end
            break
          end
        end
      end)
    end,
  })
end

---@param win Edgy.Window
function M:on_hide(win)
  if not win:is_valid() or vim.api.nvim_get_current_win() == win.win then
    Editor:goto_main()
  end
  local visible = 0
  local pinned = 0
  local real = {}
  for _, w in ipairs(self.wins) do
    if w:is_valid() then
      visible = visible + (w.visible and 1 or 0)
      if w:is_pinned() then
        pinned = pinned + 1
      else
        table.insert(real, w)
      end
    end
  end

  if visible > 0 then
    return
  end
  if #real == 0 then
    return self:close()
  end

  if visible == 0 and require("edgy.config").close_when_all_hidden then
    return self:close()
  end

  table.sort(real, function(a, b)
    local da = a == win and math.huge or math.abs(a.idx - win.idx)
    local db = b == win and math.huge or math.abs(b.idx - win.idx)
    return da < db or da == db and a.idx < b.idx
  end)
  real[1]:show()
end

function M.__tostring(self)
  local lines = { "Edgy.Edgebar(" .. self.pos .. ")" }
  for _, view in ipairs(self.views) do
    for _, l in ipairs(vim.split(tostring(view), "\n")) do
      table.insert(lines, "  " .. l)
    end
  end
  return table.concat(lines, "\n")
end

---@param wins table<string, number[]>
---@return boolean updated if the edgebar was updated
function M:update(wins)
  local before = tostring(self)

  self.visible = 0
  local current = {} ---@type table<Edgy.View, Edgy.Window[]>
  for _, view in ipairs(self.views) do
    current[view] = view.wins
    view:update(wins[view.ft] or {})
    self.visible = self.visible + #view.wins
    wins[view.ft] = vim.tbl_filter(function(w)
      for _, win in ipairs(view.wins) do
        if win.win == w then
          return false
        end
      end
      return true
    end, wins[view.ft] or {})
  end
  self:_update({ check = true })

  -- check if the layout changed
  for _, view in ipairs(self.views) do
    if not vim.deep_equal(current[view], view.wins) then
      -- dd(view.get_title(), vim.tbl_map(tostring, view.wins), vim.tbl_map(tostring, current[view]))
      -- vim.notify(before .. "\n---\n" .. tostring(self))
      return true
    end
  end
  return false
end

---@param opts? {check: boolean}
function M:_update(opts)
  self.wins = {}
  for _, view in ipairs(self.views) do
    view:layout(opts)
    for _, win in ipairs(view.wins) do
      table.insert(self.wins, win)
      win.idx = #self.wins
    end
  end
end

function M:layout()
  -- HACK: don't layout when the command-line window is active
  if vim.fn.getcmdwintype() ~= "" then
    return
  end

  if self.stop then
    return
  end
  if vim.v.exiting ~= vim.NIL then
    return
  end
  if not (self.dirty or #self.wins > 0) then
    return
  end
  if self.dirty then
    self:_update()
  end

  self.dirty = true
  ---@type number?
  local last
  for _, w in ipairs(self.wins) do
    -- move first window to the edgebar position
    -- and make floating windows normal windows
    if not last or vim.api.nvim_win_get_config(w.win).relative ~= "" then
      vim.api.nvim_win_call(w.win, function()
        vim.cmd("wincmd " .. wincmds[self.pos])
      end)
    end
    -- move other windows to the end of the edgebar
    if last then
      local ok, err = pcall(vim.fn.win_splitmove, w.win, last, { vertical = not self.vertical, rightbelow = true })
      if not ok then
        error("Edgy: Failed to layout windows.\n" .. err .. "\n" .. vim.inspect({
          win = vim.bo[vim.api.nvim_win_get_buf(w.win)].ft,
          last = vim.bo[vim.api.nvim_win_get_buf(last)].ft,
        }))
      end
    end
    last = w.win
  end
  self.dirty = false
end

local size_getter = {
  width = vim.api.nvim_win_get_width,
  height = vim.api.nvim_win_get_height,
}

-- Detect windows whose size was changed by a mouse drag since the last
-- resize pass, and persist that as a manual override instead of snapping
-- it back to the computed target. `skip` is true when the change can't be
-- trusted: mid-relayout (positions not settled yet), an animation is
-- running, or -- most importantly -- no mouse drag was actually observed
-- (see lua/edgy/mouse.lua), since Nvim's WinResized fires identically
-- whether a window was resized by the user or by anything else (Vim's own
-- rebalancing, another plugin opening/closing windows, a terminal
-- resize).
---@param skip boolean
function M:detect_external_resize(skip)
  if not (Config.mouse_resize and Config.mouse_resize.enabled) then
    return
  end
  if skip or require("edgy.animate").is_active() then
    return
  end
  if #self.wins == 0 then
    return
  end

  local long = self.vertical and "height" or "width"
  local short = self.vertical and "width" or "height"

  ---@param win Edgy.Window
  local function eligible(win)
    -- terminal buffers are not excluded: a terminal's PTY reacts to the
    -- window size, it never drives it, so there is no extra size-churn
    -- risk here compared to any other buffer
    return win.visible
      and win:is_valid()
      and not win:is_pinned()
      and vim.api.nvim_win_get_config(win.win).relative == ""
  end

  ---@type Edgy.Window[]
  local eligible_wins = {}

  for _, win in ipairs(self.wins) do
    if eligible(win) then
      eligible_wins[#eligible_wins + 1] = win
      if win[long] ~= nil then
        local actual = size_getter[long](win.win)
        if actual ~= win[long] then
          vim.w[win.win]["edgy_" .. long] = actual
          -- also persist on the view itself (not just the window): a
          -- `vim.w` override dies with the window it's attached to, so
          -- without this, closing and reopening the view (a new window)
          -- would forget a resize that shrank it below the configured
          -- size, since only growing past it could still win via
          -- Edgebar:resize()'s math.max() against the original config
          win.view.size[long] = actual
        end
      end
    end
  end

  -- border between the edgebar and the main editor: only persist when
  -- `size` is a plain number, since a user-supplied function must keep
  -- being recomputed on its own terms. All windows in the bar share this
  -- dimension; sample it from the first eligible window, so
  -- pinned/floating windows never influence it.
  if type(self.size) == "number" and eligible_wins[1] then
    local actual = size_getter[short](eligible_wins[1].win)
    if actual ~= self.bounds[short] then
      self.size = actual
      -- a per-view `size` acts as a floor via math.max() in Edgebar:resize(),
      -- which would otherwise silently clamp the drag back up; override it
      -- on every eligible window (and its view, so it survives that
      -- window being closed and reopened) so the explicit resize wins
      for _, win in ipairs(eligible_wins) do
        vim.w[win.win]["edgy_" .. short] = actual
        win.view.size[short] = actual
      end
    end
  end
end

function M:resize()
  if #self.wins == 0 then
    return
  end

  -- always override these options before resizing
  vim.o.winminheight = 0
  vim.o.winminwidth = 1

  local long = self.vertical and "height" or "width"
  local short = self.vertical and "width" or "height"

  self.bounds = {
    width = self.vertical and M.size(self.size, vim.o.columns) or 0,
    height = self.vertical and 0 or M.size(self.size, vim.o.lines),
  }

  -- calculate the edgebar bounds
  for _, win in ipairs(self.wins) do
    if win.visible then
      local size = M.size(win:dim(short) or 0, self.vertical and vim.o.columns or vim.o.lines)
      self.bounds[short] = math.max(self.bounds[short], size)
    end
    local size = self.vertical and vim.api.nvim_win_get_height(win.win) or vim.api.nvim_win_get_width(win.win)
    self.bounds[long] = self.bounds[long] + size
  end

  -- views with auto-sized windows
  local auto = {} ---@type Edgy.Window[]

  -- views with fixed-sized windows
  local fixed = {} ---@type Edgy.Window[]

  local hidden_size = self.vertical and (vim.o.laststatus == 1 or vim.o.laststatus == 2) and 2 or 1

  -- calculate window sizes
  local free = self.bounds[long]
  for _, win in ipairs(self.wins) do
    win[short] = self.bounds[short]
    win[long] = hidden_size
    -- fixed-sized windows
    local dim = win:dim(long)
    if win.visible and dim then
      win[long] = M.size(dim, self.bounds[long])
      fixed[#fixed + 1] = win
    -- auto-sized windows
    elseif win.visible then
      auto[#auto + 1] = win
    -- hidden windows
    elseif self.vertical then
      win[long] = 1
    else
      local title_width = vim.fn.strdisplaywidth(win.view.get_title())
      -- if vim.api.nvim_eval_statusline then
      --   title_width = vim.api.nvim_eval_statusline(win.view.get_title(), {
      --     use_winbar = true,
      --     winid = win.win,
      --   }).width
      -- end
      win[long] = title_width + 3
    end
    free = free - win[long]
  end

  -- distribute free space to auto-sized windows,
  -- or fixed-sized windows when there are no auto-sized windows
  local subtract = free < 0
  if subtract then
    free = math.abs(free)
  end
  if free > 0 then
    local _wins = #auto > 0 and auto or #fixed > 0 and fixed or self.wins
    local extra = math.ceil(free / #_wins)
    for _, win in ipairs(_wins) do
      win[long] = win[long] + (subtract and -1 or 1) * math.min(extra, free)
      free = math.max(free - extra, 0)
    end
  end

  for _, win in ipairs(self.wins) do
    if win:needs_resize() then
      return true
    end
  end
end

function M:open()
  for _, view in ipairs(self.views) do
    if view.pinned and (#view.wins == 0 or view.wins[1]:is_pinned()) then
      view:open_pinned()
    end
  end
end

function M:equalize()
  self.size = self.default_size
  for _, view in ipairs(self.views) do
    view.size = vim.deepcopy(view.default_size)
  end
  for _, win in ipairs(self.wins) do
    vim.w[win.win].edgy_width = nil
    vim.w[win.win].edgy_height = nil
  end
  require("edgy.layout").update()
end

function M:close()
  for _, win in ipairs(self.wins) do
    pcall(vim.api.nvim_win_close, win.win, true)
  end
end

M.close = Util.noautocmd(M.close)

return M
