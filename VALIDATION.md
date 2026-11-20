# Validation

## Version 0.1.1

Validated with Swift 6.3.3, the macOS SDK, Node.js 22.22.3, and an Apple silicon Mac running macOS 26.4.

- Eight core tests passed. The named-profile regression test covers version fixtures 4.119.0, 4.141.0, and 4.160.0 and proves no CLI invocation or fallback occurs. Other checks cover version floors, Finder discovery, environment isolation, default arguments, duplicate sign-in locking, failure status, discarded output, and log redirection.
- The built app exposes its actual command policy through a side-effect-free `--print-login-plan` test mode. The integration harness checked that policy against existing official npm Wrangler **4.141.0, 4.157.0, and 4.160.0** installations. Their real parsers accepted the default device arguments with the non-authenticating `--scopes-list` flag, rejected the old `login --profile` syntax, and documented `auth create NAME` without a device flag.
- Existing Wrangler **4.86.0** rejected the unsupported device option, agreeing with the app's minimum-version rule.
- All CLI integration checks ran with a separate empty temporary home and no inherited credentials. They used static help or the scope-list handler, never started OAuth, and created no credential files. No packages were downloaded or installed.
- Native AppKit smoke mode verified the actual menu's accessible name, initial default state, disabled legacy named-profile state, and available named-profile help. Its legacy preference fixture is in memory; no real preferences or credentials were modified.
- Release packaging targets Apple silicon (`arm64`) and Intel (`x86_64`), applies and verifies an ad-hoc integrity signature, and writes a SHA-256 checksum for the ZIP. Intel hardware runtime testing is not implied by a universal build.

The app declares macOS 13.5 as its minimum. The minimum OS, manual keyboard/VoiceOver interaction, Gatekeeper behavior after a real browser download, and real Cloudflare browser approval have not been tested. The app is not Developer ID signed or notarized. No end-to-end OAuth test is claimed.

## Version 0.1.0 history

The original release's six fake-CLI/synthetic-process tests and native-menu smoke passed, but the fake accepted a named-profile argument that the real CLI rejects. That validation did not establish command compatibility. Version 0.1.1 adds real parser/help checks, disables unsupported named-profile login, and provides the official Terminal instructions. The v0.1.0 Git tag and release assets are preserved.
