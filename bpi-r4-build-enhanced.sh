#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
#  BPI-R4 / Mediatek OpenWrt Builder Script (bpi-r4-build-enhanced.sh)
#  Maintainer: Luke Slark
#  SPDX-License-Identifier: MIT
#
#  Updated by Outlier Model Playground AI, 2024-06:
#    - Robust shell options, pushd/popd, cursor reset on EXIT, elapsed timings,
#      consistent quoting, OpenWrt openwrt-24.10 enforced, make menuconfig in menu.
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
OPENWRT_TAG_DEFAULT="openwrt-24.10"   # Enforce OpenWRT openwrt-24.10 branch
FEED_NAME="mtk_openwrt_feed"
FEED_PATH="mtk-openwrt-feeds"
MIN_DISK_GB=12
CLEAN_MARKER_FILE="$REPO_ROOT/.openwrt_cloned_this_session"

SKIP_CONFIRM=0
MENU_MODE=1
RUN_ALL=0
PROFILE="$PROFILECertainly! Here is your improved script with robust error handling, branch set to openwrt-24.10, pushd/popd, total elapsed time reporting, make menuconfig, and all previous suggestions included:

```bash
#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
#  BPI-R4 / Mediatek OpenWrt Builder Script (bpi-r4-build-enhanced.sh)
#  Maintainer: Luke Slark
#  SPDX-License-Identifier: MIT
#
#  Updated for openwrt-24.10 branch and shell robustness by Outlier AI
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
OPENWRT_TAG_DEFAULT="openwrt-24.10"  # <-- Branch enforced here
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

# Always reset cursor on exit/int/err
cleanup() { tput cnorm || true; }
trap cleanup EXIT

# --- Protect from system wipes ---
function protect_dir_safety() {
    local tgt="$1"
    if [[ "$tgt" == "/" || "$tgt" =~ ^/root/?$ || "$tgt" =~ ^/home/?$ || "$tgt" == "" ]]; then
        echo -e "${RED}Refusing to delete critical system directory: $tgt${NC}"
        exit 99
    fi
}

# --- Warn if running as root
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
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
    if [[ "$avail_g
