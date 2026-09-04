# Releasing Phone to TestFlight and the Mac App Store

The build is a shell script, not an Xcode project. Everything Apple needs to
see — sandbox, hardened runtime, our own baresip, no G.722 — is produced by
`scripts/build-app.sh --store`. This page lists what the script does and the
handful of things only an Apple account holder can do.

## What the store build produces

```sh
sh scripts/build-baresip.sh                      # once, or after a baresip bump
PHONE_TEAM_ID=TF5Y2AJ5QZ sh scripts/build-app.sh --store            # dist/Phone.app
PHONE_TEAM_ID=TF5Y2AJ5QZ sh scripts/build-app.sh --store --package  # + dist/Phone.pkg
PHONE_TEAM_ID=TF5Y2AJ5QZ ASC_API_KEY_ID=… ASC_API_ISSUER_ID=… \
  sh scripts/build-app.sh --store --upload       # + validate and upload to App Store Connect
```

- **Release configuration**, bundle identifier `com.nordwerk.phone`, version
  `1.0.0`, build number = commit count (override with `PHONE_BUILD_NUMBER`).
- **App Sandbox** for all three executables. The app has network client and
  server, microphone, and Contacts; the baresip engine inherits the app's
  sandbox; `phone-mcp` is sandboxed on its own and reaches the app through
  the **app group** `<TEAMID>.com.nordwerk.phone`, which the script writes
  into both entitlement files and into `Info.plist` (`PhoneAppGroup`).
- **Hardened runtime** with secure timestamps on every Mach-O, signed inside
  out (modules, dylibs, helpers, app) without `--deep`.
- **baresip and libre built from source** (`scripts/build-baresip.sh`, from
  the release tarballs Homebrew verifies) so every binary carries our
  signature. G.722 is left out: it links spandsp, which is LGPL. Opus and
  G.711 remain, which covers Deutsche Telekom and sipgate.
- **Audio sockets inside the container** (`$TMPDIR`), the control socket in
  the app group container, and a `container-migration.plist` that moves a
  pre-sandbox `~/Library/Application Support/Phone` into the container on the
  first launch. Set `PHONE_MIGRATE_CONTAINER=0` to build without the
  migration — useful when checking a store build on the development Mac,
  where the migration would move the development data.
- **Privacy manifest** (`Resources/PrivacyInfo.xcprivacy`): no tracking, no
  collected data, and the two required-reason APIs the app touches —
  UserDefaults (CA92.1) and file timestamps for the log rotation (C617.1).
- `ITSAppUsesNonExemptEncryption` is `false`: TLS and SRTP use standard
  algorithms through OpenSSL. Confirm the export compliance answer in App
  Store Connect on the first submission.

Without `PHONE_PROVISIONING_PROFILE` the script builds and signs but warns;
TestFlight and the store need the embedded profile.

## A DMG for early testers

The store build does not run outside the store. Testers who should have the
app before TestFlight get the same release build signed with **Developer
ID**, notarised, and packed into a disk image:

```sh
PHONE_TEAM_ID=TF5Y2AJ5QZ ASC_API_KEY_ID=… ASC_API_ISSUER_ID=… \
  sh scripts/release-github.sh          # build, notarise, tag v1.0.0, pre-release with the DMG
```

`scripts/release-github.sh` refuses to run from a dirty tree, from a branch
other than main, or from a main that is not pushed; the notes come from
`docs/releases/<version>.md`. `--draft` keeps the release unpublished for a
look before it goes out.

Same sandbox, hardened runtime, app group, and container migration as the
store build; the only difference is the signature and that G.722 stays in,
because the LGPL limit is a store rule. The image goes to GitHub Releases in
the public repository, marked as a pre-release; the landing page links there.
The notarisation uses the same App Store Connect API key as the upload. A
**Developer ID Application** certificate is the one extra thing to create, in
the same Xcode dialog as the others.

## What only you can do (once)

