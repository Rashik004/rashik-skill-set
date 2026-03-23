# AzDevOps CLI

PowerShell module for querying Azure DevOps boards, pull requests, and sprint data from the terminal.

This version uses **Azure CLI-backed Microsoft Entra login** for authentication. It does **not** store PATs in the skill config.

## Requirements

- PowerShell 7+
- Azure CLI installed and available on `PATH`
- Access to one or more Azure DevOps Services organizations
- A work or school account that can sign in through Microsoft Entra

## What Gets Stored

The skill stores only configuration in:

```text
~/.azdevops/config.json
```

That file contains:

- configured organization names
- configured project names
- default org/project
- optional preferred tenant ID

It does **not** store:

- PATs
- access tokens
- refresh tokens
- passwords

## Install

From the repo root:

```powershell
Import-Module .\scripts\AzDevOps.psd1 -Force
```

You can also run the interactive setup wizard:

```powershell
.\scripts\Setup-AzDevOps.ps1
```

## Configure

### Option 1: Interactive setup

Run:

```powershell
.\scripts\Setup-AzDevOps.ps1
```

The wizard will ask for:

- organization names
- project names for each org
- default organization
- default project
- optional tenant ID

At the end, it can also start sign-in for you by calling `Connect-Ado`.

### Option 2: Manual setup

Import the module and create config yourself:

```powershell
Import-Module .\scripts\AzDevOps.psd1 -Force

Initialize-AdoConfig -Orgs @(
    @{ Name='contoso'; Projects=@('WebApp','Backend') },
    @{ Name='fabrikam'; Projects=@('MobileApp') }
) -DefaultOrg 'contoso' -DefaultProject 'WebApp'
```

If you want to prefer a specific tenant:

```powershell
Initialize-AdoConfig -Orgs @(
    @{ Name='contoso'; Projects=@('WebApp','Backend') }
) -DefaultOrg 'contoso' -DefaultProject 'WebApp' -TenantId '00000000-0000-0000-0000-000000000000'
```

## Authenticate

### Normal interactive sign-in

```powershell
Connect-Ado
```

Behavior:

- reuses an existing Azure CLI login if one is already available
- otherwise runs `az login`
- fetches an Azure DevOps access token through Azure CLI
- validates access against your default org when possible

### Device code sign-in

If browser-based sign-in is unavailable:

```powershell
Connect-Ado -UseDeviceCode
```

This uses:

```powershell
az login --use-device-code
```

### Tenant-specific sign-in

```powershell
Connect-Ado -TenantId '00000000-0000-0000-0000-000000000000'
```

## Verify The Setup

Run these after configuring:

```powershell
Get-AdoOrgs
Get-AdoSession
Test-AdoConnection
```

You should then be able to run normal queries such as:

```powershell
Get-AdoCurrentSprint
Get-AdoWorkItems -Type Bug -State Active
Get-AdoPullRequests
```

## Common Usage

```powershell
Get-AdoCurrentSprint | claude "Summarize this sprint"
Get-AdoPullRequestDetail -RepoName api -PrId 123 | openai "Review this PR"
Search-AdoAllOrgs -AssignedTo 'me@company.com'
```

## Helpful Commands

```powershell
Get-AdoOrgs
Set-AdoDefault -Org 'contoso' -Project 'Backend'
Get-AdoSession
Disconnect-Ado
```

## Troubleshooting

### `AzureCliNotFound`

Azure CLI is missing or not on `PATH`.

Fix:

```powershell
az --version
```

If that fails, install Azure CLI first.

### `AzureCliLoginFailed`

Azure CLI could not sign you in.

Try:

```powershell
az login
Connect-Ado
```

Or:

```powershell
Connect-Ado -UseDeviceCode
```

### `NotConnected`

No active session is available.

Fix:

```powershell
Connect-Ado
```

### `ReauthRequired`

The Azure CLI session or token expired.

Fix:

```powershell
Connect-Ado
```

### `OrganizationNotFound`

The org name passed to a command does not match what is in config.

Check:

```powershell
Get-AdoOrgs
```

### Validation fails after login

Your signed-in account may not have access to the configured Azure DevOps organization.

Check:

- the signed-in Azure CLI account
- the tenant you used
- the org name in config
- your Azure DevOps org access

## Notes

- This skill targets **Azure DevOps Services**, not Azure DevOps Server/on-prem.
- Existing legacy configs that still contain PAT fields are tolerated, but PATs are ignored and removed when config is rewritten.
- `Disconnect-Ado` clears the module session state only. It does not run `az logout`.

## Reference

- Skill details: [SKILL.md](./SKILL.md)
- Command reference: [references/FUNCTIONS.md](./references/FUNCTIONS.md)
