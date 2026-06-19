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

# ==============================================================================
# DECOUPLED TASK FUNCTIONS FOR PROVISIONING (Opeartes via QEMU-NBD)
# ==============================================================================

# TASK FUNCTION: INJECT ROOT PASSWORD
set_root_password() {
    local disk_path="$1"
    local password="$2"
    local mount_point="/mnt/vm_ctl_tmp"

    echo "[*] Preparing host environment for password injection..."
    modprobe nbd max_part=8 2>/dev/null
    local nbd_dev="/dev/nbd0"
    
    qemu-nbd --connect="${nbd_dev}" "${disk_path}"
    sleep 1

    local root_partition=$(lsblk -lnp -o NAME,TYPE "${nbd_dev}" | awk '$2=="part" {print $1}' | tail -n 1)
    if [ -z "$root_partition" ]; then
        echo "[!] Error: No partitions detected inside the virtual disk."
        qemu-nbd --disconnect "${nbd_dev}"
        return 1
    fi

    echo "[*] Mounting root partition (${root_partition}) to ${mount_point}..."
    mkdir -p "${mount_point}"
    mount "${root_partition}" "${mount_point}"

    echo "[*] Injecting root password..."
    echo "root:${password}" | chroot "${mount_point}" chpasswd

    echo "[*] Synchronizing filesystem changes and releasing block device..."
    sync
    umount "${mount_point}"
    qemu-nbd --disconnect "${nbd_dev}"
    rmdir "${mount_point}"

    echo "[+] Root password set successfully!"
}

# TASK FUNCTION: DISABLE CLOUD-INIT
disable_cloud_init() {
    local disk_path="$1"
    local mount_point="/mnt/vm_ctl_tmp"

    echo "[*] Preparing host environment for cloud-init deactivation..."
    modprobe nbd max_part=8 2>/dev/null
    local nbd_dev="/dev/nbd0"
    
    qemu-nbd --connect="${nbd_dev}" "${disk_path}"
    sleep 1

    local root_partition=$(lsblk -lnp -o NAME,TYPE "${nbd_dev}" | awk '$2=="part" {print $1}' | tail -n 1)
    if [ -z "$root_partition" ]; then
        echo "[!] Error: No partitions detected inside the virtual disk."
        qemu-nbd --disconnect "${nbd_dev}"
        return 1
    fi

    echo "[*] Mounting root partition (${root_partition}) to ${mount_point}..."
    mkdir -p "${mount_point}"
    mount "${root_partition}" "${mount_point}"

    echo "[*] Neutralizing cloud-init infrastructure components..."
    
    # 1. Mask the services (Standard systemd block)
    chroot "${mount_point}" systemctl mask cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service 2>/dev/null
    
    # 2. Tell the internal engine to stay disabled
    touch "${mount_point}/etc/cloud/cloud-init.disabled" 2>/dev/null
    
    # 3. Disable the dynamic systemd generators (This stops it from bypassing the masks)
    rm -f "${mount_point}/lib/systemd/system-generators/cloud-init-generator" 2>/dev/null
    rm -f "${mount_point}/usr/lib/systemd/system-generators/cloud-init-generator" 2>/dev/null

    # 4. Write a kernel cmdline override to completely bypass cloud-init initramfs detection
    mkdir -p "${mount_point}/etc/cloud/cloud.cfg.d"
    echo "cloud-init: '{config: {disabled: true}}'" > "${mount_point}/etc/cloud/cloud.cfg.d/99-disable.cfg"

    echo "[*] Synchronizing filesystem changes and releasing block device..."
    sync
    umount "${mount_point}"
    qemu-nbd --disconnect "${nbd_dev}"
    rmdir "${mount_point}"

    echo "[+] cloud-init disabled successfully!"
}

# --- Parse Command Line Arguments ---
if [[ "$1" == "start" || "$1" == "stop" || "$1" == "status" || "$1" == "connect" || "$1" == "destroy" || "$1" == "set" ]]; then
    ACTION="$1"
    shift
else
    echo "Usage: $0 {start|stop|status|connect|destroy|set} [options]"
    echo "Options for lifecycle: --name NAME | --ram MB | --cpus INT | --iso PATH_TO_ISO | --snapshot"
    echo "Options for set:       --name NAME {--root-pass PASSWORD | --disable-cloud-init}"
    exit 1
fi

