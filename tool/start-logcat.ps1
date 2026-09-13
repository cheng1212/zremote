# Detached logcat capture that survives Claude session teardown.
# Launch via WMI: Invoke-CimMethod Win32_Process Create powershell -File this.
$log = 'D:\tools\zremote-new\logs\logcat-live.log'
$err = 'D:\tools\zremote-new\logs\logcat-live.err.log'
"[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] capture started" | Out-File $log -Append -Encoding utf8
# flutter logs + crash buffer + ActivityManager (ANR lines) ; everything else silenced.
$filter = 'flutter:V AndroidRuntime:E ActivityManager:W ActivityManager:I DEBUG:E FATAL:E *:S'
cmd.exe /c "adb logcat -b main -b system -b crash -v time $filter >> `"$log`" 2>> `"$err`""
