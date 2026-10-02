fn main() {
    println!("cargo::rerun-if-changed=build.rs");
    println!("cargo::rerun-if-env-changed=MACOSX_DEPLOYMENT_TARGET");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    assert!(
        std::env::var("MACOSX_DEPLOYMENT_TARGET").as_deref() == Ok("15.0"),
        "zc requires MACOSX_DEPLOYMENT_TARGET=15.0; build from the repository with its Cargo configuration"
    );
    // Keep the same strong system dependencies and native TLS/DNS bindings.
    // Apple ld generates both function and data first-use activation helpers.
    println!(
        "cargo::rustc-link-arg=-Wl,-delay_framework,Security,-delay_framework,SystemConfiguration,-delay_framework,CoreFoundation"
    );
    // Unsupported/ignored delay-init must fail, not produce an eager candidate.
    println!("cargo::rustc-link-arg=-Wl,-fatal_warnings");
    println!("cargo::rustc-link-arg=-Wl,-adhoc_codesign");
}
