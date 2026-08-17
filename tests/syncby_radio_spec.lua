--[[ Sync By Property radio-group tests.

         lua53 tests/syncby_radio_spec.lua roomcombine-components-syncer.qplug

     The point of these tests is the re-entrancy. In Q-SYS, assigning to a
     control's .Boolean fires that control's own EventHandler, so making four
     Toggle buttons mutually exclusive is a recursion hazard: clearing the other
     three has each of them re-assert itself and clear the rest. A missing guard
     shows up here as a stack overflow, not as a wrong value.
]]--

package.path = (arg[0]:match("^(.*)[/\\][^/\\]*$") or ".") .. "/support/?.lua;" .. package.path
local S = require("qsys_stub")

local qplug = assert(arg[1], "usage: lua syncby_radio_spec.lua <file.qplug>")

local failures, checks = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    print("  FAIL " .. msg)
  end
end

-- Load the plugin with the four Sync By buttons pre-set as given.
local function load(presets)
  local h = S.design({ rooms = 8, presets = presets })
  local ok, err = S.run(h, qplug)
  return h.C, ok, err, h
end

local function activeNames(C)
  local names = {}
  for _, n in ipairs({ "String", "Value", "Position", "Boolean" }) do
    if C["SyncBy" .. n].Boolean then names[#names + 1] = n end
  end
  return names
end

local function countActive(C) return #activeNames(C) end

print("=== Sync By Property radio group ===\n")

--[[ 1. A fresh instance settles on exactly one selection, and it is String. ]]--
do
  local C, ok, err = load()
  check(ok, "fresh instance: runtime block loads without error (" .. tostring(err) .. ")")
  check(countActive(C) == 1,
        "fresh instance: exactly one property active, got " .. countActive(C))
  check(C.SyncByString.Boolean, "fresh instance: defaults to String")
end

--[[ 2. Selecting another property deselects the rest — no recursion. ]]--
do
  local C = load()
  local ok, err = pcall(function() C.SyncByValue.Boolean = true end)
  check(ok, "select Value: no stack overflow or error (" .. tostring(err) .. ")")
  check(countActive(C) == 1,
        "select Value: exactly one active, got " .. table.concat(activeNames(C), ","))
  check(C.SyncByValue.Boolean, "select Value: Value is the active one")
  check(not C.SyncByString.Boolean, "select Value: String was cleared")
end

--[[ 3. Each of the four can be selected in turn and wins outright. ]]--
do
  local C = load()
  for _, n in ipairs({ "Position", "Boolean", "String", "Value", "Position" }) do
    local ok, err = pcall(function() C["SyncBy" .. n].Boolean = true end)
    check(ok, "select " .. n .. ": no error (" .. tostring(err) .. ")")
    check(countActive(C) == 1 and C["SyncBy" .. n].Boolean,
          "select " .. n .. ": is sole active, got " .. table.concat(activeNames(C), ","))
  end
end

--[[ 4. Pressing the ACTIVE button re-asserts it: the group is never empty. ]]--
do
  local C = load()
  check(C.SyncByString.Boolean, "press active: String starts active")
  local ok, err = pcall(function() C.SyncByString.Boolean = false end)
  check(ok, "press active: no error (" .. tostring(err) .. ")")
  check(countActive(C) == 1, "press active: group is not empty, got " .. countActive(C))
  check(C.SyncByString.Boolean, "press active: String re-asserted itself")
end

--[[ 5. A design saved by 1.0.x may have several set; precedence resolves it. ]]--
do
  local C = load({ Value = true, Position = true, Boolean = true })
  check(countActive(C) == 1,
        "1.0.x upgrade: collapses to one, got " .. table.concat(activeNames(C), ","))
  check(C.SyncByValue.Boolean,
        "1.0.x upgrade: Value wins over Position and Boolean (precedence order)")
end

do
  local C = load({ String = true, Boolean = true })
  check(countActive(C) == 1, "1.0.x upgrade: String+Boolean collapses to one")
  check(C.SyncByString.Boolean, "1.0.x upgrade: String wins, being first in precedence")
end

--[[ 6. A design already holding a single non-default choice keeps it. ]]--
do
  local C = load({ Position = true })
  check(countActive(C) == 1, "existing choice: still exactly one")
  check(C.SyncByPosition.Boolean,
        "existing choice: Position preserved, not reset to the String default")
end

print(("\n%d checks, %d failure(s)"):format(checks, failures))
if failures > 0 then os.exit(1) end
print("ALL RADIO TESTS PASSED")
