extends Node

var _failures: int = 0
var _checks: int = 0
var _router: AutomationRouter


func _ready() -> void:
	_run.call_deferred()


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("FAIL: " + label)


func _edit(method: String, args: Dictionary = {}) -> Dictionary:
	args.merge({ "instance_id": _router.instance_id, "song_id": _router.song_id,
		"expected_revision": _router.revision, "operation_id": Crypto.new().generate_random_bytes(16).hex_encode() })
	return _router.dispatch(method, args)


func _run() -> void:
	Controller.set_current_song(Song.create_default_song(), false)
	_router = AutomationRouter.new()
	_router.initialize()
	var status := _router.dispatch("bosca_status", {})
	_check(status.result.mode == "read_only", "read-only default")
	_check(_edit("bosca_song_update", { "bpm": 100 }).error.code == "READ_ONLY", "read-only rejects write")
	_router.allow_editing = true
	var initial_revision := _router.revision
	_check(_router.dispatch("bosca_pattern_get", { "pattern_index": -1 }).has("error"), "negative index rejected")
	_check(_router.dispatch("bosca_pattern_get", { "pattern_index": 0.5 }).has("error"), "fractional index rejected")
	_check(_router.dispatch("bosca_song_get", { "unknown": 1 }).has("error"), "unknown field rejected")
	_check(_router.revision == initial_revision && not Controller.current_song.is_dirty(), "queries leave song clean")
	var catalog := _router.dispatch("bosca_catalog_list", { "limit": 200 })
	_check(catalog.result.items.size() == 200 && catalog.result.next_cursor == 200, "catalog pagination")
	var changed := _edit("bosca_song_update", { "bpm": 100, "swing": 2 })
	_check(changed.result.revision_after == initial_revision + 1, "one compound edit increments revision once")
	_check(Controller.current_song.bpm == 100 && Controller.current_song.swing == 2, "compound song edit")
	_edit("bosca_history_step", { "action": "undo" })
	_check(Controller.current_song.bpm == 120 && Controller.current_song.swing == 0, "one undo restores both properties")
	_edit("bosca_history_step", { "action": "redo" })
	_check(Controller.current_song.bpm == 100, "redo reapplies properties")
	var no_change_revision := _router.revision
	_edit("bosca_song_update", { "bpm": 100 })
	_check(_router.revision == no_change_revision, "no-op creates no history")
	var notes := [{ "pitch": 60, "position": 0, "length": 2 }, { "pitch": 64, "position": 4, "length": 128 }]
	_check(_edit("bosca_notes_set", { "pattern_index": 0, "mode": "replace", "notes": notes }).has("result"), "batch notes accepted")
	_check(Controller.current_song.patterns[0].note_amount == 2, "batch committed all notes")
	var note_revision := _router.revision
	var invalid := notes.duplicate(true)
	invalid.append({ "pitch": 67, "position": 16, "length": 1 })
	_check(_edit("bosca_notes_set", { "pattern_index": 0, "mode": "replace", "notes": invalid }).has("error"), "invalid note rejects batch")
	_check(_router.revision == note_revision && Controller.current_song.patterns[0].note_amount == 2, "invalid batch has no side effects")
	_check(_edit("bosca_song_update", { "pattern_size": 4 }).error.code == "WOULD_DROP_NOTES", "shrinking pattern rejects hidden notes")
	_edit("bosca_history_step", { "action": "undo" })
	_check(Controller.current_song.patterns[0].note_amount == 0, "one undo removes whole note batch")
	_edit("bosca_history_step", { "action": "redo" })
	_check(Controller.current_song.patterns[0].note_amount == 2, "redo restores whole note batch")
	var retry_args := { "instance_id": _router.instance_id, "song_id": _router.song_id,
		"expected_revision": _router.revision, "operation_id": "dedup-test", "bpm": 110 }
	var first := _router.dispatch("bosca_song_update", retry_args)
	var replay := _router.dispatch("bosca_song_update", retry_args)
	_check(first == replay, "same operation is replayed without another commit")
	var changed_args := retry_args.duplicate(true)
	changed_args.bpm = 111
	_check(_router.dispatch("bosca_song_update", changed_args).error.code == "INVALID_ARGUMENT", "operation reuse with changed payload rejected")
	changed_args.operation_id = "stale-test"
	_check(_router.dispatch("bosca_song_update", changed_args).error.code == "REVISION_CONFLICT", "stale revision rejected")
	var prior := _router.revision
	Controller.set_song_bpm(112)
	_check(_router.revision == prior + 1, "UI command updates same revision")
	_edit("bosca_pattern_clone", { "pattern_index": 0 })
	var cells: Array[Dictionary] = []
	for bar in 8:
		cells.append({ "bar": bar, "channel": 0, "pattern_index": 0 })
		cells.append({ "bar": bar, "channel": 1, "pattern_index": 1 })
	_check(_edit("bosca_arrangement_set", { "cells": cells }).has("result"), "8-bar arrangement committed")
	_check(Controller.current_song.arrangement.timeline_length == 8, "timeline grows")
	_edit("bosca_loop_set", { "start": 0, "end": 8 })
	_check(Controller.current_song.arrangement.loop_end == 8, "exclusive loop end")
	Controller.edit_pattern(1)
	_edit("bosca_pattern_delete", { "pattern_index": 0 })
	_check(Controller.current_song.patterns.size() == 1 && Controller.current_song.arrangement.timeline_bars[7][1] == 0, "delete remaps references")
	_check(Controller.current_song.arrangement.timeline_bars[7][0] == -1 && Controller.current_pattern_index == 0, "delete clears cells and selection")
	_edit("bosca_history_step", { "action": "undo" })
	_check(Controller.current_song.patterns.size() == 2 && Controller.current_pattern_index == 1, "undo deletion restores selection")
	_check(Controller.current_song.arrangement.timeline_bars[7][1] == 1, "undo deletion restores references")
	_check(_edit("bosca_song_new").error.code == "UNSAVED_CHANGES", "new song guards dirty state")
	var old_song_id := _router.song_id
	_edit("bosca_song_new", { "discard_unsaved": true })
	_check(_router.song_id != old_song_id && not Controller.music_player.is_playing(), "new song changes identity without autoplay")
	_edit("bosca_pattern_delete", { "pattern_index": 0 })
	_check(Controller.current_song.patterns.size() == 1, "deleting last pattern retains valid song")
	_edit("bosca_history_step", { "action": "undo" })
	_check(Controller.current_song.arrangement.timeline_bars[0][0] == 0, "last-pattern undo restores arrangement")
	_test_files()
	Controller.music_player.stop_playback()
	print("AUTOMATION_TESTS: %d checks, %d failures" % [_checks, _failures])
	get_tree().quit(1 if _failures else 0)


