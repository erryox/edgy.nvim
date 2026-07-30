# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

edgy.nvim is a Neovim plugin (Lua) that manages predefined "edgebar" window
layouts (left/right/top/bottom docks), automatically moving windows into
place based on filetype, similar to IDE-style docked panels.

## Development commands

There is no build step, test suite, or package.json/Makefile in this repo — it's a plain Lua plugin loaded directly by Neovim/lazy.nvim.

- **Formatting**: [StyLua](https://github.com/JohnnyMorganz/StyLua), config in `stylua.toml` (2-space indent, 120 col width, sorted requires). Run `stylua lua/`.
- **Linting**: [Selene](https://github.com/Kampfkarren/selene), config in `selene.toml` (std = "vim"). Run `selene lua/`.
- **CI/docs/PR checks**: all handled by the reusable `folke/github` workflows referenced in `.github/workflows/*.yml` (`ci.yml`, `pr.yml`, `labeler.yml`, `update.yml`) — there's nothing project-specific to invoke locally for these.
- **No automated test suite exists** (no `tests/`/`spec/` directory). `vim.yml` declares busted-style globals (`describe`, `it`, `before_each`) for the linter's benefit, but there are currently no test files. Verify changes by manually loading the plugin in Neovim.
- Docs (`doc/edgy.nvim.txt`) are auto-generated (see recent commits "chore(build): auto-generate docs") — don't hand-edit `doc/`.

## Architecture

Core module graph (`lua/edgy/`), roughly bottom-up:

- **`config.lua`** — defaults + `setup(opts)`. Merges user opts, builds `M.layout` (a `table<Edgy.Pos, Edgy.Edgebar>` for `"left"|"right"|"top"|"bottom"`), sets highlight groups, and wires up the autocmds (`BufWinEnter`, `WinResized`, `FileType`, `VimResized`) that drive `layout.lua`'s `Layout.update`. Also exposed as the live config table via a metatable `__index`.
- **`edgebar.lua`** — one `Edgy.Edgebar` per screen edge. Owns a list of `Edgy.View`s and the flattened `Edgy.Window`s across them. `:layout()` physically moves windows into position with `wincmd` + `win_splitmove`; `:resize()` computes target width/height per window (auto vs fixed-size vs hidden) and returns whether a resize is needed; `:update(wins)` reconciles which real nvim windows belong to which view.
- **`view.lua`** — an `Edgy.View` matches windows by `ft` (+ optional `filter`). Handles pinned views: a pinned view with no real window gets a synthetic 1x1 floating "placeholder" window (`show_pinned`/`hide_pinned`) so it always renders in the edgebar and can be opened on demand (`open_pinned` calls the view's `open` string/fn).
- **`window.lua`** — wraps a real nvim window (`Edgy.Window`). Applies per-window options (`Config.wo` merged with edgebar/view overrides), renders the clickable winbar (`edgy_winbar`/`edgy_click`, driven by a `win -> Edgy.Window` weak cache `M.cache`), and implements window-local behavior: show/hide/close/toggle, `next`/`prev` sibling navigation among sibling windows in the same edgebar, and manual `resize` (stored as `vim.w[win].edgy_width/height` overrides consulted by `edgebar:resize()`).
- **`layout.lua`** — the update loop. `M.update` (wrapped with retry + `noautocmd`) is the autocmd entrypoint: classifies all windows in the tab by filetype, updates each edgebar, then does a "full" layout pass (physically repositioning windows) only if `needs_layout()` detects the real window tree doesn't match the desired one, followed by a resize pass. Resize scheduling is debounced (`Util.debounce`, 50ms) and coordinates with `state.lua` (save cursor/view state before moving windows, restore after) and `animate.lua` (animates size changes instead of snapping instantly).
- **`editor.lua`** — tab-level bookkeeping independent of specific edgebars: classifies all windows into edgy/main/floating, ensures there's always a "main" (non-edgy, non-floating) window (`check_main`, opens a scratch/most-recently-entered buffer or honors `exit_when_last`), `goto_main()`, and the public `select`/`close`/`open`/`toggle`/`equalize`/`get_win` operations re-exported by `commands.lua`.
- **`state.lua`** — preserves `winsaveview()`/`winrestview()` state across the window moves layout.lua performs (moving a window in Neovim can reset scroll position); tracks whether the window layout is "stable" to avoid interfering with unrelated splits (see the `splitkeep` upstream Vim issue referenced in comments).
- **`animate.lua`** — optional smooth resize animation (fps/cps-based tweening) used by `layout.lua` instead of snapping window sizes instantly when `animate.enabled`.
- **`actions.lua`** — installs the buffer-local keymaps from `Config.keys` onto edgebar buffers exactly once (guarded by `vim.b[buf].edgy_keys`), never overriding pre-existing user mappings.
- **`hacks.lua`** — optional FFI patch (`fix_win_height`) to `vim.api.nvim_win_set_height` for older Neovim versions where folding/height handling for edgebar windows is broken.
- **`commands.lua`** / **`init.lua`** — public API surface (`require("edgy").setup/select/close/open/toggle/goto_main/get_win`), exposed via a metatable that lazily delegates to `editor.lua`.

### Key control flow

1. Autocmds in `config.lua` fire `Layout.update()` on relevant events.
2. `layout.lua` classifies live windows by filetype and hands them to each `Edgy.Edgebar:update()`, which distributes them into matching `Edgy.View`s.
3. If the real window tree doesn't match the desired tree (`needs_layout`), `edgebar:layout()` physically relocates windows via `wincmd`/`win_splitmove`, wrapped with `state.lua` save/restore to preserve scroll position.
4. `edgebar:resize()` computes per-window target width/height (respecting manual per-window overrides in `vim.w[win].edgy_width/height`, fixed `size` from view opts, or auto-distributing remaining space) and either applies it directly or hands off to `animate.lua` for a tweened resize.
5. Pinned views without a live window get a synthetic placeholder window so they still show up (and can trigger `open()` when clicked/focused) even with no buffer open yet.

### Conventions

- Class-style modules: `local M = {}; M.__index = M`, constructed via `M.new(...)`, with `__tostring` for debug printing.
- LuaCATS/EmmyLua annotations (`---@class`, `---@field`, `---@param`) are used throughout — keep them accurate when changing signatures, since `doc/edgy.nvim.txt` and downstream tooling rely on them.
- Position strings are always one of `"left"|"right"|"top"|"bottom"` (type `Edgy.Pos`); vertical edgebars are left/right, horizontal are top/bottom.
