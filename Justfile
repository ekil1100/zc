default:
    @just --list

install:
    zig build -Doptimize=ReleaseFast
    bash scripts/install/local-dev-install.sh
