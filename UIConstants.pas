unit UIConstants;

{
  Centralized UI constants and theme helpers for the CoverDrop form.

  Colors are NOT hardcoded here. All accent / selection / text colors come from
  the active VCL Style via StyleServices, with a graceful fallback to the raw
  Windows system colors when Windows high-contrast mode is active or when no
  style is loaded. Spacing, padding, and font choices remain plain constants
  so they can be tweaked from a single location.
}

interface

uses
  Vcl.Graphics;

const
  { Primary UI font for labels, buttons and list captions. }
  UIFontName            = 'Ebrima';
  UIFontSize            = 9;

  { Monospace font used for log output and numeric / timestamp counters. }
  UIMonoFontName        = 'Consolas';
  UIMonoFontSize        = 9;

  { Fallback font used when Windows high-contrast mode is active. }
  UIHighContrastFont    = 'Segoe UI';

  { Target row height for the primary ListView (in pixels).
    The forced row height comes from an internal 1xUIListViewRowHeight image
    list attached as SmallImages in code (see TCoverDropForm.FormCreate). }
  UIListViewRowHeight   = 22;

  { Horizontal padding (in pixels) applied inside list cells when drawing text
    via OnCustomDrawSubItem. Reserved for future custom cell drawing. }
  UICellPaddingLeft     = 6;
  UICellPaddingRight    = 6;

  { Minimum dimensions for primary command buttons. }
  UIButtonMinWidth      = 80;
  UIButtonMinHeight     = 28;

  { Square dimension for the browse ("...") button. }
  UIBrowseButtonSize    = 28;

  { Vertical gap between stacked checkboxes (top-to-top distance). }
  UICheckBoxVerticalGap = 26;

  { Left padding (in pixels) for checkbox captions relative to the parent. }
  UICheckBoxLeftPadding = 12;

  { Inner padding applied to single-line edit fields when drawn by the theme. }
  UIEditInnerPadding    = 6;

  { Padding applied around progress / status text in the status bar. }
  UIStatusBarPadding    = 6;

  { Name of the VCL Style to apply when available. TStyleManager.TrySetStyle
    silently no-ops when the style is not linked into the executable. }
  UIPreferredStyle      = 'Windows11 Polar Smoke';

{ Returns True when Windows reports a high-contrast accessibility scheme is
  active. In that case theme color lookups are skipped and raw system colors
  are returned instead. }
function IsHighContrastActive: Boolean;

{ Theme-driven accent color (selection / progress fill).
  Resolves to the active VCL Style's clHighlight, or the raw system clHighlight
  when no style is active or high-contrast mode is on. }
function UIGetAccentColor: TColor;

{ Theme-driven background color for a selected ListView row. }
function UIGetSelectedRowColor: TColor;

{ Theme-driven foreground color for text drawn over a selected row. }
function UIGetSelectedTextColor: TColor;

implementation

uses
  Winapi.Windows, Vcl.Themes;

function IsHighContrastActive: Boolean;
var
  HC: THighContrast;
begin
  Result := False;
  FillChar(HC, SizeOf(HC), 0);
  HC.cbSize := SizeOf(HC);
  if SystemParametersInfo(SPI_GETHIGHCONTRAST, SizeOf(HC), @HC, 0) then
    Result := (HC.dwFlags and HCF_HIGHCONTRASTON) <> 0;
end;

function ResolveSystemColor(SystemColor: TColor): TColor;
{ Returns SystemColor resolved through the active VCL Style. In high-contrast
  mode or when no style is active, the raw Windows system color is returned so
  Windows can map it to the active accessibility palette. }
var
  Svc: TCustomStyleServices;
begin
  if IsHighContrastActive then
    Exit(SystemColor);

  Svc := StyleServices;
  if (Svc <> nil) and Svc.Enabled then
    Result := Svc.GetSystemColor(SystemColor)
  else
    Result := SystemColor;
end;

function UIGetAccentColor: TColor;
begin
  Result := ResolveSystemColor(clHighlight);
end;

function UIGetSelectedRowColor: TColor;
begin
  { Theme's clHighlight is the canonical selection background. The TStyleColor
    enum in this Delphi version does not expose scListItemSelected / scListItemHot,
    so we route through clHighlight which every VCL Style is required to define. }
  Result := ResolveSystemColor(clHighlight);
end;

function UIGetSelectedTextColor: TColor;
begin
  Result := ResolveSystemColor(clHighlightText);
end;

end.
