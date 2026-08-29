#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')
SIGN_IDENTITY=${SIGN_IDENTITY:--}

cd "$ROOT"
sh "$ROOT/scripts/build-audio-tap.sh"
mkdir -p "$ROOT/.build/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/ModuleCache"
swift build --disable-sandbox -c debug

BIN_DIR=$(swift build --disable-sandbox -c debug --show-bin-path)
APP="$ROOT/dist/Phone.app"
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
cp "$BARESIP_EXECUTABLE" "$APP/Contents/Helpers/baresip"
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/baresip/modules"
cp "$ROOT/runtime/baresip/config" "$APP/Contents/Resources/baresip/config"
cp "$ROOT/runtime/baresip/accounts.example" "$APP/Contents/Resources/baresip/accounts.example"
cp "$ROOT/Resources/baresip/contacts" "$APP/Contents/Resources/baresip/contacts"

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

for module in $(awk '$1 == "module" || $1 == "module_app" {print $2}' "$APP/Contents/Resources/baresip/config"); do
  if [ "$module" = "phone_tap.so" ] || [ "$module" = "g722.so" ]; then
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

for module in "$MODULES"/*.so; do
  codesign --force --sign "$SIGN_IDENTITY" "$module"
done
for library in "$FRAMEWORKS"/*.dylib; do
  codesign --force --sign "$SIGN_IDENTITY" "$library"
done
codesign --force --sign "$SIGN_IDENTITY" "$HELPER"
codesign --force --sign "$SIGN_IDENTITY" "$MCP_HELPER"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Phone</string>
  <key>CFBundleIdentifier</key><string>local.phone.mini</string>
  <key>CFBundleName</key><string>Phone</string>
  <key>CFBundleDisplayName</key><string>Phone</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSContactsUsageDescription</key><string>Phone shows contact names for incoming and outgoing calls.</string>
  <key>NSMicrophoneUsageDescription</key><string>Phone needs the microphone for SIP calls.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Phone transcribes calls locally on this Mac.</string>
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

codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
