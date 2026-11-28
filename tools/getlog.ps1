# Pull the iOS kernel log from the phone (read-only). Run from platform-tools
# with the phone in fastboot (bootloader): powershell -ExecutionPolicy Bypass -File .\getlog.ps1
# Boots OrangeFox from RAM (nothing flashed), reads the last 4 MiB of userdata.
Remove-Item -ErrorAction SilentlyContinue .\sweetlog.bin
.\fastboot.exe boot recovery.img
if ($LASTEXITCODE -ne 0) { Write-Host "FAILED: fastboot boot (is the phone in fastboot?)"; exit 1 }
.\adb.exe wait-for-recovery
Start-Sleep -Seconds 3
.\adb.exe shell 'd=$(readlink -f /dev/block/by-name/userdata); s=$(cat /sys/class/block/${d##*/}/size); dd if=$d of=/tmp/sweetlog.bin bs=4096 skip=$(( s/8 - 1025 )) count=1025'
.\adb.exe pull /tmp/sweetlog.bin
if ((Test-Path .\sweetlog.bin) -and ((Get-Item .\sweetlog.bin).Length -eq 4198400)) { Write-Host "log ready" } else { Write-Host "FAILED: no sweetlog.bin pulled" }
