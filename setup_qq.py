#!/usr/bin/env python3
"""Create a local QQ copy and install StickerBox's startup bridge."""
import argparse
import json
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile

from install_qq_bridge import install, QQ


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path('/Applications/QQ.app'))
    args = parser.parse_args()
    source = args.source.expanduser().resolve()
    package = source / 'Contents/Resources/app/package.json'
    if not package.is_file():
        raise RuntimeError('未找到 QQ 安装文件，请先安装 Mac QQ，或使用 --source 指定 QQ.app 路径。')
    if json.loads(package.read_text()).get('main') != './application.asar/app_launcher/index.js':
        raise RuntimeError('QQ 启动结构与已验证版本不同，未创建副本。')
    if QQ.exists():
        raise RuntimeError('QQ-debug.app 已存在，未覆盖。更新连接请使用 install_qq_bridge.py；重建前请退出副本并手动移走旧副本。')
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(source)], capture_output=True, check=True)
    raw = result.stdout if b'<?xml' in result.stdout else result.stderr
    start = raw.find(b'<?xml')
    if start < 0:
        raise RuntimeError('无法读取 QQ 原始权限，未创建副本。')
    permissions = plistlib.loads(raw[start:])
    permissions['com.apple.security.cs.disable-library-validation'] = True
    permissions['com.apple.security.network.server'] = True
    QQ.parent.mkdir(parents=True, exist_ok=True)
    # Stage outside the final app path, so an interrupted copy is not used as QQ-debug.
    with tempfile.TemporaryDirectory(prefix='stickerbox-setup-', dir=QQ.parent) as temp:
        staging = Path(temp) / 'QQ-debug.app'
        subprocess.run(['/usr/bin/ditto', str(source), str(staging)], check=True)
        entitlements = Path(temp) / 'entitlements.plist'
        entitlements.write_bytes(plistlib.dumps(permissions))
        subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(entitlements), str(staging)], check=True)
        staging.rename(QQ)
    try:
        install()
    except Exception:
        print('副本已创建，但连接安装失败。原版 QQ 未修改。请保留错误信息，退出副本后再运行 install_qq_bridge.py。')
        raise
    print('已创建：' + str(QQ))
    print('请打开此副本并登录自己的 QQ 账号，然后打开表情匣。')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        raise SystemExit('安装失败：' + str(error))
