#Requires -Version 7.0
<#
.SYNOPSIS
    Azure DevOps CLI module for multi-org, multi-project work item and PR management.
    Outputs structured JSON for AI provider consumption.

.DESCRIPTION
    Supports multiple Azure DevOps organizations under a single identity.
    Configuration is stored at ~/.azdevops/config.json and does not contain secrets.
    Interactive Microsoft Entra login is brokered through Azure CLI and scoped to the
    current PowerShell session only.
#>

$ErrorActionPreference = 'Stop'
$script:ConfigPath = Join-Path $HOME '.azdevops' 'config.json'
$script:AdoResourceId = '499b84ac-1321-427f-aa17-267ca6975798'
$script:RefreshBuffer = [TimeSpan]::FromMinutes(5)
$script:LegacyPatWarningShown = $false
$script:Session = [ordered]@{
    IsConnected = $false
    AccessToken = $null
    ExpiresOn = $null
    Username = $null
    TenantId = $null
    AuthBroker = 'azure-cli'
    ValidationOrg = $null
    ValidationStatus = 'disconnected'
}

function ConvertTo-AdoJson {
    param(
        [Parameter(Mandatory)]
        [object] $InputObject,

        [int] $Depth = 6
    )

    $InputObject | ConvertTo-Json -Depth $Depth
}

function New-AdoErrorObject {
    param(
        [Parameter(Mandatory)][string] $Code,
        [Parameter(Mandatory)][string] $Message,
        [string] $Hint,
        [int] $StatusCode = 0,
        [string] $Uri,
        [hashtable] $Context
    )

    $errorObject = [ordered]@{
        error   = $true
        code    = $Code
        message = $Message
    }

    if ($Hint) { $errorObject.hint = $Hint }
    if ($StatusCode -gt 0) { $errorObject.statusCode = $StatusCode }
    if ($Uri) { $errorObject.uri = $Uri }
    if ($Context) { $errorObject.context = $Context }

    $errorObject
}

function Reset-AdoSessionState {
    $script:Session = [ordered]@{
        IsConnected = $false
        AccessToken = $null
        ExpiresOn = $null
        Username = $null
        TenantId = $null
        AuthBroker = 'azure-cli'
        ValidationOrg = $null
        ValidationStatus = 'disconnected'
    }
}

function Get-AdoSessionSnapshot {
    [ordered]@{
        connected = [bool]$script:Session.IsConnected
        authMode = 'azure-cli'
        authBroker = $script:Session.AuthBroker
        account = $script:Session.Username
        tenantId = $script:Session.TenantId
        expiresOn = $script:Session.ExpiresOn
        validation = [ordered]@{
            org = $script:Session.ValidationOrg
            status = $script:Session.ValidationStatus
        }
    }
}

function ConvertTo-AdoConfigState {
    param([Parameter(Mandatory)][object] $Config)

    $tenantId = $null
    if ($Config.PSObject.Properties.Name -contains 'auth' -and $Config.auth) {
        if ($Config.auth.PSObject.Properties.Name -contains 'tenantId' -and $Config.auth.tenantId) {
            $tenantId = [string] $Config.auth.tenantId
        }
    } elseif ($Config.PSObject.Properties.Name -contains 'tenantId' -and $Config.tenantId) {
        $tenantId = [string] $Config.tenantId
    }

    $organizations = @()
    foreach ($org in @($Config.organizations)) {
        if (-not $org) { continue }

        if ($org.PSObject.Properties.Name -contains 'pat' -and -not $script:LegacyPatWarningShown) {
            Write-Warning "Legacy PAT values were found in ~/.azdevops/config.json. They are ignored and will be removed the next time the config is saved."
            $script:LegacyPatWarningShown = $true
        }

        $name = $null
        if ($org.PSObject.Properties.Name -contains 'name') {
            $name = [string] $org.name
        } elseif ($org.PSObject.Properties.Name -contains 'Name') {
            $name = [string] $org.Name
        }

        if (-not $name) { continue }

        $projects = @()
        if ($org.PSObject.Properties.Name -contains 'projects') {
            $projects = @($org.projects | ForEach-Object { [string] $_ } | Where-Object { $_ })
        } elseif ($org.PSObject.Properties.Name -contains 'Projects') {
            $projects = @($org.Projects | ForEach-Object { [string] $_ } | Where-Object { $_ })
        }

        $organizations += [ordered]@{
            name = $name
            projects = $projects
        }
    }

    $normalized = [ordered]@{
        defaultOrg = if ($Config.PSObject.Properties.Name -contains 'defaultOrg') { [string] $Config.defaultOrg } else { $null }
        defaultProject = if ($Config.PSObject.Properties.Name -contains 'defaultProject') { [string] $Config.defaultProject } else { $null }
        organizations = $organizations
        auth = [ordered]@{
            mode = 'azure-cli'
            tenantId = $tenantId
        }
    }

    $normalized | ConvertTo-Json -Depth 6 | ConvertFrom-Json
}

function Write-AdoConfig {
    param([Parameter(Mandatory)][object] $Config)

    $configObject = if ($Config -is [hashtable] -or $Config -is [System.Collections.Specialized.OrderedDictionary]) {
        $Config | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    } else {
        $Config
    }

    $normalized = ConvertTo-AdoConfigState -Config $configObject
    $configDir = Split-Path $script:ConfigPath
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    $normalized | ConvertTo-Json -Depth 6 | Set-Content $script:ConfigPath -Force
    $normalized
}

function Get-AdoConfig {
    if (-not (Test-Path $script:ConfigPath)) {
        throw "Config not found. Run Initialize-AdoConfig first."
    }

    $raw = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
    ConvertTo-AdoConfigState -Config $raw
}

function Get-AdoPreferredTenantId {
    if (-not (Test-Path $script:ConfigPath)) { return $null }

    try {
        $cfg = Get-AdoConfig
        if ($cfg.auth -and $cfg.auth.tenantId) {
            return [string] $cfg.auth.tenantId
        }
    } catch {
        return $null
    }

    $null
}

function Get-AdoValidationOrg {
    param([Parameter(Mandatory)][object] $Config)

    if ($Config.defaultOrg) { return [string] $Config.defaultOrg }

    $firstOrg = @($Config.organizations | Select-Object -First 1)
    if ($firstOrg.Count -gt 0) {
        return [string] $firstOrg[0].name
    }

    $null
}

function Get-AdoAzureCliExtensionDirectory {
    $configDir = Split-Path $script:ConfigPath
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    $extensionDir = Join-Path $configDir 'azcliextensions'
    if (-not (Test-Path $extensionDir)) {
        New-Item -ItemType Directory -Path $extensionDir -Force | Out-Null
    }

    $extensionDir
}

function Invoke-AdoAzureCli {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [switch] $ParseJson,
        [Parameter(Mandatory)][string] $ErrorCode,
        [Parameter(Mandatory)][string] $ErrorHint,
        [switch] $AllowFailure
    )

    $azCommand = Get-Command az -ErrorAction SilentlyContinue
    if (-not $azCommand) {
        $errorObject = New-AdoErrorObject -Code 'AzureCliNotFound' -Message "Azure CLI ('az') is not installed or not on PATH." -Hint 'Install Azure CLI and run Connect-Ado again.'
        if ($AllowFailure) { return [ordered]@{ ok = $false; error = $errorObject } }
        return $errorObject
    }

    $previousExtensionDir = $env:AZURE_EXTENSION_DIR
    $env:AZURE_EXTENSION_DIR = Get-AdoAzureCliExtensionDirectory

    try {
        $output = & $azCommand.Source @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        if ($null -eq $previousExtensionDir) {
            Remove-Item Env:AZURE_EXTENSION_DIR -ErrorAction SilentlyContinue
        } else {
            $env:AZURE_EXTENSION_DIR = $previousExtensionDir
        }
    }

    if ($exitCode -ne 0) {
        $message = ($output | Out-String).Trim()
        if (-not $message) { $message = "Azure CLI command failed: az $($Arguments -join ' ')" }
        $errorObject = New-AdoErrorObject -Code $ErrorCode -Message $message -Hint $ErrorHint
        if ($AllowFailure) { return [ordered]@{ ok = $false; error = $errorObject } }
        return $errorObject
    }

    $text = ($output | Out-String).Trim()
    if ($ParseJson) {
        if (-not $text) {
            return [ordered]@{
                ok = $true
                value = $null
                raw = $text
            }
        }

        try {
            return [ordered]@{
                ok = $true
                value = ($text | ConvertFrom-Json)
                raw = $text
            }
        } catch {
            $errorObject = New-AdoErrorObject -Code 'AzureCliParseFailed' -Message "Failed to parse Azure CLI JSON output. Raw output: $text" -Hint $ErrorHint
            if ($AllowFailure) { return [ordered]@{ ok = $false; error = $errorObject } }
            return $errorObject
        }
    }

    [ordered]@{
        ok = $true
        value = $text
        raw = $text
    }
}

