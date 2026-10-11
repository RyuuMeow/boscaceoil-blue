# Local MCP control

The MCP server connects an AI host to a running desktop copy of Bosca Ceoil Blue.
Song edits appear in the application and share its undo history. Normal use of
Bosca does not require Node.js, and no port opens unless MCP is explicitly enabled.
The Web build does not start a bridge.

## Install and start

### Windows installer

The Windows x64 preview installer bundles the application, GDSiON, Node.js and
production MCP dependencies. No separate Node install is needed. It installs for
the current user and offers **Connect MCP to Codex** plus an optional **Allow
Codex to edit songs and export files** checkbox. Existing configuration is preserved
on upgrades. Fresh connections default to read-only.

After setup, start Bosca and restart MCP servers in Codex Settings (or restart
Codex). The app also offers **Advanced → MCP Settings → Install in Codex** to
connect later. Setup uses the official `codex mcp add` command and verifies the
result; unrelated existing entries are left untouched. Other MCP hosts can use
the dialog's copy-configuration button. See the [official Codex MCP guide](https://learn.chatgpt.com/docs/extend/mcp).

The installer config lives at `%LOCALAPPDATA%/BoscaCeoilBlueMCP/mcp.json`; packaged
Windows builds load it automatically if no environment or saved config path is
set. Default songs go in Documents/Bosca Ceoil Blue. Uninstall removes only this
installation's unchanged Codex entry and retains songs/settings. The preview is
unsigned. See [packaging.md](packaging.md) for builds and installer smoke tests.

### From source

Requirements: Godot 4.3, GDSiON 0.7-beta8 in `bin/`, and Node.js 22 or newer.
The implementation has been tested with Node.js 24.19.0 on Windows.
The MCP SDK is pinned to 2.3.1; the stdio entry supports legacy MCP handshakes
through the SDK's compatibility mode.

From the repository root:

```powershell
npm --prefix mcp ci
npm --prefix mcp run build
node mcp/dist/configure.js --config C:/Users/YOU/AppData/Local/BoscaMCP/mcp.json --root C:/Users/YOU/Music/Bosca
```

Replace the example paths with your own **absolute** paths. The song directory must
already exist. Configuration creation will not overwrite an existing file. It
generates a random token, protects the file for the current user, and defaults to
`read_only`. To enable editing, initially create the configuration with
`--mode edit`, or use Advanced → MCP Settings after selecting the configuration.

The settings dialog can enable/disable MCP, select read-only or editing mode,
change the port/song root, rotate the token, disconnect a client and copy the host
configuration. Apply saves the selected path in Bosca's preferences. An environment
variable overrides that remembered path on the next launch. Token rotation
disconnects the old client immediately; restart the host's MCP server to reread it.
Settings cannot change during an active MCP export. The first configuration is
created by the CLI above; the UI then updates it through the same protected writer.

For CLI updates, pass `--update true` with `--root`, `--mode`, `--port` and
`--enabled true|false`; add `--rotate true` to replace the token. Omitted mode,
port and enabled options use the creation defaults. A failed update preserves the
original file. Keep the configuration and its parent directory private.

Start Bosca with the configuration path in its environment:

```powershell
$env:BOSCA_MCP_CONFIG = 'C:/Users/YOU/AppData/Local/BoscaMCP/mcp.json'
godot --path C:/path/to/boscaceoil-blue
```

