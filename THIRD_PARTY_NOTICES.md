# Third-party software notices

This distribution contains third-party software. The project-level MIT license
in `LICENSE` applies only to the bb-k8s wrapper; each bundled component remains
under its own license.

## Direct runtime components

| Component | Version | License | Source and bundled notice |
| --- | --- | --- | --- |
| bb (`bb-app`) | 0.43.1 | MIT | [get-bb/bb, `desktop-v0.43.1`](https://github.com/get-bb/bb/tree/desktop-v0.43.1); copied to `/licenses/third-party/bb/LICENSE` |
| Codex CLI (`@openai/codex`) | 0.155.0 | Apache-2.0 | [openai/codex, `rust-v0.155.0`](https://github.com/openai/codex/tree/rust-v0.155.0); license and NOTICE copied to `/licenses/third-party/codex/` |
| Node.js | 24.21.0 | MIT and bundled third-party terms | The official Node image's `/usr/local/LICENSE` is retained |
| Debian Bookworm packages | image-specific | package-specific | Debian copyright files are retained under `/usr/share/doc/*/copyright` |

The bb npm tarball does not declare a `license` field or include its top-level
license. Its repository's exact `desktop-v0.43.1` tag is MIT-licensed, so that
license is included explicitly here and in the image.

## npm production dependencies

The npm lockfile is checked in CI against a reviewed permissive-license
allowlist. At the time of this release it contains MIT, ISC, Apache-2.0,
BlueOak-1.0.0, BSD-2-Clause, BSD-3-Clause, CC0-1.0, CC-BY-3.0,
Artistic-2.0, and permissive multi-license expressions. It contains no GPL,
AGPL, or LGPL dependencies.

Package-level license and notice files installed by npm are retained alongside
their packages under `/opt/bb-k8s/node_modules`. In particular, npm's
`qrcode-terminal` bundle omits license metadata from the lockfile but ships its
Apache-2.0 license and QRCode attribution in its package directory.

This notice is informational and is not legal advice. No license grants rights
to third-party names, logos, or trademarks beyond customary identification of
the software.
