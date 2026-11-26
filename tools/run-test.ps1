# Unattended vayu test run (patch 0171). Run from platform-tools with the phone in fastboot:
#   powershell -ExecutionPolicy Bypass -File .\run-test.ps1 vayu-xxx-testNN.img
# 1. fastboot boot IMAGE: boots it from RAM only, nothing is flashed.
# 2. The image plays a fixed swipe script (vayuautotest), then its watchdog (flamereboot) resets the phone into fastboot.
# 3. Waits for fastboot, then runs getlog.ps1 (boots OrangeFox from RAM, reads the last 4 MiB of userdata).
# Writes no partition. If the phone does not come back, hold Volume Down + Power for fastboot and run getlog.ps1.
param([Parameter(Mandatory = $true)][string]$Image, [int]$TimeoutMin = 8)
Set-Location $PSScriptRoot
.\fastboot.exe boot $Image
if ($LASTEXITCODE -ne 0) { Write-Host "FAILED: fastboot boot (is the phone in fastboot? is OpenTabletDriver closed?)"; exit 1 }
Write-Host "Booted. Hands off the screen: the test plays by itself and the phone returns to fastboot in about 3 min."
Start-Sleep -Seconds 60
$deadline = (Get-Date).AddMinutes($TimeoutMin)
do {
    Start-Sleep -Seconds 5
    $seen = (.\fastboot.exe devices) -match 'fastboot'
} until ($seen -or (Get-Date) -gt $deadline)
if (-not $seen) { Write-Host "FAILED: phone did not return to fastboot. Hold Volume Down + Power, then run getlog.ps1."; exit 1 }
Write-Host "Back in fastboot, pulling the log."
& .\getlog.ps1
