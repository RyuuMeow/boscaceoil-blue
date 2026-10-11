## Synchronous domain commands: validate the whole change before recording history.
class_name SongEditService extends RefCounted


static func _changed(data: Dictionary = {}) -> Dictionary:
	data["changed"] = true
	return AutomationResult.success(data)


static func _unchanged() -> Dictionary:
	return AutomationResult.success({ "changed": false })


static func update_song(params: Dictionary, accumulation_id: String = "") -> Dictionary:
	var ranges := { "bpm": Vector2i(Song.MIN_BPM, Song.MAX_BPM), "pattern_size": Vector2i(1, Song.MAX_PATTERN_SIZE),
		"bar_size": Vector2i(1, Song.MAX_PATTERN_SIZE), "swing": Vector2i(-10, 10),
		"global_effect": Vector2i(0, Effect.MAX - 1), "global_effect_power": Vector2i(0, 130) }
	var error := AutomationResult.fields(params, ranges.keys())
	if not error.is_empty():
		return error
	var song := Controller.current_song
	var changes: Dictionary = {}
	for key: String in params:
		var bounds: Vector2i = ranges[key]
		if not AutomationResult.is_integer(params[key], bounds.x, bounds.y):
			return AutomationResult.failure("INVALID_ARGUMENT", "Song setting is out of range.", { "field": key })
		if song.get(key) != params[key]:
			changes[key] = int(params[key])
	if changes.has("pattern_size") && changes.pattern_size < song.pattern_size:
		for pattern in song.patterns:
			for i in pattern.note_amount:
				if pattern.notes[i].y >= changes.pattern_size:
					return AutomationResult.failure("WOULD_DROP_NOTES", "Shortening the pattern would hide notes. Remove them explicitly first.")
	if changes.is_empty():
		return _unchanged()
	var state := Controller.state_manager.create_state_change(StateManager.StateChangeType.SONG, -1, accumulation_id)
	for key: String in changes:
		state.add_property(song, key, changes[key])
	state.add_action(func() -> void:
		if changes.has("pattern_size") || changes.has("bar_size"):
			Controller.song_sizes_changed.emit()
		if changes.has("bpm"):
			Controller.music_player.update_driver_bpm()
			Controller.song_bpm_changed.emit()
		if changes.has("swing"):
			Controller.song_swing_changed.emit()
		if changes.has("global_effect") || changes.has("global_effect_power"):
			Controller.music_player.update_driver_effects()
			Controller.song_effect_changed.emit()
	)
	Controller.state_manager.commit_state_change(state)
	return _changed()


static func create_instrument(params: Dictionary) -> Dictionary:
	var error := AutomationResult.fields(params, ["voice_id"], ["voice_id"])
	if not error.is_empty():
		return error
	if not AutomationResult.is_integer(params.voice_id, 0, Controller.voice_manager.get_voice_count() - 1):
		return AutomationResult.failure("INVALID_ARGUMENT", "Unknown voice_id. Read the voice catalog first.")
	var song := Controller.current_song
	if song.instruments.size() >= Song.MAX_INSTRUMENT_COUNT:
		return AutomationResult.failure("LIMIT_EXCEEDED", "The song already has 16 instruments.")
	var index := song.instruments.size()
	var instrument := Controller.instance_instrument_by_voice(Controller.voice_manager.get_voice_data_at(int(params.voice_id)))
	var state := Controller.state_manager.create_state_change(StateManager.StateChangeType.SONG)
	state.add_do_action(func() -> void:
		song.add_instrument(instrument)
		Controller.song_instrument_created.emit()
	)
	state.add_undo_action(func() -> void:
		Controller.delete_instrument_nocheck(index)
		Controller.song_instrument_changed.emit()
	)
	Controller.state_manager.commit_state_change(state)
	return _changed({ "instrument_index": index })


