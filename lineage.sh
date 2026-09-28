#!/bin/bash
# =========================================================
# LineageOS 23.2 (Android 16) Build Script for Sony Xperia XZ2 (akari)
# Diadaptasi dari: https://github.com/aoitsme/crave_script
# =========================================================

DEVICE_CODE="akari"
BUILD_TARGET="LineageOS"
ANDROID_VERSION="16"

# Setup Timezone
export TZ="Asia/Jakarta"

# Telegram Bot (Opsional: isi jika ingin notifikasi ke Telegram Anda sendiri)
TG_BOT_TOKEN="8516156955:AAFUULKoafYmMgEBFjk94lKaZt7mkeEMJiM"
TG_CHAT_ID="6701005865"

# =========================================================
# TELEGRAM FUNCTIONS
# =========================================================
send_telegram_msg() {
  local chat_id="$1"
  local message="$2"
  if [ -n "$TG_BOT_TOKEN" ] && [ -n "$chat_id" ]; then
    echo "Mengirim notifikasi ke Telegram..."
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
      -d "chat_id=${chat_id}" \
      --data-urlencode "text=${message}" \
      -d "parse_mode=HTML" \
      -d "disable_web_page_preview=true" &> /dev/null || true
  fi
}

send_telegram_file() {
  local chat_id="$1"
  local file_path="$2"
  if [ -n "$TG_BOT_TOKEN" ] && [ -n "$chat_id" ] && [ -f "$file_path" ]; then
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument" \
      -F chat_id="${chat_id}" \
      -F document=@"${file_path}" &> /dev/null || true
  fi
}

format_duration() {
    local T=$1
    local H=$((T/3600))
    local M=$(( (T%3600)/60 ))
    local S=$((T%60))
    printf "%02d jam, %02d menit, %02d detik" $H $M $S
}

