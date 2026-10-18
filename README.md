# ondevice-ios-agent

EXPERIMENTAL SOURCE-ONLY PUBLICATION. NOT A BINARY RELEASE. No build, signing,
installation or phone operation has been run on this tree (see "Build layout").

This is the source of three parts: the on-device Swift app, its Rust C ABI, and a native
WebDriverAgent runner with local compact-observation/target changes. It contains no
pairing record, credentials, device data or signed binaries. It also leaves out the
original hardware firmware and the Appium Node host package.

**One input is deliberately left out.** The runner's `PrivateHeaders/` directory is not
distributed. See `runner/PRIVATE_HEADERS_PREREQUISITE.md`. As a result this tree is
**not** a complete, reproducible or offline-buildable distribution.

## On-device execution is not local inference

**The agent runs on the iPhone, but the model does not.** Every model request is sent to
a remote AI endpoint over the network: the OpenAI-compatible provider you configure
(the built-in presets point at hosted services such as OpenAI, OpenRouter, Google Gemini,
Alibaba Cloud DashScope and DeepSeek) or, in Debug builds only, the ChatGPT Responses
endpoint. Requests can include your task text and the observed screen content (UI
element tree; the model client can also send screenshots) of the apps the agent operates. Review the
data you expose and the terms, privacy policy and data-retention rules of the service
you use before running it. Nothing in this repository runs a model locally.

**Experimental ChatGPT sign-in (Debug builds only).** `Core/Sources/UnifiedAgentCore/ChatGPT/`
and `App/ChatGPTPlan.swift` implement an experimental "Sign in with ChatGPT" client
for ChatGPT plan usage. The on-device loopback redirect has never been verified on an
iPhone. This support is not affiliated with or endorsed by OpenAI, and no warranty is
given that your account, plan or region is entitled to use it, or that OpenAI will keep
accepting it. You are responsible for complying with OpenAI's terms.

## Prominent upstream attribution

Based in part on **esp32-iphone-agent by Henry Yuan** (2026, MIT). Taken from it: the
model-client sources, JSON support, adapted Live Activity UI and prompt concepts. The full
license is in `licenses/esp32-iphone-agent-MIT.txt`, and the existing file headers are
unchanged.

**This project's tunnel extension (`Tunnel/`) is based on LocalDevVPN / StosVPN by the
SideStore Team (2025).** It uses the same on-device loopback technique as
`TunnelProv/PacketTunnelProvider.swift` in https://github.com/seomin0610/LocalDevVPN at revision
`8a97427bcbdf90cbb62c2eadb8cfe5751c50eccc` (a fork of SideStore/StosVPN). The
copyright and permission notice is reproduced in full in
`licenses/LocalDevVPN-StosVPN.txt` (StosVPN License). This project is **not** LocalDevVPN
or StosVPN. It is not a re-upload of either, does not use their names or branding for its
product, and is not endorsed by their authors.

Rust uses **idevice by Jackson Coxson (MIT)**, revision
`3854a5df4a5a6dee71ffce4d8befc2ea356a8065`. See `DEPENDENCIES.json`, `licenses/cargo/` and
`licenses/cargo-embedded/`.

The native **WebDriverAgent** runner comes from Appium WebDriverAgent v16.15.3, commit
`02cb92f0e93c8b021443bcbb8eeb80932c113220`. Local additions are in
`runner/WebDriverAgentLib/Commands/FBDebugCommands.m`. The root `runner/LICENSE` is
BSD-3-Clause-style (Facebook, Inc., 2015-present). Some embedded sources (HTTP status
codes, LRUCache) are Apache-2.0, and the npm metadata says Apache-2.0. Treat it as a
mixed tree, not as a single license. See `THIRD_PARTY_NOTICES.md`.

## License

The root `LICENSE` grants the MIT License (Copyright (c) 2026 Iván Moreno) **only** for
project-owned or authorized contributions. It does not relicense anything else:
third-party files and third-party portions of files keep their original licenses and
notices (esp32-iphone-agent MIT, StosVPN License, WebDriverAgent BSD-3-Clause-style,
Apache-2.0 runner sources, idevice MIT and the Rust crates in `licenses/`). The list is
at the end of `LICENSE` and in `THIRD_PARTY_NOTICES.md`.

### Source distribution (this tree)

- All third-party license texts and notices referred to above ship in `licenses/`,
  `runner/LICENSE` and `Core/LICENSE.upstream-MIT`. Upstream file headers are unchanged.
