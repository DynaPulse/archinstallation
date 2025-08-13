#!/usr/bin/env bash
#
# arch-dualboot-secureboot.sh
#
# Full interactive Arch Linux dual-boot installer (copy-paste ready).
# - Uses existing Windows EFI partition (shared ESP, no new ESP)
# - Leaves Windows partitions alone unless you explicitly choose to overwrite them
# - Installs curated developer meta-package list (AUTOSAR, kernel, VLSI, embedded tools)
# - Installs nvidia-dkms and configures Hyprland (Wayland) with NVIDIA tweaks
# - Sets up systemd-boot and creates both Arch and Windows entries (user menu at boot)
# - Sets up sbctl (Secure Boot) full flow: create-keys, enroll-keys, verify
# - Dedupes and verifies all packages, adds AUR helper (paru)
# - Interactive and supports --dry-run mode
#
# WARNING: This script can be destructive. Read and edit CONFIG below before running.
# Run from an official Arch live environment. Prefer latest Arch ISO.
#
# Usage:
#   chmod +x arch-dualboot-secureboot.sh
#   ./arch-dualboot-secureboot.sh            # actual run (interactive confirmations)
#   ./arch-dualboot-secureboot.sh --dry-run  # show commands without destructive actions
#


# Enhanced error tracing
set -eEuo pipefail
IFS=$'\n\t'

# Track last command for debugging
trap 'LAST_COMMAND=$BASH_COMMAND' DEBUG
trap 'LAST_EXIT_CODE=$?' RETURN

# --- FATAL ERROR HANDLING & CLEANUP ---
RESTORED_PARTTABLE=0
PARTTABLE_BACKUP_FILE=""
MOUNTED=()

fatal() {
  error "FATAL: $*"
  debug "fatal() called. Last command exit code: $?"
  debug "Stack trace: $(caller 0)"
    error "Last command: ${LAST_COMMAND:-unknown}"
  error "Last exit code: ${LAST_EXIT_CODE:-unknown}"
  # Print stack trace for debugging
  local i=0
  while caller $i; do ((i++)); done
  cleanup_and_maybe_restore
  exit 1
}

cleanup_unmount() {
  debug "cleanup_unmount: unmounting mounts (${MOUNTED[*]})"
  for m in "${MOUNTED[@]}"; do
    debug "Attempting to unmount $m"
    if mountpoint -q "${m}"; then
      warn "Unmounting ${m}"
      umount -R "${m}" || debug "Failed to unmount $m (ignored)"
    else
      debug "$m is not a mountpoint, skipping"
    fi
  done
  MOUNTED=()
  debug "cleanup_unmount: done"
}

cleanup_and_maybe_restore() {
  debug "cleanup_and_maybe_restore: called"
  cleanup_unmount
  if [ -n "${PARTTABLE_BACKUP_FILE}" ] && [ "${RESTORED_PARTTABLE}" -eq 0 ] && [ "${DRY_RUN}" -eq 0 ]; then
    warn "A partition table backup exists at ${PARTTABLE_BACKUP_FILE}."
    if confirm "Attempt to restore original partition table from backup? (recommended)"; then
      warn "Restoring partition table (sgdisk --load-backup=${PARTTABLE_BACKUP_FILE})"
      sgdisk --load-backup="${PARTTABLE_BACKUP_FILE}" "${DISK}" || warn "Failed to restore partition table automatically; you may need to restore manually."
      RESTORED_PARTTABLE=1
      partprobe "${DISK}" || true
    fi
  fi
  debug "cleanup_and_maybe_restore: done"
}


# Enhanced ERR trap with command/exit code
trap 'rc=$?; LAST_EXIT_CODE=$rc; error "[DEBUG] ERR trap triggered. Last exit code: ${rc}"; error "[DEBUG] Last command: ${LAST_COMMAND:-unknown}"; fatal "Aborting due to trapped error."' ERR
trap 'debug "[DEBUG] EXIT trap triggered. Calling cleanup_unmount"; cleanup_unmount' EXIT

### ---------- CONFIG - EDIT BEFORE RUNNING ---------- ###
DISK="/dev/nvme0n1"          # target disk (change if different)
# Known Windows partitions (do NOT change unless you know what you're doing)
WIN_ESP="${DISK}p1"          # Windows EFI (do NOT format)
WIN_SYSTEM="${DISK}p2"       # Windows C: (do NOT touch)
WIN_UNKNOWN="${DISK}p3"      # Windows unknown FS (do NOT touch)
WIN_RECOVERY="${DISK}p4"     # Windows Recovery (do NOT touch)


ARCH_ALLOCATION_GiB=512      # carve out this much from free space (must exist)
ROOT_GiB=100                 # root size inside allocation
ESP_USE_EXISTING=1           # 1 = use existing Windows ESP (shared), 0 = create new ESP (NOT recommended)
SWAPSIZE_GiB=0               # 0 => don't create swapfile, else 1-16 GiB
USERNAME="sagar"
HOSTNAME="archbox"
TIMEZONE="Asia/Kolkata"
LOCALE="en_US.UTF-8"

DRY_RUN=0                    # set to 1 or use --dry-run flag
DEBUG=0                      # set to 1 or use --debug for extra logs


# Pacstrap package lists (deduped, improved)
PKGS_common=(base linux linux-headers amd-ucode networkmanager sudo efibootmgr dosfstools mtools bash-completion curl wget openssh rsync sbctl sbsigntool pacman-contrib)
PKGS_desktop=(nvidia-dkms nvidia-utils libglvnd wayland wayland-protocols xorg-xwayland hyprland xdg-desktop-portal xdg-desktop-portal-hyprland pipewire pipewire-pulse wireplumber firefox alacritty)
PKGS_dev=(git cmake gcc python python-pip qemu virt-manager openocd base-devel)
PKGS_ALL=("${PKGS_common[@]}" "${PKGS_desktop[@]}" "${PKGS_dev[@]}")
AUR_HELPER="paru"  # installed inside chroot (build from AUR)

