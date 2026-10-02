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
