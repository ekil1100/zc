use serde_json::{Value, json};
use zc::override_script::{materialize_source, merge};

fn yaml(text: &str) -> Value {
    serde_saphyr::from_str(text).unwrap()
}

#[test]
fn patch_replaces_whole_collections_and_keeps_source_secrets() {
    let source = "# source stays frozen\nmixed-port: 19090\nsecret: controller-secret\nproxies: []\nproxy-groups: []\nrule-providers: {old: {type: file, behavior: domain, path: old.yaml}}\nrules: ['MATCH,DIRECT']\nexternal-controller: localhost:19091\n";
    let patch =
        "mode: global\nrules: ['MATCH,REJECT']\nrule-providers: {}\nexternal-controller: null\n";
    let result = merge(source.as_bytes(), patch.as_bytes()).unwrap();
    let result = yaml(&result);
    assert_eq!(result["rules"], json!(["MATCH,REJECT"]));
    assert_eq!(result["rule-providers"], json!({}));
    assert_eq!(result["secret"], "controller-secret");
    assert!(result.get("external-controller").is_none());
    assert_eq!(
        materialize_source(source.as_bytes(), b" \r\n").unwrap(),
        source.as_bytes()
    );
}

#[test]
fn patch_rejects_unsupported_types_duplicates_and_invalid_utf8_atomically() {
    let source = b"mixed-port: 19090\nmode: rule\n";
    for patch in [
        &b"mode: global\nipv6: true"[..],
        b"dns: {}",
        b"mode: 1",
        b"allow-lan: 1",
        b"mixed-port: 65536",
        b"mixed-port: -1",
        b"mixed-port: '19090'",
        b"external-controller: []",
        b"mode: global\nmode: rule",
        b"[]",
        b"null",
        b"mode: rule\n---\nmode: global",
        b"log-level: \xff",
        b"rules: [1]",
    ] {
        assert!(merge(source, patch).is_err(), "accepted {patch:?}");
    }
    assert_eq!(source, b"mixed-port: 19090\nmode: rule\n");
    assert_eq!(
        yaml(&merge(source, b"external-controller: 'null'").unwrap())["external-controller"],
        "null"
    );
}

#[test]
fn cli_arguments_preserve_delimiters_order_and_empty_values() {
    use zc::override_script::{CliOptions, OverrideArg, parse_timeout_ms};
    let options = CliOptions::parse(&[
        "test",
        "-c",
        "source.yaml",
        "--override-script=first.lua",
        "--override-script",
        "second.lua",
        "--override-arg",
        " key =a;b=c",
        "--override-arg=key=",
        "--override-timeout-ms=60000",
    ])
    .unwrap();
    assert_eq!(options.script_path.as_deref(), Some("second.lua"));
    assert_eq!(
        options.args,
        vec![
            OverrideArg {
                key: "key".into(),
                value: "a;b=c".into()
            },
            OverrideArg {
                key: "key".into(),
                value: "".into()
            }
        ]
    );
    assert_eq!(options.timeout_ms, 60000);
    for bad in ["0", "60001", "-1", "+1", "", " 1"] {
        assert!(parse_timeout_ms(bad).is_err());
    }
    for args in [
        vec!["test", "--override-script"],
        vec!["test", "--override-arg==bad"],
        vec!["test", "--override-arg=bad"],
        vec!["test", "--override-dump-yaml"],
    ] {
        assert!(CliOptions::parse(&args).is_err());
    }
}

