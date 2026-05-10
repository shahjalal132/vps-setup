# rclone — install and configure (Google Drive and basics)

This document explains how to install **rclone**, create a **remote** (cloud backend), and verify it — so scripts like `backup_script.sh` can upload backups reliably.

---

## What rclone is

**rclone** is a command-line tool to sync files and directories to and from cloud storage (Google Drive, Dropbox, S3, Backblaze B2, etc.). It handles OAuth, retries, and large transfers better than ad-hoc `curl` scripts.

---

## 1. Install rclone (Linux — Debian / Ubuntu)

### Option A — package manager (simplest)

```bash
sudo apt update
sudo apt install -y rclone
rclone version
```

### Option B — upstream install script (newer version)

Use when you need a feature or fix not yet in your distro package:

```bash
curl -fsSL https://rclone.org/install.sh | sudo bash
rclone version
```

> **Note:** Inspect any `curl | bash` script in your environment before running it in production.

---

## 2. First-time configuration (`rclone config`)

Interactive wizard — run as the **same Linux user** that will run backups (e.g. `root` if cron runs as root, or `www-data` — not recommended unless you tighten permissions).

```bash
rclone config
```

Typical flow to add **Google Drive**:

1. Choose **`n`** — New remote.
2. **name** — e.g. `google_drive` (must match `REMOTE_NAME` in `backup_script.sh`).
3. **Storage** — type `drive` or pick the number for **Google Drive**.
4. **client_id / client_secret** — press **Enter** to use rclone’s default OAuth app, *or* create your own in [Google Cloud Console](https://console.cloud.google.com/) (APIs & Services → Credentials → OAuth 2.0 Client ID → Desktop) if you hit rate limits or policy limits.
5. **scope** — for full Drive access often **`1`** (full access); for a folder-limited app, follow rclone’s scoped-drive docs.
6. **Service Account** — usually **no** for personal Drive; **yes** for Google Workspace shared drives with a JSON key (advanced).
7. **Edit advanced config** — usually **no** until you need chunk size, team drive ID, etc.
8. **Use auto config?**
   - **On a machine with a browser:** **`y`** — rclone opens a browser to sign in with your Google account.
   - **On a headless server:** **`n`** — rclone prints a URL; open it on **another** computer, sign in, paste the verification code back into the terminal.

When finished, **`q`** quits the config menu.

### List remotes

```bash
rclone listremotes
```

You should see something like:

```text
google_drive:
```

The trailing colon is how rclone spells a remote in commands (`google_drive:path`).

---

## 3. Verify access

List the root of Drive (or the first level the token can see):

```bash
rclone lsd google_drive:
```

List a specific folder you will use for backups (create an empty folder in the Drive UI first, or let the first `copy` create path segments the API allows):

```bash
rclone lsd "google_drive:Site_Backups"
```

Upload a tiny test file:

```bash
echo test | rclone rcat "google_drive:Site_Backups/rclone-smoke-test.txt"
rclone cat "google_drive:Site_Backups/rclone-smoke-test.txt"
rclone delete "google_drive:Site_Backups/rclone-smoke-test.txt"
```

If these work, **`backup_script.sh`** can use the same `REMOTE_NAME` and `REMOTE_FOLDER` values.

---

## 4. Match `backup_script.sh` settings

In `backup_script.sh`:

| Variable        | Meaning |
|----------------|---------|
| `REMOTE_NAME`  | Name from `rclone config` (no colon in the variable). |
| `REMOTE_FOLDER`| Top-level folder name on that remote (e.g. `Site_Backups`). |

Example command the script relies on:

```bash
rclone copy /path/to/local.zip "google_drive:Site_Backups"
```

And for retention cleanup:

```bash
rclone delete "google_drive:Site_Backups" --min-age 5d
```

> **`rclone delete`** removes objects **under** that path older than `--min-age`. Ensure `REMOTE_FOLDER` is **only** backup zips you are willing to prune, or use a dedicated subfolder per site.

---

## 5. Optional: config file location and permissions

- User config: `~/.config/rclone/rclone.conf`
- Restrict access (contains tokens):

```bash
chmod 600 ~/.config/rclone/rclone.conf
```

If backups run as **root**, configure rclone **as root** (`sudo rclone config`) so `root` owns `rclone.conf`.

---

## 6. Optional: bandwidth and stability

Add global or per-command flags if uploads saturate the link:

```bash
rclone copy /data/big.zip "google_drive:Site_Backups" \
  --transfers 1 \
  --checkers 2 \
  --bwlimit 8M
```

Useful flags (see `rclone copy --help`):

- `--dry-run` — log what would happen without uploading.
- `-P` / `--progress` — progress in the terminal.
- `--log-file /var/log/rclone.log` — persistent logging for cron jobs.

---

## 7. Running from cron

Example: daily at 02:15 as root (adjust path and user):

```cron
15 2 * * * /usr/local/bin/backup_script.sh >> /var/log/backup_script.log 2>&1
```

Use the **full path** to `rclone` if cron’s `PATH` is minimal:

```bash
which rclone
```

If the script sources secrets, use a wrapper:

```cron
15 2 * * * . /root/.backup-env.sh && /root/bin/backup_script.sh >> /var/log/backup_script.log 2>&1
```

---

## 8. Troubleshooting

| Symptom | What to check |
|--------|----------------|
| `Failed to configure token` | Clock skew (`ntp`), firewall, headless OAuth done on another machine with correct URL. |
| `403` / `rateLimitExceeded` | Too many API calls; reduce parallelism; consider your own OAuth client ID. |
| `insufficientFilePermissions` | Shared drive / folder permissions; service account not added as folder editor. |
| `disk full` on server | `BACKUP_DIR` needs free space ≥ site size + zip overhead before upload. |
| Cron works manually but not in cron | `PATH`, full path to `rclone`, permissions on `SOURCE_DIR` and `rclone.conf`. |

Verbose debug:

```bash
rclone copy /tmp/test.zip "google_drive:Site_Backups" -vv
```

---

## 9. Further reading

- Official docs: [https://rclone.org/docs/](https://rclone.org/docs/)
- Google Drive backend: [https://rclone.org/drive/](https://rclone.org/drive/)
- `rclone config` reference: [https://rclone.org/commands/rclone_config/](https://rclone.org/commands/rclone_config/)

After rclone is installed and `google_drive:Site_Backups` (or your chosen names) tests clean, you can rely on `backup_script.sh` for scheduled uploads.
