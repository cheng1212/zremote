# Detached APK build: survives Claude session restarts.
# Progress: D:\Workspace\zRemote\gradle-direct.log (+ gradle-err.log)
# Done:     D:\Workspace\zRemote\gradle-direct.done  (EXIT=0 / EXIT=1)
$log = 'D:\Workspace\zRemote\gradle-direct.log'
$err = 'D:\Workspace\zRemote\gradle-err.log'
Remove-Item 'D:\Workspace\zRemote\gradle-direct.done', $log, $err -ErrorAction SilentlyContinue
$proc = Start-Process -FilePath 'D:\Workspace\zRemote\android\gradlew.bat' `
  -ArgumentList 'assembleRelease', '--console=plain', '--stacktrace', '--no-daemon' `
  -WorkingDirectory 'D:\Workspace\zRemote\android' `
  -WindowStyle Hidden -PassThru `
  -RedirectStandardOutput $log -RedirectStandardError $err
$proc.WaitForExit()
"EXIT=$($proc.ExitCode)" | Out-File 'D:\Workspace\zRemote\gradle-direct.done' -Encoding ascii
