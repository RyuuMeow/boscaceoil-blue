# Troubleshooting

| Symptom | Action |
| --- | --- |
| `APP_NOT_CONNECTED` | Start the desktop app; inspect Advanced → MCP Settings. Check the config path and enabled flag. |
| Port unavailable | Another app may own the port. Choose a free port and apply; restart the host server with the same config. |
| Authentication fails after rotation | Restart the MCP server so it rereads the token. Do not paste tokens into chat. |
| `READ_ONLY` | Enable editing locally in the settings dialog if desired. |
| `REVISION_CONFLICT` | Read status/song again and rebuild the edit against current state. |
| Timeout or `OUTCOME_UNKNOWN` | Query `bosca_operation_get` with the original instance/operation IDs; inspect the song if no outcome remains. |
| `APP_BUSY` | Poll the export job or cancel it. A disconnected host does not stop an export. |
| `UNSAVED_CHANGES` | Save first, or intentionally provide `discard_unsaved: true` when replacing the song. |
| `PATH_NOT_ALLOWED` | Use a configured root and plain filename. Check links/junctions, extension and reserved names. |
| `FILE_EXISTS` | Use a different name or explicitly request overwrite. |
| Publication/configuration fails | Check directory permissions, free disk space, fixed Node/script paths and filesystem support for rename/hard links. |
| Godot cannot find SiON classes | Install the pinned GDSiON in `bin/`, then import the project twice with Godot 4.3. |

Configuration is disabled by default. Selecting a generated enabled config starts
its listener; Apply remembers its path. An environment-provided path takes priority
over the saved path on restart. A failed reload closes the old listener and shows
the error. Keep the config outside the repository and protect its containing folder.

Run `scripts/test-mcp.ps1` for diagnostics. A domain run needs the explicit success
marker and no script errors; a process exit code alone is insufficient. Headless
Godot exit-time resource warnings also occur on the original baseline; native GUI
and audio quality should still be checked before a release.