# =========================================================
# GOFILE UPLOAD LOGIC
# =========================================================
upload_files() {
  if [ $# -eq 0 ]; then
      echo "Error: Tidak ada file yang ditentukan untuk upload." >&2
      return 1
  fi

  echo "Mengambil server terbaik dari Gofile..." >&2
  BEST_SERVER=$(curl -s https://api.gofile.io/servers | grep -oP '(?<="name":")[^"]*' | head -n 1)

  if [ -z "$BEST_SERVER" ]; then
      echo "Gagal mengambil server aktif. Menggunakan fallback store3..." >&2
      BEST_SERVER="store3"
  fi

  for FILE in "$@"; do
    if [ ! -f "$FILE" ]; then
      echo "\"$FILE\" tidak ditemukan! Lewati." >&2
      continue
    fi

    FILENAME="${FILE##*/}"
    FILESIZE=$(du -h "$FILE" | cut -f1)
    
    echo "Mengupload $FILENAME ($FILESIZE) ke $BEST_SERVER..." >&2

    RESPONSE=$(curl -# -F "file=@$FILE" "https://${BEST_SERVER}.gofile.io/contents/uploadfile")
    UPLOAD_STATUS=$(echo "$RESPONSE" | grep -o '"status":"ok"')

    if [[ -n "$UPLOAD_STATUS" ]]; then
        GOLINK=$(echo "$RESPONSE" | grep -oP '"downloadPage":"\K[^"]+')
        echo "Upload Berhasil!" >&2
        echo "Link Unduh: ${GOLINK}" >&2
        echo "${FILENAME}|${FILESIZE}|${GOLINK}"
        return 0
    else
        echo "Upload gagal! Response: $RESPONSE" >&2
        echo "UPLOAD_FAILED"
        return 1
    fi
  done
}

# =========================================================
# BUILD FUNCTION
# =========================================================
start_build_process() {
    START_TIME=$(date +%s)

    echo "=========================================================="
    echo "  Memulai Build LineageOS 23.2 (Android 16) untuk $DEVICE_CODE"
    echo "=========================================================="

    initial_msg=$'⚙️ <b>ROM Build Dimulai!</b>\n\n• <b>ROM:</b> '"$BUILD_TARGET"$'\n• <b>Android:</b> '"$ANDROID_VERSION"$'\n• <b>Device:</b> '"$DEVICE_CODE"$'\n• <b>Server:</b> foss.crave.io\n• <b>Mulai:</b> '"$(date '+%Y-%m-%d %H:%M:%S %Z')"
    send_telegram_msg "$TG_CHAT_ID" "$initial_msg"
    
    echo ">>> [1/7] Membersihkan workspace & folder lama..."
    rm -rf .repo/local_manifests
    rm -rf kernel/configs
    rm -rf hardware/interfaces
    rm -rf frameworks/native
    rm -rf kernel/sony
    rm -rf device/sony
    rm -rf hardware/sony
    rm -rf vendor/sony
    rm -rf vendor/lineage-priv

    echo ">>> [2/7] Konfigurasi identitas Git..."
    git config --global user.name "jun"
    git config --global user.email "juniarafi506@gmail.com"

    echo ">>> [3/7] Inisialisasi LineageOS 23.2..."
    repo init -u https://github.com/LineageOS/android.git -b lineage-23.2 --git-lfs --depth=1

    echo ">>> [4/7] Sinkronisasi repository..."
    if [ -f /opt/crave/resync.sh ]; then
      /opt/crave/resync.sh
    fi
    repo sync -c -j$(nproc --all) --force-sync --no-clone-bundle --no-tags

    echo ">>> [5/7] Mengganti kernel/configs & hardware/interfaces (fix Android 16)..."
    rm -rf kernel/configs
    rm -rf hardware/interfaces
    git clone https://github.com/crdroidandroid/android_kernel_configs -b 16.0 --depth=1 kernel/configs
    git clone https://github.com/crdroidandroid/android_hardware_interfaces -b 16.0 --depth=1 hardware/interfaces
    
    echo ">>> [6/7] Menerapkan patch frameworks/native (fix kamera Android 16)..."
    cd frameworks/native
    wget -q https://raw.githubusercontent.com/aoitsme/crave_script/refs/heads/main/patch/001-temp-fix-camera.patch
    wget -q https://raw.githubusercontent.com/aoitsme/crave_script/refs/heads/main/patch/002-temp-fix-camera.patch
    git am 001-temp-fix-camera.patch
    git am 002-temp-fix-camera.patch
    cd -

    echo ">>> [7/7] Mengambil device, vendor, dan kernel trees (romiyusnandar - Dynamic Partition)..."
    git clone https://github.com/romiyusnandar/kernel_sony_sdm845 -b bpf --depth=1 kernel/sony/sdm845
    git clone https://github.com/romiyusnandar/device_sony_"$DEVICE_CODE" -b lineage-23.2 --depth=1 device/sony/"$DEVICE_CODE"
    git clone https://github.com/romiyusnandar/device_sony_tama-common -b lineage-23.2 --depth=1 device/sony/tama-common
    git clone https://github.com/aoitsme/android_hardware_sony_SonyOpenTelephony -b lineage-23.2 --depth=1 hardware/sony/SonyOpenTelephony
    git clone https://github.com/romiyusnandar/vendor_sony_"$DEVICE_CODE" -b lineage-23.2 --depth=1 vendor/sony/"$DEVICE_CODE"
    git clone https://github.com/romiyusnandar/vendor_sony_tama-common -b bka --depth=1 vendor/sony/tama-common
    git clone https://github.com/aoi-itsme/keys -b new --depth=1 vendor/lineage-priv
    
    echo "=========================================================="
    echo " Memulai kompilasi ROM..."
    echo "=========================================================="
    . build/envsetup.sh
    m installclean
    brunch "$DEVICE_CODE"

    BUILD_STATUS=$?

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    DURATION_FORMATTED=$(format_duration $DURATION)

    if [[ $BUILD_STATUS -eq 0 ]]; then
        echo "=========================================================="
        echo " Build Sukses! Durasi: $DURATION_FORMATTED"
        echo "=========================================================="
        ZIP_FILE=$(ls -t out/target/product/"$DEVICE_CODE"/*"$DEVICE_CODE"*.zip 2>/dev/null | head -n 1)
        
        if [ -n "$ZIP_FILE" ]; then
            echo "File ROM: $ZIP_FILE"
            UPLOAD_RESULT=$(upload_files "$ZIP_FILE")

            if [[ "$UPLOAD_RESULT" != "UPLOAD_FAILED" ]]; then
                IFS='|' read -r FILENAME FILESIZE GOLINK <<< "$UPLOAD_RESULT"
                final_msg=$'✅ <b>ROM Build Berhasil!</b>\n\n• <b>ROM:</b> '"$BUILD_TARGET"$'\n• <b>Android:</b> '"$ANDROID_VERSION"$'\n• <b>Device:</b> '"$DEVICE_CODE"$'\n• <b>File:</b> '"$FILENAME"$'\n• <b>Ukuran:</b> '"$FILESIZE"$'\n• <b>Link Unduh:</b> '"$GOLINK"$'\n• <b>Durasi:</b> '"$DURATION_FORMATTED"$'\n• <b>Status:</b> Sukses'
            else
                final_msg=$'⚠️ <b>ROM Build Berhasil, Gagal Upload ke Gofile</b>\n\n• <b>Device:</b> '"$DEVICE_CODE"$'\n• <b>Durasi:</b> '"$DURATION_FORMATTED"
            fi
        fi
    else
        echo "=========================================================="
        echo " Build Gagal dengan exit code: $BUILD_STATUS"
        echo "=========================================================="
        final_msg=$'❌ <b>ROM Build Gagal!</b>\n\n• <b>ROM:</b> '"$BUILD_TARGET"$'\n• <b>Device:</b> '"$DEVICE_CODE"$'\n• <b>Durasi:</b> '"$DURATION_FORMATTED"$'\n• <b>Exit Code:</b> '"$BUILD_STATUS"
    fi

    send_telegram_msg "$TG_CHAT_ID" "$final_msg"
    
    if [[ $BUILD_STATUS -ne 0 ]]; then
        send_telegram_file "$TG_CHAT_ID" "out/error.log"
    fi

    return $BUILD_STATUS
}

case "$1" in
    --aurora)
        DEVICE_CODE="aurora"
        ;;
    --akatsuki)
        DEVICE_CODE="akatsuki"
        ;;
    --akari|*)
        DEVICE_CODE="akari"
        ;;
esac

start_build_process
