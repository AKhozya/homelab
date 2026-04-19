# iOS Photos Import to Immich

Guide for importing photos from macOS Photos app (iCloud-synced from iOS) to Immich.

## Overview

Uses two tools:
- **osxphotos**: exports from macOS Photos library with filtering
- **Immich CLI**: uploads to Immich with duplicate detection

Script handles workflow:
- Export by album
- Download from iCloud if needed
- Upload via local network
- Skip duplicates on re-runs

## What It Does

### Photo Export
- Export **all photos** from macOS Photos
- Export **photos in albums** (organized folders)
- Export **photos NOT in any album** ("Not-in-Album" folder)
- Export **edited versions** (cropped, filtered) instead of originals
- Export **videos** (.MOV, .MP4) alongside photos
- Download from **iCloud** auto if not local
- **Incremental exports** — only new/changed on re-runs

### Upload Features
- Upload via **local network** (10-100x faster than public internet)
- **Auto duplicate detection** — skip files in Immich
- **Photos + videos** (all Immich formats)
- **Progress tracking** during upload
- **Resumable** — re-run safely after interrupt

### Album Organization
- Photos organized by album in export dir
- Albums created manually in Immich after upload
- Note: auto album creation needs external library setup (advanced)

## Limitations

- Cannot preserve Live Photos as Live Photos (exports separate photo + video)
- Cannot auto-create albums from CLI uploads (manual OR external library)
- Cannot sync deletions — deleted photos in app stay in Immich
- Cannot preserve edits separately — final edited version OR original, not both
- Cannot select by date range via script (use manual osxphotos filtering)
- Requires macOS

### Workarounds
- **Albums**: create manually in Immich web UI after upload
- **Live Photos**: both photo + video uploaded, viewable separately
- **Deletions**: manual cleanup in Immich or external library sync
- **Date filtering**: use osxphotos advanced query options (see osxphotos docs)

## Prerequisites

### Required
1. **macOS** with Photos app
2. **iCloud Photos** enabled + synced
3. **kubectl** access to cluster
4. **Immich API key** (from Immich web UI)

### Auto-Installed (if missing)
- pipx (via Homebrew)
- osxphotos (via pipx)
- Immich CLI (via npm)

## Quick Start

### 1. Create API Key

1. Go to: https://immich.h0melab.work/user-settings?isOpen=api-keys
2. Click "Create API Key"
3. Name (e.g., "iOS Import")
4. Grant **ALL permissions**
5. Copy key
6. Save:
   ```bash
   mkdir -p ~/.config/immich
   echo 'your-api-key-here' > ~/.config/immich/api_key.txt
   chmod 600 ~/.config/immich/api_key.txt
   ```

### 2. Run Import Script

```bash
immich-import-ios-photos.sh
```

Script will:
1. Check required tools (install if needed)
2. Export photos from Photos app
3. Upload to Immich via local network
4. Show progress + summary

### 3. Customize (Optional)

```bash
# Custom export directory
immich-import-ios-photos.sh ~/my-custom-export

# Use public URL instead of local network
USE_LOCAL=false immich-import-ios-photos.sh

# Custom API key file
immich-import-ios-photos.sh ~/ios-photos ~/.config/immich/other-key.txt
```

## How It Works

### Phase 1: Export from macOS Photos

```
Photos App → osxphotos → Export Directory
```

**What happens:**
1. osxphotos reads Photos library DB
2. For each photo:
   - If in iCloud: downloads via AppleScript
   - If edited: exports edited version (not original)
   - If in album: saves to `{album-name}/`
   - If not in album: saves to `Not-in-Album/`
3. Creates `.osxphotos_export.db` — tracks exported

**On re-runs:**
- Checks export DB
- Only exports NEW or CHANGED
- Skips rest
- **Result**: 5000 photos → ~30 min first time, ~1 min for 3 new

### Phase 2: Upload to Immich

```
Export Directory → kubectl port-forward → Immich Server
```

**What happens:**
1. Script creates `kubectl port-forward` to Immich pod (localhost:2283)
2. Immich CLI:
   - Walks export dir recursively
   - For each file:
     - Calculate SHA-256 hash
     - Send hash to Immich: "Do you have this?"
     - If yes: skip ("already uploaded")
     - If no: upload
3. Immich processes in background (thumbnails, ML)

**Network Path:**
- **Local (default)**: Mac → LAN → kubectl → Pod (fast, ~100MB/s)
- **Public**: Mac → Internet → Cloudflare → Traefik → Pod (slow, ~10MB/s)

### Phase 3: Background Processing

```
Immich Server → ML Pod (ROCm GPU)
```

