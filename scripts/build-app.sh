#!/bin/sh
# Builds dist/Phone.app.
#
#   sh scripts/build-app.sh                 development build: debug, ad hoc or
#                                           Apple Development signed, Homebrew
#                                           baresip, no sandbox
#   sh scripts/build-app.sh --store         App Store build: release, sandboxed,
#                                           hardened runtime, our own baresip
#                                           from scripts/build-baresip.sh, no
#                                           G.722
#   sh scripts/build-app.sh --store --package   … and wrap it in dist/Phone.pkg
#   sh scripts/build-app.sh --store --upload    … and hand the package to App
#                                           Store Connect (TestFlight)
#   sh scripts/build-app.sh --direct        the same release build for early
#                                           testers outside the store: signed
#                                           with Developer ID, with G.722
#   sh scripts/build-app.sh --direct --dmg  … packed into dist/Phone-<version>.dmg
#   sh scripts/build-app.sh --direct --dmg --notarize   … notarised and stapled,
#                                           ready for a GitHub release
#
# Environment for the release builds (see docs/RELEASE.md):
#   PHONE_TEAM_ID              Apple team identifier; names the app group
#   PHONE_SIGN_IDENTITY        "Apple Distribution: …" for --store,
#                              "Developer ID Application: …" for --direct
#                              (default: first matching identity found)
#   PHONE_INSTALLER_IDENTITY   "3rd Party Mac Developer Installer: …"
#   PHONE_PROVISIONING_PROFILE path to the Mac App Store .provisionprofile
#   PHONE_BUILD_NUMBER         CFBundleVersion (default: commit count)
#   ASC_API_KEY_ID / ASC_API_ISSUER_ID   App Store Connect API key for --upload
#                              and --notarize (~/.private_keys/AuthKey_<id>.p8)
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

STORE_BUILD=0
DIRECT_BUILD=0
MAKE_PACKAGE=0
UPLOAD=0
MAKE_DMG=0
NOTARIZE=0
for argument in "$@"; do
  case "$argument" in
    --store) STORE_BUILD=1 ;;
    --direct) DIRECT_BUILD=1 ;;
    --package) MAKE_PACKAGE=1 ;;
    --upload) MAKE_PACKAGE=1; UPLOAD=1 ;;
    --dmg) MAKE_DMG=1 ;;
    --notarize) MAKE_DMG=1; NOTARIZE=1 ;;
    *) echo "Unknown option: $argument" >&2; exit 2 ;;
  esac
done
[ "${PHONE_STORE_BUILD:-0}" = 1 ] && STORE_BUILD=1
if [ "$STORE_BUILD" = 1 ] && [ "$DIRECT_BUILD" = 1 ]; then
  echo "--store and --direct are two builds; run them one after the other." >&2
  exit 2
fi
# The store build is the one without G.722; the direct build keeps it.
export PHONE_STORE_BUILD=$STORE_BUILD
RELEASE_BUILD=0
if [ "$STORE_BUILD" = 1 ] || [ "$DIRECT_BUILD" = 1 ]; then RELEASE_BUILD=1; fi

BUNDLE_ID=${PHONE_BUNDLE_ID:-com.nordwerk.phone}
VERSION=${PHONE_VERSION:-1.0.0}
BUILD_NUMBER=${PHONE_BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}
MIN_SYSTEM=26.0
TEAM_ID=${PHONE_TEAM_ID:-}
APP_GROUP=${PHONE_APP_GROUP:-${TEAM_ID:+$TEAM_ID.$BUNDLE_ID}}

