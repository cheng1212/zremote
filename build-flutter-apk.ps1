# Detached FULL flutter APK build (gradlew alone skips Dart compilation!).
# Progress: D:\tools\zremote-new\flutter-build.log
# Done:     D:\tools\zremote-new\flutter-build.done
$flutter = (Get-Command flutter.bat -ErrorAction SilentlyContinue).Source
if (-not $flutter) { $flutter = "$env:USERPROFILE\flutter\bin\flutter.bat" }
$stdout = 'D:\tools\zremote-new\flutter-build.log'
$stderr = 'D:\tools\zremote-new\flutter-build.err.log'
Remove-Item 'D:\tools\zremote-new\flutter-build.done', $stdout, $stderr -ErrorAction SilentlyContinue
$proc = Start-Process -FilePath $flutter `
  -ArgumentList 'build', 'apk', '--release' `
  -WorkingDirectory 'D:\tools\zremote-new' `
  -WindowStyle Hidden -PassThru `
  -RedirectStandardOutput $stdout -RedirectStandardError $stderr
$proc.WaitForExit()
"EXIT=$($proc.ExitCode)" | Out-File 'D:\tools\zremote-new\flutter-build.done' -Encoding ascii
