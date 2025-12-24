#!/bin/bash
# 2-hour rebuilderd test - run on worker-node with sudo
set -e

API="http://127.0.0.1:8484/api/v0"

echo "=== Rebuilderd Worker-1 (2-Hour Test) ==="
echo "Start time: $(date)"
echo ""

# Get initial counts
echo "=== Initial package status ==="
INITIAL_GOOD=$(curl -s "$API/pkgs/list?status=GOOD" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
INITIAL_BAD=$(curl -s "$API/pkgs/list?status=BAD" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
INITIAL_UNKWN=$(curl -s "$API/pkgs/list?status=UNKWN" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
echo "GOOD (verified):    $INITIAL_GOOD"
echo "BAD (failed):       $INITIAL_BAD"
echo "UNKWN (pending):    $INITIAL_UNKWN"
echo ""

# Start local worker
echo "=== Starting worker ==="
sudo systemctl start rebuilderd-worker@1
echo "Worker started!"
echo ""

echo "=== Running for 2 hours ==="
echo "Will stop at: $(date -d '+2 hours')"
echo ""

# Show logs for 2 hours
timeout 7200 journalctl -fu rebuilderd-worker@1 || true

# Stop worker
echo ""
echo "=== 2 hours elapsed, stopping worker ==="
sudo systemctl stop rebuilderd-worker@1

# Final counts
echo ""
echo "=== Final package status ==="
FINAL_GOOD=$(curl -s "$API/pkgs/list?status=GOOD" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
FINAL_BAD=$(curl -s "$API/pkgs/list?status=BAD" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
FINAL_UNKWN=$(curl -s "$API/pkgs/list?status=UNKWN" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

echo "GOOD (verified):    $FINAL_GOOD (+$((FINAL_GOOD - INITIAL_GOOD)))"
echo "BAD (failed):       $FINAL_BAD (+$((FINAL_BAD - INITIAL_BAD)))"
echo "UNKWN (pending):    $FINAL_UNKWN"
echo ""

TOTAL_PROCESSED=$((FINAL_GOOD + FINAL_BAD - INITIAL_GOOD - INITIAL_BAD))
echo "=== SUMMARY ==="
echo "Total packages processed (both workers): $TOTAL_PROCESSED"
echo "Packages per hour: $((TOTAL_PROCESSED / 2))"
echo "End time: $(date)"
