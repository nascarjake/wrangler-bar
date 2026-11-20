# Wrangler Bar

A small native macOS menu-bar app for signing in to the Cloudflare CLI's **default profile**. Click or right-click the cloud in the menu bar, choose **Sign in to default Cloudflare profile…**, and approve Wrangler's request in your browser.

Built with Swift and AppKit. No third-party app dependencies. This is an independent utility, not an official Cloudflare product.

## Requirements and download

- macOS **13.5 or later**, Apple silicon or Intel.
- An installed, supported Node.js runtime, **22.13.0 or newer**. A supported LTS release is recommended; the app also checks whether the installed Wrangler actually runs.
- An existing official **Wrangler 4.119.0 or newer** installation that supports `login --device`.
- Internet access and a Cloudflare account for the browser approval.

See the [latest release](https://github.com/nascarjake/wrangler-bar/releases/latest) for the universal Mac ZIP and `SHA256SUMS`. Version 0.1.1 is an early release. Its integrity signature is **ad-hoc only**: it has no Apple Developer ID signature and is **not notarized**. A downloaded build may be blocked by Gatekeeper. A signed, notarized download is not available. You can review and build the source locally with Xcode instead; do not disable Gatekeeper.

To check a downloaded ZIP before extracting it, put the ZIP and `SHA256SUMS` in the same directory and run:

```sh
shasum -a 256 -c SHA256SUMS
```

After extracting a build that your Mac permits, open **Wrangler Bar.app**. It lives in the menu bar and does not add a Dock window, background login item, or system service.

## First sign-in

1. Install Node.js and Wrangler yourself using [Cloudflare's setup guide](https://developers.cloudflare.com/workers/wrangler/install-and-update/). The app never installs or updates tools. For a project-local installation, Cloudflare documents `npm i -D wrangler@latest`; run installation commands only in a project you choose.
2. Open the app. Its readiness check runs the installed Node version, Wrangler version, and `login --help`. It does not start authentication.
3. If needed, choose **Node.js executable…** and **Wrangler executable…**. For npm project installs, select `node_modules/.bin/wrangler`, or the underlying `node_modules/wrangler/bin/wrangler.js`. Press ⌘⇧G in the file picker to enter a path. npm's JavaScript entry point is required; package-manager shell shims may need their underlying JavaScript file selected.
4. Choose **Sign in to default Cloudflare profile…**, confirm that updating Wrangler's default profile is intended, then approve the account and permissions in Cloudflare's browser page. The browser uses your existing default. The app passes no additional OAuth scopes.
5. For a named profile, use **Named-profile setup help…** and the official Terminal flow below. The app does not run named-profile authentication.

Both primary and secondary clicks open the standard AppKit menu. macOS keyboard menu-bar navigation and VoiceOver use the native menu; menu actions have labels and sign-in/check/quit keyboard equivalents. No Accessibility permission is requested.

## How authentication works

Wrangler Bar invokes your installed npm Wrangler entry point directly with a checked Node runtime, using `wrangler login --device` for the default profile. [Cloudflare documents this device flow](https://developers.cloudflare.com/changelog/post/2026-08-04-wrangler-login-device-flow/): Wrangler opens the approval page itself and owns polling and credential storage. It does not start a localhost callback server.

### Named profiles and upgrading from 0.1.0

Wrangler rejects `login --profile NAME`. Its [supported named-profile command](https://developers.cloudflare.com/workers/wrangler/commands/general/#auth-create) is `wrangler auth create NAME`, which creates or re-authenticates that profile. The installed versions checked for this release document browser and localhost callback options for that command and no device flag. Run `wrangler auth create --help` in Terminal to check your version, then use the named command yourself if intended. Optional directory binding is a separate explicit command, `wrangler auth activate NAME /path/to/project`. The app's help explains these steps and can open [Cloudflare's profile guide](https://developers.cloudflare.com/workers/wrangler/profiles/); it runs none of these commands and never substitutes a different CLI.

Version 0.1.0 incorrectly offered named-profile device login. Version 0.1.1 disables that path. If an existing named choice was saved, the sign-in button stays disabled. **Use default profile in this app…** asks for confirmation before clearing only that app preference. It does not authenticate or change credentials or project bindings. A later default-profile sign-in requires its own explicit confirmation. There is no silent fallback.

The app does not implement OAuth, fetch or export tokens, inspect Wrangler's private config, scrape browser state, copy codes, or provide logout/account switching. Login stdout/stderr are discarded, and Wrangler's debug log is directed to a `.log` symlink to `/dev/null` in a private temporary working directory. No device code is displayed, parsed, or retained by the app. It saves executable paths and preserves any old named-profile choice until you explicitly clear it. Ambient API credentials, Node injection flags, and inherited Wrangler profile overrides are excluded from the CLI environment.

Sign-in is available only after a successful tool check. One operation can run at a time. Cancel stops the app's active CLI process; quitting also requests cancellation. Cloudflare still controls request expiry and browser approval. Cancelling after you approve cannot undo a sign-in that Wrangler already completed.

**Ready** describes the installed tools, not whether your current credentials are valid. **Sign-in completed** reports Wrangler's exit status for that attempt; it is not a persistent account or session monitor. The app never shows an account email or ID.

## Troubleshooting

| Problem | Try this |
| --- | --- |
| Works in Terminal, not Finder | Choose the installed executables explicitly. Discovery checks PATH, Homebrew, Volta, mise/asdf shims, and installed nvm/fnm versions without sourcing shell startup files. Unsupported shims fail the check safely. |
| Old Node is selected | Choose a supported LTS Node executable. Node 20 is rejected; newer Wrangler releases may impose further runtime requirements. |
| Wrangler is not found | Select an existing project's npm Wrangler entry point. An npm cache or `npx` download is not searched or installed automatically. |
| `--device` is unavailable | Update Wrangler yourself after reviewing Cloudflare's guide. The app checks both the version and help output. |
| Named profile selected; sign-in disabled | Use Named-profile setup help for `wrangler auth create NAME` in Terminal. To use the default profile instead, explicitly choose Use default profile in this app. |
| Browser does not open, request expires, or network fails | Cancel. For the default profile, run `wrangler login --device` in Terminal to use Wrangler's own fallback instructions. For named profiles use `wrangler auth create NAME`. Never paste device codes into an issue. |
| Wrong account appears in browser | Cancel and select the intended account yourself in Cloudflare. The app does not log you out or switch accounts. |
| Download blocked by macOS | This release is not Developer ID signed or notarized. Review and build the source locally, or wait for a signed distribution. Keep Gatekeeper enabled. |

## Build and test

Use Xcode 16 or newer with Swift 6 and the macOS SDK:

```sh
swift test
bash scripts/package.sh
```

Packaging builds both `arm64` and `x86_64`, bundles the app, applies an ad-hoc signature, verifies it, and creates the ZIP and checksum in `dist/`. No signing identity, paid membership, provisioning profile, entitlements, or network package dependency is required.

```sh
.build/debug/WranglerBar --smoke-test
```

The smoke mode constructs the actual native menu, checks its accessible label and both default/legacy named-profile states, then exits. It never invokes a CLI or opens a browser. Core tests cover version checks, discovery, environment isolation, named-profile blocking without fallback, duplicate sign-in prevention, failure handling, and discarded output.

To verify the built app's command policy against an existing npm Wrangler installation, use a supported Node runtime:

```sh
node scripts/verify-wrangler.mjs --app .build/debug/WranglerBar --cli /path/to/node_modules/wrangler/bin/wrangler.js
```

Repeat `--cli` to test multiple existing versions. This harness downloads nothing. It uses an empty temporary home, reads actual CLI help, and probes the default command with `--scopes-list` so it exits before OAuth. It also verifies the rejected named-login syntax and the official named-profile help. No live browser authentication or account modification is part of these tests. See [validation](VALIDATION.md) for this release's evidence and limits.

MIT licensed. Cloudflare and Wrangler are trademarks of their respective owners.