#[test]
fn lua_returns_table_yaml_or_nil_and_preserves_argument_bytes() {
    use zc::override_script::{Invocation, OverrideArg, evaluate};
    let invocation = Invocation {
        command: "proxy.list".into(),
        config_path: "config.yaml".into(),
        script_path: "rules.lua".into(),
        timeout_ms: 100,
        args: vec![
            OverrideArg::parse("value=old").unwrap(),
            OverrideArg::parse("value=a;b=c\nnext").unwrap(),
            OverrideArg::parse("empty=").unwrap(),
        ],
    };
    let patch = evaluate(
        br#"
        assert(input.command == 'proxy.list' and input.config_path == 'config.yaml')
        assert(input.script_path == 'rules.lua' and input.args.empty == '')
        assert(os.getenv('ZC_OVERRIDE_ARG_COUNT') == '3')
        assert(os.getenv('ZC_OVERRIDE_ARG_1_VALUE') == 'a;b=c\nnext')
        return { ['log-level'] = input.args.value, rules = {}, ['rule-providers'] = {} }
    "#,
        &invocation,
    )
    .unwrap();
    assert_eq!(
        yaml(std::str::from_utf8(&patch).unwrap()),
        json!({"log-level": "a;b=c\nnext", "rules": [], "rule-providers": {}})
    );
    assert_eq!(
        evaluate(b"return 'mode: global\\n'", &invocation).unwrap(),
        b"mode: global\n"
    );
    assert!(evaluate(b"return nil", &invocation).unwrap().is_empty());
    assert!(evaluate(b"return 42", &invocation).is_err());
}

#[test]
fn lua_evaluation_rejects_loops_cycles_memory_and_output_excess() {
    use zc::override_script::{Invocation, evaluate};
    let invocation = Invocation {
        timeout_ms: 20,
        ..Invocation::default()
    };
    for script in [
        "while true do end",
        "while true do pcall(function() while true do end end) end",
        "local t = {}; t.rules = t; return t",
        "return string.rep('x', 1024 * 1024 + 1)",
        "return { mode = string.rep('x', 128 * 1024 * 1024) }",
        "local t = {}; local p = t; for i=1,100 do p.x = {}; p = p.x end; return t",
    ] {
        assert!(
            evaluate(script.as_bytes(), &invocation).is_err(),
            "accepted {script}"
        );
    }
}

#[cfg(unix)]
#[tokio::test]
async fn executable_script_receives_contract_and_freezes_captured_bytes() {
    use std::os::unix::fs::PermissionsExt;
    use zc::override_script::{Invocation, OverrideArg, execute};
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("override.sh");
    let script = b"#!/bin/sh\n[ -z \"${HOME+x}\" ] || exit 9\n[ \"$ZC_OVERRIDE_COMMAND\" = test ] || exit 10\n[ \"$ZC_OVERRIDE_ARG_COUNT\" = 2 ] || exit 11\n[ \"$ZC_OVERRIDE_ARG_0_VALUE\" = 'a;b=c' ] || exit 12\n[ \"$ZC_OVERRIDE_ARG_EMPTY\" = '' ] || exit 13\nprintf 'mode: global\\n'\n";
    std::fs::write(&path, script).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
    let invocation = Invocation {
        script_path: path.to_str().unwrap().into(),
        command: "test".into(),
        args: vec![
            OverrideArg::parse("value=a;b=c").unwrap(),
            OverrideArg::parse("empty=").unwrap(),
        ],
        ..Invocation::default()
    };
    let result = execute(&invocation).await.unwrap();
    assert_eq!(result.patch_bytes, b"mode: global\n");
    assert_eq!(result.script.bytes, script);
    assert_eq!(result.script.name, "override.sh");
    let frozen = result
        .materialize(b"# preserved\nmixed-port: 19090\n", |effective| {
            zc::config::Config::parse(&zc::override_script::runtime_source(effective)?).map(|_| ())
        })
        .unwrap();
    assert_eq!(frozen.source_bytes, b"# preserved\nmixed-port: 19090\n");
    assert_eq!(
        yaml(std::str::from_utf8(&frozen.effective_yaml).unwrap())["mode"],
        "global"
    );
    assert_eq!(frozen.invocation, invocation);
}