if [ "$RELEASE_BUILD" = 1 ]; then
  CONFIGURATION=release
  if [ "$STORE_BUILD" = 1 ]; then
    SIGN_IDENTITY=${PHONE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Distribution|3rd Party Mac Developer Application/ {print $2; exit}')}
    IDENTITY_HINT="Create an Apple Distribution certificate in Xcode → Settings → Accounts"
  else
    SIGN_IDENTITY=${PHONE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')}
    IDENTITY_HINT="Create a Developer ID Application certificate in Xcode → Settings → Accounts"
  fi
  if [ -z "$SIGN_IDENTITY" ]; then
    echo "No signing identity found. $IDENTITY_HINT, or pass PHONE_SIGN_IDENTITY." >&2
    exit 1
  fi
  if [ -z "$TEAM_ID" ]; then
    echo "PHONE_TEAM_ID is required for a release build; it names the app group phone-mcp shares with the app." >&2
    exit 1
  fi
  DEPS="$ROOT/.build/deps"
  [ -x "$DEPS/bin/baresip" ] || sh "$ROOT/scripts/build-baresip.sh"
  export BARESIP_PREFIX="$DEPS"
  export LIBRE_PREFIX="$DEPS"
else
  CONFIGURATION=debug
  SIGN_IDENTITY=${PHONE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')}
  SIGN_IDENTITY=${SIGN_IDENTITY:--}
fi

cd "$ROOT"
sh "$ROOT/scripts/build-audio-tap.sh"
mkdir -p "$ROOT/.build/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/ModuleCache"
swift build --disable-sandbox -c "$CONFIGURATION"

BIN_DIR=$(swift build --disable-sandbox -c "$CONFIGURATION" --show-bin-path)
DIST=${PHONE_DIST:-$ROOT/dist}
mkdir -p "$DIST"
APP="$DIST/Phone.app"
BARESIP_PREFIX=${BARESIP_PREFIX:-$(brew --prefix baresip 2>/dev/null || true)}
LIBRE_PREFIX=${LIBRE_PREFIX:-$(brew --prefix libre 2>/dev/null || true)}
SPANDSP_PREFIX=${SPANDSP_PREFIX:-$(brew --prefix spandsp 2>/dev/null || true)}
BARESIP_EXECUTABLE="$BARESIP_PREFIX/bin/baresip"

if [ ! -x "$BARESIP_EXECUTABLE" ]; then
  echo "baresip was not found. Install it with: brew install baresip" >&2
  exit 1
fi
if [ ! -d "$LIBRE_PREFIX/lib" ]; then
  echo "libre was not found. Install it with: brew install libre" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN_DIR/Phone" "$APP/Contents/MacOS/Phone"
cp "$BIN_DIR/phone-mcp" "$APP/Contents/Helpers/phone-mcp"

# SwiftPM in Xcode 27 stamps every executable with an absolute runpath into
# .build/out/Products/…/PackageFrameworks. Nothing in the bundle lives there;
# drop it before the bundle is signed or verified.
drop_build_tree_runpaths() {
  object=$1
  otool -l "$object" | awk '/cmd LC_RPATH/{found=1; next} found && /path /{print $2; found=0}' \
    | while IFS= read -r runpath; do
        case "$runpath" in
          @executable_path/*|@loader_path|@loader_path/*) ;;
          *) install_name_tool -delete_rpath "$runpath" "$object" ;;
        esac
      done
}
drop_build_tree_runpaths "$APP/Contents/MacOS/Phone"
drop_build_tree_runpaths "$APP/Contents/Helpers/phone-mcp"
cp "$BARESIP_EXECUTABLE" "$APP/Contents/Helpers/baresip"
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/baresip/modules"
cp "$ROOT/runtime/baresip/config" "$APP/Contents/Resources/baresip/config"
cp "$ROOT/runtime/baresip/accounts.example" "$APP/Contents/Resources/baresip/accounts.example"
cp "$ROOT/Resources/baresip/contacts" "$APP/Contents/Resources/baresip/contacts"

if [ "$STORE_BUILD" = 1 ] && [ -f "$ROOT/runtime/modules/g722.so" ]; then
  echo "g722.so must not ship in a store build" >&2
  exit 1
fi

if [ -f "$ROOT/runtime/modules/g722.so" ]; then
  config="$APP/Contents/Resources/baresip/config"
  temporary_config="$config.tmp"
  awk '
    /^[[:space:]]*#?[[:space:]]*module[[:space:]]+g722[.]so([[:space:]]|$)/ { next }
    /^[[:space:]]*module[[:space:]]+g711[.]so([[:space:]]|$)/ && !added {
      print "module\t\t\tg722.so"
      added = 1
    }
    { print }
    END { if (!added) print "module\t\t\tg722.so" }
  ' "$config" > "$temporary_config"
  mv "$temporary_config" "$config"
fi

if [ -f "$ROOT/runtime/modules/opus.so" ]; then
  config="$APP/Contents/Resources/baresip/config"
  temporary_config="$config.tmp"
  awk '
    /^[[:space:]]*#?[[:space:]]*module[[:space:]]+opus[.]so([[:space:]]|$)/ { next }
    /^[[:space:]]*module[[:space:]]+(g722|g711)[.]so([[:space:]]|$)/ && !added {
      print "module\t\t\topus.so"
      added = 1
    }
    { print }
    END { if (!added) print "module\t\t\topus.so" }
  ' "$config" > "$temporary_config"
  mv "$temporary_config" "$config"
fi

for module in $(awk '$1 == "module" || $1 == "module_app" {print $2}' "$APP/Contents/Resources/baresip/config"); do
  if [ "$module" = "phone_tap.so" ] || [ "$module" = "opus.so" ] || [ "$module" = "g722.so" ]; then
    source="$ROOT/runtime/modules/$module"
  else
    source="$BARESIP_PREFIX/lib/baresip/modules/$module"
  fi
  if [ ! -f "$source" ]; then
    echo "Required baresip module was not found: $module" >&2
    exit 1
  fi
  cp -L "$source" "$APP/Contents/Resources/baresip/modules/$module"
done

cp -L "$BARESIP_PREFIX/lib/baresip/modules/aubridge.so" "$APP/Contents/Resources/baresip/modules/aubridge.so"
cp -L "$BARESIP_PREFIX/lib/baresip/modules/in_band_dtmf.so" "$APP/Contents/Resources/baresip/modules/in_band_dtmf.so"

FRAMEWORKS="$APP/Contents/Frameworks"
HELPER="$APP/Contents/Helpers/baresip"
MCP_HELPER="$APP/Contents/Helpers/phone-mcp"
MODULES="$APP/Contents/Resources/baresip/modules"
DEPENDENCIES=$(mktemp)
trap 'rm -f "$DEPENDENCIES"' EXIT

list_dependencies() {
  otool -L "$1" | tail -n +2 | sed -E 's/^[[:space:]]*//; s/[[:space:]]+\(compatibility version.*$//'
}

resolve_dependency() {
  dependency=$1
  object=$2
  case "$dependency" in
    /*)
      [ -f "$dependency" ] && printf '%s\n' "$dependency"
      ;;
    @rpath/*)
      relative=${dependency#@rpath/}
      for directory in "$(dirname "$object")" "$BARESIP_PREFIX/lib" "$LIBRE_PREFIX/lib" "$SPANDSP_PREFIX/lib"; do
        if [ -f "$directory/$relative" ]; then
          printf '%s\n' "$directory/$relative"
          return
        fi
      done
      ;;
    @loader_path/*)
      relative=${dependency#@loader_path/}
      candidate="$(dirname "$object")/$relative"
      [ -f "$candidate" ] && printf '%s\n' "$candidate"
      ;;
    @executable_path/*)
      relative=${dependency#@executable_path/}
      candidate="$APP/Contents/Helpers/$relative"
      [ -f "$candidate" ] && printf '%s\n' "$candidate"
      ;;
  esac
}

added=1
while [ "$added" -eq 1 ]; do
  added=0
  for object in "$HELPER" "$MODULES"/*.so "$FRAMEWORKS"/*.dylib; do
    [ -f "$object" ] || continue
    list_dependencies "$object" > "$DEPENDENCIES"
    while IFS= read -r dependency; do
      case "$dependency" in
        /usr/lib/*|/System/Library/*) continue ;;
      esac
      destination="$FRAMEWORKS/$(basename "$dependency")"
      [ -f "$destination" ] && continue
      source=$(resolve_dependency "$dependency" "$object" || true)
      if [ -z "$source" ]; then
        echo "Could not resolve dependency $dependency for $object" >&2
        exit 1
      fi
      cp -L "$source" "$destination"
      added=1
    done < "$DEPENDENCIES"
  done
done

rewrite_macho() {
  object=$1
  runpath=$2
  codesign --remove-signature "$object" 2>/dev/null || true
  list_dependencies "$object" > "$DEPENDENCIES"
  while IFS= read -r dependency; do
    case "$dependency" in
      /usr/lib/*|/System/Library/*) continue ;;
    esac
    replacement="@rpath/$(basename "$dependency")"
    [ "$dependency" = "$replacement" ] || install_name_tool -change "$dependency" "$replacement" "$object"
  done < "$DEPENDENCIES"

  otool -l "$object" | awk '/cmd LC_RPATH/{found=1; next} found && /path /{print $2; found=0}' > "$DEPENDENCIES"
  while IFS= read -r old_runpath; do
    [ "$old_runpath" = "$runpath" ] && continue
    install_name_tool -delete_rpath "$old_runpath" "$object"
  done < "$DEPENDENCIES"
  if ! otool -l "$object" | awk '/cmd LC_RPATH/{found=1; next} found && /path /{print $2; found=0}' | grep -Fx "$runpath" >/dev/null; then
    install_name_tool -add_rpath "$runpath" "$object"
  fi
}

rewrite_macho "$HELPER" "@executable_path/../Frameworks"
for module in "$MODULES"/*.so; do
  rewrite_macho "$module" "@loader_path/../../../Frameworks"
done
for library in "$FRAMEWORKS"/*.dylib; do
  codesign --remove-signature "$library" 2>/dev/null || true
  install_name_tool -id "@rpath/$(basename "$library")" "$library"
  rewrite_macho "$library" "@loader_path"
done

verify_macho() {
  object=$1
  list_dependencies "$object" > "$DEPENDENCIES"
  while IFS= read -r dependency; do
    case "$dependency" in
      /usr/lib/*|/System/Library/*) ;;
      @rpath/*)
        if [ ! -f "$FRAMEWORKS/$(basename "$dependency")" ]; then
          echo "Bundled dependency is missing for $object: $dependency" >&2
          exit 1
        fi
        ;;
      *)
        echo "External dependency remains in $object: $dependency" >&2
        exit 1
        ;;
    esac
  done < "$DEPENDENCIES"

  otool -l "$object" | awk '/cmd LC_RPATH/{found=1; next} found && /path /{print $2; found=0}' > "$DEPENDENCIES"
  while IFS= read -r runpath; do
    case "$runpath" in
      @executable_path/*|@loader_path|@loader_path/*) ;;
      *)
        echo "External runpath remains in $object: $runpath" >&2
        exit 1
        ;;
    esac
  done < "$DEPENDENCIES"
}

verify_macho "$HELPER"
verify_macho "$MCP_HELPER"
for module in "$MODULES"/*.so; do
  verify_macho "$module"
done
for library in "$FRAMEWORKS"/*.dylib; do
  verify_macho "$library"
done

# Entitlements. The app group carries the team identifier, so it is written
# into the entitlement files and the Info.plist here rather than kept in
# the repository.
ENTITLEMENTS_DIR=$(mktemp -d)
trap 'rm -f "$DEPENDENCIES"; rm -rf "$ENTITLEMENTS_DIR"' EXIT
add_app_group() {
  # plutil reads dots in a key as a key path; they have to be escaped.
  plutil -insert 'com\.apple\.security\.application-groups' -json "[\"$APP_GROUP\"]" "$1"
}
if [ "$RELEASE_BUILD" = 1 ]; then
  cp "$ROOT/Resources/Entitlements/Phone.entitlements" "$ENTITLEMENTS_DIR/app.entitlements"
  cp "$ROOT/Resources/Entitlements/PhoneEngine.entitlements" "$ENTITLEMENTS_DIR/engine.entitlements"
  cp "$ROOT/Resources/Entitlements/PhoneMCP.entitlements" "$ENTITLEMENTS_DIR/mcp.entitlements"
  if [ -n "$APP_GROUP" ]; then
    add_app_group "$ENTITLEMENTS_DIR/app.entitlements"
    add_app_group "$ENTITLEMENTS_DIR/mcp.entitlements"
  fi
  if [ "${PHONE_MIGRATE_CONTAINER:-1}" = 1 ]; then
    cp "$ROOT/Resources/container-migration.plist" "$APP/Contents/Resources/container-migration.plist"
  fi
  RUNTIME_FLAGS="--options runtime --timestamp"
  APP_SIGN_FLAGS="--entitlements $ENTITLEMENTS_DIR/app.entitlements"
  ENGINE_SIGN_FLAGS="--entitlements $ENTITLEMENTS_DIR/engine.entitlements"
  MCP_SIGN_FLAGS="--entitlements $ENTITLEMENTS_DIR/mcp.entitlements"
else
  RUNTIME_FLAGS=""
  APP_SIGN_FLAGS=""
  ENGINE_SIGN_FLAGS=""
  MCP_SIGN_FLAGS=""
fi

# Signed inside out: every nested piece first, the app last and without
# --deep, which is what the App Store expects.
for module in "$MODULES"/*.so; do
  codesign --force --sign "$SIGN_IDENTITY" $RUNTIME_FLAGS "$module"
done
for library in "$FRAMEWORKS"/*.dylib; do
  codesign --force --sign "$SIGN_IDENTITY" $RUNTIME_FLAGS "$library"
done
codesign --force --sign "$SIGN_IDENTITY" $RUNTIME_FLAGS $ENGINE_SIGN_FLAGS --identifier "$BUNDLE_ID.engine" "$HELPER"
codesign --force --sign "$SIGN_IDENTITY" $RUNTIME_FLAGS $MCP_SIGN_FLAGS --identifier "$BUNDLE_ID.mcp" "$MCP_HELPER"

if [ -n "${PHONE_PROVISIONING_PROFILE:-}" ]; then
  cp "$PHONE_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
elif [ "$STORE_BUILD" = 1 ]; then
  echo "Note: no PHONE_PROVISIONING_PROFILE — fine for a local check, required for TestFlight and the App Store." >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Phone</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Phone</string>
  <key>CFBundleDisplayName</key><string>Phone</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.business</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 nordwerk. MIT licensed.</string>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>NSContactsUsageDescription</key><string>Phone shows contact names for incoming and outgoing calls.</string>
  <key>NSMicrophoneUsageDescription</key><string>Phone needs the microphone for SIP calls.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Phone transcribes calls locally on this Mac.</string>${APP_GROUP:+
  <key>PhoneAppGroup</key><string>$APP_GROUP</string>}
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Phone call</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>tel</string>
        <string>callto</string>
        <string>sip</string>
      </array>
    </dict>
  </array>
</dict></plist>
PLIST

if [ "$RELEASE_BUILD" = 1 ]; then
  codesign --force --sign "$SIGN_IDENTITY" $RUNTIME_FLAGS $APP_SIGN_FLAGS "$APP"
else
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Built: $APP ($BUNDLE_ID $VERSION ($BUILD_NUMBER), $CONFIGURATION, signed as $SIGN_IDENTITY)"

if [ "$MAKE_PACKAGE" = 1 ]; then
  INSTALLER_IDENTITY=${PHONE_INSTALLER_IDENTITY:-$(security find-identity -v 2>/dev/null | awk -F'"' '/3rd Party Mac Developer Installer|Mac Installer Distribution/ {print $2; exit}')}
  if [ -z "$INSTALLER_IDENTITY" ]; then
    echo "No installer identity found. Create a Mac Installer Distribution certificate, or pass PHONE_INSTALLER_IDENTITY." >&2
    exit 1
  fi
  PKG="$DIST/Phone.pkg"
  rm -f "$PKG"
  productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG"
  echo "Packaged: $PKG"
fi

if [ "$MAKE_DMG" = 1 ]; then
  DMG="$DIST/Phone-$VERSION.dmg"
  STAGING=$(mktemp -d)
  cp -R "$APP" "$STAGING/Phone.app"
  ln -s /Applications "$STAGING/Applications"
  rm -f "$DMG"
  hdiutil create -volname "Phone" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"
  rm -rf "$STAGING"
  codesign --force --sign "$SIGN_IDENTITY" $RUNTIME_FLAGS "$DMG"
  echo "Disk image: $DMG"
fi

if [ "$NOTARIZE" = 1 ]; then
  : "${ASC_API_KEY_ID:?Set ASC_API_KEY_ID (App Store Connect API key id; the .p8 lives in ~/.private_keys)}"
  : "${ASC_API_ISSUER_ID:?Set ASC_API_ISSUER_ID}"
  KEY_FILE="$HOME/.private_keys/AuthKey_$ASC_API_KEY_ID.p8"
  [ -f "$KEY_FILE" ] || { echo "API key file not found: $KEY_FILE" >&2; exit 1; }
  xcrun notarytool submit "$DMG" --key "$KEY_FILE" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID" --wait
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
  echo "Notarised and stapled: $DMG — attach it to a GitHub release, for example:"
  echo "  gh release create v$VERSION --prerelease --title \"Phone $VERSION\" \"$DMG\""
fi

if [ "$UPLOAD" = 1 ]; then
  : "${ASC_API_KEY_ID:?Set ASC_API_KEY_ID (App Store Connect API key id; the .p8 lives in ~/.private_keys)}"
  : "${ASC_API_ISSUER_ID:?Set ASC_API_ISSUER_ID}"
  xcrun altool --validate-app -f "$DIST/Phone.pkg" -t macos --apiKey "$ASC_API_KEY_ID" --apiIssuer "$ASC_API_ISSUER_ID"
  xcrun altool --upload-app -f "$DIST/Phone.pkg" -t macos --apiKey "$ASC_API_KEY_ID" --apiIssuer "$ASC_API_ISSUER_ID"
  echo "Uploaded build $BUILD_NUMBER of $VERSION; it appears under TestFlight in App Store Connect after processing."
fi