Configure the MCP host to start this command (use the host's own configuration UI):

```json
{
  "command": "C:/path/to/node.exe",
  "args": [
    "C:/path/to/boscaceoil-blue/mcp/dist/index.js",
    "--config",
    "C:/Users/YOU/AppData/Local/BoscaMCP/mcp.json"
  ]
}
```

The app and server must use the same configuration. Keep this file outside the
repository; it contains a credential. Only `127.0.0.1` is supported. The default
port is 37641; use `--port` during configuration if it is occupied. Only one MCP
control connection is accepted per application instance.

## Available workflow

1. Call `bosca_status`, then `bosca_song_get`, `bosca_catalog_list`,
   `bosca_pattern_get` or `bosca_arrangement_get` to inspect the song.
2. For every editing call, supply the latest `instance_id`, `song_id`,
   `expected_revision` and a fresh `operation_id`. Read state again after a
   `REVISION_CONFLICT`; do not simply replace the version and replay an old edit.
3. Create instruments and patterns, write notes with `bosca_notes_set`, arrange
   cells with `bosca_arrangement_set`, and set an exclusive-end loop.
4. Use `bosca_playback_set` to listen. `bosca_history_step` uses the same history
   as Ctrl+Z/Ctrl+Y. A note batch or arrangement batch is one undo operation.
5. Save with `bosca_song_save`. Open a CEOL file with `bosca_song_open`. Opening
   or creating a song refuses unsaved changes by default and does not autoplay.
6. Start `bosca_export_start` with `format: wav` or `midi`; poll `bosca_job_get`
   until a terminal state. Only `succeeded` means a file was published. Use
   `bosca_job_cancel` to cancel and restore playback/loop/editor state.

All indices are zero-based. Four sequencer steps equal one beat without swing.
A timeline bar contains `pattern_size` steps, so it is not necessarily a 4/4 bar.
MIDI pitch 60 is middle C. Drum notes use catalog `drum_index` values, not MIDI
drum pitches. Note lengths may extend across pattern boundaries. There is no
per-note velocity field; instrument volume ranges from 0 to 256.

Limits include 16 instruments, 4096 patterns, 128 notes per pattern, eight
channels, 1000 timeline bars and 256 cells per arrangement batch. Exports are
limited to five minutes and 64 MiB of rendered PCM data.

## File protection and recovery

File operations accept a configured `root_id` (the generated configuration calls
it `songs`) and a **plain filename** such as `loop.ceol`, `loop.mid` or `loop.wav`.
Subdirectories, path traversal, reserved filenames, symbolic links and Windows
junctions are rejected. Read/write permission is configured separately per root.

Output is first written to a randomly named staging file in the destination
directory. The fixed `mcp/dist/publish.js` helper publishes it using Node's atomic
rename for explicit overwrites, or an atomic hard link for no-clobber creation.
The helper is invoked with an argument array, never a shell command. Filesystems
without the required operation report an error rather than falling back to a
destructive write. Do not move the MCP package or Node executable without
regenerating/updating the configuration's publisher paths.

These checks protect against tool-supplied paths and accidental clobbering. They
are not an isolation boundary against a malicious process running as the same
OS user and racing filesystem changes. The standard UI's pre-existing file
operations are independent of MCP's root policy.

After a timeout, query `bosca_operation_get` or repeat the **identical** operation
ID and arguments. The app retains 256 outcomes for ten minutes. There is no
exactly-once guarantee across application restarts or cache expiry. An
`OUTCOME_UNKNOWN` requires reading the song before deciding what to do next.
Disconnecting the client does not quit Bosca or cancel a running export.

## Development checks

```powershell
./scripts/test-mcp.ps1 -Godot C:/path/to/Godot_v4.3-stable_win64_console.exe
```

The script builds and typechecks TypeScript, runs unit tests, imports Godot twice,
then runs domain and integration checks. Use `-Suite Unit`, `Domain` or `Integration`
for focused checks. `-Node` and `-NpmCli` support explicit runtime paths. Diagnostic
logs are retained in a fresh temporary directory. Integration tests use a real application
scene, official MCP client, synthesizer, CEOL saver/loader and WAV/MIDI exporters;
they create and clean up their own output directory.

The domain runner is `tests/automation/runner.tscn`. It requires
`BOSCA_MCP_TEST_ROOT` (a scratch directory) and `BOSCA_MCP_TEST_NODE` (absolute Node
executable path), and prints `AUTOMATION_TESTS: ...` with the check count. Missing
that completion marker or any `SCRIPT ERROR` is a failed run even if Godot exits 0.

Current validation: 83 Godot domain/UI-construction checks, 13 Node tests and one
end-to-end scenario through the official SDK client and real GDSiON. The scenario
covers two voices/eight bars, undo/redo, CEOL round-trip, WAV/MIDI, cancellation,
authentication rejection, oversized messages and publication failure recovery.
Windows executable export and installer smoke tests also pass: actual install,
real Codex registration in an isolated profile, packaged runtime/CEOL/WAV/MIDI,
and uninstall preserving song/config files. The Windows CI
workflow runs the same suite, but has not been run on GitHub yet.

Manual listening, native-dialog interaction, performance percentiles and
Linux/macOS/Web release validation remain release
gates. The unmodified baseline also emits Godot resource-leak warnings on headless
exit; these warnings are not counted as passed assertions. See `plan.md` for the
release checklist, [protocol.md](protocol.md) for semantics and
[troubleshooting.md](troubleshooting.md) for recovery.
