#!/bin/bash
#
# QASSA (Android 10) build script for Sony Xperia XZ2 (akari)
#
# Usage:
#   ./qassa.sh [--akari] [--with-gapps | --vanilla]
#
set -o pipefail

# =========================================================
# CONFIGURATION
# =========================================================
BUILD_TARGET="QASSA"
ANDROID_VERSION="10 (Q)"
DEVICE_CODE="akari"
WITH_GAPPS="${WITH_GAPPS:-true}"

BASE_REPO_INIT="repo init --depth=1 -u https://github.com/keepQASSA/manifest -b Q --git-lfs"

KERNEL_REPO="https://github.com/juniarafi213/kernel_sony_sdm845"
KERNEL_BRANCH="qassa-10"

DEVICE_REPO="https://github.com/juniarafi213/device_sony_akari"
DEVICE_BRANCH="qassa-10"

DEVICE_COMMON_REPO="https://github.com/juniarafi213/device_sony_tama"
DEVICE_COMMON_BRANCH="qassa-10"

VENDOR_REPO="https://github.com/TheMuppets/proprietary_vendor_sony"
VENDOR_BRANCH="lineage-17.1"

# Telegram notifications (base64-encoded credentials, override via env if needed)
TG_BOT_TOKEN="${TG_BOT_TOKEN:-$(echo "ODUxNjE1Njk1NTpBQUZVVUxLb2FmWW1NZ0VCRmprOTRsS2FadDdta2VFTUppTQ==" | base64 -d)}"
TG_CHAT_ID="${TG_CHAT_ID:-$(echo "NjcwMTAwNTg2NQ==" | base64 -d)}"

# Setup timezone
export TZ="Asia/Jakarta"

# =========================================================
# HELPERS
# =========================================================

usage() {
  echo "Usage: $0 [--akari] [--with-gapps | --vanilla]"
}

tg_send() {
  if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
    return 0
  fi
  curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=$1" \
    -d "parse_mode=HTML" \
    -d "disable_web_page_preview=true" &> /dev/null
}

format_duration() {
  local T=$1
  local H=$((T/3600))
  local M=$(( (T%3600)/60 ))
  local S=$((T%60))
  printf "%02d hours, %02d minutes, %02d seconds" "$H" "$M" "$S"
}

upload_files() {
  if [ $# -eq 0 ]; then
    echo "Error: No file specified for upload." >&2
    echo "UPLOAD_FAILED"
    return 1
  fi

  echo "Fetching best server from Gofile..." >&2
  BEST_SERVER=$(curl -s https://api.gofile.io/servers | grep -oP '(?<="name":")[^"]*' | head -n 1)
  if [ -z "$BEST_SERVER" ]; then
    echo "Failed to get active server. Falling back to store3..." >&2
    BEST_SERVER="store3"
  fi

  for FILE in "$@"; do
    if [ ! -f "$FILE" ]; then
      echo "\"$FILE\" not found! Skipping." >&2
      continue
    fi

    FILENAME="${FILE##*/}"
    FILESIZE=$(du -h "$FILE" | cut -f1)

    echo "Uploading $FILENAME ($FILESIZE) via $BEST_SERVER..." >&2
    RESPONSE=$(curl -# -F "file=@$FILE" "https://${BEST_SERVER}.gofile.io/contents/uploadfile")
    UPLOAD_STATUS=$(echo "$RESPONSE" | grep -o '"status":"ok"')

    if [[ -n "$UPLOAD_STATUS" ]]; then
      GOLINK=$(echo "$RESPONSE" | grep -oP '"downloadPage":"\K[^"]+')
      echo "Success!" >&2
      echo "Link: ${GOLINK}" >&2
      echo "${FILENAME}|${FILESIZE}|${GOLINK}"
      return 0
    else
      echo "Upload failed! Response: $RESPONSE" >&2
      echo "UPLOAD_FAILED"
      return 1
    fi
  done
}

# =========================================================
# PARSE ARGUMENTS
# =========================================================
for arg in "$@"; do
  case "$arg" in
    --akari)
      DEVICE_CODE="akari"
      ;;
    --with-gapps)
      WITH_GAPPS="true"
      ;;
    --vanilla)
      WITH_GAPPS="false"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
  esac
