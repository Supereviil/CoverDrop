unit CoverDrop;

{
  Main form for CoverDrop / ArtRipr.

  Responsibilities:
    * Let the user pick a root folder (edtBrowse + FileOpenDialog1).
    * Walk that tree up to depth 3, listing every folder in ListView1 with a
      checkbox so the user can opt out of individual folders.
    * For each checked folder that contains audio, ask the matching TagLib.*
      reader for the first embedded JPEG/PNG picture and write it as
      <folder>\folder.jpg.
    * Surface progress in ProgressBar1, counters/elapsed in StatusBar1, and
      a per-folder result (Extracted/Skipped/Error + reason) in the ListView.
    * Optionally convert embedded PNG -> JPG and save a session log.

  Threading: everything runs on the UI thread; long operations call
  Application.ProcessMessages and check FStopRequested to stay responsive
  and to honor the Stop button.

  This unit deliberately keeps scanning/extraction logic in plain procedural
  methods and only delegates file format parsing to TagLib.MPEG/FLAC/M4A/
  OGG/Opus/WMA. Theming and UI tweaks come from UIConstants.
}

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.ComCtrls, Vcl.StdCtrls, Vcl.ImgList, CommCtrl;

type
  TCoverDropForm = class(TForm)
    edtBrowse: TEdit;
    gbBrowse: TGroupBox;
    btnBrowse: TButton;
    chkOverwrite: TCheckBox;
    chkSkip: TCheckBox;
    chkLog: TCheckBox;
    StatusBar1: TStatusBar;
    ListView1: TListView;
    btnScan: TButton;
    btnClear: TButton;
    FileOpenDialog1: TFileOpenDialog;
    ProgressBar1: TProgressBar;
    btnStop: TButton;
    btnQuit: TButton;
    chkPNGtoJPG: TCheckBox;
    chkLogFile: TCheckBox;
    constructor Create(AOwner: TComponent); override;
    procedure FormCreate(Sender: TObject);
    procedure btnBrowseClick(Sender: TObject);
    procedure btnScanClick(Sender: TObject);
    procedure btnStopClick(Sender: TObject);
    procedure btnClearClick(Sender: TObject);
    procedure btnQuitClick(Sender: TObject);
    procedure ListView1CustomDrawItem(Sender: TCustomListView; Item: TListItem;
      State: TCustomDrawState; var DefaultDraw: Boolean);
    procedure ListView1CustomDrawSubItem(Sender: TCustomListView; Item: TListItem;
      SubItem: Integer; State: TCustomDrawState; var DefaultDraw: Boolean);
  private
    { Set by btnStopClick; long loops poll this between folders. }
    FStopRequested: Boolean;
    { Progress counters. FFoldersTotal feeds ProgressBar1.Max,
      FFoldersProcessed feeds .Position, FFoldersCreated counts successful
      folder.jpg writes for the status bar. }
    FFoldersTotal: Integer;
    FFoldersProcessed: Integer;
    FFoldersCreated: Integer;
    { Wall-clock start time of the current scan; FormatElapsedScan uses it. }
    FScanStart: TDateTime;
    { Out-params from ExtractAlbumArt. ProcessFolder reads them after each
      extraction to decide which Status/Notes string to write to the row. }
    FExtractSaved: Boolean;
    FExtractNoEmbeddedArt: Boolean;
    FExtractPngNoConvert: Boolean;
    FExtractPngConvertFailed: Boolean;
    FExtractJpegWriteFailed: Boolean;
    FExtractErrorMsg: string;
    { Transparent 1xUIListViewRowHeight image list assigned as SmallImages
      purely to force a comfortable row height on ListView1. }
    FListRowSpacer: TImageList;
    procedure ApplyUITheme;
    procedure ApplyListViewRowHeight;
    function ColumnIsMonospaced(SubItem: Integer): Boolean;
    function FormatElapsedScan: string;
    function CountProcessFolderSteps(const Path: string; Depth: Integer): Integer;
    function FolderHasAudio(const Folder: string): Boolean;
    procedure PopulateFolderItems(const Path: string);
    procedure ScanRootFolder(const Root: string);
    procedure ProcessFolder(const Path, RootAlbum: string; Depth: Integer);
    procedure FinishFolder;
    procedure EnumerateSubfoldersAndProcess(const Path, RootAlbum: string; Depth: Integer);
    function FindAudioWithArtCandidate(const Folder: string): string;
    procedure ExtractAlbumArt(const AudioFile, FolderPath: string);
    function FindItemByPath(const Path: string): TListItem;
    function NormalizePath(const Path: string): string;
    procedure ResetStatusBar;
    procedure UpdateStatusBar;
    procedure SaveListViewLog(const Root: string);
  public
  end;