function Get-AdoAzureCliAccount {
    param([switch] $AllowFailure)

    $result = Invoke-AdoAzureCli -Arguments @('account', 'show', '--output', 'json', '--only-show-errors') -ParseJson -ErrorCode 'AzureCliAccountUnavailable' -ErrorHint 'Run Connect-Ado to establish an Azure CLI session.' -AllowFailure:$AllowFailure
    if (-not $result.ok) { return $result.error }
    $result.value
}

function Get-AdoAzureCliAccessToken {
    param(
        [string] $TenantId,
        [switch] $AllowFailure
    )

    $arguments = @('account', 'get-access-token', '--resource', $script:AdoResourceId, '--output', 'json', '--only-show-errors')
    if ($TenantId) {
        $arguments += @('--tenant', $TenantId)
    }

    $result = Invoke-AdoAzureCli -Arguments $arguments -ParseJson -ErrorCode 'AzureCliTokenFailed' -ErrorHint 'Run Connect-Ado to sign in with Azure CLI.' -AllowFailure:$AllowFailure
    if (-not $result.ok) { return $result.error }

    $token = $result.value
    $expiresOn = $null
    if ($token.expires_on) {
        $expiresOn = [DateTimeOffset]::FromUnixTimeSeconds([int64] $token.expires_on)
    } elseif ($token.expiresOn) {
        $expiresOn = [DateTimeOffset]::Parse($token.expiresOn)
    } else {
        $expiresOn = [DateTimeOffset]::UtcNow.AddMinutes(55)
    }

    [ordered]@{
        accessToken = $token.accessToken
        expiresOn = $expiresOn
        tenantId = if ($token.tenant) { [string] $token.tenant } else { $TenantId }
    }
}

function Update-AdoSessionState {
    param(
        [Parameter(Mandatory)][object] $TokenState,
        [object] $AccountState,
        [string] $TenantId
    )

    $username = $null
    if ($AccountState -and $AccountState.user -and $AccountState.user.name) {
        $username = [string] $AccountState.user.name
    }

    $effectiveTenant = if ($TokenState.tenantId) { $TokenState.tenantId } else { $TenantId }

    $script:Session.IsConnected = $true
    $script:Session.AccessToken = $TokenState.accessToken
    $script:Session.ExpiresOn = [DateTimeOffset] $TokenState.expiresOn
    $script:Session.Username = $username
    $script:Session.TenantId = $effectiveTenant
    $script:Session.AuthBroker = 'azure-cli'
}

function Invoke-AdoInteractiveLogin {
    param(
        [string] $TenantId,
        [switch] $UseDeviceCode
    )

    $arguments = @('login', '--allow-no-subscriptions', '--output', 'none', '--only-show-errors')
    if ($UseDeviceCode) {
        $arguments += '--use-device-code'
    }
    if ($TenantId) {
        $arguments += @('--tenant', $TenantId)
    }

    $loginResult = Invoke-AdoAzureCli -Arguments $arguments -ErrorCode 'AzureCliLoginFailed' -ErrorHint 'Run Connect-Ado again after confirming Azure CLI can sign you in.'
    if ($loginResult.error) { return $loginResult }

    $tokenState = Get-AdoAzureCliAccessToken -TenantId $TenantId
    if ($tokenState.error) { return $tokenState }

    $accountState = Get-AdoAzureCliAccount -AllowFailure
    if ($accountState.error) { $accountState = $null }

    Update-AdoSessionState -TokenState $tokenState -AccountState $accountState -TenantId $TenantId
    $tokenState
}

function Get-AdoAccessToken {
    if (-not $script:Session.IsConnected -or -not $script:Session.AccessToken) {
        return (New-AdoErrorObject -Code 'NotConnected' -Message 'No active Azure DevOps session. Run Connect-Ado.' -Hint 'Use Connect-Ado -UseDeviceCode if browser sign-in is unavailable.')
    }

    $expiresOn = [DateTimeOffset] $script:Session.ExpiresOn
    if ($expiresOn -gt [DateTimeOffset]::UtcNow.Add($script:RefreshBuffer)) {
        return [ordered]@{
            accessToken = $script:Session.AccessToken
            expiresOn = $expiresOn
            tenantId = $script:Session.TenantId
        }
    }

    $tokenState = Get-AdoAzureCliAccessToken -TenantId $script:Session.TenantId -AllowFailure
    if ($tokenState.error) {
        if ($tokenState.code -eq 'AzureCliNotFound') {
            return $tokenState
        }

        return (New-AdoErrorObject -Code 'ReauthRequired' -Message 'Your Azure CLI session has expired. Run Connect-Ado again.' -Hint 'Use Connect-Ado -UseDeviceCode if browser sign-in is unavailable.')
    }

    $accountState = Get-AdoAzureCliAccount -AllowFailure
    if ($accountState.error) { $accountState = $null }
    Update-AdoSessionState -TokenState $tokenState -AccountState $accountState -TenantId $script:Session.TenantId

    [ordered]@{
        accessToken = $script:Session.AccessToken
        expiresOn = [DateTimeOffset] $script:Session.ExpiresOn
        tenantId = $script:Session.TenantId
    }
}

function Invoke-AdoApi {
    param(
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][hashtable] $Headers,
        [string] $Method = 'GET',
        [object] $Body
    )

    $params = @{
        Uri = $Uri
        Headers = $Headers
        Method = $Method
        ErrorAction = 'Stop'
    }

    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
    }

    try {
        Invoke-RestMethod @params
    } catch {
        $statusCode = 0
        try {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int] $_.Exception.Response.StatusCode
            }
        } catch {
            $statusCode = 0
        }

        $hint = $null
        if ($statusCode -eq 401) {
            $hint = 'Run Connect-Ado to sign in again.'
        }

        New-AdoErrorObject -Code 'ApiRequestFailed' -Message $_.Exception.Message -Hint $hint -StatusCode $statusCode -Uri $Uri
    }
}

function Resolve-AdoContext {
    param(
        [string] $Org,
        [string] $Project
    )

    $cfg = $null
    try {
        $cfg = Get-AdoConfig
    } catch {
        return (New-AdoErrorObject -Code 'ConfigNotFound' -Message $_.Exception.Message -Hint 'Run Initialize-AdoConfig first.')
    }

    $orgName = if ($Org) { $Org } else { $cfg.defaultOrg }
    $projectName = if ($Project) { $Project } else { $cfg.defaultProject }

    if (-not $orgName) {
        return (New-AdoErrorObject -Code 'NoDefaultOrg' -Message 'No default organization is configured.' -Hint 'Run Set-AdoDefault -Org <name> -Project <name> or specify -Org on the command.')
    }

    if (-not $projectName) {
        return (New-AdoErrorObject -Code 'NoDefaultProject' -Message 'No default project is configured.' -Hint 'Run Set-AdoDefault -Org <name> -Project <name> or specify -Project on the command.')
    }

    $orgEntry = @($cfg.organizations | Where-Object { $_.name -eq $orgName } | Select-Object -First 1)
    if ($orgEntry.Count -eq 0) {
        return (New-AdoErrorObject -Code 'OrganizationNotFound' -Message "Organization '$orgName' not found in config." -Hint 'Check Get-AdoOrgs and make sure the organization name matches exactly.')
    }

    $tokenState = Get-AdoAccessToken
    if ($tokenState.error) { return $tokenState }

    [PSCustomObject]@{
        Org = $orgName
        Project = $projectName
        Headers = @{
            Authorization = "Bearer $($tokenState.accessToken)"
            'Content-Type' = 'application/json'
        }
        BaseUrl = "https://dev.azure.com/$orgName"
    }
}

