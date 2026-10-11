## Bounds-check legacy CEOL tokens before SongLoader can allocate/index from them.
## Decoding still belongs to SongLoader; this validates counts and references only.
class_name SongFileValidator extends RefCounted


static func validate_text(text: String) -> Dictionary:
	var reader := CheckedTokens.new(text)
	var version := reader.take(1, 3)
	if version >= 2:
		reader.take(-10, 10) # Swing.
	if version >= 3:
		reader.take(0, Effect.MAX - 1)
		reader.take(0, 130)
	reader.take(Song.MIN_BPM, Song.MAX_BPM)
	var pattern_size := reader.take(1, Song.MAX_PATTERN_SIZE)
	reader.take(1, Song.MAX_PATTERN_SIZE)
	var instrument_count := reader.take(1, Song.MAX_INSTRUMENT_COUNT)
	if reader.failed: return reader.error()
	var note_limits: Array[int] = []
	for _i in instrument_count:
		var voice_id := reader.take(0, Controller.voice_manager.get_voice_count() - 1)
		reader.take(0, Instrument.InstrumentType.MAX - 1)
		reader.take(0, 255) # Historical palette metadata is ignored by the loader.
		reader.take(0, Instrument.MAX_FILTER_CUTOFF)
		reader.take(0, Instrument.MAX_FILTER_RESONANCE)
		if version >= 2: reader.take(0, Instrument.MAX_VOLUME)
		if reader.failed: return reader.error()
		var voice := Controller.voice_manager.get_voice_data_at(voice_id)
		note_limits.append((voice as VoiceManager.DrumkitData).items.size() - 1 if voice is VoiceManager.DrumkitData else 127)
	var pattern_count := reader.take(1, Song.MAX_PATTERN_COUNT)
	if reader.failed: return reader.error()
	for _i in pattern_count:
		reader.take(0, Note.MAX - 1)
		reader.take(0, Scale.MAX - 1)
		var instrument := reader.take(0, instrument_count - 1)
		reader.take(0, 255)
		var count := reader.take(0, Pattern.MAX_NOTES_IN_PATTERN)
		if reader.failed: return reader.error()
		var seen: Dictionary = {}
		for _j in count:
			var value := reader.take(0, note_limits[instrument])
			reader.take(1, Pattern.MAX_NOTE_LENGTH)
			var position := reader.take(0, pattern_size - 1)
			reader.take(-2147483648, 2147483647) # Unused compatibility value.
			if reader.failed: return reader.error()
			var key := Vector2i(value, position)
			if seen.has(key): return AutomationResult.failure("INVALID_ARGUMENT", "The song contains duplicate note positions.")
			seen[key] = true
		if reader.take(0, 1) == 1:
			for _j in 16:
				reader.take(0, Instrument.MAX_VOLUME)
				reader.take(0, Instrument.MAX_FILTER_CUTOFF)
				reader.take(0, Instrument.MAX_FILTER_RESONANCE)
		if reader.failed: return reader.error()
	var length := reader.take(0, Arrangement.BAR_NUMBER)
	var loop_start := reader.take(0, maxi(0, length - 1))
	var loop_end := reader.take(1, maxi(1, length))
	if reader.failed: return reader.error()
	if loop_start >= loop_end: return AutomationResult.failure("INVALID_ARGUMENT", "The song has an invalid loop range.")
	for _i in length * Arrangement.CHANNEL_NUMBER:
		reader.take(-1, pattern_count - 1)
		if reader.failed: return reader.error()
	if reader.offset != reader.tokens.size():
		return AutomationResult.failure("INVALID_ARGUMENT", "The song contains unexpected trailing data.")
	return {}


class CheckedTokens:
	var tokens: PackedStringArray
	var offset: int = 0
	var failed: bool = false

	func _init(text: String) -> void:
		tokens = text.strip_edges().split(",", true)
		if not tokens.is_empty() && tokens[tokens.size() - 1].is_empty():
			tokens.remove_at(tokens.size() - 1)

	func take(minimum: int, maximum: int) -> int:
		if failed || offset >= tokens.size():
			failed = true
			return minimum
		var token := tokens[offset].strip_edges()
		offset += 1
		if token.length() > 11 || not token.is_valid_int():
			failed = true
			return minimum
		var value := token.to_int()
		if value < minimum || value > maximum:
			failed = true
			return minimum
		return value

	func error() -> Dictionary:
		return AutomationResult.failure("INVALID_ARGUMENT", "Song data is truncated, non-integer or out of range.", { "token": offset })
