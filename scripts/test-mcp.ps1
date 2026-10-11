param(
    [ValidateSet('All', 'Unit', 'Domain', 'Integration')][string]$Suite = 'All',
    [string]$Godot = $env:BOSCA_GODOT,
    [string]$Node = 'node',
    [string]$NpmCli = ''
)
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$nodePath = (Get-Command $Node).Source
function Invoke-Npm([string[]]$Arguments) {
    if ($NpmCli) { & $nodePath $NpmCli @Arguments } else { & npm @Arguments }
    if ($LASTEXITCODE -ne 0) { throw "npm failed: $Arguments" }
}
Push-Location (Join-Path $project 'mcp')
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('bosca-check-' + [guid]::NewGuid())
$saved = @{}
foreach ($name in @('APPDATA', 'XDG_DATA_HOME', 'BOSCA_MCP_CONFIG', 'BOSCA_GODOT', 'BOSCA_MCP_TEST_ROOT', 'BOSCA_MCP_TEST_NODE', 'PATH')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}
try {
    $env:PATH = (Split-Path $nodePath) + [IO.Path]::PathSeparator + $env:PATH
    Invoke-Npm @('run', 'typecheck')
    Invoke-Npm @('run', 'build')
    if ($Suite -in @('All', 'Unit')) { Invoke-Npm @('run', 'test:unit') }
    if ($Suite -ne 'Unit') {
        if (-not $Godot) { throw 'Pass -Godot or set BOSCA_GODOT to Godot 4.3.' }
        $godotPath = (Get-Command $Godot).Source
        New-Item -ItemType Directory -Path $scratch | Out-Null
        $env:APPDATA = $scratch
        $env:XDG_DATA_HOME = $scratch
        $env:BOSCA_MCP_CONFIG = ''
        $env:BOSCA_GODOT = $godotPath
        $env:BOSCA_MCP_TEST_NODE = $nodePath
        $env:BOSCA_MCP_TEST_ROOT = $scratch
        # A fresh import first discovers GDSiON and then resolves dependent scripts.
        & $godotPath --headless --path $project --editor --import --quit *> (Join-Path $scratch 'import-first.log')
        & $godotPath --headless --path $project --editor --import --quit *> (Join-Path $scratch 'import.log')
        $importLog = Get-Content (Join-Path $scratch 'import.log') -Raw
        if ($LASTEXITCODE -ne 0 -or $importLog -match 'SCRIPT ERROR|Parse Error') { throw $importLog }
        if ($Suite -in @('All', 'Domain')) {
            & $godotPath --headless --path $project res://tests/automation/runner.tscn --quit-after 300 *> (Join-Path $scratch 'domain.log')
            $domainLog = Get-Content (Join-Path $scratch 'domain.log') -Raw
            Write-Output $domainLog
            if ($LASTEXITCODE -ne 0 -or $domainLog -notmatch 'AUTOMATION_TESTS: \d+ checks, 0 failures' -or $domainLog -match 'SCRIPT ERROR|Parse Error') { throw 'Godot domain checks failed.' }
        }
        if ($Suite -in @('All', 'Integration')) { Invoke-Npm @('run', 'test:integration') }
    }
    Write-Output 'MCP checks passed.'
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    Pop-Location
    # Keep diagnostic logs available; do not recursively delete a computed directory.
    if (Test-Path -LiteralPath $scratch) { Write-Output "Diagnostics: $scratch" }
}
