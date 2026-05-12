# CoverDrop  
*A Superevil Enterprises Utility*

<img width="256" height="256" alt="CoverDrop" src="https://github.com/user-attachments/assets/f4bf63f8-9364-4b4b-896c-771a89e5d411" />

CoverDrop is a fast, native Windows utility for extracting **embedded album artwork** from audio files and saving it as `folder.jpg`. It’s built for collectors who maintain clean, consistent music libraries and want Windows Explorer to display proper folder thumbnails — without retagging or modifying audio files.

---

## Features
- Recursively scans your music library (up to depth 3)
- Extracts embedded JPEG or PNG artwork from:
  - MP3 (ID3v2 APIC)
  - FLAC (PICTURE block)
  - M4A / AAC (MP4 atoms)
  - OGG Vorbis (METADATA_BLOCK_PICTURE)
  - Opus (OpusTags)
  - WMA (WM/Picture)
- Saves artwork as `folder.jpg` in the album root
- Optional PNG → JPG conversion
- Skip rules for existing folder.jpg
- Per‑folder status reporting
- Optional session log file
- Clean Windows 11–styled UI (Polar Smoke theme)
- Zero metadata modification — audio files are never changed

---

## Who This Is For
CoverDrop is designed for users who:

- Maintain well‑organized, consistently tagged music libraries  
- Prefer uniform embedded artwork (e.g., 500×500 JPGs)  
- Want Windows Explorer to show full‑size folder thumbnails  
- Need to batch‑extract art across thousands of albums  
- Want a tool that is fast, predictable, and safe  

If you’re picky about metadata, CoverDrop fits right into your workflow.

---

## How It Works
1. Choose a root folder  
2. CoverDrop scans all subfolders (up to depth 3)  
3. For each folder containing audio:
   - Finds the first file with embedded artwork  
   - Extracts JPEG directly  
   - Converts PNG → JPG if enabled  
   - Writes `folder.jpg` to the album root  
4. Displays per‑folder status and progress  
5. Optionally writes a timestamped log file  

No retagging. No rewriting. No surprises.

---

## Performance
CoverDrop is highly optimized thanks to its native Delphi implementation and lightweight TagLib‑style readers.

**Example benchmark:**  
> 2,959 folders scanned and 2,888 folder.jpg files extracted  
> in **2 minutes 43 seconds** on a standard 7200rpm HDD.

SSD performance is even higher.

---

## Screenshots
<img width="705" height="438" alt="screenshot" src="https://github.com/user-attachments/assets/2c1170ee-ab08-4c80-b89c-263329798831" />


---

## Download
Prebuilt binaries are available on the **Releases** page.

---

## Building From Source
CoverDrop is written in **Delphi** and requires:

- Delphi 11+  
- VCL Styles (Windows11 Polar Smoke recommended)

All TagLib readers are implemented in pure Object Pascal — no external DLLs required.

---

## License
MIT License  

---

## Support
If you enjoy this tool and want to support development:

**https://ko-fi.com/superevil**

