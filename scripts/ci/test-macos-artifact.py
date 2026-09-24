#!/usr/bin/env python3
"""Exercise the public CLI with independent Mach-O wire-format fixtures.

Numbers/layouts below come from Apple's mach-o/loader.h and nlist.h, not
from the verifier. Fixtures model the distribution contract, not runnable code.
"""

import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CLI = Path(__file__).with_name("verify-macos-artifact.py")


def fixture(cpu=0x0100000C, minimum=0x000F0000):
    paths = [
        b"/System/Library/Frameworks/Security.framework/Versions/A/Security",
        b"/System/Library/Frameworks/SystemConfiguration.framework/Versions/A/SystemConfiguration",
        b"/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
    ]
    commands = [struct.pack("<6I", 0x32, 24, 1, minimum, 0x001B0000, 0)]
    for path in paths:
        size = (28 + len(path) + 1 + 7) & ~7
        commands.append(
            struct.pack("<7I", 0xC, size, 28, 0x1A741800, 0, 0, 8)
            + (path + b"\0").ljust(size - 28, b"\0")
        )
    sections = b""
    for name, offset in [(b"__delay_stubs", 4096), (b"__delay_helper", 4112)]:
        sections += struct.pack(
            "<16s16sQQ8I",
            name,
            b"__TEXT",
            0x100000000 + offset,
            16,
            offset,
            2,
            0,
            0,
            0x80000400,
            0,
            0,
            0,
        )
    commands.append(
        struct.pack(
            "<II16sQQQQ4I", 0x19, 232, b"__TEXT", 0x100000000, 8192, 0, 8192, 5, 5, 2, 0
        )
        + sections
    )
    strings = b"\0"
    symbols = b""
    for name, ordinal in [
        (b"_SecTrustSettingsCopyCertificates", 1),
        (b"_SecTrustSettingsCopyTrustSettings", 1),
        (b"_SCDynamicStoreCreateWithOptions", 2),
        (b"_SCDynamicStoreCopyValue", 2),
        (b"_kSCDynamicStoreUseSessionKeys", 2),
        (b"_kCFAllocatorDefault", 3),
        (b"_kCFAllocatorNull", 3),
        (b"_kCFBooleanFalse", 3),
    ]:
        symbols += struct.pack("<IBBHQ", len(strings), 1, 0, ordinal << 8, 0)
        strings += name + b"\0"
    commands.append(struct.pack("<6I", 2, 24, 8192, 8, 8320, len(strings)))
    commands.append(
        struct.pack(
            "<II16sQQQQ4I",
            0x19,
            72,
            b"__LINKEDIT",
            0x100002000,
            4096,
            8192,
            len(symbols + strings),
            1,
            1,
            0,
            0,
        )
    )
    header = struct.pack(
        "<8I",
        0xFEEDFACF,
        cpu,
        0 if cpu == 0x0100000C else 3,
        2,
        len(commands),
        len(b"".join(commands)),
        0x200085,
        0,
    )
    return bytearray(
        (header + b"".join(commands)).ljust(4096, b"\0")
        + bytes.fromhex("1f2003d5") * 8
        + bytes(4064)
        + symbols
        + strings
    )


def command_offset(data, command, occurrence=0):
    """Locate a public load command for controlled corruption of our own fixture."""
    offset = 32
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        kind, size = struct.unpack_from("<II", data, offset)
        if kind == command:
            if occurrence == 0:
                return offset
            occurrence -= 1
        offset += size
    raise AssertionError("Fixture command not found")


def put(data, offset, value, fmt="<I"):
    struct.pack_into(fmt, data, offset, value)
    return data


def append_command(data, command):
    count, size = struct.unpack_from("<II", data, 16)
    data[32 + size : 32 + size + len(command)] = command
    put(data, 16, count + 1)
    put(data, 20, size + len(command))
    return data


