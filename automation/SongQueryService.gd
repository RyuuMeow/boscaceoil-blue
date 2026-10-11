class_name SongQueryService extends RefCounted

const LIMITS := {
	"instruments": Song.MAX_INSTRUMENT_COUNT,
	"patterns": Song.MAX_PATTERN_COUNT,
	"notes_per_pattern": Pattern.MAX_NOTES_IN_PATTERN,
	"pattern_steps": Song.MAX_PATTERN_SIZE,
	"channels": Arrangement.CHANNEL_NUMBER,
	"timeline_bars": Arrangement.BAR_NUMBER,
	"bpm_min": Song.MIN_BPM,
	"bpm_max": Song.MAX_BPM,
	"steps_per_beat": 4,
}


func song_summary() -> Dictionary:
	var song := Controller.current_song
	var instruments: Array[Dictionary] = []
	for i in song.instruments.size():
		var instrument := song.instruments[i]
		instruments.append({ "instrument_index": i, "voice_id": instrument.voice_index,
			"name": instrument.name, "category": instrument.category,
			"type": "drumkit" if instrument is DrumkitInstrument else "melodic",
			"volume": instrument.volume, "cutoff": instrument.lp_cutoff, "resonance": instrument.lp_resonance })
	return { "name": song.name, "dirty": song.is_dirty(), "bpm": song.bpm,
		"pattern_size": song.pattern_size, "bar_size": song.bar_size,
		"swing": song.swing, "global_effect": song.global_effect, "global_effect_power": song.global_effect_power,
		"instruments": instruments, "pattern_count": song.patterns.size(),
		"timeline_length": song.arrangement.timeline_length,
		"loop": { "start": song.arrangement.loop_start, "end": song.arrangement.loop_end },
		"selection": { "pattern_index": Controller.current_pattern_index, "instrument_index": Controller.current_instrument_index } }


func pattern_data(index: int) -> Dictionary:
	var pattern := Controller.current_song.patterns[index]
	var drum := Controller.current_song.instruments[pattern.instrument_idx] is DrumkitInstrument
	var notes: Array[Dictionary] = []
	for i in pattern.note_amount:
		var note := pattern.notes[i]
		var data := { "position": note.y, "length": note.z }
		data["drum_index" if drum else "pitch"] = note.x
		notes.append(data)
	return { "pattern_index": index, "instrument_index": pattern.instrument_idx,
		"key": pattern.key, "scale": pattern.scale, "notes": notes,
		"record_instrument": pattern.record_instrument }


func arrangement_data(start: int, count: int) -> Dictionary:
	var arrangement := Controller.current_song.arrangement
	var bars: Array[Dictionary] = []
	var end := mini(start + count, arrangement.timeline_length)
	for bar in range(start, end):
		var channels: Array = []
		for index in arrangement.timeline_bars[bar]:
			channels.append(null if index == -1 else index)
		bars.append({ "bar": bar, "channels": channels })
	return { "bars": bars, "timeline_length": arrangement.timeline_length,
		"next_start": end if end < arrangement.timeline_length else null,
		"loop": { "start": arrangement.loop_start, "end": arrangement.loop_end } }


func catalog(kind: String, filter_text: String, cursor: int, limit: int) -> Dictionary:
	var items: Array[Dictionary] = []
	if kind == "voices":
		for i in Controller.voice_manager.get_voice_count():
			var voice := Controller.voice_manager.get_voice_data_at(i)
			if not filter_text.is_empty() && not (voice.name + " " + voice.category).to_lower().contains(filter_text.to_lower()):
				continue
			var data := { "voice_id": i, "name": voice.name, "category": voice.category,
				"type": "drumkit" if voice is VoiceManager.DrumkitData else "melodic" }
			if voice is VoiceManager.DrumkitData:
				var drum_data := voice as VoiceManager.DrumkitData
				var drums: Array[Dictionary] = []
				for j in drum_data.items.size():
					var drum := drum_data.items[j]
					drums.append({ "drum_index": j, "name": drum.name, "midi_note": drum.midi_note })
				data["drums"] = drums
			items.append(data)
	elif kind == "scales":
		for i in Scale.MAX:
			items.append({ "id": i, "name": Scale.get_scale_name(i) })
	else:
		for i in Effect.MAX:
			items.append({ "id": i, "name": Effect.get_effect_name(i) })
	var end := mini(cursor + limit, items.size())
	return { "items": items.slice(mini(cursor, items.size()), end), "total": items.size(),
		"next_cursor": end if end < items.size() else null }
