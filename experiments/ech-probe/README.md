# HarmonyOS ECH experiment

This is an isolated feasibility probe, not the normal application's network layer.
The native probe performs allowlisted, credential-free GET requests to `linux.do`
and the public Cloudflare control site. The optional browser trial reuses the
normal app's existing forum session and same-origin request adapter. The signed
prototype uses the same app identity to preserve app data during device testing.

## What counts as success

The ECH path requires Rustls `EchStatus::Accepted` before sending HTTP. It retains
WebPKI hostname/certificate verification and accepts neither GREASE nor a silent
plaintext fallback as success. A trace success additionally requires HTTP 200,
`h=linux.do`, and server-reported `sni=encrypted`. API HTTP 403 is recorded separately
from TLS success. No Cookie, password, authorization token, TLS key log, or response
content from the forum is exported. Only trace host/TLS/SNI and public topic count
are summarized.

The same IP is tested with TLS 1.3 without ECH and with mandatory ECH. Different IPs
and DoH providers can have different connectivity. Tests do not change system DNS,
VPN settings, certificates, or certificate validation.

## Published trial package

The v0.3.1 GitHub pre-release includes a separately labelled `edge-ech-trial-debug.hap`,
built with `--browser-trial --edge-doh --startup-diagnostics`. The ordinary debug HAP
does not enable this trial. Both packages have the same app identity and replace
one another while preserving app data; they cannot be installed side by side.
They use a development profile limited to authorized devices. Other devices need
their own developer signature, as described in the project README.

The trial's forum requests and images use ArkWeb after a valid CSRF receipt; the
Rustls library is a diagnostic probe, not a replacement transport for every app
operation. Wi-Fi/5G observations below were made on 2026-10-19/20 and are not a
guarantee for other networks, resolver availability, fresh login, uploads or
long-term verification recovery. Third-party notices are bundled in the HAP at
`resources/rawfile/THIRD_PARTY_LICENSES.txt` and supplied as a release attachment.

## Build and reproduce

Prerequisites: the normal HarmonyOS app already builds/signs through DevEco CLI;
Rust stable, its `aarch64-unknown-linux-ohos` target, and the installed OHOS SDK.
`ECH_OHOS_SDK_ROOT` can specify the SDK's `native` directory.

From the project root:

```sh
rustup target add aarch64-unknown-linux-ohos
experiments/ech-probe/build-ohos.sh --lib
python3 experiments/ech-probe/prepare-prototype.py
cd artifacts/ech-native-20261018/prototype-app
devecocli build
devecocli run --module entry --skip-build --device CodexPhone
```

The preparation script creates an ignored copy of the current app, adds the native
async wrapper and the experimental page there, and fetches a short-lived seed for
the optional handshake-isolation control. The ordinary app source/build stays
independent of the Rust toolchain. On device, open My → About/connection diagnostics
→ connection probe. Run the phone-side DoH path to verify a self-contained chain.
The seed path deliberately expires at the resolver TTL (capped at 600 seconds) and
does not prove that the phone can perform DoH itself.

The phone disallows executing standalone binaries from the debug directory. Use
the signed N-API prototype; do not change SELinux or device security policy. To
return to the normal local app, run the normal project's `devecocli run --skip-build`
from `app/`, without uninstalling or clearing app data.

For the browser integration trial, prepare the copy with
`python3 experiments/ech-probe/prepare-prototype.py --browser-trial --edge-doh`, then build and
run that copy on the explicitly selected test device. The prototype initializes
the engine and configures the selected DoH before creating the normal Web profile, then
enables the existing browser request adapter only after a successful CSRF probe.
Phase diagnostics contain no URLs, account identifiers or response bodies. The
session trace check uses that same adapter and logs only filtered host/TLS/SNI.
Detailed media/frame diagnostics are omitted unless `--media-diagnostics` is
explicitly provided; distributed trial packages do not include that option.

On the physical API26 phone, initial `about:blank` navigation previously cancelled
recovery, and waiting for full-page completion exceeded the recovery deadline.
The app now leaves initial navigation to the controller and permits a read-only
CSRF probe from a usable same-origin top-level document. A genuine JSON CSRF
receipt is still required. The final trial passed startup and process-restart
recovery, server-confirmed ECH, topic reads and existing-account display on Wi-Fi
with VPN/proxy off. Later checks also verified image loading, animated avatars
and reaction images. Uploads, fresh login and long-term clearance recovery
remain outside the verified scope. This is not a production setting. The prototype's “恢复系统 DNS”
button clears the process's temporary DNS setting before returning to a normal build.

On 2026-10-19, the phone's 5G connection timed out while querying kudo DoH, while
edge DoH returned an ECH configuration. Native requests to both target addresses
failed in ordinary TLS and succeeded with required ECH, verified certificates and
HTTP 200. The `--edge-doh` option selects that resolver for the browser trial and
its Web diagnostics; omitting it retains kudo for comparison. This is a current
network observation, not a guarantee about either resolver on other networks.

Startup recovery now waits for a newly committed, usable same-origin document and
bridge, uses one 25-second budget, retries a main-frame connection reset once,
and never replays a write. `--startup-diagnostics` adds only stage, readiness
categories and numeric error codes. Final device evidence is recorded under the
ignored `artifacts/session-startup-fix-20261019/` directory.

## Sources and dependencies

- [Rustls ECH example](https://github.com/rustls/rustls/blob/v/0.23.35/examples/src/bin/ech-client.rs)
  and [ECH status API](https://docs.rs/rustls/0.23.45/rustls/client/enum.EchStatus.html).
- [Rust OpenHarmony target](https://doc.rust-lang.org/rustc/platform-support/openharmony.html).
- Rustls 0.23.45 with AWS-LC HPKE, WebPKI roots, Hickory protocol 0.26.3,
  httparse/chunked-transfer, base64, serde_json; exact versions/checksums in Cargo.lock.
- Community DoH URLs were read from the public preset metadata in
  `xuemk/linuxdo-android` commit `a7e6c81bccee1eec8f75542a91fcd6c0f24e11b5`.
  Its closed SDK is not used or redistributed by this experiment.

Device evidence and build/test receipts are kept in the ignored
`artifacts/ech-native-20261018/` directory. Project findings are in
`docs/ech-feasibility.md`.
