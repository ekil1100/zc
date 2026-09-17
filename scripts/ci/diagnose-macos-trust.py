#!/usr/bin/env python3
"""DIAGNOSTIC ONLY: isolate stock User TrustSettings writes without Rust.

Only for explicitly disposable, exclusive macOS 15+ GitHub Actions runners.
Environment flags are not attestation; fake HOME does not isolate trust. Never
run on a development host. The caller must destroy the runner after use, and
must not upload the private fixture (certificate private key/keychain).

No TLS, DNS or nine-case native acceptance claim. --keychain-only changes just
one variable: add-certificates into the owned keychain instead of User trust.
Use separate fresh runners for the two modes; no retries or policy changes.

On an approved ephemeral GHA arm64 runner only:
  python3 scripts/ci/diagnose-macos-trust.py --ephemeral-runner --target aarch64-apple-darwin
The stock setter keeps its original 30s budget, including the halfway owned
stack sample. Service logs run concurrently and retain at most 16 KiB of output;
empty/filtered logs are not evidence that authorization or GUI activity is absent.
After the attempt, before cleanup, one authd/SecurityAgent persisted last-minute
query has its own 3s watchdog and 16 KiB output cap, with password redaction first.
Missing request origin/right context leaves the authorization/GUI cause unknown.
"""

import argparse
import contextlib
from datetime import datetime, timezone
import importlib.util
import os
from pathlib import Path
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time


SPEC = importlib.util.spec_from_file_location(
    "native_runner", Path(__file__).with_name("test-macos-native.py")
)
native = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(native)


LOG_LIMIT = 16384
LOG_PREDICATE = (
    '(process == "trustd" OR process == "authd" OR process == "securityd") AND '
    '(eventMessage CONTAINS[c] "trust" OR eventMessage CONTAINS[c] "auth" OR '
    'eventMessage CONTAINS[c] "xpc" OR eventMessage CONTAINS[c] "lock" OR '
    'eventMessage CONTAINS[c] "session" OR eventMessage CONTAINS[c] "interaction")'
)


@contextlib.contextmanager
def service_logs(password, cleanup_errors):
    # Read-only, no sudo, no log configuration changes. Stream only across the
    # write, not keychain password setup or cleanup. A kernel pipe bounds queued
    # output; if full, only this log client stalls. Retain a prefix, not an archive.
    # No communicate()/extra watchdog: stop immediately when the write finishes.
    child = None
    started = time.monotonic()
    try:
        child = subprocess.Popen(
            ["/usr/bin/log", "stream", "--style", "compact", "--level", "debug",
             "--predicate", LOG_PREDICATE],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            umask=0o077,
        )
        print(f"BEGIN service logs pid={child.pid} utc={datetime.now(timezone.utc).isoformat()}", flush=True)
    except Exception as error:
        print(f"WARN service logs unavailable ({type(error).__name__})", flush=True)
    try:
        yield
    finally:
        if child is not None:
            output = b""
            status = None
            try:
                status = child.poll()
                if status is None:
                    child.kill()
                child.wait()
                # The direct child is reaped; no shell/descendants hold the pipe.
                # Read enough extra bytes to redact a secret straddling the cap.
                output = child.stdout.read(LOG_LIMIT + len(password) + 1)
            except (Exception, KeyboardInterrupt) as error:
                cleanup_errors.append(f"service log child reap/read failed ({type(error).__name__})")
            finally:
                try:
                    child.stdout.close()
                except (Exception, KeyboardInterrupt) as error:
                    cleanup_errors.append(f"service log stream close failed ({type(error).__name__})")
            text = native.diagnostic_text(output, ["-p", password]).encode("utf-8")
            if text:
                print("EVIDENCE service logs (bounded prefix; may be filtered, buffered or truncated):", flush=True)
                print(text[:LOG_LIMIT - 1].decode("utf-8", errors="ignore"), flush=True)
            else:
                print("WARN service logs: no evidence captured", flush=True)
            if status is not None:
                print(f"WARN service logs exited before collection ended (exit {status})", flush=True)
            print(f"END service logs pid={child.pid} elapsed={time.monotonic() - started:.3f}s", flush=True)
        print("NOTE missing service logs does not rule out authorization/IPC waits; "
              "startup, permissions and privacy filtering limit evidence", flush=True)


def authorization_window(password):
    # One read-only persisted query covers events missed during stream startup.
    # A pipe bounds queued output; a full pipe may stall this client until its
    # own watchdog kills it. Never communicate() an unbounded log into memory.
    child = None
    started = time.monotonic()
    output = b""
    outcome = "captured"
    print("BEGIN authorization window (last 1m; owned watchdog 3s)", flush=True)
    try:
        child = subprocess.Popen(
            ["/usr/bin/log", "show", "--last", "1m", "--style", "compact", "--info", "--debug",
             "--predicate", '(process == "authd" OR process == "SecurityAgent") AND '
             'subsystem == "com.apple.Authorization"'],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            umask=0o077,
        )
        status = child.wait(timeout=max(0, started + 3 - time.monotonic()))
        if status:
            outcome = f"exit {status}"
    except subprocess.TimeoutExpired:
        outcome = "owned watchdog expired after 3s"
    except (Exception, KeyboardInterrupt) as error:
        outcome = type(error).__name__
    finally:
        if child is not None:
            try:
                if child.poll() is None:
                    child.kill()
                child.wait()
                # Direct child only: after reaping, this pipe cannot block.
                output = child.stdout.read(LOG_LIMIT + len(password))
            except (Exception, KeyboardInterrupt) as error:
                outcome = f"reap/read failed ({type(error).__name__})"
            finally:
                try:
                    child.stdout.close()
                except (Exception, KeyboardInterrupt) as error:
                    outcome = f"stream close failed ({type(error).__name__})"
    text = native.diagnostic_text(output, ["-p", password])
    # A bounded read or killed writer can end inside the password. Suppress that
    # suffix too, even if earlier redactions have shortened the retained prefix.
    for length in range(len(password) - 1, 0, -1):
        if text.endswith(password[:length]):
            text = text[:-length]
            break
    if text:
        print("EVIDENCE authorization window (bounded prefix; may be truncated):", flush=True)
        # Reserve space for the probe's status lines as well as the newline.
        print(text.encode("utf-8")[:LOG_LIMIT - 1024].decode("utf-8", errors="ignore"), flush=True)
    else:
        print("WARN authorization window: no evidence captured", flush=True)
    print(f"END authorization window: {outcome}; elapsed={time.monotonic() - started:.3f}s", flush=True)
    print("NOTE persistence, permissions and privacy may omit context; without a linked right/request, "
          "origin/GUI cause remains unknown", flush=True)


