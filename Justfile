default:
    @just --list

install:
    zig build -Doptimize=ReleaseFast
    mkdir -p ~/.local/bin
    cp zig-out/bin/zc ~/.local/bin/zc