var
  CoverDropForm: TCoverDropForm;

implementation

{$R *.dfm}

uses
  System.IOUtils, System.DateUtils, System.UITypes, Vcl.Themes, Vcl.Imaging.pngimage,
  Vcl.Imaging.jpeg, UIConstants,
  TagLib.MPEG, TagLib.FLAC, TagLib.M4A, TagLib.OGG, TagLib.Opus, TagLib.WMA;

type
  { Convenience wrappers for LVM_GET/SETEXTENDEDLISTVIEWSTYLE so we can OR in
    LVS_EX_FULLROWSELECT / LVS_EX_DOUBLEBUFFER / LVS_EX_LABELTIP without
    repeating SendMessage boilerplate. }
  TListViewHelper = class helper for TListView
    function GetExtendedStyle: DWORD;
    procedure SetExtendedStyle(const Value: DWORD);
  end;

function TListViewHelper.GetExtendedStyle: DWORD;
begin
  Result := SendMessage(Self.Handle, LVM_GETEXTENDEDLISTVIEWSTYLE, 0, 0);
end;

procedure TListViewHelper.SetExtendedStyle(const Value: DWORD);
begin
  SendMessage(Self.Handle, LVM_SETEXTENDEDLISTVIEWSTYLE, 0, LPARAM(Value));
end;

constructor TCoverDropForm.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  { Wire up handlers in code so the .dfm stays free of event references.
    All controls are still designed and laid out visually in CoverDrop.dfm. }
  OnCreate := FormCreate;
  btnBrowse.OnClick := btnBrowseClick;
  btnScan.OnClick := btnScanClick;
  btnStop.OnClick := btnStopClick;
  btnClear.OnClick := btnClearClick;
  btnQuit.OnClick := btnQuitClick;
  ListView1.OnCustomDrawItem := ListView1CustomDrawItem;
  ListView1.OnCustomDrawSubItem := ListView1CustomDrawSubItem;
end;

procedure TCoverDropForm.FormCreate(Sender: TObject);
begin
  { Limit the browse dialog to folders only. }
  FileOpenDialog1.Options := [fdoPickFolders, fdoPathMustExist];
  { Full-row selection makes the list usable as a "table"; double-buffering
    eliminates flicker when ProcessFolder updates SubItems mid-scan. }
  ListView1.SetExtendedStyle(ListView1.GetExtendedStyle or LVS_EX_FULLROWSELECT
    or LVS_EX_DOUBLEBUFFER);
  ApplyUITheme;
  ApplyListViewRowHeight;
end;

procedure TCoverDropForm.ApplyUITheme;
var
  UseHighContrast: Boolean;
  ChosenFontName: string;
begin
  { Attempt to apply the preferred VCL Style. TrySetStyle silently no-ops if
    the style is not linked into the executable, so this is safe. }
  try
    TStyleManager.TrySetStyle(UIPreferredStyle, False);
  except
    { Never let a style error block UI creation. }
  end;

  UseHighContrast := IsHighContrastActive;
  if UseHighContrast then
    ChosenFontName := UIHighContrastFont
  else
    ChosenFontName := UIFontName;

  { Cascade font to the form; controls with ParentFont=True inherit. }
  Font.Name := ChosenFontName;
  Font.Size := UIFontSize;
  Font.Charset := DEFAULT_CHARSET;

  { Make sure all visible controls really inherit the form font. The DFM was
    designed with Cabin; ParentFont may be False on some controls. }
  edtBrowse.ParentFont    := True;
  btnBrowse.ParentFont    := True;
  btnScan.ParentFont      := True;
  btnStop.ParentFont      := True;
  btnClear.ParentFont     := True;
  btnQuit.ParentFont      := True;
  chkOverwrite.ParentFont := True;
  chkSkip.ParentFont      := True;
  chkLog.ParentFont       := True;
  chkPNGtoJPG.ParentFont  := True;
  chkLogFile.ParentFont   := True;
  gbBrowse.ParentFont     := True;

  { ListView gets explicit font assignment so cell drawing matches caption. }
  ListView1.Font.Name    := ChosenFontName;
  ListView1.Font.Size    := UIFontSize;
  ListView1.Font.Charset := DEFAULT_CHARSET;

  { Status bar caption font; numeric panel font is set in UpdateStatusBar. }
  StatusBar1.Font.Name    := ChosenFontName;
  StatusBar1.Font.Size    := UIFontSize;
  StatusBar1.Font.Charset := DEFAULT_CHARSET;

  { Show tooltips on truncated cells so long folder paths remain discoverable. }
  ListView1.ShowHint := True;
  ListView1.SetExtendedStyle(ListView1.GetExtendedStyle or LVS_EX_LABELTIP);
end;

