#!/bin/bash

# BPI-R4 OpenWrt/MediaTek Build Automation Script (OpenWrt 24.10.2 Release)
# All overlays in BPI-R4-BUILD/contents/
# Maintainer: Luke

set -euo pipefail

# --- Install Dependencies ---
install_dependencies() {
  echo "Checking and installing dependencies..."
  packages=(
    build-essential clang flex bison g++ gawk gcc-multilib g++-multilib
    gettext git libncurses-dev libssl-dev python3-setuptools rsync swig
    unzip zlib1g-dev file wget libtraceevent-dev systemtap-sdt-dev libslang-dev
    pv
  )

  for package in "${packages[@]}"; do
    if ! dpkg -s "$package" &> /dev/null; then
      echo "Installing $package..."
      sudo apt-get install -y "$package" || echo "Skipping $package (not available)"
    else
      echo "$package is already installed."
    fi
  done
}

# --- Progress Functions ---
progress_bar() {
  local current=$1
  local total=$2
  local bar_length=50
  local progress=$((current * bar_length / total))
  
  tput sc # Save the cursor position
  tput cup $(($(tput lines) - 1)) 0 # Move cursor to the bottom of the screen

  printf "\r[%-${bar_length}s] %d%%" "$(printf '#%.0s' $(seq 1 $progress))" "$((current * 100 / total))"
  [ "$current" -eq "$total" ] && echo ""

  tput rc # Restore the cursor to previous position
}

log_progress() {
  local current_step=$1
  local total_steps=$2
  echo "Progress: Step $current_step of $total_steps"
}

# Simulate tracking build progress
track_build_progress() {
  local progress_count=0
  make V=sc -j"$(nproc)" 2>&1 | tee -a "$LOG_FILE" | while read -r line; do
    echo "$line"
    if [[ "$line" == *"Entering directory"* ]]; then
      progress_count=$((progress_count+1))
    fi
    progress_bar "$progress_count" 100 # Adjust total based on expected directories
  done
}

# --- Relative Build Asset Locations ---
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
REPO_ROOT="$SCRIPT_DIR"
CONTENTS_DIR="$REPO_ROOT/contents"

OPENWRT_DIR="$REPO_ROOT/OpenWRT_BPI_R4"
PROFILE="filogic-mac80211-mt7988_rfb-mt7996"

LEXY_CONFIG_SRC="$CONTENTS_DIR/mm_config"
DEVICE_FILES_SRC="$CONTENTS_DIR/files"
BUILDER_FILES_SRC="$CONTENTS_DIR"
EEPROM_BLOB=$(find "$CONTENTS_DIR" -maxdepth 1 -type f -iname '*.bin' | head -n1)
DEST_EEPROM_NAME="mt7996_eeprom_233_2i5i6i.bin"

MTK_REPO="https://git01.mediatek.com/openwrt/feeds/mtk-openwrt-feeds"
OPENWRT_REPO="https://git.openwrt.org/openwrt/openwrt.git"
OPENWRT_TAG="v24.10.2"
FEED_NAME="mtk_openwrt_feed"
FEED_PATH="mtk-openwrt-feeds"

RED='\033[0;31m'
NC='\033[0m'
MIN_DISK_GB=12
CLEAN_MARKER_FILE="$REPO_ROOT/.openwrt_cloned_this_session"

# --- Argument Parsing ---
SKIP_CONFIRM=0
if [[ "${1-}" == "--force" ]]; then
    SKIP_CONFIRM=1
fi

# --- Error Handling ---
on_error() {
  local exit_code=$?
  echo -e "${RED}##########################################################${NC}"
  echo -e "${RED}#           >>>>> A CRITICAL ERROR OCCURRED <<<<<         #${NC}"
  echo -e "${RED}# Error on line $LINENO: Command '$BASH_COMMAND' exited with status $exit_code.${NC}"
  echo -e "${RED}##########################################################${NC}"
  echo "For troubleshooting, review the build log:"
  [[ -f "$LOG_FILE" ]] && echo "   $LOG_FILE"
  exit $exit_code
}
trap on_error ERR

# --- Logging Setup ---
DATE_TAG=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="$REPO_ROOT/build_log_${DATE_TAG}.txt"
exec > >(tee -a "$LOG_FILE") 2>&1

# --- Helper Functions ---
step_echo() {
  echo "================================================================="
  echo "=> $1"
  echo "================================================================="
}

check_space() {
    local avail
    avail=$(df --output=avail "$REPO_ROOT" | tail -1)
    local avail_gb=$((avail / 1024 / 1024))
    if [[ "$avail_gb" -lt "$MIN_DISK_GB" ]]; then
        echo -e "${RED}ERROR: Less than ${MIN_DISK_GB}GB free disk on $REPO_ROOT. (Available: ${avail_gb}GB)${NC}"
        exit 1
    fi
}

check_requirements() {
    local err=0
    if [[ ! -d "$BUILDER_FILES_SRC/my_files" ]]; then
        echo -e "${RED}ERROR: Expected builder my_files at $BUILDER_FILES_SRC/my_files${NC}"; err=1
    fi
    if [[ ! -d "$BUILDER_FILES_SRC/configs" ]]; then
        echo -e "${RED}ERROR: Expected builder configs at $BUILDER_FILES_SRC/configs${NC}"; err=1
    fi
    if [[ ! -d "$DEVICE_FILES_SRC" ]]; then
        echo -e "${RED}ERROR: Expected 'files' directory at $DEVICE_FILES_SRC${NC}"; err=1
    fi
    if [[ ! -f "$LEXY_CONFIG_SRC" ]]; then
        echo -e "${RED}ERROR: Expected .config file at $LEXY_CONFIG_SRC${NC}"; err=1
    fi
    if [[ -z "$EEPROM_BLOB" ]]; then
        echo -e "${RED}ERROR: No EEPROM *.bin found at $CONTENTS_DIR${NC}"; err=1
    fi
    if [[ "$err" != 0 ]]; then
        echo -e "${RED}One or more required files/folders missing!${NC}"
        exit 1
    fi
}

