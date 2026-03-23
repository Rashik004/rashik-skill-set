# AzDevOps Function Reference

Complete parameter reference for the exported functions. Data functions accept optional
`-Org` and `-Project` parameters to override the configured defaults.

---

## Config And Session

These commands use Azure CLI as the Microsoft Entra auth broker. Make sure `az` is
installed and available on `PATH`.

### Initialize-AdoConfig

Bootstrap the configuration file at `~/.azdevops/config.json`.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `-Orgs` | `hashtable[]` | Yes | Array of org definitions (see below) |
| `-DefaultOrg` | `string` | Yes | Org name used when `-Org` is omitted |
| `-DefaultProject` | `string` | Yes | Project name used when `-Project` is omitted |
| `-TenantId` | `string` | No | Preferred tenant for `Connect-Ado` |

Each hashtable in `-Orgs` has two keys:

| Key | Type | Description |
|---|---|---|
| `Name` | `string` | Organization name (the slug in `dev.azure.com/{name}`) |
| `Projects` | `string[]` | Project names you want to query in this org |

```powershell
Initialize-AdoConfig -Orgs @(
    @{ Name='contoso'; Projects=@('WebApp','Backend','Infra') },
    @{ Name='fabrikam'; Projects=@('MobileApp') }
) -DefaultOrg 'contoso' -DefaultProject 'WebApp'
```

### Get-AdoOrgs

List all configured organizations, projects, and basic auth state.

```powershell
Get-AdoOrgs
```

### Set-AdoDefault

Change the default org and/or project without rewriting the whole config.

| Parameter | Type | Required |
|---|---|---|
| `-Org` | `string` | No |
| `-Project` | `string` | No |

```powershell
Set-AdoDefault -Org 'fabrikam' -Project 'MobileApp'
```

### Connect-Ado

Start or reuse an Azure CLI-backed Microsoft Entra session for the current PowerShell session.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `-TenantId` | `string` | No | Override the configured tenant preference |
| `-UseDeviceCode` | `switch` | No | Use `az login --use-device-code` instead of browser sign-in |

```powershell
Connect-Ado
Connect-Ado -UseDeviceCode
Connect-Ado -TenantId '00000000-0000-0000-0000-000000000000'
```

### Disconnect-Ado

Clear the current in-memory Azure DevOps session.

```powershell
Disconnect-Ado
```

### Get-AdoSession

Show the current session state.

```powershell
Get-AdoSession
```

### Test-AdoConnection

Validate the current session against a configured org.

| Parameter | Type | Required |
|---|---|---|
| `-Org` | `string` | No |

```powershell
Test-AdoConnection
Test-AdoConnection -Org 'contoso'
```

---

## Work Items

### Get-AdoWorkItem

Fetch a single work item by ID with full field expansion and relations.

| Parameter | Type | Required |
|---|---|---|
| `-Id` | `int` | Yes |

```powershell
Get-AdoWorkItem -Id 42351
Get-AdoWorkItem -Id 42351 -Org fabrikam -Project MobileApp
```

### Get-AdoWorkItems

Query multiple work items by type, state, assignee, or raw WIQL.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `-Type` | `string` | No | `Bug`, `User Story`, `Feature`, `Task`, `Epic` |
| `-State` | `string` | No | Common values include `Active`, `New`, `Resolved`, `Closed` |
| `-AssignedTo` | `string` | No | Display name or email |
| `-Wiql` | `string` | No | Raw WIQL - overrides Type/State/AssignedTo |
| `-Top` | `int` | No | Max results (default 50) |

```powershell
Get-AdoWorkItems -Type Bug -State Active
Get-AdoWorkItems -Type 'User Story' -Org fabrikam -Project MobileApp
Get-AdoWorkItems -Type Feature -AssignedTo 'jane@contoso.com'
Get-AdoWorkItems -Wiql "SELECT [System.Id] FROM WorkItems WHERE [System.Tags] CONTAINS 'P0'"
```

### Get-AdoWorkItemComments

Fetch all comments on a work item. HTML is stripped for AI readability.

| Parameter | Type | Required |
|---|---|---|
| `-Id` | `int` | Yes |

```powershell
Get-AdoWorkItemComments -Id 42351
```

---

## Pull Requests

### Get-AdoPullRequests

List pull requests, optionally filtered.

| Parameter | Type | Required | Default |
|---|---|---|---|
| `-RepoName` | `string` | No | All repos |
| `-CreatedBy` | `string` | No | All authors |
| `-Status` | `string` | No | `active` |
| `-Top` | `int` | No | 30 |

Valid `-Status` values: `active`, `completed`, `abandoned`, `all`.

```powershell
Get-AdoPullRequests
Get-AdoPullRequests -RepoName 'my-api' -Status active
Get-AdoPullRequests -CreatedBy 'Jane'
```

### Get-AdoPullRequestDetail

Full detail for a single PR including threads, iterations, file changes, and linked work items.

| Parameter | Type | Required |
|---|---|---|
| `-RepoName` | `string` | Yes |
| `-PrId` | `int` | Yes |

```powershell
Get-AdoPullRequestDetail -RepoName 'my-api' -PrId 987
```

### Get-AdoPullRequestDiff

Get the source and target file content for a specific file in a PR.

| Parameter | Type | Required |
|---|---|---|
| `-RepoName` | `string` | Yes |
| `-PrId` | `int` | Yes |
| `-FilePath` | `string` | Yes |

```powershell
Get-AdoPullRequestDiff -RepoName 'my-api' -PrId 987 -FilePath '/src/Api/Startup.cs'
```

---

## Sprints

### Get-AdoCurrentSprint

Get the current (active) sprint iteration and all its work items.

| Parameter | Type | Required | Default |
|---|---|---|---|
| `-Team` | `string` | No | `{Project} Team` |

```powershell
Get-AdoCurrentSprint
Get-AdoCurrentSprint -Team 'Backend Team' -Org contoso -Project WebApp
```

---

## User And Assignment Queries

### Get-AdoUserWorkItems

All active (non-closed/removed/done) work items assigned to a specific user.

| Parameter | Type | Required |
|---|---|---|
| `-User` | `string` | Yes |

```powershell
Get-AdoUserWorkItems -User 'jane@contoso.com'
Get-AdoUserWorkItems -User 'Jane Doe' -Org fabrikam -Project MobileApp
```

### Get-AdoSprintAssignments

Current sprint cards pivoted by assignee.

| Parameter | Type | Required |
|---|---|---|
| `-Team` | `string` | No |

```powershell
Get-AdoSprintAssignments
Get-AdoSprintAssignments -Team 'Frontend Team'
```

---

## Cross-Org Search

### Search-AdoAllOrgs

Run the same query across every configured organization and project.

| Parameter | Type | Required |
|---|---|---|
| `-Type` | `string` | No |
| `-State` | `string` | No |
| `-AssignedTo` | `string` | No |
| `-Top` | `int` | No (default 20) |

```powershell
Search-AdoAllOrgs -Type Bug -State Active
Search-AdoAllOrgs -AssignedTo 'me@company.com'
```
