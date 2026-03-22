# Runtime Config Override

`zc` supports runtime config override for commands that load config (`start`, `tui`, `test`, `doctor`, `proxy ...`).

Override is in-memory only and does not rewrite profile files.
You can bind a persistent override script to the current config profile via `zc config override`.

## CLI Flags

- `--override-script <path>`: run override script.
- `--override-arg <k=v>`: repeatable key/value arguments passed to script.
- `--override-timeout-ms <n>`: script timeout, default `500`.

For merged config output, use:

- `zc config dump` (YAML)
- `zc config dump --json` (JSON)
- `zc config dump --no-override` (ignore all override scripts and dump source config)

## Persistent Binding (Per Config)

- `zc config override <script.lua>`: bind a persistent override script to current config.
- `zc config override --clear`: clear persistent binding for current config.
- `zc config override`: show current config binding status.

Persistence scope is `meta.json -> configs.<key>.override_script` (per-config only).
When setting override:

- script is copied into managed directory: `~/.config/zc/override/`
- merged config is prepared immediately and missing rule-provider files are auto-downloaded
- if daemon is running, config is auto-applied (`auto`: try hot, fallback restart)

When clearing override:

- only managed override script copy is removed
- downloaded ruleset files are kept as cache

Runtime priority:

1. CLI `--override-script` (highest, one-shot)
2. persisted `zc config override` binding
3. no override

## Script Contract

### Mode A: Lua script (`*.lua`)

`zc` executes lua script and expects:

- return `table`: override object
- return `nil`: no override

Requirement: `luajit` or `lua` executable must be available in runtime environment.

Global input available in script:

```lua
input.command      -- string, e.g. "test" / "proxy.list"
input.config_path  -- base config path or ""
input.script_path  -- resolved override script path
input.args         -- key/value map from --override-arg
```

Example:

```lua
return {
  mode = "global",
  ["log-level"] = "debug",
  ["mixed-port"] = 7899,
}
```

### Mode B: executable script (non-lua)

Executable script should print YAML override map to stdout.

Example output:

```yaml
mode: global
log-level: debug
```

## Merge Rules

- scalar keys: replace
- map key `rule-providers`: whole-map replace
- list keys (`proxies`, `proxy-groups`, `rules`): whole-list replace
- unknown/unsupported key: error (`OVERRIDE_OUTPUT_INVALID`)

`RULE-SET` in `rules` is supported via `rule-providers`.
Runtime preparation behavior:

- missing provider file + `url` present: download required (failure returns error)
- existing provider file + `url` present + interval due: best-effort refresh (failure keeps cached file)
- `zc test` exception: if the provider file already exists, skip interval-based refresh and reuse the local cache
- missing provider file without `url`: `RULE_PROVIDER_FILE_NOT_FOUND`

## Dump Output

`zc config dump` prints merged config with sensitive fields redacted (`password`, `uuid`, `secret`, `sni`).
Persistent override (`zc config override ...`) and temporary override flags are both applied before dump.

## Error Codes

- `OVERRIDE_SCRIPT_NOT_FOUND`
- `OVERRIDE_SCRIPT_EXEC_FAILED`
- `OVERRIDE_SCRIPT_TIMEOUT`
- `OVERRIDE_OUTPUT_INVALID`
- `OVERRIDE_MERGE_FAILED`
- `OVERRIDE_OPTION_DEPRECATED`
- `RULE_PROVIDER_DOWNLOAD_FAILED`
- `RULE_PROVIDER_FILE_NOT_FOUND`
- `CONFIG_OVERRIDE_APPLY_FAILED`
- `CONFIG_DUMP_FAILED`

## Example

- Lua rules override example: `docs/config/examples/override-loyalsoldier-rules.lua`
