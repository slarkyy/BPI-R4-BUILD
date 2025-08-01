#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
#  BPI-R4 / Mediatek OpenWrt Builder Script (Outlier enhanced, v2.3)
# ===========================================================================
#  IMPROVEMENTS IN THIS VERSION:
#  - Script now intelligently searches for control files (mm_config, EEPROM)
#    in EITHER 'contents/' or 'patches_overlay/', giving the user flexibility.
#  - rsync is now smart enough to exclude these control files from the overlay.
# ===========================================================================

RED='\033[0;31m'
NC='\033[0m'
GREEN='\033[0;32m'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPO_ROOT="$SCRIPT_DIR"
LOGS_DIR="$REPO_ROOT/logs"
CONTENTS_DIR="$REPO_ROOT/contents"
OVERLAY_DIR="$REPO_ROOT/patches_overlay"
OPENWRT_DIR="$REPO_ROOT/OpenWRT_BPI_R4"
PROFILE_DEFAULT="filogic-mac80211-mt7988_rfb-mt7996"
DEST_EEPROM_NAME="mt7996_eeprom_233_2i5i6i.bin"
MIN_DISK_GB=12
CLEAN_MARKER_FILE="$REPO_ROOT/.openwrt_cloned_this_session"

# --- Git and Feed Configuration ---
OPENWRT_REPO="https://git.openwrt.org/openwrt/openwrt.git"
OPENWRT_BRANCH="openwrt-24.10"
OPENWRT_COMMIT="4a18bb1056c78e1224ae3444f5862f6265f9d91c"
FEED_PATH="mtk-openwrt-feeds"
MTK_REPO="https://git01.mediatek.com/openwrt/feeds/mtk-openwrt-feeds"
MTK_BRANCH="master"
MTK_COMMIT="05615a80ed680b93c3c8337c209d42a2e00db99b"
MTK_FEED_REV="05615a8"

# --- Script State Variables ---
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
MM_CONFIG_PATH=""
EEPROM_PATH=""

cleanup() { tput cnorm || true; }
trap cleanup EXIT

# --- Helper Functions ---
require_folder() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        echo -e "${RED}ERROR: Required directory not found: $dir${NC}"
        exit 1
    fi
}
protect_dir_safety() {
    local tgt="$1"
    if [[ "$tgt" == "/" || "$tgt" =~ ^/root/?$ || "$tgt" =~ ^/home/?$ || -z "$tgt" ]]; then
        echo -e "${RED}Refusing to delete critical system directory: $tgt${NC}"; exit 99; fi
}
nuke_dir_forcefully() {
    local tgt="$1"
    protect_dir_safety "$tgt"
    if [[ -e "$tgt" ]]; then
        echo "Removing existing directory (or symlink) '$tgt'..."
        rm -rf --one-file-system "$tgt"
        if [[ -e "$tgt" ]]; then echo -e "${RED}ERROR: Failed to remove $tgt.${NC}"; exit 98; fi
    fi
}

if [[ "${EUID:-$(id -u)}" -eq 0 && "$ALLOW_ROOT" -eq 0 ]]; then
    echo -e "${RED}Refusing to run as root! Use --allow-root only if you understand the risks.${NC}" >&2; exit 100; fi

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
    echo "Review the build log for diagnostics: $LOG_FILE"
    exit "$exit_code"
}
trap on_error ERR INT

step_echo() {
    echo -e "${GREEN}=================================================================${NC}"
    echo -e "${GREEN}=> $1${NC}"
    echo -e "${GREEN}=================================================================${NC}"
}

