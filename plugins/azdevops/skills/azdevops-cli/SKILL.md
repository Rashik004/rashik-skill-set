---
name: azdevops-cli
description: >
  PowerShell module for querying Azure DevOps boards, PRs, sprints, and wikis via the
  REST API. Supports multiple organizations and projects under a single identity and uses
  session-scoped Microsoft Entra interactive login via Azure CLI instead of stored PATs.
  All output is structured JSON for piping to AI providers from the CLI.

  Use this skill whenever the user mentions Azure DevOps, ADO boards, work items, sprints,
  pull requests, wiki pages, WIQL queries, or DevOps backlog management from PowerShell
  or the terminal. Also trigger when the user wants to query bugs, user stories, features,
  tasks, or epics from their DevOps board, check PR review comments or code diffs, see who
  is assigned what in a sprint, read or search wiki documentation, create or update wiki
  pages, or pipe DevOps data to an AI tool like Claude, GPT, or Gemini from the CLI.
  Even if the user just says "check my board", "what PRs are open", "sprint status",
  "what's assigned to me in ADO", "DevOps bugs", "find in wiki", "read the wiki page",
  or "update wiki" - use this skill.
---

# AzDevOps CLI Skill

A PowerShell 7+ module that wraps the Azure DevOps REST API v7.0 for multi-org,
multi-project access. Every function emits structured JSON to stdout so any AI
provider can consume it from the command line.

## When to use this skill

- User wants to query Azure DevOps work items (bugs, stories, features, tasks, epics)
- User wants to read comments/discussion on a board card
- User wants to check active pull requests, code changes, review threads
- User wants current sprint status or per-user workload breakdown
- User wants to search across multiple ADO organizations at once
- User wants to read, search, create, update, or delete wiki pages
- User wants to browse wiki page hierarchy (table of contents)
- User wants to pipe DevOps data into an AI CLI tool

## Multi-project disambiguation

When the user has multiple projects configured (check via `Get-AdoOrgs`), project-specific
requests require knowing which project to target. If the user does not mention a specific
project in their request, you **must ask them which project they mean** before running the
command — do not silently fall back to the default project.

**Project-specific operations** (require disambiguation):
- Work items: `Get-AdoWorkItem`, `Get-AdoWorkItems`, `Get-AdoWorkItemComments`
- Pull requests: `Get-AdoPullRequests`, `Get-AdoPullRequestDetail`, `Get-AdoPullRequestDiff`
- Sprints: `Get-AdoCurrentSprint`, `Get-AdoSprintAssignments`
- User items: `Get-AdoUserWorkItems`
- Wiki: `Get-AdoWikiList`, `Get-AdoWikiPage`, `Get-AdoWikiPageTree`, `Set-AdoWikiPage`,
  `Remove-AdoWikiPage`, `Search-AdoWiki`

**Non-project-specific operations** (skip disambiguation):
- Config/session: `Initialize-AdoConfig`, `Get-AdoOrgs`, `Set-AdoDefault`, `Connect-Ado`,
  `Disconnect-Ado`, `Get-AdoSession`, `Test-AdoConnection`
- Cross-org: `Search-AdoAllOrgs` (searches all orgs/projects by design)

**How to disambiguate:**
1. At the start of the skill, run `Get-AdoOrgs` to check configured projects.
2. If only one project is configured across all orgs, write it down and proceed with it — no need to ask.
3. If multiple projects exist and the user's request clearly names one (e.g., "check PRs
   in ilap.flow"), use that project via the `-Project` parameter.
4. If multiple projects exist and the request is ambiguous, ask the user:
   *"You have multiple projects configured: [list projects]. Which project should I use?"*
5. Once the user specifies a project, pass it via `-Project` on the relevant commands.
6. If the user wants to stop being asked, suggest `Set-AdoDefault -Org <name> -Project <name>` to update the configured default.

## Architecture overview

