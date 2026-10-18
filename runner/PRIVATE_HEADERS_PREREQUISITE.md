# Local-only prerequisite: `runner/PrivateHeaders/` (not distributed)

The native runner project (`WebDriverAgent.xcodeproj`) refers to 143 header files
under `runner/PrivateHeaders/` (XCTest, UIKitCore, TextInput, MobileCoreServices,
AccessibilityUtilities). In upstream WebDriverAgent these files declare private Apple
framework interfaces, and most of them say they were generated with the `ipsw` tool
from Apple SDK binaries.

**This repository does not include those files.** Nobody has established the right
to redistribute them. The WebDriverAgent BSD license covers WebDriverAgent's own code.
It does not show that Apple, or anyone else, has allowed redistribution of material
generated from Apple's interfaces. This repository does not claim that such permission
exists. It also does not say that redistribution is forbidden. The question is open.

## What this means for this repository

- This is a **source distribution with one input left out**. It is **not** a complete,
  reproducible or offline-buildable runner. Without that directory the runner will not
  compile: 168 runner source/header files import headers from it.
- The project file, include paths and group references are unchanged. They still point
  to `runner/PrivateHeaders/` by relative path, so nothing in the project has to be edited.
- The Swift app, Rust FFI and tunnel extension do not use these headers.

## If you choose to supply the directory locally

The upstream WebDriverAgent revision this runner was derived from is:

- repository: `https://github.com/appium/WebDriverAgent`
- commit: `02cb92f0e93c8b021443bcbb8eeb80932c113220` (v16.15.3)
- upstream directory: `PrivateHeaders/`

**You alone are responsible** for getting these files by legitimate means and for
deciding whether you have the right to use them under the terms that apply to you,
including Apple's SDK and developer agreements. The upstream pin above only identifies
which files match this project. It is **not** evidence of permission. This repository
has no script that downloads them, and it does not tell you to run one.

If you do have a copy you are entitled to use:

1. Place it at `runner/PrivateHeaders/`, keeping the upstream sub-directory layout
   (for example `runner/PrivateHeaders/XCTest/XCUIApplication.h`).
2. Check it against the expected path/size/hash list (read-only, no network access):

       python3 tools/verify_export.py --check-prerequisite runner/PrivateHeaders .

3. Keep it out of version control. `runner/PrivateHeaders/` is in `.gitignore`.
   Once the directory is present, `python3 tools/verify_export.py .` will report the
   files as `withheld_prerequisite_present`. That is intentional: the scan verifies the
   distributable tree, so run it on a clean checkout before publishing or packaging.

`runner/PrivateHeaders.expected.json` gives only paths, byte sizes, SHA-256 and git blob
SHA-1 values for the upstream files at that commit. It is not a license and contains no
header content.
