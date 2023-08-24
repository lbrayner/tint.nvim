local colors = require("tint.colors")
local transforms = require("tint.transforms")

local tint = { transforms = { SATURATE_TINT = "saturate_tint" } }

-- Private "namespace" for functions, etc. that might not be defined before they are used
local __ = { enabled = true }

-- Default module configuration values
__.default_config = {
  tint = -40,
  saturation = 0.7,
  transforms = nil,
  tint_background_colors = false,
  highlight_ignore_patterns = {},
  dynamic_window_ignore = false,
  window_ignore_function = nil,
  focus_change_events = {
    focus = { "WinEnter" },
    unfocus = { "WinLeave" },
  },
}

-- Pre-defined transforms that can be used by the user
__.transforms = {
  [tint.transforms.SATURATE_TINT] = function()
    return {
      transforms.saturate(__.user_config.saturation),
      transforms.tint(__.user_config.tint),
    }
  end,
}

--- Ensure the passed table has only valid keys to hand to `nvim_set_hl`
---
---@param hl_def table Value returned by `nvim_get_hl_by_name` with `rgb` colors exported
---@return table The passed highlight definition with valid `nvim_set_hl` keys only
local function ensure_valid_hl_keys(hl_def)
  return {
    fg = hl_def.fg or hl_def.foreground,
    bg = hl_def.bg or hl_def.background,
    sp = hl_def.sp or hl_def.special,
    blend = hl_def.blend,
    bold = hl_def.bold,
    standout = hl_def.standout,
    underline = hl_def.underline,
    undercurl = hl_def.undercurl,
    underdouble = hl_def.underdouble,
    underdotted = hl_def.underdotted,
    underdashed = hl_def.underdashed,
    strikethrough = hl_def.strikethrough,
    italic = hl_def.italic,
    reverse = hl_def.reverse,
    nocombine = hl_def.nocombine,
    link = hl_def.link,
    default = hl_def.default,
    ctermfg = hl_def.ctermfg,
    ctermbg = hl_def.ctermbg,
    cterm = hl_def.cterm,
  }
end

--- Get the set of transforms to apply to highlight groups from the colorscheme in question
---
---@return table A table of functions to transform the input RGB color values by
local function get_transforms()
  if type(__.user_config.transforms) == "string" and __.transforms[__.user_config.transforms] then
    return __.transforms[__.user_config.transforms]()
  elseif __.user_config.transforms then
    return __.user_config.transforms
  else
    return __.transforms[tint.transforms.SATURATE_TINT]()
  end
end

--- Determine if a window should be ignored or not, triggered on `WinLeave`
---
---@param winid number Window ID
---@return boolean Whether or not the window should be ignored for tinting
local function win_should_ignore_tint(winid)
  return __.user_config.window_ignore_function and __.user_config.window_ignore_function(winid) or false
end

--- Determine if a highlight group should be ignored or not
---
---@param hl_group_name string The name of the highlight group
---@return boolean `true` if the group should be ignored, `false` otherwise
local function hl_group_is_ignored(hl_group_name)
  for _, pat in ipairs(__.user_config.highlight_ignore_patterns) do
    if string.find(hl_group_name, pat) then
      return true
    end
  end

  return false
end

--- Create the "default" (non-tinted) highlight namespace
---
---@param hl_group_name string
---@param hl_def table The highlight definition, see `:h nvim_set_hl`
local function set_default_ns(hl_group_name, hl_def)
  vim.api.nvim_set_hl(__.default_ns, hl_group_name, hl_def)
end

--- Create the "tinted" highlight namespace
---
---@param hl_group_name string
---@param hl_def table The highlight definition, see `:h nvim_set_hl`
local function set_tint_ns(hl_group_name, hl_def)
  local ignored = hl_group_is_ignored(hl_group_name)
  local hl_group_info = { hl_group_name = hl_group_name }

  if hl_def.fg and not ignored then
    hl_def.fg = transforms.transform_color(hl_group_info, colors.get_hex(hl_def.fg), __.user_config.transforms)
  end

  if hl_def.sp and not ignored then
    hl_def.sp = transforms.transform_color(hl_group_info, colors.get_hex(hl_def.sp), __.user_config.transforms)
  end

  if __.user_config.tint_background_colors and hl_def.bg and not ignored then
    hl_def.bg = transforms.transform_color(hl_group_info, colors.get_hex(hl_def.bg), __.user_config.transforms)
  end

  vim.api.nvim_set_hl(__.tint_ns, hl_group_name, hl_def)
end

--- Backwards compatibile (for now) method of getting highlights as
--- nvim__get_hl_defs is removed in #22693
local function get_global_highlights()
  return vim.api.nvim__get_hl_defs and vim.api.nvim__get_hl_defs(0) or vim.api.nvim_get_hl(0, {})
end