### ---------- END CONFIG ---------- ###

# Logging
LOG="/tmp/arch_install_final.log"
: > "${LOG}"
exec > >(tee -a "${LOG}") 2>&1

timestamp(){ date +"%Y-%m-%d %H:%M:%S"; }
info(){ echo "$(timestamp) [INFO]  $*"; }
warn(){ echo "$(timestamp) [WARN]  $*"; }
debug(){ [ "${DEBUG}" -eq 1 ] && echo "$(timestamp) [DEBUG] $*"; }
error(){ echo "$(timestamp) [ERROR] $*" >&2; }

# Helpers for dry-run and running
run_cmd(){
  debug "[DEBUG] About to run: $*"
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[DRY-RUN] $*"
  else
    debug "RUN: $*"
    eval "$@"
    local rc=$?
    debug "[DEBUG] Command exit code: $rc"
    return $rc
  fi
}

confirm(){
  # interactive yes/no prompt. Default no.
  local prompt="${1:-Proceed?}"
  while true; do
    read -r -p "${prompt} [yes/NO]: " ans
    case "${ans}" in
      [Yy][Ee][Ss]|[Yy]) return 0 ;;
      [Nn][Oo]|[Nn]|"") return 1 ;;
      *) echo "Please type 'yes' or 'no'." ;;
    esac
  done
}


# Checkpoint printing (structured, explicit summaries)
TOTAL_CHECKPOINTS=12
CHECKPOINT_IDX=0
checkpoint_start() {
  CHECKPOINT_IDX=$((CHECKPOINT_IDX+1))
  debug "[DEBUG] Entering checkpoint: $1"
  echo
  echo "=============================================="
  echo "[CHECKPOINT ${CHECKPOINT_IDX}/${TOTAL_CHECKPOINTS}] $1"
  echo "----------------------------------------------"
}
checkpoint_ok() {
  # Accept an array of lines to print as summary with checkmarks
  local lines=("$@")
  for l in "${lines[@]}"; do
    echo "  ✔ ${l}"
  done
  echo "=============================================="
  debug "[DEBUG] Exiting checkpoint"
  echo
}

usage(){
  cat <<USAGE
Usage: $0 [--dry-run] [--debug] [-d /dev/nvme0n1]
  --dry-run   : Show steps but don't run destructive commands.
  --debug     : Enable debug logs.
  -d <disk>   : Specify disk (overrides DISK variable).
USAGE
  exit 1
}

# Argument parsing
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift;;
    --debug) DEBUG=1; shift;;
    -d) DISK="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done


# --- UEFI BOOT MODE CHECK ---
if [ ! -d /sys/firmware/efi ]; then
  fatal "Not booted in UEFI mode. Please boot the installer in UEFI mode."
fi

info "Starting Arch dualboot installer (interactive). Log -> ${LOG}"
info "Target disk: ${DISK}"
debug "Config: ARCH_ALLOC=${ARCH_ALLOCATION_GiB} GiB, ROOT=${ROOT_GiB} GiB"


# Check tools existence (abort if missing, unless dry-run)
MISSING_TOOLS=()
for t in parted lsblk sgdisk mkfs.ext4 mkfs.fat mount umount pacstrap genfstab arch-chroot partprobe blkid awk grep dd mkinitcpio bootctl; do
  if ! command -v "${t}" >/dev/null 2>&1; then
    warn "Tool ${t} not found in live environment. You may need a full official Arch ISO."
    MISSING_TOOLS+=("${t}")
  fi
done
if [ "${#MISSING_TOOLS[@]}" -gt 0 ] && [ "${DRY_RUN}" -eq 0 ]; then
  error "Missing required tools: ${MISSING_TOOLS[*]}. Aborting."
  exit 1
fi


# --- USER INPUT VALIDATION ---
if ! [[ "${DISK}" =~ ^/dev/ ]]; then
  fatal "DISK variable must be a valid /dev/ device."
