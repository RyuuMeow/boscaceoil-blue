class_name ExportJobManager extends Node

const MAX_DURATION_SECONDS := 300.0
const MAX_AUDIO_BYTES := 64 * 1024 * 1024
const JOB_LIMIT := 32

var files: SongFileService
var _jobs: Dictionary = {}
var _active_id: String = ""
var _exporter: WavExporter = null
var _restore: Dictionary = {}
var _sample_bytes: int = 0
var _failure: String = ""
var _cancelled: bool = false


func _ready() -> void:
	set_process(false)


func is_busy() -> bool:
	return not _active_id.is_empty()


func start_job(params: Dictionary) -> Dictionary:
	var error := AutomationResult.fields(params, ["format", "root_id", "relative_path", "start", "end", "overwrite"], ["format", "root_id", "relative_path"])
	if not error.is_empty(): return error
	if params.format not in ["wav", "midi"]:
		return AutomationResult.failure("INVALID_ARGUMENT", "Supported export formats are wav and midi.")
	if not _active_id.is_empty() || Controller.music_player.is_exporting():
		return AutomationResult.failure("APP_BUSY", "An export is already running.")
	var song := Controller.current_song
	var start: Variant = params.get("start", song.arrangement.loop_start)
	var end: Variant = params.get("end", song.arrangement.loop_end)
	if not AutomationResult.is_integer(start, 0, song.arrangement.timeline_length - 1) || not AutomationResult.is_integer(end, 1, song.arrangement.timeline_length) || start >= end:
		return AutomationResult.failure("INVALID_ARGUMENT", "Export range must satisfy 0 <= start < end <= timeline_length.")
	var duration := (int(end) - int(start)) * song.pattern_size * 60.0 / song.bpm / 4.0
	if duration > MAX_DURATION_SECONDS:
		return AutomationResult.failure("LIMIT_EXCEEDED", "Export range exceeds five minutes.")
	var extension := "wav" if params.format == "wav" else "mid"
	var resolved := files.resolve_path(params, extension, true)
	if resolved.has("error"): return resolved
	var id := Crypto.new().generate_random_bytes(16).hex_encode()
	if _jobs.size() >= JOB_LIMIT:
		_jobs.erase(_jobs.keys()[0])
	_jobs[id] = { "job_id": id, "state": "queued", "format": params.format, "root_id": params.root_id,
		"relative_path": params.relative_path, "start": int(start), "end": int(end),
		"created_at": Time.get_unix_time_from_system(), "error": null,
		"_path": resolved.result.path, "_root": resolved.result.root,
		"_temporary": files.temporary_path(resolved.result.root, extension), "_overwrite": params.get("overwrite", false) }
	_active_id = id
	_restore = Controller.music_player.capture_transport_state()
	_restore["loop_start"] = song.arrangement.loop_start
	_restore["loop_end"] = song.arrangement.loop_end
	_sample_bytes = 0
	_failure = ""
	_cancelled = false
	Controller.music_player.stop_playback()
	Controller.lock_song_editing("MCP EXPORT IN PROGRESS")
	_begin.call_deferred(id)
	return AutomationResult.success(_public_job(id))


func get_job(params: Dictionary) -> Dictionary:
	var error := AutomationResult.fields(params, ["job_id"], ["job_id"])
	if not error.is_empty(): return error
	if not params.job_id is String || not _jobs.has(params.job_id):
		return AutomationResult.failure("NOT_FOUND", "Export job is not retained in this instance.")
	return AutomationResult.success(_public_job(params.job_id))


func cancel_job(params: Dictionary) -> Dictionary:
	var checked := get_job(params)
	if checked.has("error"): return checked
	if params.job_id != _active_id:
		return checked
	_cancelled = true
	if Controller.music_player.is_exporting():
		Controller.music_player.cancel_export()
	else:
		_finish(false)
	return AutomationResult.success(_public_job(params.job_id))