function Invoke-AdoOrgValidation {
    param([string] $Org)

    if (-not $Org) {
        return (New-AdoErrorObject -Code 'NoOrganizationConfigured' -Message 'No configured organization is available for connection validation.' -Hint 'Run Initialize-AdoConfig first, or pass -Org to Test-AdoConnection.')
    }

    $tokenState = Get-AdoAccessToken
    if ($tokenState.error) { return $tokenState }

    $headers = @{
        Authorization = "Bearer $($tokenState.accessToken)"
        'Content-Type' = 'application/json'
    }
    $uri = "https://dev.azure.com/$Org/_apis/projects?`$top=1&api-version=7.0"
    Invoke-AdoApi -Uri $uri -Headers $headers
}

function Format-WorkItem {
    param([Parameter(Mandatory)][object] $Item)

    $fields = $Item.fields
    $assignedTo = $fields.'System.AssignedTo'

    [ordered]@{
        id = $Item.id
        url = $Item._links.html.href
        type = $fields.'System.WorkItemType'
        title = $fields.'System.Title'
        state = $fields.'System.State'
        assignedTo = if ($assignedTo) { $assignedTo.displayName } else { $null }
        assignedMail = if ($assignedTo) { $assignedTo.uniqueName } else { $null }
        priority = $fields.'Microsoft.VSTS.Common.Priority'
        severity = $fields.'Microsoft.VSTS.Common.Severity'
        tags = $fields.'System.Tags'
        areaPath = $fields.'System.AreaPath'
        iteration = $fields.'System.IterationPath'
        createdDate = $fields.'System.CreatedDate'
        changedDate = $fields.'System.ChangedDate'
        description = $fields.'System.Description'
        reproSteps = $fields.'Microsoft.VSTS.TCM.ReproSteps'
        acceptCriteria = $fields.'Microsoft.VSTS.Common.AcceptanceCriteria'
        storyPoints = $fields.'Microsoft.VSTS.Scheduling.StoryPoints'
        effort = $fields.'Microsoft.VSTS.Scheduling.Effort'
    }
}

# ── Private Wiki Helpers ──

function Resolve-AdoWikiIdentifier {
    param(
        [string] $Wiki,
        [Parameter(Mandatory)][PSCustomObject] $Context
    )

    if ($Wiki) {
        return [ordered]@{ wikiIdentifier = $Wiki }
    }

    $uri = "$($Context.BaseUrl)/$($Context.Project)/_apis/wiki/wikis?api-version=7.0"
    $result = Invoke-AdoApi -Uri $uri -Headers $Context.Headers
    if ($result.error) { return $result }

    if (-not $result.value -or $result.value.Count -eq 0) {
        return (New-AdoErrorObject -Code 'WikiNotFound' -Message 'No wikis found in this project.' -Hint 'Create a wiki in Azure DevOps or specify -Wiki with the wiki name or ID.')
    }

    $projectWiki = @($result.value | Where-Object { $_.type -eq 'projectWiki' } | Select-Object -First 1)
    if ($projectWiki.Count -gt 0) {
        return [ordered]@{ wikiIdentifier = $projectWiki[0].name }
    }

    return [ordered]@{ wikiIdentifier = $result.value[0].name }
}

function Get-AdoWikiPageVersion {
    param(
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][hashtable] $Headers
    )

    try {
        $response = Invoke-WebRequest -Uri $Uri -Headers $Headers -Method GET -ErrorAction Stop
        $etag = $response.Headers['ETag']
        if ($etag -is [array]) { $etag = $etag[0] }
        return [ordered]@{ exists = $true; etag = $etag }
    } catch {
        $statusCode = 0
        try {
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
        } catch {}

        if ($statusCode -eq 404) {
            return [ordered]@{ exists = $false; etag = $null }
        }

        $hint = $null
        if ($statusCode -eq 401) {
            $hint = 'Your Azure DevOps session may have expired. Re-authenticate and try again.'
        }

        return (New-AdoErrorObject -Code 'ApiRequestFailed' -Message $_.Exception.Message -StatusCode $statusCode -Uri $Uri -Hint $hint)
    }
}

function Format-WikiPage {
    param(
        [Parameter(Mandatory)][object] $Page,
        [switch] $IncludeContent
    )

    $formatted = [ordered]@{
        id       = $Page.id
        path     = $Page.path
        order    = $Page.order
        gitItemPath = $Page.gitItemPath
        url      = $Page.remoteUrl
    }

    if ($IncludeContent -and $null -ne $Page.content) {
        $formatted.content = $Page.content
    }

    if ($Page.subPages -and $Page.subPages.Count -gt 0) {
        $formatted.subPages = @($Page.subPages | ForEach-Object { Format-WikiPage -Page $_ })
    }

    $formatted
}

function Initialize-AdoConfig {
    <#
    .SYNOPSIS
        Bootstrap config with one or more orgs and projects.
    .PARAMETER Orgs
        Array of hashtables: @{ Name='myorg'; Projects=@('Proj1','Proj2') }
    .PARAMETER DefaultOrg
        Org name used when -Org is omitted.
    .PARAMETER DefaultProject
        Project name used when -Project is omitted.
    .PARAMETER TenantId
        Optional tenant preference used by Connect-Ado when -TenantId is omitted.
    .EXAMPLE
        Initialize-AdoConfig -Orgs @(
            @{ Name='contoso'; Projects=@('WebApp','Backend') },
            @{ Name='fabrikam'; Projects=@('Mobile') }
        ) -DefaultOrg 'contoso' -DefaultProject 'WebApp'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable[]] $Orgs,
        [Parameter(Mandatory)][string] $DefaultOrg,
        [Parameter(Mandatory)][string] $DefaultProject,
        [string] $TenantId
    )

    if ($Orgs.Count -eq 0) {
        throw "At least one organization must be provided."
    }

    $normalizedOrgs = @()
    foreach ($org in $Orgs) {
        if (-not $org.Name) {
            throw "Each organization must include a Name value."
        }

        $projects = @($org.Projects | ForEach-Object { [string] $_ } | Where-Object { $_ })
        if ($projects.Count -eq 0) {
            throw "Organization '$($org.Name)' must include at least one project."
        }

        $normalizedOrgs += [ordered]@{
            name = [string] $org.Name
            projects = $projects
        }
    }

    $defaultOrgEntry = @($normalizedOrgs | Where-Object { $_.name -eq $DefaultOrg } | Select-Object -First 1)
    if ($defaultOrgEntry.Count -eq 0) {
        throw "Default organization '$DefaultOrg' was not found in the supplied org list."
    }

    if ($defaultOrgEntry[0].projects -notcontains $DefaultProject) {
        throw "Default project '$DefaultProject' was not found under organization '$DefaultOrg'."
    }

    $config = [ordered]@{
        defaultOrg = $DefaultOrg
        defaultProject = $DefaultProject
        organizations = $normalizedOrgs
        auth = [ordered]@{
            mode = 'azure-cli'
            tenantId = $TenantId
        }
    }

    $saved = Write-AdoConfig -Config $config
    ConvertTo-AdoJson -InputObject ([ordered]@{
        configPath = $script:ConfigPath
        defaultOrg = $saved.defaultOrg
        defaultProject = $saved.defaultProject
        authMode = $saved.auth.mode
        tenantId = $saved.auth.tenantId
        organizations = $saved.organizations
    }) -Depth 6
}

