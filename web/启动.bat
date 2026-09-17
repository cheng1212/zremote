@echo off
REM ── zremote Web 端 · 一键启动（手机可访问）──────────────────────────
REM 双击即可。--host 让它监听 0.0.0.0，手机才能用局域网 IP 打开。
REM 启动后终端会打印两个地址：
REM   Local:   http://localhost:5173
REM   Network: http://192.168.x.x:5173   ← 手机用这个
REM
REM ⚠️ 注意：局域网 http 属于「非安全上下文」，浏览器会禁用
REM    Notification / Service Worker（通知与 PWA 装不了）。
REM    聊天功能不受影响。要通知能力必须走 https（自签证书或公网部署）。
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo === zremote Web 端启动中 ===
echo.
call npm run dev -- --host
pause
