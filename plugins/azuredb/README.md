# Azure DB Sync

A Claude Code skill that copies an **Azure SQL database down to a local SQL
Server** — full schema + data — through a BACPAC export/import driven by
SqlPackage. Direction is **one-way: Azure → Local**. The local target database
is dropped and rebuilt, so it must not hold local-only data you care about.

## What you can ask

Once the plugin is installed, just ask Claude. The agent collects connection
details in chat, remembers them between runs, asks which authentication to use,
confirms the destructive drop, and runs the bundled script for you.

- *"Sync the azure db down to my local."*
- *"Pull prod data into my dev database."*
- *"Refresh my local database from Azure."*
- *"Copy the cloud DB locally."*
- *"Get the latest data from Azure into LocalDB."*

## How it works

1. **Load defaults** — reads the first `.db-sync/config.json` that exists, in
   order: current dir → git repo root → central `~/.db-sync/` (names only, no
   secrets), and offers to reuse a saved DB or sync a different one.
2. **Collect details** — Azure server, Azure database, local instance, local
   database, optional bacpac folder.
3. **Pick auth** — Entra ID interactive (browser sign-in + MFA) or SQL login
   (username + password). Asked every run; credentials are never stored.
4. **Confirm the drop** — the local target is dropped and rebuilt; the script
   refuses to drop without `-AcceptDrop`, so this gate is mandatory.
5. **Export + import** — SqlPackage exports Azure → `.bacpac`, then imports into
   the local instance in one non-interactive run.

## Requirements

- PowerShell 7+
- **SqlPackage** on `PATH` — `dotnet tool install -g microsoft.sqlpackage`
- **sqlcmd** on `PATH` (SQL Server Client SDK / ODBC tools) — used to drop the
  local DB
- A reachable local SQL Server instance (`.` default, or `(localdb)\MSSQLLocalDB`)
- Your client IP allowed in the Azure SQL server firewall (Azure portal → SQL
  server → Networking → Firewall rules), or export fails

## What gets stored

Connection **names only**, in a `.db-sync/config.json` file at one of three
locations (first existing wins, read in this order):

```text
<cwd>/.db-sync/config.json          # current directory
<repoRoot>/.db-sync/config.json     # current git repo root
~/.db-sync/config.json              # central fallback
```

Each file is a JSON **array** of saved DBs. Per entry: `Name` (a nickname),
`SourceServer`, `SourceDatabase`, `TargetInstance`, `TargetDatabase`,
`BacpacFolder`.

Not stored: usernames, passwords, tokens. That's why authentication is asked
every run.

> **Note:** with SQL-login auth the password is passed to SqlPackage as a
> command-line argument, so it is briefly visible to other processes on the
> machine (e.g. the process list) for the duration of the export. Prefer Entra ID
> interactive auth where possible.

## Install

This plugin is installed via the marketplace:

```
/plugin marketplace add Rashik004/rashik-skill-set
/plugin install azuredb@rashik-skills
```

Claude Code copies the plugin to its cache and exposes the path as
`$env:CLAUDE_PLUGIN_ROOT` while the plugin is active. The bundled script lives at:

```powershell
& "$env:CLAUDE_PLUGIN_ROOT/skills/sync-azure-db/scripts/Sync-AzureToLocal.ps1"
```

You normally never call it yourself — Claude runs it with the right parameters
once you trigger the skill.

## Script exit codes

| Exit | Meaning |
|---|---|
| `0` | Success — local DB now mirrors Azure; names saved to config |
| `1` | Export or import failed (often Azure firewall blocking your client IP) |
| `2` | Missing tool (SqlPackage / sqlcmd), bad arguments, or local instance unreachable |
| `3` | Local DB exists and would be dropped, but `-AcceptDrop` was not passed |

## Notes

- **Destructive on the local side only** — never writes to Azure. There is no
  Local → Azure direction; pushing local data up would overwrite production.
- The `.bacpac` is deleted after a successful import unless `-KeepBacpac` is set.

## Reference

- Skill instructions for Claude: [`SKILL.md`](./skills/sync-azure-db/SKILL.md)