After upload, Immich auto:
1. Generates thumbnails (VAAPI hw accel)
2. Extracts metadata (EXIF, date, location)
3. Runs ML:
   - Face detection (ROCm GPU)
   - Object recognition
   - CLIP embeddings for smart search
4. Processes videos (VAAPI hw transcoding if needed)

**Performance with boosted resources:**
- ~5000 photos: 30-60 min total
- ML pod: 4 CPU + 8GB RAM during bulk import
- AMD GPU accel via ROCm for face detection

## Duplicate Handling

### Two-Layer Protection

#### Layer 1: osxphotos (Export Side)
- Maintains `.osxphotos_export.db` in export dir
- Tracks: filename, size, mtime
- Re-export: only new/changed files

#### Layer 2: Immich CLI (Upload Side)
- Hash each file before upload
- Check server: "Already have this hash?"
- Skip if duplicate

### Example Scenario

**First Run (5000 photos):**
```
Export: 30 minutes (downloading from iCloud + exporting)
Upload: 20 minutes (via local network)
Total: ~50 minutes
```

**Second Run (3 new photos):**
```
Export: 10 seconds (only 3 new files)
Upload: 30 seconds (only 3 new files)
Total: ~40 seconds
```

### Safe to Re-Run

Run as often as you want:
- **Daily**: sync new photos auto
- **After edits**: re-export edited
- **After interrupt**: resume

**Important**: don't delete `.osxphotos_export.db` — makes re-runs fast.

## Troubleshooting

### "osxphotos not found" / pip externally-managed-environment

Script auto-installs via pipx. If fails:

```bash
brew install pipx
pipx ensurepath
pipx install osxphotos
```

### "Immich CLI not found"

Script auto-installs via npm. If fails:

```bash
npm install -g @immich/cli
```

### "Failed to connect: 401 Invalid API key"

API key invalid/missing:

1. Create new API key in Immich web UI
2. Save: `echo 'your-key' > ~/.config/immich/api_key.txt`
3. Re-run script

### "Port-forward failed to start"

kubectl can't connect:

```bash
# Check cluster connection
kubectl get pods -n immich

# Or use public URL instead
USE_LOCAL=false immich-import-ios-photos.sh
```

### "Waiting for iCloud download..." (stuck)

Photos app needs manual help:

1. Open Photos app
2. Click stuck photo
3. Photos starts downloading
4. Wait for complete
5. Script continues auto

### Export slow / Taking forever

**Normal:**
- First export with iCloud: 30-60 min for 5000 photos
- Subsequent: <1 min for new photos only

**If stuck:**
- Check Photos for iCloud download prompts
- Check internet (iCloud needs bandwidth)
- Consider `--skip-edited` if only originals wanted (faster)

### Upload fails with connection errors

Switch to public URL:

```bash
USE_LOCAL=false immich-import-ios-photos.sh
```

Or check kubectl:

```bash
kubectl port-forward -n immich svc/immich-server 2283:2283
# In another terminal:
curl http://localhost:2283/api/server-info/ping
```

## Advanced Usage

### Export Only New Photos

Script auto does this via `--update`:

```bash
# First run: exports all
immich-import-ios-photos.sh

# Later runs: only new/changed photos
immich-import-ios-photos.sh
```

### Export to Different Location

```bash
immich-import-ios-photos.sh /path/to/custom/export
```

### Use Different API Key

```bash
immich-import-ios-photos.sh ~/ios-photos ~/.config/immich/different-key.txt
```

### Skip Export, Only Upload

If photos already exported:

```bash
immich-import-ios-photos.sh
# Choose 'N' for export
# Choose 'Y' to continue with upload
```

### Manual osxphotos Commands

For advanced filtering:

```bash
# Export only from specific album
osxphotos export ~/export --directory "{album}" --album "Vacation 2024"

# Export only from date range
osxphotos export ~/export --from-date "2024-01-01" --to-date "2024-12-31"

# Export with different filename template
osxphotos export ~/export --filename "{created.year}-{created.month}-{original_name}"

# See all options
osxphotos export --help
```

### Manual Immich Upload

```bash
# Upload with custom settings
immich login-key "https://immich.h0melab.work/api" "your-api-key"

# Upload with album creation based on folders
immich upload ~/export --recursive --album

# Upload to specific album
immich upload ~/export --recursive --album-name "iOS Import 2024"

# Dry run (see what would be uploaded)
immich upload ~/export --recursive --dry-run
```

## Related Documentation

- [Immich Import Script Reference](./IMPORT_SCRIPT_REFERENCE.md) — technical details
- [osxphotos Documentation](https://github.com/RhetTbull/osxphotos) — full feature list
- [Immich CLI Documentation](https://immich.app/docs/features/command-line-interface) — CLI reference
- Script: `~/.local/bin/immich-import-ios-photos.sh`
