#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
#  BPI-R4 / Mediatek OpenWrt Builder Script (bpi-r4-build-enhanced.sh)
#  Maintainer: Luke Slark
#  SPDX-License-Identifier: MIT
# ===========================================================================

RED='\033[0;31m'
NC='\033[0m'
GREEN='\033[0;32m'

### --- DIR & ENV VARS --- ###
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPO_ROOT="$SCRIPT_DIR"
LOGS_DIR="$REPO_ROOT/logs"
CONTENTS_DIR="$REPO_ROOT/contents"
OPENWRT_DIR="$REPO_ROOT/OpenWRT_BPI_R4"
PROFILE_DEFAULT="filogic-mac80211-mt7988_rfb-mt7996"
LEXY_CONFIG_SRC="$CONTENTS_DIR/mm_config"
DEVICE_FILES_SRC="$CONTENTS_DIR/files"
BUILDER_FILES_SRC="$CONTENTS_DIR"
EEPROM_BLOB=$(find "$CONTENTS_DIR" -maxdepth 1 -type f -iname '*.bin' | head -n1)
DEST_EEPROM_NAME="mt7996_eeprom_233_2i5i6i.bin"
MTK_REPO="https://git01.mediatek.com/openwrt/feeds/mtk-openwrt-feeds"
MTK_FEEDS_COMMIT="9a5944b3c880a3d2622d360ca4a2e9aedbde2314"
OPENWRT_REPO="https://git.openwrt.org/openwrt/openwrt.git"
OPENWRT_TAG_DEFAULT="openwrt-24.10"
FEED_NAME="mtk_openwrt_feed"
FEED_PATH="mtk-openwrt-feeds"
MIN_DISK_GB=12
CLEAN_MARKER_FILE="$REPO_ROOT/.openwrt_cloned_this_session"

SKIP_CONFIRM=0
MENU_MODE=1
RUN_ALL=0
PROFILE="$PROFILE_DEFAULT"
OPENWRT_TAG="$OPENWRT_TAG_DEFAULT"
warn_at_script_end=""

START_SCRIPT_TIME=$(date +%s)
BUILD_START_TIME=0

cleanup() { tput cnorm || true; }
trap cleanup EXIT

function protect_dir_safety() {
    local tgt="$1"
    if [[ "$tgt" == "/" || "$tgt" =~ ^/root/?$ || "$tgt" =~ ^/home/?$ || "$tgt" == "" ]]; then
        echo -e "${RED}Refusing to delete critical system directory: $tgt${NC}"
        exit 99
    fi
}

function nuke_dir_forcefully() {
    local tgt="$1"
    protect_dir_safety "$tgt"
    if [[ -e "$tgt" ]]; then
        echo "Removing existing directory (or symlink) '$tgt'..."
        rm -rf --one-file-system "$tgt"
        if [[ -e "$tgt" ]]; then
            echo -e "${RED}ERROR: Failed to cleanly remove $tgt. Aborting!${NC}"
            exit 98
        fi
    fi
}

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo -e "${RED}WARNING: Running as root is NOT recommended!${NC}"
    sleep 1
fi

DATE_TAG=$(date +"%Y-%m-%d_%H-%M-%S")
mkdir -p "$LOGS_DIR"
LOG_FILE="$LOGS_DIR/build_log_${DATE_TAG}.txt"
exec > >(tee -a "$LOG_FILE") 2>&1

on_error() {
    local exit_code=$?
    tput cnorm || true
    echo -e "${RED}##########################################################${NC}"
    echo -e "${RED}#           >>>>> A CRITICAL ERROR OCCURRED <<<<<         #${NC}"
    echo -e "${RED}# Error on line $LINENO: Command '$BASH_COMMAND' exited with status $exit_code.${NC}"
    echo -e "${RED}##########################################################${NC}"
    echo "Review the build log for diagnostics:"
    [[ -f "$LOG_FILE" ]] && echo "   $LOG_FILE"
    exit $exit_code
}
trap on_error ERR INT

