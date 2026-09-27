@echo off
REM ── zremote Web 端 · 打包产物预览（手机可访问）──────────────────────
REM 双击即可。跑的是 **dist\ 的生产构建**（不是 dev），要看真打包结果用这个。
REM   Local:   http://localhost:4173
REM   Network: http://192.168.x.x:4173   ← 手机用这个
REM
REM 和 启动.bat 的区别：启动.bat 是 `npm run dev`（改代码即时热更，跑源码）；
REM 本脚本是 `vite preview`（先 build 再伺服 dist，验证压缩后/打包后的行为）。
REM 改了代码要重新 build 才会在这里生效。
REM
REM ⚠️ 局域网 http 属「非安全上下文」：Notification / Service Worker 不可用
REM    （通知与 PWA 装不了），聊天功能不受影响。要通知必须走 https。
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo === 先做一次生产构建 ===
call npm run build
if errorlevel 1 (
  echo.
  echo [失败] 构建没过，检查上面 vue-tsc / vite 的报错。
  pause
  exit /b 1
)
echo.
echo === 构建成功，伺服 dist\（Ctrl+C 停止）===
call npx vite preview --host 0.0.0.0 --port 4173
pause
