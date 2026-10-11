# Windows installer

The build entry is `scripts/build-windows-installer.ps1`. It exports the existing
Windows x64 Godot preset, stages production MCP dependencies and a private Node
runtime, then compiles `packaging/windows/bosca-mcp.iss` with Inno Setup 6.
The bundle contains license notices and no token/configuration, development
dependencies, test fixtures, build tools or Codex executable.

## Inputs and reproduction

Use Godot 4.3 and matching official `windows_release_x86_64.exe` and
`windows_release_x86_64_console.exe` templates from the
[4.3 release](https://github.com/godotengine/godot/releases/tag/4.3-stable).
Install GDSiON 0.7-beta8 into `bin/` and run `npm --prefix mcp ci` first.
Provide Node.js 22+ (this preview bundles 24.19.0), its full LICENSE, Godot's
COPYRIGHT.txt, GDSiON's LICENSE, and rcedit 2.0.0. Keep inputs outside the repository.

```powershell
./scripts/build-windows-installer.ps1 `
  -Godot C:/tools/godot/Godot_v4.3-stable_win64_console.exe `
  -TemplateDirectory C:/tools/godot/templates `
  -Node C:/tools/node/node.exe `
  -NodeLicense C:/tools/node/LICENSE `
  -GodotCopyright C:/tools/godot/COPYRIGHT.txt `
  -GdsionLicense C:/tools/gdsion/LICENSE `
  -RcEdit C:/tools/rcedit.exe `
  -OutputDirectory C:/builds/bosca
```

`-NpmCli` can point to npm-cli.js when npm is not on PATH. `-InnoCompiler` defaults
to the standard Inno Setup 6 installation. The build keeps unique scratch folders
under `export/`; it never recursively removes an existing directory. Export
templates and editor settings use a temporary APPDATA scope. The script emits the
installer, SHA-256 sidecar, bundle directory and build-log directory.

## Installation behavior

- Per-user installation under LocalAppData/Programs; no elevation, background
  service, autostart task or firewall rule.
- Codex connection is a visible installer task; edit permission is a separate,
  initially unchecked task. For existing configuration, the unchecked edit task
  preserves its existing mode rather than silently changing user preferences.
- The setup helper locates the desktop app's `codex.exe` in LocalAppData/OpenAI/Codex/bin
  (including versioned runtime directories), LocalAppData/Programs/OpenAI/Codex/bin,
  or PATH. Versioned CLI binaries are preferred over older flat-layout binaries.
  An explicit `--codex-command` path is available for diagnostics. If unavailable,
  the app installation succeeds and explains how to retry/copy configuration.
- Credentials stay in a protected per-user file. Registration contains executable
  and config paths, never the token. Upgrades retain the token, root permissions
  and song directory while refreshing bundled runtime paths.
- A receipt tracks registration ownership. Uninstall refuses to remove changed
  entries or registrations belonging to another Bosca installation.

## Installer verification

```powershell
$env:BOSCA_INSTALLER_EXE = 'C:/builds/bosca/Bosca-Ceoil-Blue-MCP-3.2-preview1-Windows-x64-Setup.exe'
$env:BOSCA_CODEX_EXE = 'C:/path/to/codex.exe'
npm --prefix mcp run test:installer
```

The test installs into a unique temporary directory with `/SMOKETEST=1`, which
suppresses the Windows uninstall registry entry and automatic Codex setup. It
then runs the real bundled setup helper against a child-process-only isolated
Codex profile, verifies the unrelated entry survives, starts the exported app,
queries all 23 tools, edits/saves/exports, unregisters, and runs the uninstaller.
Songs and settings must survive. Diagnostic logs remain in the reported directory.
This test does not install the server into the current user's Codex profile.

The preview has no code-signing certificate. Windows publisher/reputation prompts
are expected; do not describe it as a signed upstream release. Manual GUI and
listening checks, fresh-machine compatibility and other platforms remain release
validation work.
