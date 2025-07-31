#!/usr/bin/env bash

# ===========================================================================
#  BPI-R4 / Mediatek OpenWrt Builder Script (bpi-r4-build-enhanced.sh)
#  Maintainer: Luke Slark
#  SPDX-License-Identifier: MIT
#
#  Features:
#  - Dependency check/installation (Debian/Ubuntu, other OSs: warns)
#  - CLI overrides: --profile, --openwrt-tag
#  - Interactive menu + batch/CI/no-menu mode
#  - Color-coded error output
#  - Pre-flight checks for networking, disk space, tooling, file structure
#  - Clean repo and patch management
#  - Logging with timestamped log files in ./logs/
#  - Post-build checksums for all output images
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
OPENWRT_REPO="https://git.openwrt.org/openwrt/openwrt.git"
OPENWRT_TAG_DEFAULT="v24.10.2"
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

### --- CLI OVERRIDES & HELP --- ###
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
  --openwrt-tag vX.Y        : Use specific OpenWrt version/tag
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

# --- Protect us from system wipes --- (do NOT delete /, /home, /root, etc)
function protect_dir_safety() {
    local tgt="$1"
    if [[ "$tgt" == "/" || "$tgt" =~ ^/root/?$ || "$tgt" =~ ^/home/?$ || "$tgt" == "" ]]; then
        echo -e "${RED}Refusing to delete critical system directory: $tgt${NC}"
        exit 99
    fi
}

# --- Warn if running as root
if [[ $EUID -eq 0 ]]; then
    echo -e "${RED}WARNING: Running as root is NOT recommended!${NC}"
    sleep 1
fi

### --- LOGGING --- ###
DATE_TAG=$(date +"%Y-%m-%d_%H-%M-%S")
mkdir -p "$LOGS_DIR"
LOG_FILE="$LOGS_DIR/build_log_${DATE_TAG}.txt"
exec > >(tee -a "$LOG_FILE") 2>&1

### --- EXIT HANDLER --- ###
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

### --- STEP ECHO / PROGRESS --- ###
step_echo() {
    echo "================================================================="
    echo "=> $1"
    echo "================================================================="
}
log_progress() { echo "Progress: Step $1 of $2"; }

### --- PREREQ, INTERNET, DEPS --- ###
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
        exit 1
    fi
}
check_internet() {
    echo "Checking Internet connectivity..."
    if ! wget -q --spider https://openwrt.org; then
        echo -e "${RED}ERROR: Internet connection not available!${NC}"
        exit 1
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
        exit 1
    fi
}
check_space() {
    local avail=$(df --output=avail "$REPO_ROOT" | tail -1)
    local avail_gb=$((avail/1024/1024))
    if [[ "$avail_gb" -lt "$MIN_DISK_GB" ]]; then
        echo -e "${RED}ERROR: Less than ${MIN_DISK_GB}GB free disk on $REPO_ROOT. (Available: ${avail_gb}GB)${NC}"
        exit 1
    fi
}