# ==============================================================================
# COMMAND PROCESSING: SUB-PARSER FOR "SET" ACTION
# ==============================================================================
if [ "$ACTION" == "set" ]; then
    ROOT_PASSWORD=""
    DISABLE_CLOUD_INIT=false
    OP_COUNT=0

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --name)               VM_NAME="$2"; shift 2 ;;
            --root-pass)          ROOT_PASSWORD="$2"; OP_COUNT=$((OP_COUNT + 1)); shift 2 ;;
            --disable-cloud-init) DISABLE_CLOUD_INIT=true; OP_COUNT=$((OP_COUNT + 1)); shift 1 ;;
            *) echo "[!] Error: Unknown option $1 for set command."; exit 1 ;;
        esac
    done

    # Strict Validations for Target Operations
    if [ -z "$VM_NAME" ]; then
        echo "[!] Error: --name is required."
        exit 1
    fi

    if [ "$OP_COUNT" -eq 0 ]; then
        echo "[!] Error: No operation flag specified. You must provide either --root-pass or --disable-cloud-init."
        exit 1
    fi

    if [ "$OP_COUNT" -gt 1 ]; then
        echo "[!] Error: Multiple operations detected. Please run only one configuration change at a time."
        exit 1
    fi

    DISK_IMG="./storage/${VM_NAME}.qcow2"
    if [ ! -f "$DISK_IMG" ]; then
        echo "[!] Error: Virtual disk not found at $DISK_IMG"
        exit 1
    fi

    # Check execution profile context to preserve disk integrity
    if pgrep -f "qemu-system-aarch64.*-name $VM_NAME" > /dev/null; then
        echo "[!] Error: VM '${VM_NAME}' is currently running. Please stop it before modifying the disk."
        exit 1
    fi

    # Dispatch to specific tasks
    if [ -n "$ROOT_PASSWORD" ]; then
        set_root_password "$DISK_IMG" "$ROOT_PASSWORD"
    elif [ "$DISABLE_CLOUD_INIT" = true ]; then
        disable_cloud_init "$DISK_IMG"
    fi

    exit 0
fi

