# debug-tools.nvim

Native Lua inspection and profiling for Neovim 0.11+. No runtime dependencies.

```lua
{ dir = '~/Documents/Github/nvim_plugins/debug-tools.nvim',
  main = 'debug_tools', opts = { globals = true, override_print = true } }
```

`inspect(...)` pretty prints values (including nils) through `vim.notify` with the
caller location. `backtrace(message)` displays a Lua traceback. `setup()` creates
`:DebugTools`; globals `dd`/`bt` and `vim.print` replacement are explicitly opt-in.
`disable()` restores only globals still owned by the plugin and stops profiling.

`:DebugTools start`, `stop`, `toggle`, `show`, `highlights`, and `save` control the
profiler. `show` opens a scratch report sorted by self time; Enter opens the source
and q closes the report. `highlights` toggles source annotations for the most
recent snapshot, clearing stale annotations after edits. `save` writes JSON under
`stdpath('state')/debug-tools`. Functions have call count, inclusive/self/max time,
source and definition line. `snapshot()` returns fresh structured data.

```lua
local p = require('debug_tools').profiler
p.start({ max_functions = 20000 })
-- Run the interaction to measure.
p.stop()
local data = p.snapshot()
p.highlights(true)
p.save('/tmp/profile.json')
```

The profiler uses the main Lua thread's call/return hook. It refuses an existing
hook, disables and flushes LuaJIT while running, and restores JIT state on stop.
Coroutine bodies are excluded. Timings include hook overhead and are for finding
hotspots; compare normal runtime separately. Functions sharing a source definition
line share one row. The function table is bounded; `dropped_calls` counts entries
beyond that bound. No unbounded event trace is retained.

Call `require('debug_tools.profiler').startup({ event = 'VeryLazy', save = true })`
before plugin initialization to capture startup. It stops after synchronous event
handlers and saves automatically; exiting before the event also stops and saves.
The plugin does not install a startup hook unless requested.

`:DebugTools startup` measures native startup in ten sequential child Neovim
processes with an attached 80×24 UI. This uses `--startuptime`, independently of
the Lua hook profiler. Reports show per-event mean self/inclusive time and total
mean, median, minimum and maximum. These are warm runs ending at the native
`NVIM STARTED` marker, not a measurement of deferred plugin readiness.
Enter opens an event's source; q closes the report.

```lua
local startup = require('debug_tools.startuptime')
local run = startup.run({ tries = 10 }) -- same executable, environment and cwd
-- startup.run({ tries = 3, args = { '-u', 'NONE' }, show = false,
--   on_done = function(result, err) ... end })
-- run.cancel() -- child and temporary files are cleaned up
```

Children inherit your configuration and its normal startup side effects. `PROF`
is disabled in children; each child has a 15-second timeout. Runs never enable
profiling in the parent editor. `startup.last` retains the latest result and
`startup.show()` reopens it. `disable()` cancels an active measurement.

Validation: `sh tests/run.sh`.

`:DebugToolsStartup [count]` measures startup (default: 10 runs).

## Command ownership

Commands belong to the plugin; choose global entry keys and short aliases in
your configuration. Registration reports same-name conflicts without replacing
user commands. Reconfiguration refreshes only commands still owned by this
plugin, and cleanup preserves subsequent user replacements.
