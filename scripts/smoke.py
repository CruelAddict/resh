#!/usr/bin/env python3
"""Verify resident UI reuse and fresh snapshots without changing any Rex sessions."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', type=Path, default=Path.home() / 'Applications/resh.app/Contents/MacOS/resh')
    parser.add_argument('--reports', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    reports = args.reports or root / '.build/resident-check'
    reports.mkdir(parents=True, exist_ok=True)
    executable = str(args.executable.resolve())
    subprocess.run([executable, '--warmup'], check=True)
    pid = None
    timings = []
    with tempfile.TemporaryDirectory(prefix='resh-smoke-', dir=reports) as temporary:
        config = Path(temporary) / 'config.toml'
        config.touch()
        for index, titles in enumerate([['fresh-one'], [], ['fresh-two', 'fresh-three'], ['fresh-one']]):
            snapshot = [{'session_id': f'session:ui-only-{i}', 'label': title} for i, title in enumerate(titles)]
            output = reports / str(index)
            subprocess.run([executable, '--config', str(config), '--sessions-json', json.dumps(snapshot), '--smoke-test', str(output)], check=True)
            report = json.loads(output.with_suffix('.json').read_text())
            for key in ['visible', 'keyWindow', 'searchFocused', 'liveSessionSnapshot',
                        'frontmostApplicationPreserved', 'nonactivating', 'hidden', 'sessionDataClearedOnHide']:
                assert report[key], (key, report)
            assert report['initialSessionTitles'] == titles, report
            assert report['error'] is None, report
            pid = pid or report['pid']
            assert report['pid'] == pid, report
            status = json.loads(subprocess.check_output([executable, '--status']))
            assert status['running'] and not status['visible'] and status['pid'] == pid, status
            assert status['retainedSessions'] == status['retainedFolders'] == 0 and not status['query'], status
            timings.append(round(report['requestToPanelMs'], 2))
    print(json.dumps({'pid': pid, 'sameProcess': True, 'freshSnapshots': True,
                      'dataClearedOnHide': True, 'requestToPanelMs': timings}, indent=2))


if __name__ == '__main__':
    main()