class ArtifactCLI(unittest.TestCase):
    def check(self, data, diagnostic=None):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "zc"
            path.write_bytes(data)
            result = subprocess.run(
                [sys.executable, str(CLI), str(path)],
                capture_output=True,
                text=True,
                timeout=10,
            )
        self.assertNotIn("Traceback", result.stderr)
        if diagnostic is None:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("PASS", result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn(diagnostic, result.stderr)

    def test_thin_arm64_and_x64_minimum_15(self):
        for cpu in (0x0100000C, 0x01000007):
            with self.subTest(cpu=cpu):
                self.check(fixture(cpu))

    def test_exact_minimum_not_lower_or_higher(self):
        for minimum in (0x000B0000, 0x000E0000, 0x000F0001, 0x000F0100, 0x00100000):
            with self.subTest(minimum=minimum):
                self.check(fixture(minimum=minimum), "minOS must be exactly 15.0.0")

    def test_header_and_command_bounds(self):
        for data, diagnostic in [
            (b"", "header"),
            (b"not a Mach-O" * 4, "thin little-endian 64-bit Mach-O"),
            (put(fixture(), 0, 0xCAFEBABE), "thin little-endian 64-bit Mach-O"),
            (put(fixture(), 4, 7), "architecture"),
            (put(fixture(), 12, 6), "executable"),
            (put(fixture(), 16, 0xFFFFFFFF), "load commands"),
            (put(fixture(), 20, 0xFFFFFFFF), "load commands"),
            (put(fixture(), 36, 0), "command size"),
            (put(fixture(), 36, 25), "command size"),
            (put(fixture(), 36, 0xFFFFFFF8), "command size"),
            (put(fixture(), 40, 2), "macOS"),
            (put(fixture(), 52, 1), "build version"),
            (put(fixture(), 32, 0x1B), "missing macOS version"),
        ]:
            with self.subTest(diagnostic=diagnostic, prefix=data[:40]):
                self.check(data, diagnostic)

    def test_all_three_frameworks_must_be_strong_delayed(self):
        for index in range(3):
            for flags in (0, 1, 2, 4, 9, 10, 12, 15, 24):
                data = fixture()
                offset = command_offset(data, 0xC, index)
                with self.subTest(index=index, flags=flags):
                    self.check(put(data, offset + 24, flags), "strong delayed-init")
            for command in (0x80000018, 0x8000001F, 0x80000023, 0x20):
                data = fixture()
                offset = command_offset(data, 0xC, index)
                with self.subTest(index=index, command=command):
                    self.check(put(data, offset, command), "strong delayed-init")
            data = fixture()
            self.check(
                put(data, command_offset(data, 0xC, index), 0x1B), "missing framework"
            )

    def test_framework_paths_marker_and_duplicates(self):
        for relative, value, diagnostic in [
            (8, 24, "strong delayed-init"),
            (12, 0, "strong delayed-init"),
            (8, 0xFFFFFFFF, "dylib path"),
        ]:
            data = fixture()
            self.check(
                put(data, command_offset(data, 0xC) + relative, value), diagnostic
            )
        data = fixture()
        offset = command_offset(data, 0xC)
        length = struct.unpack_from("<I", data, offset + 4)[0]
        data[offset + 28 : offset + length] = b"x" * (length - 28)
        self.check(data, "unterminated dylib path")
        data = fixture()
        offset = command_offset(data, 0xC)
        length = struct.unpack_from("<I", data, offset + 4)[0]
        original = bytes(data[offset : offset + length])
        self.check(append_command(data, original), "duplicate framework")
        for command in (0xC, 0x80000018, 0x8000001F, 0x80000023, 0x20):
            alias = put(bytearray(original), 0, command)
            alias[28:35] = b"/Other_"
            self.check(append_command(fixture(), alias), "non-system framework path")
        # Legacy dylib_command with no extended flags is not delayed-init.
        legacy = bytearray(original)
        put(legacy, 8, 24)
        put(legacy, 12, 2)
        legacy[24:] = original[28:] + bytes(4)
        data = fixture()
        data[offset : offset + length] = legacy
        self.check(data, "strong delayed-init")

    def test_header_flags_and_conflicting_versions(self):
        for flags in (0, 4, 0x184):
            self.check(put(fixture(), 24, flags), "two-level")
        self.check(put(fixture(), 28, 1), "reserved header")
        for command in (
            struct.pack("<6I", 0x32, 24, 1, 0x000F0000, 0, 0),
            struct.pack("<4I", 0x24, 16, 0x000F0000, 0),
        ):
            self.check(append_command(fixture(), command), "conflicting")

    def test_delay_sections_must_be_nonempty_file_backed_code(self):
        for index in (0, 1):
            for relative, value, fmt, diagnostic in [
                (0, 0, "<I", "missing delay section"),
                (16, 0, "<I", "section segment"),
                (32, 0, "<Q", "section VM range"),
                (40, 0, "<Q", "nonempty"),
                (40, 0xFFFFFFFFFFFFFFFF, "<Q", "section VM range"),
                (48, 0xFFFFFFFF, "<I", "section file range"),
                (48, 0, "<I", "section file range"),
                (64, 1, "<I", "file-backed instructions"),
                (64, 0, "<I", "file-backed instructions"),
            ]:
                data = fixture()
                section = command_offset(data, 0x19) + 72 + 80 * index
                with self.subTest(index=index, relative=relative, value=value):
                    self.check(put(data, section + relative, value, fmt), diagnostic)
        data = fixture()
        data[4096:4112] = bytes(16)
        self.check(data, "nonzero code")

    def test_segment_bounds_and_section_count(self):
        for relative, value, fmt, diagnostic in [
            (40, 0xFFFFFFFFFFFFFFFF, "<Q", "segment file range"),
            (48, 0xFFFFFFFFFFFFFFFF, "<Q", "segment file range"),
            (64, 0xFFFFFFFF, "<I", "section count"),
            (60, 1, "<I", "executable segment"),
        ]:
            data = fixture()
            self.check(
                put(data, command_offset(data, 0x19) + relative, value, fmt), diagnostic
            )
        data = fixture()
        section = command_offset(data, 0x19) + 72
        data[section + 80 : section + 160] = data[section : section + 80]
        self.check(data, "duplicate delay section")
        self.check(fixture()[:4100], "segment file range")

    def test_native_imports_cannot_be_removed_defined_weak_or_redirected(self):
        for index in range(8):
            for relative, value, fmt in [
                (0, 0, "<I"),  # Empty symbol name.
                (4, 0x0F, "<B"),  # Defined external instead of import.
                (4, 0xE1, "<B"),  # Debug symbol instead of import.
                (5, 1, "<B"),  # Undefined symbol cannot have a section.
                (6, 0x0140, "<H"),  # N_WEAK_REF.
                (6, 0x0180, "<H"),  # N_REF_TO_WEAK.
                (6, 0xFE00, "<H"),  # Dynamic lookup ordinal.
                (6, 0, "<H"),  # Self ordinal.
                (8, 1, "<Q"),  # Common symbol, not undefined import.
            ]:
                with self.subTest(index=index, relative=relative, value=value):
                    self.check(
                        put(fixture(), 8192 + index * 16 + relative, value, fmt),
                        "native import",
                    )
        self.check(put(fixture(), 8192 + 6, 0x0300, "<H"), "native import")

    def test_symbol_table_bounds_and_missing_table(self):
        for relative, value, diagnostic in [
            (0, 0x1B, "missing LC_SYMTAB"),
            (8, 0xFFFFFFFF, "symbol table"),
            (12, 0xFFFFFFFF, "symbol table"),
            (16, 0xFFFFFFFF, "string table"),
            (20, 0xFFFFFFFF, "string table"),
            (16, 8192, "overlapping symbol/string tables"),
        ]:
            data = fixture()
            self.check(put(data, command_offset(data, 2) + relative, value), diagnostic)
        self.check(put(fixture(), 8192, 0xFFFFFFFF), "symbol string index")
        data = fixture()
        data[-1] = 65
        self.check(data, "unterminated symbol name")
        data = fixture()
        offset = command_offset(data, 2)
        self.check(
            append_command(data, bytes(data[offset : offset + 24])),
            "duplicate LC_SYMTAB",
        )


if __name__ == "__main__":
    unittest.main()
