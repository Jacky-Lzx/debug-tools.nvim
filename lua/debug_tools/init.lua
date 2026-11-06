local M = {}
local originals, installed = {}, {}
local last_config, enabled = nil, false

function M.inspect(...)
  local values = {}
  for i = 1, select("#", ...) do
    values[i] = vim.inspect((select(i, ...)))
  end
  local caller = debug.getinfo(2, "Sl") or {}
  local message = table.concat(values, "\n")
  vim.notify(message, vim.log.levels.INFO, {
    title = ("Debug · %s:%d"):format((caller.short_src or "?"), caller.currentline or 0),
    ft = "lua",
  })
  return message
end

function M.backtrace(message)
  local trace = debug.traceback(message or "Backtrace", 2)
  vim.notify(trace, vim.log.levels.WARN, { title = "Backtrace" })
  return trace
end

M.profiler = setmetatable({}, {
  __index = function(_, key)
    return require("debug_tools.profiler")[key]
  end,
})

function M.setup(opts)
  assert(opts == nil or type(opts) == "table", "debug-tools.nvim: setup expects a table")
  opts = vim.deepcopy(opts or {})
  for _, name in ipairs({ "globals", "override_print" }) do
    assert(opts[name] == nil or type(opts[name]) == "boolean", name .. " must be boolean")
  end
  if installed.dd and _G.dd == installed.dd then
    _G.dd = originals.dd
  end
  if installed.bt and _G.bt == installed.bt then
    _G.bt = originals.bt
  end
  if installed.print and vim.print == installed.print then
    vim.print = originals.print
  end
  installed, originals = {}, {}
  if opts.globals then
    originals.dd, originals.bt = _G.dd, _G.bt
    installed.dd, installed.bt = M.inspect, M.backtrace
    _G.dd, _G.bt = installed.dd, installed.bt
  end
  if opts.override_print then
    originals.print, installed.print = vim.print, M.inspect
    vim.print = installed.print
  end
  require("debug_tools.user_command").create("DebugToolsStartup", function(args)
    local tries = args.args == "" and 10 or tonumber(args.args)
    assert(tries, "Expected a run count from 1 to 100")
    require("debug_tools.startuptime").run({ tries = tries })
  end, { nargs = "?", desc = "Measure native Neovim startup (default: 10 runs)" })
  require("debug_tools.user_command").create("DebugTools", function(args)
    local action = args.args ~= "" and args.args or "show"
    assert(
      vim.tbl_contains({ "start", "stop", "toggle", "show", "highlights", "save", "startup" }, action),
      "Unknown debug action"
    )
    if action == "startup" then
      require("debug_tools.startuptime").run()
    elseif action == "highlights" then
      M.profiler.highlights()
    elseif action == "save" then
      vim.notify(M.profiler.save(), vim.log.levels.INFO, { title = "Profile saved" })
    else
      M.profiler[action]()
    end
  end, {
    nargs = "?",
    complete = function()
      return { "start", "stop", "toggle", "show", "highlights", "save", "startup" }
    end,
    force = true,
  })
  last_config, enabled = opts, true
end

function M.enable()
  if not enabled then
    M.setup(last_config)
  end
  return M
end

function M.is_enabled()
  return enabled
end

function M.dispose()
  M.disable()
  last_config = nil
end

function M.disable()
  enabled = false
  if installed.dd and _G.dd == installed.dd then
    _G.dd = originals.dd
  end
  if installed.bt and _G.bt == installed.bt then
    _G.bt = originals.bt
  end
  if installed.print and vim.print == installed.print then
    vim.print = originals.print
  end
  installed, originals = {}, {}
  local startup = package.loaded["debug_tools.startuptime"]
  if startup then
    startup.cancel()
  end
  local profiler = package.loaded["debug_tools.profiler"]
  if profiler then
    profiler.stop()
    profiler.highlights(false)
  end
  require("debug_tools.user_command").delete("DebugToolsStartup")
  pcall(require("debug_tools.user_command").delete, "DebugTools")
end
return M
