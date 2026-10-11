$ErrorActionPreference = 'Stop'
if (-not $env:RUNNER_TEMP -or -not $env:GITHUB_ENV) { throw 'Run this helper inside GitHub Actions.' }
$tools = Join-Path $env:RUNNER_TEMP 'installer-tools'
New-Item -ItemType Directory -Path $tools -Force | Out-Null
$downloads = @{
    'godot.zip' = 'https://github.com/godotengine/godot/releases/download/4.3-stable/Godot_v4.3-stable_win64.exe.zip'
    'templates.zip' = 'https://github.com/godotengine/godot/releases/download/4.3-stable/Godot_v4.3-stable_export_templates.tpz'
    'node-LICENSE.txt' = 'https://raw.githubusercontent.com/nodejs/node/v22.16.0/LICENSE'
    'godot-COPYRIGHT.txt' = 'https://raw.githubusercontent.com/godotengine/godot/4.3-stable/COPYRIGHT.txt'
    'gdsion-LICENSE.txt' = 'https://raw.githubusercontent.com/YuriSizov/gdsion/0.7-beta8/LICENSE'
}
foreach ($name in $downloads.Keys) { Invoke-WebRequest $downloads[$name] -OutFile (Join-Path $tools $name) }
Expand-Archive "$tools/godot.zip" "$tools/godot"
Expand-Archive "$tools/templates.zip" "$tools/templates"
gh release download rust-v0.162.1 --repo openai/codex --pattern codex-x86_64-pc-windows-msvc.exe.tar.gz --dir $tools
if ($LASTEXITCODE -ne 0) { throw 'Could not download pinned Codex test binary.' }
tar -xzf "$tools/codex-x86_64-pc-windows-msvc.exe.tar.gz" -C $tools
if ($LASTEXITCODE -ne 0) { throw 'Could not extract Codex.' }
$codex = Join-Path $tools 'codex-x86_64-pc-windows-msvc.exe'
if (-not (Test-Path $codex)) { throw 'Codex executable is missing.' }
if (-not (Test-Path 'C:/Program Files (x86)/Inno Setup 6/ISCC.exe')) {
    choco install innosetup --version=6.4.3 --yes --no-progress
    if ($LASTEXITCODE -ne 0) { throw 'Could not install Inno Setup.' }
}
"INSTALLER_TOOLS=$tools" >> $env:GITHUB_ENV
"BOSCA_GODOT=$tools/godot/Godot_v4.3-stable_win64_console.exe" >> $env:GITHUB_ENV
"BOSCA_CODEX_EXE=$codex" >> $env:GITHUB_ENV
"BOSCA_INSTALLER_TEST_ROOT=$env:RUNNER_TEMP" >> $env:GITHUB_ENV
