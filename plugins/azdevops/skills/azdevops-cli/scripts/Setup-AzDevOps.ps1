#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Interactive setup wizard for the AzDevOps module.
    Run this once to configure your organizations, projects, defaults, and Azure CLI-backed auth.

.EXAMPLE
    ./Setup-AzDevOps.ps1
#>

$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  AzDevOps Module - Interactive Setup" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

$modulePath = Join-Path $PSScriptRoot 'AzDevOps.psd1'
Import-Module $modulePath -Force

$orgs = @()

do {
    Write-Host "-- Organization Setup --" -ForegroundColor Yellow
    $orgName = Read-Host "  Organization name (for example, 'contoso')"

    Write-Host "  Enter project names (comma-separated):" -ForegroundColor DarkGray
    $projInput = Read-Host "  Projects"
    $projects = $projInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

    if (-not $projects -or $projects.Count -eq 0) {
        Write-Host "  At least one project is required." -ForegroundColor Red
        continue
    }

    $orgs += @{
        Name = $orgName
        Projects = $projects
    }

    Write-Host "  Added org '$orgName' with $($projects.Count) project(s)." -ForegroundColor Green
    Write-Host ""

    $more = Read-Host "Add another organization? [y/N]"
} while ($more -match '^[yY]')

if ($orgs.Count -eq 0) {
    throw "No organizations were configured."
}

Write-Host ""
Write-Host "-- Defaults --" -ForegroundColor Yellow
$defaultOrg = if ($orgs.Count -eq 1) {
    $orgs[0].Name
} else {
    $orgList = ($orgs | ForEach-Object { $_.Name }) -join ', '
    Read-Host "  Default organization [$orgList]"
}

$defaultOrgEntry = $orgs | Where-Object { $_.Name -eq $defaultOrg } | Select-Object -First 1
if (-not $defaultOrgEntry) {
    throw "Default organization '$defaultOrg' was not found in the configured org list."
}

$defaultProject = if ($defaultOrgEntry.Projects.Count -eq 1) {
    $defaultOrgEntry.Projects[0]
} else {
    $projList = $defaultOrgEntry.Projects -join ', '
    Read-Host "  Default project [$projList]"
}

$tenantId = Read-Host "  Preferred tenant ID (optional, press Enter to skip)"

Initialize-AdoConfig -Orgs $orgs -DefaultOrg $defaultOrg -DefaultProject $defaultProject -TenantId $tenantId

Write-Host ""
Write-Host "Setup complete." -ForegroundColor Green
Write-Host "  Config: ~/.azdevops/config.json" -ForegroundColor DarkGray
Write-Host "  Default: $defaultOrg / $defaultProject" -ForegroundColor DarkGray
if ($tenantId) {
    Write-Host "  Tenant preference: $tenantId" -ForegroundColor DarkGray
}

$connectNow = Read-Host "Connect now with Microsoft Entra interactive login? [Y/n]"
if (-not $connectNow -or $connectNow -match '^[yY]') {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Host "Azure CLI ('az') is required for Connect-Ado. Install it, then run Connect-Ado." -ForegroundColor Yellow
    } else {
        Connect-Ado
    }
}

Write-Host ""
Write-Host "Quick test:" -ForegroundColor Yellow
Write-Host "  Get-AdoOrgs" -ForegroundColor DarkGray
Write-Host "  Get-AdoSession" -ForegroundColor DarkGray
Write-Host "  Test-AdoConnection" -ForegroundColor DarkGray
Write-Host "  Get-AdoCurrentSprint" -ForegroundColor DarkGray
Write-Host "  Get-AdoCurrentSprint | claude 'summarize'" -ForegroundColor DarkGray
Write-Host ""
