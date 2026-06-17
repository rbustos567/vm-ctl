#!/usr/bin/env bash

# ==============================================================================
#  Installer for vm-ctl Framework
# ==============================================================================

set -euo pipefail

# --- Path Configuration ---
INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="vm-ctl.sh"
TARGET_NAME="vm-ctl"
STORAGE_DIR="./storage"
ISOS_DIR="./isos"

# Output colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Initializing vm-ctl installation ===${NC}"

# 1. Privilege Validation
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root (sudo).${NC}"
    exit 1
fi

# 2. Check Critical Host Binary Dependencies
echo -e "\n${BLUE}[1/4] Verifying system binary dependencies...${NC}"
DEPENDENCIES=(qemu-system-aarch64 qemu-img socat curl)
for cmd in "${DEPENDENCIES[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${RED}⚠️  Missing binary dependency: $cmd${NC}"
        echo -e "Please install the required packages using your distribution's package manager."
        echo -e "Example for Debian/Ubuntu/Armbian:"
        echo -e "  ${BLUE}apt install qemu-system-arm qemu-utils qemu-efi-aarch64 socat curl${NC}"
        exit 1
    else
        echo -e "  [✓] $cmd is installed."
    fi
done

# 3. Create Local Directory Structure for the Lab
echo -e "\n${BLUE}[2/4] Creating local storage structure...${NC}"
mkdir -p "$STORAGE_DIR" "$ISOS_DIR"
echo "  [✓] Directories created: $STORAGE_DIR, $ISOS_DIR"

# 4. Ensure ARM64 UEFI Firmware Presence (Provided by qemu-efi-aarch64)
echo -e "\n${BLUE}[3/4] Verifying UEFI firmware (qemu-efi-aarch64)...${NC}"
UEFI_PATH="/usr/share/AAVMF/AAVMF_CODE.fd"
if [[ ! -f "$UEFI_PATH" ]]; then
    echo -e "⚠️  UEFI firmware file NOT found at $UEFI_PATH."
    echo -e "This usually means 'qemu-efi-aarch64' is missing or installed in a non-standard path."
    echo -e "Attempting to download a standalone copy for fallback compatibility..."
    mkdir -p "/usr/share/AAVMF"
    
    # Direct download from verified snapshot backup as safe fallback
    curl -L -o "$UEFI_PATH" "https://github.com/snapshots/AAVMF_CODE.fd/raw/main/AAVMF_CODE.fd" || {
        echo -e "${RED}Error: Failed to automatically download UEFI firmware.${NC}"
        echo -e "Please run: ${BLUE}apt install qemu-efi-aarch64${NC} manually to fix this layout."
        exit 1
    }
    echo -e "${GREEN}  [✓] UEFI firmware successfully deployed via backup stream.${NC}"
else
    echo "  [✓] UEFI firmware successfully verified (provided by qemu-efi-aarch64)."
fi

# 5. Install the Script into the Global System PATH
echo -e "\n${BLUE}[4/4] Installing global binary...${NC}"
if [[ -f "$SCRIPT_NAME" ]]; then
    cp "$SCRIPT_NAME" "$INSTALL_DIR/$TARGET_NAME"
    chmod +x "$INSTALL_DIR/$TARGET_NAME"
    echo -e "${GREEN}  [✓] Script copied to $INSTALL_DIR/$TARGET_NAME with execution permissions.${NC}"
else
    echo -e "${RED}Critical error: '$SCRIPT_NAME' not found in the current directory.${NC}"
    exit 1
fi

# Installation Completed Successfully
echo -e "\n${GREEN}======================================================${NC}"
echo -e "${GREEN}       vm-ctl installation completed successfully!${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e "You can now run the command globally from any directory:"
echo -e "  ${BLUE}vm-ctl start --name lab-instance --ram 1024${NC}\n"
