class_name AutomationRouter extends RefCounted

var instance_id: String = Crypto.new().generate_random_bytes(16).hex_encode()
var song_id: String = ""
var revision: int = 0
var allow_editing: bool = false
var files := SongFileService.new()
var jobs: ExportJobManager = null
var _query := SongQueryService.new()
var _operations: Dictionary = {}

const MUTATIONS := ["bosca_song_new", "bosca_song_update", "bosca_instrument_create", "bosca_instrument_update",
	"bosca_pattern_create", "bosca_pattern_clone", "bosca_pattern_delete", "bosca_notes_set",
	"bosca_arrangement_set", "bosca_loop_set", "bosca_playback_set", "bosca_history_step",
	"bosca_song_save", "bosca_song_open", "bosca_export_start", "bosca_job_cancel"]


func initialize() -> void:
	Controller.song_loaded.connect(_song_loaded)
	Controller.state_manager.state_changed.connect(_state_changed)
	Controller.song_saved.connect(_state_changed)
	if Controller.current_song:
		_song_loaded()


func _song_loaded() -> void:
	song_id = Crypto.new().generate_random_bytes(16).hex_encode()
	revision = 0


func _state_changed() -> void:
	revision += 1


func dispatch(method: String, params: Dictionary) -> Dictionary:
	var result: Dictionary
	match method:
		"bosca_status":
			result = AutomationResult.fields(params, [])
			if result.is_empty():
				result = AutomationResult.success({ "app_version": ProjectSettings.get_setting("application/config/version"),
					"bridge_version": 1, "mode": "edit" if allow_editing else "read_only", "busy": Controller.is_song_editing_locked(),
					"ready": Controller.current_song != null, "limits": SongQueryService.LIMITS,
					"roots": files.root_summary(),
					"playing": Controller.music_player.is_playing(),
					"can_undo": Controller.state_manager.can_undo(), "can_redo": Controller.state_manager.can_redo(),
					"current_bar": Controller.current_song.arrangement.current_bar_idx if Controller.current_song else null })
		"bosca_catalog_list":
			result = _catalog(params)
		"bosca_operation_get":
			result = _operation_get(params)
		"bosca_job_get":
			result = jobs.get_job(params) if jobs else AutomationResult.failure("NOT_READY", "Export manager is not initialized.")
		"bosca_song_get", "bosca_pattern_get", "bosca_arrangement_get":
			if not Controller.current_song:
				return AutomationResult.failure("NO_SONG", "No song is open.")
			result = _song_query(method, params)
		_:
			if method in MUTATIONS:
				return _mutation(method, params)
			return AutomationResult.failure("NOT_FOUND", "Unknown automation method.")
	if result.has("result"):
		result.result.merge({ "instance_id": instance_id, "song_id": song_id, "revision": revision })
	return result


func _expire_operations() -> void:
	var now := Time.get_ticks_msec()
	for id: String in _operations.keys():
		if now - int(_operations[id].time) > 600000:
			_operations.erase(id)


func _operation_get(params: Dictionary) -> Dictionary:
	var error := AutomationResult.fields(params, ["instance_id", "operation_id"], ["instance_id", "operation_id"])
	if not error.is_empty():
		return error
	_expire_operations()
	if params.instance_id != instance_id || not params.operation_id is String || not _operations.has(params.operation_id):
		return AutomationResult.failure("OUTCOME_UNKNOWN", "Operation is not retained in this instance. Read current state before retrying.")
	return AutomationResult.success({ "operation_id": params.operation_id, "outcome": _operations[params.operation_id].response.duplicate(true) })


func _mutation(method: String, params: Dictionary) -> Dictionary:
	if not allow_editing:
		return AutomationResult.failure("READ_ONLY", "Enable editing in the local Bosca MCP configuration first.")
	for key in ["instance_id", "song_id", "operation_id"]:
		if not params.get(key) is String || params[key].is_empty() || params[key].length() > 128:
			return AutomationResult.failure("INVALID_ARGUMENT", "A session identity or operation ID is missing.", { "field": key })
	if not AutomationResult.is_integer(params.get("expected_revision"), 0, 9007199254740991):
		return AutomationResult.failure("INVALID_ARGUMENT", "expected_revision must be a nonnegative safe integer.")
	if params.instance_id != instance_id:
		return AutomationResult.failure("REVISION_CONFLICT", "The application instance changed. Read status again.")
	_expire_operations()
	var operation_id: String = params.operation_id
	var fingerprint := (method + JSON.stringify(params)).sha256_text()
	if _operations.has(operation_id):
		if _operations[operation_id].fingerprint != fingerprint:
			return AutomationResult.failure("INVALID_ARGUMENT", "operation_id was already used for different arguments.")
		return _operations[operation_id].response.duplicate(true)
	if not Controller.current_song:
		return AutomationResult.failure("NO_SONG", "No song is open.")
	if params.song_id != song_id || params.expected_revision != revision:
		return AutomationResult.failure("REVISION_CONFLICT", "The song changed. Read the current state before editing.", { "song_id": song_id, "current_revision": revision })
	if Controller.is_song_editing_locked() && method != "bosca_job_cancel":
		return AutomationResult.failure("APP_BUSY", "The editor is busy.")
	var before := revision
	var arguments := params.duplicate(true)
	for key in ["instance_id", "song_id", "expected_revision", "operation_id"]:
		arguments.erase(key)
	var response := _execute_mutation(method, arguments)
	if response.has("result"):
		response.result.merge({ "instance_id": instance_id, "song_id": song_id, "revision": revision,
			"revision_before": before, "revision_after": revision, "operation_id": operation_id })
	if _operations.size() >= 256:
		_operations.erase(_operations.keys()[0])
	_operations[operation_id] = { "fingerprint": fingerprint, "time": Time.get_ticks_msec(), "response": response.duplicate(true) }
	return response


