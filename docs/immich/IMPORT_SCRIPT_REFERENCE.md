# Immich Import Script Technical Reference

Technical docs for `immich-import-ios-photos.sh`.

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
| `EXPORT_DIR` | `$HOME/ios-photos-export` | Export dir |
| `API_KEY_FILE` | `$HOME/.config/immich/api_key.txt` | API key file |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `USE_LOCAL` | `true` | Local port-forward vs public URL |
| `IMMICH_PUBLIC_URL` | `https://immich.h0melab.work` | Public URL (USE_LOCAL=false) |
| `IMMICH_LOCAL_URL` | `http://localhost:2283` | Local URL (USE_LOCAL=true) |
| `IMMICH_LOCAL_PORT` | `2283` | Local port |

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
2. Check `osxphotos` binary
3. Check `immich` CLI binary
4. Offer to install missing

**Install Methods:**
- `osxphotos`: `pipx install osxphotos` (pipx via Homebrew)
- `immich`: `npm install -g @immich/cli`

**Exit Conditions:**
- API key file not found → error with instructions
- User declines install → exit

### Phase 1: Port-Forward Setup (if USE_LOCAL=true)

**Actions:**
1. Start kubectl port-forward in background
2. Store PID for cleanup
3. Wait 3s for establishment
4. Verify process running

**Command:**
```bash
kubectl port-forward -n immich svc/immich-server 2283:2283 > /dev/null 2>&1 &
```

**Cleanup Trap:**
```bash
trap cleanup EXIT INT TERM
cleanup() {
    kill $PORT_FORWARD_PID 2>/dev/null || true
}
```

**Error Handling:**
- Port-forward fails → suggest public URL
- Process dies → check kubectl connection

### Phase 2: Export from Photos

**Actions:**
1. Prompt user — proceed export
2. Create export dir
3. Run osxphotos export with template
4. Verify content

**Export Command:**
```bash
osxphotos export "$EXPORT_DIR" \
  --directory "{album,Not-in-Album}" \
  --download-missing \
  --update \
  --verbose \
  --skip-original-if-edited
```

**Options:**

| Option | Purpose |
|--------|---------|
| `--directory "{album,Not-in-Album}"` | Template: album name if exists, else "Not-in-Album" |
| `--download-missing` | Download from iCloud if not local |
| `--update` | Only new/changed photos (incremental) |
| `--verbose` | Show progress |
| `--skip-original-if-edited` | Export edited version vs original |

**Template Syntax:**
- `{album}`: album name
- `{album,DEFAULT}`: album name with fallback DEFAULT if no album

**Database:**
- Location: `$EXPORT_DIR/.osxphotos_export.db`
- Tracks: filename, size, mtime, signature
- Used by `--update` for incremental

**Skip Option:**
- User can skip export + use existing files
- For re-upload after failed upload

### Phase 3: Upload to Immich

**Actions:**
1. Configure Immich CLI with API key
2. Prompt user — proceed upload
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
1. Calculate SHA-256 hash
2. Send check: `GET /api/asset/check?fileHash=...`
3. If duplicate → skip, log "already uploaded"
4. If new → upload: `POST /api/asset/upload`

**Performance:**
- Default concurrency: 4 files at once
- Can boost: `IMMICH_UPLOAD_CONCURRENCY=8 immich upload ...`

### Phase 4: Album Creation (Manual)

**Current State:**
- Script does NOT auto-create albums
- CLI uploads don't support album association
- User creates albums manually OR uses external library

**Manual Process:**
1. Open Immich web UI
2. Select photos from folder
3. Create album
4. Add photos

**Future Enhancement:**
- Use Immich API to create albums from folder names
- Needs additional API calls post-upload
- See: `immich-create-albums.sh` for reference

## Duplicate Detection

### Export Side (osxphotos)

**DB Schema:**
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

**Signature:**
- Size (bytes)
- mtime (timestamp)
- Filename

**Note**: does NOT compare content/hashes (for perf)

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
- `isDuplicate: true` → skip
- `isDuplicate: false` → upload

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

**Pros:**
- Fast: ~100MB/s (disk I/O bound)
- Direct pod connection
- No internet bandwidth
- No Cloudflare rate limits

**Cons:**
- Needs kubectl access
- Port-forward unstable for long transfers

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

**Pros:**
- Works from anywhere
- Stable connection
- No kubectl needed

**Cons:**
- Slower: ~10MB/s (internet upload)
- Uses internet bandwidth
- Multiple proxies

## Error Handling

### Auto Retries

**osxphotos:**
- iCloud download fails: retries with exponential backoff
- FS errors: reports + continues with next file

**Immich CLI:**
- Network errors: retries up to 3x per file
- Upload fails: reports + continues

### User Intervention Required

| Error | Cause | Solution |
|-------|-------|----------|
| "API key file not found" | Missing API key | Create API key, save to file |
| "Port-forward failed" | kubectl not connected | `kubectl get pods` or use public URL |
| "Photos library not found" | Photos app not setup | Open Photos, setup library |
| "Waiting for iCloud download..." (stuck) | Manual prompt in Photos | Open Photos, click download |
| "Permission denied" | API key lacks perms | Recreate with ALL permissions |

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
- Mem: ~500MB
- Disk I/O: read Photos lib, write export dir
- Network: iCloud downloads if needed

