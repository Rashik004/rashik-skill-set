# AzDevOps CLI

A Claude Code skill for working with Azure DevOps boards, pull requests, sprints, and wikis through natural-language prompts. Authentication is brokered by Azure CLI / Microsoft Entra — no PATs stored.

## What you can ask

Once the skill is loaded and you're connected, just ask Claude. No cmdlets to memorize.

### Work items / boards

- *"Find me all active bugs assigned to Rashik."*
- *"What's the status of card 42351?"*
- *"Show me every P0 feature in the fabrikam org."*
- *"List all user stories I have open."*
- *"What are the latest comments on bug 9182?"*

### Pull requests

- *"Check the current status of all PRs created by Jane."*
- *"Show me active PRs in the api repo."*
- *"Summarize reviewer feedback on PR 500."*
- *"What changed in `Startup.cs` in PR 987?"*
- *"Are there PRs waiting on my review?"*

### Sprint

- *"What's in the current sprint?"*
- *"Who's overloaded this sprint?"*
- *"Show me sprint status grouped by assignee."*
- *"What's blocking the sprint right now?"*

### Cross-org

- *"Find all my open items across every org."*
- *"Show me active bugs in every project I'm in."*

### Wiki

- *"Find me the wiki page that explains the codebase."*
- *"Search the wiki for deployment steps."*
- *"Show me the architecture overview wiki."*
- *"Update the runbook page with these new deploy steps."*
- *"List every wiki in this project."*

### Session / config

- *"Am I connected to Azure DevOps?"*
- *"Switch my default project to Backend."*
- *"Disconnect from ADO."*

### Multi-project note

If you have several projects configured, Claude will ask which one to use unless your prompt names it (*"...in fabrikam"*). To stop being asked, set a default:

```powershell
Set-AdoDefault -Org 'contoso' -Project 'Backend'
```

## Requirements

- PowerShell 7+
- Azure CLI installed and on `PATH`
- Access to one or more Azure DevOps Services organizations
- Work or school account that can sign in through Microsoft Entra

## What gets stored

Configuration only, at:

```text
~/.azdevops/config.json
```

Contents:

- configured organization names
- configured project names
- default org/project
- optional preferred tenant ID

Not stored:

- PATs
- access tokens
- refresh tokens
- passwords

## Install

From the repo root:

```powershell
Import-Module .\scripts\AzDevOps.psd1 -Force
```

## Configure

### Option 1 — interactive wizard

```powershell
.\scripts\Setup-AzDevOps.ps1
```

Asks for orgs, projects, defaults, optional tenant ID, and can call `Connect-Ado` at the end.

### Option 2 — manual

```powershell
Initialize-AdoConfig -Orgs @(
    @{ Name='contoso'; Projects=@('WebApp','Backend') },
    @{ Name='fabrikam'; Projects=@('MobileApp') }
) -DefaultOrg 'contoso' -DefaultProject 'WebApp'
```

Pin a tenant if needed:

```powershell
Initialize-AdoConfig -Orgs @(
    @{ Name='contoso'; Projects=@('WebApp','Backend') }
) -DefaultOrg 'contoso' -DefaultProject 'WebApp' -TenantId '00000000-0000-0000-0000-000000000000'
```

## Authenticate

Browser sign-in:

```powershell
Connect-Ado
```

Device code (no browser available):

```powershell
Connect-Ado -UseDeviceCode
```

Specific tenant:

```powershell
Connect-Ado -TenantId '00000000-0000-0000-0000-000000000000'
```

`Connect-Ado` reuses an existing Azure CLI login if there is one, otherwise calls `az login` for you.

## Verify

```powershell
Get-AdoOrgs
Get-AdoSession
Test-AdoConnection
```

Once those pass, switch back to talking to Claude.

## Under the hood

Claude maps every prompt to a PowerShell cmdlet from this module and pipes the JSON result back into context. You almost never need to type the cmdlet yourself, but the mapping looks like this:

| Prompt | Cmdlet Claude runs |
|---|---|
| *"Active bugs assigned to Rashik"* | `Get-AdoWorkItems -Type Bug -State Active -AssignedTo 'rashik@...'` |
| *"Status of card 42351"* | `Get-AdoWorkItem -Id 42351` |
| *"PRs created by Jane"* | `Get-AdoPullRequests -CreatedBy 'Jane'` |
| *"Search wiki for deployment steps"* | `Search-AdoWiki -Query 'deployment steps'` |

Full cmdlet list and parameters: see [`SKILL.md`](./SKILL.md) and [`references/FUNCTIONS.md`](./references/FUNCTIONS.md).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `NotConnected` | Run `Connect-Ado` |
| `ReauthRequired` | Run `Connect-Ado` again |
| `ConfigNotFound` | Run `Initialize-AdoConfig` to create `~/.azdevops/config.json` |
| `NoDefaultOrg` / `NoDefaultProject` | Run `Set-AdoDefault -Org X -Project Y` or pass `-Org`/`-Project` per call |
| `OrganizationNotFound` | Check `Get-AdoOrgs` — name must match exactly |
| `ProjectNotFound` | Project not configured under that org; add it to config or fix the name |
| `AzureCliNotFound` | Install Azure CLI and ensure `az` is on `PATH` (`az --version`) |
| `AzureCliLoginFailed` | Run `az login` manually, then `Connect-Ado` again |
| `AzureCliTokenFailed` / `AzureCliAccountUnavailable` | Run `Connect-Ado` again; if still failing, `az logout` then `az login` |
| `ApiRequestFailed` | Check network and that your work account has access to the org/project |
| `WikiNotFound` | No wikis exist in the project, or pass `-Wiki` with the correct name |
| Wiki page 409 conflict | Page changed externally — retry the update |
| Validation fails after login | Confirm signed-in account, tenant, org name, and Azure DevOps access |

## Notes

- Targets **Azure DevOps Services**, not Azure DevOps Server / on-prem.
- Legacy configs with PAT fields are tolerated, but PATs are ignored and stripped on rewrite.
- `Disconnect-Ado` clears the in-memory module session only — it does not call `az logout`.

## Reference

- Skill instructions for Claude: [`SKILL.md`](./SKILL.md)
- Cmdlet parameter reference: [`references/FUNCTIONS.md`](./references/FUNCTIONS.md)