safe_rsync() {
    local SRC="$1"
    local DST="$2"
    rsync -a --delete --info=progress2 "$SRC" "$DST"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}rsync failed copying $SRC to $DST.${NC}"
        exit 1
    fi
}

register_feed() {
    local FEED_NAME="$1"
    sed -i "/$FEED_NAME/d" feeds.conf.default
    echo "Feed '$FEED_NAME' lines cleaned (addition deferred to MTK autobuilder)."
}

ensure_patch_directories() {
    local dir="$OPENWRT_DIR/package/boot/uboot-envtools/files"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        echo "Created missing patch directory: $dir"
    fi
}

inject_custom_be14_eeprom() {
    local eeprom_src="$EEPROM_BLOB"
    local eeprom_dst="$OPENWRT_DIR/files/lib/firmware/mediatek/$DEST_EEPROM_NAME"
    local fw_dir
    fw_dir="$(dirname "$eeprom_dst")"

    if [[ ! -f "$eeprom_src" ]]; then
        echo -e "${RED}ERROR: BE14 EEPROM .bin not found at $eeprom_src${NC}"
        exit 1
    fi

    mkdir -p "$fw_dir"
    cp -af "$eeprom_src" "$eeprom_dst"
    echo "Copied EEPROM as $eeprom_dst"
}

patch_config_for_main_be14_router() {
  local config_file="$OPENWRT_DIR/.config"
  if [[ ! -f "$config_file" ]]; then
    echo -e "${RED}ERROR: Could not patch .config (file not found at $config_file)!${NC}"
    exit 1
  fi

  echo "Patching .config to ensure up-to-date packages for BE14/RM520NGL-AP main router..."

  local WANTED_CONFIGS=$(cat <<'EOF'
CONFIG_PACKAGE_kmod-mt7996=y
CONFIG_PACKAGE_wireless-regdb=y
CONFIG_PACKAGE_iw=y
CONFIG_PACKAGE_wpad-openssl=y
CONFIG_PACKAGE_kmod-usb-net-qmi-wwan=y
CONFIG_PACKAGE_kmod-wwan=y
CONFIG_PACKAGE_uqmi=y
CONFIG_PACKAGE_luci-proto-qmi=y
CONFIG_PACKAGE_modemmanager=y
CONFIG_PACKAGE_luci-proto-modemmanager=y
CONFIG_PACKAGE_minicom=y
CONFIG_PACKAGE_usb-modeswitch=y
CONFIG_PACKAGE_kmod-usb-serial-option=y
CONFIG_PACKAGE_kmod-usb-serial=y
CONFIG_PACKAGE_kmod-usb-acm=y
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-app-firewall=y
CONFIG_PACKAGE_dnsmasq=y
CONFIG_PACKAGE_firewall4=y
CONFIG_PACKAGE_odhcpd-ipv6only=y
CONFIG_PACKAGE_luci-app-mwan3=y
CONFIG_PACKAGE_luci-app-statistics=y
CONFIG_PACKAGE_usbutils=y
CONFIG_PACKAGE_pciutils=y
CONFIG_PACKAGE_htop=y
CONFIG_PACKAGE_iftop=y
CONFIG_PACKAGE_tcpdump=y
CONFIG_PACKAGE_kmod-fs-ext4=y
CONFIG_PACKAGE_kmod-fs-vfat=y
CONFIG_PACKAGE_e2fsprogs=y
CONFIG_PACKAGE_block-mount=y
EOF
)

  while read line; do
    [[ -z "$line" ]] && continue
    if ! grep -q -F "$line" "$config_file"; then
      echo "$line" >> "$config_file"
      echo "  + Added: $line"
    fi
  done <<< "$WANTED_CONFIGS"
}

check_for_patch_rejects() {
    local build_dir="$1"
    local rejs
    rejs=$(find "$build_dir" -name '*.rej' 2>/dev/null)
    if [[ -n "$rejs" ]]; then
        echo -e "${RED}#########################################################${NC}"
        echo -e "${RED} PATCH REJECT(S) DETECTED!${NC}"
        echo -e "${RED} These files indicate a patch failed to apply cleanly:${NC}"
        echo "$rejs"
        echo ""
        for file in $rejs; do
            echo -e "${RED}---- Contents of $file ----${NC}"
            cat "$file"
            echo -e "${RED}---------------------------${NC}"
        done
        echo ""
        echo -e "${RED}=== Build is aborting due to patch rejects. Please review above and fix the patch set. ===${NC}"
        exit 77
    fi
}

# --- Build Steps ---

clean_and_clone() {
    local total_steps=4
    local current_step=1
    log_progress "$current_step" "$total_steps"
    progress_bar "$current_step" "$total_steps"
    
    step_echo "Step 1: Clean Up & Clone Repos into a Fresh Directory"

    rm -rf "$OPENWRT_DIR"
    rm -f "$CLEAN_MARKER_FILE"

    if [[ "$SKIP_CONFIRM" == "0" ]]; then
        read -p "This will delete the '$OPENWRT_DIR' directory. Continue? (y/n) " -n 1 -r; echo
        if [[ ! $REPLY =~
