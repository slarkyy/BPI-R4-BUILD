#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
#  BPI-R4 / Mediatek OpenWrt Builder Script (Outlier enhanced, v3)
# ===========================================================================

RED='\033[0;31m'
NC='\033[0m'
GREEN='\033[0;32m'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPO_ROOT="$SCRIPT_DIR"
LOGS_DIR="$REPO_ROOT/logs"
CONTENTS_DIR="$REPO_ROOT/contents"
OPENWRT_DIR="$REPO_ROOT/OpenWRT_BPI_R4"
PROFILE_DEFAULT="mt7988_rfb"
LEXY_CONFIG_SRC="$CONTENTS_DIR/mm_config"
DEVICE_FILES_SRC="$CONTENTS_DIR/files"
BUILDER_FILES_SRC="$CONTENTS_DIR"
DEST_EEPROM_NAME="mt7996_eeprom_233_2i5i6i.bin"
MIN_DISK_GB=12
CLEAN_MARKER_FILE="$REPO_ROOT/.openwrt_cloned_this_session"

OPENWRT_REPO="https://git.openwrt.org/openwrt/openwrt.git"
OPENWRT_BRANCH="openwrt-24.10"
OPENWRT_COMMIT="4a18bb1056c78e1224ae3444f5862f6265f9d91c"
FEED_NAME="mtk_openwrt_feed"
FEED_PATH="mtk-openwrt-feeds"
MTK_REPO="https://git01.mediatek.com/openwrt/feeds/mtk-openwrt-feeds"
MTK_BRANCH="master"
MTK_COMMIT="05615a80ed680b93c3c8337c209d42a2e00db99b"
MTK_FEED_REV="05615a8"

PARALLEL_JOBS="${PARALLEL_JOBS:-$(nproc)}"
SKIP_CONFIRM=0
MENU_MODE=1
RUN_ALL=0
PROFILE="$PROFILE_DEFAULT"
ALLOW_ROOT=0
warn_at_script_end=()
DATE_TAG=$(date +"%Y-%m-%d_%H-%M-%S")
START_SCRIPT_TIME=$(date +%s)
BUILD_START_TIME=0

PER_STEP_TIMING=0   # set to 1 to track per-step durations

cleanup() { tput cnorm || true; }
trap cleanup EXIT

require_folder() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        echo -e "${RED}ERROR: Required directory not found: $dir${NC}"
        exit 1
    fi
}
require_file() {
    local f="$1"
    if [[ ! -f "$f" ]]; then
        echo -e "${RED}ERROR: Required file not found: $f${NC}"
        exit 1
    fi
}
protect_dir_safety() {
    local tgt="$1"
    if [[ "$tgt" == "/" || "$tgt" =~ ^/root/?$ || "$tgt" =~ ^/home/?$ || -z "$tgt" ]]; then
        echo -e "${RED}Refusing to delete critical system directory: $tgt${NC}"
        exit 99
    fi
}
nuke_dir_forcefully() {
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

if [[ "${EUID:-$(id -u)}" -eq 0 && "$ALLOW_ROOT" -eq 0 ]]; then
    echo -e "${RED}Refusing to run as root! Use --allow-root only if you understand the risks.${NC}" >&2
    exit 100
fi

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
    if [[ -f "$LOG_FILE" ]]; then echo "   $LOG_FILE"; fi
    exit "$exit_code"
}
trap on_error ERR INT

step_echo() {
    echo -e "${GREEN}=================================================================${NC}"
    echo -e "${GREEN}=> $1${NC}"
    echo -e "${GREEN}=================================================================${NC}"
}

log_progress() { echo "Progress: Step $1 of $2"; }

step_timer_start=0
step_time_print() {
    if [[ "$PER_STEP_TIMING" -eq 1 && "$step_timer_start" -gt 0 ]]; then
        local now; now=$(date +%s)
        echo -e "${GREEN}Step duration: $((now-step_timer_start)) seconds${NC}"
    fi
    step_timer_start=$(date +%s)
}

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
        echo -e "${RED}ERROR: Internet connection not available!${NC}" >&2
        exit 3
    fi
}

