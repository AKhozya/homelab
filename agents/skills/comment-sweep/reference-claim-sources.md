# Claim sources

Read this before you write a comment that asserts a fact, to find the check that settles it.

### Example claims and how to check them

- "this is the only writer of X" → `rg` for every writer.
- "callers always pass converted HTML" → read every call site.
- "50MB is Telegram's ceiling" → check. (It is not; the Bot API download limit is 20MB.
  This exact claim was caught mid-sweep on 2026-07-29.)
- "entries before vX had no field" → `git log -S` for when the field landed, or drop the
  version and state the guard's purpose.

### Where to check, by claim type

Nearly every claim has an authority on this machine. Reach for it before weakening the
statement — a whole sweep's worth of "unverifiable" items resolved this way on 2026-08-07.

| Claim | Authority |
|---|---|
| A platform or API limit | the installed types' docstrings, not the vendor's website — `@grammyjs/types` carries the Bot API's own wording, and a test can gate the constant against it |
| An SDK symbol or behaviour | `sdk.d.ts` for the surface **and** `sdk.mjs` for use. A table the SDK exports but never reads means the choice belongs to the consumer — that finding rewrote a comment that had asserted CLI behaviour |
| Strings a compiled CLI prints | `grep` the shipped binary. It shows which messages are terminal and which are notices; it does **not** show control flow, so do not upgrade the claim to "never thrown" |
| A cited `node_modules` line | open it. All four in one repo were still exact, so these earn their keep |
| A commit SHA in a comment | `git cat-file -t`, then read the subject and confirm it matches the claim it supports |
| An in-repo `file.ts:NN` | assume it has rotted. A reformat moved one call three lines and no test noticed |
| A deployment or infra coupling | the sibling repo checkout (deployment manifests, the chezmoi source), never memory |
| A vendored pin (tag, revision, checksum) | the vendor's API. A tag can move; a published checksum settles it |
