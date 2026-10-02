# Detached FULL flutter APK build (gradlew alone skips Dart compilation!).
# Progress: D:\Workspace\zRemote\flutter-build.log
# Done:     D:\Workspace\zRemote\flutter-build.done
$flutter = (Get-Command flutter.bat -ErrorAction SilentlyContinue).Source
if (-not $flutter) { $flutter = "$env:USERPROFILE\flutter\bin\flutter.bat" }
$stdout = 'D:\Workspace\zRemote\flutter-build.log'
$stderr = 'D:\Workspace\zRemote\flutter-build.err.log'
Remove-Item 'D:\Workspace\zRemote\flutter-build.done', $stdout, $stderr -ErrorAction SilentlyContinue
$proc = Start-Process -FilePath $flutter `
  -ArgumentList 'build', 'apk', '--release' `
  -WorkingDirectory 'D:\Workspace\zRemote' `
  -WindowStyle Hidden -PassThru `
  -RedirectStandardOutput $stdout -RedirectStandardError $stderr
$proc.WaitForExit()
"EXIT=$($proc.ExitCode)" | Out-File 'D:\Workspace\zRemote\flutter-build.done' -Encoding ascii
