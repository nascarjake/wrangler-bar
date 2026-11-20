# Wrangler Bar

A native Mac menu-bar monitor for your existing Cloudflare Wrangler profiles. Each profile shows **Signed in**, **Reauthentication needed**, or **Unknown**, with its own last check, last verified scopes, and completed sign-in time. **Sign in to NAME…** starts Wrangler's official browser authentication specifically for that profile, then refreshes it.

Swift and AppKit, without third-party app dependencies. This independent utility is not an official Cloudflare product.

## Staged version

**0.2.0 is staged for review. It has not been published or installed by this change.** The existing v0.1.0 and v0.1.1 releases remain available and unchanged. They do not include the profile monitor or improved discovery described here.

Requirements for 0.2.0:

- macOS 13.5+, Apple silicon or Intel.
- An installed native Node.js LTS binary, at least 22.13.0. Discovery prefers an installed Node 22 LTS; odd-numbered Node releases and shell shims are rejected.
- An existing official npm Wrangler **4.160.0+** installation. The app checks the version, named-auth help, and explicit profile selection before querying any real profile.
- Internet access for status checks and the user-approved browser authentication.

The staged universal ZIP and `SHA256SUMS` are generated in `dist/`. The signature is ad-hoc integrity signing only: no Developer ID signature and no notarization. A downloaded build may be blocked by Gatekeeper. Review and build the source locally or wait for a signed distribution; keep Gatekeeper enabled.

## Use

1. Open the app and click or right-click the cloud in the menu bar. It finds installed tools, loads **all profiles reported by `wrangler auth list`**, and checks each separately. No profile names or account identities are hardcoded. An expired registered profile remains listed; the app does not invent a missing profile. The global default appears only if Wrangler lists it.
2. Open a profile's submenu to see its status, check time, number of directory bindings, last verified permission scopes, and last completed sign-in. These details remain separate for every profile and stay in memory for this app session.
3. Click **Sign in to NAME…**. This is the explicit initiation; no CLI typing is required. Wrangler opens the default browser and Cloudflare asks for approval. Review the intended account and permissions there. The browser's current account is not necessarily implied by a local profile's name.
4. When Wrangler exits successfully, the app refreshes only that selected profile. **Refresh NAME** performs a status check without browser authentication. Automatic catalogue/status checks run every five minutes.

**Signed in** means the selected profile passed Wrangler's identity check. **Reauthentication needed** means Wrangler reported missing or rejected authentication. **Unknown** covers network, permission, timeout, CLI, or profile-selection failures. A failed check does not falsely classify another profile as signed out. Old scopes are retained as **last verified**, with their original timestamp.

Only one operation runs at a time, preventing duplicate browser logins and competing localhost callback listeners. **Cancel current operation** terminates this app's active CLI process. Cancellation cannot undo approval that already completed; refresh the selected profile to check its current state. The app has no logout action and changes no directory bindings.

## Official authentication and status commands

For a registered named profile, the button launches the installed Wrangler directly through the checked Node binary:

```text
wrangler auth create NAME --browser=true
```

