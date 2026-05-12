unit TagLib.MPEG;

{
  Object Pascal implementation of the TagLib-style MPEG + ID3v2 path:
  open file, read ID3v2 frames, use the first APIC (or v2.2 PIC) whose MIME
  or format is JPEG or PNG, return raw picture bytes. No external DLL required.

  Roughly:
    ReadId3HeaderAndTag  - read the 10-byte ID3v2 header, validate, and pull
                           the tag body (skipping any extended header).
    DeUnsynchronize2     - reverse the "unsynchronization" byte stuffing if
                           the header flagged it.
    ScanId3Frames        - walk frames (APIC for v2.3/v2.4, PIC for v2.2)
                           and stop at the first usable picture.
    ParseApicPayload /
    ParsePicV22Payload   - decode the per-frame layout to MIME + image bytes.
}

interface

uses
  System.SysUtils,
  System.Classes;

type
  TMpegFile = class
  private
    FPath: string;
    function LoadFirstJpegApic(out AMime: string; out AData: TBytes): Boolean;
  public
    constructor Create(const AFileName: string);
    property FileName: string read FPath;
    { Returns True if the first APIC/PIC frame is image/jpeg or image/png with non-empty data. }
    function FirstAttachedPicture(out AMimeType: string; out APictureData: TBytes): Boolean;
  end;

implementation

uses
  System.StrUtils;

{ ID3v2 "synchsafe" 28-bit integer: only the low 7 bits of each byte are used
  so the encoded value can never contain a 0xFF byte (which would otherwise
  collide with the MPEG frame sync). }
function SynchSafeToInt(const B0, B1, B2, B3: Byte): Integer;
begin
  Result := (B0 and $7F) shl 21 or (B1 and $7F) shl 14 or (B2 and $7F) shl 7 or (B3 and $7F);
end;

function ReadId3HeaderAndTag(const APath: string; out TagBody: TBytes; out MajorVer: Byte;
  out Unsync: Boolean): Boolean;
var
  FS: TFileStream;
  Hdr: array[0..9] of Byte;
  ExtBuf: array[0..3] of Byte;
  Major, Flags: Byte;
  TagSize, ExtSize, I, TagBodyLen: Integer;
begin
  Result := False;
  SetLength(TagBody, 0);
  MajorVer := 0;
  Unsync := False;
  FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    if FS.Size < 10 then
      Exit;
    FS.ReadBuffer(Hdr[0], 10);
    if (Hdr[0] <> Ord('I')) or (Hdr[1] <> Ord('D')) or (Hdr[2] <> Ord('3')) then
      Exit;
    Major := Hdr[3];
    MajorVer := Major;
    Flags := Hdr[5];
    Unsync := (Flags and $80) <> 0;
    TagSize := SynchSafeToInt(Hdr[6], Hdr[7], Hdr[8], Hdr[9]);
    if TagSize <= 0 then
      Exit;
    if Int64(10) + TagSize > FS.Size then
      Exit;
    I := 10;
    if (Major >= 3) and ((Flags and $40) <> 0) then
    begin
      if Int64(I) + 4 > FS.Size then
        Exit;
      FS.Position := I;
      FS.ReadBuffer(ExtBuf[0], 4);
      if Major = 4 then
        ExtSize := SynchSafeToInt(ExtBuf[0], ExtBuf[1], ExtBuf[2], ExtBuf[3])
      else
        ExtSize := Integer(Cardinal((Cardinal(ExtBuf[0]) shl 24) or (Cardinal(ExtBuf[1]) shl 16) or
          (Cardinal(ExtBuf[2]) shl 8) or Cardinal(ExtBuf[3])));
      if ExtSize < 4 then
        Exit;
      I := I + ExtSize;
      if I > 10 + TagSize then
        Exit;
    end;
    TagBodyLen := 10 + TagSize - I;
    if TagBodyLen <= 0 then
      Exit;
    SetLength(TagBody, TagBodyLen);
    FS.Position := I;
    FS.ReadBuffer(TagBody[0], TagBodyLen);
    Result := True;
  finally
    FS.Free;
  end;
end;