static func update_instrument(params: Dictionary) -> Dictionary:
	var error := AutomationResult.fields(params, ["instrument_index", "voice_id", "volume", "cutoff", "resonance"], ["instrument_index"])
	if not error.is_empty():
		return error
	var song := Controller.current_song
	if not AutomationResult.is_integer(params.instrument_index, 0, song.instruments.size() - 1):
		return AutomationResult.failure("INVALID_ARGUMENT", "Invalid instrument index.")
	var index := int(params.instrument_index)
	var before := song.instruments[index]
	var ranges := { "voice_id": Controller.voice_manager.get_voice_count() - 1,
		"volume": Instrument.MAX_VOLUME, "cutoff": Instrument.MAX_FILTER_CUTOFF, "resonance": Instrument.MAX_FILTER_RESONANCE }
	for key: String in ranges:
		if params.has(key) && not AutomationResult.is_integer(params[key], 0, ranges[key]):
			return AutomationResult.failure("INVALID_ARGUMENT", "Instrument setting is out of range.", { "field": key })
	var voice_id := int(params.get("voice_id", before.voice_index))
	var volume := int(params.get("volume", before.volume))
	var cutoff := int(params.get("cutoff", before.lp_cutoff))
	var resonance := int(params.get("resonance", before.lp_resonance))
	if voice_id == before.voice_index && volume == before.volume && cutoff == before.lp_cutoff && resonance == before.lp_resonance:
		return _unchanged()
	var after := Controller.instance_instrument_by_voice(Controller.voice_manager.get_voice_data_at(voice_id))
	after.volume = volume
	after.lp_cutoff = cutoff
	after.lp_resonance = resonance
	after.update_filter()
	for pattern in song.patterns:
		if pattern.instrument_idx != index:
			continue
		if before.type != after.type && pattern.note_amount > 0:
			return AutomationResult.failure("WOULD_DROP_NOTES", "Clear notes before changing between melodic and drum instruments.")
		if after is DrumkitInstrument:
			for i in pattern.note_amount:
				if not after.is_note_valid(pattern.notes[i]):
					return AutomationResult.failure("WOULD_DROP_NOTES", "The new drumkit does not contain all referenced drums.")
	var state := Controller.state_manager.create_state_change(StateManager.StateChangeType.INSTRUMENT, index)
	state.add_do_action(func() -> void: _set_instrument(index, after))
	state.add_undo_action(func() -> void: _set_instrument(index, before))
	Controller.state_manager.commit_state_change(state)
	return _changed({ "instrument_index": index })


static func _set_instrument(index: int, instrument: Instrument) -> void:
	Controller.current_song.instruments[index] = instrument
	instrument.update_filter()
	for pattern in Controller.current_song.patterns:
		if pattern.instrument_idx == index:
			pattern.instrument_changed.emit()
	Controller.song_instrument_changed.emit()


static func create_pattern(params: Dictionary, clone: bool = false) -> Dictionary:
	var allowed := ["pattern_index"] if clone else ["instrument_index", "key", "scale"]
	var required := ["pattern_index"] if clone else ["instrument_index"]
	var error := AutomationResult.fields(params, allowed, required)
	if not error.is_empty():
		return error
	var song := Controller.current_song
	if song.patterns.size() >= Song.MAX_PATTERN_COUNT:
		return AutomationResult.failure("LIMIT_EXCEEDED", "The song already has 4096 patterns.")
	var pattern: Pattern
	if clone:
		if not AutomationResult.is_integer(params.pattern_index, 0, song.patterns.size() - 1):
			return AutomationResult.failure("INVALID_ARGUMENT", "Invalid pattern index.")
		pattern = song.patterns[int(params.pattern_index)].clone()
	else:
		if not AutomationResult.is_integer(params.instrument_index, 0, song.instruments.size() - 1) || not AutomationResult.is_integer(params.get("key", 0), 0, Note.MAX - 1) || not AutomationResult.is_integer(params.get("scale", 0), 0, Scale.MAX - 1):
			return AutomationResult.failure("INVALID_ARGUMENT", "Invalid instrument, key or scale.")
		if song.instruments[int(params.instrument_index)] is DrumkitInstrument && params.get("key", 0) != 0:
			return AutomationResult.failure("INVALID_ARGUMENT", "Drum patterns require key 0.")
		pattern = Pattern.new()
		pattern.instrument_idx = int(params.instrument_index)
		pattern.key = int(params.get("key", 0))
		pattern.scale = int(params.get("scale", 0))
	var index := song.patterns.size()
	var state := Controller.state_manager.create_state_change(StateManager.StateChangeType.SONG)
	state.add_do_action(func() -> void:
		song.add_pattern(pattern)
		Controller.song_pattern_created.emit()
	)
	state.add_undo_action(func() -> void:
		Controller.delete_pattern_nocheck(index)
		Controller.song_pattern_changed.emit()
	)
	Controller.state_manager.commit_state_change(state)
	return _changed({ "pattern_index": index })