func _public_job(id: String) -> Dictionary:
	var result: Dictionary = _jobs[id].duplicate(true)
	for key: String in result.keys():
		if key.begins_with("_"): result.erase(key)
	return result


func _begin(id: String) -> void:
	if _active_id != id: return # A queued job may have been cancelled already.
	var job: Dictionary = _jobs[id]
	job.state = "running"
	job["_started_ms"] = Time.get_ticks_msec()
	var song := Controller.current_song
	if job.format == "midi":
		var config := ExportMasterPopup.ExportConfig.new()
		config.loop_start = job.start
		config.loop_end = job.end
		_finish(MidiExporter.save(song, job._temporary, config))
		return
	_exporter = WavExporter.new()
	if not _exporter.set_export_path(job._temporary):
		_failure = "Cannot create the staged WAV file."
		_finish(false)
		return
	song.arrangement.set_loop(job.start, job.end)
	song.reset_arrangement()
	Controller.music_player.export_ended.connect(_wav_ended, CONNECT_ONE_SHOT)
	Controller.music_player.start_exporting(_stream)
	set_process(true)


func _stream(event: SiONEvent) -> void:
	if _active_id.is_empty() || not _failure.is_empty() || _cancelled: return
	var buffer := event.get_stream_buffer()
	_sample_bytes += buffer.size() * 4
	if _sample_bytes > MAX_AUDIO_BYTES:
		_failure = "Rendered audio exceeded 64 MiB."
		Controller.music_player.cancel_export.call_deferred()
		return
	_exporter.append_data(buffer)


func _process(_delta: float) -> void:
	if _active_id.is_empty(): return
	var job: Dictionary = _jobs[_active_id]
	if Time.get_ticks_msec() - int(job._started_ms) > int((MAX_DURATION_SECONDS + 30.0) * 1000):
		_failure = "Audio rendering timed out."
		Controller.music_player.cancel_export()


func _wav_ended() -> void:
	_finish(not _cancelled && _failure.is_empty() && _exporter != null && _exporter.save())


func _finish(written: bool) -> void:
	if _active_id.is_empty(): return
	set_process(false)
	var job: Dictionary = _jobs[_active_id]
	var published := AutomationResult.failure("EXPORT_FAILED", "Rendering or writing the export failed.")
	if written && not _cancelled && _failure.is_empty():
		# Recheck root policy after asynchronous rendering, before publication.
		var extension := "wav" if job.format == "wav" else "mid"
		var checked := files.resolve_path({ "root_id": job.root_id, "relative_path": job.relative_path, "overwrite": job._overwrite }, extension, true)
		if checked.has("error"):
			published = checked
		elif checked.result.path != job._path:
			published = AutomationResult.failure("PATH_NOT_ALLOWED", "Export destination changed while rendering.")
		else:
			published = files.publish_file(job._temporary, job._path, job._root, job._overwrite)
	if _cancelled:
		job.state = "cancelled"
	elif not _failure.is_empty() || published.has("error"):
		job.state = "failed"
		job.error = published.error if _failure.is_empty() else { "code": "EXPORT_FAILED", "message": _failure }
	else:
		job.state = "succeeded"
		var file := FileAccess.open(job._path, FileAccess.READ)
		job["size"] = file.get_length() if file else null
	if FileAccess.file_exists(job._temporary):
		DirAccess.remove_absolute(job._temporary)
	job["finished_at"] = Time.get_unix_time_from_system()
	if Controller.music_player.export_ended.is_connected(_wav_ended):
		Controller.music_player.export_ended.disconnect(_wav_ended)
	Controller.current_song.arrangement.set_loop(_restore.loop_start, _restore.loop_end)
	Controller.music_player.restore_transport_state(_restore)
	Controller.unlock_song_editing()
	_exporter = null
	_active_id = ""
	_restore.clear()


func _exit_tree() -> void:
	if not _active_id.is_empty():
		_cancelled = true
		if Controller.music_player.is_exporting():
			Controller.music_player.cancel_export()
		else:
			_finish(false)
