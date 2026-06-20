---
name: sync-azure-db
description: >-
  Sync (copy) an Azure SQL database down to a local SQL Server, schema + data,
  via a BACPAC export/import using SqlPackage. Use this whenever the user wants
  to refresh, pull, copy, mirror, or sync their cloud/Azure database into their
  local/dev database — phrases like "sync the azure db", "pull prod data down",
  "refresh my local database", "copy the cloud DB locally", or "get the latest
  data from Azure into LocalDB". You read a saved list of previously-synced DBs
  (from the current dir, the git repo root, or the central ~/.db-sync folder) and
  let the user pick one or enter a new one, always ask which authentication to
  use, then run the bundled script. One-way only: Azure overwrites local.
---

# Sync Azure SQL → Local

Copies an Azure SQL database to a local SQL Server as a full schema + data
refresh. Direction is **one-way: Azure → Local** — the local target database is
dropped and rebuilt, so it must not hold local-only data the user cares about.

**You (the agent) drive this.** Collect the details in chat, then call the
bundled script with everything as parameters — the script is non-interactive and
does the export + import in one run. Do NOT tell the user to run the script
themselves.

## Workflow

### 1. Resolve the saved-DB list and ask which one to sync

Saved DBs live in a **JSON array** in a `.db-sync/config.json` file. There are
three possible locations; use the **first that exists**, in this order:

1. current directory — `<cwd>\.db-sync\config.json`
2. current git repo root — `<repoRoot>\.db-sync\config.json`
3. central — `$env:USERPROFILE\.db-sync\config.json`

Run this snippet (PowerShell tool) to resolve and read the first existing file. It
prints the resolved path + raw JSON, or `none` plus the candidate paths (which
double as the save targets in step 2b):

```powershell
$cands = @()
$cwd = (Get-Location).Path
$cands += (Join-Path $cwd '.db-sync\config.json')
$root = (git rev-parse --show-toplevel 2>$null)
if ($root) { $r = (Join-Path ($root -replace '/','\') '.db-sync\config.json'); if ($r -ne $cands[0]) { $cands += $r } }
$cands += (Join-Path $env:USERPROFILE '.db-sync\config.json')
$hit = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($hit) { "RESOLVED: $hit"; Get-Content $hit -Raw } else { "RESOLVED: none"; "CANDIDATES: $($cands -join ' | ')" }
```

Each entry holds (no secrets): `Name` (a nickname), `SourceServer`,
`SourceDatabase`, `TargetInstance`, `TargetDatabase`, `BacpacFolder`. Parse the
output as an array; an old central file may be a **single object** — treat it as a
one-element array. An entry with no `Name` displays by its `SourceDatabase`.

- **No file found (`RESOLVED: none`)** → first run; skip to step 2 and ask for
  each value. Keep the candidate paths for step 2b.
- **File found** → present the saved DBs with **AskUserQuestion**, one option per
  entry labeled `Name (SourceDatabase -> TargetDatabase)`, plus a final
  **"Sync a new / different DB"** option.
  - **Picked a saved entry** → fill all five connection values from it and go
    straight to step 3 (auth). Do **not** re-ask them, and do **not** save again.
  - **"Sync a new / different DB"** → go to step 2, offering a picked entry's
    values as defaults if helpful.

### 2. Collect connection details in chat

Ask for these five, showing any remembered values as defaults:
- **Azure server** (e.g. `portfolio.database.windows.net`)
- **Azure database** (e.g. `portfolio-db`)
- **Local instance** — `.` for the default local SQL Server, or
  `(localdb)\MSSQLLocalDB` for LocalDB
- **Local database** — the target that will be dropped + rebuilt
- **Bacpac folder** — optional; the script defaults to `~/db-sync-bacpacs`

### 2b. Offer to save the new DB

Only on the new-DB path (you collected fresh values in step 2). Use
**AskUserQuestion**:

1. **Save this DB to the list?** (yes / no). If no, run step 5 with no save flags.
2. If yes, ask for a **nickname** (free text, e.g. `prod`, `staging`).
3. Ask **where** to save it. Offer the candidate locations from step 1, deduped:
   - **current dir** — `<cwd>\.db-sync\config.json`
   - **repo root** — `<repoRoot>\.db-sync\config.json` (only if in a git repo and
     different from the current dir)
   - **central** — `$env:USERPROFILE\.db-sync\config.json`