{ Undo ID3v2 unsynchronization: any 0xFF 0x00 pair was inserted to break
  potential MPEG frame syncs in the tag bytes; here we drop the 0x00. }
function DeUnsynchronize2(const Data: TBytes): TBytes;
var
  R: TBytes;
  I, J, L: Integer;
begin
  L := Length(Data);
  SetLength(R, L);
  J := 0;
  I := 0;
  while I < L do
  begin
    R[J] := Data[I];
    Inc(J);
    if (Data[I] = $FF) and (I + 1 < L) and (Data[I + 1] = $00) then
      Inc(I);
    Inc(I);
  end;
  SetLength(R, J);
  Result := R;
end;

{ Decode an ID3v2.3 / v2.4 APIC frame payload.

  APIC layout:
    [1 byte encoding][MIME (ISO-8859-1, $00-terminated)]
    [1 byte picture type][description (encoding-dependent, $00-terminated)]
    [picture bytes ...]

  Only JPEG and PNG pictures are returned to the caller. }
function ParseApicPayload(const Payload: TBytes; out AMime: string; out AData: TBytes): Boolean;
var
  Enc: Byte;
  Pos, Len: Integer;
  procedure SkipUtf16NullTerminated;
  begin
    while Pos + 1 < Len do
    begin
      if (Payload[Pos] = 0) and (Payload[Pos + 1] = 0) then
      begin
        Inc(Pos, 2);
        Exit;
      end;
      Inc(Pos, 2);
    end;
  end;
  procedure SkipLatin1NullTerminated;
  begin
    while (Pos < Len) and (Payload[Pos] <> 0) do
      Inc(Pos);
    if Pos < Len then
      Inc(Pos);
  end;
