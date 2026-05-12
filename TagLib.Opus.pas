unit TagLib.Opus;

{
  Opus picture extractor.

  Opus reuses the Ogg container, so packet reassembly is identical to
  TagLib.OGG. The metadata packet differs: instead of the Vorbis comment
  header it is the "OpusTags" packet, which still uses the Vorbis-comment
  layout for key=value fields. As with Vorbis, cover art lives under
  METADATA_BLOCK_PICTURE as a Base64-encoded FLAC PICTURE block.
}

interface

uses
  System.SysUtils,
  System.Classes;

type
  TOpusFile = class
  private
    FPath: string;
    function LoadFirstPicture(out AMimeType: string; out APictureData: TBytes): Boolean;
  public
    constructor Create(const AFileName: string);
    function FirstAttachedPicture(out AMimeType: string; out APictureData: TBytes): Boolean;
  end;

implementation

uses
  System.NetEncoding,
  System.StrUtils,
  TagLib.Utils;

constructor TOpusFile.Create(const AFileName: string);
begin
  inherited Create;
  FPath := AFileName;
end;

{ Same Ogg packet reassembly as TagLib.OGG (duplicated to keep each format
  reader self-contained and to avoid cross-unit dependencies on private
  helpers). Reads pages until a segment of length < 255 terminates the
  current packet. }
function TryReadNextOggPacket(Stream: TStream; out Packet: TBytes): Boolean;
var
  Header, SegTable, Chunk: TBytes;
  SegCount, I, SegLen, OldLen: Integer;
  Finished: Boolean;
begin
  SetLength(Packet, 0);
  Result := False;
  Finished := False;
  while not Finished do
  begin
    if Stream.Position + 27 > Stream.Size then
      Exit(False);
    if not ReadBytes(Stream, 27, Header) then
      Exit(False);
    if (Header[0] <> Ord('O')) or (Header[1] <> Ord('g')) or (Header[2] <> Ord('g')) or (Header[3] <> Ord('S')) then
      Exit(False);
    SegCount := Header[26];
    if not ReadBytes(Stream, SegCount, SegTable) then
      Exit(False);
    for I := 0 to SegCount - 1 do
    begin
      SegLen := SegTable[I];
      if not ReadBytes(Stream, SegLen, Chunk) then
        Exit(False);
      OldLen := Length(Packet);
      SetLength(Packet, OldLen + SegLen);
      if SegLen > 0 then
        Move(Chunk[0], Packet[OldLen], SegLen);
      if SegLen < 255 then
      begin
        Finished := True;
        Break;
      end;
    end;
  end;
  Result := Length(Packet) > 0;
end;

function ParseFlacPictureBlob(const PicData: TBytes; out AMimeType: string; out APictureData: TBytes): Boolean;
var
  Pos, MimeLen, DescLen, DataLen: Integer;
  Mime: string;
begin
  Result := False;
  AMimeType := '';
  SetLength(APictureData, 0);
  if Length(PicData) < 32 then
    Exit;
  Pos := 0;
  Inc(Pos, 4); // type
  MimeLen := Integer(ReadUInt32BE(PicData, Pos));
  Inc(Pos, 4);
  if (MimeLen < 0) or (Pos + MimeLen > Length(PicData)) then
    Exit;
  if MimeLen > 0 then
    SetString(Mime, PAnsiChar(@PicData[Pos]), MimeLen)
  else
    Mime := '';
  Inc(Pos, MimeLen);
  DescLen := Integer(ReadUInt32BE(PicData, Pos));
  Inc(Pos, 4);
  if (DescLen < 0) or (Pos + DescLen > Length(PicData)) then
    Exit;
  Inc(Pos, DescLen);
  if Pos + 16 > Length(PicData) then
    Exit;
  Inc(Pos, 16);
  if Pos + 4 > Length(PicData) then
    Exit;
  DataLen := Integer(ReadUInt32BE(PicData, Pos));
  Inc(Pos, 4);
  if (DataLen <= 0) or (Pos + DataLen > Length(PicData)) then
    Exit;
  AMimeType := NormalizeImageMime(Mime);
  if not IsSupportedImageMime(AMimeType) then
    Exit;
  SetLength(APictureData, DataLen);
  Move(PicData[Pos], APictureData[0], DataLen);
  Result := True;
end;

function ReadCommentFieldLE32(const Packet: TBytes; var Pos: Integer; out S: string): Boolean;
var
  L: Integer;
begin
  Result := False;
  S := '';
  if Pos + 4 > Length(Packet) then
    Exit;
  L := Integer(ReadUInt32LE(Packet, Pos));
  Inc(Pos, 4);
  if (L < 0) or (Pos + L > Length(Packet)) then
    Exit;
  if L > 0 then
    SetString(S, PAnsiChar(@Packet[Pos]), L)
  else
    S := '';
  Inc(Pos, L);
  Result := True;
end;

{ Inspect a single Opus packet. If it begins with the 8-byte magic
  "OpusTags", parse the following Vorbis-style comment fields and look
  for METADATA_BLOCK_PICTURE; otherwise return False without raising. }
function TryExtractPictureFromOpusTagsPacket(const Packet: TBytes; out AMimeType: string; out APictureData: TBytes): Boolean;
var
  Pos, I, Count, EqPos: Integer;
  Vendor, Field, Key, Value: string;
  Raw: TBytes;
begin
  Result := False;
  AMimeType := '';
  SetLength(APictureData, 0);
  if Length(Packet) < 8 then
    Exit;
  if (Packet[0] <> Ord('O')) or (Packet[1] <> Ord('p')) or (Packet[2] <> Ord('u')) or (Packet[3] <> Ord('s')) or
     (Packet[4] <> Ord('T')) or (Packet[5] <> Ord('a')) or (Packet[6] <> Ord('g')) or (Packet[7] <> Ord('s')) then
    Exit;
  Pos := 8;
  if not ReadCommentFieldLE32(Packet, Pos, Vendor) then
    Exit;
  if Pos + 4 > Length(Packet) then
    Exit;
  Count := Integer(ReadUInt32LE(Packet, Pos));
  Inc(Pos, 4);
  for I := 0 to Count - 1 do
  begin
    if not ReadCommentFieldLE32(Packet, Pos, Field) then
      Exit(False);
    EqPos := PosEx('=', Field);
    if EqPos < 2 then
      Continue;
    Key := UpperCase(Copy(Field, 1, EqPos - 1));
    Value := Copy(Field, EqPos + 1, MaxInt);
    if Key = 'METADATA_BLOCK_PICTURE' then
    begin
      try
        Raw := TNetEncoding.Base64.DecodeStringToBytes(Value);
      except
        Continue;
      end;
      if ParseFlacPictureBlob(Raw, AMimeType, APictureData) then
        Exit(True);
    end;
  end;
end;

function TOpusFile.LoadFirstPicture(out AMimeType: string; out APictureData: TBytes): Boolean;
var
  FS: TFileStream;
  Packet: TBytes;
begin
  Result := False;
  AMimeType := '';
  SetLength(APictureData, 0);
  try
    FS := TFileStream.Create(FPath, fmOpenRead or fmShareDenyWrite);
    try
      while TryReadNextOggPacket(FS, Packet) do
        if TryExtractPictureFromOpusTagsPacket(Packet, AMimeType, APictureData) then
          Exit(True);
    finally
      FS.Free;
    end;
  except
    Exit(False);
  end;
end;

function TOpusFile.FirstAttachedPicture(out AMimeType: string; out APictureData: TBytes): Boolean;
begin
  Result := LoadFirstPicture(AMimeType, APictureData);
end;

end.
