function NormalizeInstallPath(const Value: String): String;
begin
  Result := Trim(Value);
  if (Length(Result) >= 2) and (Result[1] = '"') and
     (Result[Length(Result)] = '"') then
  begin
    Delete(Result, Length(Result), 1);
    Delete(Result, 1, 1);
  end;
  StringChangeEx(Result, '/', '\', True);
  Result := RemoveBackslashUnlessRoot(Result);
end;

function IsAbsoluteInstallPath(const Value: String): Boolean;
begin
  Result := ((Length(Value) >= 3) and (Value[2] = ':') and
             ((Value[3] = '\') or (Value[3] = '/'))) or
            ((Length(Value) >= 2) and (Value[1] = '\') and (Value[2] = '\'));
end;

function FindPreviousInstallDirectory: String;
var
  RegistryPath: String;
begin
  Result := NormalizeInstallPath(GetPreviousData('InstallPath', ''));
  if Result = '' then
  begin
    if RegQueryStringValue(HKCU, PreviousInstallUninstallKey,
         'InstallLocation', RegistryPath) then
      Result := NormalizeInstallPath(RegistryPath);
  end;
  if not IsAbsoluteInstallPath(Result) then
    Result := '';
end;

function RemovePreviousFile(const AppDirectory: String;
  const RelativePath: String): String;
var
  InstalledPath: String;
begin
  Result := '';
  InstalledPath := AddBackslash(AppDirectory) + RelativePath;
  if not FileExists(InstalledPath) then
    Exit;
  if HasReparseDirectoryAt(InstalledPath, AppDirectory) then
  begin
    Result := 'Codex Bridge found an unsafe previous application directory.';
    Exit;
  end;
  if not DeleteFile(InstalledPath) then
    Result := 'Codex Bridge could not remove an obsolete previous application file.';
  if Result = '' then
    RemoveEmptyParentsAt(InstalledPath, AppDirectory);
end;

function RemovePreviousSHA256Payload(const AppDirectory: String): String;
var
  I: Integer;
  ManifestFile: String;
  Lines: TArrayOfString;
  RelativePath: String;
  InstalledPath: String;
begin
  Result := '';
  ManifestFile := AddBackslash(AppDirectory) + 'SHA256SUMS.txt';
  if not FileExists(ManifestFile) then
    Exit;
  if not LoadStringsFromFile(ManifestFile, Lines) then
  begin
    Result := 'Codex Bridge could not read the previous payload manifest.';
    Exit;
  end;

  for I := 0 to GetArrayLength(Lines) - 1 do
  begin
    RelativePath := ManifestPath(Lines[I]);
    if not IsSafeRelativePath(RelativePath) then
      Continue;
    InstalledPath := AddBackslash(AppDirectory) + RelativePath;
    if FileExists(InstalledPath) and
       HasReparseDirectoryAt(InstalledPath, AppDirectory) then
    begin
      Result := 'Codex Bridge found an unsafe previous application directory.';
      Exit;
    end;
    if FileExists(InstalledPath) and not DeleteFile(InstalledPath) then
    begin
      Result := 'Codex Bridge could not remove an obsolete previous application file.';
      Exit;
    end;
    RemoveEmptyParentsAt(InstalledPath, AppDirectory);
  end;
  if FileExists(ManifestFile) and not DeleteFile(ManifestFile) then
    Result := 'Codex Bridge could not remove the previous payload manifest.';
end;

function RemovePreviousInstallPayload(const AppDirectory: String): String;
var
  I: Integer;
  KnownFiles: TArrayOfString;
  RelativePath: String;
begin
  Result := '';
  if not DirExists(AppDirectory) then
    Exit;

  Result := RemovePreviousSHA256Payload(AppDirectory);
  if Result <> '' then
    Exit;
  if FileExists(AddBackslash(AppDirectory) + 'payload-manifest.json') then
  begin
    Result := RemoveLegacyPayloadFilesAt(AppDirectory, '');
    if Result <> '' then
      Exit;
    if FileExists(AddBackslash(AppDirectory) + 'payload-manifest.json') and
       not DeleteFile(AddBackslash(AppDirectory) + 'payload-manifest.json') then
    begin
      Result := 'Codex Bridge could not remove the previous payload manifest.';
      Exit;
    end;
  end;

  SetArrayLength(KnownFiles, 6);
  KnownFiles[0] := 'BUILD-INFO.json';
  KnownFiles[1] := 'AppIcon.ico';
  KnownFiles[2] := 'CodexBridgeControl.v1';
  KnownFiles[3] := 'unins000.exe';
  KnownFiles[4] := 'unins000.dat';
  KnownFiles[5] := 'unins000.msg';
  for I := 0 to GetArrayLength(KnownFiles) - 1 do
  begin
    RelativePath := KnownFiles[I];
    Result := RemovePreviousFile(AppDirectory, RelativePath);
    if Result <> '' then
      Exit;
  end;
  RemoveDir(AppDirectory);
end;

function MigrateServiceRunEntry(const PreviousDirectory: String;
  var ErrorMessage: String): Boolean;
var
  ConfiguredCommand: String;
  CurrentDirectory: String;
  CurrentCommand: String;
  CurrentServiceCommand: String;
  CommandDirectory: String;
  PreviousGuiCommand: String;
  PreviousServiceCommand: String;
begin
  Result := True;
  ErrorMessage := '';
  if not RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run',
       'CodexBridgeService', ConfiguredCommand) then
    Exit;

  CurrentDirectory := NormalizeInstallPath(ExpandConstant('{app}'));
  CurrentCommand := GuiRunCommand(CurrentDirectory);
  if SameRunCommand(ConfiguredCommand, CurrentCommand) then
    Exit;
  CurrentServiceCommand := ServiceRunCommand(CurrentDirectory);
  CommandDirectory := NormalizeInstallPath(PreviousDirectory);
  if SameRunCommand(ConfiguredCommand, CurrentServiceCommand) then
    CommandDirectory := CurrentDirectory;
  if CommandDirectory = '' then
    Exit;
  PreviousGuiCommand := GuiRunCommand(CommandDirectory);
  PreviousServiceCommand := ServiceRunCommand(CommandDirectory);
  if not SameRunCommand(ConfiguredCommand, PreviousGuiCommand) and
     not SameRunCommand(ConfiguredCommand, PreviousServiceCommand) then
    Exit;
  if not RegWriteStringValue(HKCU,
       'Software\Microsoft\Windows\CurrentVersion\Run',
       'CodexBridgeService', CurrentCommand) then
  begin
    ErrorMessage := 'Codex Bridge could not move its startup registration to the new application directory.';
    Result := False;
  end;
end;