#[cfg(unix)]
#[tokio::test]
async fn executable_timeout_and_both_output_limits_are_bounded() {
    use zc::override_script::{Invocation, Script, execute_bytes};
    for (script, expected) in [
        ("#!/bin/sh\nsleep 5\n", "OVERRIDE_SCRIPT_TIMEOUT"),
        (
            "#!/bin/sh\nwhile :; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n'; done\n",
            "OVERRIDE_OUTPUT_INVALID",
        ),
        (
            "#!/bin/sh\nwhile :; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n' >&2; done\n",
            "OVERRIDE_OUTPUT_INVALID",
        ),
        (
            "#!/bin/sh\nprintf secret >&2\nexit 7\n",
            "OVERRIDE_SCRIPT_EXEC_FAILED",
        ),
    ] {
        let started = std::time::Instant::now();
        let result = execute_bytes(
            &Script {
                name: "test.sh".into(),
                bytes: script.as_bytes().to_vec(),
            },
            &Invocation {
                timeout_ms: if expected == "OVERRIDE_SCRIPT_TIMEOUT" {
                    30
                } else {
                    2000
                },
                ..Invocation::default()
            },
        )
        .await;
        let error = result.unwrap_err().to_string();
        assert!(error.contains(expected), "{error}");
        assert!(!error.contains("secret"));
        assert!(started.elapsed() < std::time::Duration::from_secs(4));
    }
}

#[test]
fn public_dump_redacts_secrets_while_runtime_dump_keeps_them_and_omits_providers() {
    use zc::override_script::{dump_config_json, dump_config_yaml, dump_runtime_config_yaml};
    let source = br#"
secret: controller-secret
mixed-port: 19090
rule-providers:
  local: { type: file, behavior: domain, path: missing.yaml }
proxies:
  - name: node
    type: ss
    server: example.com
    port: 443
    password: proxy-password
    uuid: private-uuid
    sni: private-sni
    plugin: obfs
    plugin_opts: { mode: http, host: example.com }
rules: ['MATCH,node']
"#;
    let dump = dump_config_yaml(source).unwrap();
    let json: Value = serde_json::from_str(&dump_config_json(source).unwrap()).unwrap();
    for secret in [
        "controller-secret",
        "proxy-password",
        "private-uuid",
        "private-sni",
    ] {
        assert!(!dump.contains(secret));
    }
    assert_eq!(yaml(&dump)["secret"], "******");
    assert_eq!(json["proxies"][0]["sni"], "******");
    assert_eq!(
        json["proxies"][0]["plugin-opts"],
        json!({"mode": "http", "host": "example.com"})
    );
    assert!(json["proxies"][0].get("plugin_opts").is_none());
    let runtime = yaml(&dump_runtime_config_yaml(source).unwrap());
    assert_eq!(runtime["proxies"][0]["password"], "proxy-password");
    assert_eq!(runtime["secret"], "controller-secret");
    assert!(runtime.get("rule-providers").is_none());
    assert!(dump_runtime_config_yaml(b"rules: ['RULE-SET,p,DIRECT']").is_err());
}

#[test]
fn worker_request_rejects_bad_json_timeout_oversize_and_unknown_fields() {
    use zc::override_script::{
        Invocation, MAX_SCRIPT_BYTES, MAX_WORKER_INPUT_BYTES, WorkerRequest,
    };
    for input in [
        b"null".as_slice(),
        b"{}",
        b"{} trailing",
        b"{\"script\":[],\"invocation\":{},\"extra\":true}",
    ] {
        assert!(WorkerRequest::decode(input).is_err());
    }
    let mut request = WorkerRequest {
        script: b"return nil".to_vec(),
        invocation: Invocation::default(),
    };
    assert!(WorkerRequest::decode(&serde_json::to_vec(&request).unwrap()).is_ok());
    request.invocation.timeout_ms = 0;
    assert!(WorkerRequest::decode(&serde_json::to_vec(&request).unwrap()).is_err());
    request.invocation.timeout_ms = 5000;
    request.script = vec![b'x'; MAX_SCRIPT_BYTES + 1];
    assert!(WorkerRequest::decode(&serde_json::to_vec(&request).unwrap()).is_err());
    assert!(WorkerRequest::decode(&vec![b' '; MAX_WORKER_INPUT_BYTES + 1]).is_err());
}

