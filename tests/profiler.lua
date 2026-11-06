vim.opt.rtp:prepend(vim.fn.getcwd())
local tools = require("debug_tools")
assert(not package.loaded["debug_tools.profiler"])
local notices = {}
vim.notify = function(msg)
  notices[#notices + 1] = msg
end
assert(tools.inspect(nil, false, { x = 1 }):find("nil\nfalse", 1, true))
local original = vim.print
tools.setup({ globals = true, override_print = true })
assert(vim.print == tools.inspect and _G.dd == tools.inspect)
assert(tools.backtrace("fixture"):find("fixture", 1, true))
tools.disable()
assert(vim.print == original and _G.dd == nil)
local p = tools.profiler
local before_jit = jit.status()
local function parent(n)
  local function child()
    local x = 0
    for i = 1, 300 do
      x = x + i
    end
    return x
  end
  if n > 0 then
    return child() + parent(n - 1)
  end
  return child()
end
p.start()
assert(p.running and not jit.status())
tools.setup({ globals = true })
assert(p.running, "Normal setup must preserve startup profiling")
assert(parent(3) == 180600)
local function failure()
  error("expected")
end
assert(not pcall(failure))
parent(1)
p.stop()
assert(jit.status() == before_jit and debug.gethook() == nil)
local snapshot = p.snapshot()
assert(#snapshot.functions > 0 and snapshot.duration_ms > 0)
local found
for _, row in ipairs(snapshot.functions) do
  assert(row.self_ms >= 0 and row.total_ms >= row.self_ms)
  if row.source == debug.getinfo(parent, "S").source and row.line == debug.getinfo(parent, "S").linedefined then
    assert(row.count == 6, vim.inspect(row))
    found = true
  end
end
assert(found)
local hook = function() end
debug.sethook(hook, "c")
assert(not pcall(p.start))
assert(debug.gethook() == hook)
debug.sethook()
p.start({ max_functions = 1 })
parent(4)
p.stop()
assert(#p.snapshot().functions == 1 and p.snapshot().dropped_calls > 0)
local out = vim.fn.tempname() .. ".json"
p.save(out)
assert(vim.json.decode(table.concat(vim.fn.readfile(out), "\n")).duration_ms > 0)
vim.fn.delete(out)
p.startup({ event = "DebugToolsFixture", save = false })
vim.api.nvim_exec_autocmds("User", { pattern = "DebugToolsFixture" })
assert(p.running)
assert(vim.wait(500, function()
  return not p.running
end))
local file = vim.fn.fnamemodify("tests/profiler.lua", ":p")
vim.cmd.edit(file)
p.highlights(true)
assert(p.highlighted)
local ns = vim.api.nvim_get_namespaces().DebugToolsProfiler
assert(#vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) > 0)
p.highlights(false)
assert(#vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) == 0)
local report = p.show()
assert(vim.bo[report].buftype == "nofile" and not vim.bo[report].modifiable)
vim.cmd.close()
print(
  "Debug tools: values, globals, recursion, errors, hook ownership, JIT restoration, bounds, startup, export and highlights passed"
)
