#ifndef BundleDir
  #error BundleDir must point to the staged application
#endif
#ifndef OutputDir
  #error OutputDir must point to the installer output directory
#endif

[Setup]
AppId={{D077BE4F-22CB-4F43-9F52-C3CD51723D24}
AppName=Bosca Ceoil Blue MCP
AppVersion=3.2-mcp.1
AppVerName=Bosca Ceoil Blue 3.2 MCP Preview 1
AppPublisher=Bosca Ceoil Blue contributors
VersionInfoVersion=3.2.0.1
DefaultDirName={localappdata}\Programs\Bosca Ceoil Blue MCP
DefaultGroupName=Bosca Ceoil Blue MCP
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=Bosca-Ceoil-Blue-MCP-3.2-preview1-Windows-x64-Setup
SetupIconFile={#BundleDir}\bosca.ico
UninstallDisplayIcon={app}\boscaceoil-blue.exe
LicenseFile={#BundleDir}\LICENSE.txt
InfoAfterFile={#BundleDir}\README-INSTALLER.txt
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
CreateUninstallRegKey=not IsSmokeTest

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked
Name: "codex"; Description: "Connect MCP to Codex (read-only by default)"
Name: "codex\edit"; Description: "Allow Codex to edit songs and export files"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Bosca Ceoil Blue MCP"; Filename: "{app}\boscaceoil-blue.exe"
Name: "{group}\Setup instructions"; Filename: "{app}\README-INSTALLER.txt"
Name: "{autodesktop}\Bosca Ceoil Blue MCP"; Filename: "{app}\boscaceoil-blue.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\boscaceoil-blue.exe"; Description: "Launch Bosca Ceoil Blue"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\runtime\node.exe"; Parameters: """{app}\mcp\dist\install-codex.js"" --action unregister --config-dir ""{localappdata}\BoscaCeoilBlueMCP"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveOwnedCodexEntry"; Check: not IsSmokeTest

[Code]
function IsSmokeTest(): Boolean;
begin
  Result := ExpandConstant('{param:SMOKETEST|0}') = '1';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Arguments: String;
  ExitCode: Integer;
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('codex') and not IsSmokeTest then
  begin
    Arguments := '"' + ExpandConstant('{app}\mcp\dist\install-codex.js') + '"' +
      ' --config-dir "' + ExpandConstant('{localappdata}\BoscaCeoilBlueMCP') + '"' +
      ' --songs-dir "' + ExpandConstant('{userdocs}\Bosca Ceoil Blue') + '"';
    if WizardIsTaskSelected('codex\edit') then
      Arguments := Arguments + ' --mode edit';
    if not Exec(ExpandConstant('{app}\runtime\node.exe'), Arguments, '', SW_HIDE, ewWaitUntilTerminated, ExitCode) or (ExitCode <> 0) then
    begin
      Log('Codex quick setup was not completed. The application was installed successfully.');
      if not WizardSilent then
        MsgBox('Bosca was installed, but Codex setup could not finish.' + #13#10 +
          'Open Bosca: Advanced > MCP Settings > Install in Codex to retry and see details.' + #13#10 +
          'Existing unrelated Codex entries are never overwritten.', mbInformation, MB_OK);
    end;
  end;
end;
