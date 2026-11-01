# Ciaobot for Mac — agent guide

`README.md` is the product and behaviour reference; read the section for the area you change before editing it, and update it when behaviour changes.

## Build and test

CI (`.github/workflows/ci.yml`, macOS 15) blocks on, in order: `swift test`, `swift build`, `scripts/build-app.sh`, `swift test --filter AppAssetsTests`, `plutil -lint .build/Ciaobot.app/Contents/Info.plist`.

On the maintainer's Mac, `xcode-select` points at the Command Line Tools, which cannot link the package manifest. Prefix every SwiftPM command:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
```

Traps:
- `swift test` exits nonzero on any failure; never pipe it into `grep`/`tail` and then commit in the same `&&` chain — the pipeline's exit status is the filter's, so a red suite still commits. Check the `Executed … with 0 failures` line first.
- Under full-suite load `SparklePackagingTests` can fail with `fork: Resource temporarily unavailable` (local process limit). Re-run that suite alone with `--filter SparklePackagingTests`; green there means a flake, a real failure fails again.
- Never set `timeoutIntervalForResource` on a WebSocket session. URLSession leaves the TCP connection open when it times out a WebSocket task itself (cancel and invalidation do not release it), so a capped, reconnecting stream leaks connections until new ones fail with `ENOMEM`. Detect dead peers with `sendPing`.
- Tests never open a real menu or leave a status item in the menu bar; follow the fakes in `MenuBarTests` / `MenubarChatsTests`.

## Git

Branch off `main`, open a PR to `main`, merge with a merge commit. Releases use the `release-mac` skill (`.claude/skills/release-mac/`).
