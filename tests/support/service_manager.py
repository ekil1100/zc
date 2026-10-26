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
diagnostics = os.environ.get("ZC_SERVICE_STOP_DIAGNOSTICS") == "1"
last_probe = None


def save():
    # A bounded manager command can be terminated during any write. Keep the
    # previous state readable by recovery until the complete replacement exists.
    pending = state_path.with_name(f".{state_path.name}.{os.getpid()}.tmp")
    try:
        pending.write_text(json.dumps(state))
        os.replace(pending, state_path)
    finally:
        pending.unlink(missing_ok=True)


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
    global last_probe
    pid = state.get("pid", 0)
    probe = {"pid": pid}
    if diagnostics:
        probe.update(monotonic=time.monotonic(), timestamp_ns=time.time_ns())
    try:
        if not pid:
            probe["alive"] = False
            return False
        try:
            os.kill(pid, 0)
            probe["kill_errno"] = 0
        except OSError as error:
            probe["kill_errno"] = error.errno
            raise
        proc = pathlib.Path(f"/proc/{pid}/stat")
        probe["proc_exists"] = proc.exists()
        if probe["proc_exists"]:
            probe["stat"] = proc.read_text()
            # Keep the original decision while diagnosing it. The raw stat also
            # preserves starttime and allows independent parsing of comm/state.
            probe["parsed_state"] = probe["stat"].split(") ", 1)[1][0]
        probe["alive"] = probe.get("parsed_state") != "Z"
        return probe["alive"]
    except (ProcessLookupError, FileNotFoundError) as error:
        # Linux may reap the process between the procfs existence check and read.
        probe.update(alive=False, errno=error.errno)
        return False
    finally:
        if diagnostics:
            probe["finished_monotonic"] = time.monotonic()
            last_probe = probe


def record_diagnostic(phase, deadline=None):
    if not diagnostics:
        return
    event = {
        "phase": phase,
        "platform": platform,
        "operation": (
            "cleanup"
            if program == "test-cleanup"
            else args[0]
            if platform == "launchd"
            else args[2]
        ),
        "manager_pid": os.getpid(),
        "monotonic": time.monotonic(),
        "timestamp_ns": time.time_ns(),
        "deadline": deadline,
        "probe": last_probe,
    }
    if phase == "timeout":
        # Read only the owned test process. Do not collect cmdline or environ.
        task = pathlib.Path(f"/proc/{state['pid']}/task")
        try:
            threads = list(task.iterdir())
            event["thread_count"] = len(threads)
            event["threads"] = []
            for thread in sorted(threads)[:32]:
                entry = {"tid": thread.name}
                for field in ("stat", "wchan", "stack"):
                    try:
                        entry[field] = (thread / field).read_text()[:4096]
                    except OSError as error:
                        entry[field + "_errno"] = error.errno
                event["threads"].append(entry)
        except OSError as error:
            event["threads_errno"] = error.errno
    try:
        with (root / "manager-stop-diagnostics.jsonl").open("a") as output:
            output.write(json.dumps(event) + "\n")
    except OSError:
        # Optional evidence must not replace the original stop result.
        pass


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
        assert job["RunAtLoad"]
        if job["KeepAlive"]:
            assert job["ThrottleInterval"] == 10
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
        assert lines["Restart"] in ("no", "always")
        if lines["Restart"] == "always":
            assert lines["RestartSec"] == "10"
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
        record_diagnostic("sigterm", deadline)
        while alive() and time.monotonic() < deadline:
            time.sleep(0.02)
        still_alive = alive()
        record_diagnostic("timeout" if still_alive else "stopped", deadline)
        assert not still_alive, "test daemon failed to stop"
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
record_diagnostic("command-end")
save()