#[test]
fn lua_rejects_invalid_utf8_sparse_and_mixed_tables_without_coercion() {
    use zc::override_script::{Invocation, evaluate};
    for script in [
        "return {mode = string.char(255)}",
        "return {rules = {[1] = 'MATCH,DIRECT', [1000000000] = 'MATCH,REJECT'}}",
        "return {rules = {[1] = 'MATCH,DIRECT', hidden = 'MATCH,REJECT'}}",
    ] {
        assert!(
            evaluate(script.as_bytes(), &Invocation::default()).is_err(),
            "accepted {script}"
        );
    }
}

#[test]
fn yaml_and_json_dumps_escape_terminal_controls_and_mapping_keys_losslessly() {
    use zc::override_script::{dump_config_json, dump_config_yaml};
    let input = json!({"external-ui": "a\u{202e}\u{009b}\u{0001}\n\"\\z", "rule-providers": {"x\u{2066}:#": {"type": "file", "behavior": "domain", "path": "not-read.yaml"}}});
    let input = serde_json::to_string(&input)
        .unwrap()
        .replace('\u{009b}', "\\u009b")
        .into_bytes();
    let yaml_text = dump_config_yaml(&input).unwrap();
    let json_text = dump_config_json(&input).unwrap();
    for text in [&yaml_text, &json_text] {
        assert!(!text.contains(['\u{202e}', '\u{009b}', '\u{0001}', '\u{2066}']));
        let dumped = yaml(text);
        let original: Value = serde_json::from_slice(&input).unwrap();
        if text == &yaml_text {
            assert_eq!(dumped["external-ui"], original["external-ui"]);
        } else {
            // Original dumpConfigJson omits this YAML-only field.
            assert!(dumped.get("external-ui").is_none());
        }
        assert_eq!(
            dumped["rule-providers"]["x\u{2066}:#"]["path"],
            "not-read.yaml"
        );
        // Actual Zig dump includes typed defaults rather than echoing input.
        assert_eq!(dumped["rule-providers"]["x\u{2066}:#"]["interval"], 86400);
        assert_eq!(dumped["rules"], json!(["MATCH,REJECT"]));
    }
}

#[test]
fn mixed_proxy_source_keeps_groups_but_proxy_patch_does_not_replace_them() {
    let source = br#"proxies:
  - {name: node, type: direct}
  - {name: existing, type: select, proxies: [DIRECT]}
proxy-groups:
  - {name: other, type: select, proxies: [REJECT]}
rules: ['MATCH,existing']
"#;
    let patch = b"proxies: [{name: ignored, type: select, proxies: [REJECT]}]\n";
    let result = yaml(&merge(source, patch).unwrap());
    assert_eq!(result["proxies"], json!([]));
    assert_eq!(result["proxy-groups"][0]["name"], "existing");
    assert_eq!(result["proxy-groups"][1]["name"], "other");
}

#[cfg(unix)]
#[tokio::test]
async fn selected_non_lua_file_must_be_executable_and_regular() {
    use zc::override_script::{Invocation, execute};
    let directory = tempfile::tempdir().unwrap();
    let file = directory.path().join("not-executable.sh");
    std::fs::write(&file, b"#!/bin/sh\nprintf 'mode: global\\n'\n").unwrap();
    let invocation = Invocation {
        script_path: file.to_str().unwrap().into(),
        ..Invocation::default()
    };
    assert!(execute(&invocation).await.is_err());
    let invocation = Invocation {
        script_path: directory.path().to_str().unwrap().into(),
        ..Invocation::default()
    };
    assert!(execute(&invocation).await.is_err());
}

#[test]
fn override_example_is_executable_with_no_provider_io() {
    use zc::override_script::{Invocation, OverrideArg, evaluate};
    let invocation = Invocation {
        command: "test".into(),
        script_path: "/isolated/override-loyalsoldier-rules.lua".into(),
        args: vec![OverrideArg::parse("proxy_group=Selected").unwrap()],
        ..Invocation::default()
    };
    let patch = evaluate(
        include_bytes!("../docs/config/examples/override-loyalsoldier-rules.lua"),
        &invocation,
    )
    .unwrap();
    let value = yaml(std::str::from_utf8(&patch).unwrap());
    assert_eq!(
        value["rule-providers"]["reject"]["path"],
        "/isolated/ruleset/reject.txt"
    );
    assert_eq!(
        value["rules"].as_array().unwrap().last().unwrap(),
        "MATCH,Selected"
    );
}