**macOS (during upload):**
- CPU: 5-15% (Immich CLI hashing)
- Mem: ~200MB
- Disk I/O: read export dir
- Network: upload bandwidth saturated

**Immich Server (during upload):**
- CPU: 200m-3000m (boosted for bulk import)
- Mem: 512Mi-6Gi (boosted)
- Disk I/O: write to storage
- Network: receive uploads

**Immich ML (background processing):**
- CPU: 200m-4000m (boosted)
- Mem: 2Gi-8Gi (boosted)
- GPU: AMD ROCm for face detection
- Disk I/O: read photos, write embeddings to DB

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
- Up to 40GB total
- Mixed photos + videos

**Expected limits:**
- osxphotos: 100k+ photos (Photos app bound)
- Immich CLI: unlimited files (uploads serially)
- Immich Server: cluster resources

**Bottlenecks:**
1. First export: iCloud download speed
2. Local upload: disk I/O export dir
3. Public upload: internet upload bandwidth
4. Background: ML inference time

## Security Considerations

### API Key Storage

**Current:**
- Plaintext: `~/.config/immich/api_key.txt`
- Permissions: `600` (owner read/write only)

**Risks:**
- Accessible to any user-process
- Visible in process list during execution

**Mitigations:**
- API key scope limited to current user
- Revokable in Immich web UI
- Should use short-lived tokens (not implemented)

### Network Security

**Local Mode:**
- kubectl uses cluster creds (`~/.kube/config`)
- Port-forward = localhost-only tunnel
- No external exposure

**Public Mode:**
- HTTPS with TLS 1.3
- Cloudflare tunnel (encrypted)
- API key in Authorization header

### File System Security

**Export Directory:**
- Default perms: user umask (typically 755)
- Contains all exported photos (sensitive)
- No encryption at rest (relies on FileVault)

**osxphotos Database:**
- Contains file paths + metadata
- No photo content
- Perms: same as export dir

## Monitoring and Logging

### Script Output

**Progress Indicators:**
- osxphotos: per-file progress with verbose
- Immich CLI: progress bar + file count
- Color-coded (green=success, red=error, yellow=warning)

**Log Locations:**
- osxphotos: stderr (terminal)
- Immich CLI: stdout (terminal)
- No persistent logs (redirect if needed)

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

**Location**: `~/.local/bin/immich-import-ios-photos.sh`

**Customizable Variables (top of script):**
```bash
USE_LOCAL="${USE_LOCAL:-true}"
IMMICH_PUBLIC_URL="https://immich.h0melab.work"
IMMICH_LOCAL_URL="http://localhost:2283"
IMMICH_LOCAL_PORT="2283"
```

### osxphotos Configuration

**No config file** — all options via CLI args

**Template Customization:**
```bash
# In script, change this line:
--directory "{album,Not-in-Album}"

# To (for example):
--directory "{created.year}/{album}"
# Result: 2024/Vacation, 2024/Not-in-Album, etc.
```

### Immich CLI Configuration

**Location**: `~/.config/immich/auth.yml` (auto-created)

**Content:**
```yaml
instanceUrl: http://localhost:2283/api
apiKey: <YOUR_API_KEY>
```

**Note**: overwritten each run (login-key command)

## Dependencies

### macOS System

| Dependency | Min Version | Used For |
|------------|-------------|----------|
| macOS | 10.15+ | Photos app |
| Photos app | Any | Photo source |
| Python | 3.8+ | osxphotos (via pipx) |
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

**Enable verbose:**
```bash
set -x
# ... rest of script
```

**Check osxphotos DB:**
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
- Not error, warning
- osxphotos devs haven't tested your macOS version
- Usually works, ignore unless actual errors

**"No such option: --add-missing-albums":**
- Old error from previous script version
- Fixed by correct options
- Update script if seen

**Export DB corruption:**
```bash
# Delete and re-export (slow but fixes issues)
rm ~/ios-photos-export/.osxphotos_export.db
immich-import-ios-photos.sh
```

## Future Enhancements

### Potential Improvements

1. **Auto-create albums via API**
   - Use Immich API
   - Match folder names to album names
   - Needs additional API calls post-upload

2. **Scheduled sync**
   - cron job for daily imports
   - launchd plist for macOS scheduling
   - Notification on completion

3. **Selective sync**
   - CLI options for date ranges
   - Album filtering
   - Exclude patterns

4. **Progress persistence**
   - Save upload state
   - Resume from interrupt
   - Skip uploaded files efficiently

5. **Encryption**
   - Encrypt export dir
   - Encrypted API key storage
   - macOS Keychain for secrets

## Related Scripts

### `immich-create-albums.sh`

**Location**: `~/.local/bin/immich-create-albums.sh`

**Purpose**: create albums from folder structure (needs external library)

**Limitation**: only works with external libraries, not CLI uploads

### `immich-import-with-albums.sh`

**Location**: `~/.local/bin/immich-import-with-albums.sh`

**Purpose**: alternative workflow — external library + album creator

**Complexity**: more setup (pod access, external library config)

## References

- [osxphotos GitHub](https://github.com/RhetTbull/osxphotos)
- [osxphotos Documentation](https://rhettbull.github.io/osxphotos/)
- [Immich CLI Documentation](https://immich.app/docs/features/command-line-interface)
- [Immich API Documentation](https://immich.app/docs/api)
- [immich-folder-album-creator](https://github.com/Salvoxia/immich-folder-album-creator)