function Get-AdoOrgs {
    try {
        $cfg = Get-AdoConfig
    } catch {
        return (ConvertTo-AdoJson -InputObject (New-AdoErrorObject -Code 'ConfigNotFound' -Message $_.Exception.Message -Hint 'Run Initialize-AdoConfig first.'))
    }

    $orgs = @($cfg.organizations | ForEach-Object {
        [ordered]@{
            organization = $_.name
            projects = $_.projects
            isDefault = ($_.name -eq $cfg.defaultOrg)
        }
    })

    ConvertTo-AdoJson -InputObject ([ordered]@{
        defaultOrg = $cfg.defaultOrg
        defaultProject = $cfg.defaultProject
        authMode = $cfg.auth.mode
        connected = [bool] $script:Session.IsConnected
        organizations = $orgs
    }) -Depth 5
}

function Set-AdoDefault {
    [CmdletBinding()]
    param(
        [string] $Org,
        [string] $Project
    )

    $cfg = $null
    try {
        $cfg = Get-AdoConfig
    } catch {
        return (ConvertTo-AdoJson -InputObject (New-AdoErrorObject -Code 'ConfigNotFound' -Message $_.Exception.Message -Hint 'Run Initialize-AdoConfig first.'))
    }

    if ($Org) {
        $orgEntry = @($cfg.organizations | Where-Object { $_.name -eq $Org } | Select-Object -First 1)
        if ($orgEntry.Count -eq 0) {
            return (ConvertTo-AdoJson -InputObject (New-AdoErrorObject -Code 'OrganizationNotFound' -Message "Organization '$Org' not found in config." -Hint 'Check Get-AdoOrgs for configured names.'))
        }
        $cfg.defaultOrg = $Org
    }

    if ($Project) {
        $targetOrg = if ($Org) { $Org } else { $cfg.defaultOrg }
        $orgEntry = @($cfg.organizations | Where-Object { $_.name -eq $targetOrg } | Select-Object -First 1)
        if ($orgEntry.Count -eq 0) {
            return (ConvertTo-AdoJson -InputObject (New-AdoErrorObject -Code 'OrganizationNotFound' -Message "Organization '$targetOrg' not found in config." -Hint 'Check Get-AdoOrgs for configured names.'))
        }

        if ($orgEntry[0].projects -notcontains $Project) {
            return (ConvertTo-AdoJson -InputObject (New-AdoErrorObject -Code 'ProjectNotFound' -Message "Project '$Project' is not configured under organization '$targetOrg'." -Hint 'Add the project to config or choose one of the configured project names.'))
        }

        $cfg.defaultProject = $Project
    }

    $saved = Write-AdoConfig -Config $cfg
    ConvertTo-AdoJson -InputObject ([ordered]@{
        defaultOrg = $saved.defaultOrg
        defaultProject = $saved.defaultProject
        authMode = $saved.auth.mode
        tenantId = $saved.auth.tenantId
    }) -Depth 4
}

function Connect-Ado {
    [CmdletBinding()]
    param(
        [string] $TenantId,
        [switch] $UseDeviceCode
    )

    $effectiveTenant = if ($TenantId) { $TenantId } else { Get-AdoPreferredTenantId }
    $tokenState = $null
    if (-not $UseDeviceCode) {
        $tokenState = Get-AdoAzureCliAccessToken -TenantId $effectiveTenant -AllowFailure
        if ($tokenState.error) {
            $tokenState = $null
        }
    }

    if (-not $tokenState) {
        $tokenState = Invoke-AdoInteractiveLogin -TenantId $effectiveTenant -UseDeviceCode:$UseDeviceCode
        if ($tokenState.error) {
            return (ConvertTo-AdoJson -InputObject $tokenState)
        }
    } else {
        $accountState = Get-AdoAzureCliAccount -AllowFailure
        if ($accountState.error) { $accountState = $null }
        Update-AdoSessionState -TokenState $tokenState -AccountState $accountState -TenantId $effectiveTenant
    }

    $validationOrg = $null
    if (Test-Path $script:ConfigPath) {
        try {
            $cfg = Get-AdoConfig
            $validationOrg = Get-AdoValidationOrg -Config $cfg
        } catch {
            $validationOrg = $null
        }
    }

    $validationStatus = 'skipped'
    $validationDetails = [ordered]@{
        org = $validationOrg
        succeeded = $false
        message = 'Sign-in complete. No configured organization was available for validation.'
    }

    if ($validationOrg) {
        $validation = Invoke-AdoOrgValidation -Org $validationOrg
        if ($validation.error) {
            $validationStatus = 'failed'
            $validationDetails = [ordered]@{
                org = $validationOrg
                succeeded = $false
                message = $validation.message
                code = $validation.code
                statusCode = $validation.statusCode
            }
        } else {
            $validationStatus = 'succeeded'
            $validationDetails = [ordered]@{
                org = $validationOrg
                succeeded = $true
                message = "Connected and validated against organization '$validationOrg'."
            }
        }
    }

    $script:Session.ValidationOrg = $validationOrg
    $script:Session.ValidationStatus = $validationStatus

    ConvertTo-AdoJson -InputObject ([ordered]@{
        connected = $true
        authMode = 'azure-cli'
        authBroker = 'azure-cli'
        account = $script:Session.Username
        tenantId = $script:Session.TenantId
        expiresOn = $script:Session.ExpiresOn
        validation = $validationDetails
    }) -Depth 6
}

function Disconnect-Ado {
    Reset-AdoSessionState
    ConvertTo-AdoJson -InputObject ([ordered]@{
        disconnected = $true
        message = 'Azure DevOps session cleared from the current PowerShell session.'
    }) -Depth 3
}

function Get-AdoSession {
    ConvertTo-AdoJson -InputObject (Get-AdoSessionSnapshot) -Depth 5
}

function Test-AdoConnection {
    [CmdletBinding()]
    param([string] $Org)

    $validationOrg = $Org
    if (-not $validationOrg) {
        if (-not (Test-Path $script:ConfigPath)) {
            return (ConvertTo-AdoJson -InputObject (New-AdoErrorObject -Code 'ConfigNotFound' -Message 'Config not found. Run Initialize-AdoConfig first.' -Hint 'You can also pass -Org to Test-AdoConnection once config exists.'))
        }

        try {
            $cfg = Get-AdoConfig
            $validationOrg = Get-AdoValidationOrg -Config $cfg
        } catch {
            return (ConvertTo-AdoJson -InputObject (New-AdoErrorObject -Code 'ConfigNotFound' -Message $_.Exception.Message -Hint 'Run Initialize-AdoConfig first.'))
        }
    }

    $result = Invoke-AdoOrgValidation -Org $validationOrg
    if ($result.error) {
        return (ConvertTo-AdoJson -InputObject $result)
    }

    $script:Session.ValidationOrg = $validationOrg
    $script:Session.ValidationStatus = 'succeeded'

    ConvertTo-AdoJson -InputObject ([ordered]@{
        connected = $true
        account = $script:Session.Username
        tenantId = $script:Session.TenantId
        expiresOn = $script:Session.ExpiresOn
        organization = $validationOrg
        message = "Connection validated for organization '$validationOrg'."
    }) -Depth 5
}

