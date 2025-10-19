# Immich Import Script Technical Reference

Technical documentation for `immich-import-ios-photos.sh` script.

## Script Location

```
~/.local/bin/immich-import-ios-photos.sh
```

## Synopsis

```bash
immich-import-ios-photos.sh [EXPORT_DIR] [API_KEY_FILE]
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `EXPORT_DIR` | `$HOME/ios-photos-export` | Directory for exported photos |
| `API_KEY_FILE` | `$HOME/.config/immich/api_key.txt` | File containing Immich API key |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `USE_LOCAL` | `true` | Use local port-forward instead of public URL |
| `IMMICH_PUBLIC_URL` | `https://immich.h0melab.work` | Public Immich URL (when USE_LOCAL=false) |
| `IMMICH_LOCAL_URL` | `http://localhost:2283` | Local Immich URL (when USE_LOCAL=true) |
| `IMMICH_LOCAL_PORT` | `2283` | Local port for port-forward |

## Architecture

### Component Flow

```
┌─────────────────┐
│   Photos App    │
│   (macOS)       │
└────────┬────────┘
         │
         │ osxphotos export
         │ - Reads Photos.sqlite
         │ - Downloads from iCloud
         │ - Exports edited versions
         │
         ▼
┌─────────────────┐
│  Export Dir     │
│  ~/ios-photos-  │
│     export      │
│                 │
│  ├─ Album1/     │
│  ├─ Album2/     │
│  └─ Not-in-     │
│     Album/      │
└────────┬────────┘
         │
         │ kubectl port-forward
         │ (localhost:2283 → pod:8080)
         │
         ▼
┌─────────────────┐
│  Immich CLI     │
│  - Hash files   │
│  - Check dups   │
│  - Upload       │
└────────┬────────┘
         │
         │ HTTP POST /api/asset/upload
         │
         ▼
┌─────────────────┐
│  Immich Server  │
│  (K8s Pod)      │
│  - Receive      │
│  - Store        │
│  - Queue jobs   │
└────────┬────────┘
         │
         │ Background Jobs
         │
         ▼
┌─────────────────┐
│  Immich ML      │
│  (ROCm GPU)     │
│  - Thumbnails   │
│  - Face detect  │
│  - CLIP embed   │
└─────────────────┘
```

## Script Phases

### Phase 0: Prerequisites Check

**Actions:**
1. Validate API key file exists
2. Check for `osxphotos` binary
3. Check for `immich` CLI binary
4. Offer to install missing tools

**Installation Methods:**
- `osxphotos`: `pipx install osxphotos` (after ensuring pipx via Homebrew)
- `immich`: `npm install -g @immich/cli`

**Exit Conditions:**
- API key file not found → Error with instructions
- User declines tool installation → Exit

### Phase 1: Port-Forward Setup (if USE_LOCAL=true)

**Actions:**
1. Start kubectl port-forward in background
2. Store PID for cleanup
3. Wait 3 seconds for establishment
4. Verify process still running

**Command:**
```bash
kubectl port-forward -n immich svc/immich-server 2283:8080 > /dev/null 2>&1 &
```

**Cleanup Trap:**
```bash
trap cleanup EXIT INT TERM
cleanup() {
    kill $PORT_FORWARD_PID 2>/dev/null || true
}
```

**Error Handling:**
- Port-forward fails to start → Suggest using public URL
- Process dies immediately → Check kubectl connection

### Phase 2: Export from Photos

**Actions:**
1. Prompt user to proceed with export
2. Create export directory
3. Run osxphotos export with template
4. Verify export directory has content

**Export Command:**
```bash
osxphotos export "$EXPORT_DIR" \
  --directory "{album,Not-in-Album}" \
  --download-missing \
  --update \
  --verbose \
  --skip-original-if-edited
```

**Options Explained:**

| Option | Purpose |
|--------|---------|
| `--directory "{album,Not-in-Album}"` | Template: use album name if exists, else "Not-in-Album" |
| `--download-missing` | Download from iCloud if not stored locally |
| `--update` | Only export new/changed photos (incremental) |
| `--verbose` | Show progress and details |
| `--skip-original-if-edited` | Export edited version instead of original |

**Template Syntax:**
- `{album}`: Album name
- `{album,DEFAULT}`: Album name with fallback to DEFAULT if no album

**Database:**
- Location: `$EXPORT_DIR/.osxphotos_export.db`
- Tracks: filename, size, mtime, signature
- Used by: `--update` for incremental exports