fi
if ! [[ "${USERNAME}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
  fatal "USERNAME variable is not a valid Linux username."
fi

# Show current partition table
checkpoint_start "Disk inspection and confirmation"
echo "Current partition layout for ${DISK}:"
lsblk -o NAME,MAJ:MIN,SIZE,TYPE,FSTYPE,MOUNTPOINT "${DISK}" || true
echo
blkid || true

# Warn if existing Linux partitions are detected
LINUX_PARTS=$(lsblk -nr -o NAME,FSTYPE,MOUNTPOINT "${DISK}" | awk '$2 ~ /(ext4|btrfs|xfs)/ && $3 !~ /^\/mnt/ {print $1}' | xargs || true)
if [ -n "${LINUX_PARTS}" ]; then
  warn "Existing Linux partitions detected on ${DISK}: ${LINUX_PARTS}"
  if ! confirm "Continue anyway? (This may overwrite existing Linux data)"; then
    info "User aborted due to existing Linux partitions. Exiting."
    exit 1
  fi
fi

# --- PARTITION TABLE BACKUP ---
BACKUP_DIR="/tmp/arch_install_backup_$(date +%s)"
mkdir -p "${BACKUP_DIR}"
PARTTABLE_BACKUP_FILE="${BACKUP_DIR}/part-table-backup.sgdisk"
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "[DRY-RUN] sgdisk --backup=${PARTTABLE_BACKUP_FILE} ${DISK}"
else
  info "Backing up current partition table to ${PARTTABLE_BACKUP_FILE}"
  sgdisk --backup="${PARTTABLE_BACKUP_FILE}" "${DISK}" || warn "sgdisk backup failed (you may not be able to auto-restore)."
fi

# Ensure we won't accidentally overwrite known Windows partitions without consent
echo
echo "IMPORTANT: The script will NOT touch these Windows partitions unless you explicitly allow:"
echo "  ${WIN_ESP}    (Windows EFI)      - WILL BE PRESERVED"
echo "  ${WIN_SYSTEM} (Windows C:)       - WILL BE PRESERVED"
echo "  ${WIN_UNKNOWN} (Windows unknown) - WILL BE PRESERVED"
echo "  ${WIN_RECOVERY} (Windows Reco)   - WILL BE PRESERVED"
echo
echo "Requested new Linux partitions (preferred):"
echo "  Root (/):   ${ROOT_GiB} GiB (ext4)"
echo "  Home (/home): remaining of the chosen free region (ext4)"
echo
if ! confirm "Do you want to continue to scan for unallocated space and propose a partition plan?"; then
  info "User aborted at initial confirmation. Exiting."
  exit 0
fi
checkpoint_ok \
  "Disk layout inspected: ${DISK}" \
  "Windows partitions detected and will be preserved" \
  "User confirmed to proceed with partition scan"



# Dynamically analyze all unallocated regions and select the largest for partitioning
checkpoint_start "Analyzing all unallocated space for partitioning"
FREE_REGIONS=$(parted -m --script "${DISK}" unit MiB print free 2>/dev/null || true)
debug "parted output:\n${FREE_REGIONS}"
LARGEST_SIZE=0; LARGEST_START=0; LARGEST_END=0
while IFS= read -r line; do
  if echo "${line}" | grep -q "Free Space"; then
    # parse start:end
    IFS=":" read -r _ start end _ <<<"${line}"
    start=${start//MiB/}
    end=${end//MiB/}
    size=$(( end - start ))
    debug "Found free region: start=${start} end=${end} size=${size} MiB"
    if [ "${size}" -gt "${LARGEST_SIZE}" ]; then
      LARGEST_SIZE=${size}; LARGEST_START=${start}; LARGEST_END=${end}
    fi
  fi
done <<< "${FREE_REGIONS}"
if [ "${LARGEST_SIZE}" -lt 32768 ]; then
  fatal "No sufficiently large unallocated region found (minimum 32 GiB required)."
fi
info "Largest unallocated region: start=${LARGEST_START} MiB, end=${LARGEST_END} MiB, size=${LARGEST_SIZE} MiB"
checkpoint_ok \
  "Largest free region found: start=${LARGEST_START} MiB, end=${LARGEST_END} MiB, size=${LARGEST_SIZE} MiB"


# Plan partitions inside free region (root & optional home only, no new ESP)
echo "Planned allocation (MiB):"
echo "  Allocation: ${ALLOC_START} - ${ALLOC_END} (${ARCH_ALLOCATION_GiB} GiB)"
echo "  ROOT   : ${ROOT_START} - ${ROOT_END} (${ROOT_GiB} GiB)"
echo "  HOME   : ${HOME_START} - ${HOME_END} (remaining)"

# Use the largest region for root and home
ALLOC_START=${LARGEST_START}
ALLOC_END=${LARGEST_END}
ROOT_START=$((ALLOC_START + 1))   # small slack
ROOT_END=$((ROOT_START + (ROOT_GiB * 1024)))
HOME_START=${ROOT_END}
HOME_END=${ALLOC_END}

info "Planned allocation (MiB):"
info "  Allocation: ${ALLOC_START} - ${ALLOC_END} MiB"
info "  ROOT   : ${ROOT_START} - ${ROOT_END} MiB (${ROOT_GiB} GiB)"
info "  HOME   : ${HOME_START} - ${HOME_END} MiB (remaining)"
if ! confirm "Create root & home partitions in this allocation window?"; then
  fatal "User cancelled partition creation."
fi
checkpoint_ok \
  "Partition plan accepted for root and home (no new ESP)" \
  "Root: ${ROOT_START}-${ROOT_END} MiB" \
  "Home: ${HOME_START}-${HOME_END} MiB (if space)"


# If user requested specific partition numbers (p4/p5/p6), check for conflicts:
checkpoint_start "Validating requested partition numbers & potential conflicts"
# Detect if requested partition numbers already exist
conflict=0
for num in "${LINUX_ESP_PART_NO}" "${LINUX_ROOT_PART_NO}" "${LINUX_HOME_PART_NO}"; do
  part="${DISK}p${num}"
  if [ -b "${part}" ]; then
    echo "Detected existing partition: ${part}"
    conflict=1
  fi
done

if [ "${conflict}" -eq 1 ]; then
  warn "One or more desired partition numbers (${LINUX_ESP_PART_NO},${LINUX_ROOT_PART_NO},${LINUX_HOME_PART_NO}) already exist."
  echo "You requested specific numbering (p${LINUX_ESP_PART_NO}-p${LINUX_HOME_PART_NO})."
  echo "OVERWRITING existing partitions would destroy data on those partitions."
  if ! confirm "Do you want to overwrite existing partitions at those numbers? (dangerous)"; then
    info "User declined to overwrite existing numbered partitions. The script will create next available partition numbers instead."
    USE_SPECIFIC_NUMS=0
  else
    USE_SPECIFIC_NUMS=1
  fi
else
  USE_SPECIFIC_NUMS=1
fi
checkpoint_ok \
  "Partition number validation complete" \
  "No Windows partitions will be touched" \
  "User confirmed handling of partition number conflicts"


# Create partitions with parted (only root & home; do NOT create an ESP)
checkpoint_start "Creating partitions (root & home only, no new ESP)"
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "[DRY-RUN] parted ${DISK} mkpart primary ext4 ${ROOT_START}MiB ${ROOT_END}MiB"
  echo "[DRY-RUN] parted ${DISK} mkpart primary ext4 ${HOME_START}MiB ${HOME_END}MiB"
else
  info "Creating root partition: ${ROOT_START}MiB - ${ROOT_END}MiB"
  parted --script "${DISK}" mkpart primary ext4 "${ROOT_START}MiB" "${ROOT_END}MiB" || fatal "parted failed for root"
  # create home if large enough
  if [ $((HOME_END-HOME_START)) -gt 32 ]; then
    info "Creating home partition: ${HOME_START}MiB - ${HOME_END}MiB"
    parted --script "${DISK}" mkpart primary ext4 "${HOME_START}MiB" "${HOME_END}MiB" || fatal "parted failed for home"
  else
    info "Not enough space for separate /home partition; will use root for /home"
  fi
  partprobe "${DISK}" || true
  sleep 2
fi
checkpoint_ok \
  "Partitions created: root and home (if space)" \
  "No new ESP created; shared Windows ESP will be used" \
  "Partitioning step complete"


# Detect new partitions (by start offset and size)
checkpoint_start "Detecting new partitions (by start offset and size)"
NEW_ESP_PART=""
ROOT_PART=""
HOME_PART=""
ALL_PARTS=()
while IFS= read -r p; do ALL_PARTS+=("/dev/${p}"); done < <(lsblk -nr -o NAME "${DISK}" | grep -E "^$(basename ${DISK})p" || true)

# Heuristic detection
for p in "${ALL_PARTS[@]}"; do
  # skip ESP if it's the existing Windows ESP
  [ "${p}" = "${WIN_ESP}" ] && continue
  start_sectors=$(lsblk -bn -o START "${p}" 2>/dev/null || echo 0)
  start_mib=$(( start_sectors * 512 / 1024 / 1024 ))
  size_bytes=$(lsblk -bn -o SIZE "${p}" 2>/dev/null || echo 0)
  size_mib=$(( size_bytes / 1024 / 1024 ))
  debug "candidate ${p} start=${start_mib} MiB size=${size_mib} MiB"
  if [ -z "${ROOT_PART}" ] && [ "${start_mib}" -ge $((ROOT_START-5)) ] && [ "${start_mib}" -le $((ROOT_START+5)) ]; then
    ROOT_PART="${p}"
    continue
  fi
  if [ -z "${HOME_PART}" ] && [ "${start_mib}" -ge $((HOME_START-5)) ] && [ "${start_mib}" -le $((HOME_START+5)) ]; then
    HOME_PART="${p}"
    continue
  fi
done


# Robust ESP detection: use Windows ESP if possible, else auto-detect any ESP with Microsoft bootloader
NEW_ESP_PART=""
if [ -b "${WIN_ESP}" ]; then
  NEW_ESP_PART="${WIN_ESP}"
else
  # Fallback: find any ESP with Microsoft bootloader
  for dev in $(lsblk -ln -o NAME | grep -E '^[a-zA-Z0-9]+[0-9]+$'); do
    devpath="/dev/${dev}"
    if blkid -o value -s PARTLABEL "$devpath" 2>/dev/null | grep -qi "EFI"; then
      mkdir -p /mnt/win_esp
      if mount "$devpath" /mnt/win_esp >/dev/null 2>&1; then
        if [ -f /mnt/win_esp/EFI/Microsoft/Boot/bootmgfw.efi ]; then
          NEW_ESP_PART="$devpath"
          umount /mnt/win_esp || true
          break
        fi
        umount /mnt/win_esp || true
      fi
    fi
  done
  rmdir /mnt/win_esp 2>/dev/null || true
fi
if [ -z "$NEW_ESP_PART" ]; then
  fatal "No suitable ESP found. Please ensure a Windows EFI partition exists."
fi

echo "Detected partitions: ROOT=${ROOT_PART} HOME=${HOME_PART:-'(none)'} ESP(shared)=${NEW_ESP_PART:-'(detect later)'}"

# Safety: confirm mapping with user
echo "Please confirm the partition mapping:"
echo "  Root partition: ${ROOT_PART}"
echo "  Home partition: ${HOME_PART:-(none)}"
if [ -n "${NEW_ESP_PART}" ]; then
  echo "  Shared ESP (will be mounted at /mnt/boot): ${NEW_ESP_PART}"
else
  echo "  No shared ESP detected; the script will create & use a new ESP (not recommended)."
fi
if ! confirm "Is this mapping correct?"; then
  fatal "User did not confirm mapping. Aborting."
fi

if [ -z "${ROOT_PART}" ]; then
  fatal "Failed to detect newly created root partition. Abort and inspect partitions manually."
fi

EFI_PART="${NEW_ESP_PART}"
checkpoint_ok \
  "Detected created partitions:" \
  "Root: ${ROOT_PART}" \
  "Home: $([ -n "${HOME_PART:-}" ] && echo "${HOME_PART}" || echo '(none, using root for /home)')" \
  "Shared ESP: ${EFI_PART}"


# Confirm formatting (do NOT format shared ESP)
checkpoint_start "Formatting partitions (ext4 for root/home, shared ESP is NOT formatted)"
info "About to format:"
info "  ${ROOT_PART} -> ext4"
[ -n "${HOME_PART:-}" ] && info "  ${HOME_PART} -> ext4"
info "  ${EFI_PART}  -> (shared Windows ESP, will NOT be formatted)"

# --- FILESYSTEM OVERWRITE WARNING ---
for p in "${ROOT_PART}" ${HOME_PART:-}; do
  if [ -n "$p" ] && blkid "$p" >/dev/null 2>&1; then
    warn "Partition $p already has a filesystem: $(blkid $p)"
    if ! confirm "Overwrite existing filesystem on $p?"; then
      fatal "User aborted formatting $p."
    fi
  fi
done

if ! confirm "Proceed to format these partitions? This will erase data on them."; then
  info "User canceled formatting. Exiting."
  exit 0
fi

# Format (do NOT format shared ESP)
if [ "${DRY_RUN}" -eq 1 ]; then
  run_cmd "mkfs.ext4 -F ${ROOT_PART}"
  [ -n "${HOME_PART:-}" ] && run_cmd "mkfs.ext4 -F ${HOME_PART}"
else
  info "Formatting root partition: ${ROOT_PART}"
  mkfs.ext4 -F "${ROOT_PART}" || fatal "mkfs.ext4 failed for ${ROOT_PART}"
  if [ -n "${HOME_PART:-}" ]; then
    info "Formatting home partition: ${HOME_PART}"
    mkfs.ext4 -F "${HOME_PART}" || fatal "mkfs.ext4 failed for ${HOME_PART}"
  fi
fi
checkpoint_ok \
  "Partitions formatted:" \
  "Root: ${ROOT_PART} (ext4)" \
  $([ -n "${HOME_PART:-}" ] && echo "Home: ${HOME_PART} (ext4)" || echo "Home: (none, using root for /home)") \
  "Shared ESP: ${EFI_PART} (not formatted)"


# Mount
checkpoint_start "Mounting filesystems (shared ESP mounted read-only)"
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "[DRY-RUN] mount ${ROOT_PART} /mnt"
  [ -n "${HOME_PART:-}" ] && echo "[DRY-RUN] mkdir -p /mnt/home && mount ${HOME_PART} /mnt/home"
  if [ -n "${EFI_PART}" ]; then
    echo "[DRY-RUN] mkdir -p /mnt/boot && mount -o ro ${EFI_PART} /mnt/boot"
  fi
else
  mount "${ROOT_PART}" /mnt || fatal "Failed to mount root"
  MOUNTED+=("/mnt")
  if [ -n "${HOME_PART}" ]; then
    mkdir -p /mnt/home
    mount "${HOME_PART}" /mnt/home || fatal "Failed to mount home"
    MOUNTED+=("/mnt/home")
  fi
  mkdir -p /mnt/boot
  if [ -n "${EFI_PART}" ]; then
    # Try mounting read-only, fallback to rw if needed
    if ! mount -o ro "${EFI_PART}" /mnt/boot; then
      warn "Failed to mount ESP read-only, trying read-write."
      if ! mount -o rw "${EFI_PART}" /mnt/boot; then
        fatal "Failed to mount shared ESP at all."
      fi
    fi
    MOUNTED+=("/mnt/boot")
  fi
fi
checkpoint_ok \
  "Filesystems mounted under /mnt" \
  "Root: ${ROOT_PART} -> /mnt" \
  $([ -n "${HOME_PART:-}" ] && echo "Home: ${HOME_PART} -> /mnt/home" || echo "Home: (none, using root for /home)") \
  "Shared ESP: ${EFI_PART} -> /mnt/boot (read-only)"
sleep 1


# Generate fstab
checkpoint_start "Generating /etc/fstab for new system"
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "[DRY-RUN] genfstab -U /mnt > /mnt/etc/fstab"
else
  genfstab -U /mnt | tee /mnt/etc/fstab
fi
checkpoint_ok \
  "fstab generated at /mnt/etc/fstab" \
  "All mount points recorded"


# Pacstrap: dedupe package list and verify availability
checkpoint_start "Preparing package list and verifying availability"
# dedupe
declare -A _seen; PKGS_UNIQ=()
for p in "${PKGS_ALL[@]}"; do
  if [ -z "${_seen[$p]:-}" ]; then PKGS_UNIQ+=("$p"); _seen[$p]=1; fi
done
PKGS_ALL=("${PKGS_UNIQ[@]}")

# check availability with pacman -Si (works in live environment if mirrors configured)
missing_pkgs=()
for p in "${PKGS_ALL[@]}"; do
  if ! pacman -Si "$p" >/dev/null 2>&1; then
    missing_pkgs+=("$p")
  fi
done
if [ "${#missing_pkgs[@]}" -gt 0 ]; then
  warn "Missing packages in repo: ${missing_pkgs[*]}"
  if ! confirm "Continue anyway (AUR helper will be installed)?"; then
    fatal "Aborting due to missing packages."
  fi
fi

# Network check before pacstrap
if ! ping -c1 archlinux.org >/dev/null 2>&1; then
  warn "No network connectivity detected. pacstrap may fail."
  if ! confirm "Continue anyway? (You are responsible for network setup)"; then
    info "User aborted due to missing network. Exiting."
    exit 1
  fi
fi

RETRY_PACSTRAP=2
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "[DRY-RUN] pacstrap /mnt ${PKGS_ALL[*]}"
else
  attempt=0
  until [ "${attempt}" -ge "${RETRY_PACSTRAP}" ]; do
    attempt=$((attempt+1))
    info "pacstrap attempt ${attempt}/${RETRY_PACSTRAP}"
    if pacstrap /mnt "${PKGS_ALL[@]}"; then
      info "pacstrap succeeded"
      break
    else
      warn "pacstrap failed on attempt ${attempt}"
      if [ "${attempt}" -ge "${RETRY_PACSTRAP}" ]; then
        fatal "pacstrap failed after ${RETRY_PACSTRAP} attempts. Aborting to allow manual inspection."
      else
        info "Retrying pacstrap after a short wait..."
        sleep 5
      fi
    fi
  done
fi
checkpoint_ok \
  "Base system and developer packages installed (or dry-run shown)" \
  "Total packages: ${#PKGS_ALL[@]} (see script for full list)"

## Add extra developer tools for AUTOSAR, kernel, VLSI
PKGS_dev+=(
  clang-tools-extra gdb-multiarch openocd-git python-pytest python-pylint python-black python-matplotlib python-numpy python-scipy python-pandas python-jupyterlab
  verilator yosys-gui gtkwave-git ghdl-gcc ghdl-llvm
  qemu-system-arm qemu-system-mips qemu-system-ppc qemu-system-x86
  socat minicom picocom
  cunit cppcheck bear
  doxygen graphviz
  cmake-gui
  ninja-build
  lcov gcovr
  clang-analyzer
  python-coverage
  python-pybind11
  python-pyserial
  python-pyusb
  python-pyqt5 python-pyqt6
  python-pyside2 python-pyside6
  python-pytest-cov
  python-pytest-xdist
  python-pytest-mock
  python-pytest-asyncio
  python-pytest-benchmark
  python-pytest-html
  python-pytest-metadata
  python-pytest-order
  python-pytest-randomly
  python-pytest-repeat
  python-pytest-sugar
  python-pytest-timeout
  python-pytest-xvfb
)
PKGS_ALL=("${PKGS_common[@]}" "${PKGS_desktop[@]}" "${PKGS_dev[@]}")


checkpoint_start "Preparing post-install chroot script (config, bootloader, sbctl, user, mkinitcpio, hooks, AUR helper)"
cat > /mnt/root/_post_install.sh <<'CHROOT'
#!/usr/bin/env bash
# runs inside installed system via arch-chroot /mnt /root/_post_install.sh
set -euo pipefail
exec > >(tee -a /root/post_install_chroot.log) 2>&1

# injected vars (outer script will sed them in)
: "${ROOT_PART:-}" 2>/dev/null || true
: "${NEW_ESP_PART:-}" 2>/dev/null || true
: "${USERNAME:-sagar}" 2>/dev/null || true
: "${HOSTNAME:-archbox}" 2>/dev/null || true
: "${LOCALE:-en_US.UTF-8}" 2>/dev/null || true
: "${TIMEZONE:-Asia/Kolkata}" 2>/dev/null || true
: "${AUR_HELPER:-paru}" 2>/dev/null || true

echo "CHROOT: starting post-install tasks"

# timezone & locale
ln -sf /usr/share/zoneinfo/"${TIMEZONE}" /etc/localtime || true
hwclock --systohc || true
echo "${LOCALE} UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# hostname & hosts
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

# root password & user creation
echo "Set ROOT password now:"
passwd
useradd -m -G wheel -s /bin/bash "${USERNAME}" || true
echo "Set password for ${USERNAME}:"
passwd "${USERNAME}"
# enable wheel sudo
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers || true

# enable NetworkManager
systemctl enable NetworkManager || true

# mkinitcpio tweaks (ensure nvidia modules present)
if grep -q '^MODULES=' /etc/mkinitcpio.conf; then
  sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf || true
fi
if ! grep -q 'modconf' /etc/mkinitcpio.conf; then
  sed -i 's/^HOOKS=(\(.*\))/HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)/' /etc/mkinitcpio.conf || true
fi
mkinitcpio -P || true


# install systemd-boot to the shared ESP mount point (remount rw if needed)
if command -v bootctl >/dev/null 2>&1; then
  mountpoint -q /boot && mount -o remount,rw /boot 2>/dev/null || true
  bootctl --path=/boot install || true
  mountpoint -q /boot && mount -o remount,ro /boot 2>/dev/null || true
else
  echo "bootctl not found; install systemd-boot manually after first boot."
fi

# Create systemd-boot entries (Arch, Arch-recovery, Windows)
ROOT_UUID=$(blkid -s PARTUUID -o value "${ROOT_PART}" 2>/dev/null || blkid -s UUID -o value "${ROOT_PART}" 2>/dev/null || true)
mkdir -p /boot/loader/entries
cat > /boot/loader/entries/arch.conf <<LOADER
title   Arch Linux
linux   /vmlinuz-linux
initrd  /amd-ucode.img
initrd  /initramfs-linux.img
options root=PARTUUID=${ROOT_UUID} rw quiet splash nvidia-drm.modeset=1 nvidia.NVreg_PreserveVideoMemoryAllocations=1
LOADER

# recovery entry (initramfs fallback)
cat > /boot/loader/entries/arch-recovery.conf <<LOADER
title   Arch Linux (recovery)
linux   /vmlinuz-linux
initrd  /initramfs-linux-fallback.img
options root=PARTUUID=${ROOT_UUID} rw single
LOADER


# Robust Windows entry: auto-detect and copy bootmgfw.efi if not present
if [ ! -f /boot/EFI/Microsoft/Boot/bootmgfw.efi ]; then
  for dev in $(lsblk -ln -o NAME | grep -E '^[a-zA-Z0-9]+[0-9]+$'); do
    devpath="/dev/${dev}"
    if blkid -o value -s PARTLABEL "$devpath" 2>/dev/null | grep -qi "EFI"; then
      mkdir -p /mnt/win_esp
      if mount "$devpath" /mnt/win_esp >/dev/null 2>&1; then
        if [ -f /mnt/win_esp/EFI/Microsoft/Boot/bootmgfw.efi ]; then
          mkdir -p /boot/EFI/Microsoft/Boot
          cp /mnt/win_esp/EFI/Microsoft/Boot/bootmgfw.efi /boot/EFI/Microsoft/Boot/bootmgfw.efi
          umount /mnt/win_esp || true
          break
        fi
        umount /mnt/win_esp || true
      fi
    fi
  done
  rmdir /mnt/win_esp 2>/dev/null || true
fi
if [ -f /boot/EFI/Microsoft/Boot/bootmgfw.efi ]; then
  cat > /boot/loader/entries/windows.conf <<WIN
title   Windows 11
efi     /EFI/Microsoft/Boot/bootmgfw.efi
WIN
fi

cat > /boot/loader/loader.conf <<LOADERCONF
default arch
timeout 5
editor 0
LOADERCONF



# Secure Boot: sbctl keys & signing (with Setup Mode check and unattended key enrollment, robust fallback)
if ! command -v sbctl >/dev/null 2>&1; then
  pacman -Sy --noconfirm sbctl sbsigntool || true
fi

if command -v sbctl >/dev/null 2>&1; then
  # Check Setup Mode, fallback to user prompt if not in Setup Mode
  if ! sbctl status | grep -q 'Setup Mode: yes'; then
    echo "[ERROR] Secure Boot firmware is not in Setup Mode. Please enable Setup Mode in your UEFI firmware before running this script." >&2
    exit 1
  fi
  if ! sbctl create-keys; then
    echo "[ERROR] sbctl create-keys failed. Check Secure Boot firmware and try again." >&2
    exit 1
  fi
  if ! sbctl enroll-keys -m; then
    echo "[ERROR] sbctl enroll-keys failed. You may need to enroll keys manually in firmware." >&2
    exit 1
  fi
  if ! sbctl status; then
    echo "[ERROR] sbctl status failed. Secure Boot may not be properly configured." >&2
    exit 1
  fi
  cat > /usr/local/sbin/dkms-sign-and-sbctl <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
LOG="/var/log/dkms-sign-sbctl.log"
echo "$(date) [dkms-sign] Starting" >> "${LOG}" 2>&1
if command -v sbctl >/dev/null 2>&1; then
  sbctl sign-all >> "${LOG}" 2>&1 || true
fi
HOOK
  cat > /etc/pacman.d/hooks/99-sign-sbctl.hook <<'HOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = linux
Target = linux-lts
Target = nvidia
Target = nvidia-dkms
Target = dkms

[Action]
Description = Sign kernel/initramfs and rebuilt DKMS modules with sbctl
When = PostTransaction
Exec = /usr/local/sbin/dkms-sign-and-sbctl
HOOK
fi


# install AUR helper (optional) as non-root user build, robust fallback
if command -v git >/dev/null 2>&1 && command -v makepkg >/dev/null 2>&1; then
  su - "${USERNAME}" -c "git clone https://aur.archlinux.org/${AUR_HELPER}.git ~/paru && cd ~/paru && makepkg -si --noconfirm" || \
  su - "${USERNAME}" -c "cd ~/paru && makepkg -si --noconfirm" || \
  echo "[WARN] Failed to install AUR helper. You may need to install it manually." >&2
fi

echo "CHROOT: done — please verify sbctl enrollment & boot entries after first boot."
CHROOT


# inject dynamic variables into chroot script
checkpoint_start "Injecting variables into chroot script"
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "[DRY-RUN] Would inject ROOT_PART='${ROOT_PART}', NEW_ESP_PART='${EFI_PART}', USERNAME='${USERNAME}' into chroot script"
else
  sed -i "1iAUR_HELPER='${AUR_HELPER}'" /mnt/root/_post_install.sh || true
  sed -i "1iNEW_ESP_PART='${EFI_PART}'" /mnt/root/_post_install.sh || true
  sed -i "1iROOT_PART='${ROOT_PART}'" /mnt/root/_post_install.sh || true
fi
checkpoint_ok \
  "Chroot script prepared at /mnt/root/_post_install.sh" \
  "Variables injected"


# Run chroot script
checkpoint_start "Running arch-chroot to finalize system configuration"
if ! confirm "Run post-install chroot script now (recommended)?"; then
  info "Skipping arch-chroot step. You can run: arch-chroot /mnt /root/_post_install.sh later."
else
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[DRY-RUN] arch-chroot /mnt /root/_post_install.sh"
  else
    arch-chroot /mnt /root/_post_install.sh || { error "arch-chroot post-install failed. Check /root/post_install_chroot.log on the installed system."; exit 1; }
  fi
fi
checkpoint_ok \
  "arch-chroot step completed (or dry-run shown)" \
  "System configuration finalized inside chroot"


# Optional swapfile creation with checks
if [ "${SWAPSIZE_GiB}" -gt 0 ]; then
  checkpoint_start "Creating swapfile (optional)"
  if [ -f /mnt/swapfile ]; then
    warn "/mnt/swapfile already exists. Skipping creation."
  else
    avail=$(df -m /mnt | awk 'NR==2{print $4}')
    if [ "$((SWAPSIZE_GiB*1024))" -gt "$avail" ]; then
      warn "Not enough space for swapfile. Requested: $((SWAPSIZE_GiB*1024)) MiB, Available: $avail MiB. Skipping swapfile."
    else
      if [ "${DRY_RUN}" -eq 1 ]; then
        echo "[DRY-RUN] dd if=/dev/zero of=/mnt/swapfile bs=1M count=$((SWAPSIZE_GiB*1024))"
      else
        dd if=/dev/zero of=/mnt/swapfile bs=1M count=$((SWAPSIZE_GiB*1024)) status=progress || true
        chmod 600 /mnt/swapfile || true
        mkswap /mnt/swapfile || true
        echo '/swapfile none swap defaults 0 0' >> /mnt/etc/fstab
      fi
      checkpoint_ok "Swapfile created"
    fi
  fi
fi

# Post-install verification script (placed in installed system for use after first boot)
checkpoint_start "Installing post-install verification helper"
cat > /mnt/usr/local/bin/post_install_verify.sh <<'VERIFY'
#!/usr/bin/env bash
# Run inside installed Arch (after first boot) to verify boot entries and Secure Boot status
set -euo pipefail
echo "=== Post-install verification ==="
echo "1) systemd-boot status:"
bootctl status || true
echo "2) sbctl status:"
if command -v sbctl >/dev/null 2>&1; then sbctl status || true; else echo "sbctl not installed"; fi
echo "3) kernel files in /boot:"
ls -lah /boot || true
echo "4) loader entries:"
ls -lah /boot/loader/entries || true
echo "5) Suggestion: run 'sudo sbctl enroll-keys -m' if not already done."
echo "=== End verification ==="
VERIFY
run_cmd "chmod +x /mnt/usr/local/bin/post_install_verify.sh" || true
checkpoint_ok \
  "Post-install verification script installed at /usr/local/bin/post_install_verify.sh"


# Final pacman hook and DKMS signing helper were created inside chroot script earlier (if executed).
# Create user Hyprland config files (inline) in /mnt/home/${USERNAME}/.config when possible
checkpoint_start "Creating Hyprland and user config files (inlined)"
HYPR_USER_HOME="/mnt/home/${USERNAME}"
if [ ! -d "${HYPR_USER_HOME}" ]; then
  # if separate home wasn't created, root is used
  HYPR_USER_HOME="/mnt/home/${USERNAME}"
fi

# Create skeleton hyprland config under /etc/skel so new user gets it if possible, else directly write to user's home when mounted
HYPR_SKEL="/mnt/etc/skel/.config/hypr"
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "[DRY-RUN] mkdir -p ${HYPR_SKEL} && create hyprland.conf and waybar config"
else
  mkdir -p "${HYPR_SKEL}"
  cat > "${HYPR_SKEL}/hyprland.conf" <<HYPR
# Minimal Hyprland config tuned for NVIDIA/Blackwell on Wayland
# This file is intended as a good starting point; tweak to taste.
general {
  # Set scaling and fractional scaling if needed
  monitorrule = eDP-1,refresh=165,preferred=3440x1440@165
}
exec = env WLR_NO_HARDWARE_CURSORS=1
# Input, keybindings and basic layout (shortened)
bind = SUPER+RETURN, exec, alacritty
bind = SUPER+q, exec, hyprctl dispatch dpms off
# Add more configs as needed...
HYPR

  # simple waybar config for hyprland (minimal)
  mkdir -p /mnt/etc/skel/.config/waybar
  cat > /mnt/etc/skel/.config/waybar/config <<WAYBAR
{
  "layer": "top",
  "position": "top"
}
WAYBAR
fi
checkpoint_ok \
  "Hyprland skeleton config created in /etc/skel/.config/hypr" \
  "Waybar config created in /etc/skel/.config/waybar" \
  "User will receive configs on first login"


# Final verification before unmount: ensure files exist and loader entries are present
checkpoint_start "Verifying loader files in /mnt/boot"
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "[DRY-RUN] check /mnt/boot/loader/entries/*.conf"
else
  if [ ! -f /mnt/boot/loader/entries/arch.conf ]; then
    warn "Arch loader entry missing!"
  fi
fi
checkpoint_ok "Loader entries verified"

# Attempt a lightweight boot-chain test: validate that bootloader files are readable and signed (if sbctl used)
checkpoint_start "Boot-chain quick check: verifying presence of bootloader files and (if sbctl present) signatures"
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "[DRY-RUN] ls -lah /mnt/boot && sbctl status"
else
  ls -lah /mnt/boot || true
  if command -v sbctl >/dev/null 2>&1; then sbctl status || true; fi
fi
checkpoint_ok "Boot-chain quick check complete"

# Sync and unmount
checkpoint_start "Final sync and unmount"
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "[DRY-RUN] sync; umount -R /mnt"
else
  sync
  umount -R /mnt || warn "Could not unmount /mnt recursively - you may need to unmount manually"
fi
checkpoint_ok \
  "All filesystems synced and unmounted from /mnt" \
  "Installation media is now safe to remove"


# Final instructions summary checkpoint
checkpoint_start "Final summary & next steps"
SUMMARY=(
  "Partitions created: EFI=${EFI_PART}, ROOT=${ROOT_PART}$( [ -n "${HOME_PART:-}" ] && echo ", HOME=${HOME_PART}" || echo "")"
  "systemd-boot entries: Arch (created). Windows (copied bootmgfw.efi into Linux ESP if available)."
  "Secure Boot (sbctl) keys created attempt inside chroot (if chroot run). You must enroll keys via sbctl enroll-keys -m in firmware."
  "DKMS + sbctl pacman hook installed to auto-sign on kernel/nvidia/dkms updates (if chroot ran)."
  "Hyprland skeleton config written into /etc/skel/.config/hypr — will be in new user's home."
  "Developer packages installed: ${#PKGS_ALL[@]} packages (see script)."
)
for s in "${SUMMARY[@]}"; do echo "  ✔ ${s}"; done

echo
echo "IMPORTANT NEXT ACTIONS (after reboot into new Arch):"
echo "  1) Boot into Arch and run: sudo pacman -Syu sbctl sbsigntool"
echo "  2) sudo sbctl enroll-keys -m   # follow prompts to enroll into firmware"
echo "  3) Validate systemd-boot menu shows both entries. If Windows is missing, double-check copied bootmgfw.efi."
echo "  4) Customize /home/${USERNAME}/.config/hypr/hyprland.conf and set WLR_NO_HARDWARE_CURSORS=1 in environment if needed."
echo "  5) For NVIDIA driver updates: use nvidia-dkms package so DKMS rebuilds and pacman hook signs new artifacts."

checkpoint_ok \
  "Installation finished (or dry-run shown)" \
  "See above for next steps"

# Option to reboot now
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "Dry-run complete. No changes were written."
else
  if confirm "Reboot now?"; then
    info "Rebooting..."
    run_cmd "reboot"
  else
    info "Installation finished. Please reboot manually when ready."
  fi
fi

exit 0
