# Watch for device online -> auto install latest APK -> re-arm logcat capture.
# Runs detached from any Claude session. Progress: logs\install-watch.log
$log = 'D:\tools\zremote-new\logs\install-watch.log'
$apk = 'D:\tools\zremote-new\build\app\outputs\flutter-apk\app-release.apk'
$deadline = (Get-Date).AddMinutes(30)
"[$(Get-Date -Format 'HH:mm:ss')] watch started (max 30 min)" | Out-File $log -Append -Encoding utf8
while ((Get-Date) -lt $deadline) {
    $out = adb devices 2>$null | Out-String
    if ($out -match '\tdevice\s*$') {
        "[$(Get-Date -Format 'HH:mm:ss')] device online, installing" | Out-File $log -Append -Encoding utf8
        adb install -r $apk *>> $log
        "[$(Get-Date -Format 'HH:mm:ss')] install finished" | Out-File $log -Append -Encoding utf8
        # Clear old buffer so post-install logs start clean.
        cmd.exe /c 'adb logcat -c' 2>$null
        Start-Process -FilePath cmd.exe -ArgumentList '/c adb logcat -b main -b crash -v time flutter:V AndroidRuntime:E DEBUG:E FATAL:E *:S >> D:\tools\zremote-new\logs\logcat-live.log 2>&1' -WindowStyle Hidden
        "[$(Get-Date -Format 'HH:mm:ss')] logcat capture re-armed" | Out-File $log -Append -Encoding utf8
        break
    }
    Start-Sleep -Seconds 5
}