function Get-AdoWorkItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int] $Id,
        [string] $Org,
        [string] $Project
    )

    $ctx = Resolve-AdoContext -Org $Org -Project $Project
    if ($ctx.error) { return (ConvertTo-AdoJson -InputObject $ctx) }

    $uri = "$($ctx.BaseUrl)/$($ctx.Project)/_apis/wit/workitems/${Id}?`$expand=all&api-version=7.0"
    $raw = Invoke-AdoApi -Uri $uri -Headers $ctx.Headers
    if ($raw.error) { return (ConvertTo-AdoJson -InputObject $raw) }

    $item = Format-WorkItem -Item $raw
    $item.relations = @()
    if ($raw.relations) {
        $item.relations = @($raw.relations | ForEach-Object {
            [ordered]@{
                rel = $_.rel
                url = $_.url
                name = $_.attributes.name
            }
        })
    }

    ConvertTo-AdoJson -InputObject ([ordered]@{
        context = [ordered]@{
            org = $ctx.Org
            project = $ctx.Project
        }
        workItem = $item
    }) -Depth 6
}

function Get-AdoWorkItems {
    [CmdletBinding()]
    param(
        [ValidateSet('Bug', 'User Story', 'Feature', 'Task', 'Epic')]
        [string] $Type,
        [string] $State,
        [string] $AssignedTo,
        [string] $Wiql,
        [int] $Top = 50,
        [string] $Org,
        [string] $Project
    )

    $ctx = Resolve-AdoContext -Org $Org -Project $Project
    if ($ctx.error) { return (ConvertTo-AdoJson -InputObject $ctx) }

    if (-not $Wiql) {
        $conditions = @("[System.TeamProject] = '$($ctx.Project)'")
        if ($Type) { $conditions += "[System.WorkItemType] = '$Type'" }
        if ($State) { $conditions += "[System.State] = '$State'" }
        if ($AssignedTo) { $conditions += "[System.AssignedTo] = '$AssignedTo'" }
        $Wiql = "SELECT [System.Id] FROM WorkItems WHERE $($conditions -join ' AND ') ORDER BY [System.ChangedDate] DESC"
    }

    $queryUri = "$($ctx.BaseUrl)/$($ctx.Project)/_apis/wit/wiql?api-version=7.0&`$top=$Top"
    $queryResult = Invoke-AdoApi -Uri $queryUri -Headers $ctx.Headers -Method POST -Body @{ query = $Wiql }
    if ($queryResult.error) { return (ConvertTo-AdoJson -InputObject $queryResult) }

    if (-not $queryResult.workItems -or $queryResult.workItems.Count -eq 0) {
        return (ConvertTo-AdoJson -InputObject ([ordered]@{
            context = [ordered]@{
                org = $ctx.Org
                project = $ctx.Project
            }
            items = @()
            count = 0
        }) -Depth 4)
    }

    $ids = ($queryResult.workItems | Select-Object -First $Top).id -join ','
    $batchUri = "$($ctx.BaseUrl)/$($ctx.Project)/_apis/wit/workitems?ids=$ids&`$expand=all&api-version=7.0"
    $batch = Invoke-AdoApi -Uri $batchUri -Headers $ctx.Headers
    if ($batch.error) { return (ConvertTo-AdoJson -InputObject $batch) }

    $items = @($batch.value | ForEach-Object { Format-WorkItem -Item $_ })

    ConvertTo-AdoJson -InputObject ([ordered]@{
        context = [ordered]@{
            org = $ctx.Org
            project = $ctx.Project
            wiql = $Wiql
        }
        count = $items.Count
        items = $items
    }) -Depth 6
}

function Get-AdoWorkItemComments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int] $Id,
        [string] $Org,
        [string] $Project
    )

    $ctx = Resolve-AdoContext -Org $Org -Project $Project
    if ($ctx.error) { return (ConvertTo-AdoJson -InputObject $ctx) }

    $uri = "$($ctx.BaseUrl)/$($ctx.Project)/_apis/wit/workitems/${Id}/comments?api-version=7.0-preview.4"
    $raw = Invoke-AdoApi -Uri $uri -Headers $ctx.Headers
    if ($raw.error) { return (ConvertTo-AdoJson -InputObject $raw) }

    $comments = @($raw.comments | ForEach-Object {
        [ordered]@{
            id = $_.id
            text = ($_.text -replace '<[^>]+>', '')
            createdBy = $_.createdBy.displayName
            createdDate = $_.createdDate
            modifiedDate = $_.modifiedDate
        }
    })

    ConvertTo-AdoJson -InputObject ([ordered]@{
        context = [ordered]@{
            org = $ctx.Org
            project = $ctx.Project
            workItemId = $Id
        }
        count = $comments.Count
        comments = $comments
    }) -Depth 5
}

function Get-AdoPullRequests {
    [CmdletBinding()]
    param(
        [string] $RepoName,
        [string] $CreatedBy,
        [ValidateSet('active', 'completed', 'abandoned', 'all')]
        [string] $Status = 'active',
        [int] $Top = 30,
        [string] $Org,
        [string] $Project
    )

    $ctx = Resolve-AdoContext -Org $Org -Project $Project
    if ($ctx.error) { return (ConvertTo-AdoJson -InputObject $ctx) }

    if ($RepoName) {
        $uri = "$($ctx.BaseUrl)/$($ctx.Project)/_apis/git/repositories/$RepoName/pullrequests?searchCriteria.status=$Status&`$top=$Top&api-version=7.0"
    } else {
        $uri = "$($ctx.BaseUrl)/$($ctx.Project)/_apis/git/pullrequests?searchCriteria.status=$Status&`$top=$Top&api-version=7.0"
    }

    $raw = Invoke-AdoApi -Uri $uri -Headers $ctx.Headers
    if ($raw.error) { return (ConvertTo-AdoJson -InputObject $raw) }

    $prs = @($raw.value | ForEach-Object {
        $pr = $_
        if ($CreatedBy -and $pr.createdBy.displayName -notlike "*$CreatedBy*") { return }

        [ordered]@{
            prId = $pr.pullRequestId
            title = $pr.title
            status = $pr.status
            createdBy = $pr.createdBy.displayName
            creationDate = $pr.creationDate
            sourceRef = $pr.sourceRefName -replace 'refs/heads/', ''
            targetRef = $pr.targetRefName -replace 'refs/heads/', ''
            repository = $pr.repository.name
            mergeStatus = $pr.mergeStatus
            isDraft = $pr.isDraft
            reviewers = @($pr.reviewers | ForEach-Object {
                [ordered]@{
                    name = $_.displayName
                    vote = $_.vote
                    isRequired = $_.isRequired
                }
            })
            url = $pr.url -replace '_apis/git/repositories/.+/pullRequests', "_git/$($pr.repository.name)/pullrequest"
            workItemRefs = @($pr.workItemRefs | ForEach-Object { $_.id })
        }
    })

    ConvertTo-AdoJson -InputObject ([ordered]@{
        context = [ordered]@{
            org = $ctx.Org
            project = $ctx.Project
            status = $Status
        }
        count = $prs.Count
        pullRequests = $prs
    }) -Depth 6
}

