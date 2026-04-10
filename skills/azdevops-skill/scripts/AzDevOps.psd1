@{
    RootModule        = 'AzDevOps.psm1'
    ModuleVersion     = '2.2.0'
    GUID              = 'a3f7c8d1-5e2b-4a90-b6d4-9c1e3f8a7b5d'
    Author            = 'AzDevOps Module'
    Description       = 'Multi-org Azure DevOps CLI module with Azure CLI-backed Microsoft Entra auth and JSON output for AI provider consumption.'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @(
        'Initialize-AdoConfig'
        'Get-AdoOrgs'
        'Set-AdoDefault'
        'Connect-Ado'
        'Disconnect-Ado'
        'Get-AdoSession'
        'Test-AdoConnection'
        'Get-AdoWorkItem'
        'Get-AdoWorkItems'
        'Get-AdoWorkItemComments'
        'Get-AdoPullRequests'
        'Get-AdoPullRequestDetail'
        'Get-AdoPullRequestDiff'
        'Get-AdoCurrentSprint'
        'Get-AdoUserWorkItems'
        'Get-AdoSprintAssignments'
        'Search-AdoAllOrgs'
        'Get-AdoWikiList'
        'Get-AdoWikiPage'
        'Get-AdoWikiPageTree'
        'Set-AdoWikiPage'
        'Remove-AdoWikiPage'
        'Search-AdoWiki'
    )
    PrivateData = @{
        PSData = @{
            Tags       = @('AzureDevOps', 'DevOps', 'WorkItems', 'PullRequests', 'Wiki', 'AI', 'CLI', 'MicrosoftEntra', 'AzureCLI')
        }
    }
}
