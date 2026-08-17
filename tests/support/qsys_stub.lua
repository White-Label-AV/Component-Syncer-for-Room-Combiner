--[[ A minimal Q-SYS runtime stand-in for host-side tests of this plugin.

     Deliberately hand-rolled rather than using qsys-dev's qsys_mock.lua, for two
     reasons: that mock's Component.GetControls only accepts a component object
     where this plugin passes a name string (which a real Core accepts), and these
     tests need a virtual clock to exercise the debounce timers.

     What it models that matters:
       * assigning .Value/.String/.Position/.Boolean re-fires the control's own
         EventHandler, but only when the value actually changed — which is how
         Q-SYS behaves and what the plugin's sync guards depend on;
       * Timer.New() objects driven by an explicit clock, so a test can advance
         time rather than sleep.
]]--

local M = {}

local FIRING = { Boolean = true, Value = true, String = true, Position = true }

--[[ Counts every ASSIGNMENT to a control value, not just the ones that change it.
     That distinction is the whole point when measuring sync cost: a redundant
     write to an already-equal control raises no event, so counting events hides
     exactly the quadratic blow-up these tests exist to catch. ]]--
M.stats = { writes = 0 }

function M.resetStats() M.stats.writes = 0 end

function M.newControl(init)
  local store = { Boolean = false, Value = 0, String = "", Position = 0, Color = "" }
  for k, v in pairs(init or {}) do store[k] = v end
  local proxy = {}
  setmetatable(proxy, {
    __index = function(_, k) return store[k] end,
    __newindex = function(self, k, v)
      if FIRING[k] then M.stats.writes = M.stats.writes + 1 end
      local changed = store[k] ~= v
      store[k] = v
      if FIRING[k] and changed and store.EventHandler then
        store.EventHandler(self)
      end
    end,
  })
  return proxy
end

