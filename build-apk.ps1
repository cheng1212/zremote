# Detached APK build: survives Claude session restarts.
# Progress: D:\tools\zremote-new\gradle-direct.log (+ gradle-err.log)
# Done:     D:\tools\zremote-new\gradle-direct.done  (EXIT=0 / EXIT=1)
$log = 'D:\tools\zremote-new\gradle-direct.log'
$err = 'D:\tools\zremote-new\gradle-err.log'
Remove-Item 'D:\tools\zremote-new\gradle-direct.done', $log, $err -ErrorAction SilentlyContinue
$proc = Start-Process -FilePath 'D:\tools\zremote-new\android\gradlew.bat' `
  -ArgumentList 'assembleRelease', '--console=plain', '--stacktrace', '--no-daemon' `
  -WorkingDirectory 'D:\tools\zremote-new\android' `
  -WindowStyle Hidden -PassThru `
  -RedirectStandardOutput $log -RedirectStandardError $err
$proc.WaitForExit()
"EXIT=$($proc.ExitCode)" | Out-File 'D:\tools\zremote-new\gradle-direct.done' -Encoding ascii
