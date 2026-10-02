# OIDC client secrets (run 2026-10-02)

Authentik is the provider for 9 clients. The provider PKs, the files and the per-app notes are in
`docs/SECRETS_ROTATION.md` § 4; confirm the PKs against the API before writing anything.

| Step | How it was done |
|---|---|
| Map | In the authentik-server pod (no curl/wget; Python with `AUTHENTIK_BOOTSTRAP_TOKEN` from the pod env, PK on stdin), GET `/api/v3/providers/oauth2/<pk>/` for name and `client_secret`, saved to a chmod-700 temp dir. Search every SOPS file for that value: 6 PKs had one copy each (some inside JSON/YAML/DSN values), Immich, Audiobookshelf and Cloudflare Access had none |
| Write | One new 64-hex value per PK, replaced in each copy only if the old value occurs exactly once; `sops-changed-keys.sh`; one commit, merge, `fr` (apps + monitoring-configs for Grafana) |
| Switch | Per app: PATCH the provider (PK and secret on stdin, expect 200), then cycle the app at once. SSO for an app fails from the PATCH until its restart. If an app pod restarts between the deploy and its PATCH, it starts with NEW while Authentik still holds OLD, so keep that interval short, or deploy and switch one app at a time |
| Immich | `system_metadata` row `system-config`, `value->'oauth'->>'clientSecret'`: `UPDATE ... jsonb_set(...) WHERE ... clientSecret = '<old>'` on stdin via `pg-primary.sh exec immich -`; require `UPDATE 1` and re-read the row before the PATCH (0 rows means the guard did not match, and the PATCH would strand Immich on OLD); restart immich-server |
| Audiobookshelf | `/config/absdatabase.sqlite` row `server-settings`, field `authOpenIDClientSecret`; no sqlite3 binary, so `node -e` from `/app` with the app's `sqlite3` module, guarded on the old value; require 1 changed row before the PATCH; restart; re-read the row after the restart |
| Cloudflare Access | An agent must not type or paste a secret into a web form. The agent puts the new value on the clipboard with `pbcopy`, opens the IdP edit form (`dash.cloudflare.com/<account>/one/integrations/identity-providers`) and **empties the Client secret field**; the operator pastes and saves; the agent PATCHes provider 50; the operator clicks **Test** (needs the passkey). A paste into the unemptied field produced `Invalid client secret` in the authentik-server log |
| Clean up | Empty the clipboard and delete the temp dir once every side holds the new value |

Rotate the Authentik secret key before this batch, not during it: the key change ends every
Authentik session, and the operator's passkey login is then needed for the Cloudflare **Test**.