**Skip Option:**
- User can skip export and use existing files
- Useful for re-upload after failed upload

### Phase 3: Upload to Immich

**Actions:**
1. Configure Immich CLI with API key
2. Prompt user to proceed with upload
3. Run recursive upload
4. Report completion

**Configure Command:**
```bash
immich login-key "$IMMICH_URL/api" "$API_KEY"
```

**Upload Command:**
```bash
immich upload "$EXPORT_DIR" --recursive
```

**Upload Process (per file):**
1. Calculate file hash (SHA-256)
2. Send check request: `GET /api/asset/check?fileHash=...`
3. If duplicate → Skip, log "already uploaded"
4. If new → Upload: `POST /api/asset/upload`

**Performance:**
- Default concurrency: 4 files at once
- Can be increased: `IMMICH_UPLOAD_CONCURRENCY=8 immich upload ...`

### Phase 4: Album Creation (Manual)

**Current State:**
- Script does NOT auto-create albums
- CLI uploads don't support album association
- User must create albums manually OR use external library

**Manual Process:**
1. Open Immich web UI
2. Select photos from folder
3. Create album
4. Add photos to album

**Future Enhancement:**
- Could use Immich API to create albums based on folder names
- Would require additional API calls after upload
- See: `immich-create-albums.sh` for reference implementation

## Duplicate Detection

### Export Side (osxphotos)

**Database Schema:**
```sql
-- Simplified representation
CREATE TABLE exported_files (
    filepath TEXT PRIMARY KEY,
    size INTEGER,
    mtime REAL,
    signature TEXT
);
```

**Comparison Logic:**
```python
# Pseudo-code
if file_exists_in_db(filepath):
    db_signature = get_signature(filepath)
    current_signature = calculate_signature(file)
    if db_signature == current_signature:
        skip_export()
    else:
        re_export()
else:
    export()
```

**Signature Calculation:**
- Size (bytes)
- Modification time (timestamp)
- Filename

**Note:** Does NOT compare file content or hashes (for performance)

### Upload Side (Immich CLI)

**Hash Calculation:**
```javascript
// Simplified
const hash = crypto.createHash('sha256');
hash.update(fileBuffer);
const checksum = hash.digest('hex');
```

**Check Request:**
```http
GET /api/asset/check HTTP/1.1
Host: immich.h0melab.work
Authorization: Bearer <API_KEY>
Content-Type: application/json

{
  "fileChecksum": "abc123...",
  "fileName": "photo.jpg"
}
```

**Server Response:**
```json
{
  "isDuplicate": true,
  "existingAssetId": "uuid-..."
}
```

**Upload Decision:**
- `isDuplicate: true` → Skip upload
- `isDuplicate: false` → Proceed with upload

## Network Topology

### Local Mode (USE_LOCAL=true)

```
┌─────────────┐
│   MacBook   │
│  10.0.0.50  │
└──────┬──────┘
       │ LAN (1Gbps)
       │
       ▼
┌─────────────────┐
│  kubectl proxy  │
│  localhost:2283 │
└──────┬──────────┘
       │ K8s API
       │
       ▼
┌──────────────────┐
│  immich-server   │
│  svc/immich-     │
│  server:8080     │
│  (in cluster)    │
└──────────────────┘
```

**Advantages:**
- Fast: ~100MB/s (limited by disk I/O)
- Direct connection to pod
- No internet bandwidth usage
- No Cloudflare rate limits

**Disadvantages:**
- Requires kubectl access
- Port-forward can be unstable for long transfers

### Public Mode (USE_LOCAL=false)

```
┌─────────────┐
│   MacBook   │
└──────┬──────┘
       │ Internet
       │
       ▼
┌─────────────┐
│  Cloudflare │
│   Tunnel    │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│   Traefik   │
│  Ingress    │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│  immich-    │
│  server:8080│
└─────────────┘
```

**Advantages:**
- Works from anywhere
- Stable connection
- No kubectl required

**Disadvantages:**
- Slower: ~10MB/s (internet upload speed)
- Uses internet bandwidth
- Goes through multiple proxies

## Error Handling

### Automatic Retries

**osxphotos:**
- iCloud download failures: Retries with exponential backoff
- File system errors: Reports and continues with next file

**Immich CLI:**
- Network errors: Retries up to 3 times per file
- Upload failures: Reports and continues with next file

