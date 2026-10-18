# Standard license texts supplied by this project

These files are **standard license texts supplied by this project**. They are not
copies of files distributed by the upstream packages that refer to them.

| File | Source | SHA-256 |
|---|---|---|
| `Apache-2.0.txt` | https://www.apache.org/licenses/LICENSE-2.0.txt (retrieved 2026-10-18) | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` |
| `MIT-SPDX-template.txt` | https://raw.githubusercontent.com/spdx/license-list-data/v3.29.0/text/MIT.txt | `b05785f9f18e6716bab63424b11454513b9943a222595b70411009202fc592b5` |

`MIT-SPDX-template.txt` is SPDX's **template**. Its `<year> <copyright holders>` line is a
placeholder. It is not filled in for any package, because no upstream copyright line exists
to fill it with.

Packages that point here:

- `ns-keyed-archive 0.1.5` declares `MIT OR Apache-2.0`. The published crate, its pinned
  VCS revision `f8cec65e865cb48301d33b2244bec45a2f3d2bc2` and its repository history
  contain no license file, copyright line or attribution text. This project **elects
  Apache-2.0** for this package and supplies the standard text above. Apache-2.0 §4(c)
  requires keeping attribution notices that exist in the Source form; none exist upstream,
  so none are reproduced, and none have been invented.
- `plist-macro 0.1.6` declares `MIT` only. The published crate, pinned revision
  `d1d48559ddc8e9bd263f36180bbe1d4f2a3d55e5` and repository history contain no license
  file and no copyright line. Its README says only "MIT". Its Cargo metadata lists
  `authors = ["Jackson Coxson"]`, which is metadata and not a copyright notice. MIT requires
  "the above copyright notice", but upstream never published one, so the condition cannot
  be met verbatim. This source tree only references plist-macro (name, version, checksum)
  and does not include its source or a binary, so this is a **follow-up for binary or
  vendored-source releases**, not part of the source files distributed here (see
  THIRD_PARTY_NOTICES.md).