procedure TCoverDropForm.ApplyListViewRowHeight;
begin
  { TListView's report-mode row height is driven by the SmallImages list.
    Attaching a 1xUIListViewRowHeight transparent image list forces the
    desired comfortable row height (target 20-22 px) without affecting
    checkbox handling. }
  if FListRowSpacer = nil then
  begin
    FListRowSpacer := TImageList.Create(Self);
    FListRowSpacer.Width  := 1;
    FListRowSpacer.Height := UIListViewRowHeight;
  end;
  ListView1.SmallImages := FListRowSpacer;
end;

function TCoverDropForm.ColumnIsMonospaced(SubItem: Integer): Boolean;
begin
  { Folder=caption (-1 / 0), Status=1, Notes=2.
    No numeric/timestamp columns are present today, but this hook is provided
    so future numeric columns can opt in to Consolas via UIMonoFontName. }
  Result := False;
end;

procedure TCoverDropForm.ListView1CustomDrawItem(Sender: TCustomListView;
  Item: TListItem; State: TCustomDrawState; var DefaultDraw: Boolean);
var
  C: TCanvas;
  LV: TListView;
begin
  { Cooperate with the active VCL Style: we only adjust Canvas.Font and
    Canvas.Brush for the selected row, and let the theme paint everything
    else. The TListView paint logic detects the canvas change and feeds the
    new colors back into the default Win32 list draw via CDRF_NEWFONT, so
    checkboxes, header alignment and theme glyphs still render correctly.

    TCustomListView declares Font as protected; cast to the concrete
    TListView so we can read the published Font property. }
  LV := TListView(Sender);
  C  := LV.Canvas;

  if cdsSelected in State then
  begin
    C.Brush.Color := UIGetSelectedRowColor;
    C.Font.Color  := UIGetSelectedTextColor;
  end
  else
  begin
    { Non-selected rows: do not touch Brush.Color so the theme owns the row
      background. Use the inherited foreground color for text. }
    C.Font.Color := LV.Font.Color;
  end;

  DefaultDraw := True;
end;

procedure TCoverDropForm.ListView1CustomDrawSubItem(Sender: TCustomListView;
  Item: TListItem; SubItem: Integer; State: TCustomDrawState;
  var DefaultDraw: Boolean);
var
  C: TCanvas;
  LV: TListView;
begin
  LV := TListView(Sender);
  C  := LV.Canvas;

  { Per-cell font selection. Currently no columns opt in to monospace,
    but the hook is centralised in ColumnIsMonospaced for future use. }
  if ColumnIsMonospaced(SubItem) then
  begin
    C.Font.Name := UIMonoFontName;
    C.Font.Size := UIMonoFontSize;
  end
  else
  begin
    C.Font.Name := LV.Font.Name;
    C.Font.Size := LV.Font.Size;
  end;

  if cdsSelected in State then
  begin
    C.Brush.Color := UIGetSelectedRowColor;
    C.Font.Color  := UIGetSelectedTextColor;
  end
  else
  begin
    C.Font.Color := LV.Font.Color;
  end;

  DefaultDraw := True;
end;

{ ------------------------------------------------------------------
  Top-of-form button handlers
  ------------------------------------------------------------------ }

procedure TCoverDropForm.btnBrowseClick(Sender: TObject);
begin
  { Folder picker -> populate the path edit box. The scan itself is on btnScan. }
  if FileOpenDialog1.Execute then
    edtBrowse.Text := FileOpenDialog1.FileName;
end;

procedure TCoverDropForm.btnStopClick(Sender: TObject);
begin
  { Cooperative cancel: scan/extract loops poll FStopRequested between folders. }
  FStopRequested := True;
end;

procedure TCoverDropForm.btnClearClick(Sender: TObject);
begin
  { Reset all UI state back to a fresh-launch look without restarting the app. }
  ListView1.Items.Clear;
  FStopRequested := False;
  FFoldersTotal := 0;
  FFoldersProcessed := 0;
  FFoldersCreated := 0;
  ProgressBar1.Min := 0;
  ProgressBar1.Max := 100;
  ProgressBar1.Position := 0;
  ResetStatusBar;
  edtBrowse.Text := '';
  chkOverwrite.Checked := False;
  chkSkip.Checked := False;
  chkLog.Checked := False;
  chkPNGtoJPG.Checked := False;
  chkLogFile.Checked := False;
end;

procedure TCoverDropForm.btnQuitClick(Sender: TObject);
begin
  Close;
end;

{ ------------------------------------------------------------------
  Status bar helpers
  Three panels: Folders Scanned | Album Art Saved | Elapsed.
  ResetStatusBar zeroes them; UpdateStatusBar refreshes from the
  FFolders* counters during a scan.
  ------------------------------------------------------------------ }

