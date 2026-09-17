#!/usr/bin/env python3
"""Test native first use only on an explicitly disposable macOS CI runner.

Usage: python3 scripts/ci/test-macos-native.py --ephemeral-runner --target TARGET
Locally, exercise refusal only: fake HOME does not isolate trust/DNS. Environment
flags are not attestation; the caller must ensure the runner is disposable and
has no concurrent keychain/trust writers. Only the unique self-signed test
certificate's User/Admin trust is changed, never System trust or global DNS.
Does not validate System priority, TrustAsRoot, external DNS, soak or performance.
"""

import argparse
import json
import os
import platform
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SECURITY = "/usr/bin/security"
TEST = "native_first_use"
CASE_TIMEOUT = 30  # Parent wall-clock watchdog; application deadlines are unchanged.
TARGETS = {"arm64": "aarch64-apple-darwin", "x86_64": "x86_64-apple-darwin"}


def require_ci(args):
    # Must run before subprocesses, temporary files, build, or native settings reads.
    if not (
        os.environ.get("GITHUB_ACTIONS") == "true"
        and os.environ.get("RUNNER_OS") == "macOS"
        and args.ephemeral_runner
        and sys.platform == "darwin"
    ):
        raise RuntimeError(
            "REFUSED: requires GITHUB_ACTIONS=true, RUNNER_OS=macOS and "
            "--ephemeral-runner on a disposable macOS CI runner; fake HOME is not isolation"
        )
    if TARGETS.get(platform.machine()) != args.target:
        raise RuntimeError("REFUSED: target must match the native runner architecture")
    version = platform.mac_ver()[0]
    if not version or int(version.split(".")[0]) < 15:
        raise RuntimeError("REFUSED: native scenarios require macOS 15 or newer")


def command(argv, label, *, timeout=30, env=None, diagnostics=False):
    # Never log argv/successful output: security's argv contains the temporary password.
    # Kill/wait only through the owned Child handle, including on interruption.
    with subprocess.Popen(
        [str(arg) for arg in argv], cwd=ROOT, env=env,
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, umask=0o077,
    ) as child:
        try:
            stdout, _stderr = child.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            raise RuntimeError(f"{label}: parent watchdog expired after {timeout}s") from None
        finally:
            if child.poll() is None:
                # Give sudo a chance to forward termination to its security child.
                child.terminate()
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill()
            child.wait()
        if child.returncode != 0:
            # Only Cargo and our fixed test executable opt in; never security/OpenSSL.
            if diagnostics:
                print((stdout + _stderr)[-16384:], file=sys.stderr)
            else:
                # Preserve OS failure causes, but not password arguments or stdout.
                detail = _stderr
                for index, arg in enumerate(argv[:-1]):
                    if str(arg) == "-p":
                        detail = detail.replace(str(argv[index + 1]), "<REDACTED>")
                print(detail[-2048:], file=sys.stderr)
            raise RuntimeError(f"{label}: child failed (exit {child.returncode})")
    return stdout


def build(target):
    output = command([
        "cargo", "test", "--locked", "--release", "--target", target,
        "--test", "macos_native", "--no-run", "--message-format=json",
    ], "release test build", timeout=1800, diagnostics=True)
    artifacts = set()
    for line in output.splitlines():
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        if (message.get("reason") == "compiler-artifact"
                and message.get("target", {}).get("name") == "macos_native"
                and "test" in message.get("target", {}).get("kind", [])
                and message.get("profile", {}).get("test") is True
                and message.get("executable")):
            artifacts.add(Path(message["executable"]).resolve())
    if len(artifacts) != 1:
        raise RuntimeError("build must report exactly one macos_native test executable")
    artifact = artifacts.pop()
    if not artifact.is_file():
        raise RuntimeError("reported test executable does not exist")
    return artifact


def private_write(path, content):
    with path.open("x", encoding="utf-8") as stream:
        path.chmod(0o600)
        stream.write(content)


def generate_certificate(directory):
    # Self-signed end-entity certificate: it is both the tested leaf and trust anchor.
    # CA:FALSE avoids accidentally testing a CA certificate as a TLS end entity.
    config = directory / "openssl.cnf"
    private_write(config, f"""[req]
 distinguished_name = dn
 x509_extensions = extensions
 prompt = no
[dn]
 CN = zc-native-{secrets.token_hex(16)}
[extensions]
 basicConstraints = critical,CA:FALSE
 keyUsage = critical,digitalSignature,keyEncipherment
 extendedKeyUsage = serverAuth
 subjectAltName = DNS:front.example
""")
    command([
        "/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-sha256", "-days", "2", "-set_serial", "0x" + secrets.token_hex(16),
        "-config", config, "-keyout", directory / "key.pem",
        "-out", directory / "cert.pem",
    ], "generate unique test certificate")
    for name in ("cert.pem", "key.pem"):
        (directory / name).chmod(0o600)


