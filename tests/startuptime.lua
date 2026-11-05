vim.opt.rtp:prepend(vim.fn.getcwd())
local startup = require("debug_tools.startuptime")
local parsed = startup.parse({
  "000.000  000.000: --- NVIM STARTING ---",
  "001.000  000.800  000.300: sourcing /a.lua",
  "002.000  001.000: --- NVIM STARTED ---",
  "010.000  008.000: ignored",
})
assert(parsed.total == 2 and #parsed.rows == 3 and parsed.rows[2].self == 0.3)
assert(not pcall(startup.parse, { "001.000  001.000: incomplete" }))
local combined = startup.aggregate({ parsed, { total = 4, rows = {} } })
assert(combined.mean == 3 and combined.median == 3 and combined.min == 2 and combined.max == 4)
local done, result, failure = false
startup.run({
  tries = 2,
  args = { "-u", "NONE", "--noplugin" },
  show = false,
  on_done = function(data, err)
    result, failure, done = data, err, true
  end,
})
assert(not pcall(startup.run, { tries = 1 }), "concurrent runs must be refused")
assert(
  vim.wait(10000, function()
    return done
  end, 10),
  "measurement timeout"
)
assert(result, failure)
assert(result.tries == 2 and result.mean > 0 and #result.rows > 10)
assert(startup.show(result))
assert(vim.bo.filetype == "debug-tools-startuptime")
vim.cmd.close()
local cancelled
local handle = startup.run({
  tries = 10,
  args = { "-u", "NONE" },
  show = false,
  on_done = function(data, err)
    assert(not data)
    cancelled = err
  end,
})
handle.cancel()
assert(cancelled == "cancelled")
local failed
startup.run({
  tries = 1,
  timeout_ms = 30,
  args = { "-u", "NONE", "--cmd", "sleep 2" },
  show = false,
  on_done = function(data, err)
    assert(not data)
    failed = err
  end,
})
assert(vim.wait(3000, function()
  return failed ~= nil
end, 10))
assert(failed:find("timed out", 1, true), failed)
assert(not package.loaded["debug_tools.profiler"], "native timing must not enable Lua hook profiling")
print("Native startup parser, statistics, UI-attached children, report, cancellation and timeout passed")