done

# =========================================================
# BUILD PROCESS
# =========================================================
start_build_process() {
  START_TIME=$(date +%s)
  local server_name
  server_name=$(hostname 2>/dev/null || echo "Build Server")

  echo "Sending build start message..."
  tg_send "⚙️ <b>ROM Build Started!</b>

• <b>ROM:</b> ${BUILD_TARGET}
• <b>Android:</b> ${ANDROID_VERSION}
• <b>Device:</b> ${DEVICE_CODE}
• <b>GApps:</b> ${WITH_GAPPS}
• <b>Server:</b> ${server_name}
• <b>Start:</b> $(date '+%Y-%m-%d %H:%M:%S %Z')"

  echo "Configuring git credentials and cookiefile bypass..."
  touch ~/.gitcookies
  chmod 600 ~/.gitcookies
  git config --global http.cookiefile ~/.gitcookies 2>/dev/null || true
  git config --global user.name "juniarafi213"
  git config --global user.email "juniarafi506@gmail.com"

  echo "Ensuring required build tools (repo, python)..."
  mkdir -p "$HOME/.bin"
  export PATH="$HOME/.bin:$PATH"

  if ! command -v python &>/dev/null && command -v python3 &>/dev/null; then
    ln -sf "$(which python3)" "$HOME/.bin/python"
  fi

  if ! command -v repo &>/dev/null; then
    echo "repo not found, downloading repo tool..."
    curl -s https://storage.googleapis.com/git-repo-downloads/repo > "$HOME/.bin/repo"
    chmod a+x "$HOME/.bin/repo"
  fi

  echo "Initializing QASSA repo manifest..."
  $BASE_REPO_INIT || {
    echo "repo init failed!"
    tg_send "❌ <b>ROM Build Failed!</b>%0A• <b>Device:</b> ${DEVICE_CODE}%0A• <b>Step:</b> repo init failed"
    exit 1
  }

  echo "Syncing sources..."
  SYNC_JOBS=16
  repo sync -c -j"$SYNC_JOBS" --force-sync --no-clone-bundle --no-tags || {
    echo "repo sync with -j$SYNC_JOBS failed, retrying with -j8..."
    repo sync -c -j8 --force-sync --no-clone-bundle --no-tags || {
      echo "repo sync failed permanently!"
      tg_send "❌ <b>ROM Build Failed!</b>%0A• <b>Device:</b> ${DEVICE_CODE}%0A• <b>Step:</b> repo sync failed"
      exit 1
    }
  }

  echo "Setting up device trees, kernel, and vendor blobs..."
  rm -rf .repo/local_manifests
  if [ ! -d "kernel/sony/sdm845/.git" ]; then
    rm -rf kernel/sony/sdm845
    git clone "$KERNEL_REPO" -b "$KERNEL_BRANCH" --depth=1 kernel/sony/sdm845 || exit 1
  else
    (cd kernel/sony/sdm845 && git fetch origin "$KERNEL_BRANCH" && git checkout "$KERNEL_BRANCH" && git reset --hard origin/"$KERNEL_BRANCH")
  fi

  if [ ! -d "device/sony/$DEVICE_CODE/.git" ]; then
    rm -rf device/sony/"$DEVICE_CODE"
    git clone "$DEVICE_REPO" -b "$DEVICE_BRANCH" --depth=1 device/sony/"$DEVICE_CODE" || exit 1
  else
    (cd device/sony/"$DEVICE_CODE" && git fetch origin "$DEVICE_BRANCH" && git checkout "$DEVICE_BRANCH" && git reset --hard origin/"$DEVICE_BRANCH")
  fi

  if [ ! -d "device/sony/tama-common/.git" ]; then
    rm -rf device/sony/tama-common
    git clone "$DEVICE_COMMON_REPO" -b "$DEVICE_COMMON_BRANCH" --depth=1 device/sony/tama-common || exit 1
  else
    (cd device/sony/tama-common && git fetch origin "$DEVICE_COMMON_BRANCH" && git checkout "$DEVICE_COMMON_BRANCH" && git reset --hard origin/"$DEVICE_COMMON_BRANCH")
  fi

  if [ ! -d "vendor/sony/.git" ]; then
    rm -rf vendor/sony
    git clone "$VENDOR_REPO" -b "$VENDOR_BRANCH" --depth=1 vendor/sony || exit 1
  else
    (cd vendor/sony && git fetch origin "$VENDOR_BRANCH" && git checkout "$VENDOR_BRANCH" && git reset --hard origin/"$VENDOR_BRANCH")
  fi

  echo "Configuring CCACHE..."
  if command -v ccache &>/dev/null; then
    export USE_CCACHE=1
    export CCACHE_EXEC=$(which ccache)
    export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
    ccache -M 50G
  fi

  echo "Starting QASSA ROM build..."
  export WITH_GAPPS="$WITH_GAPPS"
  export TARGET_GAPPS_ARCH="arm64"
  export TARGET_BOOT_ANIMATION_RES="1080"
  source build/envsetup.sh
  lunch "qassa_${DEVICE_CODE}-userdebug" || {
    echo "lunch failed!"
    tg_send "❌ <b>ROM Build Failed!</b>%0A• <b>Device:</b> ${DEVICE_CODE}%0A• <b>Step:</b> lunch failed"
    exit 1
  }

  BUILD_JOBS=$(nproc 2>/dev/null || echo 4)
  mka qassa -j"$BUILD_JOBS"
  BUILD_STATUS=$?

  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))
  DURATION_FORMATTED=$(format_duration "$DURATION")

  if [[ $BUILD_STATUS -eq 0 ]]; then
    ZIP_FILE=$(ls -t out/target/product/"$DEVICE_CODE"/qassa_*"$DEVICE_CODE"*.zip 2>/dev/null | head -n 1)
    if [ -z "$ZIP_FILE" ]; then
      ZIP_FILE=$(ls -t out/target/product/"$DEVICE_CODE"/*.zip 2>/dev/null | head -n 1)
    fi

    UPLOAD_RESULT=$(upload_files "$ZIP_FILE")

    if [[ "$UPLOAD_RESULT" != "UPLOAD_FAILED" ]]; then
      IFS='|' read -r FILENAME FILESIZE GOLINK <<< "$UPLOAD_RESULT"
      tg_send "✅ <b>ROM Build Finished!</b>

• <b>ROM:</b> ${BUILD_TARGET}
• <b>Android:</b> ${ANDROID_VERSION}
• <b>Device:</b> ${DEVICE_CODE}
• <b>File:</b> ${FILENAME}
• <b>Size:</b> ${FILESIZE}
• <b>Link:</b> ${GOLINK}
• <b>Duration:</b> ${DURATION_FORMATTED}"
    else
      tg_send "✅ <b>ROM Build Finished!</b> (upload failed)

• <b>ROM:</b> ${BUILD_TARGET}
• <b>Device:</b> ${DEVICE_CODE}
• <b>Duration:</b> ${DURATION_FORMATTED}"
    fi
  else
    tg_send "❌ <b>ROM Build Failed!</b>

• <b>ROM:</b> ${BUILD_TARGET}
• <b>Device:</b> ${DEVICE_CODE}
• <b>Exit code:</b> ${BUILD_STATUS}
• <b>Duration:</b> ${DURATION_FORMATTED}"
    exit "$BUILD_STATUS"
  fi
}

start_build_process