# --- Standard Lifecycle Argument Processing ---
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
# ACTION: STATUS
# ==============================================================================
if [ "$ACTION" == "status" ]; then
    echo "========================================================================================================="
    echo "                                   QEMU/KVM Virtual Machine Inventory                                    "
    echo "========================================================================================================="
    
    STORAGE_DIR="./storage"
    
    if [ ! -d "$STORAGE_DIR" ] || [ -z "$(ls ${STORAGE_DIR}/*.qcow2 2>/dev/null)" ]; then
        echo "No virtual machines have been created yet (no disks found in $STORAGE_DIR)."
        echo "========================================================================================================="
        exit 0
    fi

    printf "%-22s %-12s %-10s %-12s %-30s\n" "VM NAME" "STATUS" "PID" "RESOURCES" "DISK PATH"
    echo "---------------------------------------------------------------------------------------------------------"
    
    for disk in "${STORAGE_DIR}"/*.qcow2; do
        name=$(basename "$disk" .qcow2)
        
        QMP_SOCKET="/tmp/qmp-${name}.sock"
        pid=$(pgrep -f "qemu-system-aarch64.*-name $name" | head -n 1)

        if [ -n "$pid" ] && [ -S "$QMP_SOCKET" ]; then
            printf "%-22s \e[32m%-12s\e[0m %-10s %-12s %-30s\n" "$name" "RUNNING" "$pid" "Active" "$disk"
        else
            if [ -S "$QMP_SOCKET" ] || [ -S "/tmp/monitor-${name}.sock" ]; then
                rm -f "/tmp/qmp-${name}.sock" "/tmp/monitor-${name}.sock"
            fi
            printf "%-22s \e[31m%-12s\e[0m %-10s %-12s %-30s\n" "$name" "STOPPED" "OFF" "Disk Staged" "$disk"
        fi
    done
    echo "========================================================================================================="
    exit 0
fi

# --- Enforce Mandatory VM Name for START, STOP and CONNECT actions ---
if [[ "$ACTION" == "start" || "$ACTION" == "stop" || "$ACTION" == "connect" ]]; then
    if [ -z "$VM_NAME" ]; then
        echo "ERROR: The --name parameter is mandatory for '$ACTION' action."
        echo "Example: vm-ctl $ACTION --name alpine-server"
        exit 1
    fi
fi

# --- Dynamically Resolve Operational Routes based on VM_NAME ---
DISK_IMG="./storage/${VM_NAME}.qcow2"
QMP_SOCKET="/tmp/qmp-${VM_NAME}.sock"
MON_SOCKET="/tmp/monitor-${VM_NAME}.sock"
SERIAL_SOCKET="/tmp/serial-${VM_NAME}.sock"

# ==============================================================================
# ACTION: CONNECT
# ==============================================================================
if [ "$ACTION" == "connect" ]; then
    pid=$(pgrep -f "qemu-system-aarch64.*-name $VM_NAME" | head -n 1)
    if [ -z "$pid" ] || [ ! -S "$QMP_SOCKET" ]; then
        echo "ERROR: VM '$VM_NAME' is not running."
        echo "Please start it first using: vm-ctl start --name $VM_NAME"
        exit 1
    fi

    if [ ! -S "$SERIAL_SOCKET" ]; then
        echo "ERROR: Serial interface socket not found at $SERIAL_SOCKET"
        exit 1
    fi

    echo "Connecting to serial console of VM: $VM_NAME..."
    echo "Escape character is 'Ctrl + O' (returns control back to host)"
    echo "----------------------------------------------------------------------"
    sleep 1

    socat -,raw,echo=0,escape=0x0f UNIX-CONNECT:"$SERIAL_SOCKET"
    
    echo -e "\n----------------------------------------------------------------------"
    echo "Disconnected from VM: $VM_NAME console stream."
    exit 0
fi

# ==============================================================================
# ACTION: DESTROY
# ==============================================================================
if [ "$ACTION" == "destroy" ]; then
    pid=$(pgrep -f "qemu-system-aarch64.*-name $VM_NAME" | head -n 1)
    if [ -n "$pid" ]; then
        echo "ERROR: VM '$VM_NAME' is currently RUNNING (PID: $pid)."
        echo "Please stop the virtual machine before destroying it: vm-ctl stop --name $VM_NAME"
        exit 1
    fi

    if [ ! -f "$DISK_IMG" ]; then
        echo "ERROR: No staged disk found for '$VM_NAME' at $DISK_IMG"
        exit 1
    fi

    echo -e "\e[31m⚠️  WARNING: You are about to permanently DELETE the VM '$VM_NAME' and all its data.\e[0m"
    read -p "Are you absolutely sure you want to proceed? (type 'yes' to confirm): " CONFIRM
    
    if [ "$CONFIRM" != "yes" ]; then
        echo "Destruction aborted. Your virtual machine remains intact."
        exit 0
    fi

    echo "Purging resources for VM: $VM_NAME..."
    rm -f "$QMP_SOCKET" "$MON_SOCKET" "/tmp/serial-${VM_NAME}.sock"
    rm -f "$DISK_IMG"
    
    echo -e "\e[32m✔ Success:\e[0m Virtual machine '$VM_NAME' and its storage assets have been completely destroyed."
    exit 0
fi

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
    echo "Please create the qcow2 image first using:"
    echo "  qemu-img create -f qcow2 $DISK_IMG 20G"
    exit 1
fi

UEFI_FW="/usr/share/AAVMF/AAVMF_CODE.fd"
if [ ! -f "$UEFI_FW" ]; then
    echo "ERROR: UEFI firmware not found at $UEFI_FW. Run: sudo apt install qemu-efi-aarch64"
    exit 1
fi

QEMU_ARGS=(
    -enable-kvm
    -machine virt
    -name "$VM_NAME"
    -m "$RAM"
    -smp "$CPUS"
    -cpu host
    -drive "if=pflash,format=raw,readonly=on,file=$UEFI_FW"
    -drive "file=$DISK_IMG,format=qcow2,if=virtio"
    -netdev user,id=vnet0
    -device virtio-net-pci,netdev=vnet0
    -qmp "unix:$QMP_SOCKET,server,nowait"
    -monitor "unix:$MON_SOCKET,server,nowait"
    -vga none
    -display none
    -serial "unix:$SERIAL_SOCKET,server,nowait"
    -daemonize
)

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
    echo "Connect to console via: vm-ctl connect --name $VM_NAME"
else
    echo "ERROR: QEMU AArch64 process failed to initialize properly."
fi