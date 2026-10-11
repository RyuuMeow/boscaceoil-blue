## Dialog-free file operations restricted to explicit roots and plain filenames.
class_name SongFileService extends RefCounted

var roots: Dictionary = {}
var publisher_node: String = ""
var publisher_script: String = ""


func configure(config: Dictionary) -> void:
	roots = config.get("roots", {}) if config.get("roots", {}) is Dictionary else {}
	publisher_node = config.get("publisher_node", "") if config.get("publisher_node", "") is String else ""
	publisher_script = config.get("publisher_script", "") if config.get("publisher_script", "") is String else ""


func root_summary() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for id: String in roots:
		if roots[id] is Dictionary:
			result.append({ "root_id": id, "read": roots[id].get("read", false), "write": roots[id].get("write", false) })
	return result


func resolve_path(params: Dictionary, extension: String, writing: bool) -> Dictionary:
	if not params.get("root_id") is String || not roots.has(params.root_id) || not roots[params.root_id] is Dictionary || not params.get("relative_path") is String:
		return AutomationResult.failure("PATH_NOT_ALLOWED", "Select a configured root and a plain filename.")
	var config: Dictionary = roots[params.root_id]
	if config.get("write" if writing else "read", false) != true || not config.get("path") is String:
		return AutomationResult.failure("PATH_NOT_ALLOWED", "The configured root does not permit this operation.")
	var name_: String = params.relative_path
	if name_.is_empty() || name_.length() > 128 || not name_.is_valid_filename() || name_.get_file() != name_ || name_.begins_with(".") || name_.ends_with(" ") || name_.ends_with(".") || name_.get_extension() != extension:
		return AutomationResult.failure("PATH_NOT_ALLOWED", "Use a plain filename with the required extension; subdirectories are not supported.")
	var base := name_.get_basename().to_upper().split(".")[0]
	if base in ["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"]:
		return AutomationResult.failure("PATH_NOT_ALLOWED", "Reserved filenames are not permitted.")
	var root: String = config.path.replace("\\", "/")
	if not root.is_absolute_path() || root.begins_with("//") || root.contains("://") || root != root.simplify_path():
		return AutomationResult.failure("PATH_NOT_ALLOWED", "The root must be a normalized local absolute path.")
	var current := root.trim_suffix("/")
	while not current.is_empty() && current != current.get_base_dir():
		var parent := current.get_base_dir()
		var directory := DirAccess.open(parent)
		if not directory || directory.is_link(current):
			return AutomationResult.failure("PATH_NOT_ALLOWED", "Linked roots or inaccessible parent directories are not allowed.")
		current = parent
	var directory := DirAccess.open(root)
	if not directory:
		return AutomationResult.failure("PATH_NOT_ALLOWED", "The root directory is unavailable.")
	var path := root.path_join(name_)
	if directory.is_link(name_) || directory.dir_exists(name_):
		return AutomationResult.failure("PATH_NOT_ALLOWED", "The target must be a regular file, not a link or directory.")
	if writing:
		if not params.get("overwrite", false) is bool:
			return AutomationResult.failure("INVALID_ARGUMENT", "overwrite must be a boolean.")
		if FileAccess.file_exists(path) && not params.get("overwrite", false):
			return AutomationResult.failure("FILE_EXISTS", "The target already exists; choose a new name or explicitly allow overwrite.")
		if not publisher_node.is_absolute_path() || not publisher_script.is_absolute_path() || not FileAccess.file_exists(publisher_node) || not FileAccess.file_exists(publisher_script):
			return AutomationResult.failure("NOT_READY", "Configure the installed MCP file publisher before writing files.")
	return AutomationResult.success({ "path": path, "root": root })


func temporary_path(root: String, extension: String) -> String:
	return root.path_join(".bosca-" + Crypto.new().generate_random_bytes(16).hex_encode() + "." + extension)


func publish_file(temporary: String, destination: String, root: String, overwrite: bool) -> Dictionary:
	var output: Array = []
	var code := OS.execute(publisher_node, [publisher_script, temporary, destination, root, "true" if overwrite else "false"], output, false, false)
	var response: Variant = JSON.parse_string("".join(output))
	if code != 0 || not response is Dictionary || response.get("code") != "OK":
		var error_code: String = response.get("code", "IO_FAILED") if response is Dictionary else "IO_FAILED"
		return AutomationResult.failure(error_code, "Could not publish the file. The existing destination was preserved.")
	return AutomationResult.success({})


func save_song(params: Dictionary) -> Dictionary:
	var error := AutomationResult.fields(params, ["root_id", "relative_path", "overwrite"], ["root_id", "relative_path"])
	if not error.is_empty(): return error
	var resolved := resolve_path(params, "ceol", true)
	if resolved.has("error"): return resolved
	var temporary := temporary_path(resolved.result.root, "ceol")
	if not SongSaver.save(Controller.current_song, temporary, false):
		DirAccess.remove_absolute(temporary)
		return AutomationResult.failure("IO_FAILED", "Could not write the staged song; the original file is unchanged.")
	var published := publish_file(temporary, resolved.result.path, resolved.result.root, params.get("overwrite", false))
	if published.has("error"):
		DirAccess.remove_absolute(temporary)
		return published
	Controller.current_song.filename = resolved.result.path
	Controller.current_song.format_version = Song.FILE_FORMAT
	Controller.mark_song_saved()
	var saved := FileAccess.open(resolved.result.path, FileAccess.READ)
	return AutomationResult.success({ "changed": false, "saved": true, "root_id": params.root_id,
		"relative_path": params.relative_path, "size": saved.get_length() if saved else null })


func open_song(params: Dictionary) -> Dictionary:
	var error := AutomationResult.fields(params, ["root_id", "relative_path", "discard_unsaved"], ["root_id", "relative_path"])
	if not error.is_empty(): return error
	if not params.get("discard_unsaved", false) is bool:
		return AutomationResult.failure("INVALID_ARGUMENT", "discard_unsaved must be a boolean.")
	if Controller.current_song && Controller.current_song.is_dirty() && not params.get("discard_unsaved", false):
		return AutomationResult.failure("UNSAVED_CHANGES", "Save or explicitly discard the current song before opening another.")
	var resolved := resolve_path(params, "ceol", false)
	if resolved.has("error"): return resolved
	var file := FileAccess.open(resolved.result.path, FileAccess.READ)
	if not file:
		return AutomationResult.failure("IO_FAILED", "Cannot read the song file.")
	if file.get_length() > 16777216:
		return AutomationResult.failure("LIMIT_EXCEEDED", "Song files are limited to 16 MiB.")
	var contents := file.get_as_text()
	error = SongFileValidator.validate_text(contents)
	if not error.is_empty(): return error
	var song := SongLoader.load_text(contents, resolved.result.path)
	if not song || not song.is_valid_song():
		return AutomationResult.failure("INVALID_ARGUMENT", "The song could not be loaded.")
	if song.arrangement.timeline_length == 0:
		song.arrangement.timeline_length = 1
	Controller.music_player.stop_playback()
	Controller.set_current_song(song, false)
	return AutomationResult.success({ "changed": true, "playing": false })