Everything below happens in Xcode → Settings → Accounts, in
[App Store Connect](https://appstoreconnect.apple.com), or in the
[developer portal](https://developer.apple.com/account/resources). Nothing
here is scripted, because each step needs your Apple ID.

1. **The team is `TF5Y2AJ5QZ` (Arne Wiese)** — the one individual membership
   that exists; `6UU9G3U3L3` (arnewiese@mac.com) is a free Xcode login. The
   store page therefore names Arne Wiese as the seller, not nordwerk; an
   organisation account would need a D-U-N-S number and an app transfer
   later. The app group is `TF5Y2AJ5QZ.com.nordwerk.phone`.
2. **Certificates.** In Xcode → Settings → Accounts → the team → Manage
   Certificates, add **Apple Distribution**, **Mac Installer Distribution**,
   and **Developer ID Application** (for the tester DMG). The script finds
   them by name; nothing to configure.
3. **Identifiers.** In the developer portal:
   - an **App Group** `<TEAMID>.com.nordwerk.phone`;
   - an **App ID** `com.nordwerk.phone` with the App Groups capability, the
     group assigned.
4. **Provisioning profile.** Profiles → new → *Mac App Store Connect*, for
   that App ID, with the Apple Distribution certificate. Download it and pass
   its path as `PHONE_PROVISIONING_PROFILE`.
5. **App record.** App Store Connect → My Apps → New App → macOS, name
   *Phone* (or the name you settle on), bundle ID `com.nordwerk.phone`, SKU
   `phone-mac`. The price is set here, not in the code.
6. **API key for uploads.** App Store Connect → Users and Access →
   Integrations → App Store Connect API → Team Keys → generate, role
   *App Manager*. Download the `.p8` once, put it at
   `~/.private_keys/AuthKey_<KEYID>.p8`, and note the Key ID and Issuer ID
   for `ASC_API_KEY_ID` and `ASC_API_ISSUER_ID`.
7. **TestFlight.** After the first upload finishes processing, App Store
   Connect → the app → TestFlight → add an internal group, or an external
   group with the waiting list's addresses; the first external build goes
   through a short beta review.
8. **Xcode 27.** The 1.0 submission is built against the macOS 27 SDK.
   Xcode 27 beta (27A5252f) is installed as `/Applications/Xcode-beta.app`;
   the scripts pick it up through
   `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` (or
   `sudo xcode-select -s /Applications/Xcode-beta.app`). The build script
   passes the SDK to the linker explicitly — the Xcode 27 Swift driver alone
   stamps the deployment target as the SDK — and refuses a release build in
   which the app, the helpers, a module, or libre/baresip carry another SDK
   stamp than the selected Xcode; after an Xcode update, rerun
   `sh scripts/build-baresip.sh --force`. `Info.plist` records the toolchain
   (`DTSDKName`, `DTXcode`, …) like an Xcode build does.

   TestFlight accepts builds from a beta Xcode; the App Store review does
   not. The final upload for review is made with the Xcode 27 release (RC
   or GM), which is the same command with the other `DEVELOPER_DIR`.

## Checking a store build locally

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
PHONE_DIST=.build/dist-store \
PHONE_SIGN_IDENTITY="Apple Development: …" \
PHONE_TEAM_ID=TF5Y2AJ5QZ \
PHONE_MIGRATE_CONTAINER=0 \
sh scripts/build-app.sh --store
codesign -dv --entitlements - .build/dist-store/Phone.app
open .build/dist-store/Phone.app
```

A development-signed sandboxed build runs from any folder and gets its own,
empty container under `~/Library/Containers/com.nordwerk.phone`; it does not
touch the development data. Add a line through the wizard, place a call, and
check `~/Library/Containers/com.nordwerk.phone/Data/Library/Application
Support/Phone/phone.log` — the sockets in the log should point into the
container's `tmp`, never into `/tmp`.

`--package` needs the installer identity; `--upload` runs
`altool --validate-app` first, so a bundle Apple would reject is caught before
anything leaves the Mac.