#[test]
fn materialization_must_pass_the_callers_capability_gate_even_for_nil_patch() {
    use zc::override_script::{ExecutedOverride, Invocation, Script};
    for patch in [b"".as_slice(), b"mode: direct\n"] {
        let executed = ExecutedOverride {
            script: Script {
                name: "script.lua".into(),
                bytes: b"return nil".to_vec(),
            },
            invocation: Invocation::default(),
            patch_bytes: patch.to_vec(),
        };
        let called = std::cell::Cell::new(false);
        let result = executed.materialize(b"mixed-port: 19090\n", |_| {
            called.set(true);
            anyhow::bail!("UnsupportedCapability")
        });
        assert!(called.get());
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("UnsupportedCapability")
        );
    }
}

#[test]
fn replacement_cannot_bypass_proxy_provider_member_and_yaml_entry_budgets() {
    for (key, value) in [
        (
            "proxies",
            json!(
                (0..4097)
                    .map(|i| json!({"name": format!("n{i}"), "type": "direct"}))
                    .collect::<Vec<_>>()
            ),
        ),
        (
            "proxy-groups",
            json!(
                (0..1025)
                    .map(|i| json!({"name": format!("g{i}"), "type": "select", "proxies": []}))
                    .collect::<Vec<_>>()
            ),
        ),
        (
            "proxy-groups",
            json!([{"name":"g", "type":"select", "proxies":vec!["DIRECT"; 5123]}]),
        ),
        (
            "rule-providers",
            Value::Object(
                (0..4097)
                    .map(|i| {
                        (
                            format!("p{i}"),
                            json!({"type":"file", "behavior":"domain", "path":"unused"}),
                        )
                    })
                    .collect(),
            ),
        ),
    ] {
        let patch = serde_json::to_vec(&json!({key: value})).unwrap();
        assert!(
            merge(b"mixed-port: 19090\n", &patch).is_err(),
            "accepted oversized {key}"
        );
    }
    let exact = serde_json::to_vec(&json!({"extension": vec![0; 262143]})).unwrap();
    assert_eq!(materialize_source(&exact, b"").unwrap(), exact);
    let oversized = serde_json::to_vec(&json!({"extension": vec![0; 262144]})).unwrap();
    assert!(materialize_source(&oversized, b"").is_err());
    assert!(merge(&exact, b"mode: direct").is_err());
    assert!(
        merge(
            b"{}",
            &vec![b' '; zc::override_script::MAX_OUTPUT_BYTES + 1]
        )
        .is_err()
    );
}