```text
~/.azdevops/config.json        <- stores orgs, projects, defaults, tenant preference
AzDevOps.psm1 / .psd1          <- the PowerShell module
Setup-AzDevOps.ps1             <- interactive first-run wizard
```

**Multi-org model**: One work account can belong to many Azure DevOps organizations. The
config file stores orgs, projects, and defaults only. Authentication is handled through
Azure CLI-backed Microsoft Entra sign-in for the current PowerShell session.

## Requirements

- PowerShell 7.0+ (Core, not Windows PowerShell 5.1)
- Azure DevOps Services with a work or school account
- Azure CLI available on `PATH`

## Setup

### Step 1 - Install the module

The PowerShell module ships inside this plugin. Import it using the
`$env:CLAUDE_PLUGIN_ROOT` env var that Claude Code sets when the plugin is active:

```powershell
Import-Module "$env:CLAUDE_PLUGIN_ROOT/skills/azdevops-cli/scripts/AzDevOps.psd1" -Force
```

Or run the interactive wizard:

```powershell
& "$env:CLAUDE_PLUGIN_ROOT/skills/azdevops-cli/scripts/Setup-AzDevOps.ps1"
```

### Step 2 - Initialize config

```powershell
Initialize-AdoConfig -Orgs @(
    @{ Name='contoso'; Projects=@('WebApp','Backend') },
    @{ Name='fabrikam'; Projects=@('Mobile') }
) -DefaultOrg 'contoso' -DefaultProject 'WebApp'
```

Optional tenant preference:

```powershell
Initialize-AdoConfig -Orgs @(
    @{ Name='contoso'; Projects=@('WebApp','Backend') }
) -DefaultOrg 'contoso' -DefaultProject 'WebApp' -TenantId '00000000-0000-0000-0000-000000000000'
```

### Step 3 - Connect for this session

```powershell
Connect-Ado
```

If browser sign-in is unavailable:

```powershell
Connect-Ado -UseDeviceCode
```

Check session status:

```powershell
Get-AdoSession
Test-AdoConnection
```

### Azure CLI note

The module uses Azure CLI as the Microsoft Entra login broker. If you are not already
signed in, `Connect-Ado` will call `az login` for you. Device code fallback is available
with `Connect-Ado -UseDeviceCode`.

```powershell
az login
az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798
```

## Function reference

Read `references/FUNCTIONS.md` for the complete parameter reference with examples for the
exported functions. Quick reference:

| Function | What it does |
|---|---|
| `Initialize-AdoConfig` | Set up orgs, projects, defaults, tenant preference |
| `Get-AdoOrgs` | List configured orgs and projects |
| `Set-AdoDefault` | Change default org/project |
| `Connect-Ado` | Start or reuse an Azure CLI-backed Microsoft Entra session |
| `Disconnect-Ado` | Clear the in-memory session |
| `Get-AdoSession` | Show current auth/session state |
| `Test-AdoConnection` | Validate the current session against a configured org |
| `Get-AdoWorkItem -Id N` | Single work item with full detail |
| `Get-AdoWorkItems -Type Bug -State Active` | Query by type, state, assignee, or WIQL |
| `Get-AdoWorkItemComments -Id N` | All comments on a card (HTML stripped) |
| `Get-AdoPullRequests` | List PRs by status, repo, or creator |
| `Get-AdoPullRequestDetail -RepoName R -PrId N` | PR threads, iterations, file changes, linked cards |
| `Get-AdoPullRequestDiff -RepoName R -PrId N -FilePath F` | Source vs target code for a file in a PR |
| `Get-AdoCurrentSprint` | Active sprint with all work items |
| `Get-AdoUserWorkItems -User U` | All active items for a person |
| `Get-AdoSprintAssignments` | Sprint cards grouped by assignee |
| `Search-AdoAllOrgs` | Fan same query across every org/project |
| `Get-AdoWikiList` | List all wikis in the project |
| `Get-AdoWikiPage -Path P` | Fetch a wiki page with content |
| `Get-AdoWikiPageTree` | Page hierarchy (table of contents) |
| `Set-AdoWikiPage -Path P -Content C` | Create or update a wiki page |
| `Remove-AdoWikiPage -Path P` | Delete a wiki page |
| `Search-AdoWiki -Query Q` | Full-text search across wiki pages |

