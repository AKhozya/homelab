# iOS Photos Import to Immich

Complete guide for importing photos from macOS Photos app (synced from iOS via iCloud) to Immich.

## Overview

This import process uses two powerful tools:
- **osxphotos**: Exports photos from macOS Photos library with advanced filtering
- **Immich CLI**: Uploads photos to Immich server with duplicate detection

The script handles the complete workflow automatically, including:
- Exporting photos organized by album
- Downloading from iCloud if needed
- Uploading via fast local network connection
- Skipping duplicates on re-runs

## What It Can Do

### Photo Export
- Export **all photos** from macOS Photos library
- Export **photos in albums** (organized in folders)
- Export **photos NOT in any album** (in "Not-in-Album" folder)
- Export **edited versions** of photos (cropped, filtered, etc.) instead of originals
- Export **videos** (.MOV, .MP4, etc.) alongside photos
- Download from **iCloud** automatically if photos not stored locally
- **Incremental exports** - only export new/changed photos on re-runs

### Upload Features
- Upload to Immich via **local network** (10-100x faster than public internet)
- **Automatic duplicate detection** - skip files already in Immich
- Support for **photos and videos** (all formats Immich supports)
- **Progress tracking** during upload
- **Resumable** - can be re-run safely if interrupted

### Album Organization
- Photos organized by album in export directory
- Albums can be created manually in Immich after upload
- Note: Automatic album creation requires external library setup (advanced)

## What It Can't Do

### Limitations
- **Cannot preserve Live Photos** as Live Photos (exports as separate photo + video)
- **Cannot auto-create albums** from CLI uploads (requires manual creation or external library)
- **Cannot sync deletions** - deleted photos in Photos app remain in Immich
- **Cannot preserve edits separately** - only exports final edited version OR original, not both
- **Cannot selective export by date range** (exports all or uses manual filtering)
- **Requires macOS** - only works on Mac with Photos app

### Workarounds
- **Albums**: Create manually in Immich web UI after upload
- **Live Photos**: Both photo and video are uploaded, can be viewed separately
- **Deletions**: Manual cleanup in Immich or use external library with sync
- **Date filtering**: Use osxphotos advanced query options (see osxphotos docs)

## Prerequisites

### Required
1. **macOS** with Photos app
2. **iCloud Photos** enabled and synced
3. **kubectl** access to homelab cluster
4. **Immich API key** (created in Immich web UI)

### Installed Automatically (if missing)
- pipx (via Homebrew)
- osxphotos (via pipx)
- Immich CLI (via npm)

## Quick Start

### 1. Create API Key

1. Go to: https://immich.h0melab.work/user-settings?isOpen=api-keys
2. Click "Create API Key"
3. Give it a name (e.g., "iOS Import")
4. Grant **ALL permissions**
5. Copy the API key
6. Save it:
   ```bash
   mkdir -p ~/.config/immich
   echo 'your-api-key-here' > ~/.config/immich/api_key.txt
   chmod 600 ~/.config/immich/api_key.txt
   ```

### 2. Run Import Script

```bash
immich-import-ios-photos.sh
```

The script will:
1. Check for required tools (install if needed)
2. Export photos from Photos app
3. Upload to Immich via local network
4. Show progress and summary

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
1. osxphotos reads your Photos library database
2. For each photo:
   - If in iCloud: Downloads using AppleScript
   - If edited: Exports edited version (not original)
   - If in album: Saves to `{album-name}/` folder
   - If not in album: Saves to `Not-in-Album/` folder
3. Creates `.osxphotos_export.db` to track what's been exported

**On re-runs:**
- Checks export database
- Only exports NEW or CHANGED photos
- Skips everything else
- **Result:** 5000 photos → ~30 min first time, ~1 min for 3 new photos

### Phase 2: Upload to Immich

```
Export Directory → kubectl port-forward → Immich Server
```