begin
  Result := False;
  AMime := '';
  SetLength(AData, 0);
  Len := Length(Payload);
  if Len < 4 then
    Exit;
  Pos := 0;
  Enc := Payload[Pos];
  Inc(Pos);
  { MIME type is ISO-8859-1 / ASCII with trailing $00 }
  while (Pos < Len) and (Payload[Pos] <> 0) do
    Inc(Pos);
  if Pos > 1 then
    SetString(AMime, PAnsiChar(@Payload[1]), Pos - 1)
  else
    AMime := '';
  while (Length(AMime) > 0) and (AMime[Length(AMime)] = #0) do
    SetLength(AMime, Length(AMime) - 1);
  AMime := LowerCase(Trim(AMime));
  if StartsStr('image/jpg', AMime) then
    AMime := 'image/jpeg'
  else if StartsStr('image/jpeg', AMime) then
    AMime := 'image/jpeg'
  else if StartsStr('image/png', AMime) then
    AMime := 'image/png';
  if Pos < Len then
    Inc(Pos); // skip $00
  if Pos >= Len then
    Exit;
  Inc(Pos); { picture type }
  case Enc of
    0, 3:
      SkipLatin1NullTerminated;
    1, 2:
      SkipUtf16NullTerminated;
  else
    SkipLatin1NullTerminated;
  end;
  if Pos > Len then
    Exit;
  if Len - Pos <= 0 then
    Exit;
  SetLength(AData, Len - Pos);
  if Length(AData) > 0 then
    Move(Payload[Pos], AData[0], Length(AData));
  Result := (Length(AData) > 0) and (SameText(AMime, 'image/jpeg') or SameText(AMime, 'image/png'));
  if not Result then
  begin
    AMime := '';
    SetLength(AData, 0);
  end;
end;

{ Decode an ID3v2.2 PIC frame payload (older 3-char format identifier
  instead of a MIME string: 'JPG' or 'PNG'). }
function ParsePicV22Payload(const Payload: TBytes; out AMime: string; out AData: TBytes): Boolean;
var
  Pos, Len: Integer;
  Fmt: string;
begin
  Result := False;
  AMime := '';
  SetLength(AData, 0);
  Len := Length(Payload);
  if Len < 6 then
    Exit;
  Pos := 1; { after encoding byte at 0 }
  { 3-char image format }
  SetString(Fmt, PAnsiChar(@Payload[Pos]), 3);
  Inc(Pos, 3);
  Inc(Pos); { picture type }
  { description: ISO, null-terminated }
  while (Pos < Len) and (Payload[Pos] <> 0) do
    Inc(Pos);
  if Pos < Len then
    Inc(Pos);
  if Pos >= Len then
    Exit;
  if SameText(Trim(Fmt), 'JPG') then
    AMime := 'image/jpeg'
  else if SameText(Trim(Fmt), 'PNG') then
    AMime := 'image/png'
  else
    Exit;
  SetLength(AData, Len - Pos);
  if Length(AData) > 0 then
    Move(Payload[Pos], AData[0], Length(AData));
  Result := Length(AData) > 0;
end;

{ Walks the tag body frame-by-frame. For v2.2 each frame header is 6 bytes
  (3-char id + 3-byte size), for v2.3 / v2.4 it is 10 bytes (4-char id +
  4-byte size + 2-byte flags). v2.4 uses synchsafe size fields. Stops at
  the first frame that yields a JPEG/PNG. }
function ScanId3Frames(const TagBody: TBytes; MajorVer: Byte; out AMime: string; out AData: TBytes): Boolean;
var
  Offset, FrameLen, TagLen: Integer;
  FrameId: string;
  Payload: TBytes;
  B0, B1, B2, B3: Byte;
begin
  Result := False;
  AMime := '';
  SetLength(AData, 0);
  TagLen := Length(TagBody);
  Offset := 0;
  if MajorVer = 2 then
  begin
    while Offset + 6 <= TagLen do
    begin
      SetString(FrameId, PAnsiChar(@TagBody[Offset]), 3);
      FrameLen := (TagBody[Offset + 3] shl 16) or (TagBody[Offset + 4] shl 8) or TagBody[Offset + 5];
      Inc(Offset, 6);
      if FrameLen < 0 then
        Break;
      if Offset + FrameLen > TagLen then
        Break;
      SetLength(Payload, FrameLen);
      Move(TagBody[Offset], Payload[0], FrameLen);
      Inc(Offset, FrameLen);
      if FrameId = 'PIC' then
      begin
        if ParsePicV22Payload(Payload, AMime, AData) then
          Exit(True);
      end;
    end;
    Exit;
  end;
  while Offset + 10 <= TagLen do
  begin
    SetString(FrameId, PAnsiChar(@TagBody[Offset]), 4);
    if FrameId = #0#0#0#0 then
      Break;
    B0 := TagBody[Offset + 4];
    B1 := TagBody[Offset + 5];
    B2 := TagBody[Offset + 6];
    B3 := TagBody[Offset + 7];
    if MajorVer = 4 then
      FrameLen := SynchSafeToInt(B0, B1, B2, B3)
    else
      FrameLen := (B0 shl 24) or (B1 shl 16) or (B2 shl 8) or B3;
    Inc(Offset, 10);
    if FrameLen <= 0 then
      Break;
    if Offset + FrameLen > TagLen then
      Break;
    SetLength(Payload, FrameLen);
    Move(TagBody[Offset], Payload[0], FrameLen);
    Inc(Offset, FrameLen);
    if FrameId = 'APIC' then
    begin
      if ParseApicPayload(Payload, AMime, AData) then
        Exit(True);
    end;
  end;
end;

function TMpegFile.LoadFirstJpegApic(out AMime: string; out AData: TBytes): Boolean;
var
  TagBody: TBytes;
  Major: Byte;
  UnsyncFlag: Boolean;
begin
  Result := False;
  AMime := '';
  SetLength(AData, 0);
  if not ReadId3HeaderAndTag(FPath, TagBody, Major, UnsyncFlag) then
    Exit;
  if UnsyncFlag then
    TagBody := DeUnsynchronize2(TagBody);
  Result := ScanId3Frames(TagBody, Major, AMime, AData);
end;

constructor TMpegFile.Create(const AFileName: string);
begin
  inherited Create;
  FPath := AFileName;
end;

function TMpegFile.FirstAttachedPicture(out AMimeType: string; out APictureData: TBytes): Boolean;
begin
  Result := LoadFirstJpegApic(AMimeType, APictureData);
end;

end.
