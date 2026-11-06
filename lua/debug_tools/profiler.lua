local M = { running = false, highlighted = false }
local uv, api = vim.uv, vim.api
local clock = uv.hrtime
local stats, stack, started, elapsed, options = {}, {}, nil, 0, {}
local hook, jit_was_on, dropped = nil, false, 0
local ns = api.nvim_create_namespace("DebugToolsProfiler")
local function finish(frame, now)
  local duration = now - frame.start
  if frame.stat then
    frame.stat.count = frame.stat.count + 1
    frame.stat.total_ns = frame.stat.total_ns + duration
    frame.stat.self_ns = frame.stat.self_ns + math.max(0, duration - frame.children)
    frame.stat.max_ns = math.max(frame.stat.max_ns, duration)
  end
  if #stack > 0 then
    stack[#stack].children = stack[#stack].children + duration
  end
end

function M.start(opts)
  if M.running then
    return false
  end
  assert(debug.gethook() == nil, "Another Lua debug hook is active")
  options = vim.tbl_extend("force", { max_functions = 20000 }, opts or {})
  assert(options.max_functions >= 1 and options.max_functions % 1 == 0, "max_functions must be a positive integer")
  stats, stack, elapsed, dropped = {}, {}, 0, 0
  local count = 0
  hook = function(event)
    local info = debug.getinfo(2, "fSn")
    local now = clock()
    if event == "call" then
      local stat
      if info.what ~= "C" and not info.source:find("debug_tools/", 1, true) then
        local key = info.source .. ":" .. info.linedefined
        stat = stats[key]
        if not stat and count < options.max_functions then
          stat = {
            source = info.source,
            line = info.linedefined,
            name = info.name or "<anonymous>",
            count = 0,
            total_ns = 0,
            self_ns = 0,
            max_ns = 0,
          }
          stats[key], count = stat, count + 1
        elseif not stat then
          dropped = dropped + 1
        end
      end
      stack[#stack + 1] = { fn = info.func, stat = stat, start = now, children = 0 }
    elseif event == "return" or event == "tail return" then
      -- An error may unwind frames without return events. Match the returning
      -- function, then close its abandoned children at the same timestamp.
      for i = #stack, 1, -1 do
        if stack[i].fn == info.func then
          while #stack >= i do
            finish(table.remove(stack), now)
          end
          break
        end
      end
    end
  end
  jit_was_on = jit and jit.status() or false
  if jit_was_on then
    jit.off()
    jit.flush()
  end
  started, M.running = clock(), true
  debug.sethook(hook, "cr")
  return true
end

function M.stop()
  if not M.running then
    return false
  end
  if debug.gethook() == hook then
    debug.sethook()
  end
  local now = clock()
  while #stack > 0 do
    finish(table.remove(stack), now)
  end
  elapsed, M.running = now - started, false
  if jit_was_on then
    jit.on()
  end
  if M.highlighted then
    M.highlights(true)
  end
  return true
end

function M.toggle()
  if M.running then
    M.stop()
    M.show()
  else
    M.start()
  end
  return M.running
end

function M.snapshot()
  local rows = {}
  for _, stat in pairs(stats) do
    rows[#rows + 1] = {
      source = stat.source,
      line = stat.line,
      name = stat.name,
      count = stat.count,
      total_ms = stat.total_ns / 1e6,
      self_ms = stat.self_ns / 1e6,
      max_ms = stat.max_ns / 1e6,
    }
  end
  table.sort(rows, function(a, b)
    if a.self_ms ~= b.self_ms then
      return a.self_ms > b.self_ms
    end
    return a.source .. a.line < b.source .. b.line
  end)
  return {
    duration_ms = (M.running and clock() - started or elapsed) / 1e6,
    running = M.running,
    dropped_calls = dropped,
    functions = rows,
  }
end

local function jump(row)
  if row and row.source:sub(1, 1) == "@" and vim.fn.filereadable(row.source:sub(2)) == 1 then
    vim.cmd.edit(vim.fn.fnameescape(row.source:sub(2)))
    api.nvim_win_set_cursor(0, { math.max(1, math.min(row.line, api.nvim_buf_line_count(0))), 0 })
  end
end

function M.show()
  local report = M.snapshot()
  vim.cmd("botright vnew")
  local buf = api.nvim_get_current_buf()
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
  local lines = {
    ("Lua profile · %.2fms · %d functions · dropped %d"):format(
      report.duration_ms,
      #report.functions,
      report.dropped_calls
    ),
    "    self ms    total ms   calls      max ms  function / location",
  }
  for _, row in ipairs(report.functions) do
    lines[#lines + 1] = ("%11.3f %11.3f %7d %11.3f  %s  %s:%d"):format(
      row.self_ms,
      row.total_ms,
      row.count,
      row.max_ms,
      row.name,
      row.source:gsub("^@", ""),
      row.line
    )
  end
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype, vim.bo[buf].modifiable = "debug-tools-profile", false
  vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = buf, desc = "Close profiling report" })
  vim.keymap.set("n", "<CR>", function()
    jump(report.functions[api.nvim_win_get_cursor(0)[1] - 2])
  end, { buffer = buf, desc = "Open profiled function source" })
  return buf