install_dependencies() {
    echo "Checking dependencies (Debian/Ubuntu only)..."
    if [[ ! -f "/etc/debian_version" ]]; then
        echo -e "${RED}WARN: Dependency install only works for Debian/Ubuntu. Please ensure build requirements are met manually!${NC}"
        warn_at_script_end+=("\n* You may need to install OpenWrt build dependencies manually on your platform!")
        return
    fi
    packages=(
        build-essential clang flex bison g++ gawk gcc-multilib g++-multilib
        gettext git libncurses-dev libssl-dev python3-setuptools rsync swig
        unzip zlib1g-dev file wget
    )
    local missing_packages=()
    for package in "${packages[@]}"; do
        if ! dpkg -s "$package" &> /dev/null; then
            missing_packages+=("$package")
        fi
    done
    if [[ ${#missing_packages[@]} -ne 0 ]]; then
        echo "The following packages are missing and will be installed: ${missing_packages[*]}"
        if [[ -z "${SKIP_CONFIRM+x}" || "$SKIP_CONFIRM" -eq 0 ]]; then
            read -p "Install missing packages with sudo? Continue? (y/n) " -n 1 -r ; echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "User cancelled dependency installation."
                exit 20
            fi
        fi
        sudo apt-get update
        sudo apt-get install -y "${missing_packages[@]}"
    else
        echo "All required dependencies are installed."
    fi
}

check_requirements() {
    require_folder "$BUILDER_FILES_SRC/my_files"
    require_folder "$BUILDER_FILES_SRC/configs"
    require_folder "$DEVICE_FILES_SRC"
    require_file "$LEXY_CONFIG_SRC"
    local EEPROM_BLOBS
    EEPROM_BLOBS=($(find "$CONTENTS_DIR" -maxdepth 1 -type f -iname '*.bin'))
    if [[ ${#EEPROM_BLOBS[@]} -eq 0 ]]; then
        echo -e "${RED}ERROR: No EEPROM *.bin found at $CONTENTS_DIR${NC}"
        exit 4
    fi
    if [[ ${#EEPROM_BLOBS[@]} -gt 1 ]]; then
        echo -e "${RED}Warning: Multiple EEPROM blobs found: ${EEPROM_BLOBS[*]}. Using '${EEPROM_BLOBS[0]}' by default.${NC}"
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
    if ! rsync -a --delete --info=progress2 "$SRC" "$DST"; then
        echo -e "${RED}rsync failed copying $SRC to $DST.${NC}"
        exit 6
    fi
}

validate_profile() {
    # Only run after $OPENWRT_DIR is present.
    # Check for the existence of the profile for autobuild
    if [[ ! -d "$OPENWRT_DIR/$FEED_PATH/autobuild/unified/filogic" ]]; then
        echo -e "${RED}ERROR: Unable to validate profile (directory structure missing)${NC}"
        return 1
    fi
    local valid_profiles
    valid_profiles=($(find "$OPENWRT_DIR/$FEED_PATH/autobuild/unified/filogic" -maxdepth 1 -type d -name "${PROFILE}*" -printf "%f\n"))
    if [[ "${#valid_profiles[@]}" -eq 0 ]]; then
        echo -e "${RED}ERROR: Profile '$PROFILE' does not appear to be valid.${NC}"
        echo "Check the available profiles in '$OPENWRT_DIR/$FEED_PATH/autobuild/unified/filogic/'"
        exit 21
    fi
    # else OK
}

apply_wireless_regdb_patches() {
    rm -rf "$OPENWRT_DIR/package/firmware/wireless-regdb/patches/"*.*
    rm -rf "$OPENWRT_DIR/$FEED_PATH/autobuild/unified/filogic/mac80211/24.10/files/package/firmware/wireless-regdb/patches/"*.*
    mkdir -p "$OPENWRT_DIR/$FEED_PATH/autobuild/unified/filogic/mac80211/24.10/files/package/firmware/wireless-regdb/patches/"
    \cp -r "$BUILDER_FILES_SRC/my_files/500-tx_power.patch" "$OPENWRT_DIR/$FEED_PATH/autobuild/unified/filogic/mac80211/24.10/files/package/firmware/wireless-regdb/patches/"
    \cp -r "$BUILDER_FILES_SRC/my_files/regdb.Makefile" "$OPENWRT_DIR/package/firmware/wireless-regdb/Makefile"
}
remove_strongswan_patch() {
    rm -rf "$OPENWRT_DIR/$FEED_PATH/24.10/patches-feeds/108-strongswan-add-uci-support.patch"
}
add_noise_fix_patch() {
    mkdir -p "$OPENWRT_DIR/package/network/utils/iwinfo/patches/"
    \cp -r "$BUILDER_FILES_SRC/my_files/200-v.kosikhin-libiwinfo-fix_noise_reading_for_radios.patch" "$OPENWRT_DIR/package/network/utils/iwinfo/patches/"
}
add_tx_power_patches() {
   mkdir -p "$OPENWRT_DIR/$FEED_PATH/autobuild/unified/filogic/mac80211/24.10/files/package/kernel/mt76/patches/"
   \cp -r "$BUILDER_FILES_SRC/my_files/99999_tx_power_check.patch" "$OPENWRT_DIR/$FEED_PATH/autobuild/unified/filogic/mac80211/24.10/files/package/kernel/mt76/patches/"
   \cp -r "$BUILDER_FILES_SRC/my_files/9997-use-tx_power-from-default-fw-if-EEPROM-contains-0s.patch" "$OPENWRT_DIR/$FEED_PATH/autobuild/unified/filogic/mac80211/24.10/files/package/kernel/mt76/patches/"
}
apply_additional_mtk_patches() {
    local f="$OPENWRT_DIR/$FEED_PATH"
    mkdir -p "$f/24.10/files/target/linux/mediatek/patches-6.6/"
    mkdir -p "$f/autobuild/unified/filogic/24.10/patches-feeds/"
    mkdir -p "$f/feed/kernel/crypto-eip/src/"
    mkdir -p "$f/24.10/patches-base/"
    mkdir -p "$f/autobuild/unified/filogic/24.10/files/scripts/make-squashfs-hashed.sh"
    mkdir -p "$f/24.10/files/target/linux/mediatek/files-6.6/arch/arm64/boot/dts/mediatek/"
    rm -rf "$f/autobuild/unified/filogic/24.10/files/target/linux/mediatek/files-6.6/drivers/net/ethernet/mediatek/mtk_eth_reset.c"
    rm -rf "$f/autobuild/unified/filogic/24.10/files/target/linux/mediatek/files-6.6/drivers/net/ethernet/mediatek/mtk_eth_reset.h"
    \cp -r "$BUILDER_FILES_SRC/my_files/mtk_eth_reset.c"  "$f/autobuild/unified/filogic/24.10/files/target/linux/mediatek/files-6.6/drivers/net/ethernet/mediatek/"
    \cp -r "$BUILDER_FILES_SRC/my_files/mtk_eth_reset.h"  "$f/autobuild/unified/filogic/24.10/files/target/linux/mediatek/files-6.6/drivers/net/ethernet/mediatek/"
    rm -rf "$f/autobuild/unified/filogic/24.10/patches-feeds/cryptsetup-01-add-host-build.patch"
    rm -rf "$f/autobuild/unified/filogic/24.10/patches-feeds/cryptsetup-03-enable-veritysetup.patch"
    \cp -r "$BUILDER_FILES_SRC/my_files/cryptsetup-01-add-host-build.patch"  "$f/autobuild/unified/filogic/24.10/patches-feeds/"
    \cp -r "$BUILDER_FILES_SRC/my_files/999-2702-crypto-avoid-rcu-stall.patch" "$f/24.10/files/target/linux/mediatek/patches-6.6/"
    rm -rf "$f/24.10/files/target/linux/mediatek/patches-6.6/999-cpufreq-02-mediatek-enable-using-efuse-cali-data-for-mt7988-cpu-volt.patch"
    \cp -r "$BUILDER_FILES_SRC/my_files/999-cpufreq-01-cpufreq-add-support-to-adjust-cpu-volt-by-efuse-cali.patch" "$f/24.10/files/target/linux/mediatek/patches-6.6/"
    \cp -r "$BUILDER_FILES_SRC/my_files/999-cpufreq-02-cpufreq-add-cpu-volt-correction-support-for-mt7988.patch" "$f/24.10/files/target/linux/mediatek/patches-6.6/"
    \cp -r "$BUILDER_FILES_SRC/my_files/999-cpufreq-03-mediatek-enable-using-efuse-cali-data-for-mt7988-cpu-volt.patch" "$f/24.10/files/target/linux/mediatek/patches-6.6/"
    \cp -r "$BUILDER_FILES_SRC/my_files/999-cpufreq-04-cpufreq-add-support-to-fix-voltage-cpu.patch" "$f/24.10/files/target/linux/mediatek/patches-6.6/"
    \cp -r "$BUILDER_FILES_SRC/my_files/999-cpufreq-05-cpufreq-mediatek-Add-support-for-MT7987.patch" "$f/24.10/files/target/linux/mediatek/patches-6.6/"
    \cp -r "$BUILDER_FILES_SRC/my_files/ddk-wrapper.c" "$f/feed/kernel/crypto-eip/src/"
    \cp -r "$BUILDER_FILES_SRC/my_files/mt7988a-rfb-4pcie.dtso" "$f/24.10/files/target/linux/mediatek/files-6.6/arch/arm64/boot/dts/mediatek/"
    \cp -r "$BUILDER_FILES_SRC/my_files/1120-image-mediatek-filogic-mt7988a-rfb-05-add-4pcie-overlays.patch" "$f/24.10/patches-base/"
    rm -rf "$f/feed/app/regs/src/regs.c"
    \cp -r "$BUILDER_FILES_SRC/my_files/regs.c" "$f/feed/app/regs/src/"
    rm -rf "$f/autobuild/unified/filogic/24.10/files/scripts/make-squashfs-hashed.sh"
    \cp -r "$BUILDER_FILES_SRC/my_files/make-squashfs-hashed.sh" "$f/autobuild/unified/filogic/24.10/files/scripts/"
}
disable_perf() {
    sed -i 's/CONFIG_PACKAGE_perf=y/# CONFIG_PACKAGE_perf is not set/' "$OPENWRT_DIR/$FEED_PATH/autobuild/unified/filogic/mac80211/24.10/defconfig" || true
    sed -i 's/CONFIG_PACKAGE_perf=y/# CONFIG_PACKAGE_perf is not set/' "$OPENWRT_DIR/$FEED_PATH/autobuild/autobuild_5.4_mac80211_release/mt7988_wifi7_mac80211_mlo/.config" || true
    sed -i 's/CONFIG_PACKAGE_perf=y/# CONFIG_PACKAGE_perf is not set/' "$OPENWRT_DIR/$FEED_PATH/autobuild/autobuild_5.4_mac80211_release/mt7986_mac80211/.config" || true
}
inject_custom_be14_eeprom() {
    local EEPROM_BLOBS
    EEPROM_BLOBS=($(find "$CONTENTS_DIR" -maxdepth 1 -type f -iname '*.bin'))
    local eeprom_src="${EEPROM_BLOBS[0]}"
    local eeprom_dst="$OPENWRT_DIR/files/lib/firmware/mediatek/$DEST_EEPROM_NAME"
    if [[ ! -f "$eeprom_src" ]]; then
        echo -e "${RED}ERROR: BE14 EEPROM .bin not found at $eeprom_src${NC}"
        exit 7
    fi
    mkdir -p "$(dirname "$eeprom_dst")"
    cp -af "$eeprom_src" "$eeprom_dst"
    echo "Copied EEPROM as $eeprom_dst"
}

clean_and_clone() {
    local total_steps=4 current_step=1
    log_progress "$current_step" "$total_steps"
    step_echo "Step 1: Nuke OpenWrt and MediaTek feeds directories, then clone fresh"
    step_time_print

    local openwrt="$OPENWRT_DIR"
    local mtkfeeds="$OPENWRT_DIR/$FEED_PATH"

    if [[ "$SKIP_CONFIRM" == "0" ]]; then
        echo -e "${RED}WARNING: This will DELETE the following directories (if they exist):${NC}"
        echo "   $openwrt"
        echo "   $mtkfeeds"
        read -p "Continue? (y/n) " -n 1 -r ; echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then echo "Operation cancelled."; return 1; fi
    else
        echo "(--force: Skipping confirmation prompt for cleanup.)"
    fi

    nuke_dir_forcefully "$openwrt"
    [[ -d "$mtkfeeds" ]] && nuke_dir_forcefully "$mtkfeeds"
    rm -f "$CLEAN_MARKER_FILE"

    ((current_step++)); log_progress "$current_step" "$total_steps"
    step_echo "Cloning OpenWrt source (branch ${OPENWRT_BRANCH}, commit ${OPENWRT_COMMIT})..."
    step_time_print
    GIT_TERMINAL_PROMPT=0 git clone --progress --branch "$OPENWRT_BRANCH" "$OPENWRT_REPO" "$openwrt"
    (
        cd "$openwrt"
        git checkout "$OPENWRT_COMMIT"
    )
    ((current_step++)); log_progress "$current_step" "$total_steps"

    step_echo "Cloning MediaTek feeds (branch ${MTK_BRANCH}, commit ${MTK_COMMIT})..."
    step_time_print
    GIT_TERMINAL_PROMPT=0 git clone --progress --branch "$MTK_BRANCH" "$MTK_REPO" "$mtkfeeds"
    (
        cd "$mtkfeeds"
        git checkout "$MTK_COMMIT"
        echo "${MTK_FEED_REV}" > autobuild/unified/feed_revision
    )
    if [[ ! -f "$mtkfeeds/autobuild/unified/autobuild.sh" ]]; then
        echo -e "${RED}ERROR: Did not find $mtkfeeds/autobuild/unified/autobuild.sh after cloning!${NC}"
        exit 99
    fi
    echo "Cloning complete."
    touch "$CLEAN_MARKER_FILE"
    ((current_step++)); log_progress "$current_step" "$total_steps"
}

prepare_tree() {
    local total_steps=9 current_step=1
    log_progress "$current_step" "$total_steps"
    if [[ ! -d "$OPENWRT_DIR" ]] || [[ ! -f "$OPENWRT_DIR/feeds.conf.default" ]] || [[ ! -f "$OPENWRT_DIR/Makefile" ]] || [[ ! -x "$OPENWRT_DIR/scripts/feeds" ]]; then
        echo -e "${RED}ERROR: OpenWrt source missing or broken at '$OPENWRT_DIR'. Please run Step 1 to clone.${NC}"
        return 1
    fi
    if [[ -f "$CLEAN_MARKER_FILE" ]]; then
        rm -f "$CLEAN_MARKER_FILE"
    else
        echo -e "${GREEN}Note:${NC} '$OPENWRT_DIR' exists and looks OK. Continuing Step 2 without re-cloning."
    fi
    step_echo "Step 2: Preparing the Build Tree (feeds, overlays, patches, config, EEPROM, etc)"
    step_time_print
    pushd "$OPENWRT_DIR" >/dev/null

    step_echo "[2.A] Cleaning duplicate MediaTek feed references"
    sed -i "/$FEED_NAME/d" feeds.conf.default
    ((current_step++)); log_progress "$current_step" "$total_steps"; step_time_print

    step_echo "[2.B] Updating and Installing ALL feeds"
    ./scripts/feeds update -a
    ./scripts/feeds install -a
    ((current_step++)); log_progress "$current_step" "$total_steps"; step_time_print

    step_echo "[2.C] Applying builder overlays from contents/my_files, configs and files"
    require_folder "$BUILDER_FILES_SRC/my_files"
    safe_rsync "$BUILDER_FILES_SRC/my_files/" "./my_files/"
    require_folder "$BUILDER_FILES_SRC/configs"
    safe_rsync "$BUILDER_FILES_SRC/configs/" "./configs/"
    require_folder "$DEVICE_FILES_SRC"
    safe_rsync "$DEVICE_FILES_SRC/" "./files/"
    ((current_step++)); log_progress "$current_step" "$total_steps"; step_time_print

    step_echo "[2.D] Injecting custom EEPROM"
    inject_custom_be14_eeprom
    ((current_step++)); log_progress "$current_step" "$total_steps"; step_time_print

    step_echo "[2.E] Applying .config file from $LEXY_CONFIG_SRC"
    cp -v "$LEXY_CONFIG_SRC" ./.config
    ((current_step++)); log_progress "$current_step" "$total_steps"; step_time_print

    step_echo "[2.F] Applying all custom/required patches and files..."
    apply_wireless_regdb_patches
    remove_strongswan_patch
    add_noise_fix_patch
    add_tx_power_patches
    apply_additional_mtk_patches
    disable_perf
    ((current_step++)); log_progress "$current_step" "$total_steps"; step_time_print

    step_echo "[2.G] Removing incompatible cryptsetup host-build patch (if present)"
    local CRYPT_PATCH="$FEED_PATH/autobuild/unified/filogic/24.10/patches-feeds/cryptsetup-01-add-host-build.patch"
    if [[ -f "$CRYPT_PATCH" ]]; then echo "Deleting incompatible cryptsetup host-build patch!"; rm -v "$CRYPT_PATCH"; fi
    ((current_step++)); log_progress "$current_step" "$total_steps"; step_time_print

    step_echo "[2.H] Running the MediaTek 'prepare' stage"
    bash "$FEED_PATH/autobuild/unified/autobuild.sh" "$PROFILE" prepare || { echo -e "${RED}ERROR: The MediaTek 'prepare' stage failed.${NC}"; popd >/dev/null || true; return 1; }
    ((current_step++)); log_progress "$current_step" "$total_steps"; step_time_print

    validate_profile

    step_echo "[2.I] Check for patch rejects"
    find . -name '*.rej' | while read -r rejfile; do
        echo -e "${RED}PATCH REJECT detected: $rejfile${NC}"
        cat "$rejfile"
        echo -e "${RED}== Build aborted due to patch rejects. Please resolve them above. ==${NC}"
        exit 77
    done

    popd >/dev/null || true
    echo "Tree preparation, patching, and config completed successfully."
    ((current_step++)); log_progress "$current_step" "$total_steps"; step_time_print
}

apply_config_and_build() {
    BUILD_START_TIME=$(date +%s)
    local total_steps=2 current_step=1
    log_progress "$current_step" "$total_steps"
    step_echo "Step 3: Building (no tree changes allowed in this phase)"
    step_time_print
    if [ ! -d "$OPENWRT_DIR" ]; then
        echo -e "${RED}Error: Tree not prepared. Run Step 2.${NC}" && return 1
    fi
    pushd "$OPENWRT_DIR" >/dev/null

    step_echo "Checking available disk space before building..."
    check_space
    ((current_step++)); log_progress "$current_step" "$total_steps"; step_time_print

    # FINAL BUILD CALL, TREE MUST BE UNTOUCHED!
    step_echo "Starting MediaTek Autobuild (log will be appended to $LOG_FILE)"
    bash mtk-openwrt-feeds/autobuild/unified/autobuild.sh "$PROFILE" log_file=make jobs="${PARALLEL_JOBS}" | tee -a "$LOG_FILE"

    popd >/dev/null || true

    echo -e "\n\n${NC}##################################################"
    echo "### Build process completed!                    ###"
    echo "### Find images in '$OPENWRT_DIR/bin/'.         ###"
    echo "### See log: $LOG_FILE"
    echo "##################################################"
    if [[ -d "$OPENWRT_DIR/bin" ]]; then
        echo -e "${GREEN}SHA256 of build images:${NC}"
        find "$OPENWRT_DIR/bin" -type f -exec sha256sum {} +
    fi
    ((current_step++)); log_progress "$current_step" "$total_steps"; step_time_print
    if [[ $BUILD_START_TIME -ne 0 ]]; then
        local END_BUILD_TIME
        END_BUILD_TIME=$(date +%s)
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
    popd >/dev/null || true
}

openwrt_menuconfig() {
    if [ ! -d "$OPENWRT_DIR" ]; then
        echo -e "${RED}OpenWrt directory ($OPENWRT_DIR) not found. Run Step 1.${NC}"
        return 1
    fi
    echo -e "${GREEN}Launching OpenWrt make menuconfig...${NC}"
    pushd "$OPENWRT_DIR" >/dev/null
    make menuconfig
    popd >/dev/null || true
}

show_menu() {
    echo ""
    step_echo "BPI-R4 Build Menu (overlays in contents/)"
    echo "a) Run All Steps (Will start FRESH, deletes previous sources)"
    echo "------------------------ THE PROCESS -----------------------"
    echo "1) Clean Up & Clone Repos (Deletes '$OPENWRT_DIR')"
    echo "2) Prepare Tree (Feeds, Inject Firmware/EEPROM, patches, config, etc.)"
    echo "3) Run Build (autobuild only)"
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
        --allow-root)
            ALLOW_ROOT=1; shift
            ;;
        -h|--help)
cat <<EOF
Usage: ./bpi-r4-build-enhanced.sh [options]

General:
  --all, --batch, --no-menu : Fully automatic build (deletes all previous sources)
  --force                   : Skip confirmation prompts (dangerous: deletes OpenWrt dir)
  --allow-root              : Allow running the script as root (dangerous)
  --profile name            : Use alternate OpenWrt build profile
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
    for line in "${warn_at_script_end[@]}"; do echo -e "$line"; done
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
