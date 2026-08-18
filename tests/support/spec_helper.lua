--[[ Bridges these specs to qsys-dev's run_tests.lua while keeping them runnable
     on their own.

     Standalone:  lua53 tests/status_and_efficiency_spec.lua <file.qplug>
     Via runner:  lua53 <qsys-dev>/skills/qsys-plugin-test/scripts/run_tests.lua

     The runner discovers tests/*_spec.lua, loads each one and then calls
     T.run(), so a spec has to register its results with the framework rather
     than print a summary and exit. It also passes no arguments, hence the
     default plugin path. ]]--

local M = {}

-- The runner is invoked from the repo root, so a relative default is right.
M.qplug = arg and arg[1] or "roomcombine-components-syncer.qplug"

local sections, current = {}, nil

function M.section(name)
  current = { name = name, failures = 0, msgs = {} }
  sections[#sections + 1] = current
  print("\n-- " .. name)
end

function M.check(cond, msg)
  if not current then M.section("checks") end
  if not cond then
    current.failures = current.failures + 1
    current.msgs[#current.msgs + 1] = msg
    print("  FAIL " .. msg)
  end
end

-- Call last. Registers one test per section when the framework is available,
-- otherwise prints a summary and sets the exit status.
function M.finish(topic)
  -- The runner loads every spec into one Lua state, so this module is shared
  -- between them. Take the sections accumulated since the last finish() and
  -- reset, or each spec would re-register the ones before it.
  local mine = sections
  sections, current = {}, nil

  local ok, T = pcall(require, "qsys_test")
  if ok and T and T.describe then
    T.describe(topic, function()
      for _, s in ipairs(mine) do
        T.it(s.name, function()
          T.ok(s.failures == 0,
               ("%d check(s) failed: %s"):format(s.failures, table.concat(s.msgs, " | ")))
        end)
      end
    end)
    return
  end
  local total, count = 0, 0
  for _, s in ipairs(mine) do
    total = total + s.failures
    count = count + 1
  end
  print(("\n%d section(s), %d failure(s)"):format(count, total))
  if total > 0 then os.exit(1) end
  print("ALL CHECKS PASSED")
end

return M
