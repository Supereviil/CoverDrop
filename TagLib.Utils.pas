unit TagLib.Utils;

{
  Low-level binary read helpers shared by the TagLib.* format readers
  (FLAC, M4A, OGG, Opus, WMA). Two flavours:

    * Read*BE / Read*LE / ReadUInt24BE - extract an integer of the given
      size and endianness from a TBytes buffer at a fixed offset.
    * ReadBytes / TryRead* - read directly from a TStream, returning False
      when the stream would underflow rather than raising.

  Also a tiny MIME + magic-byte helper set so format readers can normalise
  the image MIME (jpg/jpeg/png variants) and sniff data when no MIME is
  given.
}

interface

uses
  System.SysUtils,
  System.Classes;

{ Fixed-width integer readers from a TBytes buffer. }
function ReadUInt16BE(const B: TBytes; Offset: Integer): Word;
function ReadUInt32BE(const B: TBytes; Offset: Integer): Cardinal;
function ReadUInt32LE(const B: TBytes; Offset: Integer): Cardinal;
function ReadUInt64BE(const B: TBytes; Offset: Integer): UInt64;
function ReadUInt64LE(const B: TBytes; Offset: Integer): UInt64;
function ReadUInt24BE(const B: TBytes; Offset: Integer): Cardinal;

{ Bounds-checked stream readers. ReadBytes never raises on EOF; it just
  returns False so callers can bail gracefully on truncated files. }
function ReadBytes(Stream: TStream; Count: Integer; out Data: TBytes): Boolean;
function TryReadUInt32BE(Stream: TStream; out Value: Cardinal): Boolean;
function TryReadUInt64BE(Stream: TStream; out Value: UInt64): Boolean;

{ Image MIME helpers. NormalizeImageMime maps the various spellings
  ('jpg' / 'image/jpg' / 'JPEG' / ...) to a canonical 'image/jpeg' or
  'image/png', or '' when unsupported. }
function NormalizeImageMime(const Mime: string): string;
function IsSupportedImageMime(const Mime: string): Boolean;

{ Raw byte signature checks for use when a container does not carry MIME. }
function LooksLikeJpeg(const Data: TBytes): Boolean;
function LooksLikePng(const Data: TBytes): Boolean;

implementation

function ReadUInt16BE(const B: TBytes; Offset: Integer): Word;
begin
  Result := (Word(B[Offset]) shl 8) or Word(B[Offset + 1]);
end;

function ReadUInt32BE(const B: TBytes; Offset: Integer): Cardinal;
begin
  Result := (Cardinal(B[Offset]) shl 24) or (Cardinal(B[Offset + 1]) shl 16) or
    (Cardinal(B[Offset + 2]) shl 8) or Cardinal(B[Offset + 3]);
end;

function ReadUInt32LE(const B: TBytes; Offset: Integer): Cardinal;
begin
  Result := Cardinal(B[Offset]) or (Cardinal(B[Offset + 1]) shl 8) or
    (Cardinal(B[Offset + 2]) shl 16) or (Cardinal(B[Offset + 3]) shl 24);
end;

function ReadUInt64BE(const B: TBytes; Offset: Integer): UInt64;
begin
  Result := (UInt64(B[Offset]) shl 56) or (UInt64(B[Offset + 1]) shl 48) or
    (UInt64(B[Offset + 2]) shl 40) or (UInt64(B[Offset + 3]) shl 32) or
    (UInt64(B[Offset + 4]) shl 24) or (UInt64(B[Offset + 5]) shl 16) or
    (UInt64(B[Offset + 6]) shl 8) or UInt64(B[Offset + 7]);
end;

function ReadUInt64LE(const B: TBytes; Offset: Integer): UInt64;
begin
  Result := UInt64(B[Offset]) or (UInt64(B[Offset + 1]) shl 8) or
    (UInt64(B[Offset + 2]) shl 16) or (UInt64(B[Offset + 3]) shl 24) or
    (UInt64(B[Offset + 4]) shl 32) or (UInt64(B[Offset + 5]) shl 40) or
    (UInt64(B[Offset + 6]) shl 48) or (UInt64(B[Offset + 7]) shl 56);
end;

function ReadUInt24BE(const B: TBytes; Offset: Integer): Cardinal;
begin
  Result := (Cardinal(B[Offset]) shl 16) or (Cardinal(B[Offset + 1]) shl 8) or Cardinal(B[Offset + 2]);
end;

function ReadBytes(Stream: TStream; Count: Integer; out Data: TBytes): Boolean;
begin
  { Returns False (with Data = empty) when reading Count bytes would run past
    the end of the stream. Otherwise reads exactly Count bytes into Data. }
  SetLength(Data, 0);
  Result := False;
  if (Count < 0) or (Int64(Stream.Position) + Count > Stream.Size) then
    Exit;
  SetLength(Data, Count);
  if Count > 0 then
    Stream.ReadBuffer(Data[0], Count);
  Result := True;
end;

function TryReadUInt32BE(Stream: TStream; out Value: Cardinal): Boolean;
var
  B: TBytes;
begin
  Result := ReadBytes(Stream, 4, B);
  if not Result then
    Exit;
  Value := ReadUInt32BE(B, 0);
end;

function TryReadUInt64BE(Stream: TStream; out Value: UInt64): Boolean;
var
  B: TBytes;
begin
  Result := ReadBytes(Stream, 8, B);
  if not Result then
    Exit;
  Value := ReadUInt64BE(B, 0);
end;

function NormalizeImageMime(const Mime: string): string;
var
  M: string;
begin
  { Map the common spellings tag writers actually emit to the two MIME
    strings the extractor knows how to handle. Anything else -> ''. }
  M := LowerCase(Trim(Mime));
  if (M = 'image/jpg') or (M = 'jpg') or (M = 'jpeg') then
    Exit('image/jpeg');
  if (M = 'image/jpeg') then
    Exit('image/jpeg');
  if (M = 'image/png') or (M = 'png') then
    Exit('image/png');
  Result := '';
end;

function IsSupportedImageMime(const Mime: string): Boolean;
begin
  Result := (Mime = 'image/jpeg') or (Mime = 'image/png');
end;

function LooksLikeJpeg(const Data: TBytes): Boolean;
begin
  { JPEG SOI marker: FF D8 FF ... }
  Result := (Length(Data) >= 3) and (Data[0] = $FF) and (Data[1] = $D8) and (Data[2] = $FF);
end;

function LooksLikePng(const Data: TBytes): Boolean;
begin
  { PNG 8-byte signature: 89 50 4E 47 0D 0A 1A 0A }
  Result := (Length(Data) >= 8) and (Data[0] = $89) and (Data[1] = $50) and (Data[2] = $4E) and
    (Data[3] = $47) and (Data[4] = $0D) and (Data[5] = $0A) and (Data[6] = $1A) and (Data[7] = $0A);
end;

end.