def run_case(artifact, directory, case):
    nonce = secrets.token_hex(32)
    manifest = directory / "fixture.json"
    # The directory remains owner-only throughout all cases.
    manifest.unlink(missing_ok=True)
    private_write(manifest, json.dumps({"version": 1, "case": case, "nonce": nonce}))
    env = os.environ.copy()
    # Unset BOTH only in the CI test child. Empty SSL_CERT_DIR is not isolation.
    env.pop("SSL_CERT_FILE", None)
    env.pop("SSL_CERT_DIR", None)
    env.update({
        "ZC_MACOS_NATIVE_EPHEMERAL": "confirmed",
        "ZC_MACOS_NATIVE_FIXTURE": str(directory),
        "ZC_MACOS_NATIVE_NONCE": nonce,
    })
    started = time.monotonic()
    output = command([
        artifact, "--ignored", "--exact", TEST, "--nocapture",
        "--test-threads=1", "--format=terse",
    ], f"native scenario {case}", timeout=CASE_TIMEOUT, env=env, diagnostics=True)
    for stage in ("BEGIN", "PASS"):
        marker = f"ZC_MACOS_NATIVE_{stage} {case} {nonce}"
        if output.count(marker) != 1:
            raise RuntimeError(f"{case}: missing or duplicate {stage} assertion marker")
    if "test result: ok. 1 passed; 0 failed; 0 ignored;" not in output:
        raise RuntimeError(f"{case}: expected exactly one executed test, not a skipped test")
    print(f"PASS native {case} ({time.monotonic() - started:.3f}s)", flush=True)


def scenarios(artifact):
    # No fake HOME: CI explicitly authorizes changes to this disposable user's trust.
    # Snapshot BEFORE create-keychain, which may itself change the search list.
    original_search = shlex.split(command(
        [SECURITY, "list-keychains", "-d", "user"], "snapshot user keychain search list"
    ))
    if any(not Path(path).is_absolute() for path in original_search):
        raise RuntimeError("cannot safely parse original keychain search list")
    # Admin priority is required here, not silently skipped if sudo is unavailable.
    command(["/usr/bin/sudo", "-n", "true"], "require noninteractive disposable runner sudo")
    directory = Path(tempfile.mkdtemp(prefix="zc-macos-native-")).resolve()
    keychain = directory / "owned.keychain-db"
    certificate = directory / "cert.pem"
    touched = set()
    keychain_attempted = False

    def security(domain, *args):
        prefix = ["/usr/bin/sudo", "-n"] if domain == "admin" else []
        domain_args = ["-d"] if domain == "admin" else []
        return command(prefix + [SECURITY, args[0]] + domain_args + list(args[1:]),
                       f"{domain} owned certificate {args[0]}")

    def trust(domain, result):
        # Mark BEFORE attempting mutation so partial failure still gets cleanup.
        touched.add(domain)
        security(domain, "add-trusted-cert", "-r", result,
                 "-k", keychain, certificate)

    def remove(domain):
        security(domain, "remove-trusted-cert", certificate)
        touched.remove(domain)

    try:
        generate_certificate(directory)
        password = secrets.token_hex(32)
        keychain_attempted = True
        command([SECURITY, "create-keychain", "-p", password, keychain], "create owned keychain")
        command([SECURITY, "unlock-keychain", "-p", password, keychain], "unlock owned keychain")
        command([SECURITY, "list-keychains", "-d", "user", "-s", *original_search, keychain],
                "append owned keychain to user search list")
        run_case(artifact, directory, "baseline-untrusted")
        trust("user", "trustRoot")
        for case in ("security-first", "dns-first", "wrong-sni",
                     "concurrent-independent", "concurrent-shared"):
            run_case(artifact, directory, case)
        remove("user")
        trust("user", "deny")
        run_case(artifact, directory, "user-deny")
        remove("user")
        trust("admin", "trustRoot")
        # Positive control makes the subsequent priority rejection meaningful.
        run_case(artifact, directory, "admin-trust")
        trust("user", "deny")
        run_case(artifact, directory, "user-deny-admin-trust")
    finally:
        errors = []

        def cleanup(action):
            try:
                action()
            except (Exception, KeyboardInterrupt) as error:
                errors.append(str(error))

        for domain in ("user", "admin"):
            if domain in touched:
                cleanup(lambda domain=domain: remove(domain))
        if keychain_attempted:
            cleanup(lambda: command(
                [SECURITY, "list-keychains", "-d", "user", "-s", *original_search],
                "restore original user keychain search list",
            ))
            if keychain.exists():
                # Deleting only our whole keychain also removes the owned certificate.
                cleanup(lambda: command([SECURITY, "delete-keychain", keychain],
                                        "delete owned keychain"))
            def verify_search():
                restored = shlex.split(command(
                    [SECURITY, "list-keychains", "-d", "user"], "verify restored search list"
                ))
                if restored != original_search:
                    raise RuntimeError("user keychain search list was not restored exactly")
            cleanup(verify_search)
        if errors:
            # Preserve the private certificate for manual repair if the OS refused cleanup.
            raise RuntimeError(
                f"CLEANUP FAILED; disposable runner must be destroyed; owned fixture: {directory}; "
                + "; ".join(errors)
            )
        shutil.rmtree(directory)
        print("PASS cleanup: owned trust/keychain removed; original search list restored", flush=True)


def interrupted(_signum, _frame):
    raise InterruptedError("runner interrupted; cleaning owned fixture")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ephemeral-runner", action="store_true",
                        help="confirm this macOS CI runner is disposable and has no concurrent trust writers")
    parser.add_argument("--target", required=True, choices=sorted(TARGETS.values()))
    args = parser.parse_args()
    require_ci(args)
    previous = signal.signal(signal.SIGTERM, interrupted)
    try:
        scenarios(build(args.target))
    finally:
        signal.signal(signal.SIGTERM, previous)
    print("PASS all 9 native first-use scenarios; no System-domain or TrustAsRoot claim")


if __name__ == "__main__":
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
