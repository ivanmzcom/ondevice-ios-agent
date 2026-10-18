# aws-lc license files omitted from the aws-lc-sys 0.46.0 crate

The `aws-lc-sys` 0.46.0 crate ships `aws-lc/LICENSE`. That file points to the license files
below ("See third_party/..."), but the crate does not include them, and it also leaves out
aws-lc's top-level `NOTICE`. The files here are **verbatim upstream copies** from
https://github.com/aws/aws-lc at commit `fa9bc8d6f7cfb2cf849b247fb06bbbfc41ecc9d6`. That commit is the `aws-lc-sys/aws-lc`
submodule pinned by aws-lc-rs at `9df497501436596d4da77109217806b3af7f56cb`, which is the VCS
revision recorded in the crate's `.cargo_vcs_info.json`. Every file in the crate's `aws-lc/`
directory matches that commit's git blobs exactly, and each file below was checked against
its git blob SHA-1 there.

| File | SHA-256 |
|---|---|
| `NOTICE` | `f97c469fa666b51b3dae2e1530504a5ee73bbf47b980aa76746d26c271dd591d` |
| `third_party/s2n-bignum/s2n-bignum-imported/LICENSE` | `41c6380384dc6065456d01405ef0b43e5fe39ba1bccc4ec67801cc66142728e5` |
| `third_party/s2n-bignum/s2n-bignum-imported/NOTICE` | `d4290ed64c2edd0fce1d84e3f9dfb2881240fe534def76b8cd29ed6af683e287` |
| `third_party/jitterentropy/jitterentropy-library/LICENSE` | `088d208b9d22530691f1e9406a85dd7f6f5a42e3cf23d3d6df6582408e3840f7` |
| `third_party/jitterentropy/jitterentropy-library/LICENSE.bsd` | `13aa749a5b0a454917a944ed8fffc530b784f5ead522b1aacaf4ec8aa55a6239` |

Jitter Entropy is dual-licensed (BSD-style or GPL-2.0). `aws-lc/LICENSE` records that
"Amazon expressly elects to distribute the package under the 3-Clause BSD License and NOT
under" the GPL. This project follows that election: `LICENSE` and `LICENSE.bsd` are included,
and the alternative GPL-2.0 text is not.
