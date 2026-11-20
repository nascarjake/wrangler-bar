# Validation

## Staged 0.2.0

Validated with Swift 6.3.3, the macOS SDK, Node.js 22.22.3, and an Apple silicon Mac on macOS 26.4. This version is staged locally; publication and installation are separate steps.

- All 16 tests passed. The profile suite covers exact default/named argument arrays, strict profile-name validation and shell metacharacters, three simultaneous mixed states, independent scopes and timestamps, per-profile refresh, successful named reauthentication, duplicate prevention, cancellation, CLI failures, removed profiles, catalogue failure, and fail-closed tool/selector checks.
- A native integration test uses the real Process runner and installed Node binary with a synthetic JavaScript CLI. With stdin closed, that fake CLI runs a loopback callback, completes the selected named-profile flow, and refreshes only that profile. It opens no browser, contacts no Cloudflare service, creates no credentials, and discards synthetic sensitive stdout/stderr.
- The real Wrangler 4.160.0 parser/help checks passed in an empty temporary home. They confirm `auth create NAME --browser=true`, browser/localhost callback help, strict name validation, explicit per-process profile selection for `whoami --json`, missing-profile authentication status, and the separate default-device command. No valid real profile was authenticated or queried. Wrangler 4.141.0 is explicitly below this version's monitoring minimum.
- Public Wrangler source was inspected: `auth create` passes the exact name to the official login/storage operation whether the profile already exists or is expired; it needs no stdin account picker. The real Cloudflare browser exchange has not been tested. The app adds no device flag to named authentication, no custom OAuth scopes, no credentials, and no project bindings.
- `--diagnose-tools` found the development Mac's installed Node 22.22.3 and existing cache Wrangler 4.160.0, labeled **npm cache · temporary**. This mode runs versions/help and an empty-home selector probe only, without reading actual credentials. Discovery tests cover installed-before-cache priority even when another supported runtime is needed, rejection of arbitrary PATH/project/symlink locations including redirected cache keys, metadata validation, and preservation of manual choices.
- The actual AppKit menu smoke passed with three fictional profiles: Signed in, Reauthentication needed, and Unknown. Each had its own enabled profile-specific sign-in action; native menu parent/submenu availability and the accessible cloud label were verified without live CLI or browser use.
- Universal packaging targets Apple silicon and Intel, verifies the ad-hoc integrity signature, includes the license, and creates a versioned ZIP and SHA-256 checksum. Intel hardware runtime testing is not implied.

Only the real profile catalogue metadata was inspected through `auth list`; actual profile identity checks were deliberately excluded to avoid any Wrangler-managed refresh of real credentials during development. Test profiles, permissions, and callback values are fictional. No private Wrangler configuration was read by the app or tests, no tokens were exported or injected, and no real browser OAuth or account changes occurred.

The minimum macOS 13.5 version, manual VoiceOver/keyboard interaction, and real Cloudflare account approval remain untested. Builds are ad-hoc signed, without Developer ID signing or notarization. Existing public releases and the installed app are preserved.

## Earlier releases

Version 0.1.1 added real parser checks and disabled the unsupported `login --profile` combination, but it did not offer named-profile monitoring or a native named login button. Version 0.2.0 replaces that limitation with the official `auth create NAME` flow and profile-specific status checks. The original v0.1.0 fake CLI had accepted the invalid named-login combination; that historical validation did not establish real command compatibility. Earlier tags and assets are unchanged.
