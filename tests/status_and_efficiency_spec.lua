--[[ Status reporting, debouncing and sync-cost tests.

         lua53 tests/status_and_efficiency_spec.lua roomcombine-components-syncer.qplug

     Covers the four issues fixed in 1.1.0.0:
       1. an unconfigured plugin reports Compromised, not Fault
       2. (layout — see geometry check)
       3. the status no longer flickers when 256 name boxes populate
       4. the sync path does not scale quadratically with room count
]]--

package.path = (arg[0]:match("^(.*)[/\\][^/\\]*$") or ".") .. "/support/?.lua;" .. package.path
local S = require("qsys_stub")

local qplug = assert(arg[1], "usage: lua status_and_efficiency_spec.lua <file.qplug>")

local failures, checks = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    print("  FAIL " .. msg)
  end
end
local function section(name) print("\n-- " .. name) end

-- Wraps the plugin's InitialiseAll so tests can count how often it actually ran.
local function countInits(h)
  local counter = { n = 0 }
  local original = h.env.InitialiseAll
  h.env.InitialiseAll = function(...)
    counter.n = counter.n + 1
    return original(...)
  end
  return counter
end

--=============================================================================
section("1. Unconfigured plugin reports Compromised, never Fault or Initializing")
--=============================================================================
do
  local h = S.design({ rooms = 8 })
  local ok, err = S.run(h, qplug)
  check(ok, "loads with nothing configured (" .. tostring(err) .. ")")
  h.advance(1)

  local v = h.C.Status.Value
  check(v == 1, "no Room Combiner selected -> Compromised, got " .. S.statusName(v))
  check(h.C.Status.String:find("Not configured") ~= nil,
        "message tells the user to configure: " .. tostring(h.C.Status.String))
  check(v ~= 5, "never reports Initializing (application-owned state)")
  check(v ~= 3, "never reports Not Present (application-owned state)")
end

do
  -- Combiner chosen, but no component names yet: still configuration, not fault.
  local h = S.design({ rooms = 8, combinerTarget = "Room Combiner", gains = 8 })
  S.run(h, qplug)
  h.advance(1)
  local v = h.C.Status.Value
  check(v == 1, "combiner set but no component names -> Compromised, got " .. S.statusName(v))
  check(h.C.Status.String:find("Not configured") ~= nil,
        "message names the missing step: " .. tostring(h.C.Status.String))
end

do
  -- A name that does not resolve IS a fault: the user asked for something real.
  local h = S.design({ rooms = 8, combinerTarget = "No Such Combiner" })
  S.run(h, qplug)
  h.advance(1)
  check(h.C.Status.Value == 2,
        "invalid combiner name -> Fault, got " .. S.statusName(h.C.Status.Value))
end

do
  -- Fully configured and valid -> OK.
  local h = S.design({ rooms = 8, combinerTarget = "Room Combiner", gains = 8 })
  S.run(h, qplug)
  h.advance(1)
  for i = 1, 8 do h.C.SyncingComponentTargets[i].String = "Room Gain_" .. i end
  h.advance(1)
  check(h.C.Status.Value == 0,
        "8 rooms fully configured -> OK, got " .. S.statusName(h.C.Status.Value)
        .. " / " .. tostring(h.C.Status.String))
end