### --- UTILITY / OVERLAY / SAFETY --- ###
safe_rsync() {
    local SRC="$1" DST="$2"
    rsync -a --delete --info=progress2 "$SRC" "$DST" || {
        echo -e "${RED}rsync failed copying $SRC to $DST.${NC}"; exit 1; }
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
    [[ ! -f "$eeprom_src" ]] && { echo -e "${RED}ERROR: BE14 EEPROM .bin not found at $eeprom_src${NC}"; exit 1; }
    mkdir -p "$(dirname "$eeprom_dst")"
    cp -af "$eeprom_src" "$eeprom_dst"
    echo "Copied EEPROM as $eeprom_dst"
}
patch_config_for_main_be14_router() {
    local config_file="$OPENWRT_DIR/.config"
    [[ ! -f "$config_file" ]] && { echo -e "${RED}ERROR: Could not patch .config (file not found at $config_file)!${NC}"; exit 1; }
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

### --- BUILD STEPS --- ###
clean_and_clone() {
    local total_steps=4 current_step=1
    log_progress "$current_step" "$total_steps"
    step_echo "Step 1: Clean Up & Clone Repos into a Fresh Directory"
    protect_dir_safety "$OPENWRT_DIR"
    rm -rf "$OPENWRT_DIR"
    rm -f "$CLEAN_MARKER_FILE"
    if [[ "$SKIP_CONFIRM" == "0" ]]; then
        read -p "This will delete the '$OPENWRT_DIR' directory. Continue? (y/n) " -n 1 -r; echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then echo "Operation cancelled."; return 1; fi
    else
        echo "(--force: Skipping confirmation prompt for cleanup.)"
    fi
    step_echo "Cloning OpenWrt source code ($OPENWRT_TAG, shallow clone)..."
    GIT_TERMINAL_PROMPT=0 git clone --progress --branch "$OPENWRT_TAG" --depth 1 "$OPENWRT_REPO" "$OPENWRT_DIR"
    ((current_step++)); log_progress "$current_step" "$total_steps"
    step_echo "Cloning MediaTek feeds INSIDE the OpenWrt directory (shallow clone)..."
    GIT_TERMINAL_PROMPT=0 git clone --progress --depth 1 "$MTK_REPO" "$OPENWRT_DIR/$FEED_PATH"
    ((current_step++)); log_progress "$current_step" "$total_steps"
    echo "Cloning complete."
    touch "$CLEAN_MARKER_FILE"
    ((current_step++)); log_progress "$current_step" "$total_steps"
}
prepare_tree() {
    local total_steps=7 current_step=1
    log_progress "$current_step" "$total_steps"
    if [[ ! -f "$CLEAN_MARKER_FILE" ]]; then
        echo -e "${RED}ERROR: You must run Step 1 (Clean Up & Clone) before Step 2 for a safe build!${NC}"
        return 1
    fi
    rm -f "$CLEAN_MARKER_FILE"
    step_echo "Step 2: Preparing the Build Tree (feeds, firmware, EEPROM)"
    [ ! -d "$OPENWRT_DIR" ] && echo -e "${RED}Error: '$OPENWRT_DIR' not found. Run Step 1.${NC}" && return 1
    cd "$OPENWRT_DIR"
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
    step_echo "[2.D] Injecting BE14 EEPROM calibration file only"
    inject_custom_be14_eeprom
    ((current_step++)); log_progress "$current_step" "$total_steps"
    step_echo "[2.E] Removing incompatible cryptsetup host-build patch (if present)"
    local CRYPT_PATCH="$OPENWRT_DIR/$FEED_PATH/autobuild/unified/filogic/24.10/patches-feeds/cryptsetup-01-add-host-build.patch"
    [[ -f "$CRYPT_PATCH" ]] && { echo "Deleting incompatible cryptsetup host-build patch!"; rm -v "$CRYPT_PATCH"; }
    ((current_step++)); log_progress "$current_step" "$total_steps"
    step_echo "[2.F] Running the MediaTek 'prepare' stage"
    bash "$FEED_PATH/autobuild/unified/autobuild.sh" "$PROFILE" prepare || { echo -e "${RED}ERROR: The MediaTek 'prepare' stage failed.${NC}"; return 1; }
    ((current_step++)); log_progress "$current_step" "$total_steps"
    step_echo "[2.G] Check for patch rejects"
    check_for_patch_rejects "$OPENWRT_DIR"
    cd "$SCRIPT_DIR"
    echo "Tree preparation and patching completed successfully."
    ((current_step++)); log_progress "$current_step" "$total_steps"
}
apply_config_and_build() {
    local total_steps=6 current_step=1
    log_progress "$current_step" "$total_steps"
    step_echo "Step 3: Applying Final Configuration and Building"
    [ ! -d "$OPENWRT_DIR" ] && echo -e "${RED}Error: Tree not prepared. Run Step 2.${NC}" && return 1
    cd "$OPENWRT_DIR"
    step_echo "Applying builder overlays from contents/my_files and contents/configs..."
    [ ! -d "$BUILDER_FILES_SRC/my_files" ] || [ ! -d "$BUILDER_FILES_SRC/configs" ] && { echo -e "${RED}Error: Builder subfolders missing at '$BUILDER_FILES_SRC/my_files' or configs.${NC}"; return 1; }
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
    # --- Begin Build ---
    step_echo "Starting final build. Build log is saved to:"
    echo "    $LOG_FILE"
    echo
    make V=sc -j"${PARALLEL_JOBS:-$(nproc)}" 2>&1 | tee -a "$LOG_FILE"
    cd "$SCRIPT_DIR"
    echo -e "\n\n${NC}##################################################"
    echo "### Build process completed successfully!      ###"
    echo "### Find images in '$OPENWRT_DIR/bin/'.        ###"
    echo "### See log: $LOG_FILE"
    echo "##################################################"
    # Post-build: show checksums for new images
    if [[ -d "$OPENWRT_DIR/bin" ]]; then
        echo -e "${GREEN}SHA256 of build images:${NC}"
        find "$OPENWRT_DIR/bin" -type f -exec sha256sum {} +
    fi
    ((current_step++)); log_progress "$current_step" "$total_steps"
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
    step_echo "BPI-R4 Build Menu (overlays in contents/)"
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

### ===== MAIN ===== ###
check_required_tools
check_internet
install_dependencies
check_requirements

if [[ $RUN_ALL -eq 1 ]]; then
    clean_and_clone && prepare_tree && apply_config_and_build
    echo -e "${GREEN}Script completed successfully!${NC}"
    echo -e "${warn_at_script_end}"
    echo ""
    cat <<EOF
=======================
Build Complete!
=======================
* Built images are inside: $OPENWRT_DIR/bin/
* Full log: $LOG_FILE

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
    case $choice in
        a|A) clean_and_clone && prepare_tree && apply_config_and_build ;;
        1) clean_and_clone ;;
        2) prepare_tree ;;
        3) apply_config_and_build ;;
        s|S) openwrt_shell ;;
        q|Q) tput cnorm; echo "Exiting script. Log is at $LOG_FILE"; exit 0 ;;
        *) echo -e "${RED}Invalid option. Please try again.${NC}";;
    esac
done
