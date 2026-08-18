	-- QSC's reference requires `json` before use, and the Core provides it. The
	-- guard is for host-side harnesses (linter, unit tests), which expose no
	-- `require` at all — without it the file cannot be loaded off-Core.
	if json == nil and require ~= nil then require("json") end

	--[[ ******************************* ]]--
	--[[ ********* Debug Print ********* ]]--
	--[[ ******************************* ]]--

	DebugFunction, DebugSync = false, false

	function SetupDebugPrint()
		local d = Properties["Debug Print"].Value
		if     d == "Function Calls" then DebugFunction = true
		elseif d == "Sync Activity"  then DebugSync = true
		elseif d == "All"            then DebugFunction, DebugSync = true, true
		end
	end

	print("Component Syncer v" .. PluginInfo.Version .. " started")
	SetupDebugPrint()

	--[[ ******************************* ]]--
	--[[ ******* Global Variables ****** ]]--
	--[[ ******************************* ]]--

	-- pull out all names and types only out of GetComponents()
	componentTypes = {}
	roomCombineTargetChoices = {}
	for i, v in pairs(Component.GetComponents()) do
		componentTypes[v.Name] = v.Type
		if v.Type == "room_combiner" then
			table.insert(roomCombineTargetChoices, v.Name)
		end
	end
	Controls.RoomCombineTarget.Choices = roomCombineTargetChoices

	rooms = {} -- key = room number, value = table of Syncing Components, LED controls (color shows group membership), script component target Text Box controls
	groups = {} -- sort of reverse table of rooms[room][group] info. Keys are group names (LED colors), Values are room numbers that are members of that group.
	wallControls = {} -- flat list of every Room Combiner wall control we have hooked
	choices = {} -- key = index, value = table with k:v pairs (Text:string, Icon:string, Color:string, Active:boolean, Index:number)
	icons = {
		[true] = string.char(0xe2,0x9c,0x93),
		[false] = string.char(0xe2,0x9c,0x95),
	}
	colors = {
		[false] = "Black",
		[true] = "Green"
	}
	detectedType = Controls.ComponentType

	--[[ ******************************* ]]--
	--[[ ********** Debouncing ********* ]]--
	--[[ ******************************* ]]--

	--[[ Both of these coalesce a burst of events into one pass.

	     Re-initialising is very expensive — it re-creates the Room Combiner
	     component, walks all of its controls, and calls Component.New() once per
	     room. At 256 rooms, loading a design fires all 256 name-box handlers, and
	     the old code ran a FULL re-initialise for every one of them. That is what
	     drove the status flicker between Initializing and OK, and it is the most
	     likely source of a Max Execution Limit error.

	     Timers must not be locals — the collector will reap them and they simply
	     stop firing. Timer.New() repeats, so each handler stops its own timer to
	     get one-shot behaviour. ]]--

	INIT_DEBOUNCE = 0.5   -- seconds; generous, only ever user- or load-driven
	SYNC_DEBOUNCE = 0.15  -- seconds; short enough that walls still feel immediate

	initTimer = Timer.New()
	syncTimer = Timer.New()

	function RequestInitialise()
		initTimer:Stop()
		initTimer:Start(INIT_DEBOUNCE)
	end

	function RequestSync()
		syncTimer:Stop()
		syncTimer:Start(SYNC_DEBOUNCE)
	end

	--[[ ******************************* ]]--
	--[[ ********** Functions ********** ]]--
	--[[ ******************************* ]]--

	--[[ Status. Per the Plugin Status Reporting standard, INITIALIZING (5) and
	     NOTPRESENT (3) are set by the application only and must never be set from
	     plugin code — so they are deliberately absent from this map. The standard
	     also warns against flipping status excessively, since a Reflect-enabled
	     design writes every change to the Core event log. ]]--
	StatusState = {
		OK = 0,
		Compromised = 1,
		Fault = 2,
		Missing = 4,
	}

	function UpdateStatus(state, msg)
		local val = state
		if type(state) == "string" then
			val = StatusState[state]
			if val == nil then
				error("UpdateStatus: expected one of OK/Compromised/Fault/Missing, received: " .. tostring(state))
			end
		end
		msg = msg or ""
		-- Only write on an actual change, so a re-initialise that reaches the same
		-- conclusion does not log a status event or flicker the indicator.
		if Controls.Status.Value ~= val or Controls.Status.String ~= msg then
			Controls.Status.Value = val
			Controls.Status.String = msg
		end
	end

	function IsComponentValid(name)  -- returns true or false if a named component is found.
		if name == nil or name == "" then return false end
		return #Component.GetControls(name) ~= 0 and true or false
	end

	function UpdateTextBoxColor(ctl, valid) -- Updates textbox color
		valid = ctl.String == "" or valid -- Textbox is white if the Text box is blank.
		ctl.Color = valid and "White" or "Red"  -- Textbox is white if the entry is valid, red if it's not valid.
	end

	--[[ Propagate one control's change to the rest of its group.

	     Writing to a synced control fires that control's own EventHandler, which
	     propagates the value back out across the whole group again. Three things
	     stop that becoming an O(rooms^2) storm:

	       * `syncing` blocks re-entry that happens DURING the write;
	       * the value comparison means an already-equal control is never written,
	         so no event is raised for it in the first place;
	       * `lastSync` catches the rest. Q-SYS dispatches control EventHandlers
	         asynchronously, so the targets' handlers run on a LATER cycle, by
	         which time `syncing` has been cleared -- measured at 256 handler runs
	         and ~66,000 control reads for a single fader move in a 256-room
	         group. Remembering the value the group was last driven to lets each
	         of those echoes bail out in O(1). ]]--
	syncing = false

	-- [groupName][controlName] = the value the group was last driven to.
	lastSync = {}

	function ControlHasChanged(roomChanged, ctlName)
		if syncing then return end
		if Controls.Status.Value ~= StatusState.OK then return end

		local origin = rooms[roomChanged]
		if origin == nil or origin.component == nil then return end
		local ctl = origin.component[ctlName]
		if ctl == nil then return end
		local group = groups[origin.groupName]
		if group == nil then return end

		if DebugSync then print("ControlHasChanged", roomChanged, ctlName) end

		-- Read the mode and the source values once rather than per target room.
		local byValue = Controls.SyncByValue.Boolean
		local byPosition = Controls.SyncByPosition.Boolean
		local byString = Controls.SyncByString.Boolean
		local byBoolean = Controls.SyncByBoolean.Boolean

		--[[ Echo short-circuit. A handler carrying the value the group was last
		     driven to is the asynchronous echo of our own write, so there is
		     nothing left to propagate. A genuine change to the value every room
		     already holds is a no-op too, so treating the two alike loses
		     nothing. Only applied when exactly one property is being synced --
		     the radio group guarantees that, but if it were ever violated the
		     cached value would not describe the whole change. ]]--
		local modes, mode = 0, nil
		if byValue    then modes = modes + 1; mode = "Value" end
		if byPosition then modes = modes + 1; mode = "Position" end
		if byString   then modes = modes + 1; mode = "String" end
		if byBoolean  then modes = modes + 1; mode = "Boolean" end
		if modes == 1 then
			local record = lastSync[origin.groupName]
			if record == nil then
				record = {}
				lastSync[origin.groupName] = record
			end
			local current = ctl[mode]
			if record[ctlName] ~= nil and record[ctlName] == current then return end
			record[ctlName] = current
		end

		local srcValue, srcPosition = ctl.Value, ctl.Position
		local srcString, srcBoolean = ctl.String, ctl.Boolean

		syncing = true
		for _, room in ipairs(group) do
			if room ~= roomChanged then
				local t = rooms[room]
				if t ~= nil and t.component ~= nil then
					local target = t.component[ctlName]
					if target ~= nil then
						if byValue    and target.Value    ~= srcValue    then target.Value = srcValue end
						if byPosition and target.Position ~= srcPosition then target.Position = srcPosition end
						if byString   and target.String   ~= srcString   then target.String = srcString end
						if byBoolean  and target.Boolean  ~= srcBoolean  then target.Boolean = srcBoolean end
					end
				end
			end
		end
		syncing = false
	end

	function DestroyComponentEventHandlers(component) -- Remove EventHandler function assigments for all controls in an unused component.
		if component ~= nil then
			for _, aControl in pairs(component) do
				aControl.EventHandler = nil
			end
		end
	end

	--[[ Drop every handler this plugin has registered and clear derived state.
	     Without this a re-initialise left the previous pass's component handlers
	     live — they kept firing against stale tables, and the wasted work grew
	     with every re-initialise. ]]--
	function TeardownAll()
		for _, t in pairs(rooms) do
			DestroyComponentEventHandlers(t.component)
		end
		for _, control in ipairs(wallControls) do
			control.EventHandler = nil
		end
		rooms = {}
		groups = {}
		wallControls = {}
		lastSync = {}
	end

	function UpdateControlEventHandler(room, ctlName, active) -- Assign or remove control EventHandler function assignment based on whether it's active or not.
		local t = rooms[room]
		if t ~= nil and t.component ~= nil and t.component[ctlName] ~= nil then
			t.component[ctlName].EventHandler = active
				and function() ControlHasChanged(room, ctlName) end
				or nil
		end
	end

	function UpdateControlEventHandlerInAllRooms(ctlName, active) -- Used when a Synced Control option changes
		for room, _ in pairs(rooms) do
			UpdateControlEventHandler(room, ctlName, active)
		end
	end

	function CreateAllControlEventHandlersInComponent(room) --Creates EventHandlers for all active Controls inside the Component
		for i, v in ipairs(choices) do
			UpdateControlEventHandler(room, v.Text, v.Active)
		end
	end

	function UpdateGroupsTable()
		groups = {}
		-- Group membership is changing, so what each group was last driven to no
		-- longer describes anything.
		lastSync = {}
		-- Ascending room order, which is what lets GetFirstRoomWithComponent take
		-- the first match without sorting.
		for room = 1, #Controls.SyncingComponentTargets do
			local t = rooms[room]
			if t ~= nil and t.LEDctl ~= nil then
				-- we're using the LED colour as the group name.
				local ledColor = t.LEDctl.Color
				t.groupName = ledColor
				if groups[ledColor] == nil then
					groups[ledColor] = {room}
				else
					table.insert(groups[ledColor], room)
				end
			end
		end
	end

	--[[ Lowest-numbered room holding a valid component. `group` nil means all
	     rooms. The old version called table.sort() on every invocation, which was
	     both redundant (groups are built in ascending order) and a side effect on
	     the caller's table. ]]--
	function GetFirstRoomWithComponent(group)
		if group == nil then
			local lowest = nil
			for room, t in pairs(rooms) do
				if t.component ~= nil and (lowest == nil or room < lowest) then
					lowest = room
				end
			end
			return lowest
		end
		for _, room in ipairs(group) do
			local t = rooms[room]
			if t ~= nil and t.component ~= nil then return room end
		end
		return nil
	end

	function SyncroniseAllGroups() -- Syncronises all active controls within all groups
		if DebugFunction then print("SyncroniseAllGroups()") end
		-- This is a deliberate "force everything into agreement" pass, so it must
		-- not be short-circuited by what was propagated before it.
		lastSync = {}
		for groupName, group in pairs(groups) do
			if #group > 1 then
				local lowestRoom = GetFirstRoomWithComponent(group)
				if lowestRoom ~= nil then
					for _, choiceTable in ipairs(choices) do
						if choiceTable.Active then
							local ctlName = choiceTable.Text
							local source = nil
							if rooms[lowestRoom].component[ctlName] ~= nil then
								source = lowestRoom
							else
								-- The lowest room's component lacks this control; take the
								-- first room in the group that has it.
								for _, room in ipairs(group) do
									local t = rooms[room]
									if t ~= nil and t.component ~= nil and t.component[ctlName] ~= nil then
										source = room
										break
									end
								end
							end
							if source ~= nil then
								ControlHasChanged(source, ctlName)
							end
						end
					end
				end
			end
		end
	end

	function WallHasChanged() -- Room Combiner Walls Control EventHandler Function
		UpdateGroupsTable()
		SyncroniseAllGroups()
	end

	syncTimer.EventHandler = function(t)
		t:Stop()
		WallHasChanged()
	end

	function SyncedControlsHasChanged(ctl) -- Synced Controls List Box EventHandler Function
		local ok, chosenChoice = pcall(json.decode, ctl.String)
		if not ok or type(chosenChoice) ~= "table" or chosenChoice.Index == nil then return end
		local index = chosenChoice.Index
		if choices[index] == nil then return end

		choices[index].Active = not choices[index].Active
		choices[index].Color = colors[choices[index].Active]
		choices[index].Icon = icons[choices[index].Active]

		UpdateControlEventHandlerInAllRooms(choices[index].Text, choices[index].Active) -- create/destroy eventHandlers for control that has changed

		SyncroniseAllGroups()

		Controls.SyncedControls.Choices = choices
		Controls.NonVolatileMem.String = json.encode(choices)
	end

	function UpdateComponentObject(room) -- adds or removes a named component into the rooms table
		local textBoxCtl = Controls.SyncingComponentTargets[room]
		if textBoxCtl == nil then return end
		local name = textBoxCtl.String
		local componentValid = IsComponentValid(name)
		UpdateTextBoxColor(textBoxCtl, componentValid)

		rooms[room].component = componentValid and Component.New(name) or nil
	end

	function VerifyComponentTypes(firstRoom) -- Verify that all component types are the same, returns true or false
		if firstRoom == nil then return false end
		local firstComponentName = rooms[firstRoom].textBox.String
		local firstType = componentTypes[firstComponentName]

		for room, t in pairs(rooms) do
			if t.component ~= nil then
				local thisRoomComponentName = t.textBox.String
				if componentTypes[thisRoomComponentName] ~= firstType then
					UpdateStatus("Fault", "Not all Syncing components are of same type. "..firstComponentName.." is "..tostring(firstType)..", "..thisRoomComponentName.." is "..tostring(componentTypes[thisRoomComponentName]))
					return false
				end
			end
		end
		return true
	end

	function VerifyTwoOrMoreComponents(firstRoom) -- Verifies that at least two components exist, returns true or false.
		if firstRoom == nil then
			UpdateStatus("Fault", "No valid components found. Check the Synced Component Names.")
			return false
		end
		local count = 0
		for _, t in pairs(rooms) do
			if t.component ~= nil then count = count + 1 end
		end
		if count < 2 then
			UpdateStatus("Fault", "Only one valid component specified.")
			return false
		end
		return true
	end

	function DisplayChoices(firstRoom) -- Displays all the choices
		local firstComponentName = rooms[firstRoom].textBox.String
		local detected = componentTypes[firstComponentName]

		--[[ The union of control names across every room's component, gathered once.
		     Sorted so the list is stable: the old code took pairs() order straight
		     from the component, which Lua does not guarantee between runs, so the
		     Synced Controls list could reorder itself across a restart. ]]--
		local seen = {}
		local names = {}
		for room, t in pairs(rooms) do
			if t.component ~= nil then
				for name, _ in pairs(t.component) do
					if seen[name] == nil then
						seen[name] = true
						names[#names + 1] = name
					end
				end
			end
		end
		table.sort(names)

		local previous = {}
		if detectedType.String == detected then
			--[[ Same component type, so carry the saved selection over. Indexed by
			     name: the old code did a linear scan of `choices` per control, and
			     could also hand out an Index that disagreed with the entry's actual
			     position — which then toggled the wrong control. ]]--
			local raw = Controls.NonVolatileMem.String
			if raw ~= nil and raw ~= "" then
				local ok, decoded = pcall(json.decode, raw)
				if ok and type(decoded) == "table" then
					for _, entry in ipairs(decoded) do
						if type(entry) == "table" and entry.Text ~= nil then
							previous[entry.Text] = entry.Active and true or false
						end
					end
				end
			end
		else
			detectedType.String = detected
		end

		choices = {}
		for i, name in ipairs(names) do
			local active = previous[name] or false
			choices[i] = {
				["Text"] = name,
				["Icon"] = icons[active],
				["Color"] = colors[active],
				["Active"] = active,
				["Index"] = i,
			}
		end

		-- save the choices into non-volatile control string, in case of reboot/redeploy.
		Controls.NonVolatileMem.String = json.encode(choices)
		Controls.SyncedControls.Choices = choices
	end

	function InitialiseAll()
		if DebugFunction then print("InitialiseAll()") end
		TeardownAll()

		local target = Controls.RoomCombineTarget.String

		--[[ Nothing configured yet. Compromised (yellow) rather than Fault (red):
		     nothing is broken, the plugin simply has not been set up, and a
		     freshly placed instance should not raise a red alarm. Note that
		     Initializing is not available to plugin code — the application owns
		     it — so it cannot be used to mean "not ready yet". ]]--
		if target == "" then
			UpdateTextBoxColor(Controls.RoomCombineTarget, true)
			UpdateStatus("Compromised", "Not configured - select a Room Combiner")
			return
		end

		local componentValid = IsComponentValid(target) --Check Room Combiner Component Exists
		UpdateTextBoxColor(Controls.RoomCombineTarget, componentValid)
		if not componentValid then
			UpdateStatus("Fault", "Room Combiner target not a valid component. Check component name and try again.")
			return
		end

		roomCombiner = Component.New(target)

		local numberOfRooms = 0
		for name, control in pairs(roomCombiner) do
			if name:find("output%.%d+%.combined") then
				numberOfRooms = numberOfRooms + 1
				local room = tonumber(name:match("output%.(%d+)%.combined"))
				rooms[room] = { LEDctl = control } -- Add each room, with its Room Combiner LED control
			elseif name:find("wall%.%d+%.") then -- Watch every wall control for a grouping change
				wallControls[#wallControls + 1] = control
				control.EventHandler = RequestSync
			end
		end

		-- Reported at the end rather than here, so a mismatch does not stop the
		-- rest of the wiring from being set up (as it did not before).
		local faultMsg = nil
		if numberOfRooms ~= #Controls.SyncingComponentTargets then
			faultMsg = "Room Combiner number of rooms does not match this plugin - Room Combiner: "..tostring(numberOfRooms)..", This Plugin: "..#Controls.SyncingComponentTargets
		end

		UpdateGroupsTable()

		local namesEntered = 0
		for room, roomTable in pairs(rooms) do
			roomTable.textBox = Controls.SyncingComponentTargets[room] -- Add Syncing Component Targets Text Boxes
			if roomTable.textBox ~= nil and roomTable.textBox.String ~= "" then
				namesEntered = namesEntered + 1
			end
			UpdateComponentObject(room) -- Update Component objects
		end

		-- A Room Combiner is chosen but no components named yet: still setup, not
		-- a fault.
		if namesEntered == 0 then
			UpdateStatus("Compromised", "Not configured - enter at least two Synced Component Names")
			return
		end

		local firstRoom = GetFirstRoomWithComponent()
		if not VerifyTwoOrMoreComponents(firstRoom) then return end -- both set their own status
		if not VerifyComponentTypes(firstRoom) then return end

		DisplayChoices(firstRoom)

		for room, t in pairs(rooms) do -- Create EventHandlers for all active controls in all rooms with components
			if t.component ~= nil then
				CreateAllControlEventHandlersInComponent(room)
			end
		end

		if faultMsg ~= nil then
			UpdateStatus("Fault", faultMsg)
		else
			UpdateStatus("OK") -- Finished initialising with no faults
			SyncroniseAllGroups()
		end
	end

	initTimer.EventHandler = function(t)
		t:Stop()
		InitialiseAll()
	end

	--[[ ******************************* ]]--
	--[[ *********** Startup *********** ]]--
	--[[ ******************************* ]]--

	for i, v in ipairs(Controls.SyncingComponentTargets) do
		v.EventHandler = RequestInitialise
	end

	--[[ Sync By Property is a radio group: exactly one property carries a change.
	     Q-SYS has no radio ButtonType available to a plugin, so the four Toggle
	     buttons are made mutually exclusive here. Listed in precedence order,
	     which decides the winner when a design arrives with more than one set. ]]--
	syncByControls = {
		Controls.SyncByString,
		Controls.SyncByValue,
		Controls.SyncByPosition,
		Controls.SyncByBoolean,
	}

	-- Assigning .Boolean re-fires the control's own EventHandler, so without this
	-- guard clearing the other three would have each of them re-assert itself and
	-- clear the rest, recursing until the stack gave out.
	syncByUpdating = false

	function SelectSyncByProperty(chosen)
		syncByUpdating = true
		for _, ctl in ipairs(syncByControls) do
			ctl.Boolean = (ctl == chosen)
		end
		syncByUpdating = false
	end

	for _, ctl in ipairs(syncByControls) do
		ctl.EventHandler = function(thisCtl)
			if syncByUpdating then return end
			-- Selecting the button makes it the sole active one either way: pressing
			-- the active button off re-asserts it, so the group is never empty.
			SelectSyncByProperty(thisCtl)
			SyncroniseAllGroups()
		end
	end

	--[[ Establish a single selection at startup. A fresh instance has none set, and
	     a design saved by 1.0.x may have several, since the four were independent
	     before this version. Either way exactly one is active afterwards. ]]--
	do
		local active = nil
		for _, ctl in ipairs(syncByControls) do
			if ctl.Boolean and active == nil then active = ctl end
		end
		SelectSyncByProperty(active or Controls.SyncByString)
	end

	Controls.RoomCombineTarget.EventHandler = RequestInitialise

	Controls.SyncedControls.EventHandler = function(ctl) SyncedControlsHasChanged(ctl) end

	-- Debounced rather than direct: at 256 rooms the name-box handlers fire as the
	-- design loads, and this folds those in with the first pass.
	RequestInitialise()
