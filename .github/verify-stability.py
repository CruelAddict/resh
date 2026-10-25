"""One-off verification; this file is not part of the CI pull request."""

import collections
import json
import os
from pathlib import Path
import statistics
import subprocess
import time


root = Path(os.environ["RUNNER_TEMP"]) / "resh-stability-results"
root.mkdir(exist_ok=False)


def command(*args):
    return subprocess.check_output(args, text=True).strip()


metadata = {
    "commit": command("git", "rev-parse", "HEAD"),
    "trees": {name: command("git", "rev-parse", "HEAD:" + name)
              for name in ["Sources", "Tests", "Package.swift", "Package.resolved"]},
    "architecture": command("uname", "-m"),
    "macos": command("sw_vers"),
    "cpus": command("sysctl", "-n", "hw.ncpu"),
    "xcode": command("xcodebuild", "-version"),
    "swift": command("swift", "--version"),
}
(root / "environment.json").write_text(json.dumps(metadata, indent=2))
print(json.dumps(metadata), flush=True)


def processes():
    result = {}
    for row in command("ps", "-axo", "pid=,ppid=,stat=,command=").splitlines():
        fields = row.strip().split(None, 3)
        if len(fields) == 4:
            result[int(fields[0])] = {"parent": int(fields[1]), "state": fields[2], "command": fields[3]}
    return result


required = ["returnsNewLinesWithoutWaitingForPipeEOF", "snapshotRecoversAfterDisconnect",
            "numberedShortcutsSkipTheCurrentSession", "cancellationStopsTheProcess",
            "reloadsSourcesKeysAndProjectsWithoutRestarting", "compositeSourcesKeepFreshSessionsAvailable"]
results = []
requested_runs = int(os.environ.get("STRESS_RUNS", "100"))
sample_after = float(os.environ.get("STRESS_SAMPLE_AFTER", "0"))
series_started = time.monotonic()
for index in range(1, requested_runs + 1):
    run = root / f"{index:03d}"
    run.mkdir()
    temporary = run / "tmp"
    temporary.mkdir()
    env = os.environ.copy()
    env["TMPDIR"] = str(temporary) + "/"
    args = ["swift", "test", "--skip-build", "--event-stream-output-path", str(run / "events.jsonl"),
            "--event-stream-version", "0"]
    (run / "invocation.json").write_text(json.dumps({"command": args, "TMPDIR": env["TMPDIR"]}, indent=2))
    seen = {}
    samples = []
    sampled = set()
    samplers = []
    timed_out = False
    started = time.monotonic()
    with (run / "output.log").open("w") as output:
        child = subprocess.Popen(args, env=env, stdout=output, stderr=subprocess.STDOUT)
        while child.poll() is None:
            current = processes()
            descendants = {child.pid}
            while True:
                extended = descendants | {pid for pid, info in current.items() if info["parent"] in descendants}
                if extended == descendants:
                    break
                descendants = extended
            snapshot = {pid: info for pid, info in current.items()
                        if pid in descendants - {child.pid} or str(temporary) in info["command"]}
            seen.update(snapshot)
            samples.append({"elapsed": round(time.monotonic() - started, 3), "processes": snapshot})
            if sample_after and time.monotonic() - started > sample_after:
                for pid, info in snapshot.items():
                    if pid not in sampled and "reshPackageTests" in info["command"]:
                        sampled.add(pid)
                        samplers.append(subprocess.Popen(["sample", str(pid), "1", "10", "-file",
                                                          str(run / f"sample-{pid}.txt")],
                                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            if time.monotonic() - started > 60:
                timed_out = True
                child.kill()
                break
            time.sleep(.05)
        code = child.wait()
    for sampler in samplers:
        sampler.wait(timeout=10)
    elapsed = time.monotonic() - started

    def survivors():
        return {pid: info for pid, info in processes().items()
                if (pid in seen and info["command"] == seen[pid]["command"])
                or str(temporary) in info["command"]}

    time.sleep(.25)
    remaining = at_250ms = survivors()
    deadline = time.monotonic() + 3
    while remaining and time.monotonic() < deadline:
        time.sleep(.1)
        remaining = survivors()
    (run / "processes.json").write_text(json.dumps({"seen": seen, "samples": samples, "at_250ms": at_250ms,
                                                   "after_grace": remaining}, indent=2))
    events = []
    events_path = run / "events.jsonl"
    if events_path.exists():
        events = [json.loads(row)["payload"] for row in events_path.read_text().splitlines()
                  if row.strip() and json.loads(row).get("kind") == "event"]
    kinds = collections.Counter(event["kind"] for event in events)
    names = {event.get("testID", "") for event in events if event["kind"] == "testStarted"}
    complete = (kinds["runEnded"] == 1 and kinds["testStarted"] >= 70
                and kinds["testStarted"] == kinds["testEnded"]
                and all(any(name in identity for identity in names) for name in required))
    passed = code == 0 and complete and kinds["issueRecorded"] == 0 and not remaining and not timed_out
    result = {"run": index, "passed": passed, "exit_code": code, "seconds": round(elapsed, 3),
              "events": dict(kinds), "complete": complete, "survivors": remaining, "timed_out": timed_out}
    results.append(result)
    (root / "results.json").write_text(json.dumps(results, indent=2))
    print(json.dumps(result), flush=True)
    if not passed:
        print((run / "output.log").read_text(), flush=True)
        break

summary = {"runs": len(results), "requested_runs": requested_runs, "sample_after": sample_after,
           "passed": sum(result["passed"] for result in results),
           "failed": sum(not result["passed"] for result in results),
           "median_seconds": statistics.median(result["seconds"] for result in results),
           "min_seconds": min(result["seconds"] for result in results),
           "max_seconds": max(result["seconds"] for result in results),
           "series_seconds": round(time.monotonic() - series_started, 3)}
(root / "summary.json").write_text(json.dumps(summary, indent=2))
print(json.dumps(summary), flush=True)
raise SystemExit(0 if summary["runs"] == requested_runs and summary["failed"] == 0 else 1)
