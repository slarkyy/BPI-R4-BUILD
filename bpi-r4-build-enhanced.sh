#!/bin/bash

# BPI-R4 OpenWrt/MediaTek Build Automation Script (OpenWrt 24.10.2 Release)
# Clean, portable: all overlays in BPI-R4-BUILD/
# Maintainer: Luke

set -euo pipefail

# --- Relative Build Asset Locations ---
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
REPO_ROOT="$SCRIPT_DIR"       # Assume script is run from BPI-R4-BUILD

OPENWRT_DIR="$REPO_ROOT/OpenWRT_BPI_R4"
PROFILE="filogic-mac80211-mt7988_rfb-mt7996"

LEXY_CONFIG_SRC="$REPO_ROOT/mm_config"
DEVICE_FILES_SRC="$REPO_ROOT/files"
BUILDER_FILES_SRC="$REPO_ROOT"
EEPROM_BLOB=$(find "$REPO_ROOT" -maxdepth 1 -type f -iname '*.bin' | head -n1)
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
    if [[ ! -d "$BUILDER_FILES_SRC" ]]; then
        echo -e "${RED}ERROR: Expected builder files at $BUILDER_FILES_SRC${NC}"; err=1
    fi
    if [[ ! -d "$DEVICE_FILES_SRC" ]]; then
        echo -e "${RED}ERROR: Expected 'files' directory at $DEVICE_FILES_SRC${NC}"; err=1
    fi
    if [[ ! -f "$LEXY_CONFIG_SRC" ]]; then
        echo -e "${RED}ERROR: Expected .config file at $LEXY_CONFIG_SRC${NC}"; err=1
    fi
    if [[ -z "$EEPROM_BLOB" ]]; then
        echo -e "${RED}ERROR: No EEPROM *.bin found at $REPO_ROOT${NC}"; err=1
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
    step_echo "Step 1: Clean Up & Clone Repos into a Fresh Directory"

    rm -rf "$OPENWRT_DIR"
    rm -f "$CLEAN_MARKER_FILE"

    if [[ "$SKIP_CONFIRM" == "0" ]]; then
        read -p "This will delete the '$OPENWRT_DIR' directory. Continue? (y/n) " -n 1 -r; echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then echo "Operation cancelled."; return 1; fi
    else
        echo "(--force: Skipping confirmation prompt for cleanup.)"
    fi

    step_echo "Cloning OpenWrt source code (v24.10.2, shallow clone)..."
    git clone --branch "$OPENWRT_TAG" --depth 1 "$OPENWRT_REPO" "$OPENWRT_DIR"

    step_echo "Cloning MediaTek feeds INSIDE the OpenWrt directory (shallow clone)..."
    git clone --depth 1 "$MTK_REPO" "$OPENWRT_DIR/$FEED_PATH"

    echo "Cloning complete."
    touch "$CLEAN_MARKER_FILE"
}

prepare_tree() {
    if [[ ! -f "$CLEAN_MARKER_FILE" ]]; then
        echo -e "${RED}ERROR: You must run Step 1 (Clean Up & Clone) before Step 2 for a safe build!"
        echo "       This prevents tree corruption and patch errors."
        echo "       Please select option 1 in the menu and try again."
        return 1
    fi

    rm -f "$CLEAN_MARKER_FILE"

    step_echo "Step 2: Preparing the Build Tree (feeds, firmware, EEPROM)"
    if [ ! -d "$OPENWRT_DIR" ]; then echo -e "${RED}Error: '$OPENWRT_DIR' not found. Run Step 1.${NC}"; return 1; fi
    cd "$OPENWRT_DIR"

    step_echo "[2.A] Cleaning duplicate MediaTek feed references"
    register_feed "$FEED_NAME"

    step_echo "[2.B] Updating and Installing ALL feeds"
    ./scripts/feeds update -a
    ./scripts/feeds install -a
    echo "All feeds successfully installed."

    step_echo "[2.C] Ensuring required patch target directories exist"
    ensure_patch_directories

    step_echo "[2.D] Injecting BE14 EEPROM calibration file only"
    inject_custom_be14_eeprom

    step_echo "[2.E] Removing incompatible cryptsetup host-build patch (if present)"
    local CRYPT_PATCH="$OPENWRT_DIR/$FEED_PATH/autobuild/unified/filogic/24.10/patches-feeds/cryptsetup-01-add-host-build.patch"
    if [[ -f "$CRYPT_PATCH" ]]; then
        echo "Deleting incompatible cryptsetup host-build patch!"
        rm -v "$CRYPT_PATCH"
    fi

    step_echo "[2.F] Running the MediaTek 'prepare' stage"
    if ! bash "$FEED_PATH/autobuild/unified/autobuild.sh" "$PROFILE" prepare; then
        echo -e "${RED}ERROR: The MediaTek 'prepare' stage failed.${NC}"; return 1;
    fi

    step_echo "[2.G] Check for patch rejects"
    check_for_patch_rejects "$OPENWRT_DIR"

    cd "$SCRIPT_DIR"
    echo "Tree preparation and patching completed successfully."
}

