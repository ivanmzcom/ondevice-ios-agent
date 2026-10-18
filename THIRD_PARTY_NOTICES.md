# Third-party notices

See the prominent attributions in README.md and the exact license texts in `licenses/`.
No upstream copyright or permission header has been removed from any source file.

## Application, tunnel and runner

- **esp32-iphone-agent**: Copyright (c) 2026 Henry Yuan, MIT
  (`licenses/esp32-iphone-agent-MIT.txt`). Four model/JSON files are byte-identical
  copies. The Live Activity sources, lifecycle and prompt concepts are adaptations.
- **idevice**: Copyright 2026 Jackson Coxson, MIT (`licenses/cargo/idevice-0.1.68/`).
  The license is kept for the code inspired by its heartbeat client as well.
- **LocalDevVPN / StosVPN**: Copyright (c) 2025 SideStore Team, StosVPN License
  (`licenses/LocalDevVPN-StosVPN.txt`, reproduced in full).
  The `Tunnel/` extension is **based on** the LocalDevVPN/StosVPN loopback technique,
  consulted at https://github.com/seomin0610/LocalDevVPN, revision `8a97427` (a fork of
  SideStore/StosVPN). The file `TunnelProv/PacketTunnelProvider.swift` there says it was
  created by Stossy11. Both tunnel source files carry this attribution. The project is not
  distributed under the LocalDevVPN or StosVPN name or branding, and it is not a copy of
  that project. Whether the code is a derivative work has not been confirmed with its
  authors, so the license's attribution and "based on" conditions are met as if it were.
- **WebDriverAgent**: Copyright (c) 2015-present, Facebook, Inc. All rights reserved.
  BSD-3-Clause-style license (`runner/LICENSE`). Keep the attribution and disclaimer, and
  respect the non-endorsement condition. Local changes are in
  `runner/WebDriverAgentLib/Commands/FBDebugCommands.m`.
- `runner/WebDriverAgentLib/Routing/FBHTTPStatusCodes.h`: Copyright (C) 2013
  Neo Visionaries Inc., Apache-2.0 (`licenses/Apache-2.0.txt`).
