# Backup Compression Analysis

## Executive Summary

Analysis of compression ratios across all backup types revealed that **compressing media files (photos/videos/audio) is not worth the time cost**. Immich photo library compression saves only 0.5% (300MB out of 60.6GB) but takes 25 minutes of CPU time.

**Decision**: Skip compression for media-heavy PVCs (Immich, Audiobookshelf).

## Compression Ratio by Backup Type

### PVC Backups (60.3GB total)

| Volume | Original | Compressed | Ratio | Time | Verdict |
|--------|----------|------------|-------|------|---------|
| **Immich (photos/videos)** | 60.6G | 60.3G | **0.5%** | **25 min** | ❌ **NOT worth it** |
| Home Assistant (configs) | 54.1M | 18.3M | **66%** | 1s | ✅ Worth it |
| Small configs | 1.4M | 108K | **92%** | <1s | ✅ Worth it |
| Audiobookshelf (audio) | Various | - | **~1%** | High | ❌ NOT worth it |

### Database Backups

| Database | Original | Compressed | Ratio | Verdict |
|----------|----------|------------|-------|---------|
| PostgreSQL | ~44M | 43.3M | **~2%** | Marginal benefit |
| CouchDB | 4.1M | 3.1M | **24%** | ✅ Worth it |

## Why Media Files Don't Compress

Modern media formats are **already heavily compressed**:
- **JPEG/PNG** (photos): Lossy compression baked in
- **MP4/MOV** (videos): H.264/H.265 codec compression
- **MP3/AAC** (audio): Lossy compression algorithms

**Result**: Gzip can't compress pre-compressed data further.

## Implementation

### Before Optimization
```
Immich: 60.6G → 60.3G (tar.gz)
Time: 25 minutes
CPU: 100% of 1 core for 1500 seconds
Space saved: 300MB (0.5%)
```

### After Optimization
```
Immich: 60.6G → 60.6G (tar only)
Time: ~2-3 minutes (estimated)
CPU: Minimal (just archiving)
Space cost: +300MB
Time saved: ~22 minutes per backup
```

## Configuration

Volumes in `NO_COMPRESS_PVCS` list skip compression:
```bash
NO_COMPRESS_PVCS="
immich-library              # Photos/videos
audiobookshelf-audiobooks   # Audio files
audiobookshelf-podcasts     # Audio files
"
```

## Resource Impact

### Before (with compression)
- **Backup duration**: ~25 minutes
- **Peak CPU**: 1005m (1.0 core)
- **Average CPU**: ~900m
- **Memory**: 11-17Mi (minimal)
- **Storage used**: 60.3GB

### After (selective compression)
- **Backup duration**: ~3 minutes (estimated)
- **Peak CPU**: <200m (archiving only)
- **Memory**: 11-17Mi (unchanged)
- **Storage used**: 60.6GB (+300MB)

## Cost-Benefit Analysis

### Time Savings
- Per backup: **22 minutes saved**
- Daily (3 AM schedule): **22 min/day**
- Monthly: **11 hours/month**
- Yearly: **133 hours/year**

### Storage Cost
- Additional: **300MB** (0.5% of 60.6GB)
- On 4.2TB storage pool: **0.007% utilization**
- Cost: **Negligible**

### CPU Savings
- Per backup: **1500 seconds** of CPU time
- Daily: **25 CPU-minutes/day**
- Monthly: **12.5 CPU-hours/month**

## Recommendation Summary

✅ **Compress**: Text-based data (configs, databases, documents)
- Home Assistant configs: 66% compression
- CouchDB documents: 24% compression
- Paperless documents: Varies

❌ **Don't Compress**: Media files (photos, videos, audio)
- Immich photos: 0.5% compression
- Audiobookshelf audio: ~1% compression
- Already pre-compressed formats

## Trade-offs Accepted

1. **+300MB storage** for Immich
   - Acceptable on 4.2TB pool (0.007%)
   - Time savings far outweigh cost

2. **Mixed backup formats** (.tar and .tar.gz)
   - Slightly more complex restore process
   - Well-documented in manifest
   - Clear labeling in logs

3. **No compression benefit** for future growth
   - As Immich library grows, no additional space savings
   - But also no additional compression time penalty

## Monitoring

Resource usage will be monitored to validate estimates:
- Current tests show ~900m average CPU during compression
- Estimate ~50-100m for archiving only
- Memory usage remains minimal (~15Mi)

## References

- Backup implementation: `infrastructure/configs/staging/backup/pvc-backup-cronjob.yaml`
- 3 AM backup logs: See job `pvc-backup-29353080` for compression analysis data
- Resource monitoring: See `infrastructure/configs/staging/backup/pvc-backup-cronjob.yaml:208-214`
