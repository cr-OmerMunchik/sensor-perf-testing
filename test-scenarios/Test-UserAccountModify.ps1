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
        Remove-LocalUser -Name $userName -ErrorAction SilentlyContinue

        $secPwd = ConvertTo-SecureString "P@ssw0rd_Create_${i}!" -AsPlainText -Force
        New-LocalUser -Name $userName -Password $secPwd -FullName "PerfTest User $i" `
            -Description "Perf test temporary account" -AccountNeverExpires `
            -PasswordNeverExpires -ErrorAction Stop | Out-Null

        $newPwd = ConvertTo-SecureString "P@ssw0rd_Modified_${i}!" -AsPlainText -Force
        Set-LocalUser -Name $userName -Password $newPwd -ErrorAction Stop

        Remove-LocalUser -Name $userName -ErrorAction Stop

        $successCount++
        Write-Host " OK" -ForegroundColor Green
    }
    catch {
        $errorCount++
        Write-Host " ERROR: $_" -ForegroundColor Red
        Remove-LocalUser -Name $userName -ErrorAction SilentlyContinue
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