### User Intervention Required

| Error | Cause | Solution |
|-------|-------|----------|
| "API key file not found" | Missing API key | Create API key, save to file |
| "Port-forward failed" | kubectl not connected | Check `kubectl get pods`, or use public URL |
| "Photos library not found" | Photos app not set up | Open Photos app, set up library |
| "Waiting for iCloud download..." (stuck) | Manual prompt in Photos | Open Photos app, click download |
| "Permission denied" | API key lacks permissions | Recreate API key with ALL permissions |

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | User cancelled |
| 1 | Missing prerequisites |
| 1 | Export failed |
| 1 | Upload failed |

## Performance Characteristics

### Resource Usage

**macOS (during export):**
- CPU: 10-30% (1 core, osxphotos)
- Memory: ~500MB
- Disk I/O: Read from Photos library, write to export dir
- Network: iCloud downloads if needed

**macOS (during upload):**
- CPU: 5-15% (Immich CLI hashing)
- Memory: ~200MB
- Disk I/O: Read from export dir
- Network: Upload bandwidth saturated

**Immich Server (during upload):**
- CPU: 200m-3000m (currently boosted for bulk import)
- Memory: 512Mi-6Gi (currently boosted)
- Disk I/O: Write to storage
- Network: Receive uploads

**Immich ML (background processing):**
- CPU: 200m-4000m (currently boosted)
- Memory: 2Gi-8Gi (currently boosted)
- GPU: AMD ROCm for face detection
- Disk I/O: Read photos, write embeddings to DB

### Timing Estimates

**First Import (~5000 photos, ~40GB):**

| Phase | Local Network | Public Internet |
|-------|---------------|-----------------|
| Export (with iCloud downloads) | 30-45 min | 30-45 min |
| Upload | 5-10 min | 40-60 min |
| **Total Upload Time** | **35-55 min** | **70-105 min** |
| Background Processing | 30-60 min | 30-60 min |

**Subsequent Import (3 new photos, ~20MB):**

| Phase | Local Network | Public Internet |
|-------|---------------|-----------------|
| Export (incremental) | 10 sec | 10 sec |
| Upload | 5 sec | 30 sec |
| **Total Upload Time** | **15 sec** | **40 sec** |
| Background Processing | 1-2 min | 1-2 min |

### Scalability

**Tested:**
- Up to 5000 photos
- Up to 40GB total size
- Mixed photos and videos

**Expected limits:**
- osxphotos: Can handle 100k+ photos (limited by Photos app)
- Immich CLI: Can handle unlimited files (uploads serially)
- Immich Server: Depends on cluster resources

**Bottlenecks:**
1. First export: iCloud download speed
2. Local upload: Disk I/O on export directory
3. Public upload: Internet upload bandwidth
4. Background processing: ML model inference time

## Security Considerations

### API Key Storage

**Current:**
- Stored in plaintext: `~/.config/immich/api_key.txt`
- Permissions: `600` (owner read/write only)

**Risks:**
- Accessible to any process running as user
- Visible in process list during script execution

**Mitigations:**
- API key has scope limited to current user
- Can be revoked in Immich web UI
- Should use short-lived tokens (not implemented)

### Network Security

**Local Mode:**
- kubectl uses cluster credentials (`~/.kube/config`)
- Port-forward creates localhost-only tunnel
- No external network exposure

**Public Mode:**
- HTTPS with TLS 1.3
- Cloudflare tunnel (encrypted)
- API key in Authorization header

### File System Security

**Export Directory:**
- Default permissions: User's umask (typically 755)
- Contains all exported photos (potentially sensitive)
- No encryption at rest (relies on FileVault)

**osxphotos Database:**
- Contains file paths and metadata
- No photo content
- Permissions: Same as export directory

## Monitoring and Logging

### Script Output

**Progress Indicators:**
- osxphotos: Per-file progress with verbose mode
- Immich CLI: Progress bar + file count
- Color-coded messages (green=success, red=error, yellow=warning)

**Log Locations:**
- osxphotos: Stderr (shown in terminal)
- Immich CLI: Stdout (shown in terminal)
- No persistent logs (user must redirect if needed)

### Immich Server Logs

**Check upload processing:**
```bash
kubectl logs -n immich deployment/immich-server -c main --tail=100
```

**Check ML processing:**
```bash
kubectl logs -n immich deployment/immich-machine-learning --tail=100
```