end

function M.save(path)
  path = path
    or vim.fs.joinpath(
      vim.fn.stdpath("state"),
      "debug-tools",
      os.date("profile-%Y%m%d-%H%M%S-") .. uv.hrtime() .. ".json"
    )
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  assert(vim.fn.writefile({ vim.json.encode(M.snapshot()) }, path) == 0, "Cannot write profile")
  return path
end

function M.highlights(enabled)
  if enabled == nil then
    enabled = not M.highlighted
  end
  local group = api.nvim_create_augroup("DebugToolsProfilerHighlights", { clear = true })
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) then
      api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
  M.highlighted = enabled
  if not enabled then
    return false
  end
  api.nvim_set_hl(0, "DebugToolsProfile", { link = "DiagnosticWarn", default = true })
  local report = M.snapshot()
  local by_file = {}
  for _, row in ipairs(report.functions) do
    if row.source:sub(1, 1) == "@" then
      local file = vim.fs.normalize(vim.fn.fnamemodify(row.source:sub(2), ":p"))
      by_file[file] = by_file[file] or {}
      by_file[file][#by_file[file] + 1] = row
    end
  end
  local function render(buf)
    if not api.nvim_buf_is_loaded(buf) then
      return
    end
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, row in ipairs(by_file[api.nvim_buf_get_name(buf)] or {}) do
      if row.line > 0 and row.line <= api.nvim_buf_line_count(buf) then
        api.nvim_buf_set_extmark(buf, ns, row.line - 1, 0, {
          virt_text = {
            { (" %.2fms self / %.2fms total ×%d"):format(row.self_ms, row.total_ms, row.count), "DebugToolsProfile" },
          },
          hl_mode = "combine",
        })
      end
    end
  end
  for _, buf in ipairs(api.nvim_list_bufs()) do
    render(buf)
  end
  api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(ev)
      render(ev.buf)
    end,
  })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(ev)
      by_file[api.nvim_buf_get_name(ev.buf)] = nil
      api.nvim_buf_clear_namespace(ev.buf, ns, 0, -1)
    end,
  })
  return true
end

function M.startup(opts)
  opts = opts or {}
  M.start(opts)
  local group = api.nvim_create_augroup("DebugToolsProfilerStartup", { clear = true })
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = opts.event or "VeryLazy",
    once = true,
    callback = function()
      vim.schedule(function()
        M.stop()
        if opts.save ~= false then
          M.last_path = M.save(opts.path)
        end
        if opts.show then
          M.show()
        end
      end)
    end,
  })
  api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    once = true,
    callback = function()
      if M.running then
        M.stop()
        if opts.save ~= false then
          M.last_path = M.save(opts.path)
        end
      end
    end,
  })
end
return M