func _test_files() -> void:
	var root := OS.get_environment("BOSCA_MCP_TEST_ROOT").replace("\\", "/")
	if root.is_empty():
		_check(false, "BOSCA_MCP_TEST_ROOT is required for file tests")
		return
	_router.files.configure({ "roots": { "songs": { "path": root, "read": true, "write": true } },
		"publisher_node": OS.get_environment("BOSCA_MCP_TEST_NODE"),
		"publisher_script": ProjectSettings.globalize_path("res://mcp/dist/publish.js") })
	var filename := "test-" + Crypto.new().generate_random_bytes(8).hex_encode() + ".ceol"
	var saved := _edit("bosca_song_save", { "root_id": "songs", "relative_path": filename })
	_check(saved.has("result"), "save publishes CEOL")
	if saved.has("error"):
		printerr(JSON.stringify(saved))
		return
	_check(not Controller.current_song.is_dirty(), "successful save marks clean")
	_check(Controller.current_song.filename == root.path_join(filename), "save uses final path, not temporary path")
	var contents := FileAccess.get_file_as_string(root.path_join(filename))
	_check(SongFileValidator.validate_text(contents).is_empty(), "saved v3 validates")
	var original_revision := _router.revision
	var exists := _edit("bosca_song_save", { "root_id": "songs", "relative_path": filename })
	_check(exists.has("error") && exists.error.code == "FILE_EXISTS", "save does not overwrite by default")
	_check(_router.revision == original_revision, "failed save does not change revision")
	_check(FileAccess.get_file_as_string(root.path_join(filename)) == contents, "failed save leaves original untouched")
	_edit("bosca_song_update", { "bpm": 140 })
	_check(_edit("bosca_song_save", { "root_id": "songs", "relative_path": filename, "overwrite": true }).has("result"), "explicit overwrite succeeds")
	_check(_edit("bosca_song_open", { "root_id": "songs", "relative_path": filename }).has("result"), "validated CEOL reload succeeds")
	_check(Controller.current_song.bpm == 140 && not Controller.music_player.is_playing(), "reload preserves song and does not autoplay")
	for bad_path in ["../outside.ceol", "sub/song.ceol", "C:/outside.ceol", "song.ceol:stream", "CON.ceol", "song.wav"]:
		_check(_edit("bosca_song_save", { "root_id": "songs", "relative_path": bad_path }).has("error"), "unsafe path rejected: " + bad_path)
	_check(SongFileValidator.validate_text("3,0,0,0,120,16,4,99999999,").has("error"), "huge instrument count rejected before loading")
	_check(SongFileValidator.validate_text(contents.substr(0, contents.length() - 8)).has("error"), "truncated document rejected")
	_check(SongFileValidator.validate_text(contents + "garbage").has("error"), "trailing garbage rejected")
	var v1 := "1,120,16,4,1,0,0,0,128,0,1,0,0,0,0,0,0,1,0,1,0,-1,-1,-1,-1,-1,-1,-1,"
	var v2 := "2,0,120,16,4,1,0,0,0,128,0,256,1,0,0,0,0,0,0,1,0,1,0,-1,-1,-1,-1,-1,-1,-1,"
	_check(SongFileValidator.validate_text(v1).is_empty(), "legacy v1 validates")
	_check(SongFileValidator.validate_text(v2).is_empty(), "legacy v2 validates")
	_check(SongLoader.load_text(v1).bpm == 120, "legacy v1 parses")
	_check(SongLoader.load_text(v2).bpm == 120, "legacy v2 parses")
	DirAccess.remove_absolute(root.path_join(filename))
