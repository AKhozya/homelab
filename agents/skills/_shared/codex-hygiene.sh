#!/usr/bin/env bash
# codex-hygiene.sh — sweep leaked Codex brokers and orphaned job records.
#
# Run BEFORE dispatching a Codex review. A wedged broker does not error — it accepts the turn
# and kills it silently with turn_aborted/interrupted after minutes of nothing, so the cheap
# moment to look is before handing it work, not after losing a review to it.
#
# Broker verdicts: STALE (cwd deleted) | IDLE (old, nothing running) | LIVE (keep)
# Exit: 0 ok, 2 bad args, 3 a kill did not take.
set -euo pipefail

APPLY=0
MAX_AGE_H=24
STATE="$HOME/.claude/plugins/data/codex-openai-codex/state"
# Anchored to how the plugin actually invokes these, not to the bare name: `pgrep -f` matches
# any argv, so a loose pattern selects a grep, an editor, or a test harness carrying the same
# string. `serve` and the trailing anchors are what make this a broker rather than a mention.
BROKER_RE='app-server-broker\.mjs serve( |$)|/codex app-server$|/codex-code-mode-host$'

usage() {
  cat <<'EOF'
usage: codex-hygiene.sh [--apply] [--max-age-hours N]
  default          dry-run: classify, change nothing
  --apply          kill leaked brokers, resolve orphaned job records
  --max-age-hours  idle-broker threshold (default 24)
EOF
}

while (($#)); do
  case "$1" in
  --apply) APPLY=1 ;;
  --max-age-hours)
    shift
    MAX_AGE_H="${1:-}"
    [[ $MAX_AGE_H =~ ^[0-9]+$ ]] || {
      echo "--max-age-hours needs an integer" >&2
      exit 2
    }
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "unknown arg: $1" >&2
    usage >&2
    exit 2
    ;;
  esac
  shift
done

for t in jq lsof; do
  command -v "$t" >/dev/null 2>&1 || {
    echo "missing required tool: $t" >&2
    exit 2
  }
done

MAX_AGE_S=$((MAX_AGE_H * 3600))
TS=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
FAILED=0

# Every helper that inspects a pid ends in `|| true`: under `pipefail` a process that exits
# between enumeration and inspection makes the whole pipeline non-zero, and errexit then kills
# the sweep mid-run with no output. Verified: without this the script aborts at exit 1.
age_seconds() { # macOS ps has no etimes; etime is [[dd-]hh:]mm:ss and parses locale-free
  ps -o etime= -p "$1" 2>/dev/null | tr -d ' ' |
    awk -F'[-:]' 'NF==2{print $1*60+$2} NF==3{print $1*3600+$2*60+$3} NF==4{print $1*86400+$2*3600+$3*60+$4}' ||
    true
}

proc_cwd() {
  lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | tail -1 || true
}

proc_argv() {
  ps -o command= -p "$1" 2>/dev/null || true
}

# Own ancestry, so the sweep cannot kill the Codex turn that is running it. Cheap and exact;
# the alternative (inferring ownership from cwd) cannot tell a parent from a sibling.
SELF_CHAIN=""
_p=$$
while [[ -n $_p && $_p -gt 1 ]]; do
  SELF_CHAIN="$SELF_CHAIN $_p"
  _p=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ' || true)
done

is_self() { [[ " $SELF_CHAIN " == *" $1 "* ]]; }

# kill(1) returning 0 only means the signal was accepted — the process may still hold the
# doomed cwd for seconds. Callers need to know it actually went, so wait, escalate, confirm.
terminate() { # terminate <pid> -> 0 gone, 1 survived
  # A failed kill is NOT proof the process died — ESRCH means gone, anything else (EPERM)
  # means alive and unsignallable. Treating both as success reports a kill that never landed.
  if ! kill -TERM "$1" 2>/dev/null; then
    kill -0 "$1" 2>/dev/null || return 0
    return 1
  fi
  for _ in $(seq 1 20); do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.25
  done
  kill -KILL "$1" 2>/dev/null || true
  sleep 0.5
  kill -0 "$1" 2>/dev/null && return 1
  return 0
}

