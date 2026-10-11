class_name AutomationSettings extends AcceptDialog

var bridge: AutomationBridge
var _path: LineEdit
var _root: LineEdit
var _enabled: CheckBox
var _editing: CheckBox
var _port: SpinBox
var _status: Label


func _ready() -> void:
	title = "Local MCP settings"
	confirmed.connect(queue_free)
	canceled.connect(queue_free)
	var body := VBoxContainer.new()
	add_child(body)
	var help := Label.new()
	help.text = "Create the configuration with mcp/dist/configure.js first.\nSelect the same file in Bosca and your MCP host."
	body.add_child(help)
	_path = _field(body, "Configuration file", bridge.config_path)
	_button(body, "Choose configuration...", _choose_file)
	_enabled = CheckBox.new()
	_enabled.text = "Enable local MCP"
	body.add_child(_enabled)
	_editing = CheckBox.new()
	_editing.text = "Allow edits (unchecked = read only)"
	body.add_child(_editing)
	_port = SpinBox.new()
	_port.min_value = 1024
	_port.max_value = 65535
	_port.prefix = "Port "
	body.add_child(_port)
	_root = _field(body, "Song directory (absolute path)", "")
	_button(body, "Apply settings", _apply.bind(false))
	_button(body, "Rotate token and reconnect", _apply.bind(true))
	_button(body, "Disconnect client", bridge.disconnect_client)
	_button(body, "Copy MCP host configuration", _copy_client)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size.x = 600
	body.add_child(_status)
	_refresh()
	var timer := Timer.new()
	timer.wait_time = 1.0
	timer.timeout.connect(func(): _status.text = bridge.connection_status())
	add_child(timer)
	timer.start()


func _field(body: VBoxContainer, caption: String, value: String) -> LineEdit:
	var label := Label.new()
	label.text = caption
	body.add_child(label)
	var field := LineEdit.new()
	field.text = value
	body.add_child(field)
	return field


func _button(body: VBoxContainer, caption: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = caption
	button.pressed.connect(callback)
	body.add_child(button)


func _choose_file() -> void:
	var picker := FileDialog.new()
	picker.access = FileDialog.ACCESS_FILESYSTEM
	picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	picker.filters = PackedStringArray(["*.json ; MCP configuration"])
	picker.use_native_dialog = true
	add_child(picker)
	picker.file_selected.connect(func(path: String):
		_path.text = path
		bridge.reload_configuration(path)
		_refresh()
		picker.queue_free())
	picker.canceled.connect(picker.queue_free)
	picker.popup_centered(Vector2i(600, 400))


func _refresh() -> void:
	var config := bridge.preferences
	_enabled.button_pressed = config.get("enabled", false)
	_editing.button_pressed = config.get("mode", "read_only") == "edit"
	_port.value = config.get("port", 37641)
	_root.text = config.get("roots", {}).get("songs", {}).get("path", "")
	_status.text = bridge.connection_status()


func _apply(rotate: bool) -> void:
	if bridge.router.jobs.is_busy():
		bridge.status_message = "Wait for the export to finish before changing settings."
		return
	if _path.text != bridge.config_path:
		bridge.reload_configuration(_path.text)
		_refresh()
		return
	var config := bridge.preferences
	var node: String = config.get("publisher_node", "")
	var script: String = config.get("publisher_script", "").get_base_dir().path_join("configure.js")
	if node.is_empty() || not FileAccess.file_exists(script):
		bridge.status_message = "Build mcp and select a generated configuration first."
		return
	var output: Array = []
	var result := OS.execute(node, PackedStringArray([script, "--config", _path.text,
		"--root", _root.text, "--mode", "edit" if _editing.button_pressed else "read_only",
		"--port", str(int(_port.value)), "--update", "true", "--enabled",
		"true" if _enabled.button_pressed else "false", "--rotate", "true" if rotate else "false"]), output, true)
	if result != 0:
		bridge.status_message = "Settings were not saved. Check file permissions, paths and the Node installation."
		return
	Controller.settings_manager.mcp_config_path = _path.text
	Controller.settings_manager.save_settings()
	bridge.reload_configuration(_path.text)
	_refresh()


func _copy_client() -> void:
	var config := bridge.preferences
	var node: String = config.get("publisher_node", "")
	if node.is_empty(): return
	var script: String = config.get("publisher_script", "").get_base_dir().path_join("index.js")
	DisplayServer.clipboard_set(JSON.stringify({"command": node, "args": [script, "--config", bridge.config_path]}, "  "))
