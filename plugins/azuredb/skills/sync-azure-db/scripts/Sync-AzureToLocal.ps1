<#
.SYNOPSIS
    Sync an Azure SQL database down to a local SQL Server (schema + data) via a
    BACPAC export/import using SqlPackage. One-way: Azure -> Local.

.DESCRIPTION
    Non-interactive: every value comes in as a parameter so the calling agent can
    collect the details in chat and run this in one shot. No Read-Host prompts.

    On success the connection NAMES (not credentials) are saved to
    ~/.db-sync/config.json so the next run can pre-fill defaults.

    The local target database is DROPPED and rebuilt. This is gated by -AcceptDrop:
    the script refuses to drop unless -AcceptDrop is passed, so the caller must have
    already confirmed with the user.

.EXAMPLE
    Sync-AzureToLocal.ps1 -SourceServer portfolio.database.windows.net `
      -SourceDatabase portfolio-db -TargetInstance . -TargetDatabase StockDataScrapperNew `
      -AuthMode interactive -AcceptDrop

.EXAMPLE
    Sync-AzureToLocal.ps1 -SourceServer portfolio.database.windows.net `
      -SourceDatabase portfolio-db -TargetInstance . -TargetDatabase StockDataScrapperNew `
      -AuthMode password -SqlUser my_login -SqlPassword 'p@ss' -AcceptDrop
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$SourceServer,
    [Parameter(Mandatory)] [string]$SourceDatabase,
    [Parameter(Mandatory)] [string]$TargetInstance,
    [Parameter(Mandatory)] [string]$TargetDatabase,

    [ValidateSet('interactive','password')]
    [string]$AuthMode = 'interactive',
    [string]$SqlUser,
    [string]$SqlPassword,

    [string]$BacpacFolder = (Join-Path $env:USERPROFILE 'db-sync-bacpacs'),
    [switch]$AcceptDrop,
    [switch]$KeepBacpac,

    # Remember this DB. When set, the connection NAMES (no credentials) are upserted
    # into the JSON array at -ConfigPath after a successful import. Off by default so
    # reusing a saved DB (or declining to save a new one) writes nothing.
    [switch]$SaveConfig,
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.db-sync\config.json'),
    [string]$ConfigLabel
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
if (-not (Get-Command SqlPackage -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: SqlPackage not found on PATH. Install: dotnet tool install -g microsoft.sqlpackage" -ForegroundColor Red
    exit 2
}
if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: sqlcmd not found on PATH (needed to drop the local DB)." -ForegroundColor Red
    exit 2
}
if ($AuthMode -eq 'password' -and (-not $SqlUser -or -not $SqlPassword)) {
    Write-Host "ERROR: -AuthMode password requires -SqlUser and -SqlPassword." -ForegroundColor Red
    exit 2
}

# ---------------------------------------------------------------------------
# Export: Azure -> .bacpac
# ---------------------------------------------------------------------------
if (-not (Test-Path $BacpacFolder)) { New-Item -ItemType Directory -Path $BacpacFolder -Force | Out-Null }
$stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$bacpacPath = Join-Path $BacpacFolder "$($SourceDatabase)_$stamp.bacpac"

if ($AuthMode -eq 'interactive') {
    $connStr = "Server=tcp:$SourceServer,1433;Database=$SourceDatabase;Authentication=Active Directory Interactive;Encrypt=True;TrustServerCertificate=False;"
    $exportArgs = @("/Action:Export", "/SourceConnectionString:$connStr", "/TargetFile:$bacpacPath")
    Write-Host "Exporting '$SourceDatabase' via Entra ID interactive (a browser window will open)..." -ForegroundColor Green
}
else {
    $exportArgs = @(
        "/Action:Export"
        "/SourceServerName:$SourceServer"
        "/SourceDatabaseName:$SourceDatabase"
        "/SourceUser:$SqlUser"
        "/SourcePassword:$SqlPassword"
        "/TargetFile:$bacpacPath"
    )
    Write-Host "Exporting '$SourceDatabase' via SQL login ($SqlUser)..." -ForegroundColor Green
}

