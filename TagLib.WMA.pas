unit TagLib.WMA;

{
  WMA / ASF picture extractor.

  ASF files are a sequence of GUID-identified objects. The first object is
  the ASF Header Object, which contains a count followed by a list of
  sub-objects. We only care about the Extended Content Description Object
  (where Windows Media tools store the WM/Picture attribute as a packed
  blob). ParseWmPictureBlob decodes that blob into MIME + image bytes.

  All multi-byte fields here are little-endian.
}

interface

uses
  System.SysUtils,
  System.Classes;

type
  TWmaFile = class
  private
    FPath: string;
    function LoadFirstPicture(out AMimeType: string; out APictureData: TBytes): Boolean;
  public
    constructor Create(const AFileName: string);
    function FirstAttachedPicture(out AMimeType: string; out APictureData: TBytes): Boolean;
  end;

implementation

uses
  TagLib.Utils;

const
  { Well-known ASF object GUIDs (from the Microsoft ASF spec). }
  ASF_Header_Object: TGUID = '{75B22630-668E-11CF-A6D9-00AA0062CE6C}';
  ASF_Extended_Content_Description_Object: TGUID = '{D2D0A440-E307-11D2-97F0-00A0C95EA850}';

constructor TWmaFile.Create(const AFileName: string);
begin
  inherited Create;
  FPath := AFileName;
end;

{ Build a TGUID from the 16 bytes ASF stores at the start of each object.
  D1/D2/D3 are little-endian; D4 is a fixed 8-byte array. }
function BytesToGuid(const B: TBytes): TGUID;
begin
  Result.D1 := ReadUInt32LE(B, 0);
  Result.D2 := (B[4]) or (B[5] shl 8);
  Result.D3 := (B[6]) or (B[7] shl 8);
  Move(B[8], Result.D4[0], 8);
end;

