unit TagLib.OGG;

{
  Ogg Vorbis picture extractor.

  An Ogg stream is a sequence of pages, each carrying segments that
  reassemble into logical "packets". For Vorbis the second packet
  (id 0x03 "vorbis") is the comment header, which contains key=value
  metadata fields. Cover art is stored as a Base64-encoded FLAC PICTURE
  block under the field METADATA_BLOCK_PICTURE.

  Flow:
    TryReadNextOggPacket             -> reassemble next logical packet.
    TryExtractPictureFromVorbisCommentPacket
                                     -> if it is the comment packet,
                                        find METADATA_BLOCK_PICTURE.
    ParseFlacPictureBlob             -> decode the (decoded-Base64) FLAC
                                        picture-block bytes.
}

interface

uses
  System.SysUtils,
  System.Classes;

type
  TOggFile = class
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

constructor TOggFile.Create(const AFileName: string);
begin
  inherited Create;
  FPath := AFileName;
end;

{ Decode the same FLAC PICTURE block layout as TagLib.FLAC, but coming
  from a Base64-decoded Vorbis comment field rather than a FLAC file. }
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

{ Reads a single Vorbis-comment string: a little-endian u32 length followed
  by that many UTF-8 bytes. Advances Pos past the field. }
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

{ Inspect a single Ogg packet. If it is the Vorbis comment header (signature
  byte 0x03 followed by "vorbis"), walk its key=value fields, find
  METADATA_BLOCK_PICTURE, Base64-decode, and parse the embedded FLAC picture
  block. Returns False (without raising) for any packet that is not the
  comment header. }
function TryExtractPictureFromVorbisCommentPacket(const Packet: TBytes; out AMimeType: string; out APictureData: TBytes): Boolean;
var
  Pos, I, Count, EqPos: Integer;
  Vendor, Field, Key, Value: string;
  Raw: TBytes;
begin
  Result := False;
  AMimeType := '';
  SetLength(APictureData, 0);
  if (Length(Packet) < 7) or (Packet[0] <> 3) then
    Exit;
  if (Packet[1] <> Ord('v')) or (Packet[2] <> Ord('o')) or (Packet[3] <> Ord('r')) or
     (Packet[4] <> Ord('b')) or (Packet[5] <> Ord('i')) or (Packet[6] <> Ord('s')) then
    Exit;
  Pos := 7;
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

{ Reassemble the next logical Ogg packet by concatenating segments from one
  or more pages. A segment of length < 255 marks the end of the packet; a
  255-byte segment means "more bytes follow in the next segment/page". }
function TryReadNextOggPacket(Stream: TStream; out Packet: TBytes): Boolean;
var
  Header, SegTable, Chunk: TBytes;
  SegCount: Integer;
  I, SegLen: Integer;
  Finished: Boolean;
  OldLen: Integer;
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

function TOggFile.LoadFirstPicture(out AMimeType: string; out APictureData: TBytes): Boolean;
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
      // Ogg Vorbis comment packet is generally packet 2; scan packets until found.
      while TryReadNextOggPacket(FS, Packet) do
        if TryExtractPictureFromVorbisCommentPacket(Packet, AMimeType, APictureData) then
          Exit(True);
    finally
      FS.Free;
    end;
  except
    Exit(False);
  end;
end;

function TOggFile.FirstAttachedPicture(out AMimeType: string; out APictureData: TBytes): Boolean;
begin
  Result := LoadFirstPicture(AMimeType, APictureData);
end;

end.
