unit TagLib.FLAC;

{
  FLAC picture extractor.

  A FLAC file starts with the 4-byte ASCII signature 'fLaC' followed by a
  chain of metadata blocks. Each block has a 4-byte header: 1 byte
  (last-block flag | block type) and a 3-byte big-endian length. We walk
  the chain, find block type 6 (PICTURE), and parse that block's body
  with ParseFlacPictureBlock to recover the MIME + image bytes.

  See https://xiph.org/flac/format.html#metadata_block_picture
}

interface

uses
  System.SysUtils,
  System.Classes;

type
  TFlacFile = class
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

constructor TFlacFile.Create(const AFileName: string);
begin
  inherited Create;
  FPath := AFileName;
end;

{ Decode the body of a FLAC PICTURE metadata block.

  Layout (all big-endian):
    [u32 picture type][u32 MIME length][MIME (ASCII)]
    [u32 description length][description (UTF-8)]
    [u32 width][u32 height][u32 depth][u32 colors]
    [u32 picture data length][picture bytes ...] }
function ParseFlacPictureBlock(const BlockData: TBytes; out AMimeType: string; out APictureData: TBytes): Boolean;
var
  Pos, MimeLen, DescLen, DataLen: Integer;
  Mime: string;
begin
  Result := False;
  AMimeType := '';
  SetLength(APictureData, 0);
  if Length(BlockData) < 32 then
    Exit;

  Pos := 0;
  Inc(Pos, 4); // picture type

  MimeLen := Integer(ReadUInt32BE(BlockData, Pos));
  Inc(Pos, 4);
  if (MimeLen < 0) or (Pos + MimeLen > Length(BlockData)) then
    Exit;
  if MimeLen > 0 then
    SetString(Mime, PAnsiChar(@BlockData[Pos]), MimeLen)
  else
    Mime := '';
  Inc(Pos, MimeLen);

  DescLen := Integer(ReadUInt32BE(BlockData, Pos));
  Inc(Pos, 4);
  if (DescLen < 0) or (Pos + DescLen > Length(BlockData)) then
    Exit;
  Inc(Pos, DescLen);

  if Pos + 16 > Length(BlockData) then
    Exit;
  Inc(Pos, 16); // width, height, depth, colors

  if Pos + 4 > Length(BlockData) then
    Exit;
  DataLen := Integer(ReadUInt32BE(BlockData, Pos));
  Inc(Pos, 4);
  if (DataLen <= 0) or (Pos + DataLen > Length(BlockData)) then
    Exit;

  AMimeType := NormalizeImageMime(Mime);
  if not IsSupportedImageMime(AMimeType) then
    Exit;

  SetLength(APictureData, DataLen);
  Move(BlockData[Pos], APictureData[0], DataLen);
  Result := Length(APictureData) > 0;
end;

{ Opens the file, validates the 'fLaC' signature, then walks the metadata
  block chain. Stops on the first PICTURE block that yields a supported
  MIME or when the last block is reached. Catches any IO/parse exception
  and returns False so the caller can fall back gracefully. }
function TFlacFile.LoadFirstPicture(out AMimeType: string; out APictureData: TBytes): Boolean;
var
  FS: TFileStream;
  Sig: TBytes;
  Hdr: TBytes;
  BlockType: Byte;
  IsLast: Boolean;
  BlockLen: Integer;
  BlockData: TBytes;
begin
  Result := False;
  AMimeType := '';
  SetLength(APictureData, 0);

  try
    FS := TFileStream.Create(FPath, fmOpenRead or fmShareDenyWrite);
    try
      if not ReadBytes(FS, 4, Sig) then
        Exit;
      if (Length(Sig) <> 4) or (Sig[0] <> Ord('f')) or (Sig[1] <> Ord('L')) or (Sig[2] <> Ord('a')) or (Sig[3] <> Ord('C')) then
        Exit;

      repeat
        if not ReadBytes(FS, 4, Hdr) then
          Exit;
        IsLast := (Hdr[0] and $80) <> 0;
        BlockType := Hdr[0] and $7F;
        BlockLen := Integer(ReadUInt24BE(Hdr, 1));
        if (BlockLen < 0) or (Int64(FS.Position) + BlockLen > FS.Size) then
          Exit;
        if not ReadBytes(FS, BlockLen, BlockData) then
          Exit;
        if BlockType = 6 then
          if ParseFlacPictureBlock(BlockData, AMimeType, APictureData) then
            Exit(True);
      until IsLast;
    finally
      FS.Free;
    end;
  except
    Exit(False);
  end;
end;

function TFlacFile.FirstAttachedPicture(out AMimeType: string; out APictureData: TBytes): Boolean;
begin
  Result := LoadFirstPicture(AMimeType, APictureData);
end;

end.
