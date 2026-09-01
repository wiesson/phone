# Releasing Phone to TestFlight and the Mac App Store

The build is a shell script, not an Xcode project. Everything Apple needs to
see — sandbox, hardened runtime, our own baresip, no G.722 — is produced by
`scripts/build-app.sh --store`. This page lists what the script does and the
handful of things only an Apple account holder can do.

## What the store build produces

```sh
sh scripts/build-baresip.sh                      # once, or after a baresip bump
PHONE_TEAM_ID=XXXXXXXXXX sh scripts/build-app.sh --store            # dist/Phone.app
PHONE_TEAM_ID=XXXXXXXXXX sh scripts/build-app.sh --store --package  # + dist/Phone.pkg
PHONE_TEAM_ID=XXXXXXXXXX ASC_API_KEY_ID=… ASC_API_ISSUER_ID=… \
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
- `ITSAppUsesNonExemptEncryption` is `false`: TLS and SRTP use standard
  algorithms through OpenSSL. Confirm the export compliance answer in App
  Store Connect on the first submission.

Without `PHONE_PROVISIONING_PROFILE` the script builds and signs but warns;
TestFlight and the store need the embedded profile.

## What only you can do (once)

Everything below happens in Xcode → Settings → Accounts, in
[App Store Connect](https://appstoreconnect.apple.com), or in the
[developer portal](https://developer.apple.com/account/resources). Nothing
here is scripted, because each step needs your Apple ID.

1. **Pick the team.** This Mac has two Apple Development identities:
   `TF5Y2AJ5QZ` (Arne Wiese) and `6UU9G3U3L3` (arnewiese@mac.com). Neither
   is a nordwerk organisation. The team decides the app group name, the
   Keychain access group, and who is named as the seller on the store page.
   Changing it later means a new app record.
2. **Certificates.** In Xcode → Settings → Accounts → the team → Manage
   Certificates, add **Apple Distribution** and **Mac Installer
   Distribution**. The script finds them by name; nothing to configure.
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
8. **Xcode 27.** The 1.0 submission is to be built against the macOS 27 SDK.
   Install the Xcode 27 GM from the developer downloads, then
   `sudo xcode-select -s /Applications/Xcode-27.app` (or the path it lands
   at) before running the store build. Until then the script builds with
   whatever `xcode-select` points at — Xcode 26.6 today.

## Checking a store build locally

```sh
PHONE_DIST=.build/dist-store \
PHONE_SIGN_IDENTITY="Apple Development: …" \
PHONE_TEAM_ID=XXXXXXXXXX \
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