def diagnose(keychain_only):
    # Entry point has already checked isolation, before even this read-only snapshot.
    print("DIAGNOSTIC ONLY: " + ("keychain-only" if keychain_only else "user TrustSettings")
          + "; no Rust or TLS verification", flush=True)
    original_search = shlex.split(native.command(
        [native.SECURITY, "list-keychains", "-d", "user"], "snapshot user keychain search list"
    ))
    if any(not Path(path).is_absolute() for path in original_search):
        raise RuntimeError("cannot safely parse original keychain search list")
    directory = Path(tempfile.mkdtemp(prefix="zc-macos-trust-diagnostic-")).resolve()
    keychain = directory / "owned.keychain-db"
    certificate = directory / "cert.pem"
    keychain_attempted = False
    trust_attempted = False
    write_attempted = False
    primary = None
    errors = []
    try:
        native.generate_certificate(directory)
        password = secrets.token_hex(32)
        # create-keychain can change the search list even on partial failure.
        keychain_attempted = True
        native.command([native.SECURITY, "create-keychain", "-p", password, keychain],
                       "create owned keychain")
        native.command([native.SECURITY, "unlock-keychain", "-p", password, keychain],
                       "unlock owned keychain")
        native.command([native.SECURITY, "list-keychains", "-d", "user", "-s", *original_search, keychain],
                       "append owned keychain to user search list")
        with service_logs(password, errors):
            write_attempted = True
            if keychain_only:
                native.command([native.SECURITY, "add-certificates", "-k", keychain, certificate],
                               "keychain-only owned certificate add-certificates")
            else:
                # Attempt-before-cleanup is required even for a timeout or a failed spawn.
                trust_attempted = True
                native.command([native.SECURITY, "add-trusted-cert", "-r", "trustRoot", "-k", keychain, certificate],
                               "user owned certificate add-trusted-cert", sample_trust=True)
    except (Exception, KeyboardInterrupt) as error:
        primary = error
    finally:
        if write_attempted:
            try:
                authorization_window(password)
            except (Exception, KeyboardInterrupt) as error:
                # Diagnostics cannot replace the saved primary or skip cleanup.
                print(f"WARN authorization window unavailable ({type(error).__name__})", flush=True)

        def cleanup(action):
            try:
                action()
            except (Exception, KeyboardInterrupt) as error:
                errors.append(str(error))

        if trust_attempted:
            # Item-not-found is NOT success; no unverified absence exemptions.
            cleanup(lambda: native.command([native.SECURITY, "remove-trusted-cert", certificate],
                                           "user owned certificate remove-trusted-cert"))
        if keychain_attempted:
            cleanup(lambda: native.command(
                [native.SECURITY, "list-keychains", "-d", "user", "-s", *original_search],
                "restore original user keychain search list",
            ))

            def delete_keychain():
                if keychain.exists():
                    native.command([native.SECURITY, "delete-keychain", keychain], "delete owned keychain")
                if keychain.exists():
                    raise RuntimeError("owned keychain still exists after deletion")

            cleanup(delete_keychain)

            def verify_search():
                restored = shlex.split(native.command(
                    [native.SECURITY, "list-keychains", "-d", "user"], "verify restored search list"
                ))
                if restored != original_search:
                    raise RuntimeError("user keychain search list was not restored exactly")

            cleanup(verify_search)
        if not errors:
            cleanup(lambda: shutil.rmtree(directory))
        if not errors:
            print("PASS cleanup: owned fixture removed; original search list restored", flush=True)
    failures = [f"PRIMARY: {primary}"] if primary is not None else []
    if errors:
        failures.append(
            f"CLEANUP FAILED; disposable runner must be destroyed; owned fixture: {directory}; "
            + "; ".join(f"CLEANUP: {error}" for error in errors)
        )
    if failures:
        raise RuntimeError("; ".join(failures)) from primary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ephemeral-runner", action="store_true",
                        help="confirm disposable, exclusive runner with no production credentials")
    parser.add_argument("--target", required=True, choices=sorted(native.TARGETS.values()))
    parser.add_argument("--keychain-only", action="store_true",
                        help="control: owned keychain certificate write, no TrustSettings write")
    args = parser.parse_args()
    native.require_ci(args)
    print(f"DIAGNOSTIC ONLY environment: target={args.target} uid={os.getuid()} euid={os.geteuid()}", flush=True)
    previous = signal.signal(signal.SIGTERM, native.interrupted)
    try:
        diagnose(args.keychain_only)
    finally:
        signal.signal(signal.SIGTERM, previous)
    print("DIAGNOSTIC ONLY complete; no TLS/DNS or native nine-case verification", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
