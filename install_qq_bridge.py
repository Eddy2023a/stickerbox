#!/usr/bin/env python3
"""Install a startup bridge in the existing QQ debug copy; preserve permissions."""
import json
from pathlib import Path
import shutil
import secrets
import socket
import subprocess

ROOT = Path(__file__).resolve().parent
QQ = Path.home() / 'Library/Application Support/StickerBox/QQ-debug.app'


def install():
    app = QQ / 'Contents/Resources/app'
    package = app / 'package.json'
    config = json.loads(package.read_text())
    original = './application.asar/app_launcher/index.js'
    if config.get('main') not in (original, './stickerbox-launcher.js'):
        raise RuntimeError('QQ 启动文件版本不匹配，未修改。')
    backup = QQ.parent / 'repair-backup'
    backup.mkdir(parents=True, exist_ok=True)
    if not (backup / 'qq-package.json').exists():
        shutil.copy2(package, backup / 'qq-package.json')
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(QQ)], capture_output=True, check=True)
    xml = result.stdout
    start = xml.find(b'<?xml')
    if start < 0:
        raise RuntimeError('无法读取现有 QQ 权限，未修改。')
    entitlement = backup / 'qq-entitlements.plist'
    entitlement.write_bytes(xml[start:])
    connection = app / 'stickerbox-connection.json'
    if not connection.exists():
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        connection.write_text(json.dumps({'version': 3, 'baseUrl': 'http://127.0.0.1:' + str(port), 'token': secrets.token_hex(32), 'expiresAt': 0}))
        connection.chmod(0o600)
    old_package = package.read_bytes()
    try:
        shutil.copy2(ROOT / 'Resources/emoji-bridge.js', app / 'stickerbox-bridge.js')
        (app / 'stickerbox-launcher.js').write_text("require('./application.asar/app_launcher/index.js');\nrequire('./stickerbox-bridge.js');\n")
        config['main'] = './stickerbox-launcher.js'
        package.write_text(json.dumps(config, ensure_ascii=False, indent=2) + '\n')
        subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(entitlement), str(QQ)], check=True)
    except Exception:
        package.write_bytes(old_package)
        raise
    print('QQ 启动连接组件已更新，请退出并重新打开 QQ 调试副本。')


if __name__ == '__main__':
    install()
