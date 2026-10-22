#!/usr/bin/env python3
"""Install resh and connect its bundled action to Rex."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-build', action='store_true')
    args = parser.parse_args()
    home = Path.home()
    source = ROOT / 'dist/resh.app'
    destination = home / 'Applications/resh.app'
    config = Path(os.environ.get('REX_CONFIG', Path(os.environ.get('XDG_CONFIG_HOME', home / '.config')) / 'rex/init.lua'))
    bundled_module = destination / 'Contents/Resources/resh.lua'
    rex = Path(os.environ.get('RESH_REX_BIN', home / 'Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex'))
    if not rex.is_file():
        raise RuntimeError('Rex CLI not found. Open Rex first or set RESH_REX_BIN.')
    if not args.skip_build:
        subprocess.run(['/bin/bash', str(ROOT / 'scripts/build.sh')], check=True)
    if not source.is_dir():
        raise RuntimeError('Build the app first: bash scripts/build.sh')
    if not (source / 'Contents/Resources/resh.lua').is_file():
        raise RuntimeError('The app is missing its bundled Rex integration; rebuild it.')
    if destination.exists():
        with (destination / 'Contents/Info.plist').open('rb') as file:
            if plistlib.load(file).get('CFBundleIdentifier') != 'io.github.CruelAddict.resh':
                raise RuntimeError(f'Refusing to replace an unrelated app: {destination}')
    clients = json.loads(subprocess.check_output([str(rex), '--autostart=false', 'client', 'list', '--json']))
    apps = [client for client in clients.get('clients', [])
            if client.get('info', {}).get('kind') == 'app' and client.get('info', {}).get('platform') == 'macos']
    if not apps:
        raise RuntimeError('Open the Rex app before installing; its keymap must be refreshed too.')
    executable = source / 'Contents/MacOS/resh'
    subprocess.run([str(executable), '--quit'], check=True, stdout=subprocess.DEVNULL, timeout=5)
    for _ in range(100):
        status = json.loads(subprocess.check_output([str(executable), '--status'], timeout=5))
        if not status.get('running'):
            break
        time.sleep(0.02)
    else:
        raise RuntimeError('The resh helper did not stop; installation cancelled.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination)
    original = config.read_bytes() if config.exists() else None
    text = (original or b'').decode('utf-8')
    escaped = str(bundled_module).replace('\\', '\\\\').replace('"', '\\"')
    integration = f'dofile("{escaped}")'
    changed = integration not in text.splitlines()
    if changed:
        config.parent.mkdir(parents=True, exist_ok=True)
        text = text.rstrip() + '\n\n' + integration + '\n' if text else integration + '\n'
        config.write_text(text)
    try:
        subprocess.run([str(rex), '--autostart=false', 'config', 'check', str(config)], check=True)
    except Exception:
        if changed:
            if original is None:
                config.unlink()
            else:
                config.write_bytes(original)
        raise
    for client in apps:
        subprocess.run([str(rex), '--autostart=false', '-C', client['client_id'], 'do', 'client.config.reload'], check=True)
    subprocess.run([str(destination / 'Contents/MacOS/resh'), '--warmup'], check=True, timeout=10)
    print(f'Installed: {destination}')
    print(f'Rex integration: {bundled_module} ({config})')
    print('Rex Server → Remote Control must be enabled for session switching.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'resh install: {error}', file=sys.stderr)
        sys.exit(1)