[Cloudflare documents](https://developers.cloudflare.com/workers/wrangler/commands/general/#auth-create) that this creates or re-authenticates a named profile. The app rechecks registration before launch, so it will not create an unlisted profile from a stale menu. The documented named flow uses a browser and localhost callback; no device flag is added. The subprocess needs no Terminal window or stdin interaction for this flow. Native tests verify callback completion with a fake CLI and closed stdin; real Cloudflare browser approval remains untested.

For a listed global `default` profile, its explicit button uses `wrangler login --device --browser=true`. Named authentication never falls back to the default, never passes the unsupported `login --profile` combination, and never substitutes the separate `cf` CLI. No custom scopes, browser choice, callback host, or account selection are injected. Wrangler and the user's Cloudflare approval own those decisions.

Status checks use `whoami --json`, with an explicit per-process `CLOUDFLARE_AUTH_PROFILE` selector implemented by the checked Wrangler version. Before enabling this, an invalid-selector probe in an empty temporary home proves that the installed CLI honors that selector; otherwise the app fails closed. This avoids rebinding projects or accidentally checking a different default profile. Background checks are noninteractive and never start browser OAuth. Wrangler owns its credential storage and may perform its ordinary session refresh while servicing a check.

Profile names are validated, and commands use executable/argument arrays without a shell. A name cannot become a shell command or extra CLI flag.

## Tool discovery and manual paths

**Find installed tools** honors existing manual choices. **Clear manual tool paths…** is a separate explicit confirmation affecting only this app's preferences.

Discovery checks known nvm/fnm runtime locations and Homebrew/system installation directories. Native Node binaries are required, with Node 22 preferred. It validates npm Wrangler's package name, real JavaScript entry point, version, and command capabilities. It ignores arbitrary PATH directories and rejects installed-tool symlinks into arbitrary project folders. No shell startup files are sourced and no project tree is crawled.

If no stable installed Wrangler is valid, a bounded scan of the standard `~/.npm/_npx` layout can find an **existing** cache entry. The app validates it and visibly labels it **npm cache · temporary**. Clearing npm's cache may remove that entry. Nothing is downloaded, installed, or updated automatically.

Use **Choose Node.js executable…** and **Choose Wrangler executable…** to select existing files. Press ⌘⇧G in the picker to enter a path. For Wrangler, select `node_modules/wrangler/bin/wrangler.js` or its npm `.bin/wrangler` symlink. Manual paths are retained if a check fails; the app does not silently choose another executable.

## Privacy and limits

The app does not implement OAuth, read private Wrangler credential files, call `auth token`, export or inject tokens, inspect browser state, or change Cloudflare resources. It delegates credential operations to the official local Wrangler.

Login stdout/stderr and Wrangler debug logs are discarded. Status JSON is briefly parsed in memory; only the authentication boolean and permission-scope labels enter the model. Emails, account IDs, credential values, raw errors, verification URLs, and codes are neither displayed nor saved. Ambient API credentials, inherited profile overrides, custom authentication endpoints, and Node injection flags are excluded from child environments. Metrics and error reports are disabled per process.

The app saves executable choices only. Profile states, scopes, binding counts, and timestamps are session-local and are cleared when it quits. It requests no Accessibility or Screen Recording permission, adds no login item, and does not change the default browser or shell.

## Build and verify

Use Xcode 16+ with Swift 6:

```sh
swift test
bash scripts/package.sh
```

The callback integration test is opt-in and uses an installed supported Node binary:

```sh
WRANGLER_BAR_TEST_NODE=/absolute/path/to/node swift test
```

That test runs a synthetic JavaScript CLI through the real native process runner, completes a local loopback callback with stdin closed, and verifies profile-specific completion and output discard. It contacts no Cloudflare service and creates no real credentials.

```sh
.build/debug/WranglerBar --smoke-test
.build/debug/WranglerBar --diagnose-tools
node scripts/verify-wrangler.mjs --app .build/debug/WranglerBar --cli /path/to/node_modules/wrangler/bin/wrangler.js
```

The native menu smoke uses three fictional profiles with mixed statuses and never launches a real CLI or browser. `--diagnose-tools` checks discovery using versions/help and an empty-home selector probe only; it does not load or check actual profiles. The real-CLI harness downloads nothing and uses help, static scope listing, invalid names, and missing profiles in an empty home, without OAuth. See [VALIDATION.md](VALIDATION.md) for evidence and remaining limits.

Packaging builds `arm64` and `x86_64`, includes the MIT license, verifies the ad-hoc signature, and writes the versioned ZIP and SHA-256 checksum. Verify with `shasum -a 256 -c SHA256SUMS` before extracting a shared ZIP.

MIT licensed. Cloudflare and Wrangler are trademarks of their respective owners.