#[cfg(unix)]
#[tokio::test]
async fn timeout_kills_the_process_group_and_reaps_the_script_leader() {
    use zc::override_script::{Invocation, OverrideArg, Script, execute_bytes};
    let directory = tempfile::tempdir().unwrap();
    let parent = directory.path().join("parent.pid");
    let child = directory.path().join("child.pid");
    let script = Script { name: "sleep.sh".into(), bytes: b"#!/bin/sh\necho $$ > \"$ZC_OVERRIDE_ARG_PARENT\"\n/bin/sleep 10 &\necho $! > \"$ZC_OVERRIDE_ARG_CHILD\"\nwait\n".to_vec() };
    let invocation = Invocation {
        timeout_ms: 2000,
        args: vec![
            OverrideArg {
                key: "parent".into(),
                value: parent.to_str().unwrap().into(),
            },
            OverrideArg {
                key: "child".into(),
                value: child.to_str().unwrap().into(),
            },
        ],
        ..Invocation::default()
    };
    assert!(
        execute_bytes(&script, &invocation)
            .await
            .unwrap_err()
            .to_string()
            .contains("OVERRIDE_SCRIPT_TIMEOUT")
    );
    for path in [parent, child] {
        let pid: i32 = std::fs::read_to_string(path)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        let pid = rustix::process::Pid::from_raw(pid).unwrap();
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(2);
        while rustix::process::test_kill_process(pid).is_ok()
            && tokio::time::Instant::now() < deadline
        {
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        assert!(
            rustix::process::test_kill_process(pid).is_err(),
            "script process survived timeout"
        );
    }
}

#[test]
fn materialization_and_public_dumps_match_actual_zig_golden_bytes() {
    use zc::override_script::dump_config_yaml;
    for (source, effective, public) in [
        (
            include_bytes!("fixtures/state_minimal_source.yaml").as_slice(),
            include_bytes!("fixtures/state_minimal_effective.yaml").as_slice(),
            include_bytes!("fixtures/state_minimal_public.yaml").as_slice(),
        ),
        (
            include_bytes!("fixtures/state_full_source.yaml").as_slice(),
            include_bytes!("fixtures/state_full_effective.yaml").as_slice(),
            include_bytes!("fixtures/state_full_public.yaml").as_slice(),
        ),
    ] {
        assert_eq!(
            materialize_source(source, include_bytes!("fixtures/state_patch.yaml")).unwrap(),
            effective
        );
        assert_eq!(dump_config_yaml(effective).unwrap().as_bytes(), public);
    }
}

#[test]
fn provider_hash_order_and_runtime_dump_match_original_zig() {
    use zc::override_script::{dump_config_yaml, dump_runtime_config_yaml};
    let effective = materialize_source(
        include_bytes!("fixtures/state_provider_source.yaml"),
        include_bytes!("fixtures/state_provider_patch.yaml"),
    )
    .unwrap();
    assert_eq!(
        effective,
        include_bytes!("fixtures/state_provider_effective.yaml")
    );
    assert_eq!(
        dump_config_yaml(&effective).unwrap(),
        include_str!("fixtures/state_provider_public.yaml")
    );
    assert_eq!(
        dump_runtime_config_yaml(include_bytes!("fixtures/state_runtime_source.yaml")).unwrap(),
        include_str!("fixtures/state_full_runtime.yaml")
    );
    assert_eq!(
        dump_config_yaml(include_bytes!("fixtures/state_transport_source.yaml")).unwrap(),
        include_str!("fixtures/state_transport_public.yaml")
    );
    assert!(
        materialize_source(include_bytes!("fixtures/state_transport_source.yaml"), b"").is_err()
    );
}

#[test]
fn public_dump_rejects_catalog_malformed_plugin_metadata_like_zig() {
    use zc::override_script::dump_config_yaml;
    // Actual parseCatalogDocument + dumpConfigYaml returns InvalidPluginOptions.
    for proxy in [
        "{name: direct-node, type: direct, plugin-opts: {}}",
        "{name: edge, type: ss, server: example.com, port: 8388, plugin: obfs, plugin-opts: {mode: tls, host: example.com}}",
    ] {
        let source = format!("mixed-port: 9000\nproxies: [{proxy}]\n");
        assert!(dump_config_yaml(source.as_bytes()).is_err());
    }
}

#[test]
fn public_json_matches_original_zig_typed_redacted_model() {
    use zc::override_script::dump_config_json;
    let source = include_bytes!("fixtures/state_full_source.yaml");
    assert_eq!(
        yaml(&dump_config_json(source).unwrap()),
        yaml(include_str!("fixtures/state_full_public.json"))
    );
}

#[test]
fn redaction_does_not_destroy_provider_names_that_match_secret_fields() {
    let source = br#"mixed-port: 9000
secret: private
rule-providers: {secret: {type: file, behavior: domain, path: rules.yaml}}
"#;
    let value = yaml(&zc::override_script::dump_config_yaml(source).unwrap());
    assert_eq!(value["secret"], "******");
    assert_eq!(value["rule-providers"]["secret"]["path"], "rules.yaml");
}
