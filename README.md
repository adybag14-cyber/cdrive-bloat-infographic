# C: Storage Atlas

A native Windows Zig app that scans an accessible drive tree, groups the largest files by likely owner, and serves a local infographic at `http://127.0.0.1:8277/`.

## Quick Start

```powershell
git clone https://github.com/adybag14-cyber/cdrive-bloat-infographic.git
cd cdrive-bloat-infographic
.\scripts\start-server.ps1 -Root C:\ -Open
```

The first run downloads or finds Zig `0.17.0-dev.305+bdfbf432d`, builds the executable, scans the drive, and opens the infographic in Chrome when Chrome is installed.

## Options

```powershell
.\scripts\start-server.ps1 -Root C:\ -Port 8277 -FileLimit 240 -GroupLimit 140 -Open
```

- `Root`: drive or folder to scan.
- `Port`: local HTTP port.
- `FileLimit`: number of largest individual files kept in the JSON payload.
- `GroupLimit`: number of largest grouped owners shown in the API.
- `NoBuild`: reuse the existing `zig-out\bin\cdrive-bloat-infographic.exe`.

The scanner skips inaccessible paths and reports the skipped count. It also guard-skips a few Windows-protected internals that commonly hang normal user-mode scans, including Windows container layer internals, recycle bins, and system volume metadata. Run PowerShell as Administrator for a more complete C: scan.

## Manual Build

```powershell
.\scripts\build.ps1 -Optimize ReleaseSafe
.\zig-out\bin\cdrive-bloat-infographic.exe --root C:\ --port 8277
```

Open `http://127.0.0.1:8277/` after the process prints `Infographic ready`.

## What It Shows

- Largest individual files, biggest to smallest.
- Likely owner groups such as Steam games, apps, app data, caches, AI models, VM/container images, archives, media, Windows system areas, and user files.
- Drive used/free space when Windows disk metadata is available.
- Accessible scanned bytes and skipped entries.

No file deletion is performed. This is a read-only scanner and local-only server.