function Get-AdoPullRequestDetail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RepoName,
        [Parameter(Mandatory)][int] $PrId,
        [string] $Org,
        [string] $Project
    )

    $ctx = Resolve-AdoContext -Org $Org -Project $Project
    if ($ctx.error) { return (ConvertTo-AdoJson -InputObject $ctx) }

    $base = "$($ctx.BaseUrl)/$($ctx.Project)/_apis/git/repositories/$RepoName/pullrequests/$PrId"

    $pr = Invoke-AdoApi -Uri "$base`?api-version=7.0" -Headers $ctx.Headers
    if ($pr.error) { return (ConvertTo-AdoJson -InputObject $pr) }

    $threads = Invoke-AdoApi -Uri "$base/threads?api-version=7.0" -Headers $ctx.Headers
    if ($threads.error) { return (ConvertTo-AdoJson -InputObject $threads) }

    $commentData = @($threads.value | ForEach-Object {
        $thread = $_
        [ordered]@{
            threadId = $thread.id
            status = $thread.status
            filePath = if ($thread.threadContext) { $thread.threadContext.filePath } else { $null }
            lineNumber = if ($thread.threadContext -and $thread.threadContext.rightFileStart) { $thread.threadContext.rightFileStart.line } else { $null }
            comments = @($thread.comments | Where-Object { $_.commentType -ne 'system' } | ForEach-Object {
                [ordered]@{
                    author = $_.author.displayName
                    content = ($_.content -replace '<[^>]+>', '')
                    date = $_.publishedDate
                }
            })
        }
    })

    $iterations = Invoke-AdoApi -Uri "$base/iterations?api-version=7.0" -Headers $ctx.Headers
    if ($iterations.error) { return (ConvertTo-AdoJson -InputObject $iterations) }

    $iterData = @($iterations.value | ForEach-Object {
        [ordered]@{
            id = $_.id
            description = $_.description
            author = $_.author.displayName
            createdDate = $_.createdDate
            sourceCommit = $_.sourceRefCommit.commitId
        }
    })

    $fileChanges = @()
    if ($iterData.Count -gt 0) {
        $lastIter = $iterData[-1].id
        $changes = Invoke-AdoApi -Uri "$base/iterations/$lastIter/changes?api-version=7.0" -Headers $ctx.Headers
        if ($changes.error) { return (ConvertTo-AdoJson -InputObject $changes) }

        $fileChanges = @($changes.changeEntries | ForEach-Object {
            [ordered]@{
                path = $_.item.path
                changeType = $_.changeType
            }
        })
    }

    $wiRefs = Invoke-AdoApi -Uri "$base/workitems?api-version=7.0" -Headers $ctx.Headers
    if ($wiRefs.error) { return (ConvertTo-AdoJson -InputObject $wiRefs) }

    $linkedItems = @($wiRefs.value | ForEach-Object {
        [ordered]@{
            id = $_.id
            url = $_.url
        }
    })

    ConvertTo-AdoJson -InputObject ([ordered]@{
        context = [ordered]@{
            org = $ctx.Org
            project = $ctx.Project
            repo = $RepoName
            prId = $PrId
        }
        pullRequest = [ordered]@{
            title = $pr.title
            description = $pr.description
            status = $pr.status
            createdBy = $pr.createdBy.displayName
            creationDate = $pr.creationDate
            sourceRef = $pr.sourceRefName -replace 'refs/heads/', ''
            targetRef = $pr.targetRefName -replace 'refs/heads/', ''
            mergeStatus = $pr.mergeStatus
            isDraft = $pr.isDraft
            reviewers = @($pr.reviewers | ForEach-Object {
                [ordered]@{
                    name = $_.displayName
                    vote = $_.vote
                    isRequired = $_.isRequired
                }
            })
        }
        threads = $commentData
        iterations = $iterData
        fileChanges = $fileChanges
        linkedWorkItems = $linkedItems
    }) -Depth 8
}

function Get-AdoPullRequestDiff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RepoName,
        [Parameter(Mandatory)][int] $PrId,
        [Parameter(Mandatory)][string] $FilePath,
        [string] $Org,
        [string] $Project
    )

    $ctx = Resolve-AdoContext -Org $Org -Project $Project
    if ($ctx.error) { return (ConvertTo-AdoJson -InputObject $ctx) }

    $base = "$($ctx.BaseUrl)/$($ctx.Project)/_apis/git/repositories/$RepoName/pullrequests/$PrId"
    $pr = Invoke-AdoApi -Uri "$base`?api-version=7.0" -Headers $ctx.Headers
    if ($pr.error) { return (ConvertTo-AdoJson -InputObject $pr) }

    $sourceCommit = $pr.lastMergeSourceCommit.commitId
    $targetCommit = $pr.lastMergeTargetCommit.commitId
    $encodedPath = [Uri]::EscapeDataString($FilePath)
    $repoBase = "$($ctx.BaseUrl)/$($ctx.Project)/_apis/git/repositories/$RepoName"

    $sourceContent = try {
        Invoke-RestMethod -Uri "$repoBase/items?path=$encodedPath&versionDescriptor.version=$sourceCommit&versionDescriptor.versionType=commit&api-version=7.0" -Headers $ctx.Headers -ErrorAction Stop
    } catch {
        '[file not in source branch]'
    }

    $targetContent = try {
        Invoke-RestMethod -Uri "$repoBase/items?path=$encodedPath&versionDescriptor.version=$targetCommit&versionDescriptor.versionType=commit&api-version=7.0" -Headers $ctx.Headers -ErrorAction Stop
    } catch {
        '[file not in target branch]'
    }

    ConvertTo-AdoJson -InputObject ([ordered]@{
        context = [ordered]@{
            org = $ctx.Org
            project = $ctx.Project
            repo = $RepoName
            prId = $PrId
            file = $FilePath
        }
        source = [ordered]@{
            commit = $sourceCommit
            content = $sourceContent
        }
        target = [ordered]@{
            commit = $targetCommit
            content = $targetContent
        }
    }) -Depth 5
}

function Get-AdoCurrentSprint {
    [CmdletBinding()]
    param(
        [string] $Team,
        [string] $Org,
        [string] $Project
    )

    $ctx = Resolve-AdoContext -Org $Org -Project $Project
    if ($ctx.error) { return (ConvertTo-AdoJson -InputObject $ctx) }

    $teamName = if ($Team) { $Team } else { "$($ctx.Project) Team" }
    $encodedTeam = [Uri]::EscapeDataString($teamName)

    $iterUri = "$($ctx.BaseUrl)/$($ctx.Project)/$encodedTeam/_apis/work/teamsettings/iterations?`$timeframe=current&api-version=7.0"
    $iter = Invoke-AdoApi -Uri $iterUri -Headers $ctx.Headers
    if ($iter.error) { return (ConvertTo-AdoJson -InputObject $iter) }

    $currentIter = $iter.value | Select-Object -First 1
    if (-not $currentIter) {
        return (ConvertTo-AdoJson -InputObject ([ordered]@{
            context = [ordered]@{
                org = $ctx.Org
                project = $ctx.Project
                team = $teamName
            }
            sprint = $null
            message = 'No active sprint found.'
        }) -Depth 4)
    }

    $wiUri = "$($ctx.BaseUrl)/$($ctx.Project)/$encodedTeam/_apis/work/teamsettings/iterations/$($currentIter.id)/workitems?api-version=7.0-preview.1"
    $wiResult = Invoke-AdoApi -Uri $wiUri -Headers $ctx.Headers
    if ($wiResult.error) { return (ConvertTo-AdoJson -InputObject $wiResult) }

    $itemIds = @($wiResult.workItemRelations | ForEach-Object { $_.target.id } | Where-Object { $_ })
    $items = @()
    if ($itemIds.Count -gt 0) {
        $idsCsv = $itemIds -join ','
        $batchUri = "$($ctx.BaseUrl)/$($ctx.Project)/_apis/wit/workitems?ids=$idsCsv&`$expand=all&api-version=7.0"
        $batch = Invoke-AdoApi -Uri $batchUri -Headers $ctx.Headers
        if ($batch.error) { return (ConvertTo-AdoJson -InputObject $batch) }
        $items = @($batch.value | ForEach-Object { Format-WorkItem -Item $_ })
    }

    ConvertTo-AdoJson -InputObject ([ordered]@{
        context = [ordered]@{
            org = $ctx.Org
            project = $ctx.Project
            team = $teamName
        }
        sprint = [ordered]@{
            name = $currentIter.name
            path = $currentIter.path
            startDate = $currentIter.attributes.startDate
            endDate = $currentIter.attributes.finishDate
            timeFrame = $currentIter.attributes.timeFrame
        }
        count = $items.Count
        items = $items
    }) -Depth 6
}

function Get-AdoUserWorkItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $User,
        [string] $Org,
        [string] $Project
    )

    $ctx = Resolve-AdoContext -Org $Org -Project $Project
    if ($ctx.error) { return (ConvertTo-AdoJson -InputObject $ctx) }

    $wiql = @"
SELECT [System.Id]
FROM WorkItems
WHERE [System.TeamProject] = '@project'
  AND [System.AssignedTo] = '$User'
  AND [System.State] NOT IN ('Closed','Removed','Done')
