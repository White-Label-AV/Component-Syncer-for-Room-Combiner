ctls = {
	{
		Name = "RoomCombineTarget",
		ControlType = "Text",
		TextBoxStyle = "ComboBox",
		Count = 1,
		PinStyle = "Input",
		UserPin = true
	},
	{
		Name = "SyncingComponentTargets",
		ControlType = "Text",
		TextBoxStyle = "Normal",
		Count = props["Rooms"].Value,
		PinStyle = "Input",
		UserPin = true
	},
	{
		Name = "SyncByString",
		ControlType = "Button",
		ButtonType = "Toggle",
		PinStyle = "Input",
		UserPin = true
	},
	{
		Name = "SyncByValue",
		ControlType = "Button",
		ButtonType = "Toggle",
		PinStyle = "Input",
		UserPin = true
	},
	{
		Name = "SyncByPosition",
		ControlType = "Button",
		ButtonType = "Toggle",
		PinStyle = "Input",
		UserPin = true
	},
	{
		Name = "SyncByBoolean",
		ControlType = "Button",
		ButtonType = "Toggle",
		PinStyle = "Input",
		UserPin = true
	},
	{
		Name = "Status",
		ControlType = "Indicator",
		IndicatorType = "Status",
		Count = 1,
		PinStyle = "Output",
		UserPin = true
	},
	{
		Name = "SyncedControls",
		ControlType = "Text",
		TextBoxStyle = "ListBox",
		Count = 1,
		UserPin = false
	},
	{
		Name = "ComponentType",
		ControlType = "Text",
		TextBoxStyle = "Normal",
		PinStyle = "Output",
		Count = 1,
		UserPin = true
	},
	{
		Name = "NonVolatileMem",
		ControlType = "Text",
		TextBoxStyle = "Normal",
		Count = 1,
		UserPin = false
	}
}