procedure TCoverDropForm.ResetStatusBar;
const
  { Leading spaces give the panel text a bit of left padding because the
    native StatusBar panel has no built-in inner-padding property. }
  Pad = '      ';
begin
  try
    if StatusBar1.Panels.Count > 0 then
      StatusBar1.Panels[0].Text := Pad + 'Folders Scanned: 0';
  except
  end;
  try
    if StatusBar1.Panels.Count > 1 then
      StatusBar1.Panels[1].Text := Pad + 'Album Art Saved: 0';
  except
  end;
  try
    if StatusBar1.Panels.Count > 2 then
      StatusBar1.Panels[2].Text := Pad + 'Elapsed: 0 s';
  except
  end;
end;

function TCoverDropForm.FormatElapsedScan: string;
var
  TotalSec, M, S: Int64;
begin
  { Pretty elapsed time: "Elapsed: N s" under a minute, "N m S s" beyond. }
  TotalSec := SecondsBetween(Now, FScanStart);
  if TotalSec < 0 then
    TotalSec := 0;
  if TotalSec < 60 then
    Result := Format('Elapsed: %d s', [TotalSec])
  else
  begin
    M := TotalSec div 60;
    S := TotalSec mod 60;
    Result := Format('Elapsed: %d m %d s', [M, S]);
  end;
end;

procedure TCoverDropForm.UpdateStatusBar;
const
  Pad = '      ';
begin
  try
    if StatusBar1.Panels.Count > 0 then
      StatusBar1.Panels[0].Text := Pad + Format('Folders Scanned: %d', [FFoldersProcessed]);
  except
  end;
  try
    if StatusBar1.Panels.Count > 1 then
      StatusBar1.Panels[1].Text := Pad + Format('Album Art Saved: %d', [FFoldersCreated]);
  except
  end;
  try
    if StatusBar1.Panels.Count > 2 then
      StatusBar1.Panels[2].Text := Pad + FormatElapsedScan;
  except
  end;
end;

{ ------------------------------------------------------------------
  Path helpers
  NormalizePath canonicalises a path for storage/display but keeps the
  on-disk casing. FindItemByPath does case-insensitive lookup so the
  same folder is recognised regardless of how it was typed.
  ------------------------------------------------------------------ }

function TCoverDropForm.NormalizePath(const Path: string): string;
begin
  { Preserve original casing for UI display.
    Still normalize the path structure (expand + remove trailing slash). }
  Result := ExcludeTrailingPathDelimiter(ExpandFileName(Path));
end;

function TCoverDropForm.FindItemByPath(const Path: string): TListItem;
var
  Target: string;
  I: Integer;
begin
  { Compare case-insensitively so display casing in the ListView caption
    does not affect lookup. NormalizePath now preserves original casing. }
  Target := LowerCase(NormalizePath(Path));
  for I := 0 to ListView1.Items.Count - 1 do
    if LowerCase(NormalizePath(ListView1.Items[I].Caption)) = Target then
      Exit(ListView1.Items[I]);
  Result := nil;
end;

{ ------------------------------------------------------------------
  Folder enumeration / pre-scan
  ------------------------------------------------------------------ }

function TCoverDropForm.CountProcessFolderSteps(const Path: string; Depth: Integer): Integer;
var
  SR: TSearchRec;
  SubPath: string;
begin
  { Counts how many times ProcessFolder will be invoked starting from Path,
    so we can prime ProgressBar1.Max before the scan starts. Must mirror the
    depth rule used in ProcessFolder: depths 0..3 each consume one step;
    at depth 3 recursion stops. }
  Result := 1;
  if Depth >= 3 then
    Exit;
  if FindFirst(TPath.Combine(Path, '*'), faDirectory, SR) = 0 then
  try
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') and (SR.Attr and faDirectory <> 0) then
      begin
        SubPath := TPath.Combine(Path, SR.Name);
        Inc(Result, CountProcessFolderSteps(SubPath, Depth + 1));
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

{ Whitelist of audio extensions that have a corresponding TagLib.* reader. }
function IsSupportedAudioExt(const Ext: string): Boolean;
begin
  Result := SameText(Ext, '.mp3') or SameText(Ext, '.flac') or SameText(Ext, '.m4a') or
    SameText(Ext, '.aac') or SameText(Ext, '.ogg') or SameText(Ext, '.opus') or SameText(Ext, '.wma');
end;

{ True when Folder directly contains at least one supported audio file
  (non-recursive). Used by ScanRootFolder to decide whether to treat the
  chosen root itself as an album or to dive into its children. }
function TCoverDropForm.FolderHasAudio(const Folder: string): Boolean;
var
  SR: TSearchRec;
