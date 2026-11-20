# Version 0.1.0 validation

Validated with Swift 6.3.3, the macOS SDK, and an Apple silicon Mac running macOS 26.4.

- Six core tests passed using an injected fake CLI or a synthetic local subprocess. They cover version floors, Finder discovery, credential/injection environment removal, readiness without authentication, explicit profile arguments, duplicate sign-in locking, failure status, log redirection, and discarded process output.
- Native AppKit smoke mode constructed the actual status-item menu, verified its accessible name and initially disabled sign-in action, and exited without starting authentication or a browser.
- Release compilation succeeded for both Apple silicon (`arm64`) and Intel (`x86_64`). This is a universal build, not evidence of runtime testing on Intel hardware.
- Packaging verifies the bundle's ad-hoc integrity signature and writes a SHA-256 checksum for the ZIP.

The app declares macOS 13.5 as its minimum. The minimum OS, manual keyboard/VoiceOver interaction, Gatekeeper behavior after a real browser download, and real Cloudflare browser approval have not been tested. No actual Wrangler account was logged in, logged out, or changed by the app tests. The app is not Developer ID signed or notarized. No claim of an end-to-end OAuth test is made.
