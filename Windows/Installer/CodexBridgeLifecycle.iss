[Code]
const
  InvalidFileAttributes = $FFFFFFFF;
  FileAttributeReparsePoint = $00000400;
  PreviousInstallUninstallKey =
    'Software\Microsoft\Windows\CurrentVersion\Uninstall\{6F51B5A4-4C25-4E72-A8E5-93447D72D031}_is1';

var
  PreviousInstallDirectory: String;

function WindowsGetFileAttributes(FileName: String): DWORD;
  external 'GetFileAttributesW@kernel32.dll stdcall';

function ManifestPath(const Line: String): String;
begin
  Result := '';
  if (Length(Line) < 67) or (Copy(Line, 65, 2) <> '  ') then
    Exit;
  Result := Copy(Line, 67, MaxInt);
  StringChangeEx(Result, '/', '\', True);
end;

function IsSafeRelativePath(const Value: String): Boolean;
var
  Bounded: String;
begin
  Result := False;
  if (Value = '') or (Value[1] = '\') or (Pos(':', Value) > 0) then
    Exit;
  Bounded := '\' + Value + '\';
  if (Pos('\..\', Bounded) > 0) or (Pos('\.\', Bounded) > 0) then
    Exit;
  Result := True;
end;

function ManifestContains(const Lines: TArrayOfString; const RelativePath: String): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to GetArrayLength(Lines) - 1 do
    if CompareText(ManifestPath(Lines[I]), RelativePath) = 0 then
    begin
      Result := True;
      Exit;
    end;
end;

function HasReparseDirectoryAt(const FilePath: String; const AppDirectory: String): Boolean;
var
  Attributes: DWORD;
  Directory: String;
  Parent: String;
  RootDirectory: String;
begin
  Result := True;
  RootDirectory := RemoveBackslashUnlessRoot(AppDirectory);
  Directory := ExtractFileDir(FilePath);
  while Length(Directory) >= Length(RootDirectory) do
  begin
    Attributes := WindowsGetFileAttributes(Directory);
    if (Attributes = InvalidFileAttributes) or
       ((Attributes and FileAttributeReparsePoint) <> 0) then
      Exit;
    if CompareText(Directory, RootDirectory) = 0 then
    begin
      Result := False;
      Exit;
    end;
    Parent := ExtractFileDir(Directory);
    if CompareText(Parent, Directory) = 0 then
      Exit;
    Directory := Parent;
  end;
end;

function HasReparseDirectory(const FilePath: String): Boolean;
begin
  Result := HasReparseDirectoryAt(FilePath, ExpandConstant('{app}'));
end;

procedure RemoveEmptyParentsAt(const FilePath: String; const AppDirectory: String);
var
  Directory: String;
  RootDirectory: String;
begin
  RootDirectory := RemoveBackslashUnlessRoot(AppDirectory);
  Directory := ExtractFileDir(FilePath);
  while (Length(Directory) > Length(RootDirectory)) and
        (CompareText(Directory, RootDirectory) <> 0) do
  begin
    if not RemoveDir(Directory) then
      Exit;
    Directory := ExtractFileDir(Directory);
  end;
end;

procedure RemoveEmptyParents(const FilePath: String);
begin
  RemoveEmptyParentsAt(FilePath, ExpandConstant('{app}'));
end;

#include "CodexBridgeLegacyMigration.iss"
#include "CodexBridgePreviousInstallMigration.iss"

function RemoveStalePayloadFiles: String;
var
  I: Integer;
  InstalledManifest: String;
  NewManifest: String;
  OldLines: TArrayOfString;
  NewLines: TArrayOfString;
  RelativePath: String;
  InstalledPath: String;
begin
  Result := '';
  InstalledManifest := ExpandConstant('{app}\SHA256SUMS.txt');
  ExtractTemporaryFile('SHA256SUMS.txt');
  NewManifest := ExpandConstant('{tmp}\SHA256SUMS.txt');
  if not FileExists(InstalledManifest) then
  begin
    Result := RemoveLegacyPayloadFiles(NewManifest);
    Exit;
  end;
  if not LoadStringsFromFile(InstalledManifest, OldLines) or
     not LoadStringsFromFile(NewManifest, NewLines) then
  begin
    Result := 'Codex Bridge could not read its payload manifest.';
    Exit;
  end;

  for I := 0 to GetArrayLength(OldLines) - 1 do
  begin
    RelativePath := ManifestPath(OldLines[I]);
    if not IsSafeRelativePath(RelativePath) then
      Continue;
    if ManifestContains(NewLines, RelativePath) then
      Continue;
    InstalledPath := AddBackslash(ExpandConstant('{app}')) + RelativePath;
    if FileExists(InstalledPath) and HasReparseDirectory(InstalledPath) then
    begin
      Result := 'Codex Bridge found an unsafe application directory.';
      Exit;
    end;
    if FileExists(InstalledPath) and not DeleteFile(InstalledPath) then
    begin
      Result := 'Codex Bridge could not remove an obsolete application file.';
      Exit;
    end;
    RemoveEmptyParents(InstalledPath);
  end;
end;

function StopInstalledServiceAt(const AppDirectory: String; var ErrorMessage: String): Boolean;
var
  ExitCode: Integer;
  ServicePath: String;
begin
  Result := True;
  ErrorMessage := '';
  ServicePath := AddBackslash(AppDirectory) + 'codex-bridge-service.exe';
  if not FileExists(ServicePath) then
    Exit;
  if not Exec(ServicePath, '--shutdown', AppDirectory, SW_HIDE,
              ewWaitUntilTerminated, ExitCode) or (ExitCode <> 0) then
  begin
    ErrorMessage := 'Codex Bridge could not stop its background service. Close the app and try again.';
    Result := False;
  end;
end;

function StopInstalledApplicationAt(const AppDirectory: String; var ErrorMessage: String): Boolean;
var
  AppPath: String;
  ExitCode: Integer;
begin
  Result := True;
  ErrorMessage := '';
  AppPath := AddBackslash(AppDirectory) + 'codex-bridge-windows-app.exe';
  if not FileExists(AppPath) then
    Exit;
  if not Exec(AppPath, '--shutdown', AppDirectory, SW_HIDE,
              ewWaitUntilTerminated, ExitCode) or (ExitCode <> 0) then
  begin
    ErrorMessage := 'Codex Bridge could not stop its desktop application. Close the app and try again.';
    Result := False;
  end;
end;

function StopInstalledProcessesAt(const AppDirectory: String; var ErrorMessage: String): Boolean;
begin
  ErrorMessage := '';
  if not FileExists(AddBackslash(AppDirectory) + 'CodexBridgeControl.v1') then
  begin
    Result := True;
    Exit;
  end;
  Result := StopInstalledApplicationAt(AppDirectory, ErrorMessage);
  if Result then
    Result := StopInstalledServiceAt(AppDirectory, ErrorMessage);
end;

function StopInstalledProcesses(var ErrorMessage: String): Boolean;
begin
  Result := StopInstalledProcessesAt(ExpandConstant('{app}'), ErrorMessage);
end;

procedure RemoveRunEntryForPath(const AppDirectory: String);
var
  ConfiguredCommand: String;
  InstalledCommand: String;
begin
  InstalledCommand := '"' + AddBackslash(AppDirectory) + 'codex-bridge-service.exe"';
  if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run',
       'CodexBridgeService', ConfiguredCommand) and
     (CompareText(ConfiguredCommand, InstalledCommand) = 0) then
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run',
      'CodexBridgeService');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  CurrentDirectory: String;
begin
  Result := '';
  CurrentDirectory := NormalizeInstallPath(ExpandConstant('{app}'));
  PreviousInstallDirectory := FindPreviousInstallDirectory;
  if (PreviousInstallDirectory <> '') and
     (CompareText(PreviousInstallDirectory, CurrentDirectory) <> 0) then
  begin
    if DirExists(PreviousInstallDirectory) and
       HasReparseDirectoryAt(
         AddBackslash(PreviousInstallDirectory) + 'payload-check',
         PreviousInstallDirectory) then
    begin
      Result := 'Codex Bridge found an unsafe previous application directory.';
      Exit;
    end;
    if not StopInstalledProcessesAt(PreviousInstallDirectory, Result) then
      Exit;
  end;
  if DirExists(ExpandConstant('{app}')) and
     HasReparseDirectory(ExpandConstant('{app}\payload-check')) then
  begin
    Result := 'Codex Bridge found an unsafe application directory.';
    Exit;
  end;
  if not StopInstalledProcesses(Result) then
    Exit;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ErrorMessage: String;
begin
  if CurStep = ssInstall then
  begin
    ErrorMessage := RemoveStalePayloadFiles;
    if ErrorMessage <> '' then
      RaiseException(ErrorMessage);
  end;
  if CurStep = ssPostInstall then
  begin
    if not MigrateServiceRunEntry(PreviousInstallDirectory, ErrorMessage) then
      RaiseException(ErrorMessage);
    if (PreviousInstallDirectory <> '') and
       (CompareText(
         NormalizeInstallPath(PreviousInstallDirectory),
         NormalizeInstallPath(ExpandConstant('{app}'))) <> 0) then
    begin
      ErrorMessage := RemovePreviousInstallPayload(PreviousInstallDirectory);
      if ErrorMessage <> '' then
        RaiseException(ErrorMessage);
    end;
  end;
end;

procedure RegisterPreviousData(PreviousDataKey: Integer);
begin
  SetPreviousData(PreviousDataKey, 'InstallPath',
    NormalizeInstallPath(ExpandConstant('{app}')));
end;

function InitializeUninstall: Boolean;
var
  ErrorMessage: String;
begin
  Result := StopInstalledProcesses(ErrorMessage);
  if not Result then
    SuppressibleMsgBox(ErrorMessage, mbError, MB_OK, IDOK);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RemoveRunEntryForPath(ExpandConstant('{app}'));
end;
