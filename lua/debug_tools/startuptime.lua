local M = {}
local api = vim.api
local active

-- Native startup logs have either elapsed time or inclusive and self time.
function M.parse(lines)
  local rows, total = {}, nil
  for _, line in ipairs(lines) do
    local clock, inclusive, own, name = line:match("^%s*([%d.]+)%s+([%d.]+)%s+([%d.]+):%s*(.+)$")
    if not clock then
      clock, inclusive, name = line:match("^%s*([%d.]+)%s+([%d.]+):%s*(.+)$")
      own = inclusive
    end
    if clock then
      rows[#rows + 1] = { name = name, clock = tonumber(clock), inclusive = tonumber(inclusive), self = tonumber(own) }
      if name == "--- NVIM STARTED ---" then
        total = tonumber(clock)
        break
      end
    end
  end
  assert(total, "Neovim exited without a complete --startuptime log")
  return { total = total, rows = rows }
end

function M.aggregate(samples)
  assert(#samples > 0, "No startup samples")
  local result = { tries = #samples, rows = {}, totals = {}, mean = 0 }
  local by_name = {}
  for _, sample in ipairs(samples) do
    result.totals[#result.totals + 1] = sample.total
    result.mean = result.mean + sample.total / #samples
    for _, row in ipairs(sample.rows) do
      local entry = by_name[row.name]
      if not entry then
        entry = { name = row.name, self = 0, inclusive = 0, count = 0 }
        by_name[row.name], result.rows[#result.rows + 1] = entry, entry
      end
      entry.self = entry.self + row.self / #samples
      entry.inclusive = entry.inclusive + row.inclusive / #samples
      entry.count = entry.count + 1
    end
  end
  table.sort(result.totals)
  result.min, result.max = result.totals[1], result.totals[#samples]
  result.median = (result.totals[math.floor((#samples + 1) / 2)] + result.totals[math.ceil((#samples + 1) / 2)]) / 2
  table.sort(result.rows, function(a, b)
    return a.self == b.self and a.name < b.name or a.self > b.self
  end)
  return result
end

function M.show(result)
  result = result or M.last
  if not result then
    return false
  end
  local lines = {
    ("Native startup · %d runs · UI attached (80×24)"):format(result.tries),
    ("Total ms: mean %.3f · median %.3f · min %.3f · max %.3f"):format(
      result.mean,
      result.median,
      result.min,
      result.max
    ),
    "Warm sequential runs; Lua hook profiler disabled. Times end at NVIM STARTED.",
    "Mean times per run; repeated event names are combined. Enter: source · q: close",
    "",
    "   Self ms  Inclusive ms  Event",
  }
  for _, row in ipairs(result.rows) do
    lines[#lines + 1] = ("%10.3f  %12.3f  %s"):format(row.self, row.inclusive, row.name)
  end
  vim.cmd("botright new")
  local buf = api.nvim_get_current_buf()
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype, vim.bo[buf].modifiable = "debug-tools-startuptime", false
  vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = buf, silent = true, desc = "Close startup report" })
  vim.keymap.set("n", "<CR>", function()
    local row = result.rows[api.nvim_win_get_cursor(0)[1] - 6]
    if not row then
      return
    end
    local file = row.name:match("^sourcing (.+)$")
    local mod = row.name:match("^require%(['\"](.+)['\"]%)$")
    if mod then
      local found = vim.loader.find(mod)
      file = found[1] and found[1].modpath
    end
    if file and vim.fn.filereadable(file) == 1 then
      vim.cmd("wincmd p")
      vim.cmd.edit(vim.fn.fnameescape(file))
    end
  end, { buffer = buf, desc = "Open startup event source" })
  return buf
end

function M.run(opts)
  opts = opts or {}
  assert(not active, "A startup measurement is already running")
  local tries = opts.tries or 10
  assert(type(tries) == "number" and tries % 1 == 0 and tries >= 1 and tries <= 100, "tries must be 1..100")
  assert(
    opts.timeout_ms == nil or type(opts.timeout_ms) == "number" and opts.timeout_ms > 0,
    "timeout_ms must be positive"
  )
  assert(opts.args == nil or type(opts.args) == "table" and vim.islist(opts.args), "args must be a list")
  for _, arg in ipairs(opts.args or {}) do
    assert(
      type(arg) == "string" and not arg:match("^%-%-startuptime") and arg ~= "--embed" and arg ~= "--headless",
      "invalid child argument"
    )
  end
  local state = { samples = {}, done = false }
  active = state
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p", 448)
  local function finish(err)
    if state.done then
      return
    end
    state.done, active = true, nil
    if state.timer then
      state.timer:stop()
      state.timer:close()
      state.timer = nil
    end
    if state.job then
      vim.fn.jobstop(state.job)
      state.job = nil
    end
    vim.fn.delete(directory, "rf")
    local result = not err and M.aggregate(state.samples) or nil
    if result then
      M.last = result
      if opts.show ~= false then
        M.show(result)
      end
    elseif not opts.on_done then
      vim.notify("Startup measurement: " .. err, vim.log.levels.WARN)
    end
    if opts.on_done then
      opts.on_done(result, err)
    end
  end
  function state.cancel()
    finish("cancelled")
  end
  local function next_run()
    if state.done then
      return
    end
    local log = directory .. "/startup.log"
    vim.fn.delete(log)
    -- --embed waits for UI attachment before loading the user's configuration.
    -- Quit after VimEnter so the log includes the native startup completion marker.
    local command = {
      vim.v.progpath,
      "--embed",
      "--startuptime",
      log,
      "-i",
      "NONE",
      "--cmd",
      "lua vim.api.nvim_create_autocmd('VimEnter',{once=true,callback=function() vim.defer_fn(function() vim.cmd('qa!') end,100) end})",
    }
    vim.list_extend(command, opts.args or {})
    local stderr = ""
    local ok, job = pcall(vim.fn.jobstart, command, {
      -- Drain redraw notifications as bytes; they are UI events, not parent API calls.
      on_stdout = function() end,
      env = { PROF = "0", NVIM_LOG_FILE = directory .. "/nvim.log" },
      on_stderr = function(_, data)
        stderr = (stderr .. table.concat(data, "\n")):sub(-2000)
      end,
      on_exit = function(_, code)
        vim.schedule(function()
          if state.done then
            return
          end
          state.job = nil
          if state.timer then
            state.timer:stop()
            state.timer:close()
            state.timer = nil
          end
          if code ~= 0 then
            finish(("child exited %d: %s"):format(code, stderr))
            return
          end
          local parsed, sample = pcall(function()
            return M.parse(vim.fn.readfile(log))
          end)
          if not parsed then
            finish(tostring(sample))
            return
          end
          state.samples[#state.samples + 1] = sample
          if #state.samples == tries then
            finish()
          else
            next_run()
          end
        end)
      end,
    })
    if not ok or job <= 0 then
      finish("Cannot launch Neovim: " .. tostring(job))
      return
    end
    state.job = job
    state.timer = vim.uv.new_timer()
    state.timer:start(
      opts.timeout_ms or 15000,
      0,
      vim.schedule_wrap(function()
        finish("child startup timed out")
      end)
    )
    local attached, err =
      pcall(vim.fn.chansend, job, vim.mpack.encode({ 2, "nvim_ui_attach", { 80, 24, { ext_linegrid = true } } }))
    if not attached then
      finish(tostring(err))
    end
  end
  next_run()
  return state
end

function M.cancel()
  if active then
    active.cancel()
  end
end

return M
