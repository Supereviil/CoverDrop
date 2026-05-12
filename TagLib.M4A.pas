unit TagLib.M4A;

{
  MP4 / M4A / AAC cover-art extractor.

  MP4 files are a tree of "atoms" (also called boxes). Each atom has an
  8-byte header (4-byte big-endian size + 4-byte ASCII type) and a body
  that is either raw data or further atoms. Cover art lives at:

      moov / udta / meta / ilst / covr / data

  FindCovrInRange descends recursively into known container atoms,
  treating the special 'covr' atom as a parent of 'data' atoms that hold
  the raw image bytes. The 'meta' atom is special-cased because it has
  4 leading bytes (version + flags) before its child atoms.
}

interface

uses
  System.SysUtils,
  System.Classes;

type
  TM4aFile = class
  private
    FPath: string;
    function LoadFirstCover(out AMimeType: string; out APictureData: TBytes): Boolean;
  public
    constructor Create(const AFileName: string);
    function FirstAttachedPicture(out AMimeType: string; out APictureData: TBytes): Boolean;
  end;

implementation

uses
  TagLib.Utils;

constructor TM4aFile.Create(const AFileName: string);
begin
  inherited Create;
  FPath := AFileName;
end;

{ Atoms whose body itself is a list of child atoms. Anything else is a
  leaf and is skipped over. }
function IsMp4ContainerAtom(const AtomType: AnsiString): Boolean;
begin
  Result := (AtomType = 'moov') or (AtomType = 'udta') or (AtomType = 'ilst') or
    (AtomType = 'trak') or (AtomType = 'mdia') or (AtomType = 'minf') or
    (AtomType = 'stbl') or (AtomType = 'meta');
end;

{ Decide the MIME of a covr/data payload.

  The 'data' atom carries a 4-byte "data type" code; the spec defines
  13 = JPEG and 14 = PNG. Many real-world taggers leave it as 0, so when
  the code is unhelpful we fall back to a raw byte-signature sniff. }
function GuessMimeFromDataTypeAndBytes(DataType: Cardinal; const Data: TBytes): string;
begin
  case DataType of
    13: Result := 'image/jpeg';
    14: Result := 'image/png';
  else
    Result := '';
  end;
  if (Result = '') and LooksLikeJpeg(Data) then
    Result := 'image/jpeg'
  else if (Result = '') and LooksLikePng(Data) then
    Result := 'image/png';
end;

{ Recursive atom walker.

  Stream         : the MP4 file.
  RangeStart..   : byte range to scan (a single atom's body, or the whole file).
  IsMetaPayload  : True when scanning the body of a 'meta' atom; the first
                   4 bytes are version+flags and must be skipped before the
                   first child atom.

  Returns the first usable cover atom encountered. Atoms with the "extended
  size" forms (size=1 -> 64-bit size in 8 extra bytes; size=0 -> "until EOF
  of parent") are handled too. }
function FindCovrInRange(Stream: TStream; RangeStart, RangeSize: Int64;
  out AMimeType: string; out APictureData: TBytes; IsMetaPayload: Boolean): Boolean;
var
  Pos, EndPos, PayloadStart, PayloadSize: Int64;
  AtomSize32: Cardinal;
  AtomSize: UInt64;
  AtomTypeBuf: TBytes;
  AtomType: AnsiString;
  HeaderSize: Int64;
  DataHdr: TBytes;
  DataType: Cardinal;
  Data: TBytes;
begin
  Result := False;
  AMimeType := '';
  SetLength(APictureData, 0);

  Pos := RangeStart;
  EndPos := RangeStart + RangeSize;
  if IsMetaPayload then
    Inc(Pos, 4); // version + flags

  while Pos + 8 <= EndPos do
  begin
    Stream.Position := Pos;
    if not TryReadUInt32BE(Stream, AtomSize32) then
      Exit(False);
    if not ReadBytes(Stream, 4, AtomTypeBuf) then
      Exit(False);
    SetString(AtomType, PAnsiChar(@AtomTypeBuf[0]), 4);

    HeaderSize := 8;
    AtomSize := AtomSize32;
    if AtomSize32 = 1 then
    begin
      if not TryReadUInt64BE(Stream, AtomSize) then
        Exit(False);
      HeaderSize := 16;
    end
    else if AtomSize32 = 0 then
      AtomSize := UInt64(EndPos - Pos);

    if (AtomSize < UInt64(HeaderSize)) or (Pos + Int64(AtomSize) > EndPos) then
      Exit(False);

    PayloadStart := Pos + HeaderSize;
    PayloadSize := Int64(AtomSize) - HeaderSize;

    if AtomType = 'covr' then
    begin
      // covr contains child atoms; look for 'data'
      if FindCovrInRange(Stream, PayloadStart, PayloadSize, AMimeType, APictureData, False) then
        Exit(True);
    end
    else if AtomType = 'data' then
    begin
      if PayloadSize >= 8 then
      begin
        Stream.Position := PayloadStart;
        if not ReadBytes(Stream, 8, DataHdr) then
          Exit(False);
        DataType := ReadUInt32BE(DataHdr, 0);
        if not ReadBytes(Stream, Integer(PayloadSize - 8), Data) then
          Exit(False);
        if Length(Data) > 0 then
        begin
          AMimeType := GuessMimeFromDataTypeAndBytes(DataType, Data);
          if IsSupportedImageMime(AMimeType) then
          begin
            APictureData := Data;
            Exit(True);
          end;
        end;
      end;
    end
    else if IsMp4ContainerAtom(AtomType) then
    begin
      if FindCovrInRange(Stream, PayloadStart, PayloadSize, AMimeType, APictureData, AtomType = 'meta') then
        Exit(True);
    end;

    Pos := Pos + Int64(AtomSize);
  end;
end;

function TM4aFile.LoadFirstCover(out AMimeType: string; out APictureData: TBytes): Boolean;
var
  FS: TFileStream;
begin
  Result := False;
  AMimeType := '';
  SetLength(APictureData, 0);
  try
    FS := TFileStream.Create(FPath, fmOpenRead or fmShareDenyWrite);
    try
      Result := FindCovrInRange(FS, 0, FS.Size, AMimeType, APictureData, False);
    finally
      FS.Free;
    end;
  except
    Exit(False);
  end;
end;

function TM4aFile.FirstAttachedPicture(out AMimeType: string; out APictureData: TBytes): Boolean;
begin
  Result := LoadFirstCover(AMimeType, APictureData);
end;

end.