--- Setup color namespaces such that they can be set per-window
local function setup_namespaces()
  if not __.default_ns and not __.tint_ns then
    __.default_ns = vim.api.nvim_create_namespace("_tint_norm")
    __.tint_ns = vim.api.nvim_create_namespace("_tint_dim")
  end

  for hl_group_name, hl_def in pairs(get_global_highlights()) do
    -- Ensure we only have valid keys copied over
    hl_def = ensure_valid_hl_keys(hl_def)
    set_default_ns(hl_group_name, hl_def)
    set_tint_ns(hl_group_name, hl_def)
  end
end

--- Create an `:h augroup` for autocommands used by this plugin
---
---@return number Identifier for created augroup
local function create_augroup()
  return vim.api.nvim_create_augroup("_tint", { clear = true })
end

--- Setup autocommands to swap (or reconfigure) tint highlight namespaces
---
--- `__.user_config.focus_change_events.focus`: Tint the window
---  `__.user_config.focus_change_events.unfocus`: Untint the window
--- `ColorScheme`: When changing colorschemes, reconfigure the tint namespaces
local function setup_autocmds()
  if __.setup_autocmds then
    return
  end

  local augroup = create_augroup()

  vim.api.nvim_create_autocmd(__.user_config.focus_change_events.focus, {
    group = augroup,
    pattern = { "*" },
    callback = __.on_focus,
  })

  vim.api.nvim_create_autocmd(__.user_config.focus_change_events.unfocus, {
    group = augroup,
    pattern = { "*" },
    callback = __.on_unfocus,
  })

  vim.api.nvim_create_autocmd({ "ColorScheme" }, {
    group = augroup,
    pattern = { "*" },
    callback = __.on_colorscheme,
  })

  __.setup_autocmds = true
end

--- Verify the version of Neovim running has `nvim_win_set_hl_ns`, added via !13457
local function verify_version()
  if not vim.api.nvim_win_set_hl_ns then
    vim.notify(
      "tint.nvim requires a newer version of Neovim that provides 'nvim_win_set_hl_ns'",
      vim.lsp.log_levels.ERROR
    )

    return false
  end

  return true
end

--- Swap old configuration keys to new ones, handle cases `tbl_extend` does not (nested config values)
---
---@param user_config table User configuration table
---@return table Modified user configuration
local function get_user_config(user_config)
  local new_config = vim.deepcopy(user_config)

  -- Copy over old configuration values here before calling `tbl_extend` later
  new_config.tint = user_config.amt or user_config.tint
  new_config.tint_background_colors = user_config.bg ~= nil and user_config.bg or user_config.tint_background_colors
  new_config.highlight_ignore_patterns = user_config.ignore or user_config.highlight_ignore_patterns
  new_config.window_ignore_function = user_config.ignorefunc or user_config.window_ignore_function

  if new_config.focus_change_events then
    new_config.focus_change_events.focus = new_config.focus_change_events.focus
      or __.default_config.focus_change_events.focus
    new_config.focus_change_events.unfocus = new_config.focus_change_events.unfocus
      or __.default_config.focus_change_events.unfocus
  end

  return new_config
end

--- Setup `__.user_config` by overriding defaults with user values
local function setup_user_config()
  __.user_config = vim.tbl_extend("force", __.default_config, get_user_config(__.user_config or {}))

  vim.validate({
    tint = { __.user_config.tint, "number" },
    saturation = { __.user_config.saturation, "number" },
    transforms = {
      __.user_config.transforms,
      function(val)
        if type(val) == "string" then
          return __.transforms[val]
        elseif type(val) == "table" then
          for _, v in ipairs(val) do
            if type(v) ~= "function" then
              return false
            end
          end

          return true
        elseif val == nil then
          return true
        end

        return false
      end,
      "'tint' passed invalid value for option 'transforms'",
    },
    tint_background_colors = { __.user_config.tint_background_colors, "boolean" },
    highlight_ignore_patterns = {
      __.user_config.highlight_ignore_patterns,
      function(val)
        for _, v in ipairs(val) do
          if type(v) ~= "string" then
            return false
          end
        end

        return true
      end,
      "'tint' passed invalid value for option 'highlight_ignore_patterns'",
    },
    dynamic_window_ignore = { __.user_config.dynamic_window_ignore, "boolean" },
    window_ignore_function = { __.user_config.window_ignore_function, "function", true },
    focus_change_events = {
      __.user_config.focus_change_events,
      function(val)
        if type(val) ~= "table" then
          return false
        end

        if not val.focus or not val.unfocus then
          return false
        end

        for _, v in ipairs(val.focus) do
          if type(v) ~= "string" then
            return false
          end
        end

        for _, v in ipairs(val.unfocus) do
          if type(v) ~= "string" then
            return false
          end
        end

        return true
      end,
      "'tint' passed invalid value for option 'focus_change_events'",
    },
  })

  __.user_config.transforms = get_transforms()
end