- LRUCache: upstream distributed no NOTICE file, so there is none to carry forward
  (details in `THIRD_PARTY_NOTICES.md`).
- Rust crates are referenced by name, version and checksum in `unified-ffi/Cargo.lock`;
  no crate source or binary is included. License elections for r-efi and ns-keyed-archive
  are documented in `THIRD_PARTY_NOTICES.md`.
- `runner/PrivateHeaders/` is absent, so it is not redistributed.

### Future binary releases (not done; separate work)

A binary release would need its own compliance pass:

- Ship the same notices with the binary, and confirm the linked Rust crates, features and
  native C/assembly objects with `cargo metadata`/`cargo tree` and the built artefacts.
- `plist-macro 0.1.6` publishes no copyright notice to reproduce; resolve this upstream or
  replace the dependency first.
- The runner cannot be built without a locally supplied `PrivateHeaders/` copy, whose
  Apple usage rights are unknown and are the builder's responsibility.
- Validate the runner icon in an asset-catalog build.

## Provenance limitations

- The experimental ChatGPT files (`Core/Sources/UnifiedAgentCore/ChatGPT/`,
  `App/ChatGPTPlan.swift` and their tests) trace back to an **uncommitted local draft**
  in a working copy of esp32-iphone-agent, as their headers say. That draft's history
  cannot be verified from this tree. This README does not certify clean-room development
  or ownership of those files. No additional third-party material has been specifically
  identified in them; any material from esp32-iphone-agent stays under its MIT notice,
  which is included.
- StikDebug is AGPLv3 and is not intentionally incorporated. The reviewed source comparison
  found no dependency on it and no match of five consecutive non-trivial lines. That
  comparison is a heuristic. It does not establish independent authorship as a legal matter.
- Some comments refer to internal design notes (`*_REPORT.md`, `CHATGPT_AUTH_GATE.md`,
  `scripts/check-vendored.sh`, `../../real/...`) that are not part of this repository.
  "Hermes" in route and schema names (`hermes/observation`, `hermes-target/1`) is an
  internal identifier for the patched runner endpoints.

## Runner icon

`runner/WebDriverAgentRunner/Assets.xcassets/AppIcon.appiconset/icon-1024.png` is an
**original placeholder**, generated by a small Python standard-library PNG writer. No input
image, font or logo was used. Details:

- 1024×1024, 8-bit RGB, no alpha.
- Background `#2E3A48`.
- A centred ring in `#E6EDF3` with outer radius 360 px and inner radius 280 px.
- A centred 200×200 square in `#4FA3D9`.
- Pixels are classified by integer arithmetic on pixel centres, with no anti-aliasing.
- Encoded with zlib level 9.
- SHA-256 `f949904ea4f5d04ab83c95b1d6e8de37a425ab46227f0fb120b928b47948d7ab`.

It is included in the project's MIT grant as project-owned material. That is a license
for whatever rights exist in it, not a claim about whether it can be protected by
copyright. Replace it with your own artwork if you prefer. `tools/verify_export.py`
accepts this exact file (path, hash, PNG signature and dimensions) and rejects every
other binary file.

## Build layout (instructions only, not executed)

You need Xcode and the iOS SDK, XcodeGen, Rust with the iOS target, and the usual native
build tools that the locked Rust dependencies require (aws-lc-sys compiles C and assembly).

1. `cargo build --manifest-path unified-ffi/Cargo.toml --locked --release --target aarch64-apple-ios --target-dir build/rust`
2. `xcodegen generate --spec project.yml`
3. Set up your own signing and entitlements locally. The app needs the loopback
   Network Extension entitlement and a user-imported pairing record. Neither is supplied.
4. Runner: first meet the local-only prerequisite in
   `runner/PRIVATE_HEADERS_PREREQUISITE.md`. Whether you have the right to use those files
   is your responsibility. Then build `runner/WebDriverAgent.xcodeproj` with your own signing
   configuration. This native-only layout needs no Node install and no upstream publication
   automation.

No build, native CI, signing, installation or phone operation was run here. Whether the
code compiles, and whether builds are reproducible, has not been checked. This is
experimental source, not a tested release. Remote Rust dependencies are pinned in
`Cargo.lock` but not vendored for offline builds.

## Verifying this tree

Run `python3 tools/verify_export.py .` to check the tree against the allowlist
(`EXPORT_MANIFEST.json`) and run the scan. A clean result is an allowlist, hash and
heuristic check only. It is not legal clearance or exhaustive secret detection, and
nothing here is legal advice or a legal guarantee.