--[[ Build a stub design.

     opts.rooms        number of plugin room slots (the Rooms property)
     opts.combinerRooms number of output.N.combined controls on the combiner
     opts.walls        number of walls on the combiner
     opts.gains        number of "Room Gain_N" gain components to publish
     opts.gainType     component type string for those (default "gain")
     opts.presets      { String=bool, Value=bool, ... } initial Sync By state
     opts.debug        Debug Print property value (default "None")
]]--
function M.design(opts)
  opts = opts or {}
  local roomCount = opts.rooms or 8
  local combinerRooms = opts.combinerRooms or roomCount
  local walls = opts.walls or 1
  local gains = opts.gains or 0
  local gainType = opts.gainType or "gain"

  local h = { now = 0, timers = {}, prints = {} }

  ---- components -------------------------------------------------------------
  local components = {}   -- name -> { type = , controls = {name -> control} }

  local combiner = { type = "room_combiner", controls = {} }
  for i = 1, combinerRooms do
    combiner.controls["output." .. i .. ".combined"] = M.newControl({ Color = "Black" })
  end
  for i = 1, walls do
    combiner.controls["wall." .. i .. ".open"] = M.newControl()
    combiner.controls["wall." .. i .. ".config"] = M.newControl()
  end
  components["Room Combiner"] = combiner
  h.combiner = combiner

  for i = 1, gains do
    components["Room Gain_" .. i] = {
      type = gainType,
      controls = {
        gain = M.newControl({ Value = 0 }),
        mute = M.newControl(),
      },
    }
  end
  h.components = components

  ---- controls ---------------------------------------------------------------
  local presets = opts.presets or {}
  local C = {
    RoomCombineTarget = M.newControl({ String = opts.combinerTarget or "" }),
    SyncByString      = M.newControl({ Boolean = presets.String   or false }),
    SyncByValue       = M.newControl({ Boolean = presets.Value    or false }),
    SyncByPosition    = M.newControl({ Boolean = presets.Position or false }),
    SyncByBoolean     = M.newControl({ Boolean = presets.Boolean  or false }),
    Status            = M.newControl(),
    SyncedControls    = M.newControl(),
    ComponentType     = M.newControl(),
    NonVolatileMem    = M.newControl({ String = "" }),
    SyncingComponentTargets = {},
  }
  for i = 1, roomCount do
    C.SyncingComponentTargets[i] = M.newControl()
  end
  h.C = C

  ---- Timer with a virtual clock --------------------------------------------
  local Timer = {}
  Timer.New = function()
    local t = { _running = false, _due = 0 }
    t.Start = function(self, sec) self._due = h.now + sec; self._running = true end
    t.Stop = function(self) self._running = false end
    t.IsRunning = function(self) return self._running end
    h.timers[#h.timers + 1] = t
    return t
  end
  Timer.CallAfter = function(fn, sec)
    local t = Timer.New()
    t.EventHandler = function(self) self:Stop(); fn() end
    t:Start(sec)
  end
  Timer.Now = function() return h.now end

  -- Advance the clock and fire whatever is due. Repeats until nothing more is
  -- due, so a handler that schedules another timer still runs.
  function h.advance(seconds)
    h.now = h.now + (seconds or 0)
    for _ = 1, 50 do
      local fired = false
      for _, t in ipairs(h.timers) do
        if t._running and t._due <= h.now then
          if t.EventHandler then t.EventHandler(t) else t:Stop() end
          fired = true
        end
      end
      if not fired then break end
    end
  end

  ---- environment -----------------------------------------------------------
  local env = {
    Controls = C,
    Properties = { ["Debug Print"] = { Value = opts.debug or "None" } },
    Timer = Timer,
    Component = {
      GetComponents = function()
        local out = {}
        for name, c in pairs(components) do
          out[#out + 1] = { Name = name, Type = c.type, Properties = {} }
        end
        table.sort(out, function(a, b) return a.Name < b.Name end)
        return out
      end,
      -- Accepts a name string, as a real Core does.
      GetControls = function(nameOrComp)
        local c = type(nameOrComp) == "string" and components[nameOrComp] or nil
        local out = {}
        if c then
          for n in pairs(c.controls) do out[#out + 1] = { Name = n } end
        end
        return out
      end,
      New = function(name)
        local c = components[name]
        if not c then return nil end
        return c.controls
      end,
    },
    json = {
      encode = function(t)
        -- Just enough to round-trip the choices table through NonVolatileMem.
        local parts = {}
        for _, e in ipairs(t) do
          parts[#parts + 1] = string.format('{"Text":%q,"Active":%s,"Index":%d}',
                                            e.Text, e.Active and "true" or "false", e.Index)
        end
        return "[" .. table.concat(parts, ",") .. "]"
      end,
      decode = function(s)
        local out = {}
        for text, active, index in s:gmatch('{"Text":"(.-)","Active":(%a+),"Index":(%d+)}') do
          out[#out + 1] = { Text = text, Active = (active == "true"), Index = tonumber(index) }
        end
        if #out == 0 then
          -- a single object, as the ListBox hands back on a click
          local text, index = s:match('"Text":"(.-)".*"Index":(%d+)')
          if text then return { Text = text, Index = tonumber(index) } end
        end
        return out
      end,
    },
    print = function(...)
      local parts = {}
      for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
      h.prints[#h.prints + 1] = table.concat(parts, "\t")
    end,
    math = math, string = string, table = table, tostring = tostring,
    tonumber = tonumber, type = type, pairs = pairs, ipairs = ipairs,
    error = error, os = os, select = select, rawget = rawget, pcall = pcall,
    setmetatable = setmetatable, getmetatable = getmetatable, next = next,
    require = nil,
  }
  env._G = env
  h.env = env

  return h
end

-- Load the compiled plugin into the stub design. Returns ok, err.
function M.run(h, qplug)
  local chunk, loadErr = loadfile(qplug, "t", h.env)
  if not chunk then return false, loadErr end
  return pcall(chunk)
end

function M.statusName(value)
  local names = { [0] = "OK", [1] = "Compromised", [2] = "Fault", [3] = "NotPresent",
                  [4] = "Missing", [5] = "Initializing" }
  return names[value] or ("?" .. tostring(value))
end

return M
