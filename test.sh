#!/usr/bin/env bash
# 一条命令跑双绿门禁（analyze + test）。
# no_proxy 必须设：不设则代理拦截 flutter_tester 回连，测试全线假失败。
set -e
cd "$(dirname "$0")"
export no_proxy="localhost,127.0.0.1,::1" NO_PROXY="localhost,127.0.0.1,::1"
echo "== flutter analyze =="
flutter analyze
echo "== flutter test =="
flutter test
echo "== 双绿通过 =="