apply_config_and_build() {
    step_echo "Step 3: Applying Final Configuration and Building"
    if [ ! -d "$OPENWRT_DIR" ]; then echo -e "${RED}Error: Tree not prepared. Run Step 2.${NC}"; return 1; fi
    cd "$OPENWRT_DIR"

    step_echo "Applying custom files from BPI-R4-BUILD (my_files and configs)..."
    if [ ! -d "$BUILDER_FILES_SRC/my_files" ] || [ ! -d "$BUILDER_FILES_SRC/configs" ]; then
        echo -e "${RED}Error: Builder subfolders missing at '$BUILDER_FILES_SRC/my_files' or configs.${NC}"; return 1; fi
    safe_rsync "$BUILDER_FILES_SRC/my_files/" "./my_files/"
    safe_rsync "$BUILDER_FILES_SRC/configs/" "./configs/"

    step_echo "Applying your custom 'files' overlay..."
    safe_rsync "$DEVICE_FILES_SRC/" "./files/"

    step_echo "Applying .config file from $LEXY_CONFIG_SRC"
    cp -v "$LEXY_CONFIG_SRC" ./.config

    step_echo "Patching .config for full BE14/RM520NGL-AP router feature set..."
    patch_config_for_main_be14_router

    make defconfig

    step_echo "Checking available disk space before building..."
    check_space

    # --- Begin Build ---
    step_echo "Starting final build (make V=sc -j$(nproc)). Build log is saved to:"
    echo "    $LOG_FILE"
    echo

    if ! make V=sc -j"$(nproc)"; then
        echo -e "${RED}##################################################"
        echo "### ERROR: Build failed!                       ###"
        echo "### Check the full build log at: $LOG_FILE     ###"
        echo "##################################################${NC}"
        exit 99
    fi

    cd "$SCRIPT_DIR"
    echo -e "\n\n${NC}##################################################"
    echo "### Build process completed successfully!      ###"
    echo "### Find images in '$OPENWRT_DIR/bin/'.        ###"
    echo "### See log: $LOG_FILE"
    echo "##################################################"
}

openwrt_shell() {
    if [ ! -d "$OPENWRT_DIR" ]; then
        echo -e "${RED}OpenWrt directory ($OPENWRT_DIR) not found. Run Step 1.${NC}"
        return 1
    fi
    echo "Dropping you into a shell in $OPENWRT_DIR. Type 'exit' to return."
    cd "$OPENWRT_DIR"
    bash
    cd "$SCRIPT_DIR"
}

show_menu() {
    echo ""
    step_echo "BPI-R4 Build Menu (fully portable)"
    echo "a) Run All Steps (Will start FRESH, deletes previous sources)"
    echo "------------------------ THE PROCESS -----------------------"
    echo "1) Clean Up & Clone Repos (Deletes '$OPENWRT_DIR')"
    echo "2) Prepare Tree (Feeds, Inject Firmware/EEPROM, patches, etc.)"
    echo "3) Apply Final Config & Run Build (make)"
    echo "------------------------ UTILITIES -------------------------"
    echo "s) Enter OpenWrt Directory Shell (debug/inspection)"
    echo "q) Quit"
    echo ""
}

check_requirements

while true; do
    trap '' ERR; set +e
    show_menu
    read -p "Please select an option: " choice
    trap on_error ERR; set -e
    case $choice in
        a|A) clean_and_clone && prepare_tree && apply_config_and_build ;;
        1) clean_and_clone ;;
        2) prepare_tree ;;
        3) apply_config_and_build ;;
        s|S) openwrt_shell ;;
        q|Q) echo "Exiting script. Log is at $LOG_FILE"; exit 0 ;;
        *) echo -e "${RED}Invalid option. Please try again.${NC}";;
    esac
done
