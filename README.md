# rashik-skill-set

Claude Code skills for everyday work tools. Setup is technical and one-time; daily use is just asking Claude.

## Skills

### AzDevOps CLI

Talk to Azure DevOps through Claude — boards, pull requests, sprints, and wikis. No PATs stored; auth runs through Azure CLI / Microsoft Entra. Full details: [`skills/azdevops-skill/README.md`](skills/azdevops-skill/README.md).

#### What you can ask

- *"Find me all active bugs assigned to Rashik."*
- *"What's the status of card 42351?"*
- *"Check the current status of all PRs created by Jane."*
- *"Summarize reviewer feedback on PR 500."*
- *"What's in the current sprint and who's overloaded?"*
- *"Find all my open items across every org."*
- *"Find me the wiki page that explains the codebase."*
- *"Update the runbook page with these new deploy steps."*

See the [skill README](skills/azdevops-skill/README.md) for the full prompt catalog.

#### Setup quickstart

Requirements: PowerShell 7+, Azure CLI on `PATH`, access to an Azure DevOps Services organization.

```powershell
Import-Module .\skills\azdevops-skill\scripts\AzDevOps.psd1 -Force
.\skills\azdevops-skill\scripts\Setup-AzDevOps.ps1
Connect-Ado
```

The wizard collects orgs, projects, defaults, and optional tenant ID, then can sign you in.

For configuration without the wizard, troubleshooting, device-code login, and the cmdlet reference, see [`skills/azdevops-skill/README.md`](skills/azdevops-skill/README.md).