begin
  Result := False;
  if FindFirst(TPath.Combine(Folder, '*'), faAnyFile, SR) = 0 then
  try
    repeat
      if ((SR.Attr and faDirectory) = 0) and IsSupportedAudioExt(LowerCase(ExtractFileExt(SR.Name))) then
      begin
        Result := True;
        Exit;
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

{ Recursively adds Path and every descendant folder as a (checked) row in
  the ListView. Called before ProcessFolder so the user can see/uncheck rows
  up-front. No file I/O beyond directory enumeration happens here. }
procedure TCoverDropForm.PopulateFolderItems(const Path: string);
var
  SR: TSearchRec;
  Item: TListItem;
  SubPath: string;
begin
  Item := ListView1.Items.Add;
  Item.Caption := NormalizePath(Path); // now preserves original casing
  Item.SubItems.Add('');
  Item.SubItems.Add('');
  Item.Checked := True;

  if FindFirst(TPath.Combine(Path, '*'), faDirectory, SR) = 0 then
  try
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') and (SR.Attr and faDirectory <> 0) then
      begin
        SubPath := TPath.Combine(Path, SR.Name);
        PopulateFolderItems(SubPath);
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

{ Dumps the final ListView contents to a timestamped UTF-8 text file inside
  the chosen root folder. Triggered after a scan when chkLogFile is checked. }
procedure TCoverDropForm.SaveListViewLog(const Root: string);
var
  SL: TStringList;
  I: Integer;
  Item: TListItem;
  FN: string;
  D: TDateTime;
begin
  SL := TStringList.Create;
  try
    SL.Add('Folder | Status | Notes');
    for I := 0 to ListView1.Items.Count - 1 do
    begin
      Item := ListView1.Items[I];
      SL.Add(Format('%s | %s | %s', [Item.Caption, Item.SubItems[0], Item.SubItems[1]]));
    end;
    D := Now;
    FN := TPath.Combine(Root, Format('CoverDrop_Log_%.4d%.2d%.2d_%.2d%.2d%.2d.txt',
      [YearOf(D), MonthOfTheYear(D), DayOfTheMonth(D), HourOfTheDay(D), MinuteOfTheHour(D), SecondOfTheMinute(D)]));
    SL.SaveToFile(FN, TEncoding.UTF8);
  finally
    SL.Free;
  end;
end;

{ Called by ProcessFolder for every exit path, regardless of outcome.
  Bumps the progress counter, refreshes the status bar, and yields to the
  message loop so the UI stays responsive and Stop is observed. }
procedure TCoverDropForm.FinishFolder;
begin
  Inc(FFoldersProcessed);
  ProgressBar1.Position := FFoldersProcessed;
  UpdateStatusBar;
  Application.ProcessMessages;
end;

{ Recursive child driver. Enumerates immediate subdirectories of Path and
  calls ProcessFolder on each, passing RootAlbum unchanged (so every child
  writes its folder.jpg into the same album root the user originally
  selected). Bails on FStopRequested between siblings. }
procedure TCoverDropForm.EnumerateSubfoldersAndProcess(const Path, RootAlbum: string; Depth: Integer);
var
  SR: TSearchRec;
  SubPath: string;
begin
  if FStopRequested then
    Exit;
  if FindFirst(TPath.Combine(Path, '*'), faDirectory, SR) = 0 then
  try
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') and (SR.Attr and faDirectory <> 0) then
      begin
        SubPath := TPath.Combine(Path, SR.Name);
        ProcessFolder(SubPath, RootAlbum, Depth + 1);
        Application.ProcessMessages;
        if FStopRequested then
          Exit;
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

{ ------------------------------------------------------------------
  Album-art extraction
  ------------------------------------------------------------------ }

{ Dispatches to the right TagLib.* reader based on file extension and
  returns the first embedded picture's MIME + raw bytes. Each reader is
  short-lived; ownership is local to this routine. }
function TryReadFirstPictureByExtension(const AFileName, Ext: string; out Mime: string; out Data: TBytes): Boolean;
var
  Mpeg: TMpegFile;
  Flac: TFlacFile;
  M4A: TM4aFile;
  Ogg: TOggFile;
  Opus: TOpusFile;
  Wma: TWmaFile;
