"""Malformed local release artifacts must leave the target untouched."""

import hashlib
import io
import os
import pathlib
import subprocess
import sys
import tarfile

installer, root, candidate = (pathlib.Path(arg).resolve() for arg in sys.argv[1:4])
version, package = sys.argv[4:]
release = root / "safety-releases" / version
release.mkdir(parents=True)
archive = release / f"{package}.tar.gz"
checksum = archive.with_suffix(".gz.sha256")
home = root / "safety-home"
home.mkdir(mode=0o700)
target = home / "bin"
target.mkdir()
sentinel = target / "zc"
sentinel.write_text("old-release-sentinel")
old = sentinel.read_bytes()
env = dict(
    os.environ,
    HOME=str(home),
    ZC_VERSION=version,
    ZC_INSTALL_DIR=str(target),
    ZC_RELEASE_BASE_URL=release.parent.as_uri(),
)
env.pop("XDG_RUNTIME_DIR", None)


def digest():
    checksum.write_text(
        f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n"
    )


def refused(case):
    with installer.open("rb") as stdin:
        result = subprocess.run(
            ["/bin/sh"],
            stdin=stdin,
            env=env,
            cwd=home,
            capture_output=True,
            text=True,
            timeout=30,
        )
    assert result.returncode != 0, (case, result)
    assert sentinel.read_bytes() == old, case
    assert not (target / ".zc.install.lock").exists(), case
    print(f"ROOT_RELEASE_SAFETY={case} PASS")


for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.DIRTYPE, tarfile.FIFOTYPE):
    with tarfile.open(archive, "w:gz") as tar:
        member = tarfile.TarInfo(f"{package}/zc")
        member.type = kind
        member.linkname = str(sentinel)
        tar.addfile(member)
    digest()
    refused(f"member-type-{kind!r}")

for names in ((f"{package}/zc", f"{package}/zc"), (f"{package}/../zc",)):
    with tarfile.open(archive, "w:gz") as tar:
        for name in names:
            member = tarfile.TarInfo(name)
            member.size = len(old)
            tar.addfile(member, io.BytesIO(old))
    digest()
    refused("duplicate-member" if len(names) == 2 else "wrong-member-path")

with tarfile.open(archive, "w:gz") as tar:
    tar.add(candidate, arcname=f"{package}/zc")
digest()
good_checksum = checksum.read_bytes()
checksum.unlink()
refused("missing-checksum")
for label, data in (
    ("oversize-checksum", b"0" * 4097),
    ("duplicate-checksum", good_checksum * 2),
    ("malformed-checksum", b"no digest\n"),
):
    checksum.write_bytes(data)
    refused(label)

with archive.open("wb") as file:
    file.truncate(67108865)
digest()
refused("archive-over-64MiB")
large = root / "oversize-binary"
with large.open("wb") as file:
    file.truncate(134217729)
with tarfile.open(archive, "w:gz") as tar:
    tar.add(large, arcname=f"{package}/zc")
digest()
refused("binary-over-128MiB")
large.unlink()

# Matching stdout with an unsuccessful self-check is still a failed candidate.
bad = root / "nonzero-version"
bad.write_text(f"#!/bin/sh\necho 'zc {version.removeprefix('v')}'\nexit 9\n")
bad.chmod(0o700)
with tarfile.open(archive, "w:gz") as tar:
    tar.add(bad, arcname=f"{package}/zc")
digest()
refused("version-exit-nonzero")
