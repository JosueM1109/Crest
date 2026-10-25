#!/bin/zsh
# Builds Josue's Crest and installs it at /Applications/Crest.app.
#
# The maintainer's published Chromium engine for this checkout's engine inputs
# is packaged with the Swift UI framework and C# core built from this checkout.
# The app is signed with Josue's Apple Development certificate. It keeps the
# com.pauldavis.crest bundle ID because the engine names its keychain item
# after that ID (see CrestEngines/Chromium/Patches/native-host.patch).
#
# The app still contains Sparkle, but its update key is replaced, so it can't
# install the maintainer's builds over this one. Local/update.sh is how this
# build gets updated.
#
# Based on Scripts/install-local-macos-release.sh. Local/update.sh warns when
# upstream changes that recipe.
#
# Environment overrides:
#   CREST_CHROMIUM_APP    use a locally built Chromium.app instead of the published engine
#   CREST_LOCAL_TEAM_ID   signing team (default LGV78N28G9)
#   CREST_DOTNET          .NET SDK (default ~/.dotnet/dotnet, from Scripts/control-plane/install-dotnet.sh)
#   CREST_LOCAL_NO_LAUNCH set to 1 to install without opening Crest

set -euo pipefail

main() {
  local repo="${0:A:h:h}"
  cd "$repo"

  local team_id="${CREST_LOCAL_TEAM_ID:-LGV78N28G9}"
  local app_path="/Applications/Crest.app"
  local cache="$HOME/Library/Caches/Crest-local"
  local derived="$HOME/Library/Developer/Xcode/DerivedData/Crest-Local"
  local engines="$cache/engines"
  local lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
  # A random Ed25519 public key with no private key behind it. Sparkle verifies
  # feeds and updates against this key, so nothing the maintainer signs passes.
  local inert_update_key="lb9kStmz+iaq6DHWrBA8Kzrp0EQeNENqmX2Ttc6uDbE="

  local dotnet="${CREST_DOTNET:-$HOME/.dotnet/dotnet}"
  if [[ ! -x "$dotnet" ]]; then
    print -u2 "No .NET SDK at $dotnet. Run Scripts/control-plane/install-dotnet.sh."
    exit 1
  fi
  export CREST_DOTNET="$dotnet" DOTNET_ROOT="${dotnet:h}" DOTNET_CLI_TELEMETRY_OPTOUT=1
  mkdir -p "$cache"

  # --- Signing identity: a valid Apple Development certificate on the team. ---
  local identity=""
  local valid_hashes="$(security find-identity -v -p codesigning | awk '/"Apple Development: / { print $2 }')"
  local candidate
  for candidate in ${(f)valid_hashes}; do
    if security find-certificate -a -Z -p -c "Apple Development" \
      | awk -v h="$candidate" '/^SHA-1 hash:/ { keep = ($3 == h) } keep' \
      | openssl x509 -noout -subject 2>/dev/null | grep -q "OU *= *${team_id}"; then
      identity="$candidate"
      break
    fi
  done
  if [[ -z "$identity" ]]; then
    print -u2 "No valid Apple Development certificate for team $team_id. Sign in to Xcode > Settings > Accounts."
    exit 1
  fi

  local build_number="$(git rev-list --count HEAD)"
  local commit="$(git rev-parse --short HEAD)"
  local upstream_base="$(git describe --tags --abbrev=0 --match 'v*' HEAD 2>/dev/null || print unknown)"
  local work="$(mktemp -d "${TMPDIR%/}/crest-local.XXXXXX")"
  local product="$work/product/Crest.app"
  trap "find '$work' -depth -delete 2>/dev/null || true" EXIT INT TERM HUP

  # --- Chromium engine: resolved first, so a missing engine stops before the builds. ---
  local engine engine_label
  if [[ -n "${CREST_CHROMIUM_APP:-}" ]]; then
    engine="${CREST_CHROMIUM_APP:A}"
    engine_label="local engine at $engine"
  else
    local tag="$(python3 Scripts/control-plane/chromium_engine.py tag)"
    local asset="$(python3 Scripts/control-plane/chromium_engine.py asset)"
    engine="$engines/$tag/Chromium.app"
    engine_label="$tag"
    if [[ ! -d "$engine" ]]; then
      print "Downloading Chromium engine $tag..."
      local download="$work/engine-download"
      mkdir -p "$download"
      if ! gh release download "$tag" --repo pauljoda/Crest \
        --pattern "$asset" --pattern "${asset}.sha256" --dir "$download"; then
        print -u2 "No published engine $tag. This checkout changed engine inputs, or the maintainer"
        print -u2 "hasn't published it. Build Chromium (CrestEngines/Chromium/README.md) and rerun"
        print -u2 "with CREST_CHROMIUM_APP=/path/to/Chromium.app."
        exit 1
      fi
      (cd "$download" && shasum -a 256 -c "${asset}.sha256")
      ditto -x -k "$download/$asset" "$download/extracted"
      [[ -d "$download/extracted/Chromium.app" ]]
      mkdir -p "$engines"
      mv "$download/extracted" "$engines/$tag"
      # Keep this engine and the one before it, for rollback.
      ls -1t "$engines" | tail -n +3 | while read -r old; do find "$engines/$old" -depth -delete; done
    fi
  fi
  [[ -f "$engine/Contents/Info.plist" ]] || { print -u2 "No Chromium.app at $engine."; exit 1; }

  print "Building Crest $commit (upstream $upstream_base, build $build_number) with $engine_label..."

  # --- Native core and UI framework. ---
  (cd CrestCore && "$dotnet" publish src/CrestCore.Native -c Release -r osx-arm64 --nologo -v quiet)
  local core="$PWD/CrestCore/src/CrestCore.Native/bin/Release/net10.0/osx-arm64/publish/CrestCore.Native.dylib"
  [[ -f "$core" ]]

  xcodebuild build -quiet \
    -project Crest.xcodeproj \
    -scheme CrestChromiumUIProduct \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived" \
    CURRENT_PROJECT_VERSION="$build_number" \
    CODE_SIGNING_ALLOWED=NO
  local ui="$derived/Build/Products/Release/CrestChromiumUIProduct.framework"
  [[ -d "$ui" ]]
  local entry
  for entry in crest_chromium_ui_start crest_native_host_run; do
    nm -gU "$ui/CrestChromiumUIProduct" | grep -q "_${entry}\$" \
      || { print -u2 "CrestChromiumUIProduct does not export $entry."; exit 1; }
  done

  # --- Package and sign, like the release. No provisioning profile, so no CloudKit. ---
  mkdir -p "${product:h}"
  CREST_DEFAULT_UPDATE_CHANNEL=stable python3 Scripts/control-plane/package-chromium-host.py \
    --browser "$engine" \
    --product \
    --distribution \
    --ui "$ui" \
    --core "$core" \
    --entitlements "$repo/Local/Crest.entitlements" \
    --signing-identity "$identity" \
    --output "$product"

  # --- Disable updates from the maintainer's feed, record where this build came from, re-sign the outer bundle. ---
  local info="$product/Contents/Info.plist"
  /usr/libexec/PlistBuddy \
    -c "Set :SUPublicEDKey $inert_update_key" \
    -c "Set :SUEnableAutomaticChecks false" \
    -c "Set :SUAutomaticallyUpdate false" \
    -c "Add :CrestLocalBuildCommit string $commit" \
    -c "Add :CrestLocalBuildUpstream string $upstream_base" \
    "$info"
  codesign --force --timestamp --preserve-metadata=entitlements,flags,runtime --sign "$identity" "$product"
  codesign --verify --deep --strict "$product"
  [[ "$(defaults read "${product}/Contents/Info" CFBundleIdentifier)" == "com.pauldavis.crest" ]]

  # --- Install, keeping the previous app for rollback. ---
  local running="^${app_path}/Contents/MacOS/"
  if pgrep -f "$running" >/dev/null 2>&1; then
    osascript -e 'tell application "Crest" to quit' || true
    local i
    for i in {1..100}; do
      pgrep -f "$running" >/dev/null 2>&1 || break
      sleep 0.1
    done
    if pgrep -f "$running" >/dev/null 2>&1; then
      print -u2 "Crest did not quit; the installed app was not replaced."
      exit 1
    fi
  fi
  local staging="/Applications/.Crest-local-install-$$.app"
  ditto "$product" "$staging"
  if [[ -e "$app_path" ]]; then
    [[ -e "$cache/Crest.previous.app" ]] && find "$cache/Crest.previous.app" -depth -delete
    mv "$app_path" "$cache/Crest.previous.app"
    "$lsregister" -u "$cache/Crest.previous.app" >/dev/null 2>&1 || true
  fi
  mv "$staging" "$app_path"
  codesign --verify --deep --strict "$app_path"
  "$lsregister" -f "$app_path" >/dev/null 2>&1 || true
  [[ "${CREST_LOCAL_NO_LAUNCH:-0}" == 1 ]] || open "$app_path"
  print "Installed Crest $commit (upstream $upstream_base, build $build_number) with $engine_label."
}

main "$@"