ORDER BY [System.ChangedDate] DESC
"@

    $wiql = $wiql -replace '@project', $ctx.Project
    Get-AdoWorkItems -Wiql $wiql -Org $ctx.Org -Project $ctx.Project
}

function Get-AdoSprintAssignments {
    [CmdletBinding()]
    param(
        [string] $Team,
        [string] $Org,
        [string] $Project
    )

    $ctx = Resolve-AdoContext -Org $Org -Project $Project
    if ($ctx.error) { return (ConvertTo-AdoJson -InputObject $ctx) }

    $teamName = if ($Team) { $Team } else { "$($ctx.Project) Team" }
    $sprintJson = Get-AdoCurrentSprint -Team $teamName -Org $ctx.Org -Project $ctx.Project
    $sprint = $sprintJson | ConvertFrom-Json
    if ($sprint.error) { return $sprintJson }

    if (-not $sprint.items) {
        return (ConvertTo-AdoJson -InputObject ([ordered]@{
            context = [ordered]@{
                org = $ctx.Org
                project = $ctx.Project
                sprint = if ($sprint.sprint) { $sprint.sprint.name } else { $null }
            }
            assignments = @{}
            message = 'No items in current sprint.'
        }) -Depth 5)
    }

    $grouped = @{}
    foreach ($item in $sprint.items) {
        $assignee = if ($item.assignedTo) { $item.assignedTo } else { '_Unassigned' }
        if (-not $grouped.ContainsKey($assignee)) {
            $grouped[$assignee] = @()
        }

        $grouped[$assignee] += [ordered]@{
            id = $item.id
            type = $item.type
            title = $item.title
            state = $item.state
            storyPoints = $item.storyPoints
        }
    }

    ConvertTo-AdoJson -InputObject ([ordered]@{
        context = [ordered]@{
            org = $ctx.Org
            project = $ctx.Project
            sprint = $sprint.sprint.name
        }
        assignments = $grouped
    }) -Depth 6
}

function Search-AdoAllOrgs {
    [CmdletBinding()]
    param(
        [string] $Type,
        [string] $State,
        [string] $AssignedTo,
        [int] $Top = 20
    )

    $cfg = $null
    try {
        $cfg = Get-AdoConfig
    } catch {
        return (ConvertTo-AdoJson -InputObject (New-AdoErrorObject -Code 'ConfigNotFound' -Message $_.Exception.Message -Hint 'Run Initialize-AdoConfig first.'))
    }

    $allResults = @()
    foreach ($orgEntry in $cfg.organizations) {
        foreach ($project in $orgEntry.projects) {
            $json = Get-AdoWorkItems -Type $Type -State $State -AssignedTo $AssignedTo -Top $Top -Org $orgEntry.name -Project $project
            $parsed = $json | ConvertFrom-Json
            if ($parsed.error) { return $json }

            if ($parsed.items) {
                $allResults += [ordered]@{
                    org = $orgEntry.name
                    project = $project
                    count = $parsed.count
                    items = $parsed.items
                }
            }
        }
    }

    ConvertTo-AdoJson -InputObject ([ordered]@{
        totalOrgs = $cfg.organizations.Count
        totalProjects = ($cfg.organizations | ForEach-Object { $_.projects.Count } | Measure-Object -Sum).Sum
        results = $allResults
    }) -Depth 8
}

# ── Wiki Functions ──

function Get-AdoWikiList {
    <#
    .SYNOPSIS
        List all wikis in the project.
    .EXAMPLE
        Get-AdoWikiList
    #>
    [CmdletBinding()]
    param(
        [string] $Org,
        [string] $Project
    )

    $ctx = Resolve-AdoContext -Org $Org -Project $Project
    if ($ctx.error) { return (ConvertTo-AdoJson -InputObject $ctx) }

    $uri = "$($ctx.BaseUrl)/$($ctx.Project)/_apis/wiki/wikis?api-version=7.0"
    $raw = Invoke-AdoApi -Uri $uri -Headers $ctx.Headers
    if ($raw.error) { return (ConvertTo-AdoJson -InputObject $raw) }

    $wikis = @($raw.value | ForEach-Object {
        [ordered]@{
            id       = $_.id
            name     = $_.name
            type     = $_.type
            url      = $_.url
            versions = @($_.versions | ForEach-Object { $_.version })
        }
    })

    ConvertTo-AdoJson -InputObject ([ordered]@{
        context = [ordered]@{
            org     = $ctx.Org
            project = $ctx.Project
        }
        count = $wikis.Count
        wikis = $wikis
    }) -Depth 5
}

function Get-AdoWikiPage {
    <#
    .SYNOPSIS
        Fetch a wiki page by path, including its content.
    .PARAMETER Path
        Page path (e.g. '/Architecture/Overview').
    .PARAMETER Wiki
        Wiki name or ID. If omitted the project wiki is used automatically.
    .PARAMETER IncludeSubPages
        When set, includes one level of child pages in the response.
    .EXAMPLE
        Get-AdoWikiPage -Path '/Architecture/Overview'
        Get-AdoWikiPage -Path '/Setup' -IncludeSubPages -Wiki 'MyProject.wiki'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [string] $Wiki,
        [switch] $IncludeSubPages,
        [string] $Org,
        [string] $Project
    )

    $ctx = Resolve-AdoContext -Org $Org -Project $Project
    if ($ctx.error) { return (ConvertTo-AdoJson -InputObject $ctx) }

    $wikiInfo = Resolve-AdoWikiIdentifier -Wiki $Wiki -Context $ctx
    if ($wikiInfo.error) { return (ConvertTo-AdoJson -InputObject $wikiInfo) }
    $wikiId = $wikiInfo.wikiIdentifier
    $encodedWikiId = [Uri]::EscapeDataString($wikiId)

    $encodedPath = [Uri]::EscapeDataString($Path)
    $recursion = if ($IncludeSubPages) { 'oneLevel' } else { 'none' }
    $uri = "$($ctx.BaseUrl)/$($ctx.Project)/_apis/wiki/wikis/$encodedWikiId/pages?path=$encodedPath&includeContent=true&recursionLevel=$recursion&api-version=7.0"

    $raw = Invoke-AdoApi -Uri $uri -Headers $ctx.Headers
    if ($raw.error) { return (ConvertTo-AdoJson -InputObject $raw) }

    $pageData = if ($raw.page) { $raw.page } else { $raw }
    $page = Format-WikiPage -Page $pageData -IncludeContent

    ConvertTo-AdoJson -InputObject ([ordered]@{
        context = [ordered]@{
            org     = $ctx.Org
            project = $ctx.Project
            wiki    = $wikiId
        }
        page = $page
    }) -Depth 8
}

function Get-AdoWikiPageTree {
    <#
    .SYNOPSIS
        Get the wiki page hierarchy (table of contents) without content.
    .PARAMETER Path
        Root path for the tree (default '/').
    .PARAMETER Depth
        Recursion depth: 'oneLevel' or 'full' (default 'full').
    .EXAMPLE
        Get-AdoWikiPageTree
        Get-AdoWikiPageTree -Path '/Architecture' -Depth oneLevel
    #>
    [CmdletBinding()]
    param(
        [string] $Path = '/',
        [string] $Wiki,
        [ValidateSet('oneLevel', 'full')]
        [string] $Depth = 'full',
        [string] $Org,
        [string] $Project
    )

    $ctx = Resolve-AdoContext -Org $Org -Project $Project
    if ($ctx.error) { return (ConvertTo-AdoJson -InputObject $ctx) }

    $wikiInfo = Resolve-AdoWikiIdentifier -Wiki $Wiki -Context $ctx
    if ($wikiInfo.error) { return (ConvertTo-AdoJson -InputObject $wikiInfo) }
    $wikiId = $wikiInfo.wikiIdentifier

    $encodedPath = [Uri]::EscapeDataString($Path)
    $uri = "$($ctx.BaseUrl)/$($ctx.Project)/_apis/wiki/wikis/$wikiId/pages?path=$encodedPath&recursionLevel=$Depth&api-version=7.0"

    $raw = Invoke-AdoApi -Uri $uri -Headers $ctx.Headers
    if ($raw.error) { return (ConvertTo-AdoJson -InputObject $raw) }

    $pageData = if ($raw.page) { $raw.page } else { $raw }
    $tree = Format-WikiPage -Page $pageData

    ConvertTo-AdoJson -InputObject ([ordered]@{
        context = [ordered]@{
            org      = $ctx.Org
            project  = $ctx.Project
            wiki     = $wikiId
            rootPath = $Path
        }
        tree = $tree
    }) -Depth 20
}