& SqlPackage @exportArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "EXPORT FAILED (exit $LASTEXITCODE). Common cause: Azure SQL firewall blocks your IP." -ForegroundColor Red
    Write-Host "Add your client IP in Azure portal -> SQL server -> Networking -> Firewall rules." -ForegroundColor Yellow
    exit 1
}
Write-Host "Export complete: $bacpacPath" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Import: .bacpac -> local (drop existing target, gated by -AcceptDrop)
# ---------------------------------------------------------------------------
if ($TargetInstance -match '^\(localdb\)') {
    $instanceShort = ($TargetInstance -replace '^\(localdb\)\\','')
    sqllocaldb start $instanceShort 2>$null | Out-Null
}

# Verify the local instance is reachable BEFORE trusting any query result against it.
# Otherwise a connection failure makes the existence check return no 'YES', and the
# script would silently skip the drop and fail later in import with a murkier error.
sqlcmd -S $TargetInstance -l 5 -Q "SELECT 1" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: cannot reach local SQL instance '$TargetInstance'. The .bacpac is kept at: $bacpacPath" -ForegroundColor Red
    exit 2
}

# Escape the database name for safe interpolation: double single quotes inside a
# 'string' literal, double ']' inside a [bracketed] identifier.
$tdbLiteral = $TargetDatabase -replace "'", "''"
$tdbBracket = $TargetDatabase -replace '\]', ']]'

$exists = sqlcmd -S $TargetInstance -h -1 -W -Q `
    "SET NOCOUNT ON; IF DB_ID('$tdbLiteral') IS NOT NULL PRINT 'YES' ELSE PRINT 'NO'" 2>$null
if ($exists -match 'YES') {
    if (-not $AcceptDrop) {
        Write-Host "REFUSED: local database '$TargetDatabase' exists and would be dropped, but -AcceptDrop was not passed." -ForegroundColor Red
        Write-Host "The exported .bacpac is kept at: $bacpacPath" -ForegroundColor Yellow
        exit 3
    }
    Write-Host "Dropping existing local database [$TargetDatabase]..." -ForegroundColor Yellow
    sqlcmd -S $TargetInstance -Q "ALTER DATABASE [$tdbBracket] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$tdbBracket];"
}

Write-Host "Importing into $TargetInstance / $TargetDatabase..." -ForegroundColor Cyan
& SqlPackage /Action:Import /SourceFile:$bacpacPath /TargetServerName:$TargetInstance /TargetDatabaseName:$TargetDatabase /TargetTrustServerCertificate:True
if ($LASTEXITCODE -ne 0) {
    Write-Host "IMPORT FAILED (exit $LASTEXITCODE). The .bacpac is kept at: $bacpacPath" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Save remembered names (no credentials) + cleanup
# ---------------------------------------------------------------------------
# Only when the caller opts in. The config file is a JSON ARRAY of saved DBs;
# this upserts the current one by its four connection names (the agent decides
# whether to save and which location to write — current dir, repo root, or the
# central ~/.db-sync/config.json default).
if ($SaveConfig) {
    $configDir = Split-Path -Parent $ConfigPath
    if ($configDir -and -not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    $list = @()
    if (Test-Path $ConfigPath) {
        $parsed = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        if ($parsed) { $list = @($parsed) }   # old single-object format -> 1-element array
    }

    # Upsert by the four connection names: drop any existing entry with the same
    # names (case-insensitive -eq), then append the current one. Filter-and-append
    # rather than in-place mutation, so an old entry missing the Name field can't
    # throw a "property cannot be found" on assignment.
    $list = @($list | Where-Object {
        -not (
            $_.SourceServer   -eq $SourceServer   -and $_.SourceDatabase -eq $SourceDatabase -and
            $_.TargetInstance -eq $TargetInstance -and $_.TargetDatabase -eq $TargetDatabase
        )
    })
    $list += [pscustomobject][ordered]@{
        Name           = $ConfigLabel
        SourceServer   = $SourceServer
        SourceDatabase = $SourceDatabase
        TargetInstance = $TargetInstance
        TargetDatabase = $TargetDatabase
        BacpacFolder   = $BacpacFolder
    }

    # -AsArray keeps the JSON an array even when there is a single element.
    @($list) | ConvertTo-Json -Depth 5 -AsArray | Set-Content -Path $ConfigPath -Encoding UTF8
}

if (-not $KeepBacpac) { Remove-Item $bacpacPath -Force -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host "SUCCESS: local DB '$TargetDatabase' on $TargetInstance now mirrors Azure '$SourceDatabase'." -ForegroundColor Green
if ($SaveConfig) { Write-Host "Saved connection names to $ConfigPath" -ForegroundColor DarkGray }
exit 0
