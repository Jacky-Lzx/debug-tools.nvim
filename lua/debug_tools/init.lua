local M = {}
local originals, installed = {}, {}

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
  opts = opts or {}
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
  vim.api.nvim_create_user_command("DebugTools", function(args)
    local action = args.args ~= "" and args.args or "show"
    assert(
      vim.tbl_contains({ "start", "stop", "toggle", "show", "highlights", "save" }, action),
      "Unknown debug action"
    )
    if action == "highlights" then
      M.profiler.highlights()
    elseif action == "save" then
      vim.notify(M.profiler.save(), vim.log.levels.INFO, { title = "Profile saved" })
    else
      M.profiler[action]()
    end
  end, {
    nargs = "?",
    complete = function()
      return { "start", "stop", "toggle", "show", "highlights", "save" }
    end,
    force = true,
  })
end

function M.disable()
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
  local profiler = package.loaded["debug_tools.profiler"]
  if profiler then
    profiler.stop()
    profiler.highlights(false)
  end
  pcall(vim.api.nvim_del_user_command, "DebugTools")
end
return M
