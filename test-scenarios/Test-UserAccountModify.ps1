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

$successCount = 0

for ($i = 1; $i -le $Cycles; $i++) {
    $userName = "PerfTestUser_$i"
    Write-Host "  Cycle $i of $Cycles ($userName)..." -ForegroundColor Gray -NoNewline

    try {
        # Cleanup from previous failed run
        & net user $userName /delete 2>&1 | Out-Null

        # Create user
        & net user $userName "P@ssw0rd_Create_$i!" /add 2>&1 | Out-Null

        # Modify password
        & net user $userName "P@ssw0rd_Modified_$i!" 2>&1 | Out-Null

        # Delete user
        & net user $userName /delete 2>&1 | Out-Null

        $successCount++
        Write-Host " OK" -ForegroundColor Green
    }
    catch {
        Write-Host " ERROR: $_" -ForegroundColor Red
        & net user $userName /delete 2>&1 | Out-Null
    }

    Start-Sleep -Milliseconds 500
}

Add-ScenarioMetric -Key "cycles" -Value $Cycles
Add-ScenarioMetric -Key "success_count" -Value $successCount
Add-ScenarioMetric -Key "expected_events" -Value "USER_MODIFIED, PROCESS_CREATED, PROCESS_ENDED"
Add-ScenarioMetric -Key "estimated_user_events" -Value ($Cycles * 3)

Complete-Scenario