# --- Pre-flight Checks ---
check_required_tools() {
    echo "Checking for required tools..."
    local missing=()
    for bin in git make rsync python3 tee wget; do
        if ! command -v "$bin" &>/dev/null; then missing+=("$bin"); fi
    done
    if [[ ${#missing[@]} -ne 0 ]]; then echo -e "${RED}Error: Missing commands: ${missing[*]}${NC}" >&2; exit 2; fi
}

check_internet() {
    echo "Checking Internet connectivity..."
    if ! wget -q --spider https://openwrt.org; then echo -e "${RED}ERROR: Internet connection not available!${NC}" >&2; exit 3; fi
}

install_dependencies() {
    echo "Checking dependencies (Debian/Ubuntu only)..."
    if [[ ! -f "/etc/debian_version" ]]; then
        echo -e "${RED}WARN: Auto-dependency install only for Debian/Ubuntu. Please ensure requirements are met manually.${NC}"; return; fi
    packages=(build-essential clang flex bison g++ gawk gcc-multilib g++-multilib gettext git libncurses-dev libssl-dev python3-setuptools rsync swig unzip zlib1g-dev file wget)
    local missing_packages=()
    for package in "${packages[@]}"; do
        if ! dpkg -s "$package" &> /dev/null; then missing_packages+=("$package"); fi
    done
    if [[ ${#missing_packages[@]} -ne 0 ]]; then
        echo "Missing packages to be installed: ${missing_packages[*]}"
        if [[ "$SKIP_CONFIRM" -eq 0 ]]; then
            read -p "Install missing packages with sudo? (y/n) " -n 1 -r ; echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then echo "User cancelled." ; exit 20; fi
        fi
        sudo apt-get update && sudo apt-get install -y "${missing_packages[@]}"
    else
        echo "All required dependencies are installed."
    fi
}

check_requirements() {
    step_echo "Verifying required files and directories..."
    require_folder "$OVERLAY_DIR"

    # Find mm_config in preferred locations
    if [[ -f "$CONTENTS_DIR/mm_config" ]]; then
        MM_CONFIG_PATH="$CONTENTS_DIR/mm_config"
        echo "Found build config at: $MM_CONFIG_PATH"
    elif [[ -f "$OVERLAY_DIR/mm_config" ]]; then
        MM_CONFIG_PATH="$OVERLAY_DIR/mm_config"
        echo "Found build config at: $MM_CONFIG_PATH"
    else
        echo -e "${RED}ERROR: Build config 'mm_config' not found in '$CONTENTS_DIR/' or '$OVERLAY_DIR/'.${NC}"; exit 4;
    fi

    # Find EEPROM .bin file in preferred locations
    local eeprom_files_contents=($(find "$CONTENTS_DIR" -maxdepth 1 -type f -iname '*.bin'))
    local eeprom_files_overlay=($(find "$OVERLAY_DIR" -maxdepth 1 -type f -iname '*.bin'))
    if [[ ${#eeprom_files_contents[@]} -gt 0 ]]; then
        EEPROM_PATH="${eeprom_files_contents[0]}"
        echo "Found EEPROM file at: $EEPROM_PATH"
    elif [[ ${#eeprom_files_overlay[@]} -gt 0 ]]; then
        EEPROM_PATH="${eeprom_files_overlay[0]}"
        echo "Found EEPROM file at: $EEPROM_PATH"
    else
        echo -e "${RED}ERROR: EEPROM '*.bin' file not found in '$CONTENTS_DIR/' or '$OVERLAY_DIR/'.${NC}"; exit 4;
    fi
}

check_space() {
    local avail_gb=$(( $(df --output=avail "$REPO_ROOT" | tail -1) / 1024 / 1024 ))
    if [[ "$avail_gb" -lt "$MIN_DISK_GB" ]]; then
        echo -e "${RED}ERROR: Less than ${MIN_DISK_GB}GB free disk space. (Available: ${avail_gb}GB)${NC}"; exit 5; fi
}

safe_rsync() {
    # INTELLIGENT RSYNC: Exclude control files so they are not copied into the source tree.
    # The script will handle them separately.
    local SRC="$1/" DST="$2/"
    if ! rsync -a --delete --info=progress2 --exclude='mm_config' --exclude='*.bin' "$SRC" "$DST"; then
        echo -e "${RED}rsync failed copying $SRC to $DST.${NC}"; exit 6; fi
}

validate_profile() {
    local profile_dir_name
    if [[ "$PROFILE" =~ mt798[68]_.+ ]]; then
        profile_dir_name=$(echo "$PROFILE" | grep -o 'mt798[68]_[^-_]*')
    else
        profile_dir_name="$PROFILE"
    fi
    if [[ ! -d "$OPENWRT_DIR/$FEED_PATH/autobuild/unified/filogic/mac80211/$profile_dir_name" ]]; then
        echo -e "${RED}ERROR: Profile directory for '$PROFILE' ('$profile_dir_name') not valid.${NC}"; exit 21; fi
    echo "Profile '$PROFILE' validated. Using directory: $profile_dir_name"
}

# --- Core Build Logic ---
clean_and_clone() {
    step_echo "Step 1: Nuke OpenWrt directory, then clone fresh"
    if [[ "$SKIP_CONFIRM" -eq 0 ]]; then
        echo -e "${RED}WARNING: This will DELETE the directory: $OPENWRT_DIR${NC}"
        read -p "Continue? (y/n) " -n 1 -r ; echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then echo "Operation cancelled."; return 1; fi
    fi
    nuke_dir_forcefully "$OPENWRT_DIR" && rm -f "$CLEAN_MARKER_FILE"
    step_echo "Cloning OpenWrt source..."
    GIT_TERMINAL_PROMPT=0 git clone --progress --branch "$OPENWRT_BRANCH" "$OPENWRT_REPO" "$OPENWRT_DIR"
    (cd "$OPENWRT_DIR" && git checkout "$OPENWRT_COMMIT")
    step_echo "Cloning MediaTek feeds..."
    local mtkfeeds="$OPENWRT_DIR/$FEED_PATH"
    GIT_TERMINAL_PROMPT=0 git clone --progress --branch "$MTK_BRANCH" "$MTK_REPO" "$mtkfeeds"
    (cd "$mtkfeeds" && git checkout "$MTK_COMMIT" && echo "${MTK_FEED_REV}" > autobuild/unified/feed_revision)
    if [[ ! -f "$mtkfeeds/autobuild/unified/autobuild.sh" ]]; then echo -e "${RED}ERROR: MediaTek autobuild script not found!${NC}"; exit 99; fi
    touch "$CLEAN_MARKER_FILE"
}

apply_overlays_and_patches() {
    step_echo "[2.B] Applying all custom patches and files from overlay directory"
    require_folder "$OVERLAY_DIR"
    safe_rsync "$OVERLAY_DIR" "$OPENWRT_DIR"
    step_echo "[2.C] Applying dynamic modifications and cleanups"
    echo "Removing known incompatible files..."
    rm -f "$OPENWRT_DIR/$FEED_PATH/24.10/patches-feeds/108-strongswan-add-uci-support.patch"
    rm -f "$OPENWRT_DIR/$FEED_PATH/autobuild/unified/filogic/24.10/patches-feeds/cryptsetup-01-add-host-build.patch"
    echo "Disabling perf package..."
    sed -i 's/CONFIG_PACKAGE_perf=y/# CONFIG_PACKAGE_perf is not set/' "$OPENWRT_DIR/$FEED_PATH/autobuild/unified/filogic/mac80211/24.10/defconfig" || true
    step_echo "[2.D] Injecting custom EEPROM"
    local eeprom_dst="$OPENWRT_DIR/files/lib/firmware/mediatek/mt7996/$DEST_EEPROM_NAME"
    mkdir -p "$(dirname "$eeprom_dst")"
    cp -af "$EEPROM_PATH" "$eeprom_dst"
    echo "Copied EEPROM to $eeprom_dst"
}

prepare_tree() {
    if [[ ! -d "$OPENWRT_DIR" ]]; then echo -e "${RED}ERROR: OpenWrt source missing. Run Step 1.${NC}"; return 1; fi
    if [[ -f "$CLEAN_MARKER_FILE" ]]; then rm -f "$CLEAN_MARKER_FILE"; else
        echo -e "${GREEN}Note:${NC} '$OPENWRT_DIR' exists. Continuing without re-cloning."
    fi
    step_echo "Step 2: Preparing the Build Tree"
    pushd "$OPENWRT_DIR" >/dev/null
    step_echo "[2.A] Updating and Installing ALL feeds"
    ./scripts/feeds update -a && ./scripts/feeds install -a
    apply_overlays_and_patches
    step_echo "[2.E] Applying build config"
    cp -v "$MM_CONFIG_PATH" ./.config
    local EXTRA_PACKAGES=${EXTRA_PACKAGES:-"luci-app-commands luci-app-advanced-reboot"}
    echo "Adding extra packages to .config: $EXTRA_PACKAGES"
    for pkg in $EXTRA_PACKAGES; do
        grep -q "^CONFIG_PACKAGE_${pkg}=y" .config || echo "CONFIG_PACKAGE_${pkg}=y" >> .config
    done
    step_echo "[2.F] Running the MediaTek 'prepare' stage"
    bash "$FEED_PATH/autobuild/unified/autobuild.sh" "$PROFILE" prepare
    validate_profile
    step_echo "[2.G] Check for patch rejects"
    if find . -name '*.rej' | read -r; then
        echo -e "${RED}== BUILD HALTED: PATCH REJECTS DETECTED! ==${NC}"
        find . -name '*.rej'
        exit 77
    fi
    popd >/dev/null
    echo "Tree preparation completed successfully."
}

apply_config_and_build() {
    BUILD_START_TIME=$(date +%s)
    step_echo "Step 3: Building"
    if [ ! -d "$OPENWRT_DIR" ]; then echo -e "${RED}Error: Tree not prepared. Run Step 2.${NC}" && return 1; fi
    pushd "$OPENWRT_DIR" >/dev/null
    check_space
    step_echo "Starting final build process..."
    bash "$FEED_PATH/autobuild/unified/autobuild.sh" "$PROFILE" build log_file=make jobs="${PARALLEL_JOBS}" V=s
    local build_status=$?
    popd >/dev/null
    if [[ $build_status -ne 0 ]]; then echo -e "${RED}ERROR: Build failed with exit code $build_status.${NC}"; exit $build_status; fi
    echo -e "\n\n${NC}##################################################"
    echo "### Build process completed! ###"
    echo "### Find images in '$OPENWRT_DIR/bin/'. ###"
    echo "##################################################"
    if [[ -d "$OPENWRT_DIR/bin" ]]; then
        echo -e "${GREEN}SHA256 of build images:${NC}"
        find "$OPENWRT_DIR/bin" -type f -exec sha256sum {} +
    fi
    local END_BUILD_TIME; END_BUILD_TIME=$(date +%s)
    echo "Build phase duration: $((END_BUILD_TIME - BUILD_START_TIME)) seconds"
}

# --- Utility Functions ---
run_menuconfig() {
    if [[ ! -f "$OPENWRT_DIR/.config" ]]; then echo -e "${RED}Error: .config not found. Run Step 2 first.${NC}" && return 1; fi
    pushd "$OPENWRT_DIR" >/dev/null
    make menuconfig
    read -p "Save updated .config back to '$MM_CONFIG_PATH'? (y/n) " -n 1 -r ; echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then cp -v ./.config "$MM_CONFIG_PATH" && echo "Config saved."; fi
    popd >/dev/null
}
clean_build_artifacts() {
    if [[ ! -d "$OPENWRT_DIR" ]]; then echo -e "${RED}OpenWrt directory not found.${NC}" && return 1; fi
    pushd "$OPENWRT_DIR" >/dev/null
    echo "Cleaning build artifacts (make clean)..."
    make clean
    popd >/dev/null
}
openwrt_shell() {
    if [[ ! -d "$OPENWRT_DIR" ]]; then echo -e "${RED}OpenWrt directory not found. Run Step 1.${NC}" && return 1; fi
    echo "Dropping you into a shell in $OPENWRT_DIR. Type 'exit' to return."
    (cd "$OPENWRT_DIR" && bash)
}
show_menu() {
    echo ""
    step_echo "BPI-R4 Build Menu"
    echo "a) Run All Steps (Clean, Prepare, Build)"
    echo "------------------------ THE PROCESS -----------------------"
    echo "1) Clean & Clone Repos (Deletes '$OPENWRT_DIR')"
    echo "2) Prepare Tree (Feeds, Overlay patches/files, config)"
    echo "3) Run Build (invokes MediaTek autobuild)"
    echo "------------------------ UTILITIES -------------------------"
    echo "c) Run 'menuconfig' (to customize included packages)"
    echo "d) Clean build artifacts (runs 'make clean')"
    echo "s) Enter OpenWrt Directory Shell (for manual debugging)"
    echo "q) Quit"
    echo ""
}

# --- Main Execution Logic ---

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) SKIP_CONFIRM=1; shift ;;
        --all|--batch|--no-menu) MENU_MODE=0; RUN_ALL=1; shift ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --allow-root) ALLOW_ROOT=1; shift ;;
        -h|--help)
cat <<EOF
Usage: ./bpi-r4-build-enhanced.sh [options]

General:
  --all, --batch, --no-menu : Fully automatic build (deletes all previous sources)
  --force                   : Skip confirmation prompts (dangerous: deletes OpenWrt dir)
  --allow-root              : Allow running the script as root (very dangerous)
  --profile name            : Use alternate OpenWrt build profile
  -h, --help                : Show this help/usage

Directory structure (two options):
  1. Separated (Recommended):
     ./contents/        -> For script assets (mm_config, EEPROM .bin)
     ./patches_overlay/ -> For all source and filesystem modifications

  2. Consolidated:
     ./patches_overlay/ -> Contains EVERYTHING (mm_config, .bin, files/, patches)

  The script will intelligently find the files in either setup.
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
        c|C) run_menuconfig ;;
        d|D) clean_build_artifacts ;;
        s|S) openwrt_shell ;;
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