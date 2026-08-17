-- Component Syncer for Room Combiner — PLUGCC entry point.
-- Order matters: design-time definitions must precede the runtime block, and
-- the brand module must be at file scope so the Get* functions can close over it.
--[[ #include "info.lua" ]]
--[[ #include "../vendor/wlav-brand/brand.lua" ]]
--[[ #include "../vendor/wlav-brand/header.lua" ]]

function GetColor(props)
	return WLAV.Color.Charcoal
end

function GetPrettyName(props)
	return "Component Syncer v" .. PluginInfo.BuildVersion
end

function GetProperties()
	--[[ #include "properties.lua" ]]
	return props
end

function GetControls(props)
	--[[ #include "controls.lua" ]]
	return ctls
end

-- This function allows you to layout pages in your plugin.
function GetControlLayout(props)
	--[[ #include "layout.lua" ]]
	return layout, graphics
end

if Controls then
--[[ #include "runtime.lua" ]]
end