**Check for errors:**
```bash
kubectl logs -n immich deployment/immich-server -c main | grep -i error
```

## Configuration Files

### Script Configuration

**Location:** `~/.local/bin/immich-import-ios-photos.sh`

**Customizable Variables (top of script):**
```bash
USE_LOCAL="${USE_LOCAL:-true}"
IMMICH_PUBLIC_URL="https://immich.h0melab.work"
IMMICH_LOCAL_URL="http://localhost:2283"
IMMICH_LOCAL_PORT="2283"
```

### osxphotos Configuration

**No config file** - all options via CLI arguments

**Template Customization:**
```bash
# In script, change this line:
--directory "{album,Not-in-Album}"

# To (for example):
--directory "{created.year}/{album}"
# Result: 2024/Vacation, 2024/Not-in-Album, etc.
```

### Immich CLI Configuration

**Location:** `~/.config/immich/auth.yml` (auto-created)

**Content:**
```yaml
instanceUrl: http://localhost:2283/api
apiKey: <YOUR_API_KEY>
```

**Note:** Overwritten each time script runs (login-key command)

## Dependencies

### macOS System

| Dependency | Min Version | Used For |
|------------|-------------|----------|
| macOS | 10.15+ | Photos app |
| Photos app | Any | Source of photos |
| Python | 3.8+ | osxphotos (installed by pipx) |
| Node.js | 14+ | Immich CLI (npm) |
| kubectl | 1.20+ | Port-forward (optional) |

### Python Tools

| Tool | Version | Install Method |
|------|---------|----------------|
| pipx | Latest | `brew install pipx` |
| osxphotos | Latest | `pipx install osxphotos` |

### Node.js Tools

| Tool | Version | Install Method |
|------|---------|----------------|
| @immich/cli | Latest | `npm install -g @immich/cli` |

### Homebrew Packages

| Package | Used For |
|---------|----------|
| pipx | Install osxphotos |
| kubectl | Port-forward (optional) |

## Troubleshooting Guide

### Debug Mode

**Enable verbose output:**
```bash
set -x
# ... rest of script
```

**Check osxphotos database:**
```bash
sqlite3 ~/ios-photos-export/.osxphotos_export.db "SELECT COUNT(*) FROM exported_files;"
```

**Test Immich CLI connection:**
```bash
immich login-key "http://localhost:2283/api" "your-key"
immich server-info
```

### Common Issues

**"Platform not tested" warning:**
```
WARNING: This module has only been tested with macOS versions [...]
```
- Not an error, just a warning
- osxphotos developers haven't tested on your macOS version yet
- Usually works fine, ignore unless you see actual errors

**"No such option: --add-missing-albums":**
- Old error from previous script version
- Fixed by using correct options
- Update script if you see this

**Export database corruption:**
```bash
# Delete and re-export (slow but fixes issues)
rm ~/ios-photos-export/.osxphotos_export.db
immich-import-ios-photos.sh
```

## Future Enhancements

### Potential Improvements

1. **Auto-create albums via API**
   - Use Immich API to create albums
   - Match folder names to album names
   - Requires additional API calls after upload

2. **Scheduled sync**
   - cron job for daily imports
   - launchd plist for macOS scheduling
   - Notification on completion

3. **Selective sync**
   - Command-line options for date ranges
   - Album filtering
   - Exclude patterns

4. **Progress persistence**
   - Save upload state
   - Resume from interruption
   - Skip already-uploaded files more efficiently

5. **Encryption**
   - Encrypt export directory
   - Encrypted API key storage
   - Use macOS Keychain for secrets

## Related Scripts

### `immich-create-albums.sh`

**Location:** `~/.local/bin/immich-create-albums.sh`

**Purpose:** Create albums from folder structure (requires external library)

**Limitation:** Only works with external libraries, not CLI uploads

### `immich-import-with-albums.sh`

**Location:** `~/.local/bin/immich-import-with-albums.sh`

**Purpose:** Alternative workflow using external library + album creator

**Complexity:** More complex setup (requires pod access, external library config)

## References

- [osxphotos GitHub](https://github.com/RhetTbull/osxphotos)
- [osxphotos Documentation](https://rhettbull.github.io/osxphotos/)
- [Immich CLI Documentation](https://immich.app/docs/features/command-line-interface)
- [Immich API Documentation](https://immich.app/docs/api)
- [immich-folder-album-creator](https://github.com/Salvoxia/immich-folder-album-creator)