static func delete_pattern(params: Dictionary) -> Dictionary:
	var error := AutomationResult.fields(params, ["pattern_index"], ["pattern_index"])
	if not error.is_empty():
		return error
	var song := Controller.current_song
	if not AutomationResult.is_integer(params.pattern_index, 0, song.patterns.size() - 1):
		return AutomationResult.failure("INVALID_ARGUMENT", "Invalid pattern index.")
	var index := int(params.pattern_index)
	var removed := song.patterns[index]
	var replacement := Pattern.new() if song.patterns.size() == 1 else null
	if replacement:
		replacement.instrument_idx = Controller.current_instrument_index
	var old_selection := Controller.current_pattern_index
	var new_selection := maxi(0, old_selection - 1) if old_selection >= index else old_selection
	var arrangement := song.arrangement
	var before: Array[PackedInt32Array] = []
	var after: Array[PackedInt32Array] = []
	var affected: Array[Dictionary] = []
	for bar in arrangement.timeline_bars.size():
		before.append(arrangement.timeline_bars[bar].duplicate())
		var next := arrangement.timeline_bars[bar].duplicate()
		for channel in Arrangement.CHANNEL_NUMBER:
			if next[channel] == index:
				next[channel] = -1
				affected.append({ "bar": bar, "channel": channel })
			elif next[channel] > index:
				next[channel] -= 1
		after.append(next)
	var length := arrangement.timeline_length
	var loop := Vector2i(arrangement.loop_start, arrangement.loop_end)
	var state := Controller.state_manager.create_state_change(StateManager.StateChangeType.SONG)
	state.add_do_action(func() -> void:
		Controller._untrack_pattern_changes(Controller.current_pattern_index)
		song.remove_pattern(index)
		if replacement:
			song.add_pattern(replacement)
		Controller._change_current_pattern(new_selection, true, true)
		_apply_arrangement(after, length, loop)
	)
	state.add_undo_action(func() -> void:
		Controller._untrack_pattern_changes(Controller.current_pattern_index)
		if replacement:
			song.remove_pattern(0)
		song.add_pattern(removed, index)
		Controller._change_current_pattern(old_selection, true, true)
		_apply_arrangement(before, length, loop)
	)
	Controller.state_manager.commit_state_change(state)
	return _changed({ "deleted_pattern_index": index, "cleared_cells": affected,
		"shifted_indices_from": index + 1, "shifted_by": -1, "replacement_created": replacement != null })


