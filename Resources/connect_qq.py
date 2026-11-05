#!/usr/bin/env python3
"""Connect to the bridge loaded by the QQ debug copy at startup."""
import fcntl
import json
from pathlib import Path
import subprocess
import sys
import time
import urllib.parse
import urllib.request

STATE = Path.home() / 'Library/Application Support/StickerBox'
QQ = STATE / 'QQ-debug.app'
CONFIG = QQ / 'Contents/Resources/app/stickerbox-connection.json'
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def ready():
    try:
        config = json.loads(CONFIG.read_text())
        url = urllib.parse.urlsplit(config['baseUrl'])
        if config.get('version', 0) < 3 or url.scheme != 'http' or url.hostname != '127.0.0.1' or not url.port or url.path or url.query or url.fragment or url.username:
            return None
        request = urllib.request.Request(config['baseUrl'] + '/health', headers={'Authorization': 'Bearer ' + config['token']})
        with OPENER.open(request, timeout=1) as response:
            health = json.load(response)
        return config if health.get('ok') and health.get('version', 0) >= 3 and health.get('loggedIn') is True else None
    except (OSError, ValueError, KeyError, TypeError):
        return None


def connect(timeout=35):
    config = ready()
    if config:
        return config
    if not QQ.exists():
        raise RuntimeError('QQ 调试副本缺失，请恢复安装后重试。')
    package = QQ / 'Contents/Resources/app/package.json'
    if json.loads(package.read_text()).get('main') != './stickerbox-launcher.js':
        raise RuntimeError('QQ 连接组件需要更新，请运行源码中的 install_qq_bridge.py。')
    subprocess.run(['/usr/bin/open', str(QQ)], check=True, timeout=8, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        config = ready()
        if config:
            return config
        time.sleep(0.25)
    raise RuntimeError('QQ 连接尚未就绪，请确认调试副本已登录；若已登录，请退出该副本再重新打开。')


def main():
    try:
        STATE.mkdir(parents=True, exist_ok=True)
        with (STATE / 'connection.lock').open('a') as lock:
            deadline = time.monotonic() + 40
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise RuntimeError('另一个 QQ 连接正在进行，请稍后重试。')
                    time.sleep(0.25)
            config = connect()
        print(json.dumps(config, ensure_ascii=False))
        return 0
    except Exception as error:
        print(json.dumps({'error': str(error)}, ensure_ascii=False))
        return 1


if __name__ == '__main__':
    sys.exit(main())
