-- Host-side geometry check for the branded Component Syncer panel.
-- Loads the compiled .qplug with Controls = nil (design time only) and asserts
-- the header is present, content clears it, and nothing overlaps or overruns.

local qplug = assert(arg[1], "usage: lua geomcheck.lua <file.qplug>")

Controls = nil
local chunk = assert(loadfile(qplug))
chunk()

local function propsFor(rooms)
  return { Rooms = { Value = rooms } }
end

local function rect(item)
  local p, s = item.Position, item.Size
  return p[1], p[2], p[1] + s[1], p[2] + s[2]
end

local function overlaps(a, b)
  local ax1, ay1, ax2, ay2 = rect(a)
  local bx1, by1, bx2, by2 = rect(b)
  return ax1 < bx2 and bx1 < ax2 and ay1 < by2 and by1 < ay2
end

local failures = 0
local function check(cond, msg)
  if not cond then
    failures = failures + 1
    print("  FAIL " .. msg)
  end
end

print("PluginInfo.Version    = " .. tostring(PluginInfo.Version))
print("PluginInfo.Model      = " .. tostring(PluginInfo.Model))
print("PluginInfo.Manufactr. = " .. tostring(PluginInfo.Manufacturer))
print("GetPrettyName()       = " .. GetPrettyName({}))
local c = GetColor({})
print(("GetColor()            = {%d, %d, %d}"):format(c[1], c[2], c[3]))
local HEADER_H = 90  -- WLAVHeader is a file-scope local in the plugin; documented height
print("header height (spec)  = " .. HEADER_H)
print("")

for _, rooms in ipairs({ 2, 4, 8, 12, 16, 24, 64, 256 }) do
  local props = propsFor(rooms)
  local layout, graphics = GetControlLayout(props)
  check(layout ~= nil and graphics ~= nil, "rooms=" .. rooms .. ": layout/graphics returned")

  -- 1. The header must be drawn: its charcoal rule is a 3px-tall GroupBox at y=87.
  local ruleFound, logoFound = false, false
  for _, g in ipairs(graphics) do
    if g.Type == "GroupBox" and g.Size[2] == 3 and g.Position[2] == 87 then ruleFound = true end
    if g.Type == "Svg" or g.Type == "Image" then logoFound = true end
  end
  check(ruleFound, "rooms=" .. rooms .. ": header baseline rule present at y=87")
  check(logoFound, "rooms=" .. rooms .. ": header logo present")

  -- 2. Every control must clear the header band entirely.
  local minY = math.huge
  local items = {}
  for name, l in pairs(layout) do
    check(l.Position ~= nil and l.Size ~= nil, "rooms=" .. rooms .. ": " .. name .. " has Position+Size")
    if l.Position then
      minY = math.min(minY, l.Position[2])
      items[#items + 1] = { name = name, Position = l.Position, Size = l.Size }
    end
  end
  check(minY >= HEADER_H,
        ("rooms=%d: topmost control y=%d clears header (%d)"):format(rooms, minY, HEADER_H))

  -- 3. No two controls may overlap.
  for i = 1, #items do
    for j = i + 1, #items do
      if overlaps(items[i], items[j]) then
        check(false, ("rooms=%d: %s overlaps %s"):format(rooms, items[i].name, items[j].name))
      end
    end
  end

  -- 4. ZOrder must be set on everything (all-or-nothing per page) and be distinct.
  local seen, missing = {}, 0
  local dupes = 0
  for _, g in ipairs(graphics) do
    if g.ZOrder == nil then missing = missing + 1
    elseif seen[g.ZOrder] then dupes = dupes + 1
    else seen[g.ZOrder] = true end
  end
  for name, l in pairs(layout) do
    if l.ZOrder == nil then missing = missing + 1
    elseif seen[l.ZOrder] then dupes = dupes + 1
    else seen[l.ZOrder] = true end
  end
  check(missing == 0, ("rooms=%d: %d element(s) missing ZOrder"):format(rooms, missing))
  check(dupes == 0, ("rooms=%d: %d duplicate ZOrder value(s)"):format(rooms, dupes))

  -- 5. Nothing may extend left of the panel.
  local minX = math.huge
  for _, g in ipairs(graphics) do minX = math.min(minX, g.Position[1]) end
  for _, l in pairs(items) do minX = math.min(minX, l.Position[1]) end
  check(minX >= 0, ("rooms=%d: leftmost x=%d is not negative"):format(rooms, minX))

  local maxX = 0
  for _, g in ipairs(graphics) do local _, _, x2 = rect(g); maxX = math.max(maxX, x2) end
  for _, l in ipairs(items) do local _, _, x2 = rect(l); maxX = math.max(maxX, x2) end
  print(("rooms=%3d  controls=%3d  graphics=%3d  panel right edge=%4d  top control y=%d")
        :format(rooms, #items, #graphics, maxX, minY))
end

print("")
if failures == 0 then
  print("ALL GEOMETRY CHECKS PASSED")
else
  print(failures .. " CHECK(S) FAILED")
  os.exit(1)
end
