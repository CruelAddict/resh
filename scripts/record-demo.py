#!/usr/bin/env python3
"""Record the opt-in visible AppKit test; input is synthetic, not Accessibility.

Runs the native panel integration test with synthetic session data. No Rex
connection, clipboard, zoxide history or user configuration is needed.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path.home() / 'Movies/resh' /
                        f'config-demo-{datetime.datetime.now():%Y%m%d-%H%M%S}.mp4')
    parser.add_argument('--temp-dir', type=Path, default=Path(tempfile.gettempdir()))
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        raise RuntimeError(f'Refusing to overwrite {output}')
    devices = subprocess.run(['ffmpeg', '-hide_banner', '-f', 'avfoundation', '-list_devices', 'true', '-i', ''],
                             capture_output=True, text=True)
    screen = re.search(r'\[(\d+)\] Capture screen 0', devices.stderr)
    if not screen:
        raise RuntimeError('No macOS screen-capture device:\n' + devices.stderr)
    recorder = test = None
    with tempfile.TemporaryDirectory(prefix='resh-ui-demo-', dir=args.temp_dir) as temporary:
        fixture = Path(temporary)
        environment = dict(os.environ, RESH_UI_DEMO_ROOT=str(fixture))
        try:
            with (fixture / 'test.log').open('w') as log:
                test = subprocess.Popen(['swift', 'test', '--filter', 'nativePanelInputAndReuse'], cwd=ROOT,
                                        env=environment, stdout=log, stderr=subprocess.STDOUT)
                deadline = time.monotonic() + 120
                while not (fixture / 'ready.json').exists():
                    if test.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError((fixture / 'test.log').read_text())
                    time.sleep(0.05)
                ready = json.loads((fixture / 'ready.json').read_text())
                x, y, width, height = [round(v * ready['scale']) for v in ready['rect']]
                recording_started = time.monotonic()
                recorder = subprocess.Popen(['ffmpeg', '-hide_banner', '-loglevel', 'warning', '-nostdin',
                    '-f', 'avfoundation', '-framerate', '20', '-pixel_format', 'uyvy422', '-capture_cursor', '0', '-i', screen[1] + ':none',
                    '-vf', f'crop={width}:{height}:{x}:{y},scale=1280:-2', '-an', '-c:v', 'libx264',
                    '-preset', 'ultrafast', '-r', '20', '-fps_mode', 'cfr', '-pix_fmt', 'yuv420p', str(fixture / 'raw.mov')],
                                            stdout=subprocess.DEVNULL, stderr=log)
                deadline = time.monotonic() + 12
                while not (fixture / 'raw.mov').exists():
                    if recorder.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError('Screen recorder failed to start:\n' + (fixture / 'test.log').read_text())
                    time.sleep(0.05)
                time.sleep(0.5)
                (fixture / 'recording-ready').touch()
                deadline = time.monotonic() + 90
                while not (fixture / 'report.json').exists():
                    if test.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError('Visible test failed:\n' + (fixture / 'test.log').read_text())
                    time.sleep(0.05)
                demo_duration = time.monotonic() - recording_started
                recorder.send_signal(signal.SIGINT)
                recorder.wait(timeout=15)
                recorder = None
                (fixture / 'recording-stopped').touch()
                code = test.wait(timeout=15)
                if code != 0:
                    raise RuntimeError((fixture / 'test.log').read_text())
            if not (fixture / 'report.json').exists():
                raise RuntimeError('The visible test exited without its report:\n' + (fixture / 'test.log').read_text())
            report = json.loads((fixture / 'report.json').read_text())
            if not (fixture / 'raw.mov').exists():
                raise RuntimeError('No screen recording was produced:\n' + (fixture / 'test.log').read_text())
            output.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-i', str(fixture / 'raw.mov'),
                            '-t', str(round(demo_duration, 2)), '-an', '-vf', 'scale=1280:-2', '-c:v', 'libx264', '-crf', '20', '-pix_fmt', 'yuv420p',
                            '-movflags', '+faststart', str(output)], check=True)
            output.with_suffix('.json').write_text(json.dumps(report, indent=2))
            print(json.dumps({'video': str(output), 'report': str(output.with_suffix('.json')),
                              'input': report['input'], 'temporaryDataRemoved': True}, indent=2))
        finally:
            if test is not None and test.poll() is None:
                test.terminate()
                test.wait(timeout=10)
            if recorder is not None and recorder.poll() is None:
                recorder.send_signal(signal.SIGINT)
                recorder.wait(timeout=10)


if __name__ == '__main__':
    main()