--- Ensure the passed function runs after `:h VimEnter` has run
---
---@param func function The function to call only after `VimEnter` is done
local function on_or_after_vimenter(func)
  if vim.v.vim_did_enter == 1 then
    func()
  else
    vim.api.nvim_create_autocmd({ "VimEnter" }, {
      callback = func,
      once = true,
    })
  end
end

--- Iterate all windows in all tabpages and call the passed function on them
---
---@param func function Function to be called with each `(winid, tabpage)` as its parameters
local function iterate_all_windows(func)
  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    if vim.api.nvim_tabpage_is_valid(tabpage) then
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
        if vim.api.nvim_win_is_valid(winid) then
          func(winid, tabpage)
        end
      end
    end
  end
end

--- Restore the global highlight namespace in all windows
local function restore_default_highlight_namespaces()
  iterate_all_windows(function(winid, _)
    vim.api.nvim_win_set_hl_ns(winid, 0)
  end)
end

--- Set the tint highlight namespace in all unfocused windows
local function set_tint_highlight_namespaces()
  iterate_all_windows(function(winid, _)
    if winid ~= vim.api.nvim_get_current_win() then
      vim.api.nvim_win_set_hl_ns(winid, __.tint_ns)
    end
  end)
end

--- Check if this plugin is currently enabled
---
---@return boolean Truth-y if enabled, false-y otherwise
local function check_enabled()
  return __.enabled
end

--- Triggered by:
---  `:h WinEnter`
---  `:h FocusGained`
---
--- Restore the default highlight namespace
---
---@param _ table Arguments from the associated `:h nvim_create_autocmd` setup
__.on_focus = function(_)
  if not check_enabled() then
    return
  end

  local winid = vim.api.nvim_get_current_win()
  if not __.user_config.dynamic_window_ignore and win_should_ignore_tint(winid) then
    return
  end

  tint.untint(winid)
end

--- Triggered by:
---  `:h WinLeave`
---  `:h FocusLost`
---
--- Set the tint highlight namespace
---
---@param _ table Arguments from the associated `:h nvim_create_autocmd` setup
__.on_unfocus = function(_)
  if not check_enabled() then
    return
  end

  local winid = vim.api.nvim_get_current_win()
  if win_should_ignore_tint(winid) then
    if __.user_config.dynamic_window_ignore then
      tint.untint(winid)
    end
    return
  end

  tint.tint(winid)
end

--- Triggered by:
---   `:h ColorScheme`
---
--- Redefine highlights in both namespaces based on colors in new colorscheme
---
---@param _ table Arguments from the associated `:h nvim_create_autocmd` setup
__.on_colorscheme = function(_)
  if not check_enabled() then
    return
  end

  __.setup_all(true)
end

--- Setup everything required for this module to run
---
---@param skip_config boolean Skip re-doing user configuration setup, useful when re-enabling, etc.
__.setup_all = function(skip_config)
  if not skip_config then
    setup_user_config()
  end

  setup_namespaces()
  setup_autocmds()
end

--- Setup user configuration, highlight namespaces, and autocommands
---
--- Triggered by:
---   `:h VimEnter`
---
---@param _ table Arguments from the associated `:h nvim_create_autocmd` setup
__.setup_callback = function(_)
  __.setup_all()
end

--- Enable this plugin
---
---@public
tint.enable = function()
  if __.enabled or not __.user_config then
    return
  end

  __.enabled = true

  -- Reconfigure autocommands, setup highlight namespaces, etc.
  --
  -- Skip user config setup as this has already happened
  __.setup_all(true)

  -- Would need to trigger too many autocommands to restore tinting,
  -- so just do this manually
  set_tint_highlight_namespaces()
end

--- Disable this plugin
---
---@public
tint.disable = function()
  if not __.enabled or not __.user_config then
    return
  end

  -- Disable autocommands
  create_augroup()
  __.setup_autocmds = false

  restore_default_highlight_namespaces()

  __.enabled = false
end

--- Toggle the plugin being enabled and/or disabled
---
---@public
tint.toggle = function()
  if __.enabled then
    tint.disable()
  else
    tint.enable()
  end
end

--- Setup the plugin - can be called infinite times but will only do setup once
---
---@public
---@param user_config table User configuration values, see `:h tint-setup`
tint.setup = function(user_config)
  if not verify_version() then
    return
  end

  if __.user_config then
    return
  end

  __.user_config = user_config

  on_or_after_vimenter(__.setup_callback)
end

--- Refresh highlight namespaces, to be used after new highlight groups are added that need to be tinted
---
---@public
tint.refresh = function()
  if not __.user_config then
    return
  end

  setup_namespaces()
end

--- Tint the specified window
---
---@param winid number A valid window handle
tint.tint = function(winid)
  if not __.user_config or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  vim.api.nvim_win_set_hl_ns(winid, __.tint_ns)
end

--- Untint the specified window
---
---@param winid number A valid window handle
tint.untint = function(winid)
  if not __.user_config or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  vim.api.nvim_win_set_hl_ns(winid, __.default_ns)
end

return tint