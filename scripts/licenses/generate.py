#!/usr/bin/env python3
"""Generate locked dependency notices without installing tools or building code."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tarfile

try:
    import tomllib
except ModuleNotFoundError:
    sys.exit("ERROR: Python 3.11 or newer is required")

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
NOTICE_NAME = re.compile(
    r"^(licen[cs]e|copying|copyright|notice|authors|patents|unlicense)(?:$|[._-])", re.I
)
NATIVE_SUFFIXES = {".c", ".h", ".cc", ".cpp", ".hpp", ".s", ".asm", ".inc", ".pl"}
COMMENT = re.compile(r"/\*.*?\*/|(?:^[ \t]*(?://|\#|;)[^\n]*(?:\n|$))+", re.S | re.M)
LEGAL = re.compile(
    r"copyright|permission is hereby|redistribution and use|SPDX-License-Identifier|public domain",
    re.I,
)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def production_closure(metadata):
    nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
    pending = [metadata["resolve"]["root"]]
    visited = set()
    while pending:
        package = pending.pop()
        if package in visited:
            continue
        visited.add(package)
        pending.extend(
            dep["pkg"]
            for dep in nodes[package]["deps"]
            if any(kind["kind"] != "dev" for kind in dep["dep_kinds"])
        )
    return visited


def unknown_license_tokens(expression):
    # This is an inventory guard, not an SPDX expression parser or approval list.
    known = {
        "MIT",
        "Apache-2.0",
        "ISC",
        "BSD-3-Clause",
        "MIT-0",
        "CC0-1.0",
        "LLVM-exception",
        "Unicode-3.0",
        "Zlib",
        "Unlicense",
        "BSL-1.0",
        "LGPL-2.1-or-later",
        "AND",
        "OR",
        "WITH",
    }
    return sorted(set(re.findall(r"[A-Za-z0-9.+-]+", expression)) - known)


def has_license_body(text):
    return bool(
        re.search(
            r"permission (?:is hereby granted|to use)|redistribution and use|TERMS AND CONDITIONS|Unicode License|CC0 1\.0 Universal",
            text,
            re.I,
        )
    )


def collect_texts(root):
    texts = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        if NOTICE_NAME.match(path.name) or any(
            part.lower() in {"licenses", ".licenses", "licences", ".licences"}
            for part in path.relative_to(root).parts[:-1]
        ):
            texts.append((relative, path.read_bytes().decode("utf-8")))
        elif path.suffix.lower() in NATIVE_SUFFIXES:
            text = path.read_bytes().decode("utf-8")
            for match in COMMENT.finditer(text):
                if LEGAL.search(match.group()):
                    line = text.count("\n", 0, match.start()) + 1
                    texts.append((f"{relative}:{line}", match.group()))
    return texts


def validate_supplement(entry, vcs, repository):
    if entry["revision"] != vcs.get("git", {}).get("sha1"):
        raise ValueError("Supplement source revision changed")
    if sha256(entry["text"].encode()) != entry["sha256"]:
        raise ValueError("Supplement text checksum mismatch")
    expected = repository.replace(
        "https://github.com/", "https://raw.githubusercontent.com/"
    )
    expected += "/" + entry["revision"] + "/" + entry["path"]
    if entry["url"] != expected:
        raise ValueError("Supplement source URL mismatch")


def verify_archive(directory, checksum, paths):
    archive = (
        directory.parent.parent.parent
        / "cache"
        / directory.parent.name
        / (directory.name + ".crate")
    )
    if sha256(archive.read_bytes()) != checksum:
        raise ValueError(f"Registry archive checksum mismatch: {directory.name}")
    with tarfile.open(archive) as crate:
        for relative in sorted(set(paths) | {"Cargo.toml"}):
            member = crate.extractfile(directory.name + "/" + relative)
            if member is None or member.read() != (directory / relative).read_bytes():
                raise ValueError(
                    f"Registry source differs from locked archive: {directory.name}/{relative}"
                )


def fenced(text):
    size = max([2] + [len(match.group()) for match in re.finditer(r"`+", text)]) + 1
    fence = "`" * size
    return (
        fence + "text\n" + text + ("" if text.endswith("\n") else "\n") + fence + "\n"
    )


def generate():
    lock_bytes = (ROOT / "Cargo.lock").read_bytes()
    manifest_bytes = (ROOT / "Cargo.toml").read_bytes()
    lock = tomllib.loads(lock_bytes.decode())
    locked = {(p["name"], p["version"], p.get("source")): p for p in lock["package"]}
    command = ["cargo", "metadata", "--locked", "--offline", "--format-version", "1"]
    metadata = json.loads(subprocess.check_output(command, cwd=ROOT))
    closure = production_closure(metadata)
    root_id = metadata["resolve"]["root"]
    project = next(p for p in metadata["packages"] if p["id"] == root_id)
    nodes = {n["id"]: n for n in metadata["resolve"]["nodes"]}
    supplements = json.loads((HERE / "upstream-report.json").read_text())
    used_supplements = set()
    packages = []
    documents = {}
    issues = []
    excluded = []
    for package in sorted(
        metadata["packages"], key=lambda p: (p["name"], p["version"])
    ):
        if package["id"] == root_id:
            continue
        name, version = package["name"], package["version"]
        if package["id"] not in closure:
            excluded.append(
                {"name": name, "version": version, "reason": "仅由 dev 边可达"}
            )
            continue
        directory = Path(package["manifest_path"]).parent
        texts = collect_texts(directory)
        if package.get("license_file"):
            relative = Path(package["license_file"])
            if relative.is_absolute():
                relative = relative.relative_to(directory)
            text = (directory / relative).read_bytes().decode()
            if (relative.as_posix(), text) not in texts:
                texts.append((relative.as_posix(), text))
        vcs_path = directory / ".cargo_vcs_info.json"
        vcs = json.loads(vcs_path.read_text()) if vcs_path.exists() else {}
        source = package["source"]
        entry = locked[(name, version, source)]
        if source != "registry+https://github.com/rust-lang/crates.io-index":
            raise ValueError(f"Unsupported source provenance: {name} {source}")
        paths = [
            path.rsplit(":", 1)[0] if re.search(r":\d+$", path) else path
            for path, _ in texts
        ]
        if vcs_path.exists():
            paths.append(vcs_path.name)
        verify_archive(directory, entry["checksum"], paths)
        for index, supplement in enumerate(supplements):
            if (supplement["package"], supplement["version"]) == (name, version):
                validate_supplement(supplement, vcs, package["repository"])
                used_supplements.add(index)
                texts.append((supplement["url"], supplement["text"]))
        if not package.get("license"):
            issues.append(f"{name} {version}：缺少许可证表达式，需人工审核。")
        unknown = unknown_license_tokens(package.get("license") or "")
        if unknown:
            issues.append(
                f"{name} {version}：尚未审核的许可标识 {', '.join(unknown)}。"
            )
        if not any(has_license_body(text) for _, text in texts):
            issues.append(f"{name} {version}：未识别到完整许可正文，需人工审核。")
        references = []
        for path, text in sorted(texts):
            digest = sha256(text.encode())
            document = documents.setdefault(digest, {"text": text, "sources": []})
            document["sources"].append(f"{name} {version} / {path}")
            references.append({"path": path, "sha256": digest})
        packages.append(
            {
                "name": name,
                "version": version,
                "license": package["license"],
                "source": source,
                "checksum": entry["checksum"],
                "repository": package["repository"],
                "vcs": vcs,
                "features": sorted(nodes[package["id"]]["features"]),
                "texts": references,
            }
        )
    if used_supplements != set(range(len(supplements))):
        raise ValueError("Unused upstream supplement; update version-pinned snapshots")
    if (
        lock_bytes != (ROOT / "Cargo.lock").read_bytes()
        or manifest_bytes != (ROOT / "Cargo.toml").read_bytes()
    ):
        raise ValueError("Dependency inputs changed during generation")
    limitations = [
        "这是默认 features、所有目标平台的 normal/build 依赖闭包上界，不是单一发行二进制的链接清单；Cargo metadata 的 feature 合并可能多收录依赖。仅 dev 边可达的包单列排除。",
        "收录全部发现的许可证、NOTICE、COPYRIGHT、AUTHORS、PATENTS 及原生源码法律注释；同文去重但保留所有来源。不自动求解 SPDX 表达式，不表示所有备选许可证同时适用。r-efi 按 AUTHORS 内 MIT 条款收录；Jitter Entropy 按 AWS-LC 明示的 BSD 分支收录。",
        "AWS-LC 的发布包未包含聚合 LICENSE 所引用的部分独立许可证文件（如 s2n-bignum、jitterentropy）；此处保留聚合全文、Fiat 独立许可证及可见原生版权注释，未验证被省略的上游文件与聚合内容完全一致。",
        "lua-src 同时携带多版 Lua，luajit-src 也进入构建依赖闭包；当前 mlua-sys 的 lua54/vendored 分支选择 Lua 5.4.9。为避免遗漏，声明保留源包中其他 Lua/LuaJIT 版本的文本，不表示二进制链接这些版本。",
        "JNI、mlua-sys、ndk-context 的源包遗漏独立许可文件，使用 .cargo_vcs_info.json 精确提交的官方仓库快照补充；离线生成校验提交、URL 和文本哈希。",
        "文件名及 C/汇编/Perl 注释扫描不是法律审计：未逐一判定 Rust 内嵌片段、生成代码、系统库、Rust 工具链及最终链接产物的额外义务；不构成完整合规或法律保证。依赖、features、目标或原生代码变化后须重新审核。",
    ]
    report = {
        "project": f"{project['name']} {project['version']}",
        "command": command,
        "cargo_lock_sha256": sha256(lock_bytes),
        "cargo_toml_sha256": sha256(manifest_bytes),
        "production_package_count": len(packages),
        "unique_text_count": len(documents),
        "issues": issues,
        "limitations": limitations,
        "excluded": excluded,
        "packages": packages,
    }
    output = [
        "# 第三方许可与版权声明\n\n",
        f"适用项目：`{report['project']}`。由 `python3.11 scripts/licenses/generate.py` 生成；勿直接编辑。\n\n",
        f"Cargo.lock SHA-256：`{report['cargo_lock_sha256']}`\n\n",
        f"生产/构建依赖闭包：**{len(packages)}** 个包；去重许可及版权文本：**{len(documents)}** 段。\n\n",
        "## 范围与审核限制\n\n",
    ]
    output.extend(f"- {limitation}\n" for limitation in limitations)
    output.append("\n## 自动检查发现\n\n")
    output.extend(f"- {issue}\n" for issue in issues)
    if not issues:
        output.append("未发现包级许可正文缺失；不消除上述审核限制。\n")
    output.append("\n## 排除的开发/测试专用依赖\n\n")
    output.extend(
        f"- `{p['name']} {p['version']}`：{p['reason']}。\n" for p in excluded
    )
    output.append(
        "\n## 保留的 Zig 源码声明\n\n仅适用于仍保留作对照的 `src/protocol/TLSClient.zig`，不表示 Rust 生产程序链接 Zig。\n\n"
    )
    output.append((HERE / "zig-notice.template.md").read_text() + "\n")
    output.append(
        "## Rust 依赖与来源索引\n\n以下路径相对于对应 crates.io 发布源包；URL 为精确上游提交的补充文件。完整源码校验和及 features 见 `scripts/licenses/license-report.json`。\n\n"
    )
    for package in packages:
        output.append(f"### {package['name']} {package['version']}\n\n")
        output.append(
            f"声明许可：`{package['license']}`；[发布源包](https://crates.io/api/v1/crates/{package['name']}/{package['version']}/download)；仓库：{package['repository']}\n\n"
        )
        for reference in package["texts"]:
            digest = reference["sha256"]
            output.append(
                f"- `{reference['path']}` → [正文 {digest[:12]}](#text-{digest})\n"
            )
        output.append("\n")
    output.append(
        "## 许可及版权原文\n\n以下原文不翻译、不改写；编号为 UTF-8 原文 SHA-256。\n\n"
    )
    for digest, document in sorted(documents.items()):
        output.append(f'<a id="text-{digest}"></a>\n\n### {digest[:12]}\n\n')
        output.extend(f"- `{source}`\n" for source in sorted(document["sources"]))
        output.append("\n" + fenced(document["text"]) + "\n")
    return (
        "".join(output).encode(),
        (json.dumps(report, ensure_ascii=False, indent=2) + "\n").encode(),
        issues,
        limitations,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Check committed artifacts without writing them",
    )
    args = parser.parse_args()
    try:
        notices, report, issues, limitations = generate()
        stale = []
        for path, content in [
            (ROOT / "THIRD_PARTY_NOTICES.md", notices),
            (HERE / "license-report.json", report),
        ]:
            if args.check:
                if not path.exists() or path.read_bytes() != content:
                    stale.append(str(path.relative_to(ROOT)))
            else:
                path.write_bytes(content)
        for index, _ in enumerate(issues, 1):
            print(
                f"ERROR: license metadata/text/identifier finding {index}; see license-report.json",
                file=sys.stderr,
            )
        for index, _ in enumerate(limitations, 1):
            print(
                f"REVIEW: scope/coverage limitation {index}; see notices and license-report.json",
                file=sys.stderr,
            )
        if stale:
            print("ERROR: stale artifacts: " + ", ".join(stale), file=sys.stderr)
        print(
            f"{'Checked' if args.check else 'Generated'} notices and license report; missing-text findings: {len(issues)}"
        )
        return 1 if issues or stale else 0
    except (
        OSError,
        ValueError,
        KeyError,
        subprocess.CalledProcessError,
        tarfile.TarError,
    ) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
