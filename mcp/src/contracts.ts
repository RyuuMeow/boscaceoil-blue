import * as z from 'zod/v4';

export const mutationIdentity = {
  instance_id: z.string().min(1).max(128), song_id: z.string().min(1).max(128),
  expected_revision: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER),
  operation_id: z.string().min(1).max(128).describe('Unique ID for this operation. Reuse the identical ID and arguments only to recover a timed-out call.'),
};
const patternIndex = z.number().int().min(0).max(4095);
const instrumentIndex = z.number().int().min(0).max(15);
const note = z.union([
  z.object({ pitch: z.number().int().min(0).max(103), position: z.number().int().min(0).max(31), length: z.number().int().min(1).max(128).optional() }).strict(),
  z.object({ drum_index: z.number().int().nonnegative(), position: z.number().int().min(0).max(31), length: z.number().int().min(1).max(128).optional() }).strict(),
]);

export const editingTools = [
  { name: 'bosca_export_start', description: 'Start a WAV or MIDI export job into a configured writable root. Range uses zero-based timeline bars with exclusive end; defaults to loop. Maximum duration five minutes. Poll bosca_job_get until succeeded; queued/running is not success.', schema: z.object({ ...mutationIdentity,
    format: z.enum(['wav', 'midi']), root_id: z.string().min(1).max(64), relative_path: z.string().min(1).max(128),
    start: z.number().int().min(0).max(999).optional(), end: z.number().int().min(1).max(1000).optional(), overwrite: z.boolean().default(false),
  }).strict() },
  { name: 'bosca_job_cancel', description: 'Cancel an export job safely and restore loop, playback state and editor controls. Already-finished jobs return their existing state.', schema: z.object({ ...mutationIdentity, job_id: z.string().min(1).max(128) }).strict() },
  { name: 'bosca_song_save', description: 'Save CEOL to a configured writable root. relative_path must be a plain .ceol filename. Atomic publication preserves an existing destination if saving fails. Overwrite is opt-in.', schema: z.object({ ...mutationIdentity, root_id: z.string().min(1).max(64), relative_path: z.string().min(1).max(128), overwrite: z.boolean().default(false) }).strict() },
  { name: 'bosca_song_open', description: 'Open and validate a CEOL file from a configured readable root without autoplay. Replaces the current song and clears history; refuses unsaved changes by default.', schema: z.object({ ...mutationIdentity, root_id: z.string().min(1).max(64), relative_path: z.string().min(1).max(128), discard_unsaved: z.boolean().default(false) }).strict() },
  { name: 'bosca_song_new', description: 'Replace the current song with a default song without starting playback. Refuses unsaved changes unless discard_unsaved is explicitly true. Clears undo history.', schema: z.object({ ...mutationIdentity, discard_unsaved: z.boolean().default(false) }).strict() },
  { name: 'bosca_song_update', description: 'Update song parameters in one undo step. Shrinking pattern_size is rejected if notes would be hidden. A step is one quarter beat; bar_size is visual grouping only.', schema: z.object({ ...mutationIdentity,
    bpm: z.number().int().min(10).max(450).optional(), pattern_size: z.number().int().min(1).max(32).optional(), bar_size: z.number().int().min(1).max(32).optional(),
    swing: z.number().int().min(-10).max(10).optional(), global_effect: z.number().int().min(0).max(6).optional(), global_effect_power: z.number().int().min(0).max(130).optional(),
  }).strict() },
  { name: 'bosca_instrument_create', description: 'Create one instrument from a catalog voice_id. Returns its zero-based instrument_index. Maximum 16 instruments per song.', schema: z.object({ ...mutationIdentity, voice_id: z.number().int().nonnegative() }).strict() },
  { name: 'bosca_instrument_update', description: 'Change voice, volume (0–256), cutoff (0–128) or resonance (0–9) in one undo step. Refuses changing instrument type when existing notes would change meaning.', schema: z.object({ ...mutationIdentity, instrument_index: instrumentIndex,
    voice_id: z.number().int().nonnegative().optional(), volume: z.number().int().min(0).max(256).optional(), cutoff: z.number().int().min(0).max(128).optional(), resonance: z.number().int().min(0).max(9).optional(),
  }).strict() },
  { name: 'bosca_pattern_create', description: 'Create an empty pattern for a song instrument. Read the scale catalog for scale IDs. Drum patterns require key 0.', schema: z.object({ ...mutationIdentity, instrument_index: instrumentIndex, key: z.number().int().min(0).max(11).default(0), scale: z.number().int().min(0).max(22).default(0) }).strict() },
  { name: 'bosca_pattern_clone', description: 'Clone a pattern including its notes and recorded instrument settings; returns a new index.', schema: z.object({ ...mutationIdentity, pattern_index: patternIndex }).strict() },
  { name: 'bosca_pattern_delete', description: 'Delete one pattern, clear its arrangement cells and remap higher indices. One undo restores it. Always re-read indices after deletion.', schema: z.object({ ...mutationIdentity, pattern_index: patternIndex }).strict() },
  { name: 'bosca_notes_set', description: 'Atomically replace, append or remove up to 128 notes in one undo step. For replace/append every note needs length; remove uses only pitch or drum_index plus position. Uses sequencer steps, allows long notes across a pattern boundary, and rejects duplicates or missing notes.', schema: z.object({ ...mutationIdentity, pattern_index: patternIndex, mode: z.enum(['replace', 'append', 'remove']), notes: z.array(note).max(128) }).strict() },
  { name: 'bosca_arrangement_set', description: 'Atomically place or clear up to 256 timeline cells. Indices are zero-based; null clears a cell. trim=false preserves length; trim=true shortens empty trailing bars and clamps loop safely.', schema: z.object({ ...mutationIdentity, trim: z.boolean().default(false),
    cells: z.array(z.object({ bar: z.number().int().min(0).max(999), channel: z.number().int().min(0).max(7), pattern_index: patternIndex.nullable() }).strict()).max(256),
  }).strict() },
  { name: 'bosca_loop_set', description: 'Set playback loop in zero-based timeline bars. End is exclusive and may not exceed timeline length. This is one undoable edit.', schema: z.object({ ...mutationIdentity, start: z.number().int().min(0).max(999), end: z.number().int().min(1).max(1000) }).strict() },
  { name: 'bosca_playback_set', description: 'Play, pause or stop the current song. This changes playback but does not add an undo entry.', schema: z.object({ ...mutationIdentity, action: z.enum(['play', 'pause', 'stop']) }).strict() },
  { name: 'bosca_history_step', description: 'Undo or redo one shared UI/MCP editing operation. Read status and use the latest revision first.', schema: z.object({ ...mutationIdentity, action: z.enum(['undo', 'redo']) }).strict() },
];