# jq|sponge is a read-modify-write with no failure atomicity: a jq error still lets sponge
# truncate the file. Same-directory temp + rename means a failed run leaves the original.
write_json() { # write_json <file> <jq-args...>
  local f="$1" tmp
  shift
  tmp="$f.hygiene.$$"
  # Braces so the redirect's own failure (unwritable directory) is silenced too — jq's
  # 2>/dev/null cannot catch an error the shell raises before jq starts.
  if { jq "$@" "$f" >"$tmp"; } 2>/dev/null && [[ -s $tmp ]] && mv -f "$tmp" "$f" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# --- orphaned job records ---
# A record stuck at status=running with a dead pid nags the Stop hook forever, and
# `codex-companion cancel` only reaches the CURRENT workspace. Resolved before the broker pass,
# because the broker verdicts depend on which jobs are genuinely running.
orphans=0 live_jobs=0 state_ok=1

scan_records() { # sets orphans/live_jobs; prints per-record lines
  local sf ws id pid rows
  orphans=0 live_jobs=0 state_ok=1
  for sf in "$STATE"/*/state.json; do
    [[ -f $sf ]] || continue
    ws=$(basename "$(dirname "$sf")")
    # An unreadable or half-written state file must not read as "nothing is running" — that
    # would silently promote every old broker to killable. Mark undetermined instead.
    if ! rows=$(jq -r '.jobs[]? | select(.status=="running") | "\(.id)\t\(.pid // "")"' "$sf" 2>/dev/null); then
      echo "UNREADABLE $ws state.json — idle kills suppressed"
      state_ok=0
      continue
    fi
    [[ -n $rows ]] || continue
    while IFS=$'\t' read -r id pid; do
      [[ -n $id ]] || continue
      if [[ -n $pid && $pid != null ]] && kill -0 "$pid" 2>/dev/null; then
        live_jobs=$((live_jobs + 1))
        echo "RUNNING  $ws job $id (pid $pid alive)"
        continue
      fi
      orphans=$((orphans + 1))
      # jobs/<id>.json first: if the second write fails, the record is still selected next
      # run. Cancelling state.json first would hide it and strand the per-job file forever.
      # The status/pid guard makes this a compare-and-swap — a record the companion revived
      # between the scan and now is left alone. $ts/$id/$pid are jq variables bound by --arg,
      # so the single quotes below are correct.
      # shellcheck disable=SC2016
      if ((APPLY)); then
        jf="$(dirname "$sf")/jobs/$id.json"
        if [[ -f $jf ]] && ! write_json "$jf" --arg ts "$TS" --arg pid "$pid" \
          'if .status=="running" and ((.pid // "")|tostring)==$pid
           then .status="cancelled" | .updatedAt=$ts else . end'; then
          # Leaving state.json alone keeps the record selectable next run. Cancelling it here
          # would hide a per-job file still stuck at running, with nothing left to find it.
          echo "FAILED   $ws job $id — jobs file unwritable, state.json untouched" >&2
          FAILED=1
          continue
        fi
        if write_json "$sf" --arg ts "$TS" --arg id "$id" --arg pid "$pid" \
          '.jobs |= map(if .id==$id and .status=="running" and ((.pid // "")|tostring)==$pid
                        then .status="cancelled" | .updatedAt=$ts else . end)'; then
          # jq succeeds whether or not the guard matched, so a write that changed nothing
          # would otherwise print RESOLVED. Read the status back and say which it was.
          now=$(jq -r --arg id "$id" '.jobs[]? | select(.id==$id) | .status' "$sf" 2>/dev/null || echo "?")
          if [[ $now == cancelled ]]; then
            echo "RESOLVED $ws job $id (pid ${pid:-none} dead)"
          else
            echo "SKIPPED  $ws job $id — record changed under us (now ${now:-gone})"
          fi
        else
          echo "FAILED   $ws job $id — state.json unchanged" >&2
          FAILED=1
        fi
      else
        echo "would resolve  $ws job $id (pid ${pid:-none} dead)"
      fi
    done <<<"$rows"
  done
}

scan_records

# --- brokers ---
# STALE dies regardless: its turns are already lost, so there is nothing left to protect.
# IDLE additionally needs a trustworthy "nothing is running" — hence state_ok and the recheck.
brokers=0
for pid in $(pgrep -f "$BROKER_RE" 2>/dev/null || true); do
  brokers=$((brokers + 1))
  cwd=$(proc_cwd "$pid")
  [[ -n $cwd ]] || continue
  age=$(age_seconds "$pid")
  age=${age:-0}
  if is_self "$pid"; then
    verdict=SELF
  elif [[ ! -d $cwd ]]; then
    verdict=STALE
  elif ((age > MAX_AGE_S && live_jobs == 0 && state_ok == 1)); then
    verdict=IDLE
  else
    verdict=LIVE
  fi
  printf '%-8s broker pid %-7s age %-5s cwd %s\n' "$verdict" "$pid" "$((age / 3600))h" "$cwd"
  [[ $verdict == LIVE || $verdict == SELF ]] && continue
  if ((APPLY)); then
    # Re-read the argv immediately before signalling: between pgrep and here the pid may have
    # been recycled onto an unrelated process. Cannot be closed fully on macOS (no pidfd), but
    # it shrinks the window to this check.
    if ! proc_argv "$pid" | grep -Eq "$BROKER_RE"; then
      echo "SKIPPED  pid $pid no longer a broker"
      continue
    fi
    if terminate "$pid"; then
      echo "KILLED   broker pid $pid ($verdict)"
    else
      echo "FAILED   broker pid $pid survived SIGKILL" >&2
      FAILED=1
    fi
  else
    echo "would kill    broker pid $pid ($verdict)"
  fi
done

# Broker count in the footer, because the per-broker lines print above it and a sweep piped
# through `tail` silently drops them — a truncated view then reads as "fewer brokers exist".
echo "--- broker processes: $brokers · orphaned records: $orphans · running jobs: $live_jobs ---"
((APPLY)) || echo "dry-run — pass --apply to act"
exit $((FAILED ? 3 : 0))
