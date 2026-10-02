"""Independent test-only manager. Never invokes launchctl or systemctl."""

import json
import os
import pathlib
import plistlib
import shlex
import signal
import subprocess
import sys
import time

root, platform, program, *args = sys.argv[1:]
root = pathlib.Path(root)
state_path = root / "fake-manager.json"
state = json.loads(state_path.read_text()) if state_path.exists() else {}


def save():
    state_path.write_text(json.dumps(state))


def barrier(phase):
    marker = root / ("pause-" + phase)
    if program == "test-cleanup" or not marker.exists():
        return
    marker.unlink()
    subprocess.Popen(
        [
            sys.executable,
            "-c",
            "import pathlib,time,sys; r=pathlib.Path(sys.argv[1]); "
            "exec(\"while not (r/'release').exists(): time.sleep(.01)\"); "
            "(r/'late-publication').write_text('unsafe')",
            str(root),
        ],
    )
    (root / "entered").write_text(phase)
    time.sleep(60)


def alive():
    pid = state.get("pid", 0)
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        proc = pathlib.Path(f"/proc/{pid}/stat")
        return not (proc.exists() and proc.read_text().split(") ", 1)[1][0] == "Z")
    except (ProcessLookupError, FileNotFoundError):
        # Linux may reap the process between the procfs existence check and read.
        return False


def start():
    if alive():
        return
    if (root / "fail-all-starts").exists():
        sys.exit(1)
    failure = root / "fail-start-once"
    if failure.exists():
        failure.unlink()
        sys.exit(1)
    if (root / "success-without-daemon").exists():
        return
    if (root / "pause-readiness-pending").exists():
        state["pause_inspect"] = "readiness-pending"
        save()
        return
    path = pathlib.Path(state["path"])
    if platform == "launchd":
        job = plistlib.loads(path.read_bytes())
        argv = job["ProgramArguments"]
        env = dict(os.environ, **job["EnvironmentVariables"])
        assert not job["KeepAlive"] and job["RunAtLoad"]
    else:
        lines = dict(
            line.split("=", 1) for line in path.read_text().splitlines() if "=" in line
        )
        assert lines["ExecStart"].startswith(":")
        argv = shlex.split(lines["ExecStart"][1:].replace("%%", "%"))
        assert not any(c in argv[0] for c in "\"'\\"), (
            "systemd string_is_safe rejects executable"
        )
        env = dict(os.environ)
        env.update(
            v.split("=", 1)
            for v in shlex.split(lines["Environment"].replace("%%", "%"))
        )
        assert lines["Restart"] == "no"
    child = subprocess.Popen(
        argv,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    state["pid"] = child.pid
    if (root / "pause-readiness-ready").exists():
        state["pause_inspect"] = "readiness-ready"
    save()


def stop():
    replacement = root / "replace-stop-pid"
    if program != "test-cleanup" and replacement.exists():
        state["pid"] = int(replacement.read_text())
        replacement.unlink()
        save()
        sys.exit(1)
    barrier("pre-stop")
    failure = root / "fail-stop-once"
    if failure.exists():
        failure.unlink()
        sys.exit(1)
    if alive():
        os.kill(state["pid"], signal.SIGTERM)
        deadline = time.monotonic() + 5
        while alive() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert not alive(), "test daemon failed to stop"
    state["pid"] = 0
    save()
    barrier("post-stop")
    failure = root / "fail-after-stop-once"
    if failure.exists():
        failure.unlink()
        sys.exit(1)


with (root / "manager-calls.jsonl").open("a") as f:
    f.write(json.dumps([program, *args]) + "\n")
if program == "test-cleanup":
    stop()
    sys.exit(0)
if state.get("pause_inspect") and any(a in args for a in ("show", "print-disabled")):
    phase = state.pop("pause_inspect")
    save()
    barrier(phase)
if (root / "manager-denied").exists():
    print("Access denied", file=sys.stderr)
    sys.exit(1)
if platform == "launchd":
    assert program == "/bin/launchctl"
    command = args[0]
    if command == "print-disabled":
        print(
            'disabled services = {\n"org.zc.user" => '
            + ("true" if state.get("disabled") else "false")
            + "\n}"
        )
    elif command == "print":
        if not state.get("loaded"):
            print('Could not find service "org.zc.user" in domain', file=sys.stderr)
            sys.exit(113)
        print("path = " + state["path"])
        job = plistlib.loads(pathlib.Path(state["path"]).read_bytes())
        print("program = " + job["ProgramArguments"][0])
        print("arguments = {\n" + "\n".join(job["ProgramArguments"]) + "\n}")
        if alive():
            print("pid = " + str(state["pid"]))
    elif command in ("enable", "disable"):
        state["disabled"] = command == "disable"
    elif command == "bootstrap":
        assert not state.get("disabled"), "disabled jobs cannot bootstrap"
        assert not state.get("loaded"), "already loaded"
        state.update(loaded=True, path=args[2])
        start()
    elif command == "bootout":
        stop()
        state["loaded"] = False
    elif command == "kickstart":
        assert "-k" not in args, "blind restart is forbidden"
        start()
    else:
        raise AssertionError(args)
else:
    assert program == "/usr/bin/systemctl"
    assert args[:2] == ["--user", "--no-pager"]
    command, *args = args[2:]
    unit = root / ".config/systemd/user/zc-user.service"
    assert "--now" not in args
    if command == "show":
        if not unit.exists():
            print("LoadState=not-found")
        else:
            print(
                "LoadState=loaded\nActiveState=" + ("active" if alive() else "inactive")
            )
            print("MainPID=" + str(state.get("pid", 0) if alive() else 0))
            print("FragmentPath=" + str(unit))
            print("DropInPaths=")
            line = next(
                line
                for line in unit.read_text().splitlines()
                if line.startswith("ExecStart=")
            )
            argv = shlex.split(line.removeprefix("ExecStart=:").replace("%%", "%"))
            print(
                "ExecStart={ path="
                + argv[0]
                + " ; argv[]="
                + " ".join(argv)
                + " ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0 }"
            )
            print(
                "UnitFileState=" + ("enabled" if state.get("enabled") else "disabled")
            )
    elif command == "daemon-reload":
        state["path"] = str(unit)
    elif command in ("enable", "disable"):
        state["enabled"] = command == "enable"
    elif command == "start":
        start()
    elif command == "stop":
        stop()
    else:
        raise AssertionError(args)
save()
