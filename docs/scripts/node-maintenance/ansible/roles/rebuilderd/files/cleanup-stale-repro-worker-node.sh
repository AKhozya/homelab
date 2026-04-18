#!/bin/bash
REPRO_DIR=/mnt/k8s-storage/repro

# Get active build container (if any)
ACTIVE=$(ps aux | grep -E 'nspawn.*repro' | grep -v grep | sed 's/.*-D \/var\/lib\/repro\///' | cut -d' ' -f1 || true)

echo "[$(date)] Starting repro cleanup"
echo "Active build: ${ACTIVE:-none}"

BEFORE=$(du -sh $REPRO_DIR 2>/dev/null | cut -f1)

cd $REPRO_DIR
FREED=0
for dir in */; do
    dir=${dir%/}
    if [[ "$dir" == "$ACTIVE" ]] || [[ "$dir" == "keyring" ]] || [[ "$dir" == "_gnupg" ]] || [[ "$dir" == "root" ]] || [[ "$dir" == .* ]]; then
        continue
    else
        SIZE=$(du -sb "$dir" 2>/dev/null | cut -f1 || echo 0)
        FREED=$((FREED + SIZE))
        rm -rf "$dir"
    fi
done

rm -f .*.lck 2>/dev/null || true

AFTER=$(du -sh $REPRO_DIR 2>/dev/null | cut -f1)
FREED_GB=$(echo "scale=1; $FREED/1024/1024/1024" | bc)
echo "Before: $BEFORE, After: $AFTER, Freed: ${FREED_GB}GB"
echo "[$(date)] Cleanup complete"