begin
  Result := False;
  Mime := '';
  SetLength(Data, 0);
  if SameText(Ext, '.mp3') then
  begin
    Mpeg := TMpegFile.Create(AFileName);
    try
      Result := Mpeg.FirstAttachedPicture(Mime, Data);
    finally
      Mpeg.Free;
    end;
  end
  else if SameText(Ext, '.flac') then
  begin
    Flac := TFlacFile.Create(AFileName);
    try
      Result := Flac.FirstAttachedPicture(Mime, Data);
    finally
      Flac.Free;
    end;
  end
  else if SameText(Ext, '.m4a') or SameText(Ext, '.aac') then
  begin
    M4A := TM4aFile.Create(AFileName);
    try
      Result := M4A.FirstAttachedPicture(Mime, Data);
    finally
      M4A.Free;
    end;
  end
  else if SameText(Ext, '.ogg') then
  begin
    Ogg := TOggFile.Create(AFileName);
    try
      Result := Ogg.FirstAttachedPicture(Mime, Data);
    finally
      Ogg.Free;
    end;
  end
  else if SameText(Ext, '.opus') then
  begin
    Opus := TOpusFile.Create(AFileName);
    try
      Result := Opus.FirstAttachedPicture(Mime, Data);
    finally
      Opus.Free;
    end;
  end
  else if SameText(Ext, '.wma') then
  begin
    Wma := TWmaFile.Create(AFileName);
    try
      Result := Wma.FirstAttachedPicture(Mime, Data);
    finally
      Wma.Free;
    end;
  end;
end;

{ Picks the audio file inside Folder that the form should ask for cover art.
  Strategy: scan all supported audio files; return the first one that actually
  contains a JPEG/PNG picture. If none of them do, fall back to the first
  audio file we saw so the caller can still report a meaningful status. }
function TCoverDropForm.FindAudioWithArtCandidate(const Folder: string): string;
var
  SR: TSearchRec;
  AudioPath, FirstAudio, Ext: string;
  Mime: string;
  Data: TBytes;
begin
  Result := '';
  FirstAudio := '';
  if FindFirst(TPath.Combine(Folder, '*'), faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Attr and faDirectory) = 0 then
      begin
        Ext := LowerCase(ExtractFileExt(SR.Name));
        if not IsSupportedAudioExt(Ext) then
          Continue;
        AudioPath := TPath.Combine(Folder, SR.Name);
        if FirstAudio = '' then
          FirstAudio := AudioPath;
        if TryReadFirstPictureByExtension(AudioPath, Ext, Mime, Data) and (Length(Data) > 0) then
          Exit(AudioPath);
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  Result := FirstAudio;
end;

