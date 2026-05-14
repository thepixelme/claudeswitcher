# Releasing ClaudeSwitcher

Maintainer doc. End users want [README.md](README.md).

This file documents the maintainer release process. It contains no release
credentials; never commit Apple ID emails, app-specific passwords, keychain
exports, or real Apple team IDs.

## Prerequisites

- Apple Developer ID Application certificate installed in the login keychain (team `<APPLE_TEAM_ID>`).
- Xcode signed in to the Apple ID under Xcode → Settings → Accounts so notarization runs without a password prompt.
- `create-dmg` installed via Homebrew: `brew install create-dmg`.
- A `notarytool` keychain profile saved once — used to notarize the DMG in step 3. Generate an app-specific password at https://appleid.apple.com (Sign-In and Security → App-Specific Passwords), then:

  ```sh
  xcrun notarytool store-credentials "ClaudeSwitcher" \
    --apple-id <your-apple-id-email> \
    --team-id <APPLE_TEAM_ID> \
    --password <app-specific-password>
  ```

- A clean working tree on `main`. Tag the release commit *after* you have a notarized artifact in hand — don't tag in advance and discover a notarization failure later.

## 1. Bump the version

Edit `ios/ClaudeSwitcher.xcodeproj/project.pbxproj`:

- `MARKETING_VERSION` — the user-visible version (e.g. `1.0.2`). Bump in BOTH the Debug and Release configuration blocks (currently lines 271 and 307).
- `CURRENT_PROJECT_VERSION` — internal build number, increment by 1. Both configs (currently lines 257 and 293).

Commit: `chore: bump version to x.y.z`.

## 2. Archive, sign, notarize, export from Xcode

1. Open `ios/ClaudeSwitcher.xcodeproj`.
2. Select the **ClaudeSwitcher** scheme and **Any Mac (Apple Silicon, Intel)** as the destination.
3. **Product → Archive.** Wait for the build.
4. In the Organizer that opens, select the new archive → **Distribute App**.
5. Choose **Direct Distribution** (Developer ID, signed and notarized by Apple).
6. Wait for notarization to complete — Xcode polls Apple and shows "Ready to distribute" when the ticket is stapled. Usually 1–5 minutes; can be longer.
7. Click **Export** and save `ClaudeSwitcher.app` somewhere convenient (e.g. `~/Desktop/ClaudeSwitcher-x.y.z/`).

Sanity-check the export from Terminal:

```sh
cd ~/Desktop/ClaudeSwitcher-x.y.z
codesign -dv --verbose=4 ClaudeSwitcher.app 2>&1 | grep -E "Authority|TeamIdentifier"
# Expect: Authority=Developer ID Application: <name> (<APPLE_TEAM_ID>)
spctl -a -vvv -t exec ClaudeSwitcher.app
# Expect: accepted, source=Notarized Developer ID
xcrun stapler validate ClaudeSwitcher.app
# Expect: The validate action worked!
```

If any of those fail, do not ship — re-archive.

## 3. Wrap in a DMG

Stay in the export directory and run:

```sh
create-dmg \
  --volname "ClaudeSwitcher x.y.z" \
  --window-size 500 300 \
  --icon-size 96 \
  --icon "ClaudeSwitcher.app" 120 130 \
  --app-drop-link 380 130 \
  ClaudeSwitcher-x.y.z.dmg \
  ClaudeSwitcher.app
```

If `create-dmg` complains about a leftover `rw` mount from a previous run, `hdiutil detach` the volume in `/Volumes/` and retry — don't `rm -rf` anything inside `/Volumes/`.

Then notarize-staple the DMG itself (the .app inside is already stapled, but the DMG needs its own ticket so Gatekeeper trusts the container before mounting):

```sh
xcrun notarytool submit ClaudeSwitcher-x.y.z.dmg \
  --keychain-profile "ClaudeSwitcher" --wait
# Expect: status: Accepted

xcrun stapler staple ClaudeSwitcher-x.y.z.dmg
# Expect: The staple and validate action worked!

xcrun stapler validate ClaudeSwitcher-x.y.z.dmg
# Expect: The validate action worked!
```

(Don't use `spctl --context context:primary-signature` here — that flag checks for an embedded code signature, which DMGs don't carry. The stapled ticket is the right thing to verify, and `stapler validate` is the way.)

Capture the SHA-256 **after stapling** (stapling rewrites the file, so a sha taken before will be wrong):

```sh
shasum -a 256 ClaudeSwitcher-x.y.z.dmg
```

## 4. Tag and push

```sh
git tag -a vX.Y.Z -m "vX.Y.Z"
git push origin main vX.Y.Z
```

## 5. Create the GitHub release

```sh
gh release create vX.Y.Z ClaudeSwitcher-x.y.z.dmg \
  --title "vX.Y.Z" \
  --notes "<short changelog — what users see, not git log>"
```

Or via the web UI at https://github.com/thepixelme/claudeswitcher/releases/new — pick the tag, attach the DMG, write notes, publish.

## 6. Update the Homebrew cask

The cask lives in https://github.com/thepixelme/homebrew-tap at `Casks/claudeswitcher.rb`. Clone or pull it, then bump:

- `version "X.Y.Z"`
- `sha256 "<the shasum from step 3>"`
- `url` — should already be a templated `…/releases/download/v#{version}/ClaudeSwitcher-#{version}.dmg`, so version-only bump is enough. If it's not templated, fix that while you're here.

Test locally before pushing:

```sh
brew uninstall --cask claudeswitcher 2>/dev/null
brew install --cask thepixelme/tap/claudeswitcher
brew uninstall --cask claudeswitcher
```

Commit and push to the tap:

```sh
git -C path/to/homebrew-tap commit -am "claudeswitcher X.Y.Z"
git -C path/to/homebrew-tap push
```

## 7. Smoke-test the published artifact

On a different Mac (or a fresh user account) — download the DMG from the Releases page, drag the app to Applications, double-click it. It must launch with no Gatekeeper prompt and no first-launch unblock. The menu-bar icon should appear within a second.

If you previously approved the Automation grant and this is a version bump, the *"would like to control Visual Studio Code"* prompt must NOT reappear — that's the whole point of Developer ID signing. If it does, the signature isn't stable across builds; investigate before announcing.