--=============================================================================
section("3. Populating 256 name boxes causes ONE initialise, and no flicker")
--=============================================================================
do
  local h = S.design({ rooms = 256, combinerTarget = "Room Combiner", gains = 256, walls = 8 })
  local ok, err = S.run(h, qplug)
  check(ok, "loads at 256 rooms (" .. tostring(err) .. ")")

  local inits = countInits(h)
  h.advance(1)
  check(inits.n == 1, "startup settles into 1 initialise, got " .. inits.n)

  -- Simulate the design loading: all 256 boxes populate in one burst.
  local statuses = {}
  h.C.Status.EventHandler = function(c) statuses[#statuses + 1] = c.Value end
  inits.n = 0
  for i = 1, 256 do
    h.C.SyncingComponentTargets[i].String = "Room Gain_" .. i
  end
  check(inits.n == 0, "no initialise runs mid-burst; all 256 edits are debounced, got " .. inits.n)

  h.advance(1)
  check(inits.n == 1, "the burst collapses into exactly 1 initialise, got " .. inits.n)
  check(h.C.Status.Value == 0,
        "settles on OK, got " .. S.statusName(h.C.Status.Value)
        .. " / " .. tostring(h.C.Status.String))

  local flickers = 0
  for _, v in ipairs(statuses) do if v == 5 then flickers = flickers + 1 end end
  check(flickers == 0, "status never passed through Initializing, saw " .. flickers .. " time(s)")
  check(#statuses <= 2,
        "at most one status transition for the whole burst, saw " .. #statuses)
end

--=============================================================================
section("4. Sync cost is linear in room count, not quadratic")
--=============================================================================
do
  -- One group of 256 rooms, syncing `gain` by Value. Moving one fader must write
  -- each of the other 255 once — not 255 times each, as the old re-entrant path
  -- did (~65,000 writes).
  local h = S.design({ rooms = 256, combinerTarget = "Room Combiner", gains = 256, walls = 8 })
  S.run(h, qplug)
  h.advance(1)
  for i = 1, 256 do h.C.SyncingComponentTargets[i].String = "Room Gain_" .. i end
  h.advance(1)
  check(h.C.Status.Value == 0, "256 rooms configured -> OK, got " .. S.statusName(h.C.Status.Value))

  -- Activate the `gain` control in the Synced Controls list.
  h.C.SyncByValue.Boolean = true
  local choices = h.C.SyncedControls.Choices
  local gainIndex = nil
  for i, c in ipairs(choices or {}) do if c.Text == "gain" then gainIndex = i end end
  check(gainIndex ~= nil, "the gain control is offered in Synced Controls")

  if gainIndex then
    h.C.SyncedControls.String =
      string.format('{"Text":"gain","Index":%d}', gainIndex)
    h.advance(1)

    --[[ Count every assignment to any control value from here on. One fader move
         across a 256-room group should write each of the other 255 exactly once.
         Without the re-entrancy guard each of those 255 writes re-enters and
         re-broadcasts, which costs ~255^2 = 65,025 assignments even though the
         values have already converged and no further events are raised. ]]--
    S.resetStats()
    -- pcall, because without the guard this does not merely get slow: each write
    -- re-enters and re-broadcasts before returning, so it recurses until the C
    -- stack is exhausted. Catch it and report a failure rather than dying here.
    local moved, moveErr = pcall(function()
      h.components["Room Gain_1"].controls.gain.Value = -12
    end)
    check(moved, "one fader move completes without runaway recursion (" .. tostring(moveErr) .. ")")
    if moved then h.advance(1) end
    local writes = S.stats.writes

    check(writes > 0, "moving room 1's gain propagated at all, writes=" .. writes)
    check(writes <= 512,
          "one fader move stays linear: expected <=512 assignments for 256 rooms, got " .. writes)

    local synced = 0
    for i = 2, 256 do
      if h.components["Room Gain_" .. i].controls.gain.Value == -12 then synced = synced + 1 end
    end
    check(synced == 255, "all 255 other rooms received the value, got " .. synced)
  end
end

--=============================================================================
section("Debug printing is off by default and gated on the property")
--=============================================================================
do
  local h = S.design({ rooms = 64, combinerTarget = "Room Combiner", gains = 64 })
  S.run(h, qplug)
  h.advance(1)
  for i = 1, 64 do h.C.SyncingComponentTargets[i].String = "Room Gain_" .. i end
  h.advance(1)
  -- Only the mandatory version banner should be present.
  check(#h.prints == 1,
        "Debug Print=None emits only the version banner, got " .. #h.prints .. " line(s)")
  check((h.prints[1] or ""):find("Component Syncer v") ~= nil,
        "version is printed at runtime start (rubric): " .. tostring(h.prints[1]))
end

do
  local h = S.design({ rooms = 8, combinerTarget = "Room Combiner", gains = 8, debug = "All" })
  S.run(h, qplug)
  h.advance(1)
  check(#h.prints > 1, "Debug Print=All does emit diagnostics, got " .. #h.prints .. " line(s)")
end

print(("\n%d checks, %d failure(s)"):format(checks, failures))
if failures > 0 then os.exit(1) end
print("ALL STATUS / EFFICIENCY TESTS PASSED")
