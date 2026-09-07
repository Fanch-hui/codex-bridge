function LegacyManifestPath(const Line: String): String;
var
  Prefix: String;
  Value: String;
begin
  Result := '';
  Prefix := '"path": "';
  Value := Trim(Line);
  if Pos(Prefix, Value) <> 1 then
    Exit;
  Delete(Value, 1, Length(Prefix));
  if (Length(Value) > 0) and (Value[Length(Value)] = ',') then
    Delete(Value, Length(Value), 1);
  if (Length(Value) < 2) or (Value[Length(Value)] <> '"') then
    Exit;
  Delete(Value, Length(Value), 1);
  StringChangeEx(Value, '/', '\', True);
  Result := Value;
end;

function RemoveLegacyPayloadFilesAt(const AppDirectory: String; const NewManifest: String): String;
var
  I: Integer;
  InstalledManifest: String;
  LegacyLines: TArrayOfString;
  NewLines: TArrayOfString;
  RelativePath: String;
  InstalledPath: String;
begin
  Result := '';
  InstalledManifest := AddBackslash(AppDirectory) + 'payload-manifest.json';
  if not FileExists(InstalledManifest) then
    Exit;
  if not LoadStringsFromFile(InstalledManifest, LegacyLines) then
  begin
    Result := 'Codex Bridge could not read its legacy payload manifest.';
    Exit;
  end;
  if NewManifest <> '' then
  begin
    if not LoadStringsFromFile(NewManifest, NewLines) then
    begin
      Result := 'Codex Bridge could not read its current payload manifest.';
      Exit;
    end;
  end
  else
    SetArrayLength(NewLines, 0);

  for I := 0 to GetArrayLength(LegacyLines) - 1 do
  begin
    RelativePath := LegacyManifestPath(LegacyLines[I]);
    if not IsSafeRelativePath(RelativePath) then
      Continue;
    if ManifestContains(NewLines, RelativePath) then
      Continue;
    InstalledPath := AddBackslash(AppDirectory) + RelativePath;
    if FileExists(InstalledPath) and
       HasReparseDirectoryAt(InstalledPath, AppDirectory) then
    begin
      Result := 'Codex Bridge found an unsafe legacy application directory.';
      Exit;
    end;
    if FileExists(InstalledPath) and not DeleteFile(InstalledPath) then
    begin
      Result := 'Codex Bridge could not remove an obsolete legacy application file.';
      Exit;
    end;
    RemoveEmptyParentsAt(InstalledPath, AppDirectory);
  end;
end;

function RemoveLegacyPayloadFiles(const NewManifest: String): String;
begin
  Result := RemoveLegacyPayloadFilesAt(ExpandConstant('{app}'), NewManifest);
end;
