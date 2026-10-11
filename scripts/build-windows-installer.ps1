param(
    [Parameter(Mandatory)][string]$Godot,
    [Parameter(Mandatory)][string]$TemplateDirectory,
    [Parameter(Mandatory)][string]$Node,
    [Parameter(Mandatory)][string]$NodeLicense,
    [Parameter(Mandatory)][string]$GodotCopyright,
    [Parameter(Mandatory)][string]$GdsionLicense,
    [Parameter(Mandatory)][string]$RcEdit,
    [string]$NpmCli = '',
    [string]$InnoCompiler = 'C:/Program Files (x86)/Inno Setup 6/ISCC.exe',
    [string]$OutputDirectory = ''
)
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $project 'export/installer' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$scratch = Join-Path $project ('export/build-' + [guid]::NewGuid())
$bundle = Join-Path $scratch 'bundle'
$buildData = Join-Path $scratch 'appdata'
$templates = Join-Path $buildData 'Godot/export_templates/4.3.stable'
$godotPath = (Get-Command $Godot).Source
$nodePath = (Get-Command $Node).Source
$TemplateDirectory = (Resolve-Path -LiteralPath $TemplateDirectory).Path
$NodeLicense = (Resolve-Path -LiteralPath $NodeLicense).Path
$GodotCopyright = (Resolve-Path -LiteralPath $GodotCopyright).Path
$GdsionLicense = (Resolve-Path -LiteralPath $GdsionLicense).Path
$RcEdit = (Resolve-Path -LiteralPath $RcEdit).Path
if ($NpmCli) { $NpmCli = (Resolve-Path -LiteralPath $NpmCli).Path }
$savedAppData = $env:APPDATA
$savedPath = $env:PATH
function Invoke-Npm([string[]]$Arguments) {
    if ($NpmCli) { & $nodePath $NpmCli @Arguments } else { & npm @Arguments }
    if ($LASTEXITCODE -ne 0) { throw "npm failed: $Arguments" }
}
foreach ($required in @($NodeLicense, $GodotCopyright, $GdsionLicense, $RcEdit, $InnoCompiler,
    (Join-Path $TemplateDirectory 'windows_release_x86_64.exe'),
    (Join-Path $TemplateDirectory 'windows_release_x86_64_console.exe'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing build input: $required" }
}
New-Item -ItemType Directory -Path $bundle, $templates, $OutputDirectory -Force | Out-Null
Push-Location $project
try {
    $env:PATH = (Split-Path $nodePath) + [IO.Path]::PathSeparator + $env:PATH
    $env:APPDATA = $buildData
    Copy-Item (Join-Path $TemplateDirectory 'windows_release_x86_64*.exe') $templates
    $editorSettings = '[gd_resource type="EditorSettings" format=3]' + "`n`n[resource]`nexport/windows/rcedit = " + '"' + $RcEdit.Replace('\', '/') + '"' + "`n"
    [IO.File]::WriteAllText((Join-Path $buildData 'Godot/editor_settings-4.3.tres'), $editorSettings)
    Invoke-Npm @('--prefix', 'mcp', 'run', 'typecheck')
    Invoke-Npm @('--prefix', 'mcp', 'run', 'build')
    & $godotPath --headless --path $project --editor --import --quit *> (Join-Path $scratch 'import.log')
    if ($LASTEXITCODE -ne 0) { throw 'Godot import failed. See build logs.' }
    $exe = Join-Path $bundle 'boscaceoil-blue.exe'
    & $godotPath --headless --path $project --export-release 'Windows - x86_64' $exe *> (Join-Path $scratch 'export.log')
    $exportLog = Get-Content (Join-Path $scratch 'export.log') -Raw
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe) -or $exportLog -match 'SCRIPT ERROR|Parse Error|Export failed') { throw "Godot export failed. See $scratch/export.log" }
    if ($exportLog -match 'Storing File: res://(mcp|tests|scripts|packaging)/') { throw 'Developer files leaked into the exported application.' }
    New-Item -ItemType Directory -Path "$bundle/runtime", "$bundle/mcp", "$bundle/licenses", "$bundle/docs/mcp" | Out-Null
    Copy-Item -LiteralPath $nodePath -Destination "$bundle/runtime/node.exe"
    Copy-Item -LiteralPath mcp/dist -Destination "$bundle/mcp/dist" -Recurse
    Copy-Item mcp/package.json,mcp/package-lock.json "$bundle/mcp"
    Invoke-Npm @('--prefix', "$bundle/mcp", 'ci', '--omit=dev', '--ignore-scripts', '--no-audit', '--no-fund')
    Copy-Item -LiteralPath LICENSE -Destination "$bundle/LICENSE.txt"
    Copy-Item -LiteralPath dist/windows-icon.ico -Destination "$bundle/bosca.ico"
    Copy-Item -LiteralPath packaging/windows/README-INSTALLER.txt -Destination "$bundle/README-INSTALLER.txt"
    Copy-Item docs/mcp/*.md "$bundle/docs/mcp"
    Copy-Item -LiteralPath $NodeLicense -Destination "$bundle/licenses/Node.js-LICENSE.txt"
    Copy-Item -LiteralPath $GodotCopyright -Destination "$bundle/licenses/Godot-COPYRIGHT.txt"
    Copy-Item -LiteralPath $GdsionLicense -Destination "$bundle/licenses/GDSiON-LICENSE.txt"
    Copy-Item -LiteralPath 'assets/fonts/FFF Aquarius - License.txt' -Destination "$bundle/licenses/FFF-Aquarius-LICENSE.txt"
    & $InnoCompiler /Qp "/DBundleDir=$bundle" "/DOutputDir=$OutputDirectory" packaging/windows/bosca-mcp.iss
    if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
    $installer = Join-Path $OutputDirectory 'Bosca-Ceoil-Blue-MCP-3.2-preview1-Windows-x64-Setup.exe'
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $installer).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$installer.sha256", "$hash  $([IO.Path]::GetFileName($installer))`n")
    Write-Output "INSTALLER=$installer"
    Write-Output "BUNDLE=$bundle"
    Write-Output "BUILD_LOGS=$scratch"
} finally {
    $env:APPDATA = $savedAppData
    $env:PATH = $savedPath
    Pop-Location
}
