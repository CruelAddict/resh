#!/usr/bin/env python3
"""Install resh locally, preserving Rex config and rolling back invalid Lua changes."""
import argparse
import datetime
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
MARKER = '-- resh: native project picker (managed by resh)'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-build', action='store_true')
    args = parser.parse_args()
    home = Path.home()
    source = ROOT / 'dist/resh.app'
    destination = home / 'Applications/resh.app'
    config = Path(os.environ.get('REX_CONFIG', Path(os.environ.get('XDG_CONFIG_HOME', home / '.config')) / 'rex/init.lua'))
    module = config.parent / 'resh.lua'
    rex = Path(os.environ.get('RESH_REX_BIN', home / 'Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex'))
    if not rex.is_file():
        raise RuntimeError('Rex CLI not found. Open Rex first or set RESH_REX_BIN.')
    if not args.skip_build:
        subprocess.run(['/bin/bash', str(ROOT / 'scripts/build.sh')], check=True)
    if not source.is_dir():
        raise RuntimeError('Build the app first: bash scripts/build.sh')
    if destination.exists():
        with (destination / 'Contents/Info.plist').open('rb') as file:
            if plistlib.load(file).get('CFBundleIdentifier') != 'io.github.CruelAddict.resh':
                raise RuntimeError(f'Refusing to replace an unrelated app: {destination}')
    backup = home / 'Library/Application Support/resh/backups' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    backup.mkdir(parents=True)
    original = {path: path.read_bytes() if path.exists() else None for path in (config, module)}
    for path, data in original.items():
        if data is not None:
            shutil.copy2(path, backup / path.name)
    # Keep the previous app too, so upgrades are reversible.
    if destination.exists():
        shutil.copytree(destination, backup / 'resh.app')
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination, dirs_exist_ok=True)
    config.parent.mkdir(parents=True, exist_ok=True)
    try:
        module.write_bytes((ROOT / 'integration/resh.lua').read_bytes())
        text = (original[config] or b'').decode('utf-8')
        if MARKER not in text:
            # dofile is absolute and also works when REX_CONFIG is outside ~/.config/rex.
            escaped = str(module).replace('\\', '\\\\').replace('"', '\\"')
            text = text.rstrip() + f'\n\n{MARKER}\ndofile("{escaped}")\n'
            config.write_text(text.lstrip('\n'))
        subprocess.run([str(rex), '--autostart=false', 'config', 'check', str(config)], check=True)
        subprocess.run([str(rex), '--autostart=false', 'config', 'reload'], check=True)
    except Exception:
        for path, data in original.items():
            if data is None:
                path.unlink(missing_ok=True)
            else:
                path.write_bytes(data)
        raise
    print(f'Installed: {destination}')
    print(f'Rex binding: Cmd+S → resh ({config})')
    print(f'Backup: {backup}')
    print('Rex Server → Remote Control must be enabled for session switching.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'resh install: {error}', file=sys.stderr)
        sys.exit(1)
