local M = {}

local uv = vim.uv or vim.loop

-- How long a detected size change stays trusted as "caused by a mouse
-- drag" after the drag/release key was seen. Needed because the
-- WinResized reporting the final size can arrive a little after
-- <LeftRelease>, not necessarily on the exact same event-loop tick.
local DRAG_BUFFER_MS = 300

---@type table<string, boolean>
local drag_keys = {
  ["<LeftMouse>"] = true,
  ["<LeftDrag>"] = true,
  ["<LeftRelease>"] = true,
}

local drag_until = 0
local registered = false

-- Whether a mouse-drag key was seen recently enough that a window-size
-- change happening right now can plausibly be attributed to it.
function M.is_dragging()
  return uv.now() < drag_until
end

---@param key string raw key bytes, as received from vim.on_key()
local function on_key(key)
  if key == "" then
    return
  end
  local ok, name = pcall(vim.fn.keytrans, key)
  if ok and drag_keys[name] then
    drag_until = uv.now() + DRAG_BUFFER_MS
  end
end

-- Exposed for tests: feeds a raw key straight into the same detection
-- path vim.on_key() uses, without needing a real mouse-capable terminal.
M._on_key = on_key

function M.setup()
  if registered then
    return
  end
  registered = true
  vim.on_key(function(_, typed)
    on_key(typed or "")
  end, vim.api.nvim_create_namespace("edgy_mouse_resize"))
end

return M
