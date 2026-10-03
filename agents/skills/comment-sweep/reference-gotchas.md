# Comment sweep gotchas

Read this when a sweep edits a heredoc patch script or a comment inside a quoted `awk` or `sed` program.

## Hook and quoting traps

A `python3 - <<'PY'` heredoc containing the word "Truncate" trips the safe-bash hook's
SQL `TRUNCATE` rule. Use the Edit tool for those files.

**Punctuation inside a quoted program.** A comment living inside a single-quoted `awk` or
`sed` program is shell text, not comment text. Adding an apostrophe to it terminates the
quote and breaks the script — `file's` did exactly that to `check-sops-encrypted.sh` on
2026-08-07, and only the CI gate caught it. Rephrase to avoid the apostrophe rather than
escaping it.

## Why a regex cannot judge a comment

A regex cannot tell `// Rate limit on first item only`
(a policy statement — keep) from `// Create streaming state` (noise — cut); both overlap
their next line's identifiers.

## Incidents and measurements

### Procedure step 6

Three
separate passes were needed on 2026-08-07 (code comments, then Markdown, then sentence
length), each finding breaches of the bar the sweep had just applied to everyone else.

### Procedure step 7

One `tokei` invocation shipped next to a line count it did
not produce — the flags were close enough to look right and off by a whole directory.

### Pod-template comments

Five apps rolled off one
comment sweep on 2026-08-07. Comments in a ConfigMap payload or a CronJob template cost nothing; they apply on
the next run.

### Hand-rolled alert check

A one-off `wget` inside the VMSingle pod returns nothing when it fails, `jq` exits 0 on the
empty input, and the sweep looks like it fired no alerts. Measured 2026-08-07: the one-off
reported clean while four alerts were firing.