function Set-AdoWikiPage {
    <#
    .SYNOPSIS
        Create or update a wiki page. Automatically detects whether the page
        exists and handles versioning (ETag) for updates.
    .PARAMETER Path
        Page path (e.g. '/Architecture/NewPage').
    .PARAMETER Content
        Markdown content for the page.
    .PARAMETER Comment
        Optional commit comment for the change.
    .EXAMPLE
        Set-AdoWikiPage -Path '/Notes/Daily' -Content '# Daily Notes'
        Set-AdoWikiPage -Path '/Runbook' -Content $md -Comment 'Updated runbook steps'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Content,
        [string] $Comment,
        [string] $Wiki,
        [string] $Org,
        [string] $Project
    )

    $ctx = Resolve-AdoContext -Org $Org -Project $Project
    if ($ctx.error) { return (ConvertTo-AdoJson -InputObject $ctx) }

    $wikiInfo = Resolve-AdoWikiIdentifier -Wiki $Wiki -Context $ctx
    if ($wikiInfo.error) { return (ConvertTo-AdoJson -InputObject $wikiInfo) }
    $wikiId = $wikiInfo.wikiIdentifier

    $encodedPath = [Uri]::EscapeDataString($Path)
    $pageUri = "$($ctx.BaseUrl)/$($ctx.Project)/_apis/wiki/wikis/$wikiId/pages?path=$encodedPath&api-version=7.0"
    if ($Comment) {
        $pageUri += "&comment=$([Uri]::EscapeDataString($Comment))"
    }

    # Check if page exists to get ETag for update vs create
    $versionInfo = Get-AdoWikiPageVersion -Uri $pageUri -Headers $ctx.Headers
    if ($versionInfo.error) { return (ConvertTo-AdoJson -InputObject $versionInfo) }

    $headers = @{}
    foreach ($key in $ctx.Headers.Keys) { $headers[$key] = $ctx.Headers[$key] }

    $isUpdate = $versionInfo.exists
    if ($isUpdate -and $versionInfo.etag) {
        $headers['If-Match'] = $versionInfo.etag
    }

    $bodyJson = @{ content = $Content } | ConvertTo-Json -Depth 4

    try {
        $response = Invoke-RestMethod -Uri $pageUri -Headers $headers -Method PUT -Body $bodyJson -ErrorAction Stop
    } catch {
        $statusCode = 0
        try {
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
        } catch {}

        $hint = $null
        if ($statusCode -eq 401) { $hint = 'Run Connect-Ado to sign in again.' }
        if ($statusCode -eq 409) { $hint = 'Page was modified by another user. Retry the operation.' }

        return (ConvertTo-AdoJson -InputObject (New-AdoErrorObject -Code 'ApiRequestFailed' -Message $_.Exception.Message -Hint $hint -StatusCode $statusCode -Uri $pageUri))
    }

    $pageData = if ($response.page) { $response.page } else { $response }

    ConvertTo-AdoJson -InputObject ([ordered]@{
        context = [ordered]@{
            org     = $ctx.Org
            project = $ctx.Project
            wiki    = $wikiId
        }
        action = if ($isUpdate) { 'updated' } else { 'created' }
        page   = [ordered]@{
            path        = $pageData.path
            gitItemPath = $pageData.gitItemPath
            order       = $pageData.order
        }
    }) -Depth 6
}

function Remove-AdoWikiPage {
    <#
    .SYNOPSIS
        Delete a wiki page by path.
    .PARAMETER Comment
        Optional commit comment for the deletion.
    .EXAMPLE
        Remove-AdoWikiPage -Path '/Obsolete/OldPage'
        Remove-AdoWikiPage -Path '/Draft' -Comment 'Removing draft page'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [string] $Comment,
        [string] $Wiki,
        [string] $Org,
        [string] $Project
    )

    $ctx = Resolve-AdoContext -Org $Org -Project $Project
    if ($ctx.error) { return (ConvertTo-AdoJson -InputObject $ctx) }

    $wikiInfo = Resolve-AdoWikiIdentifier -Wiki $Wiki -Context $ctx
    if ($wikiInfo.error) { return (ConvertTo-AdoJson -InputObject $wikiInfo) }
    $wikiId = $wikiInfo.wikiIdentifier

    $encodedPath = [Uri]::EscapeDataString($Path)
    $uri = "$($ctx.BaseUrl)/$($ctx.Project)/_apis/wiki/wikis/$wikiId/pages?path=$encodedPath&api-version=7.0"
    if ($Comment) {
        $uri += "&comment=$([Uri]::EscapeDataString($Comment))"
    }

    $result = Invoke-AdoApi -Uri $uri -Headers $ctx.Headers -Method DELETE
    if ($result.error) { return (ConvertTo-AdoJson -InputObject $result) }

    ConvertTo-AdoJson -InputObject ([ordered]@{
        context = [ordered]@{
            org     = $ctx.Org
            project = $ctx.Project
            wiki    = $wikiId
        }
        deleted = $true
        path    = $Path
    }) -Depth 5
}

function Search-AdoWiki {
    <#
    .SYNOPSIS
        Full-text search across wiki pages. Uses the Azure DevOps Search API.
    .PARAMETER Query
        Search text (supports ADO search syntax: exact phrases, boolean operators).
    .PARAMETER Wiki
        Limit search to a specific wiki name. If omitted, searches all wikis.
    .PARAMETER Top
        Max results (default 20).
    .PARAMETER Skip
        Number of results to skip for pagination (default 0).
    .EXAMPLE
        Search-AdoWiki -Query 'deployment steps'
        Search-AdoWiki -Query '"connection string"' -Wiki 'MyProject.wiki' -Top 10
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Query,
        [string] $Wiki,
        [int] $Top = 20,
        [int] $Skip = 0,
        [string] $Org,
        [string] $Project
    )

    $ctx = Resolve-AdoContext -Org $Org -Project $Project
    if ($ctx.error) { return (ConvertTo-AdoJson -InputObject $ctx) }

    $searchUri = "https://almsearch.dev.azure.com/$($ctx.Org)/$($ctx.Project)/_apis/search/wikisearchresults?api-version=7.0"

    $body = [ordered]@{
        searchText = $Query
        '$top'     = $Top
        '$skip'    = $Skip
    }

    if ($Wiki) {
        $body.filters = @{ Wiki = @($Wiki) }
    }

    $raw = Invoke-AdoApi -Uri $searchUri -Headers $ctx.Headers -Method POST -Body $body
    if ($raw.error) { return (ConvertTo-AdoJson -InputObject $raw) }

    $results = @($raw.results | ForEach-Object {
        [ordered]@{
            wiki       = $_.wiki.name
            path       = $_.path
            fileName   = $_.fileName
            highlights = @($_.hits | ForEach-Object {
                [ordered]@{
                    field      = $_.fieldReferenceName
                    highlights = $_.highlights
                }
            })
        }
    })

    ConvertTo-AdoJson -InputObject ([ordered]@{
        context = [ordered]@{
            org     = $ctx.Org
            project = $ctx.Project
            query   = $Query
        }
        count   = $raw.count
        results = $results
    }) -Depth 8
}

Export-ModuleMember -Function @(
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