static func notes_set(params: Dictionary) -> Dictionary:
	var error := AutomationResult.fields(params, ["pattern_index", "mode", "notes"], ["pattern_index", "mode", "notes"])
	if not error.is_empty():
		return error
	var song := Controller.current_song
	if not AutomationResult.is_integer(params.pattern_index, 0, song.patterns.size() - 1) || params.mode not in ["replace", "append", "remove"] || not params.notes is Array:
		return AutomationResult.failure("INVALID_ARGUMENT", "Invalid pattern, note mode or notes array.")
	if params.notes.size() > Pattern.MAX_NOTES_IN_PATTERN:
		return AutomationResult.failure("LIMIT_EXCEEDED", "A note batch can contain at most 128 notes.")
	var index := int(params.pattern_index)
	var pattern := song.patterns[index]
	var instrument := song.instruments[pattern.instrument_idx]
	var value_key := "drum_index" if instrument is DrumkitInstrument else "pitch"
	var max_value := (instrument as DrumkitInstrument).voices.size() - 1 if instrument is DrumkitInstrument else Pattern.MAX_NOTE_VALUE - 1
	var next: Array[Vector3i] = []
	if params.mode != "replace":
		next.assign(pattern.notes.slice(0, pattern.note_amount))
	var seen: Dictionary = {}
	for note: Variant in params.notes:
		if not note is Dictionary:
			return AutomationResult.failure("INVALID_ARGUMENT", "Every note must be an object.")
		var required: Array = [value_key, "position"] if params.mode == "remove" else [value_key, "position", "length"]
		error = AutomationResult.fields(note, required, required)
		if not error.is_empty():
			return error
		if not AutomationResult.is_integer(note[value_key], 0, max_value) || not AutomationResult.is_integer(note.position, 0, song.pattern_size - 1) || (params.mode != "remove" && not AutomationResult.is_integer(note.length, 1, Pattern.MAX_NOTE_LENGTH)):
			return AutomationResult.failure("INVALID_ARGUMENT", "Note value, position or length is out of range.")
		var value := int(note[value_key])
		var position := int(note.position)
		var key := Vector2i(value, position)
		if seen.has(key):
			return AutomationResult.failure("INVALID_ARGUMENT", "The batch contains duplicate note positions.")
		seen[key] = true
		var found := -1
		for i in next.size():
			if next[i].x == value && next[i].y == position:
				found = i
				break
		if params.mode == "remove":
			if found < 0:
				return AutomationResult.failure("NOT_FOUND", "A note to remove was not found.")
			next.remove_at(found)
		else:
			if found >= 0:
				return AutomationResult.failure("INVALID_ARGUMENT", "A note already occupies this pitch and position.")
			next.append(Vector3i(value, position, int(note.length)))
	if next.size() > Pattern.MAX_NOTES_IN_PATTERN:
		return AutomationResult.failure("LIMIT_EXCEEDED", "A pattern can contain at most 128 notes.")
	return replace_notes(index, next)


## Low-level typed command used by UI note drawing and validated MCP batches.
static func replace_notes(index: int, next: Array[Vector3i], preview: bool = false) -> Dictionary:
	if next.size() > Pattern.MAX_NOTES_IN_PATTERN:
		return AutomationResult.failure("LIMIT_EXCEEDED", "A pattern can contain at most 128 notes.")
	var pattern := Controller.current_song.patterns[index]
	var before: Array[Vector3i] = []
	before.assign(pattern.notes.slice(0, pattern.note_amount))
	var after := next.duplicate()
	after.sort_custom(func(a: Vector3i, b: Vector3i) -> bool: return a.x < b.x || (a.x == b.x && a.y < b.y))
	if before == after:
		return _unchanged()
	var state := Controller.state_manager.create_state_change(StateManager.StateChangeType.PATTERN, index)
	state.add_do_action(func() -> void: _apply_notes(index, after, preview))
	state.add_undo_action(func() -> void: _apply_notes(index, before, preview))
	Controller.state_manager.commit_state_change(state)
	return _changed({ "pattern_index": index, "note_count": after.size() })


static func _apply_notes(index: int, notes: Array[Vector3i], preview: bool) -> void:
	var pattern := Controller.current_song.patterns[index]
	var previous := pattern.notes.slice(0, pattern.note_amount)
	pattern.replace_notes(notes)
	if preview:
		for note in notes:
			if note not in previous:
				pattern.note_added.emit(note)


