#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Scenario 6: User Account Modify

.DESCRIPTION
    Creates a test user, modifies the password, then deletes the user.
    Generates: USER_MODIFIED, PROCESS_CREATED, PROCESS_ENDED

    Useful for IAM event validation.

.PARAMETER Cycles
    Number of create/modify/delete cycles. Default: 10.

.EXAMPLE
    .\Test-UserAccountModify.ps1
    .\Test-UserAccountModify.ps1 -Cycles 25
#>

param(
    [int]$Cycles = 10
)

. "$PSScriptRoot\ScenarioHelpers.ps1"

Start-Scenario -Name "user_account_modify" `
    -Description "User create/modify/delete ($Cycles cycles)"

$savedEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"

$successCount = 0
$errorCount = 0

for ($i = 1; $i -le $Cycles; $i++) {
    $userName = "PerfTestUser_$i"
    Write-Host "  Cycle $i of $Cycles ($userName)..." -ForegroundColor Gray -NoNewline

    try {
        # Cleanup from previous failed run (ignore if user doesn't exist)
        cmd /c "net user $userName /delete" 2>$null | Out-Null

        # Create user
        cmd /c "net user $userName `"P@ssw0rd_Create_$i!`" /add" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to create user $userName (exit code $LASTEXITCODE)" }

        # Modify password
        cmd /c "net user $userName `"P@ssw0rd_Modified_$i!`" " 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to modify user $userName (exit code $LASTEXITCODE)" }

        # Delete user
        cmd /c "net user $userName /delete" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to delete user $userName (exit code $LASTEXITCODE)" }

        $successCount++
        Write-Host " OK" -ForegroundColor Green
    }
    catch {
        $errorCount++
        Write-Host " ERROR: $_" -ForegroundColor Red
        cmd /c "net user $userName /delete" 2>$null | Out-Null
    }

    Start-Sleep -Milliseconds 500
}

$ErrorActionPreference = $savedEAP

Add-ScenarioMetric -Key "cycles" -Value $Cycles
Add-ScenarioMetric -Key "success_count" -Value $successCount
Add-ScenarioMetric -Key "error_count" -Value $errorCount
Add-ScenarioMetric -Key "expected_events" -Value "USER_MODIFIED, PROCESS_CREATED, PROCESS_ENDED"
Add-ScenarioMetric -Key "estimated_user_events" -Value ($Cycles * 3)

Complete-Scenario