{ Reads embedded artwork out of AudioFile and writes <FolderPath>\folder.jpg.

  The outcome is communicated to the caller (ProcessFolder) via the
  FExtract* fields rather than the function result, because there are
  several distinct non-fatal outcomes (no art, PNG-but-no-convert, write
  error, ...) and ProcessFolder turns each one into a row's Status/Notes. }
procedure TCoverDropForm.ExtractAlbumArt(const AudioFile, FolderPath: string);
var
  Ext: string;
  Mime: string;
  Data: TBytes;
  JpgPath: string;
  MS: TMemoryStream;
  Png: TPngImage;
  Bmp: TBitmap;
  Jpg: TJPEGImage;
begin
  { Reset all out-flags so leftover state from the previous folder cannot
    leak into this one. }
  FExtractSaved := False;
  FExtractNoEmbeddedArt := False;
  FExtractPngNoConvert := False;
  FExtractPngConvertFailed := False;
  FExtractJpegWriteFailed := False;
  FExtractErrorMsg := '';
  JpgPath := TPath.Combine(FolderPath, 'folder.jpg');
  Ext := LowerCase(ExtractFileExt(AudioFile));
  if not TryReadFirstPictureByExtension(AudioFile, Ext, Mime, Data) then
  begin
    FExtractNoEmbeddedArt := True;
    Exit;
  end;
  if SameText(Mime, 'image/jpeg') then
  begin
    { Embedded JPEG: write the bytes directly, no decoding round-trip. }
    if Length(Data) = 0 then
    begin
      FExtractNoEmbeddedArt := True;
      Exit;
    end;
    try
      TFile.WriteAllBytes(JpgPath, Data);
      FExtractSaved := True;
    except
      on E: Exception do
      begin
        FExtractJpegWriteFailed := True;
        FExtractErrorMsg := E.Message;
      end;
    end;
  end
  else if SameText(Mime, 'image/png') then
  begin
    { Embedded PNG: only convert if the user opted in via chkPNGtoJPG;
      otherwise record "PNG embedded art" as a skip reason so the row
      explains why no folder.jpg was produced. }
    if chkPNGtoJPG.Checked then
    begin
      try
        MS := TMemoryStream.Create;
        try
          if Length(Data) > 0 then
            MS.WriteBuffer(Data[0], Length(Data));
          MS.Position := 0;
          Png := TPngImage.Create;
          try
            Png.LoadFromStream(MS);
            Bmp := TBitmap.Create;
            Jpg := TJPEGImage.Create;
            try
              { TJPEGImage cannot Assign(TPngImage); use TBitmap as intermediate. }
              Bmp.Assign(Png);
              Jpg.Assign(Bmp);
              Jpg.SaveToFile(JpgPath);
              FExtractSaved := True;
            finally
              Bmp.Free;
              Jpg.Free;
            end;
          finally
            Png.Free;
          end;
        finally
          MS.Free;
        end;
      except
        on E: Exception do
        begin
          FExtractPngConvertFailed := True;
          FExtractErrorMsg := E.Message;
        end;
      end;
    end
    else
      FExtractPngNoConvert := True;
  end
  else
    FExtractNoEmbeddedArt := True;
end;

{ Core per-folder pipeline.

  Path       = folder currently being processed
  RootAlbum  = the album-root folder.jpg should be written into. For the
               very first call it equals Path; recursive child calls keep
               the same RootAlbum so a multi-disc album writes one
               folder.jpg at the album root, not in each child.
  Depth      = recursion depth (0..3). At depth > 2 we stop descending
               but still bump the progress counter via FinishFolder.

  Behaviour per row:
    * Unchecked  -> "Skipped: Folder not selected" and recurse to children.
    * Skip rule  -> chkSkip + folder.jpg already exists -> skip + recurse.
    * No audio   -> "Skipped: No audio file found" + recurse.
    * Exists+no overwrite -> "Skipped: folder.jpg exists" + recurse.
    * Otherwise  -> ExtractAlbumArt and translate FExtract* into a row
      Status/Notes + (on success) bump FFoldersCreated. }
procedure TCoverDropForm.ProcessFolder(const Path, RootAlbum: string; Depth: Integer);
var
  Item: TListItem;
  AudioPath: string;
  JpgPath: string;
  P: string;
begin
  if FStopRequested then
    Exit;

  if Depth > 2 then
  begin
    FinishFolder;
    Exit;
  end;

  { Try to find the row PopulateFolderItems added for this path; if it
    wasn't pre-populated (e.g. scan started without a root pre-walk),
    create a row on the fly so we still get UI feedback. }
  P := NormalizePath(Path);
  Item := FindItemByPath(P);
  if Item = nil then
  begin
    Item := ListView1.Items.Add;
    Item.Caption := NormalizePath(Path); // now preserves original casing
    Item.SubItems.Add('');
    Item.SubItems.Add('');
    Item.Checked := True;
  end;

  if (Item <> nil) and (not Item.Checked) then
  begin
    Item.SubItems[0] := 'Skipped';
    Item.SubItems[1] := 'Folder not selected';
    FinishFolder;
    Application.ProcessMessages;
    if FStopRequested then
      Exit;
    EnumerateSubfoldersAndProcess(P, RootAlbum, Depth);
    if FStopRequested then
      Exit;
    Exit;
  end;

  if chkSkip.Checked and FileExists(TPath.Combine(RootAlbum, 'folder.jpg')) then
  begin
    if Item <> nil then
    begin
      Item.SubItems[0] := 'Skipped';
      Item.SubItems[1] := 'folder.jpg already present (skip rule)';
    end;
    FinishFolder;
    Application.ProcessMessages;
    if FStopRequested then
      Exit;
    EnumerateSubfoldersAndProcess(P, RootAlbum, Depth);
    if FStopRequested then
      Exit;
    Exit;
  end;

  AudioPath := FindAudioWithArtCandidate(P);
  if AudioPath = '' then
  begin
    if Item <> nil then
    begin
      Item.SubItems[0] := 'Skipped';
      Item.SubItems[1] := 'No audio file found';
    end;
    FinishFolder;
    Application.ProcessMessages;
    if FStopRequested then
      Exit;
    EnumerateSubfoldersAndProcess(P, RootAlbum, Depth);
    if FStopRequested then
      Exit;
    Exit;
  end;

  JpgPath := TPath.Combine(RootAlbum, 'folder.jpg');
  if FileExists(JpgPath) and (not chkOverwrite.Checked) then
  begin
    if Item <> nil then
    begin
      Item.SubItems[0] := 'Skipped';
      Item.SubItems[1] := 'folder.jpg exists (overwrite disabled)';
    end;
    FinishFolder;
    Application.ProcessMessages;
    if FStopRequested then
      Exit;
    EnumerateSubfoldersAndProcess(P, RootAlbum, Depth);
    if FStopRequested then
      Exit;
    Exit;
  end;

  ExtractAlbumArt(AudioPath, RootAlbum);
  if FExtractSaved then
  begin
    Inc(FFoldersCreated);
    if Item <> nil then
    begin
      Item.SubItems[0] := 'Extracted';
      Item.SubItems[1] := 'Saved folder.jpg';
    end;
  end
  else if FExtractJpegWriteFailed and (Item <> nil) then
  begin
    Item.SubItems[0] := 'Error';
    Item.SubItems[1] := 'Could not write folder.jpg';
    if FExtractErrorMsg <> '' then
      Item.SubItems[1] := Item.SubItems[1] + ': ' + FExtractErrorMsg;
  end
  else if FExtractPngConvertFailed and (Item <> nil) then
  begin
    Item.SubItems[0] := 'Error';
    Item.SubItems[1] := 'PNG to JPG conversion failed';
    if FExtractErrorMsg <> '' then
      Item.SubItems[1] := Item.SubItems[1] + ': ' + FExtractErrorMsg;
  end
  else if FExtractPngNoConvert and (Item <> nil) then
  begin
    Item.SubItems[0] := 'Skipped';
    Item.SubItems[1] := 'PNG embedded art (enable Convert to JPG)';
  end
  else if FExtractNoEmbeddedArt and (Item <> nil) then
  begin
    Item.SubItems[0] := 'Skipped';
    Item.SubItems[1] := 'No embedded art';
  end;

  FinishFolder;
  Application.ProcessMessages;
  if FStopRequested then
    Exit;
  EnumerateSubfoldersAndProcess(P, RootAlbum, Depth);
end;

{ Top-level scan driver. Two modes:

  1) Root itself contains audio  -> treat it as a single album: pre-count
     steps, populate rows recursively, and call ProcessFolder(R, R, 0).
  2) Root is a library of albums -> each immediate subfolder is its own
     album root (folder.jpg goes into that subfolder), so we count, then
     populate, then process each subfolder with itself as RootAlbum.

  After either branch, write the session log if chkLogFile is checked. }