step_echo() {
    echo "================================================================="
    echo "=> $1"
    echo "================================================================="
}
log_progress() { echo "Progress: Step $1 of $2"; }

check_required_tools() {
    echo "Checking for required tools..."
    local missing=()
    for bin in git make rsync python3 tee wget; do
        if ! command -v "$bin" &>/dev/null; then
            missing+=("$bin")
        fi
    done
    if [[ ${#missing[@]} -ne 0 ]]; then
        echo -e "${RED}Error: Required commands missing: ${missing[*]}${NC}"
        echo "Please install these before running this script. Aborting."
        exit 2
    fi
}

check_internet() {
    echo "Checking Internet connectivity..."
    if ! wget -q --spider https://openwrt.org; then
        echo -e "${RED}ERROR: Internet connection not available!${NC}"
        exit 3
    fi
}

install_dependencies() {
    echo "Checking dependencies (Debian/Ubuntu only)..."
    if [[ ! -f "/etc/debian_version" ]]; then
        echo -e "${RED}WARN: Dependency install only works for Debian/Ubuntu. Please ensure build requirements are met manually!${NC}"
        warn_at_script_end+="\n* You may need to install OpenWrt build dependencies manually on your platform!"
        return
    fi
    packages=(
        build-essential clang flex bison g++ gawk gcc-multilib g++-multilib
        gettext git libncurses-dev libssl-dev python3-setuptools rsync swig
        unzip zlib1g-dev file wget libtraceevent-dev systemtap-sdt-dev libslang-dev
        pv bc libelf-dev libtool autoconf
        libc6-dev libmpc-dev libmpfr-dev libgmp-dev gawk
    )
    local missing_packages=()
    for package in "${packages[@]}"; do
        if ! dpkg -s "$package" &> /dev/null; then
            missing_packages+=("$package")
        fi
    done
    if [ ${#missing_packages[@]} -ne 0 ]; then
        echo "Installing missing dependencies: ${missing_packages[*]}"
        sudo apt-get update
        for pkg in "${missing_packages[@]}"; do
            sudo apt-get install -y "$pkg" || echo "WARNING: Skipping $pkg (not available)"
        done
    else
        echo "All required dependencies are installed."
    fi
}

check_requirements() {
    local err=0
    [[ ! -d "$BUILDER_FILES_SRC/my_files" ]] && { echo -e "${RED}ERROR: Expected builder my_files at $BUILDER_FILES_SRC/my_files${NC}"; err=1; }
    [[ ! -d "$BUILDER_FILES_SRC/configs" ]] && { echo -e "${RED}ERROR: Expected builder configs at $BUILDER_FILES_SRC/configs${NC}"; err=1; }
    [[ ! -d "$DEVICE_FILES_SRC" ]] && { echo -e "${RED}ERROR: Expected 'files' directory at $DEVICE_FILES_SRC${NC}"; err=1; }
    [[ ! -f "$LEXY_CONFIG_SRC" ]] && { echo -e "${RED}ERROR: Expected .config file at $LEXY_CONFIG_SRC${NC}"; err=1; }
    [[ -z "$EEPROM_BLOB" ]] && { echo -e "${RED}ERROR: No EEPROM *.bin found at $CONTENTS_DIR${NC}"; err=1; }
    if [[ "$err" != 0 ]]; then
        echo -e "${RED}One or more required files/folders missing!${NC}"
        exit 4
    fi
}

check_space() {
    local avail
    avail=$(df --output=avail "$REPO_ROOT" | tail -1)
    local avail_gb=$((avail/1024/1024))
    if [[ "$avail_gb" -lt "$MIN_DISK_GB" ]]; then
        echo -e "${RED}ERROR: Less than ${MIN_DISK_GB}GB free disk on $REPO_ROOT. (Available: ${avail_gb}GB)${NC}"
        exit 5
    fi
}

safe_rsync() {
    local SRC="$1"
    local DST="$2"
    rsync -a --delete --info=progress2 "$SRC" "$DST" || {
        echo -e "${RED}rsync failed copying $SRC to $DST.${NC}"; exit 6; }
}

register_feed() {
    local FEED_NAME="$1"
    sed -i "/$FEED_NAME/d" feeds.conf.default
    echo "Feed '$FEED_NAME' lines cleaned (addition deferred to MTK autobuilder)."
}

ensure_patch_directories() {
    local dir="$OPENWRT_DIR/package/boot/uboot-envtools/files"
    [[ ! -d "$dir" ]] && { mkdir -p "$dir"; echo "Created missing patch directory: $dir"; }
}

inject_custom_be14_eeprom() {
    local eeprom_src="$EEPROM_BLOB"
    local eeprom_dst="$OPENWRT_DIR/files/lib/firmware/mediatek/$DEST_EEPROM_NAME"
    [[ ! -f "$eeprom_src" ]] && { echo -e "${RED}ERROR: BE14 EEPROM .bin not found at $eeprom_src${NC}"; exit 7; }
    mkdir -p "$(dirname "$eeprom_dst")"
    cp -af "$eeprom_src" "$eeprom_dst"
    echo "Copied EEPROM as $eeprom_dst"
}

apply_yukariin_patch() {
    local PATCH_SRC="$CONTENTS_DIR/001-Add-tx_power-check-Yukariin.patch"
    local TARGET_DIR="$OPENWRT_DIR/package/kernel/mt76/patches/"
    if [[ ! -f "$PATCH_SRC" ]]; then
        echo -e "${RED}WARNING: Patch $PATCH_SRC not found, skipping Yukariin patch!${NC}"
        return 0
    fi
    if [[ ! -d "$TARGET_DIR" ]]; then
        echo "Creating missing patch directory: $TARGET_DIR"
        mkdir -p "$TARGET_DIR"
    fi
    local PATCH_DST="$TARGET_DIR/$(basename "$PATCH_SRC")"
    cp -af "$PATCH_SRC" "$PATCH_DST"
    echo "Yukariin patch copied to $PATCH_DST"
}

patch_config_for_main_be14_router() {
    local config_file="$OPENWRT_DIR/.config"
    [[ ! -f "$config_file" ]] && { echo -e "${RED}ERROR: Could not patch .config (file not found at $config_file)!${NC}"; exit 8; }
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
    while read -r line; do
        [[ -z "$line" ]] && continue
        grep -q -F "$line" "$config_file" || { echo "$line" >> "$config_file"; echo "  + Added: $line"; }
    done <<< "$WANTED_CONFIGS"
}

check_for_patch_rejects() {
    local build_dir="$1"
    local rejs
    rejs=$(find "$build_dir" -name '*.rej' 2>/dev/null)
    if [[ -n "$rejs" ]]; then
        echo -e "${RED}#########################################################${NC}"
        echo -e "${RED} PATCH REJECT(S) DETECTED!${NC}"
        echo "$rejs"
        for file in $rejs; do
            echo -e "${RED}---- $file ----${NC}"
            cat "$file"
            echo -e "${RED}---------------------------${NC}"
        done
        echo -e "${RED}=== Build aborted due to patch rejects. Please resolve them above. ===${NC}"
        exit 77
    fi
}

compare_configs_warn() {
    if [[ -f .config && -f .config.old ]]; then
        if ! diff -u .config.old .config > /dev/null; then
            echo -e "${RED}WARNING: .config changed after defconfig!${NC}"
            diff -u .config.old .config || true
            sleep 2
        fi
    fi
}

ensure_stdc_predef_in_toolchain() {
    local src="/usr/include/stdc-predef.h"
    if [[ ! -f "$src" ]]; then
        echo -e "${RED}Host missing: $src - cannot fix stdc-predef.h; aborting!${NC}"
        exit 21
    fi
    find "$OPENWRT_DIR/staging_dir" -type d -path '*/toolchain-*/include' 2>/dev/null | while read -r toolchain_inc_dir; do
        echo "Ensuring stdc-predef.h in $toolchain_inc_dir ..."
        cp -f "$src" "$toolchain_inc_dir/"
    done
}

clean_and_clone() {
    local total_steps=4 current_step=1
    log_progress "$current_step" "$total_steps"
    step_echo "Step 1: Clean Up & Clone Repos into a Fresh Directory"
    protect_dir_safety "$OPENWRT_DIR"
    if [[ "$SKIP_CONFIRM" == "0" ]]; then
        read -p "This will DELETE the '$OPENWRT_DIR' directory (if it exists). Continue? (y/n) " -n 1 -r ; echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then echo "Operation cancelled."; return 1; fi
    else
        echo "(--force: Skipping confirmation prompt for cleanup.)"
    fi
    nuke_dir_forcefully "$OPENWRT_DIR"
    rm -f "$CLEAN_MARKER_FILE"

    step_echo "Cloning OpenWrt source code ($OPENWRT_TAG, full clone)..."
    GIT_TERMINAL_PROMPT=0 git clone --progress --branch "$OPENWRT_TAG" "$OPENWRT_REPO" "$OPENWRT_DIR"
    ((current_step++)); log_progress "$current_step" "$total_steps"

    step_echo "Cloning MediaTek feeds at commit $MTK_FEEDS_COMMIT (full clone)..."
    if command -v script >/dev/null 2>&1; then
        GIT_TERMINAL_PROMPT=0 script -q -c "git clone --progress '$MTK_REPO' '$OPENWRT_DIR/$FEED_PATH'" /dev/null
    else
        echo "script utility not found, falling back to non-TTY git clone. If no progress is shown, install 'script' from util-linux for progress meter."
        GIT_TERMINAL_PROMPT=0 git clone --progress "$MTK_REPO" "$OPENWRT_DIR/$FEED_PATH"
    fi
    (
        cd "$OPENWRT_DIR/$FEED_PATH"
        git checkout "$MTK_FEEDS_COMMIT"
    )
    ((current_step++)); log_progress "$current_step" "$total_steps"
    echo "Cloning complete."
    touch "$CLEAN_MARKER_FILE"
    ((current_step++)); log_progress "$current_step" "$total_steps"
}

prepare_tree() {
    local total_steps=7 current_step=1
    log_progress "$current_step" "$total_steps"
    if [[ ! -d "$OPENWRT_DIR" ]] || [[ ! -f "$OPENWRT_DIR/feeds.conf.default" ]] || [[ ! -f "$OPENWRT_DIR/Makefile" ]] || [[ ! -x "$OPENWRT_DIR/scripts/feeds" ]]; then
        echo -e "${RED}ERROR: OpenWrt source missing or broken at '$OPENWRT_DIR'. Please run Step 1 to clone.&{NC}"
        return 1
    fi
    if [[ -f "$CLEAN_MARKER_FILE" ]]; then
        rm -f "$CLEAN_MARKER_FILE"
    else
        echo -e "${GREEN}Note:${NC} '$OPENWRT_DIR' exists and looks OK. Continuing Step 2 without re-cloning."
    fi
    step_echo "Step 2: Preparing the Build Tree (feeds, firmware, EEPROM)"
    pushd "$OPENWRT_DIR" >/dev/null
    step_echo "[2.A] Cleaning duplicate MediaTek feed references"
    register_feed "$FEED_NAME"
    ((current_step++)); log_progress "$current_step" "$total_steps"
    step_echo "[2.B] Updating and Installing ALL feeds"
    ./scripts/feeds update -a
    ./scripts/feeds install -a
    echo "All feeds successfully installed."
    ((current_step++)); log_progress "$current_step" "$total_steps"
    step_echo "[2.C] Ensuring required patch target directories exist"
    ensure_patch_directories
    ((current_step++)); log_progress "$current_step" "$total_steps"
    step_echo "[2.D] Skipped EEPROM/patch overlays (done pre-build)"
    ((current_step++)); log_progress "$current_step" "$total_steps"
    step_echo "[2.E] Removing incompatible cryptsetup host-build patch (if present)"
    local CRYPT_PATCH="$OPENWRT_DIR/$FEED_PATH/autobuild/unified/filogic/24.10/patches-feeds/cryptsetup-01-add-host-build.patch"
    [[ -f "$CRYPT_PATCH" ]] && { echo "Deleting incompatible cryptsetup host-build patch!"; rm -v "$CRYPT_PATCH"; }
    ((current_step++)); log_progress "$current_step" "$total_steps"
    step_echo "[2.F] Running the MediaTek 'prepare' stage"
    bash "$FEED_PATH/autobuild/unified/autobuild.sh" "$PROFILE" prepare || { echo -e "${RED}ERROR: The MediaTek 'prepare' stage failed.${NC}"; popd; return 1; }
    ((current_step++)); log_progress "$current_step" "$total_steps"
    step_echo "[2.G] Check for patch rejects"
    check_for_patch_rejects "$OPENWRT_DIR"
    popd >/dev/null
    echo "Tree preparation and patching completed successfully."
    ((current_step++)); log_progress "$current_step" "$total_steps"
}

apply_config_and_build() {
    BUILD_START_TIME=$(date +%s)
    local total_steps=6 current_step=1
    log_progress "$current_step" "$total_steps"
    step_echo "Step 3: Applying Final Configuration and Building"
    [ ! -d "$OPENWRT_DIR" ] && echo -e "${RED}Error: Tree not prepared. Run Step 2.${NC}" && return 1
    pushd "$OPENWRT_DIR" >/dev/null
    step_echo "Applying builder overlays from contents/my_files and contents/configs..."
    [ ! -d "$BUILDER_FILES_SRC/my_files" ] || [ ! -d "$BUILDER_FILES_SRC/configs" ] && { echo -e "${RED}Error: Builder subfolders missing at '$BUILDER_FILES_SRC/my_files' or configs.${NC}"; popd; return 1; }
    safe_rsync "$BUILDER_FILES_SRC/my_files/" "./my_files/"
    ((current_step++)); log_progress "$current_step" "$total_steps"
    safe_rsync "$BUILDER_FILES_SRC/configs/" "./configs/"
    step_echo "Applying your custom 'files' overlay from contents/files/..."
    safe_rsync "$DEVICE_FILES_SRC/" "./files/"
    ((current_step++)); log_progress "$current_step" "$total_steps"
    step_echo "Applying .config file from $LEXY_CONFIG_SRC"
    cp -v "$LEXY_CONFIG_SRC" ./.config
    cp -v .config .config.old
    ((current_step++)); log_progress "$current_step" "$total_steps"
    step_echo "Patching .config for full BE14/RM520NGL-AP router feature set..."
    patch_config_for_main_be14_router
    make defconfig
    compare_configs_warn
    step_echo "Checking available disk space before building..."
    check_space
    ((current_step++)); log_progress "$current_step" "$total_steps"

    # Must re-overlay custom blobs/patches, as feeds/autobuild/prep may have wiped them!
    ensure_stdc_predef_in_toolchain
    inject_custom_be14_eeprom
    apply_yukariin_patch

    # --- Begin Build ---
    step_echo "Starting final build. Build log is saved to:"
    echo "    $LOG_FILE"
    echo
    make V=sc -j"${PARALLEL_JOBS:-$(nproc)}" 2>&1 | tee -a "$LOG_FILE"
    popd >/dev/null
    echo -e "\n\n${NC}##################################################"
    echo "### Build process completed successfully!      ###"
    echo "### Find images in '$OPENWRT_DIR/bin/'.        ###"
    echo "### See log: $LOG_FILE"
    echo "##################################################"
    if [[ -d "$OPENWRT_DIR/bin" ]]; then
        echo -e "${GREEN}SHA256 of build images:${NC}"
        find "$OPENWRT_DIR/bin" -type f -exec sha256sum {} +
    fi
    ((current_step++)); log_progress "$current_step" "$total_steps"
    if [[ $BUILD_START_TIME -ne 0 ]]; then
        local END_BUILD_TIME=$(date +%s)
        echo "Build phase duration: $((END_BUILD_TIME - BUILD_START_TIME)) seconds"
    fi
}

openwrt_shell() {
    if [ ! -d "$OPENWRT_DIR" ]; then
        echo -e "${RED}OpenWrt directory ($OPENWRT_DIR) not found. Run Step 1.${NC}"
        return 1
    fi
    echo "Dropping you into a shell in $OPENWRT_DIR. Type 'exit' to return."
    pushd "$OPENWRT_DIR" >/dev/null
    bash
    popd >/dev/null
}

openwrt_menuconfig() {
    if [ ! -d "$OPENWRT_DIR" ]; then
        echo -e "${RED}OpenWrt directory ($OPENWRT_DIR) not found. Run Step 1.${NC}"
        return 1
    fi
    echo -e "${GREEN}Launching OpenWrt make menuconfig...${NC}"
    pushd "$OPENWRT_DIR" >/dev/null
    make menuconfig
    popd >/dev/null
}

show_menu() {
    echo ""
    step_echo "BPI-R4 Build Menu (overlays in contents/)"
    echo "a) Run All Steps (Will start FRESH, deletes previous sources)"
    echo "------------------------ THE PROCESS -----------------------"
    echo "1) Clean Up & Clone Repos (Deletes '$OPENWRT_DIR')"
    echo "2) Prepare Tree (Feeds, Inject Firmware/EEPROM, patches, etc.)"
    echo "3) Apply Final Config & Run Build (make)"
    echo "------------------------ UTILITIES -------------------------"
    echo "s) Enter OpenWrt Directory Shell (debug/inspection)"
    echo "m) OpenWrt make menuconfig"
    echo "q) Quit"
    echo ""
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) SKIP_CONFIRM=1 ;;
        --all|--batch|--no-menu) MENU_MODE=0; RUN_ALL=1 ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --openwrt-tag) OPENWRT_TAG="$2"; shift 2 ;;
        -h|--help)
cat <<EOF
Usage: ./bpi-r4-build-enhanced.sh [options]

General:
  --all, --batch, --no-menu : Fully automatic build (deletes all previous sources)
  --force                   : Skip confirmation prompts (dangerous: deletes OpenWrt dir)
  --profile name            : Use alternate OpenWrt build profile
  --openwrt-tag vX.Y        : Use specific OpenWrt version/tag (default: openwrt-24.10)
  --help                    : Show this help/usage

Directory structure:
  ./contents/   Overlays (my_files/, configs/, files/, mm_config, etc)
  ./logs/       Build and script logs
  ./OpenWRT_BPI_R4/bin/  Images built

EOF
        exit 0
        ;;
        *) shift ;;
    esac
done

check_required_tools
check_internet
install_dependencies
check_requirements

if [[ $RUN_ALL -eq 1 ]]; then
    clean_and_clone && prepare_tree && apply_config_and_build
    END_SCRIPT_TIME=$(date +%s)
    echo -e "${GREEN}Script completed successfully!${NC}"
    echo -e "${warn_at_script_end}"
    echo ""
    cat <<EOF
=======================
Build Complete!
=======================
* Built images are inside: $OPENWRT_DIR/bin/
* Full log: $LOG_FILE
* Total script time: $((END_SCRIPT_TIME - START_SCRIPT_TIME)) seconds

To flash your device, use the appropriate OpenWrt sysupgrade or recovery method.
Consult your device's documentation, and see https://openwrt.org/ for more info!
EOF
    exit 0
fi

while (( MENU_MODE )); do
    trap '' ERR; set +e
    show_menu
    read -p "Please select an option: " choice
    trap on_error ERR; set -e
    case "$choice" in
        a|A) clean_and_clone && prepare_tree && apply_config_and_build ;;
        1) clean_and_clone ;;
        2) prepare_tree ;;
        3) apply_config_and_build ;;
        s|S) openwrt_shell ;;
        m|M) openwrt_menuconfig ;;
        q|Q)
            tput cnorm
            END_SCRIPT_TIME=$(date +%s)
            echo "Exiting script. Log is at $LOG_FILE. Total time: $((END_SCRIPT_TIME - START_SCRIPT_TIME)) seconds"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option. Please try again.${NC}"
            ;;
    esac
done
