default:
    @just --list

install:
    rm -rf ~/.local/bin/zc
    zig build -Doptimize=ReleaseFast
    mkdir -p ~/.local/bin
    cp zig-out/bin/zc ~/.local/bin/zc
