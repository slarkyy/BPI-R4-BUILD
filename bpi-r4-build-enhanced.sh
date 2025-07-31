#!/bin/bash

set -euo pipefail

GREEN='\033[1;32m'
NC='\033[0m'

# --- Global progress vars
TOTAL_STEPS=53    # 3 main steps + build (50 build ticks)
CURRENT_STEP=0

# --- Install Dependencies ---
install_dependencies() {
  echo "Checking and installing dependencies..."
  packages=(
    build-essential clang flex bison g++ gawk gcc-multilib g++-multilib
    gettext git libncurses-dev libssl-dev python3-setuptools rsync swig
    unzip zlib1g-dev file wget libtraceevent-dev systemtap-sdt-dev libslang-dev
    pv bc libelf-dev libtool autoconf
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

# --- Green Progress Bar on Bottom Line ---
progress_bar() {
  local current=$1 total=$2 bar_length=50
  local percent=$(( 100 * current / total ))
  (( percent > 100 )) && percent=100
  local progress=$(( bar_length * percent / 100 ))
  tput civis
  tput cup $(($(tput lines) - 1)) 0
  printf "${GREEN}[%-${bar_length}s] %3d%%${NC}" "$(printf '#%.0s' $(seq 1 $progress))" "$percent"
  tput cnorm
}

bump_progress() {
  ((CURRENT_STEP++))
  (( CURRENT_STEP > TOTAL_STEPS )) && CURRENT_STEP=$TOTAL_STEPS
  progress_bar "$CURRENT_STEP" "$TOTAL_STEPS"
}

log_progress() { echo "Progress: Step $CURRENT_STEP of $TOTAL_STEPS"; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
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
MIN_DISK_GB=12
CLEAN_MARKER_FILE="$REPO_ROOT/.openwrt_cloned_this_session"

SKIP_CONFIRM=0
if [[ "${1-}" == "--force" ]]; then SKIP_CONFIRM=1; fi

on_error() {
  local exit_code=$?
  tput cnorm
  echo -e "${RED}##########################################################${NC}"
  echo -e "${RED}#           >>>>> A CRITICAL ERROR OCCURRED <<<<<         #${NC}"
  echo -e "${RED}# Error on line $LINENO: Command '$BASH_COMMAND' exited with status $exit_code.${NC}"
  echo -e "${RED}##########################################################${NC}"
  echo "For troubleshooting, review the build log:"
  [[ -f "$LOG_FILE" ]] && echo "   $LOG_FILE"
  exit $exit_code
}
trap on_error ERR

DATE_TAG=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="$REPO_ROOT/build_log_${DATE_TAG}.txt"
exec > >(tee -a "$LOG_FILE") 2>&1

step_echo() { echo "================================================================="; echo "=> $1"; echo "================================================================="; }
check_space() {
  local avail=$(df --output=avail "$REPO_ROOT" | tail -1)
  local avail_gb=$((avail/1024/1024))
  if [[ "$avail_gb" -lt "$MIN_DISK_GB" ]]; then
    echo -e "${RED}ERROR: Less than ${MIN_DISK_GB}GB free disk on $REPO_ROOT. (Available: ${avail_gb}GB)${NC}"
    exit 1
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
safe_rsync() { local SRC="$1" DST="$2"; rsync -a --delete --info=progress2 "$SRC" "$DST" || { echo -e "${RED}rsync failed copying $SRC to $DST.${NC}"; exit 1; }; }
register_feed() { local FEED_NAME="$1"; sed -i "/$FEED_NAME/d" feeds.conf.default; }
ensure_patch_directories() { local dir="$OPENWRT_DIR/package/boot/uboot-envtools/files"; [[ ! -d "$dir" ]] && mkdir -p "$dir"; }
inject_custom_be14_eeprom() {
  local eeprom_src="$EEPROM_BLOB"
  local eeprom_dst="$OPENWRT_DIR/files/lib/firmware/mediatek/$DEST_EEPROM_NAME"
  [[ ! -f "$eeprom_src" ]] && { echo -e "${RED}ERROR: BE14 EEPROM .bin not found at $eeprom_src${NC}"; exit 1; }
  mkdir -p "$(dirname "$eeprom_dst")"
  cp -af "$eeprom_src" "$eeprom_dst"
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
  while read line; do
    [[ -z "$line" ]] && continue
    grep -q -F "$line" "$config_file" || echo "$line" >> "$config_file"
  done <<< "$WANTED_CONFIGS"
}
check_for_patch_rejects() {
  local build_dir="$1" rejs
  rejs=$(find "$build_dir" -name '*.rej' 2>/dev/null)
  if [[ -n "$rejs" ]]; then
    echo -e "${RED}Patch reject(s) detected:\n${rejs}${NC}"; exit 77
  fi
}

clean_and_clone() {
  step_echo "Clean Up & Clone Repos"
  rm -rf "$OPENWRT_DIR"
  rm -f "$CLEAN_MARKER_FILE"
  [[ "$SKIP_CONFIRM" == "0" ]] && { read -p "This will delete '$OPENWRT_DIR'. Continue? (y/n) " -n 1 -r; echo; [[ ! $REPLY =~ ^[Yy]$ ]] && echo "Operation cancelled." && exit 1; }
  step_echo "Cloning OpenWrt..."
  GIT_TERMINAL_PROMPT=0 git clone --progress --branch "$OPENWRT_TAG" --depth 1 "$OPENWRT_REPO" "$OPENWRT_DIR"
  bump_progress
  step_echo "Cloning MediaTek feeds (shallow)..."
  GIT_TERMINAL_PROMPT=0 git clone --progress --depth 1 "$MTK_REPO" "$OPENWRT_DIR/$FEED_PATH"
  echo "Cloning complete."
  touch "$CLEAN_MARKER_FILE"
  bump_progress
}

prepare_tree() {
  [[ ! -f "$CLEAN_MARKER_FILE" ]] && { echo -e "${RED}ERROR: You must run 'Clean & Clone' first!${NC}"; exit 1; }
  rm -f "$CLEAN_MARKER_FILE"
  step_echo "Preparing the Build Tree"
  [[ ! -d "$OPENWRT_DIR" ]] && { echo -e "${RED}Error: '$OPENWRT_DIR' not found. Run Step 1.${NC}"; exit 1; }
  cd "$OPENWRT_DIR"
  register_feed "$FEED_NAME"; bump_progress
  ./scripts/feeds update -a && ./scripts/feeds install -a; bump_progress
  ensure_patch_directories; bump_progress
  inject_custom_be14_eeprom; bump_progress
  local CRYPT_PATCH="$OPENWRT_DIR/$FEED_PATH/autobuild/unified/filogic/24.10/patches-feeds/cryptsetup-01-add-host-build.patch"
  [[ -f "$CRYPT_PATCH" ]] && { echo "Deleting incompatible cryptsetup patch."; rm -v "$CRYPT_PATCH"; }
  bump_progress
  bash "$FEED_PATH/autobuild/unified/autobuild.sh" "$PROFILE" prepare; bump_progress
  check_for_patch_rejects "$OPENWRT_DIR"
  cd "$SCRIPT_DIR"
  bump_progress
}

apply_config_and_build() {
  step_echo "Applying overlays, config, and Building"
  [[ ! -d "$OPENWRT_DIR" ]] && { echo -e "${RED}Tree not prepared. Run previous steps.${NC}"; exit 1; }
  cd "$OPENWRT_DIR"
  [[ ! -d "$BUILDER_FILES_SRC/my_files" ]] || [[ ! -d "$BUILDER_FILES_SRC/configs" ]] && { echo -e "${RED}Error: Builder subfolders missing.${NC}"; exit 1; }
  safe_rsync "$BUILDER_FILES_SRC/my_files/" ./my_files/; bump_progress
  safe_rsync "$BUILDER_FILES_SRC/configs/" ./configs/; bump_progress
  safe_rsync "$DEVICE_FILES_SRC/" ./files/; bump_progress
  cp -v "$LEXY_CONFIG_SRC" ./.config; bump_progress
  patch_config_for_main_be14_router; make defconfig; bump_progress
  check_space; bump_progress

  # --- Begin Build, subdivide ticks for smooth bar ---
  step_echo "Starting build (make)..."
  local build_ticks=50
  for ((progress_here=1; progress_here<=build_ticks; progress_here++)); do
    sleep 0.15
    progress_bar "$((CURRENT_STEP+progress_here))" "$TOTAL_STEPS"
  done &
  local fake_pid=$!
  make V=sc -j"$(nproc)" 2>&1 | tee -a "$LOG_FILE"
  kill $fake_pid 2>/dev/null || true
  CURRENT_STEP=$TOTAL_STEPS
  progress_bar "$CURRENT_STEP" "$TOTAL_STEPS"
  echo ""; tput cnorm
  cd "$SCRIPT_DIR"
  echo
  echo -e "${GREEN}\n##################################################"
  echo "### Build process completed successfully!      ###"
  echo "### Find images in '$OPENWRT_DIR/bin/'.        ###"
  echo "### See log: $LOG_FILE"
  echo "##################################################${NC}"
}

openwrt_shell() {
  [[ ! -d "$OPENWRT_DIR" ]] && { echo -e "${RED}OpenWrt directory ($OPENWRT_DIR) not found. Run Step 1.${NC}"; exit 1; }
  echo "Dropping you into a shell in $OPENWRT_DIR. Type 'exit' to return."
  cd "$OPENWRT_DIR"
  bash
  cd "$SCRIPT_DIR"
}

show_menu() {
  echo ""
  echo "================================================================="
  echo "=> BPI-R4 Build Menu (overlays in contents/)"
  echo "================================================================="
  echo "a) Run All Steps (Fresh, deletes previous sources)"
  echo "------------------------ THE PROCESS -----------------------"
  echo "1) Clean Up & Clone Repos"
  echo "2) Prepare Tree (Feeds, inject firmware/EEPROM, patches, etc.)"
  echo "3) Apply Final Config & Run Build (make)"
  echo "------------------------ UTILITIES -------------------------"
  echo "s) Enter OpenWrt Directory Shell (debug/inspection)"
  echo "q) Quit"
  echo ""
}

install_dependencies
check_requirements

while true; do
  trap '' ERR; set +e
  show_menu
  read -p "Please select an option: " choice
  trap on_error ERR; set -e
  case $choice in
    a|A) CURRENT_STEP=0; clean_and_clone; prepare_tree; apply_config_and_build ;;
    1) CURRENT_STEP=0; clean_and_clone ;;
    2) prepare_tree ;;
    3) apply_config_and_build ;;
    s|S) openwrt_shell ;;
    q|Q) tput cnorm; echo "Exiting script. Log is at $LOG_FILE"; exit 0 ;;
    *) echo -e "${RED}Invalid option. Please try again.${NC}";;
  esac
done
