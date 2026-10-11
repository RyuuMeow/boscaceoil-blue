class_name AutomationBridge extends Node

const MAX_MESSAGE_BYTES := 1048576
const MAX_BUFFER_BYTES := MAX_MESSAGE_BYTES * 2
const MAX_MESSAGES_PER_FRAME := 8
const AUTH_TIMEOUT_MS := 3000

var router := AutomationRouter.new()
var _server := TCPServer.new()
var _peer: StreamPeerTCP = null
var _input := PackedByteArray()
var _output := PackedByteArray()
var _authenticated: bool = false
var _accepted_at: int = 0
var _token: String = ""
var config_path: String = ""
var status_message: String = "Disabled"
var preferences: Dictionary = {}


func _ready() -> void:
	router.initialize()
	router.jobs = ExportJobManager.new()
	router.jobs.files = router.files
	add_child(router.jobs)
	set_process(false)
	if OS.has_feature("web"):
		return
	config_path = OS.get_environment("BOSCA_MCP_CONFIG")
	if config_path.is_empty():
		config_path = Controller.settings_manager.mcp_config_path
	if config_path.is_empty() && OS.has_feature("windows") && not OS.has_feature("editor"):
		var installed_config := OS.get_environment("LOCALAPPDATA").path_join("BoscaCeoilBlueMCP/mcp.json")
		if FileAccess.file_exists(installed_config):
			config_path = installed_config
	reload_configuration(config_path)


func reload_configuration(path: String) -> void:
	if router.jobs && router.jobs.is_busy():
		status_message = "Wait for the export to finish before changing MCP settings."
		return
	_disconnect()
	_server.stop()
	set_process(false)
	_token = ""
	preferences = {}
	config_path = path
	status_message = "Disabled"
	if config_path.is_empty():
		return
	var file := FileAccess.open(config_path, FileAccess.READ)
	if not file || file.get_length() > 65536:
		status_message = "Cannot read configuration."
		return
	var config: Variant = JSON.parse_string(file.get_as_text())
	if not config is Dictionary:
		status_message = "Invalid configuration JSON."
		return
	preferences = config.duplicate(true)
	preferences.erase("token")
	if config.get("enabled", false) != true:
		return
	if not config.get("token") is String || config.token.length() < 32 || config.token.length() > 256:
		status_message = "Token must contain 32 to 256 characters."
		return
	if not AutomationResult.is_integer(config.get("port", 37641), 1024, 65535):
		status_message = "Invalid port."
		return
	_token = config.token
	router.allow_editing = config.get("mode", "read_only") == "edit"
	router.files.configure(config)
	var error := _server.listen(int(config.get("port", 37641)), "127.0.0.1")
	if error != OK:
		status_message = "Loopback port unavailable (code %d)." % error
		return
	set_process(true)
	status_message = "Listening on 127.0.0.1:%d" % int(config.get("port", 37641))


func disconnect_client() -> void:
	_disconnect()


func connection_status() -> String:
	return status_message + (" / Client connected" if _authenticated else " / No client")


func _exit_tree() -> void:
	_disconnect()
	_server.stop()


func _disconnect() -> void:
	if _peer:
		_peer.disconnect_from_host()
	_peer = null
	_authenticated = false
	_input.clear()
	_output.clear()


func _process(_delta: float) -> void:
	if _server.is_connection_available():
		var incoming := _server.take_connection()
		if _peer:
			incoming.disconnect_from_host()
		else:
			_peer = incoming
			_accepted_at = Time.get_ticks_msec()
	if not _peer:
		return
	_peer.poll()
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_disconnect()
		return
	if not _authenticated && Time.get_ticks_msec() - _accepted_at > AUTH_TIMEOUT_MS:
		_disconnect()
		return
	var available := mini(_peer.get_available_bytes(), 65536)
	if available > 0:
		var received := _peer.get_partial_data(available)
		if received[0] != OK:
			_disconnect()
			return
		_input.append_array(received[1])
	if _input.size() > MAX_BUFFER_BYTES:
		_disconnect()
		return
	for _i in MAX_MESSAGES_PER_FRAME:
		var newline := _input.find(10)
		if newline == -1:
			if _input.size() > MAX_MESSAGE_BYTES:
				_disconnect()
			break
		if newline > MAX_MESSAGE_BYTES:
			_disconnect()
			return
		var line := _input.slice(0, newline)
		_input = _input.slice(newline + 1)
		_handle_line(line)
		if not _peer:
			return
	if not _output.is_empty():
		var sent := _peer.put_partial_data(_output.slice(0, 65536))
		if sent[0] != OK:
			_disconnect()
			return
		_output = _output.slice(int(sent[1]))


func _handle_line(line: PackedByteArray) -> void:
	var parser := JSON.new()
	if parser.parse(line.get_string_from_utf8()) != OK || not parser.data is Dictionary:
		_disconnect()
		return
	var request: Dictionary = parser.data
	if not request.get("id") is String || request.id.length() > 128 || not request.get("method") is String || not request.get("params", {}) is Dictionary:
		_disconnect()
		return
	var params: Dictionary = request.get("params", {})
	var response: Dictionary
	if not _authenticated:
		if request.method != "hello" || params.get("token") != _token:
			_disconnect()
			return
		if params.get("bridge_version") != 1:
			response = AutomationResult.failure("UNSUPPORTED_VERSION", "Bridge version 1 is required.")
		else:
			_authenticated = true
			response = AutomationResult.success({ "bridge_version": 1, "instance_id": router.instance_id, "max_message_bytes": MAX_MESSAGE_BYTES })
	else:
		response = router.dispatch(request.method, params)
	response["id"] = request.id
	_output.append_array((JSON.stringify(response) + "\n").to_utf8_buffer())
	if _output.size() > MAX_BUFFER_BYTES:
		_disconnect()
