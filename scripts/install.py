#!/usr/bin/env python3
"""Install resh and connect its bundled action to Rex."""
import argparse
import json
import os
from pathlib import Path
import re
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
    source = ROOT / 'dist/resh'
    destination = home / 'Library/Application Support/resh'
    config = Path(os.environ.get('REX_CONFIG', Path(os.environ.get('XDG_CONFIG_HOME', home / '.config')) / 'rex/init.lua'))
    bundled_module = destination / 'resh.lua'
    rex = Path(os.environ.get('RESH_REX_BIN', home / 'Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex'))
    if not rex.is_file():
        raise RuntimeError('Rex CLI not found. Open Rex first or set RESH_REX_BIN.')
    if not args.skip_build:
        subprocess.run(['/bin/bash', str(ROOT / 'scripts/build.sh')], check=True)
    if not (source / 'resh').is_file():
        raise RuntimeError('Build the helper first: bash scripts/build.sh')
    if not (source / 'resh.lua').is_file() or not (source / 'resh_Resh.bundle').is_dir():
        raise RuntimeError('The helper is missing its bundled Lua resources; rebuild it.')
    clients = json.loads(subprocess.check_output([str(rex), '--autostart=false', 'client', 'list', '--json']))
    apps = [client for client in clients.get('clients', [])
            if client.get('info', {}).get('kind') == 'app' and client.get('info', {}).get('platform') == 'macos']
    if not apps:
        raise RuntimeError('Open the Rex app before installing; its keymap must be refreshed too.')
    executable = source / 'resh'
    subprocess.run([str(executable), '--quit'], check=True, stdout=subprocess.DEVNULL, timeout=10)
    destination.mkdir(parents=True, exist_ok=True)
    # Runtime state lives here too. Replace only the distribution's files, never
    # sessions.json or the user's config, and do not retain old installations.
    for entry in source.iterdir():
        target = destination / entry.name
        if entry.is_dir():
            if target.exists():
                shutil.rmtree(target)
            shutil.copytree(entry, target)
        else:
            temporary = destination / ('.' + entry.name + '.install')
            shutil.copy2(entry, temporary)
            temporary.replace(target)
    original = config.read_bytes() if config.exists() else None
    text = (original or b'').decode('utf-8')
    def lua_string(value):
        return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'

    integration = f'dofile({lua_string(bundled_module)})'
    loads = re.findall(r'\bdofile\s*\(([^)\n]*)\)', text)
    if not any('/resh.lua' in argument for argument in loads):
        text = text.rstrip() + '\n\n' + integration + '\n' if text else integration + '\n'
    # Keep the user's startup arguments in Rex's config, not in resh settings.
    # In particular, never append a default start beside an existing custom one.
    starts = re.findall(r'^[ \t]*rex\.exec\.start\s*\(\s*\{([^}]*)\}', text, re.DOTALL | re.MULTILINE)
    if not any('resh' in arguments and re.search(r'''["']--start["']''', arguments)
               for arguments in starts):
        text = text.rstrip() + '\n' + (
            f'rex.exec.start({{ {lua_string(destination / "resh")}, "--start" }},\n'
            '  { detach = true, stdout = false, stderr = false })\n')
    changed = text != (original or b'').decode('utf-8')
    if changed:
        config.parent.mkdir(parents=True, exist_ok=True)
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
    # Reload above executes the startup command with the user's own arguments.
    # Do not start again here with defaults and overwrite a custom --config.
    installed_executable = destination / 'resh'
    for _ in range(150):
        status = json.loads(subprocess.check_output([str(installed_executable), '--status'], timeout=5))
        if status.get('running') and not status.get('stopping'):
            break
        time.sleep(0.02)
    else:
        raise RuntimeError("The startup command in Rex's init.lua did not start resh. Check that command.")
    print(f'Installed: {destination}')
    print(f'Rex integration: {bundled_module} ({config})')
    print('Rex Server → Remote Control must be enabled for session switching.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'resh install: {error}', file=sys.stderr)
        sys.exit(1)