{ Read a UTF-16LE string slice from a byte buffer and strip trailing NULs. }
function ReadUtf16LeString(const B: TBytes; Offset, ByteLen: Integer): string;
begin
  if (ByteLen <= 0) or (Offset < 0) or (Offset + ByteLen > Length(B)) then
    Exit('');
  Result := TEncoding.Unicode.GetString(B, Offset, ByteLen);
  while (Length(Result) > 0) and (Result[Length(Result)] = #0) do
    SetLength(Result, Length(Result) - 1);
end;

{ Decode a WM/Picture blob.

  Layout (little-endian throughout):
    [1 byte picture type][u32 picture data length]
    [MIME (UTF-16LE, $00 $00-terminated)]
    [description (UTF-16LE, $00 $00-terminated)]
    [picture bytes ...]

  The description is parsed only to keep Pos in sync; it is not used. }
function ParseWmPictureBlob(const Blob: TBytes; out AMimeType: string; out APictureData: TBytes): Boolean;
var
  Pos, DataLen, MimeStart, DescStart: Integer;
  Mime, Desc: string;
begin
  Result := False;
  AMimeType := '';
  SetLength(APictureData, 0);
  if Length(Blob) < 7 then
    Exit;

  Pos := 0;
  Inc(Pos); // picture type
  if Pos + 4 > Length(Blob) then
    Exit;
  DataLen := Integer(ReadUInt32LE(Blob, Pos));
  Inc(Pos, 4);
  MimeStart := Pos;
  while Pos + 1 < Length(Blob) do
  begin
    if (Blob[Pos] = 0) and (Blob[Pos + 1] = 0) then
      Break;
    Inc(Pos, 2);
  end;
  if Pos + 1 >= Length(Blob) then
    Exit;
  Mime := ReadUtf16LeString(Blob, MimeStart, Pos - MimeStart);
  Inc(Pos, 2); // null terminator

  DescStart := Pos;
  while Pos + 1 < Length(Blob) do
  begin
    if (Blob[Pos] = 0) and (Blob[Pos + 1] = 0) then
      Break;
    Inc(Pos, 2);
  end;
  if Pos + 1 >= Length(Blob) then
    Exit;
  Desc := ReadUtf16LeString(Blob, DescStart, Pos - DescStart);
  Inc(Pos, 2); // description terminator
  if Desc <> '' then
  begin
    // Description is parsed for structure correctness but not used.
  end;

  if (DataLen <= 0) or (Pos + DataLen > Length(Blob)) then
    Exit;
  AMimeType := NormalizeImageMime(Mime);
  if not IsSupportedImageMime(AMimeType) then
    Exit;

  SetLength(APictureData, DataLen);
  Move(Blob[Pos], APictureData[0], DataLen);
  Result := True;
end;

{ Walk the Extended Content Description Object's attribute list.

  Object body layout: u16 attribute-count, then for each attribute:
    u16 NameLen, NameLen bytes UTF-16LE name,
    u16 ValueType, u16 ValueLen, ValueLen bytes value.

  Two attributes are of interest: WM/Picture (the actual picture blob)
  and WM/PictureMimeType (older MIME-only attribute kept for parsing
  completeness, but the blob remains authoritative). }
function ParseExtendedContentDescription(Stream: TStream; ObjectSize: UInt64;
  out AMimeType: string; out APictureData: TBytes): Boolean;
var
  Buf: TBytes;
  Pos, I, Count: Integer;
  NameLen, ValueType, ValueLen: Word;
  Name, ValueText: string;
  ValueBytes: TBytes;
begin
  Result := False;
  AMimeType := '';
  SetLength(APictureData, 0);
  if ObjectSize < 24 then
    Exit;
  if not ReadBytes(Stream, Integer(ObjectSize - 24), Buf) then
    Exit;
  Pos := 0;
  if Length(Buf) < 2 then
    Exit;
  Count := (Buf[0]) or (Buf[1] shl 8);
  Pos := 2;
  for I := 0 to Count - 1 do
  begin
    if Pos + 6 > Length(Buf) then
      Exit(False);
    NameLen := (Buf[Pos]) or (Buf[Pos + 1] shl 8);
    Inc(Pos, 2);
    if Pos + NameLen > Length(Buf) then
      Exit(False);
    Name := ReadUtf16LeString(Buf, Pos, NameLen);
    Inc(Pos, NameLen);
    if Pos + 4 > Length(Buf) then
      Exit(False);
    ValueType := (Buf[Pos]) or (Buf[Pos + 1] shl 8);
    Inc(Pos, 2);
    ValueLen := (Buf[Pos]) or (Buf[Pos + 1] shl 8);
    Inc(Pos, 2);
    if Pos + ValueLen > Length(Buf) then
      Exit(False);
    SetLength(ValueBytes, ValueLen);
    if ValueLen > 0 then
      Move(Buf[Pos], ValueBytes[0], ValueLen);
    Inc(Pos, ValueLen);

    if SameText(Name, 'WM/Picture') then
    begin
      if ParseWmPictureBlob(ValueBytes, AMimeType, APictureData) then
        Exit(True);
    end
    else if (ValueType = 0) and SameText(Name, 'WM/PictureMimeType') then
    begin
      ValueText := ReadUtf16LeString(ValueBytes, 0, Length(ValueBytes));
      if ValueText <> '' then
      begin
        // Parsed for compatibility, but WM/Picture blob is authoritative.
      end;
    end;
  end;
end;

{ Read the ASF Header Object, then iterate its child objects. Each child
  has a 16-byte GUID + 8-byte size header; we descend into the Extended
  Content Description Object (the one carrying WM/Picture) and skip
  everything else. Any IO/parse error returns False so the caller can
  fall back gracefully. }
function TWmaFile.LoadFirstPicture(out AMimeType: string; out APictureData: TBytes): Boolean;
var
  FS: TFileStream;
  GuidBytes: TBytes;
  ObjGuid: TGUID;
  ObjSize: UInt64;
  HeaderRest: TBytes;
  ObjectCount, I: Integer;
  SkipLen: Int64;
begin
  Result := False;
  AMimeType := '';
  SetLength(APictureData, 0);
  try
    FS := TFileStream.Create(FPath, fmOpenRead or fmShareDenyWrite);
    try
      if not ReadBytes(FS, 16, GuidBytes) then
        Exit;
      ObjGuid := BytesToGuid(GuidBytes);
      if not ReadBytes(FS, 8, HeaderRest) then
        Exit;
      ObjSize := ReadUInt64LE(HeaderRest, 0);
      if not IsEqualGUID(ObjGuid, ASF_Header_Object) then
        Exit;
      if (ObjSize < 30) or (ObjSize > UInt64(FS.Size)) then
        Exit;
      if not ReadBytes(FS, 6, HeaderRest) then
        Exit;
      ObjectCount := Integer(ReadUInt32LE(HeaderRest, 0));

      for I := 0 to ObjectCount - 1 do
      begin
        if FS.Position + 24 > FS.Size then
          Break;
        if not ReadBytes(FS, 16, GuidBytes) then
          Exit(False);
        ObjGuid := BytesToGuid(GuidBytes);
        if not ReadBytes(FS, 8, HeaderRest) then
          Exit(False);
        ObjSize := ReadUInt64LE(HeaderRest, 0);
        if ObjSize < 24 then
          Exit(False);

        if IsEqualGUID(ObjGuid, ASF_Extended_Content_Description_Object) then
        begin
          if ParseExtendedContentDescription(FS, ObjSize, AMimeType, APictureData) then
            Exit(True)
          else
            Exit(False);
        end
        else
        begin
          SkipLen := Int64(ObjSize) - 24;
          if (SkipLen < 0) or (FS.Position + SkipLen > FS.Size) then
            Exit(False);
          FS.Position := FS.Position + SkipLen;
        end;
      end;
    finally
      FS.Free;
    end;
  except
    Exit(False);
  end;
end;

function TWmaFile.FirstAttachedPicture(out AMimeType: string; out APictureData: TBytes): Boolean;
begin
  Result := LoadFirstPicture(AMimeType, APictureData);
end;

end.