static func arrangement_set(params: Dictionary) -> Dictionary:
	var error := AutomationResult.fields(params, ["cells", "trim"], ["cells"])
	if not error.is_empty():
		return error
	if not params.cells is Array || params.cells.size() > 256 || not params.get("trim", false) is bool:
		return AutomationResult.failure("INVALID_ARGUMENT", "Expected up to 256 cells and a boolean trim flag.")
	var arrangement := Controller.current_song.arrangement
	var before: Array[PackedInt32Array] = []
	for bar in arrangement.timeline_bars:
		before.append(bar.duplicate())
	var after: Array[PackedInt32Array] = []
	for bar in before:
		after.append(bar.duplicate())
	var next_length := maxi(1, arrangement.timeline_length)
	var seen: Dictionary = {}
	for cell: Variant in params.cells:
		if not cell is Dictionary:
			return AutomationResult.failure("INVALID_ARGUMENT", "Every cell must be an object.")
		error = AutomationResult.fields(cell, ["bar", "channel", "pattern_index"], ["bar", "channel", "pattern_index"])
		if not error.is_empty():
			return error
		if not AutomationResult.is_integer(cell.bar, 0, Arrangement.BAR_NUMBER - 1) || not AutomationResult.is_integer(cell.channel, 0, Arrangement.CHANNEL_NUMBER - 1) || (cell.pattern_index != null && not AutomationResult.is_integer(cell.pattern_index, 0, Controller.current_song.patterns.size() - 1)):
			return AutomationResult.failure("INVALID_ARGUMENT", "Arrangement cell is out of range.")
		var key := Vector2i(int(cell.bar), int(cell.channel))
		if seen.has(key):
			return AutomationResult.failure("INVALID_ARGUMENT", "The batch writes the same cell twice.")
		seen[key] = true
		after[key.x][key.y] = -1 if cell.pattern_index == null else int(cell.pattern_index)
		if cell.pattern_index != null:
			next_length = maxi(next_length, key.x + 1)
	if params.get("trim", false):
		next_length = 1
		for bar in after.size():
			for value in after[bar]:
				if value != -1:
					next_length = maxi(next_length, bar + 1)
	var old_loop := Vector2i(arrangement.loop_start, arrangement.loop_end)
	var next_loop := Vector2i(mini(old_loop.x, next_length - 1), clampi(old_loop.y, 1, next_length))
	if before == after && arrangement.timeline_length == next_length && old_loop == next_loop:
		return _unchanged()
	var old_length := arrangement.timeline_length
	var state := Controller.state_manager.create_state_change(StateManager.StateChangeType.ARRANGEMENT)
	state.add_do_action(func() -> void: _apply_arrangement(after, next_length, next_loop))
	state.add_undo_action(func() -> void: _apply_arrangement(before, old_length, old_loop))
	Controller.state_manager.commit_state_change(state)
	return _changed({ "timeline_length": next_length })


static func _apply_arrangement(bars: Array[PackedInt32Array], length: int, loop: Vector2i) -> void:
	var arrangement := Controller.current_song.arrangement
	for i in bars.size():
		arrangement.timeline_bars[i] = bars[i].duplicate()
	arrangement.timeline_length = length
	arrangement.set_loop(loop.x, loop.y)
	arrangement.patterns_changed.emit()


static func loop_set(params: Dictionary) -> Dictionary:
	var error := AutomationResult.fields(params, ["start", "end"], ["start", "end"])
	if not error.is_empty():
		return error
	var arrangement := Controller.current_song.arrangement
	if not AutomationResult.is_integer(params.start, 0, arrangement.timeline_length - 1) || not AutomationResult.is_integer(params.end, 1, arrangement.timeline_length) || params.start >= params.end:
		return AutomationResult.failure("INVALID_ARGUMENT", "Loop must satisfy 0 <= start < end <= timeline_length.")
	var before := Vector2i(arrangement.loop_start, arrangement.loop_end)
	var after := Vector2i(int(params.start), int(params.end))
	if before == after:
		return _unchanged()
	var state := Controller.state_manager.create_state_change(StateManager.StateChangeType.ARRANGEMENT)
	state.add_do_action(func() -> void: arrangement.set_loop(after.x, after.y))
	state.add_undo_action(func() -> void: arrangement.set_loop(before.x, before.y))
	Controller.state_manager.commit_state_change(state)
	return _changed()