procedure TCoverDropForm.ScanRootFolder(const Root: string);
var
  R, SubPath: string;
  SR: TSearchRec;
begin
  R := NormalizePath(Root);

  if FolderHasAudio(R) then
  begin
    FFoldersTotal := CountProcessFolderSteps(R, 0);
    FFoldersProcessed := 0;
    FFoldersCreated := 0;
    FStopRequested := False;
    ProgressBar1.Min := 0;
    ProgressBar1.Max := FFoldersTotal;
    ProgressBar1.Position := 0;
    ResetStatusBar;
    ListView1.Items.Clear;
    PopulateFolderItems(R);
    FScanStart := Now;
    UpdateStatusBar;
    ProcessFolder(R, R, 0);
  end
  else
  begin
    FFoldersTotal := 0;
    FFoldersProcessed := 0;
    FFoldersCreated := 0;
    FStopRequested := False;
    ProgressBar1.Min := 0;
    ProgressBar1.Position := 0;
    ResetStatusBar;
    ListView1.Items.Clear;

    if FindFirst(TPath.Combine(R, '*'), faDirectory, SR) = 0 then
    try
      repeat
        if (SR.Name <> '.') and (SR.Name <> '..') and (SR.Attr and faDirectory <> 0) then
        begin
          SubPath := TPath.Combine(R, SR.Name);
          Inc(FFoldersTotal, CountProcessFolderSteps(SubPath, 0));
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;

    if FFoldersTotal < 1 then
      FFoldersTotal := 1;
    ProgressBar1.Max := FFoldersTotal;
    FScanStart := Now;
    UpdateStatusBar;

    if FindFirst(TPath.Combine(R, '*'), faDirectory, SR) = 0 then
    try
      repeat
        if (SR.Name <> '.') and (SR.Name <> '..') and (SR.Attr and faDirectory <> 0) then
        begin
          SubPath := TPath.Combine(R, SR.Name);
          PopulateFolderItems(SubPath);
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;

    if FindFirst(TPath.Combine(R, '*'), faDirectory, SR) = 0 then
    try
      repeat
        if (SR.Name <> '.') and (SR.Name <> '..') and (SR.Attr and faDirectory <> 0) then
        begin
          SubPath := TPath.Combine(R, SR.Name);
          ProcessFolder(SubPath, SubPath, 0);
          if FStopRequested then
            Break;
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;

  if chkLogFile.Checked then
    SaveListViewLog(R);
end;

{ "Scan" button entry point. Validates the input path, disables UI that
  shouldn't be re-entered mid-scan, and re-enables it in a finally block
  so an exception inside ScanRootFolder cannot leave buttons disabled. }
procedure TCoverDropForm.btnScanClick(Sender: TObject);
var
  Root: string;
begin
  Root := Trim(edtBrowse.Text);
  if (Root = '') or not DirectoryExists(Root) then
  begin
    ShowMessage('Please enter a valid folder path.');
    Exit;
  end;

  btnScan.Enabled := False;
  btnClear.Enabled := False;
  btnBrowse.Enabled := False;
  try
    ScanRootFolder(Root);
  finally
    btnScan.Enabled := True;
    btnClear.Enabled := True;
    btnBrowse.Enabled := True;
  end;
end;

end.
