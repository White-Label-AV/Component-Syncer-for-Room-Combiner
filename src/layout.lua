	local roomQty = props["Rooms"].Value

	-- layout holds the representation of Controls; graphics holds aesthetic items.
	local layout = {}
	local graphics = {}

	local MARGIN  = WLAV.Space.PadNarrow   -- 16
	local LABEL_X = 18
	local LABEL_W = 136
	local FIELD_X = 162
	local ROW_H   = 20
	local ROW_GAP = 4

	--[[ Synced Component Name grid. The boxes wrap into a new row after
	     ROOM_COLS, so the panel grows downward instead of running off to the
	     right — at 256 rooms a single row was over 9000 px wide. Because the
	     column count is capped, the grid's WIDTH is constant for any room count
	     above ROOM_COLS, which is what lets the fields below align to it. ]]--
	local ROOM_COLS    = 4
	local ROOM_NUM_W   = 25             -- fits a right-aligned "256"
	local ROOM_NUM_GAP = 4
	local ROOM_BOX_W   = 96
	local ROOM_BOX_H   = 20
	local ROOM_COL_GAP = 12
	local ROOM_ROW_GAP = 6
	local GRID_PAD     = 8
	local GROUP_HDR    = 20                -- room left for the "Room" group title

	local cols  = math.min(roomQty, ROOM_COLS)
	local rows  = math.ceil(roomQty / cols)
	local cellW = ROOM_NUM_W + ROOM_NUM_GAP + ROOM_BOX_W
	local gridW = cols * cellW + (cols - 1) * ROOM_COL_GAP

	-- Every field below the grid takes this width, so the panel reads as one
	-- block rather than a wide box above a narrow column.
	local FIELD_W = math.max(288, gridW + GRID_PAD * 2)
	local ROWS_H  = GROUP_HDR + GRID_PAD
	                + rows * ROOM_BOX_H + (rows - 1) * ROOM_ROW_GAP + GRID_PAD

	-- The panel sizes itself to its contents, so the header is given the width the
	-- plugin's own content occupies — never more, or the panel stretches to fit.
	local contentR = FIELD_X + FIELD_W
	local PANEL_W  = contentR + LABEL_X

	-- This page sets ZOrder, so the header must too — mixing is undefined. Content
	-- is numbered from the next free level the header reports, never a literal.
	local top, z = WLAVHeader.Draw(graphics, PANEL_W, { ZOrder = 1 })

	--[[ ZOrder is handed out one level per element, counting up from what the
	     header reported. `z` is advanced in place rather than through a helper that
	     hands it back, because the QP002 linter check inspects every exit point in
	     GetControlLayout and expects each to yield `layout, graphics`. ]]--

	-- A right-aligned field label in the left gutter.
	local function fieldLabel(text, y, h)
		z = z + 1
		table.insert(graphics, {
			Type = "Text",
			Text = text,
			Font = WLAV.Font,
			FontSize = WLAV.Size.Meta,
			FontStyle = WLAV.Weight.Medium,
			HTextAlign = "Right",
			Color = WLAV.Color.Charcoal,
			Fill = WLAV.Color.Clear,
			Position = {LABEL_X, y},
			Size = {LABEL_W, h},
			ZOrder = z
		})
	end

	--[[ Row origins. Each is derived from the one above it, so the whole panel
	     moves with the header rather than carrying hard-coded y values. ]]--
	local roomsY     = top + MARGIN
	local syncByY    = roomsY + ROWS_H + 8
	local compTypeY  = syncByY + ROW_H + ROW_GAP
	local syncedY    = compTypeY + ROW_H + ROW_GAP
	local combinerY  = syncedY + 128 + ROW_GAP
	local statusY    = combinerY + ROW_H + ROW_GAP

	--[[ Room group box and the per-room component name boxes ]]--
	z = z + 1
	table.insert(graphics, {
		Type = "GroupBox",
		Text = "Room",
		Font = WLAV.Font,
		FontSize = WLAV.Size.Meta,
		FontStyle = WLAV.Weight.Medium,
		HTextAlign = "Left",
		StrokeColor = WLAV.Color.Hairline,
		StrokeWidth = 1,
		CornerRadius = 2,
		Color = WLAV.Color.Charcoal,
		Fill = WLAV.Color.Clear,
		Position = {FIELD_X, roomsY},
		Size = {FIELD_W, ROWS_H},
		ZOrder = z
	})

	for i = 1, roomQty do
		local col = (i - 1) % cols
		local row = math.floor((i - 1) / cols)
		local numX = FIELD_X + GRID_PAD + col * (cellW + ROOM_COL_GAP)
		local boxX = numX + ROOM_NUM_W + ROOM_NUM_GAP
		local cellY = roomsY + GROUP_HDR + GRID_PAD + row * (ROOM_BOX_H + ROOM_ROW_GAP)

		z = z + 1
		table.insert(graphics, {
			Type = "Text",
			Text = tostring(i),
			Font = WLAV.Font,
			FontSize = WLAV.Size.Meta,
			FontStyle = WLAV.Weight.Regular,
			HTextAlign = "Right",
			Color = WLAV.Color.Slate,
			Fill = WLAV.Color.Clear,
			Position = {numX, cellY},
			Size = {ROOM_NUM_W, ROOM_BOX_H},
			ZOrder = z
		})
		z = z + 1
		layout["SyncingComponentTargets " .. tostring(i)] = {
			PrettyName = "Synced Component Name~Room " .. tostring(i),
			Style = "Text",
			TextBoxStyle = "Normal",
			Position = {boxX, cellY},
			Size = {ROOM_BOX_W, ROOM_BOX_H},
			HTextAlign = "Left",
			Font = WLAV.Font,
			FontSize = WLAV.Size.Meta,
			Color = WLAV.Color.Surface,
			StrokeColor = WLAV.Color.Hairline,
			StrokeWidth = 1,
			ZOrder = z
		}
	end
	-- Centred on the grid, which is now several rows tall. The label wraps to two
	-- lines: it is wider than the 136 px gutter, and a single-line box lets the
	-- two rendered lines spill out of it.
	fieldLabel("Synced Component Names", roomsY + math.floor((ROWS_H - 32) / 2), 32)

	--[[ Sync by property — a radio group, so the four buttons span the field
	     width as one control strip. ]]--
	local syncBy = {
		{key = "SyncByString",   legend = "String"},
		{key = "SyncByValue",    legend = "Value"},
		{key = "SyncByPosition", legend = "Position"},
		{key = "SyncByBoolean",  legend = "Boolean"},
	}
	local btnW = math.floor(FIELD_W / #syncBy)
	for i, b in ipairs(syncBy) do
		z = z + 1
		-- The last button absorbs the rounding remainder so the strip ends flush
		-- with the fields above and below it.
		local w = (i == #syncBy) and (FIELD_W - btnW * (#syncBy - 1)) or btnW
		layout[b.key] = {
			PrettyName = "Sync by~" .. b.legend,
			Style = "Button",
			ButtonStyle = "Toggle",
			Legend = b.legend,
			Position = {FIELD_X + (i - 1) * btnW, syncByY},
			Size = {w, ROW_H},
			Font = WLAV.Font,
			FontSize = WLAV.Size.Meta,
			ZOrder = z
		}
	end
	fieldLabel("Sync By Property", syncByY, ROW_H)

	--[[ Detected component type ]]--
	z = z + 1
	layout["ComponentType"] = {
		PrettyName = "Detected Component Type",
		IsReadOnly = true,
		Style = "Indicator",
		IndicatorStyle = "TextBox",
		Position = {FIELD_X, compTypeY},
		Size = {FIELD_W, ROW_H},
		Font = WLAV.Font,
		FontSize = WLAV.Size.Meta,
		ZOrder = z
	}
	fieldLabel("Detected Component Type", compTypeY, ROW_H)

	--[[ Synced controls ]]--
	z = z + 1
	layout["SyncedControls"] = {
		PrettyName = "Synced Controls",
		Style = "ListBox",
		Position = {FIELD_X, syncedY},
		Size = {FIELD_W, 128},
		Font = WLAV.Font,
		FontSize = WLAV.Size.Meta,
		ZOrder = z
	}
	fieldLabel("Synced Controls", syncedY, 128)

	--[[ Room Combiner target ]]--
	z = z + 1
	layout["RoomCombineTarget"] = {
		PrettyName = "Room Combiner Name",
		Style = "ComboBox",
		Position = {FIELD_X, combinerY},
		Size = {FIELD_W, ROW_H},
		Font = WLAV.Font,
		FontSize = WLAV.Size.Meta,
		ZOrder = z
	}
	fieldLabel("Room Combiner Name", combinerY, ROW_H)

	--[[ Status ]]--
	z = z + 1
	layout["Status"] = {
		PrettyName = "Status",
		Style = "Indicator",
		IndicatorStyle = "Status",
		Position = {FIELD_X, statusY},
		Size = {FIELD_W, 48},
		Font = WLAV.Font,
		FontSize = WLAV.Size.Meta,
		ZOrder = z
	}
	fieldLabel("Status", statusY, 48)

	--[[ Internal storage for the Synced Controls selection. Style "None" hides it
	     while keeping it a real control, which is what the layout completeness
	     check asks for -- every control wants a layout entry, even the ones the
	     integrator is never meant to see. Nothing is rendered, so its position is
	     immaterial. ]]--
	z = z + 1
	layout["NonVolatileMem"] = {
		PrettyName = "Internal~Saved Control Selection",
		Style = "None",
		Position = {LABEL_X, top},
		Size = {1, 1},
		ZOrder = z
	}
