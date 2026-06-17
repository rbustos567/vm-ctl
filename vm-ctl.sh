#!/usr/bin/env bash

# ==============================================================================
# QEMU/KVM VM Orchestration Script (ISO Boot & UEFI Edition)
# ==============================================================================

ACTION=""
VM_NAME="" # Left empty to enforce mandatory user input
RAM="2048"
CPUS="2"
ISO_IMG=""
SNAPSHOT=false

# --- Parse Command Line Arguments ---
if [[ "$1" == "start" || "$1" == "stop" || "$1" == "status" ]]; then
    ACTION="$1"
    shift
else
    echo "Usage: $0 {start|stop|status} [options]"
    echo "Options: --name NAME | --ram MB | --cpus INT | --iso PATH_TO_ISO | --snapshot"
    exit 1
fi

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --name)     VM_NAME="$2"; shift ;;
        --ram)      RAM="$2"; shift ;;
        --cpus)     CPUS="$2"; shift ;;
        --iso)      ISO_IMG="$2"; shift ;;
        --snapshot) SNAPSHOT=true ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# ==============================================================================
# ACTION: STATUS (Scans storage inventory and runtime sockets)
# ==============================================================================
if [ "$ACTION" == "status" ]; then
    echo "======================================================================"
    echo "                 QEMU/KVM Virtual Machine Inventory                   "
    echo "======================================================================"
    
    STORAGE_DIR="./storage"
    
    # Check if storage directory exists or contains any qcow2 images
    if [ ! -d "$STORAGE_DIR" ] || [ -z "$(ls ${STORAGE_DIR}/*.qcow2 2>/dev/null)" ]; then
        echo "No virtual machines have been created yet (no disks found in $STORAGE_DIR)."
        echo "======================================================================"
        exit 0
    fi

    printf "%-25s %-12s %-10s %-15s\n" "VM NAME" "STATUS" "PID" "RESOURCES"
    echo "----------------------------------------------------------------------"
    
    # Iterate through all configured virtual disks in our inventory
    for disk in "${STORAGE_DIR}"/*.qcow2; do
        # Extract the VM name from the file name (e.g., ./storage/alpine.qcow2 -> alpine)
        name=$(basename "$disk" .qcow2)
        
        QMP_SOCKET="/tmp/qmp-${name}.sock"
        pid=$(pgrep -f "name $name" | head -n 1)

        if [ -n "$pid" ] && [ -S "$QMP_SOCKET" ]; then
            # The VM has an active process and control socket
            printf "%-25s \e[32m%-12s\e[0m %-10s %-15s\n" "$name" "RUNNING" "$pid" "Active"
        else
            # The process is dead, but let's check for left-over/stale sockets to clean up
            if [ -S "$QMP_SOCKET" ] || [ -S "/tmp/monitor-${name}.sock" ]; then
                rm -f "/tmp/qmp-${name}.sock" "/tmp/monitor-${name}.sock"
            fi
            # The VM is registered in storage but not actively executing
            printf "%-25s \e[31m%-12s\e[0m %-10s %-15s\n" "$name" "STOPPED" "OFF" "Disk Staged"
        fi
    done
    echo "======================================================================"
    exit 0
fi

# --- Enforce Mandatory VM Name for START and STOP actions ---
if [ -z "$VM_NAME" ]; then
    echo "ERROR: The --name parameter is mandatory for '$ACTION' action."
    echo "Example: vm-ctl $ACTION --name alpine-server"
    exit 1
fi

# --- Dynamically Resolve Operational Routes based on VM_NAME ---
DISK_IMG="./storage/${VM_NAME}.qcow2"
QMP_SOCKET="/tmp/qmp-${VM_NAME}.sock"
MON_SOCKET="/tmp/monitor-${VM_NAME}.sock"

# ==============================================================================
# ACTION: STOP
# ==============================================================================
if [ "$ACTION" == "stop" ]; then
    echo "Attempting graceful shutdown for VM: $VM_NAME..."
    if [ ! -S "$QMP_SOCKET" ]; then
        echo "ERROR: Control socket not found at $QMP_SOCKET. Is the VM actually running?"
        exit 1
    fi
    (
        echo '{ "execute": "qmp_capabilities" }'
        sleep 0.1
        echo '{ "execute": "system_powerdown" }'
    ) | socat - UNIX-CONNECT:"$QMP_SOCKET" > /dev/null

    echo "Waiting for guest OS to power down cleanly..."
    TIMEOUT=15
    while [ $TIMEOUT -gt 0 ]; do
        if [ ! -S "$QMP_SOCKET" ]; then
            echo "VM '$VM_NAME' has shut down cleanly."
            exit 0
        fi
        sleep 1
        ((TIMEOUT--))
    done

    if [ -S "$QMP_SOCKET" ]; then
        echo "VM did not respond. Executing hard power-off (SIGKILL)..."
        pkill -9 -f "name $VM_NAME"
        rm -f "$QMP_SOCKET" "$MON_SOCKET"
        echo "VM '$VM_NAME' forced to stop and resources cleared."
    fi
    exit 0
fi

# ==============================================================================
# ACTION: START
# ==============================================================================
if [ ! -e /dev/kvm ]; then
    echo "ERROR: /dev/kvm does not exist. Hardware acceleration unavailable."
    exit 1
fi

if [ ! -f "$DISK_IMG" ]; then
    echo "ERROR: Storage disk image not found at target location: $DISK_IMG"
    echo "Please create the qcow2 image first using: qemu-img create -f qcow2 $DISK_IMG 20G"
    exit 1
fi

# Path to the standard AArch64 UEFI firmware on Debian/Ubuntu hosts
UEFI_FW="/usr/share/AAVMF/AAVMF_CODE.fd"
if [ ! -f "$UEFI_FW" ]; then
    echo "ERROR: UEFI firmware not found at $UEFI_FW. Run: sudo apt install qemu-efi-aarch64"
    exit 1
fi

# Base QEMU arguments
QEMU_ARGS=(
    -enable-kvm
    -machine virt
    -name "$VM_NAME"
    -m "$RAM"
    -smp "$CPUS"
    -cpu host
    
    # --- UEFI Firmware Mapping ---
    -drive "if=pflash,format=raw,readonly=on,file=$UEFI_FW"
    
    # --- Main Storage System ---
    -drive "file=$DISK_IMG,format=qcow2,if=virtio"
    
    # --- Networking Stack ---
    -netdev user,id=vnet0
    -device virtio-net-pci,netdev=vnet0
    
    # --- Instrumentation ---
    -qmp "unix:$QMP_SOCKET,server,nowait"
    -monitor "unix:$MON_SOCKET,server,nowait"
    
    # --- Headless Execution Context ---
    -vga none
    -display none
    
    # Virtual serial port configuration
    -serial "unix:/tmp/serial-${VM_NAME}.sock,server,nowait"
    
    -daemonize
)

# --- Conditional CD-ROM/ISO Mapping ---
if [ -n "$ISO_IMG" ]; then
    if [ ! -f "$ISO_IMG" ]; then
        echo "ERROR: ISO image not found at $ISO_IMG"
        exit 1
    fi
    QEMU_ARGS+=(-device virtio-scsi-pci -drive "file=$ISO_IMG,media=cdrom,if=none,id=cd0" -device scsi-cd,drive=cd0)
    echo "ISO attached: $ISO_IMG"
fi

if [ "$SNAPSHOT" = true ]; then
    QEMU_ARGS+=(-snapshot)
    echo "WARNING: Running in SNAPSHOT mode. Data changes will be discarded on stop."
fi

echo "Launching native ARM64 virtual machine: $VM_NAME..."
qemu-system-aarch64 "${QEMU_ARGS[@]}"

if [ $? -eq 0 ]; then
    echo "VM '$VM_NAME' successfully initialized with KVM acceleration."
    echo "Control socket exposed at: $QMP_SOCKET"
    echo "Connect to console via: socat -,raw,echo=0 UNIX-CONNECT:/tmp/serial-${VM_NAME}.sock"
else
    echo "ERROR: QEMU AArch64 process failed to initialize properly."
fi