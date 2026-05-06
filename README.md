# rashik-skill-set

A Claude Code plugin marketplace of skills for everyday work tools.

## Install

In Claude Code:

```
/plugin marketplace add https://github.com/Rashik004/rashik-skill-set
/plugin install azdevops@rashik-skills
```

Then ask Claude things like *"What's in the current sprint?"* or *"Summarize PR 500."*

To get updates later:

```
/plugin marketplace update rashik-skills
```

## Skills in this marketplace

| Plugin | What it does |
|---|---|
| [`azdevops`](plugins/azdevops/README.md) | Query Azure DevOps boards, PRs, sprints, and wikis from PowerShell. No PATs — auth runs through Azure CLI / Microsoft Entra. |

More skills will land here over time.

## What you can ask (azdevops plugin)

- *"Find me all active bugs assigned to Rashik."*
- *"What's the status of card 42351?"*
- *"Check the current status of all PRs created by Jane."*
- *"Summarize reviewer feedback on PR 500."*
- *"What's in the current sprint and who's overloaded?"*
- *"Find all my open items across every org."*
- *"Find me the wiki page that explains the codebase."*
- *"Update the runbook page with these new deploy steps."*

See the [plugin README](plugins/azdevops/README.md) for the full prompt catalog, configuration, troubleshooting, and cmdlet reference.

## Requirements

The `azdevops` plugin needs PowerShell 7+, Azure CLI on `PATH`, and access to an Azure DevOps Services organization. First-time setup runs through:

```powershell
Connect-Ado
Initialize-AdoConfig -Orgs @(@{ Name='contoso'; Projects=@('WebApp') }) -DefaultOrg 'contoso' -DefaultProject 'WebApp'
```

Full setup details: [`plugins/azdevops/README.md`](plugins/azdevops/README.md).
