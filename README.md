# Ciaobot for Mac

A client-only macOS 13+ app for a separately installed Ciaobot server. It does not install, manage, restart, or replace the server or its workspace.

## Build and run

Requires a working Xcode or Xcode Command Line Tools Swift toolchain. From the repository root:

```sh
swift test
swift build
scripts/build-app.sh
open .build/Ciaobot.app
```

The script creates an unsigned, unnotarized local app under `.build/`; it does not install it. If the selected Command Line Tools are broken but Xcode is installed, select it for these commands with `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` (adjust the path to your installation). No dependencies are downloaded.

## Connecting safely

The initial address is a same-Mac candidate, not discovery or proof of identity. Enter an origin without a path, query, fragment, or credentials. HTTP is accepted only for `localhost`, `127.0.0.1`, and `::1`; all other hosts require HTTPS. The app checks `/api/startup-status` without credentials, rejects redirects, and requires a successful JSON response with a nonempty `startup_id`. This checks protocol shape **not server identity**; verify that you trust the address before signing in. TLS uses the system's normal certificate validation.

The web login handles authentication using a nonpersistent WebKit cookie store. Existing persistent cookies are never sent automatically, and this first slice requires signing in again on each launch (and after the window's session ends). This is a temporary safety tradeoff; persistent login remains open work and is not implemented. The client does not collect passwords or expose native shell/filesystem APIs to web content. Navigation stays on the exact selected origin; user-initiated external HTTP, HTTPS, and mail links open in the system browser, except HTTPS-to-HTTP downgrades are blocked. Other schemes and URLs with credentials are blocked.

## Prior implementation

The retired Tauri desktop app in the `ciaobot` repository at commit `20d2c23f^`, `desktop/src-tauri/src/lib.rs`, informed the window and navigation safety boundaries. Its server ownership, installer, and update behavior are not included here.
