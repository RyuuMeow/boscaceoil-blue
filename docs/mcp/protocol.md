# Protocol and editing semantics

The public interface is MCP over stdio, using the pinned TypeScript SDK. stdout
contains only protocol messages; diagnostics use stderr. The official SDK client
has been tested using its default legacy handshake. Other host applications and
modern protocol negotiation are not yet individually certified.

## Runtime connection

The private runtime protocol is UTF-8 JSON lines over IPv4 loopback. It is not a
second MCP server. Requests have string `id`, string `method` and object `params`.
The first request is `hello` with `token` and `bridge_version: 1`. Replies carry
the same ID and either `result` or `error: {code, message, details?}`. The token is
read from the shared local configuration, never returned by tools.

The bridge accepts one connection, authenticates within three seconds, limits
each message to 1 MiB and buffered data to 2 MiB, and processes up to eight
requests and 64 KiB of I/O per frame. Invalid framing and failed authentication
disconnect the peer. An unsupported bridge version returns `UNSUPPORTED_VERSION`.
Godot executes all commands on the main thread. The Node client allows at most
32 pending requests and does not automatically replay a disconnected mutation.

## Tools

The tool schemas returned by `tools/list` are generated from
`mcp/src/contracts.ts` and `mcp/src/server.ts`; those files are the schema source
of truth. Unknown fields are rejected.

| Tools | Effect and history |
| --- | --- |
| `bosca_status`, `bosca_song_get`, `bosca_pattern_get`, `bosca_arrangement_get` | Read current state; no history or dirty change |
| `bosca_catalog_list` | Paginated voices/drums/scales/effects; no state change |
| `bosca_operation_get`, `bosca_job_get` | Read retained outcomes/jobs |
| `bosca_song_update`, `bosca_instrument_create`, `bosca_instrument_update` | One undo step per changed call |
| `bosca_pattern_create`, `bosca_pattern_clone`, `bosca_pattern_delete` | One undo step; deletion remaps references |
| `bosca_notes_set`, `bosca_arrangement_set`, `bosca_loop_set` | Validate entire batch before one undo step |
| `bosca_playback_set` | Play/pause/stop; no undo entry |
| `bosca_history_step` | Move shared UI/MCP undo cursor |
| `bosca_song_new`, `bosca_song_open` | Replace song and clear history; dirty guard; no autoplay |
| `bosca_song_save` | Publish CEOL, then update filename/dirty status; no undo entry |
| `bosca_export_start`, `bosca_job_cancel` | Manage export jobs; no song undo entry |

Read-only mode rejects all mutations, including playback, history, file operations
and job control. No-op editing calls create no history. Song edits retain Bosca's
existing conservative dirty behavior: undoing to the saved contents does not
promise a clean flag.

## Identity and retries

Every mutation supplies `instance_id`, `song_id`, `expected_revision` and
`operation_id`. Get them from a fresh status/query response. Opening/new song
changes `song_id`; application restart changes `instance_id`. Shared editing
history and saves advance the revision; playback is not a song edit.

The app checks identities and revision before committing. Successful edits return
`revision_before`, `revision_after` and result-specific fields. Repeating the
identical operation ID/arguments returns its retained outcome even if the revision
has since advanced; changing arguments for an existing ID is rejected. Outcomes
expire after ten minutes or 256 operations. No durable exactly-once guarantee is
provided. After cache loss, inspect current state before deciding on a new edit.

`REVISION_CONFLICT` requires rereading and reconsidering the edit. Do not merely
replace the revision and blindly retry. `OUTCOME_UNKNOWN` means the client cannot
establish whether the change happened. MCP tool errors use `isError: true` and a
JSON text payload; successful calls also provide structured content.

## Resources and units

Read-only resources: `bosca://status`, `bosca://song/current`,
`bosca://catalog/voices`, and `bosca://song/current/pattern/{index}`.
Indices are zero-based; a pattern index can change after deletion. Four steps
equal one beat before swing. A timeline bar has `pattern_size` steps. Loop end is
exclusive. Melodic pitch is 0–103 (60 = middle C); drums use the selected catalog's
`drum_index`. Notes may last up to 128 steps across pattern boundaries. No
per-note velocity is supported. Consult status for capacity limits.

## Files and export jobs

File operations take `root_id` and one plain filename, never a full path or nested
directory. Explicit `overwrite: true` is required to replace an existing file.
CEOL versions 1–3 are validated before the current song is replaced. Legacy
zero-length arrangements are normalized to one empty bar.

Export states are `queued`, `running`, `succeeded`, `failed`, `cancelled`.
Only `succeeded` confirms publication. At most one export is active, with 32 jobs
retained. While exporting, editing is locked and reads remain available. Cancel,
render failure and publish failure restore the loop, transport and editing lock.
Client disconnection leaves the job running. Maximum range is five minutes and
rendered PCM is limited to 64 MiB. MIDI serialization/publication runs on the main
thread; WAV uses the existing synthesizer callback. The fixed Node publication
helper is synchronous, so its small process-startup cost is not a latency guarantee.