func _execute_mutation(method: String, params: Dictionary) -> Dictionary:
	match method:
		"bosca_export_start":
			return jobs.start_job(params) if jobs else AutomationResult.failure("NOT_READY", "Export manager is not initialized.")
		"bosca_job_cancel":
			return jobs.cancel_job(params) if jobs else AutomationResult.failure("NOT_READY", "Export manager is not initialized.")
		"bosca_song_save": return files.save_song(params)
		"bosca_song_open": return files.open_song(params)
		"bosca_song_update": return SongEditService.update_song(params)
		"bosca_instrument_create": return SongEditService.create_instrument(params)
		"bosca_instrument_update": return SongEditService.update_instrument(params)
		"bosca_pattern_create": return SongEditService.create_pattern(params)
		"bosca_pattern_clone": return SongEditService.create_pattern(params, true)
		"bosca_pattern_delete": return SongEditService.delete_pattern(params)
		"bosca_notes_set": return SongEditService.notes_set(params)
		"bosca_arrangement_set": return SongEditService.arrangement_set(params)
		"bosca_loop_set": return SongEditService.loop_set(params)
		"bosca_song_new":
			var error := AutomationResult.fields(params, ["discard_unsaved"])
			if not error.is_empty(): return error
			if not params.get("discard_unsaved", false) is bool:
				return AutomationResult.failure("INVALID_ARGUMENT", "discard_unsaved must be a boolean.")
			if Controller.current_song.is_dirty() && not params.get("discard_unsaved", false):
				return AutomationResult.failure("UNSAVED_CHANGES", "Save the current song or explicitly discard it before creating a new one.")
			Controller.music_player.stop_playback()
			Controller.set_current_song(Song.create_default_song(), false)
			return AutomationResult.success({ "changed": true, "playing": false })
		"bosca_playback_set", "bosca_history_step":
			var error := AutomationResult.fields(params, ["action"], ["action"])
			if not error.is_empty(): return error
			if method == "bosca_playback_set":
				match params.action:
					"play": Controller.music_player.start_playback()
					"pause": Controller.music_player.pause_playback()
					"stop": Controller.music_player.stop_playback()
					_: return AutomationResult.failure("INVALID_ARGUMENT", "Expected play, pause or stop.")
				return AutomationResult.success({ "changed": false, "playing": Controller.music_player.is_playing() })
			if params.action not in ["undo", "redo"]:
				return AutomationResult.failure("INVALID_ARGUMENT", "Expected undo or redo.")
			if params.action == "undo":
				if not Controller.state_manager.can_undo(): return AutomationResult.failure("NO_HISTORY", "Nothing to undo.")
				Controller.state_manager.undo_state_change()
			else:
				if not Controller.state_manager.can_redo(): return AutomationResult.failure("NO_HISTORY", "Nothing to redo.")
				Controller.state_manager.do_state_change()
			return AutomationResult.success({ "changed": true })
	return AutomationResult.failure("NOT_FOUND", "Unknown editing method.")


func _song_query(method: String, params: Dictionary) -> Dictionary:
	if method == "bosca_song_get":
		var error := AutomationResult.fields(params, [])
		return AutomationResult.success(_query.song_summary()) if error.is_empty() else error
	if method == "bosca_pattern_get":
		var error := AutomationResult.fields(params, ["pattern_index"], ["pattern_index"])
		if not error.is_empty():
			return error
		if not AutomationResult.is_integer(params.pattern_index, 0, Controller.current_song.patterns.size() - 1):
			return AutomationResult.failure("INVALID_ARGUMENT", "Pattern index is out of range.")
		return AutomationResult.success(_query.pattern_data(int(params.pattern_index)))
	var error := AutomationResult.fields(params, ["start", "count"])
	if not error.is_empty():
		return error
	var start: Variant = params.get("start", 0)
	var count: Variant = params.get("count", 16)
	if not AutomationResult.is_integer(start, 0, Arrangement.BAR_NUMBER - 1) || not AutomationResult.is_integer(count, 1, 128):
		return AutomationResult.failure("INVALID_ARGUMENT", "Invalid arrangement range.")
	return AutomationResult.success(_query.arrangement_data(int(start), int(count)))


func _catalog(params: Dictionary) -> Dictionary:
	var error := AutomationResult.fields(params, ["kind", "filter", "cursor", "limit"])
	if not error.is_empty():
		return error
	var kind: Variant = params.get("kind", "voices")
	var filter_text: Variant = params.get("filter", "")
	var cursor: Variant = params.get("cursor", 0)
	var limit: Variant = params.get("limit", 50)
	if kind not in ["voices", "scales", "effects"] || not filter_text is String || filter_text.length() > 128:
		return AutomationResult.failure("INVALID_ARGUMENT", "Invalid catalog kind or filter.")
	if not AutomationResult.is_integer(cursor, 0, 10000) || not AutomationResult.is_integer(limit, 1, 200):
		return AutomationResult.failure("INVALID_ARGUMENT", "Invalid catalog page.")
	return AutomationResult.success(_query.catalog(kind, filter_text, int(cursor), int(limit)))