**What happens:**
1. Script creates `kubectl port-forward` to Immich pod (localhost:2283)
2. Immich CLI:
   - Walks through export directory recursively
   - For each file:
     - Calculates SHA-256 hash
     - Sends hash to Immich: "Do you have this?"
     - If yes: Skips (reports "already uploaded")
     - If no: Uploads file
3. Immich processes uploads in background (thumbnails, ML, etc.)

**Network Path:**
- **Local (default)**: Mac → LAN → kubectl → Pod (fast, ~100MB/s)
- **Public**: Mac → Internet → Cloudflare → Traefik → Pod (slow, ~10MB/s)

### Phase 3: Background Processing

```
Immich Server → ML Pod (ROCm GPU)
```

After upload, Immich automatically:
1. Generates thumbnails (VAAPI hardware accelerated)
2. Extracts metadata (EXIF, date, location, etc.)
3. Runs machine learning:
   - Face detection (ROCm GPU accelerated)
   - Object recognition
   - CLIP embeddings for smart search
4. Processes videos (VAAPI hardware transcoding if needed)

**Performance with increased resources:**
- ~5000 photos: 30-60 minutes total processing
- ML pod has 4 CPU cores + 8GB RAM during bulk import
- AMD GPU acceleration via ROCm for face detection

## Duplicate Handling

### Two-Layer Protection

#### Layer 1: osxphotos (Export Side)
- Maintains `.osxphotos_export.db` in export directory
- Tracks: filename, size, modification time
- On re-export: Only exports new/changed files

#### Layer 2: Immich CLI (Upload Side)
- Calculates hash for each file before upload
- Checks server: "Do you already have this hash?"
- Skips upload if duplicate found

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

You can run the script as often as you want:
- **Daily**: Sync new photos automatically
- **After edits**: Re-export edited photos
- **After interruption**: Resume where it left off

**Important:** Don't delete `.osxphotos_export.db` - it's what makes re-runs fast!

## Troubleshooting

### "osxphotos not found" / pip externally-managed-environment

The script auto-installs via pipx. If it fails:

```bash
brew install pipx
pipx ensurepath
pipx install osxphotos
```

### "Immich CLI not found"

The script auto-installs via npm. If it fails:

```bash
npm install -g @immich/cli
```

### "Failed to connect: 401 Invalid API key"

Your API key is invalid or missing:

1. Create new API key in Immich web UI
2. Save it: `echo 'your-key' > ~/.config/immich/api_key.txt`
3. Re-run script

### "Port-forward failed to start"

kubectl can't connect to cluster:

```bash
# Check cluster connection
kubectl get pods -n immich

# Or use public URL instead
USE_LOCAL=false immich-import-ios-photos.sh
```

### "Waiting for iCloud download..." (stuck)

Photos app needs manual intervention:

1. Open Photos app
2. Click on the stuck photo
3. Photos will start downloading
4. Wait for download to complete
5. Script will continue automatically

### Export is slow / Taking forever

**Normal behavior:**
- First export with iCloud downloads: 30-60 minutes for 5000 photos
- Subsequent exports: <1 minute for new photos only

**If stuck:**
- Check Photos app for iCloud download prompts
- Check internet connection (iCloud needs good bandwidth)
- Consider using `--skip-edited` if you only want originals (faster)

### Upload fails with connection errors

Switch to public URL:

```bash
USE_LOCAL=false immich-import-ios-photos.sh
```

Or check kubectl connection:

```bash
kubectl port-forward -n immich svc/immich-server 2283:8080
# In another terminal:
curl http://localhost:2283/api/server-info/ping
```

## Advanced Usage

### Export Only New Photos

The script automatically does this via `--update`:

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

If you already have photos exported:

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

- [Immich Import Script Reference](./IMPORT_SCRIPT_REFERENCE.md) - Technical details
- [osxphotos Documentation](https://github.com/RhetTbull/osxphotos) - Full feature list
- [Immich CLI Documentation](https://immich.app/docs/features/command-line-interface) - CLI reference
- Script location: `~/.local/bin/immich-import-ios-photos.sh`
