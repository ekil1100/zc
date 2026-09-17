#!/usr/bin/env python3
"""Check zc's macOS distribution contract without executing the artifact.

Uses Apple's public mach-o/loader.h and nlist.h layouts. This is a narrow
link-output check, not a replacement for codesign, dyld, or runtime tests.
Only thin little-endian arm64/x86_64 executables are supported. LC_SYMTAB
must retain native imports; missing evidence fails closed. Transitive dyld
initialization and actual trust/DNS behavior still require runtime tests.
"""

import argparse
import struct
import sys
from pathlib import Path


FRAMEWORKS = {
    name: f"/System/Library/Frameworks/{name}.framework/Versions/A/{name}".encode()
    for name in ("Security", "SystemConfiguration", "CoreFoundation")
}
# LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB,
# LC_LOAD_UPWARD_DYLIB, and the obsolete LC_LAZY_LOAD_DYLIB.
DYLIB_COMMANDS = (0xC, 0x80000018, 0x8000001F, 0x80000023, 0x20)
DELAY_SECTIONS = (b"__delay_stubs", b"__delay_helper")
# Sentinels for the existing native trust/DNS paths and delayed CF data access.
NATIVE_IMPORTS = {
    b"_SecTrustSettingsCopyCertificates": "Security",
    b"_SecTrustSettingsCopyTrustSettings": "Security",
    b"_SCDynamicStoreCreateWithOptions": "SystemConfiguration",
    b"_SCDynamicStoreCopyValue": "SystemConfiguration",
    b"_kSCDynamicStoreUseSessionKeys": "SystemConfiguration",
    b"_kCFAllocatorDefault": "CoreFoundation",
    b"_kCFAllocatorNull": "CoreFoundation",
    b"_kCFBooleanFalse": "CoreFoundation",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def bounds(data, offset, size, label):
    require(0 <= offset <= len(data) and 0 <= size <= len(data) - offset,
            f"{label}: range outside file (offset={offset}, size={size})")


def unpack(data, offset, fmt, label):
    bounds(data, offset, struct.calcsize("<" + fmt), label)
    return struct.unpack_from("<" + fmt, data, offset)


def check_segment(data, body, commands_end, delay_sections):
    (_, length, segment, vmaddr, vmsize, fileoff, filesize,
     maxprot, initprot, count, flags) = unpack(body, 0, "II16sQQQQ4I", "segment")
    require(length == 72 + count * 80, "invalid segment section count/size")
    bounds(data, fileoff, filesize, "segment file range")
    require(filesize <= vmsize, "segment file size exceeds VM size")
    segment = segment.rstrip(b"\0")
    for index in range(count):
        (name, owner, address, size, offset, alignment, reloff, nreloc,
         attributes, r1, r2, r3) = unpack(body, 72 + index * 80, "16s16sQQ8I", "section")
        name = name.rstrip(b"\0")
        require(owner.rstrip(b"\0") == segment, "section segment name mismatch")
        require(vmaddr <= address <= vmaddr + vmsize and size <= vmaddr + vmsize - address,
                f"{name!r}: invalid section VM range")
        zero_fill = attributes & 0xFF in (1, 0xC, 0x12)
        if not zero_fill and size:
            bounds(data, offset, size, "section file range")
            require(offset >= commands_end and fileoff <= offset
                    and offset + size <= fileoff + filesize
                    and offset - fileoff == address - vmaddr,
                    f"{name!r}: invalid section file range/mapping")
        if nreloc:
            bounds(data, reloff, nreloc * 8, "section relocations")
        if name in DELAY_SECTIONS:
            label = name.decode()
            require(name not in delay_sections, f"duplicate delay section: {label}")
            require(segment == b"__TEXT" and initprot & maxprot & 4,
                    f"{label}: expected __TEXT executable segment")
            require(size > 0, f"{label}: expected nonempty delay section")
            require(attributes & 0xFF in (0, 8) and attributes & 0x80000400,
                    f"{label}: expected file-backed instructions")
            require(any(data[offset:offset + size]), f"{label}: expected nonzero code")
            delay_sections.add(name)


def check_imports(data, symtab, commands_end, frameworks):
    require(symtab is not None, "missing LC_SYMTAB: cannot verify native imports")
    symoff, count, stroff, strsize = symtab
    bounds(data, symoff, count * 16, "symbol table")
    bounds(data, stroff, strsize, "string table")
    require(symoff >= commands_end and stroff >= commands_end,
            "symbol/string table overlaps load commands")
    require(symoff + count * 16 <= stroff or stroff + strsize <= symoff,
            "overlapping symbol/string tables")
    strings = data[stroff:stroff + strsize]
    found = set()
    for index in range(count):
        strx, kind, section, description, value = unpack(
            data, symoff + index * 16, "IBBHQ", "symbol table entry")
        require(strx < strsize, "invalid symbol string index")
        end = strings.find(b"\0", strx)
        require(end != -1, "unterminated symbol name")
        name = strings[strx:end]
        ordinal = description >> 8
        # N_UNDF | N_EXT, no section/common value, no N_WEAK_REF/N_REF_TO_WEAK.
        imported = kind == 1 and section == 0 and value == 0
        if imported and ordinal in frameworks.values():
            require(not description & 0xC0, f"weak native import: {name!r}")
        if name in NATIVE_IMPORTS:
            require(imported and not description & 0xC0
                    and ordinal == frameworks[NATIVE_IMPORTS[name]],
                    f"invalid native import: {name!r}; expected strong undefined symbol from {NATIVE_IMPORTS[name]}")
            require(name not in found, f"duplicate native import: {name!r}")
            found.add(name)
    for name in NATIVE_IMPORTS:
        require(name in found, f"missing native import: {name.decode()}")


def verify(data):
    magic, cpu, subtype, kind, count, size, flags, reserved = unpack(
        data, 0, "8I", "Mach-O header")
    require(magic == 0xFEEDFACF, "expected thin little-endian 64-bit Mach-O (not fat/32-bit)")
    require(cpu in (0x0100000C, 0x01000007), "unsupported architecture: expected arm64 or x86_64")
    require(kind == 2, "expected MH_EXECUTE executable")
    require(reserved == 0, "invalid reserved header field")
    require(flags & 0x84 == 0x84 and not flags & 0x100,
            "expected dyld-linked two-level namespace, not flat lookup")
    bounds(data, 32, size, "load commands")
    require(count <= size // 8, "invalid load commands count")
    end = 32 + size
    offset = 32
    version_seen = False
    libraries = []
    frameworks = {}
    delay_sections = set()
    symtab = None
    for _ in range(count):
        require(offset + 8 <= end, "truncated load commands")
        command, length = unpack(data, offset, "2I", "load command")
        require(length >= 8 and length % 8 == 0 and length <= end - offset,
                f"invalid load command size at offset {offset}")
        body = data[offset:offset + length]
        if command in (0x32, 0x24, 0x25, 0x2F, 0x30):
            require(not version_seen, "duplicate/conflicting macOS version commands")
            version_seen = True
            if command == 0x32:  # LC_BUILD_VERSION
                platform, minimum, sdk, tools = unpack(body, 8, "4I", "build version")
                require(length == 24 + tools * 8, "invalid build version tool count/size")
                require(platform == 1, "expected macOS platform")
            else:
                require(command == 0x24, "expected macOS version command")
                require(length == 16, "invalid macOS version command size")
                minimum, sdk = unpack(body, 8, "2I", "macOS version")
            require(minimum == 0x000F0000,
                    "minOS must be exactly 15.0.0; found "
                    f"{minimum >> 16}.{(minimum >> 8) & 255}.{minimum & 255}")
        elif command == 2:  # LC_SYMTAB
            require(symtab is None, "duplicate LC_SYMTAB")
            require(length == 24, "invalid symbol table command size")
            symtab = unpack(body, 8, "4I", "symbol table command")
        elif command == 0x19:  # LC_SEGMENT_64
            check_segment(data, body, end, delay_sections)
        elif command in DYLIB_COMMANDS:
            nameoff, marker, current, compatibility = unpack(body, 8, "4I", "dylib command")
            require(24 <= nameoff < length, "invalid dylib path offset")
            require(marker != 0x1A741800 or nameoff == 28,
                    "invalid strong delayed-init encoding: dylib path offset must be 28")
            terminator = body.find(b"\0", nameoff)
            require(terminator != -1, "unterminated dylib path")
            path = body[nameoff:terminator]
            require(path, "empty dylib path")
            libraries.append(path)
            for name, expected in FRAMEWORKS.items():
                # Reject alternate spellings/locations even alongside a valid entry.
                if name.encode() == path.rsplit(b"/", 1)[-1] or (name + ".framework").encode() in path.split(b"/"):
                    require(path == expected, f"{name}: non-system framework path {path!r}")
                    require(name not in frameworks, f"duplicate framework: {name}")
                    require(command == 0xC and nameoff == 28 and marker == 0x1A741800,
                            f"{name}: expected strong delayed-init LC_LOAD_DYLIB (Apple -delay_framework)")
                    use_flags, = unpack(body, 24, "I", "dylib use flags")
                    require(use_flags == 0x08,
                            f"{name}: expected only strong delayed-init flag 0x08; found {use_flags:#x}")
                    frameworks[name] = len(libraries)
        offset += length
    require(offset == end, "load commands count/size mismatch")
    require(version_seen, "missing macOS version command")
    for name in FRAMEWORKS:
        require(name in frameworks, f"missing framework: {name}")
    for name in DELAY_SECTIONS:
        require(name in delay_sections, f"missing delay section: __TEXT,{name.decode()}")
    check_imports(data, symtab, end, frameworks)
    return "arm64" if cpu == 0x0100000C else "x86_64"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path, help="path to the final thin macOS zc executable")
    args = parser.parse_args()
    try:
        architecture = verify(args.artifact.read_bytes())
    except (OSError, ValueError) as error:
        print(f"FAIL: {args.artifact}: {error}", file=sys.stderr)
        return 1
    print(f"PASS: {args.artifact}: {architecture}, minOS 15.0.0; "
          "Security/SystemConfiguration/CoreFoundation strong delayed-init; "
          "delay sections and native trust/DNS imports preserved")
    return 0


if __name__ == "__main__":
    sys.exit(main())