- `runner/WebDriverAgentLib/Utilities/LRUCache/{LRUCache,LRUCacheNode}.{h,m}`: Apache-2.0
  file headers, kept unmodified (the files are byte-identical to upstream commit `02cb92f`).
  Their header says "See the NOTICE file distributed with this work". Here is where the
  files come from and what was checked:
  - They were added to appium/WebDriverAgent in commit
    `7e36b8f4846f3a24177b1479caa3cdd45396adf9` (PR #510, 2021, git author Mykola Mokhnach),
    and later changed in `7ecf758`, `46dc417` and `fb52865`. The PR does not say they were
    taken from another project.
  - No NOTICE file exists in the repository tree at the introducing commit, at the pinned
    commit, or at the current default-branch root.
  - No NOTICE file exists in the published npm package `appium-webdriveragent@16.15.3`,
    whose integrity was verified and whose gitHead is the pinned commit.
  - Conclusion: upstream distributed no NOTICE file with this work. Apache-2.0 §4(d)
    applies only when the Work includes a NOTICE file, so there is nothing to carry forward.
    No NOTICE, copyright holder or owner has been invented. The Apache-2.0 text is in
    `licenses/Apache-2.0.txt` and in `licenses/standard/Apache-2.0.txt`.
- **Runner `PrivateHeaders/`** (143 files) are **not distributed**. See
  `runner/PRIVATE_HEADERS_PREREQUISITE.md`.

## Rust dependencies

`DEPENDENCIES.json` lists every package in `unified-ffi/Cargo.lock`. For each one it gives
the declared license expression, the license texts shipped under `licenses/cargo/`, and the
package's role for `aarch64-apple-ios` and `aarch64-apple-ios-sim`. The roles come from a
static target/feature resolution over the locked graph and the pinned manifests. No
`cargo` command or build script was run, so these roles do not prove what ends up in a
binary.

- **AND** expressions (Unicode, crypto sublicenses) are cumulative. **OR** alternatives do
  not license away independently licensed subcomponents. No LGPL-only election is made.
- **aws-lc-sys 0.46.0** is a runtime dependency and compiles C and assembly. Its license
  files are in `licenses/cargo/aws-lc-sys-0.46.0/`. In addition,
  `licenses/cargo-embedded/aws-lc-sys-0.46.0-embedded-notices.txt` reproduces every
  distinct copyright/license comment block found in the crate's C, assembly and header
  files, plus the Perl generators of the pregenerated iOS assembly. Each block is marked
  `[selection]` or `[superset]`:
  - `[selection]`: the file is named by the default cc_builder lists for apple/aarch64, or
    reached through their `#include` closure (static analysis).
  - `[superset]`: the file ships in the crate but falls outside that selection.

  The crate's `aws-lc/LICENSE` refers to the s2n-bignum and Jitter Entropy license files,
  but the crate does not ship them, nor aws-lc's `NOTICE`. These files were recovered
  verbatim from aws/aws-lc at the exact submodule commit `fa9bc8d6`, and every crate file
  matches that commit. They are in `licenses/cargo/aws-lc-sys-0.46.0/upstream-aws-lc/`.
  For Jitter Entropy, Amazon's recorded BSD-3-Clause election is followed.
- **aws-lc-rs 1.18.2 / aws-lc-sys 0.46.0**: the root `NOTICE` of the aws-lc-rs repository
  ("AWS Libcrypto for Rust … Based on ring, Copyright Brian Smith") is not shipped in the
  crates. It is reproduced verbatim in `licenses/cargo/aws-lc-rs-1.18.2/upstream-aws-lc-rs/`.
- **ring 0.17.14** and **zlib-rs 0.6.8** are in `Cargo.lock` but are **not selected** for
  iOS or the simulator with the enabled features. idevice uses its default `aws-lc`
  feature, and flate2 uses miniz_oxide. Their license texts are kept anyway, as a
  precaution.
- **r-efi 5.3.0 / 6.0.0** (`MIT OR Apache-2.0 OR LGPL-2.1-or-later`): **MIT is elected.**
  The upstream `AUTHORS` file contains the MIT permission text and the copyright lines
  (Red Hat, Inc.; Microsoft Corporation; David Rheinsberg). It is reproduced verbatim in
  `licenses/cargo/r-efi-*/AUTHORS`. r-efi is only a dependency under
  `cfg(all(target_os = "uefi", getrandom_backend = "efi_rng"))` in getrandom 0.3.4/0.4.3,
  so it is **not selected** for iOS or the simulator.
- **ns-keyed-archive 0.1.5** (`MIT OR Apache-2.0`, author per Cargo metadata: Jackson Coxson).
  **Apache-2.0 is elected.** Upstream provides no license file or notice, so the standard
  Apache-2.0 text is supplied by this project (`licenses/standard/`). It is not an upstream
  file. No copyright line has been invented.
- **plist-macro 0.1.6** (declared `MIT` in Cargo metadata, `authors = ["Jackson Coxson"]`):
  this source tree **only references** it by name, version and checksum in
  `unified-ffi/Cargo.lock` and `DEPENDENCIES.json`; it contains no plist-macro source file
  or binary. The crate, its pinned revision `d1d48559` and its repository history publish
  no license text and no copyright notice, and its README says only "MIT". No copyright
  notice has been invented. The SPDX MIT template in `licenses/standard/` is a generic
  reference text, not an upstream file. **Follow-up for any binary or vendored-source
  release:** the MIT notice condition cannot be satisfied verbatim until upstream
  publishes a copyright notice (or the dependency is replaced).

This is not a completed compliance notice for binary releases. Building the code, checking
the selected features and linked objects, and the plist-macro follow-up above remain to be
done before any binary release.
