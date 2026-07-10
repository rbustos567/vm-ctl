#!/usr/bin/env bash

# ==============================================================================
#  Installer for vm-ctl Framework (Dynamic Debian/Fedora & ARM64/x86_64 Edition)
# ==============================================================================

set -euo pipefail

# --- Path Configuration ---
INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="vm-ctl.sh"
TARGET_NAME="vm-ctl"
STORAGE_DIR="./storage"
ISOS_DIR="./isos"

# --- Output Colors ---
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Initializing native vm-ctl installation ===${NC}"

# 1. Privilege Validation
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root (sudo).${NC}"
    exit 1
fi

# --- Host Environment Detection ---
HOST_ARCH=$(uname -m)
PKG_MANAGER=""

if command -v dnf &> /dev/null; then
    PKG_MANAGER="fedora"
elif command -v apt-get &> /dev/null; then
    PKG_MANAGER="debian"
fi

echo -e "[*] Detected Host Architecture: ${BLUE}${HOST_ARCH}${NC}"
echo -e "[*] Detected Distribution Base: ${BLUE}${PKG_MANAGER:-Unknown}${NC}"

# 2. Check Critical Host Binary Dependencies
echo -e "\n${BLUE}[1/4] Verifying system binary dependencies...${NC}"

# Dynamically map the native execution binary based on host architecture
QEMU_NATIVE="qemu-system-aarch64"
if [[ "$HOST_ARCH" == "x86_64" ]]; then
    QEMU_NATIVE="qemu-system-x86_64"
fi

DEPENDENCIES=("$QEMU_NATIVE" qemu-img socat curl)
MISSING_DEPS=()

for cmd in "${DEPENDENCIES[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${RED}⚠️  Missing binary dependency: $cmd${NC}"
        MISSING_DEPS+=("$cmd")
    else
        echo -e "  [✓] $cmd is installed."
    fi
done

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    echo -e "\n${RED}Critical dependencies missing. Please install the required packages:${NC}"
    if [[ "$PKG_MANAGER" == "fedora" ]]; then
        echo -e "Run on your x86_64 system:\n  ${BLUE}dnf install qemu-kvm qemu-img edk2-ovmf socat curl${NC}"
    else
        echo -e "Run on your aarch64 system:\n  ${BLUE}apt install qemu-system-arm qemu-utils qemu-efi-aarch64 socat curl${NC}"
    fi
    exit 1
fi

# 3. Create Local Directory Structure for the Lab
echo -e "\n${BLUE}[2/4] Creating local storage structure...${NC}"
mkdir -p "$STORAGE_DIR" "$ISOS_DIR"
echo "  [✓] Directories verified: $STORAGE_DIR, $ISOS_DIR"

# 4. Ensure Native UEFI Firmware Presence
echo -e "\n${BLUE}[3/4] Verifying native UEFI firmware engine...${NC}"

# Resolve the native firmware path depending on the combination of Host Arch and Distro Base
NATIVE_UEFI=""
PKG_TO_INSTALL=""

if [[ "$HOST_ARCH" == "x86_64" ]]; then
    if [[ "$PKG_MANAGER" == "fedora" ]]; then
        NATIVE_UEFI="/usr/share/edk2/ovmf/OVMF_CODE.fd"
        PKG_TO_INSTALL="edk2-ovmf"
    else
        NATIVE_UEFI="/usr/share/OVMF/OVMF_CODE.fd"
        PKG_TO_INSTALL="ovmf"
    fi
elif [[ "$HOST_ARCH" == "aarch64" ]]; then
    if [[ "$PKG_MANAGER" == "fedora" ]]; then
        NATIVE_UEFI="/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw"
        PKG_TO_INSTALL="edk2-aarch64"
    else
        NATIVE_UEFI="/usr/share/AAVMF/AAVMF_CODE.fd"
        PKG_TO_INSTALL="qemu-efi-aarch64"
    fi
fi

# Validate target path or auto-install if missing
if [[ -n "$NATIVE_UEFI" && -f "$NATIVE_UEFI" ]]; then
    echo -e "  [✓] Native ${HOST_ARCH} UEFI firmware verified at: $NATIVE_UEFI"
else
    echo -e "⚠️  Native UEFI firmware missing. Attempting automatic installation of: ${BLUE}${PKG_TO_INSTALL}${NC}..."
    
    if [[ "$PKG_MANAGER" == "fedora" ]]; then
        dnf install -y "$PKG_TO_INSTALL"
    elif [[ "$PKG_MANAGER" == "debian" ]]; then
        apt-get update -y && apt-get install -y "$PKG_TO_INSTALL"
    else
        echo -e "${RED}ERROR: Package manager not supported for auto-installation. Please install ${PKG_TO_INSTALL} manually.${NC}"
        exit 1
    fi

    # Double check after package manager execution
    if [[ -f "$NATIVE_UEFI" ]]; then
        echo -e "${GREEN}  [✓] Native UEFI firmware successfully installed and verified!${NC}"
    else
        # Emergency standalone fallback download only for ARM64 on Debian layout if package paths mismatch
        if [[ "$HOST_ARCH" == "aarch64" && "$PKG_MANAGER" == "debian" ]]; then
            echo -e "[*] Path mismatch detected. Deploying emergency standalone fallback..."
            mkdir -p "$(dirname "$NATIVE_UEFI")"
            curl -L -o "$NATIVE_UEFI" "https://github.com/snapshots/AAVMF_CODE.fd/raw/main/AAVMF_CODE.fd" && echo -e "${GREEN}  [✓] Standalone firmware deployed.${NC}" && exit 0
        fi
        echo -e "${RED}ERROR: Firmware package installed but binary footprint not found at: ${NATIVE_UEFI}${NC}"
        exit 1
    fi
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
