---
name: release-mac
description: Release Ciaobot for Mac — build, Developer ID sign, notarize, generate the signed appcast, and publish a version plus the update feed. Use whenever cutting a Mac client version, shipping an update, regenerating the appcast, or when a user asks why an installed client is not updating.
---

# Releasing Ciaobot for Mac

This repository is public. Treat every committed file as publishable: no
private keys, app-specific passwords, keychain profile names, Apple Account
identifiers, absolute paths, or CI secrets may ever be added. Release
credentials live in the release operator's login keychain.

Read `README.md` first for the current commands; this skill is the sequence and
the judgement around them. If a script's flags disagree with this document,
the script wins — fix this document in the same change.

## Before you start

You need, on one trusted Mac:

- Xcode 24 or later with the command line tools selected
  (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).
- A **Developer ID Application** certificate for this project's team in the
  login keychain (`security find-identity -v -p codesigning` shows it).
- A **notarytool keychain profile** created once with
  `xcrun notarytool store-credentials`, holding an app-specific password.
  Never put that password in the repository, a shell profile, or a chat.
- The **Sparkle EdDSA private key** in the same keychain. Generate it once with
  Sparkle's `generate_keys`; it prints the public key that belongs in
  `release/update-config.env`. Losing this key stops all future updates.
- Clean `main` and a green CI run for the commit you are releasing.

Check both keys still exist before building: losing either late in the process
wastes the whole run.

On the first signing run the keychain asks whether `generate_appcast` may use
the update key. Choose **Always Allow**; that exception is per binary path, so a
Sparkle upgrade may ask once again. If the release runs unattended, expect it to
wait on that dialog rather than fail.

## 1. Decide the version

`scripts/build-app.sh` is the single definition of `CFBundleShortVersionString`
and `CFBundleVersion`. Bump both in the same commit as the change that warrants
the release. Sparkle compares `CFBundleVersion` as an integer, so it must
increase monotonically; never reuse a build number.

Semantic versioning applies to the client: a fix is a patch, a feature is a
minor, a change users must act on is a major.

## 2. Land the change through a pull request

Branch, push, open a PR against `main`, and wait for CI. Never tag or release a
commit that CI has not built: the release artifact must be reproducible from a
commit that passed the suite.

## 3. Build and notarize

Build the release artifact from the merged commit, not from a dirty worktree:

```sh
git archive <commit> | tar -x -C "$SCRATCH"
cd "$SCRATCH"
CIAOBOT_RELEASE_UPDATES=1 \
SIGNING_IDENTITY='Developer ID Application: …' \
NOTARY_PROFILE='<your keychain profile>' \
scripts/package-notarized.sh
```

`CIAOBOT_RELEASE_UPDATES=1` is what makes the client update-capable. Without it
the build is inert and its menu reports that updates are unavailable — that is
the correct state for local, debug and test builds. Never ship a build that
claims update support without the flag, and never set the flag on a build whose
`release/update-config.env` is wrong.

The script signs Sparkle's nested helpers inside out, signs the app, submits to
Apple, **requires** an `Accepted` result, staples the ticket, and verifies
Gatekeeper on both the bundle and the extracted ZIP. Treat its failure as
fatal; a rejected or unstapled archive must not be published.

If notarization reports a missing keychain profile, stop and ask the operator to
recreate it. Do not substitute a password, an App Store Connect key, or an
unsigned build.

## 4. Verify the artifact by hand

```sh
shasum -a 256 -c Ciaobot-<version>-notarized.zip.sha256
ditto -x -k Ciaobot-<version>-notarized.zip /tmp/ciaobot-check
codesign --verify --deep --strict --verbose=2 /tmp/ciaobot-check/Ciaobot.app
xcrun stapler validate /tmp/ciaobot-check/Ciaobot.app
spctl --assess --type execute --verbose=4 /tmp/ciaobot-check/Ciaobot.app
plutil -p /tmp/ciaobot-check/Ciaobot.app/Contents/Info.plist | grep -E 'SU(FeedURL|PublicEDKey|AutomaticallyUpdate)|CFBundle(Short)?Version'
```

The result must be `accepted` with `source=Notarized Developer ID`, and the
plist must carry the feed URL and public key from `release/update-config.env`.

## 5. Generate the appcast

```sh
scripts/make-appcast.sh \
  --archive Ciaobot-<version>-notarized.zip \
  --download-url https://github.com/<owner>/<repo>/releases/download/v<version>/ \
  --output appcast.xml
```

`--download-url` is a **prefix ending in `/`** because Sparkle appends the
archive filename. The script refuses an archive another team signed, without a
TeamIdentifier, without Developer ID Application authority, unnotarized,
wrong-version, or non-arm64. It only reads; it never publishes.

## 6. Publish, archive first and feed last

Order matters: an appcast must never point at an archive that is not yet
downloadable.

1. Create the version release with the ZIP and its `.sha256`, marked
   **pre-release** while the build is still a preview. `gh release create
   --target` needs a full commit SHA; a short SHA is rejected as invalid.
2. Then publish `appcast.xml` as an asset on the dedicated `updates` release.
   The asset name must be exactly `appcast.xml` because the feed URL embeds it;
   `gh release upload` uses the local filename, so copy the generated file to
   that name first. Keep the release pre-release too, so it never becomes
   "latest" and never replaces the download page. `gh release edit
   --prerelease=true` is the flag that actually sets it.
3. Confirm the feed URL from `release/update-config.env` downloads the appcast
   you just generated, and diff it against the local file.

A brand-new asset on a brand-new release can briefly 404 on the public
`/releases/download/<tag>/<asset>` path while the API already serves it. Re-upload
and retry before touching the feed URL: the URL in the shipped app must not
change to work around a propagation delay.

Replacing the appcast asset is the only intentional overwrite in this flow;
versioned archives are immutable. Never delete a published version: installed
clients may still be fetching it.

## 7. Prove the update chain

Unit tests cannot prove an update installs. On a disposable Mac or VM:

1. Install the previous release manually, launch it, and **leave it open**.
2. Publish the new build as above.
3. Wait for a check (or use Check for Updates…) and confirm the running client
   is replaced and relaunched while in use, with the bundle identifier and
   version updated, and the separate Ciaobot engine still running untouched.
4. Confirm the new version's menu still reports updates as available.

Also try one negative case — a tampered ZIP or a wrong-key signature — and
confirm the client refuses it and keeps running.

## Recovery

- **Bad appcast entry:** remove it and publish a corrected appcast pointing at a
  **higher** build. Sparkle will not downgrade.
- **Bad build already installed:** publish a fixed higher build; do not try to
  revoke the version.
- **Lost EdDSA key:** updates stop for installed clients until they install a
  key rotation by hand. This is why the key is backed up before the first
  updater release.
- **Failed notarization:** fix the cause and rebuild from the merged commit.
  Never staple or publish a rejected archive.

## Report

End with: version and build, commit SHA, Apple submission outcome, artifact
SHA-256, feed URL, and exactly what was verified on a real machine versus what
remains unverified. Do not describe a release as shipped until CI, notarization
and the published download have all been checked.
