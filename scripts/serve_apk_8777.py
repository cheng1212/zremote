# -*- coding: utf-8 -*-
"""8777 APK 分发服务（带自动复活）。

python -m http.server 单次进程会莫名退出（2026-09-15 凌晨实测两次），
这里用 supervisor 循环：服务崩了 2 秒内自动重拉，日志走 stderr。
"""
import http.server
import socketserver
import functools
import time

DIR = r'D:\tools\zremote-new\build\app\outputs\flutter-apk'
PORT = 8777


def main():
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    handler = functools.partial(
        http.server.SimpleHTTPRequestHandler, directory=DIR
    )
    while True:
        try:
            with socketserver.ThreadingTCPServer(('0.0.0.0', PORT), handler) as httpd:
                print('serving %s on :%d' % (DIR, PORT), flush=True)
                httpd.serve_forever()
        except Exception as e:  # 崩了自动重拉
            print('server died: %r, restart in 2s' % (e,), flush=True)
            time.sleep(2)


if __name__ == '__main__':
    main()
