# Changelog

## [Unreleased]

### Changed
- Align v1.0 release planning with code-first validation.
- Require Zig 0.16.0+ across project policy, CI, release workflow, and package metadata.
- Remove TUI from the v1.0 scope and from CLI help/dispatch.
- Replace stale root `ROADMAP.md` / `TASKS.md` planning entry points with `docs/README.md` and `docs/roadmap/v1.0.md`.
- Reframe public documentation around the currently implemented CLI, daemon runtime, minimal API, install validation, and compatibility boundaries.

### Archived
- Move stale install, benchmark, roadmap, API versioning, TUI, and historical agent planning drafts under `docs/archive/`.
- Archive the old full API v1 OpenAPI draft because it described endpoints and WebSocket events that are not implemented in v1.0.

### Known Blockers Before v1.0.0
- Decide and enforce the HTTP/SOCKS5 outbound policy: implement them or reject them early in validation/docs/migrator.
- Fix `zc test --json` so it emits valid JSON or remove it from the advertised JSON contract.
- Pass the final smoke gate before tagging `v1.0.0`.

## [0.1.0] - 2025-12

### Added
- Initial project structure.
- Zig build system.
- Basic proxy forwarding.
- YAML config parsing.
