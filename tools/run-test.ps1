# Unattended vayu test run (patch 0171). Run from platform-tools with the phone in fastboot:
#   powershell -ExecutionPolicy Bypass -File .\run-test.ps1 vayu-xxx-testNN.img
# 1. fastboot boot IMAGE: boots it from RAM only, nothing is flashed.
# 2. The image plays a fixed swipe script (vayuautotest), then its watchdog (flamereboot) resets the phone into fastboot.
# 3. Waits for fastboot, boots OrangeFox from RAM, reads the last 4 MiB of userdata (read-only dd), then reboots to fastboot.
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
# Same read as getlog.ps1, but the adb server is started first (a cold start made wait-for-recovery return at once)
# and OrangeFox is then told to reboot into fastboot, ready for the next run.
Remove-Item -ErrorAction SilentlyContinue .\sweetlog.bin
.\adb.exe start-server | Out-Null
.\fastboot.exe boot recovery.img
if ($LASTEXITCODE -ne 0) { Write-Host "FAILED: fastboot boot recovery.img"; exit 1 }
$deadline = (Get-Date).AddSeconds(120)
do {
    Start-Sleep -Seconds 3
    $up = (.\adb.exe devices) -match 'recovery'
} until ($up -or (Get-Date) -gt $deadline)
if (-not $up) { Write-Host "FAILED: OrangeFox did not show up in adb. Run getlog.ps1 once it has booted."; exit 1 }
Start-Sleep -Seconds 3
.\adb.exe shell 'd=$(readlink -f /dev/block/by-name/userdata); s=$(cat /sys/class/block/${d##*/}/size); dd if=$d of=/tmp/sweetlog.bin bs=4096 skip=$(( s/8 - 1025 )) count=1025'
.\adb.exe pull /tmp/sweetlog.bin
if ((Test-Path .\sweetlog.bin) -and ((Get-Item .\sweetlog.bin).Length -eq 4198400)) {
    .\adb.exe reboot bootloader
    Write-Host "log ready (phone is rebooting into fastboot)"
} else { Write-Host "FAILED: no sweetlog.bin pulled (OrangeFox stays up; run getlog.ps1)" }