Carry the chosen path + nickname into step 5 as `-SaveConfig -ConfigPath <path>
-ConfigLabel <nickname>`. The script upserts the entry into that array **only after
a successful import**, so a failed sync saves nothing.

### 3. Always ask which authentication to use

Never assume — ask every run (use AskUserQuestion):
- **Entra ID interactive** → pass `-AuthMode interactive`. A browser window opens
  on the user's machine for sign-in + MFA. No credentials needed in chat.
- **SQL login** → ask for username and password, pass
  `-AuthMode password -SqlUser <u> -SqlPassword <p>`. Treat the password as
  sensitive: use it only in the script call, never echo it back, repeat it in
  prose, or write it to a file.

### 4. Confirm the destructive drop

The local target database is dropped and replaced. Confirm with the user before
running (AskUserQuestion or a clear y/n in chat). Only after they confirm, pass
`-AcceptDrop` to the script. The script REFUSES to drop an existing database
without `-AcceptDrop`, so this gate is mandatory.

### 5. Run the script

Call it via the PowerShell tool with all parameters, e.g.:

```powershell
& "$env:CLAUDE_PLUGIN_ROOT/skills/sync-azure-db/scripts/Sync-AzureToLocal.ps1" `
  -SourceServer "portfolio.database.windows.net" `
  -SourceDatabase "portfolio-db" `
  -TargetInstance "." `
  -TargetDatabase "StockDataScrapperNew" `
  -AuthMode interactive `
  -AcceptDrop `
  -SaveConfig -ConfigPath "F:\Personal\StockDataScrapper\.db-sync\config.json" -ConfigLabel "prod"
```

Pass the `-SaveConfig -ConfigPath -ConfigLabel` trio only when the user chose to
save a new DB in step 2b. Omit it when they reused a saved entry or declined —
without it the script writes no config. Add `-KeepBacpac` if the user wants the
`.bacpac` file kept (default: deleted after import). For password auth, add
`-AuthMode password -SqlUser ... -SqlPassword ...`.

Entra interactive opens a browser on the user's machine — tell them to expect
the sign-in popup. Export/import of a large DB is slow; that's not a hang.

### 6. Report the result

The script prints `SUCCESS:` and exits 0 on success (and, when `-SaveConfig` was
passed, upserts the names into the chosen `.db-sync/config.json`). Non-zero exits:
`1` = export/import failed (often the Azure firewall blocking the client IP —
point them to Azure portal → SQL server → Networking → Firewall rules),
`2` = missing tool/bad args/local instance unreachable, `3` = drop needed but `-AcceptDrop` was not passed.
Relay the outcome plainly, including where a new DB was saved.

### 6b. Offer to gitignore (repo-location saves only)

If a new DB was just saved at the current dir or repo root **inside a git repo**,
the `.db-sync/` folder may not be ignored. Check, then offer:

```powershell
git check-ignore .db-sync/ 2>$null
```

If that prints nothing (not ignored), ask the user (AskUserQuestion) whether to
add `.db-sync/` to the repo's `.gitignore`. Only on yes, append the line. Skip
this for central saves (they live outside any repo).

## Prerequisites

- **SqlPackage** on PATH — `dotnet tool install -g microsoft.sqlpackage`.
- **sqlcmd** on PATH (SQL Server Client SDK / ODBC tools) — used to drop the
  local DB.
- A reachable **local SQL Server instance** (`.` default, or LocalDB).
- The client IP allowed in the Azure SQL server firewall, or export fails.

## Notes

- **Destructive on the local side only** — never writes to Azure. Never offer a
  Local → Azure direction; pushing local data up would overwrite production.
- Config lives in a `.db-sync/config.json` file at one of three locations (current
  dir, git repo root, or central `~/.db-sync/`), read by first-existing precedence
  (step 1). Each file is a JSON **array** of saved DBs; an old central file may be a
  single object (still read, rewritten as an array on the next save). It holds only
  non-secret names — credentials are never stored, which is why auth is asked every
  run.