## AI piping pattern

Every data function outputs JSON. Pipe to any AI CLI:

```powershell
Get-AdoCurrentSprint | claude "Summarize this sprint. Who is overloaded?"
Get-AdoPullRequestDetail -RepoName api -PrId 123 | openai "Review this PR"
Search-AdoAllOrgs -Type Bug -State Active | your-ai "Prioritize these"
```

## JSON output structure

All data responses follow a consistent envelope:

```json
{
  "context": { "org": "contoso", "project": "WebApp" },
  "count": 5,
  "items": [ ... ]
}
```

`context` may include function-specific fields like `wiql`, `team`, `iteration`, `repo`, `prId`.

Errors also return JSON:

```json
{
  "error": true,
  "code": "NotConnected",
  "message": "No active Azure DevOps session. Run Connect-Ado.",
  "hint": "Use Connect-Ado -UseDeviceCode if browser sign-in is unavailable."
}
```

## Common workflows

**"What's blocking the sprint?"**

```powershell
Connect-Ado
Get-AdoCurrentSprint | claude "List blockers and risks from this sprint data"
```

**"Summarize PR feedback"**

```powershell
Connect-Ado
Get-AdoPullRequestDetail -RepoName api -PrId 500 | claude "Summarize reviewer comments"
```

**"Who has too much on their plate?"**

```powershell
Connect-Ado
Get-AdoSprintAssignments | claude "Flag anyone with >15 story points"
```

**"Find my open items everywhere"**

```powershell
Connect-Ado
Search-AdoAllOrgs -AssignedTo 'me@co.com' | claude "Group by priority"
```

**"Find deployment docs in the wiki"**

```powershell
Connect-Ado
Search-AdoWiki -Query 'deployment steps'
```

**"Read a specific wiki page"**

```powershell
Connect-Ado
Get-AdoWikiPage -Path '/Architecture/Overview' | claude "Summarize this page"
```

**"Browse wiki table of contents"**

```powershell
Connect-Ado
Get-AdoWikiPageTree -Depth oneLevel
```

**"Update a wiki page"**

```powershell
Connect-Ado
Set-AdoWikiPage -Path '/Runbook/Deploy' -Content $newContent -Comment 'Updated deploy steps'
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `NotConnected` | Run `Connect-Ado` |
| `ReauthRequired` | Run `Connect-Ado` again |
| `ConfigNotFound` | Run `Initialize-AdoConfig` to create `~/.azdevops/config.json` |
| `NoDefaultOrg` / `NoDefaultProject` | Run `Set-AdoDefault -Org X -Project Y` or pass `-Org`/`-Project` per call |
| `OrganizationNotFound` | Check `Get-AdoOrgs` - name must match exactly |
| `ProjectNotFound` | Project not configured under that org; add it to config or fix the name |
| `AzureCliNotFound` | Install Azure CLI and make sure `az` is on `PATH` |
| `AzureCliLoginFailed` | Run `az login` manually, then try `Connect-Ado` again |
| `AzureCliTokenFailed` / `AzureCliAccountUnavailable` | Run `Connect-Ado` again; if it still fails, run `az logout` then `az login` |
| `ApiRequestFailed` | Check network and that your work account has access to the org/project |
| Empty sprint results | Verify team name with `-Team 'Exact Team Name'` |
| Validation fails after login | Confirm your signed-in work account can access the configured org |
| `WikiNotFound` | No wikis exist in the project, or specify `-Wiki` with the correct name |
| Wiki page 409 conflict | Page was modified externally; retry the `Set-AdoWikiPage` call |
