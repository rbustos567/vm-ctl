#!/usr/bin/env bash

# ==============================================================================
# QEMU/KVM VM Orchestration Script (Dynamic Cross-Platform Edition)
# ==============================================================================

ACTION=""
VM_NAME="" # Left empty to enforce mandatory user input
RAM="2048"
CPUS="2"
ISO_IMG=""
SNAPSHOT=false

# --- HOST ENVIRONMENT DETECTION ---
HOST_ARCH=$(uname -m)
PKG_MANAGER="debian"
if command -v dnf &> /dev/null; then PKG_MANAGER="fedora"; fi

# ==============================================================================
# DECOUPLED TASK FUNCTIONS FOR PROVISIONING (Operates via QEMU-NBD)
# ==============================================================================

# --- HOST INFRASTRUCTURE VALIDATION ---
ensure_host_bridge() {
    local bridge_name="vm-ctl-br"
    local phys_interface
    
    phys_interface=$(ip route show default | awk '/default/ {print $5}' | head -n 1)
    if [ -z "$phys_interface" ]; then
        echo "[ERROR] No active internet-facing network interface detected on the host."
        return 1
    fi

    if ip link show "$bridge_name" >/dev/null 2>&1; then
        return 0
    fi

    echo "[*] Active host uplink discovered: ${phys_interface}"
    echo "[*] Initializing dedicated network infrastructure: ${bridge_name}..."

    if [ "$EUID" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        echo "[ERROR] Root privileges or sudo required to provision the host network layer."
        return 1
    fi

    local sudo_cmd=""
    [ "$EUID" -ne 0 ] && sudo_cmd="sudo"

    $sudo_cmd ip link add name "$bridge_name" type bridge
    $sudo_cmd ip link set "$phys_interface" master "$bridge_name"
    $sudo_cmd ip link set "$bridge_name" up
    $sudo_cmd ip link set "$phys_interface" up
    
    echo "[*] Migrating host IP footprints via DHCP..."
    $sudo_cmd dhclient "$bridge_name"

    if [ ! -f /etc/qemu/bridge.conf ] || ! grep -q "allow $bridge_name" /etc/qemu/bridge.conf; then
        $sudo_cmd mkdir -p /etc/qemu
        echo "allow $bridge_name" | $sudo_cmd tee -a /etc/qemu/bridge.conf >/dev/null
        $sudo_cmd chmod 0644 /etc/qemu/bridge.conf
    fi
    
    echo "[SUCCESS] Host network runtime patched. Bridge ${bridge_name} is active on ${phys_interface}."
}

# TASK FUNCTION: INJECT STATIC NETWORK CONFIGURATION (OFFLINE MODE)
set_static_ip() {
    local target_vm_name="$1"
    local requested_ip="$2"
    local requested_gateway="$3"
    local requested_dns="$4"
    local mount_point="/mnt/vm_ctl_tmp"

    if [ -z "$target_vm_name" ] || [ -z "$requested_ip" ]; then
        echo "[ERROR] Missing required parameters. Usage: set_static_ip <vm_name> <ip_address> [gateway] [dns]"
        return 1
    fi

    if [[ "$requested_ip" != */* ]]; then
        echo "[*] No CIDR prefix specified. Appending /24 by default."
        requested_ip="${requested_ip}/24"
    fi

    if [ -z "$requested_dns" ]; then
        requested_dns="1.1.1.1"
    fi

    if [ -z "$requested_gateway" ]; then
        local raw_ip_address
        raw_ip_address=$(echo "$requested_ip" | cut -d'/' -f1)
        requested_gateway=$(echo "$raw_ip_address" | awk -F. '{print $1"."$2"."$3".1"}')
        echo "[*] No gateway provided. Inferred network gateway: ${requested_gateway}"
    fi

    echo "[*] Injecting static network configuration into '${target_vm_name}':"
    echo "    IP/CIDR: $requested_ip"
    echo "    Gateway: $requested_gateway"
    echo "    DNS    : $requested_dns"

    if [ -d "${mount_point}/etc/netplan" ]; then
        echo "[*] Target layout detected: Netplan"
        local timestamp
        timestamp=$(date +"%Y%m%d_%H%M%S")

        for original_file in "${mount_point}/etc/netplan/"*.yaml; do
            if [ -f "$original_file" ]; then
                local backup_name="${original_file}.bak_${timestamp}"
                echo "[*] Backing up original config: $(basename "$original_file") -> $(basename "$backup_name")"
                cp "$original_file" "$backup_name"
            fi
        done
        
        rm -f "${mount_point}/etc/netplan/"*.yaml
        
        cat <<EOF > "${mount_point}/etc/netplan/50-cloud-init.yaml"
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: no
      addresses:
        - ${requested_ip}
      routes:
        - to: default
          via: ${requested_gateway}
      nameservers:
        addresses: [${requested_dns}]
EOF
        chmod 600 "${mount_point}/etc/netplan/50-cloud-init.yaml"
        echo "[SUCCESS] Netplan static profile injected into 50-cloud-init.yaml."

    elif [ -d "${mount_point}/etc/network" ]; then
        echo "[*] Target layout detected: ifupdown (Debian/Alpine style)"
        mkdir -p "${mount_point}/etc/network/interfaces.d"
        
        if [ ! -f "${mount_point}/etc/network/interfaces" ]; then
            echo "[*] Main interfaces file missing. Creating fallback definition."
            cat <<EOF > "${mount_point}/etc/network/interfaces"
# This file is auto-generated by vm-ctl
auto lo
iface lo inet loopback

source /etc/network/interfaces.d/*
EOF
        fi
        
        cat <<EOF > "${mount_point}/etc/network/interfaces.d/eth0"
auto eth0
iface eth0 inet static
    address ${requested_ip}
    gateway ${requested_gateway}
    dns-nameservers ${requested_dns}
EOF
        echo "[SUCCESS] Debian/Alpine network interfaces configuration injected."

    elif [ -d "${mount_point}/etc/NetworkManager/system-connections" ]; then
        echo "[*] Target layout detected: NetworkManager KeyFile (RHEL/Fedora style)"
        
        cat <<EOF > "${mount_point}/etc/NetworkManager/system-connections/eth0.nmconnection"
[connection]
id=eth0
type=ethernet
interface-name=eth0

[ethernet]

[ipv4]
address1=${requested_ip},${requested_gateway}
dns=${requested_dns};
method=manual

[ipv6]
method=disabled
EOF
        chmod 600 "${mount_point}/etc/NetworkManager/system-connections/eth0.nmconnection"
        echo "[SUCCESS] NetworkManager connection profile successfully generated."

    else
        echo "[WARN] Unsupported or unrecognized network management layout. Host file changes skipped."
        return 1
    fi

    return 0
}

# --- Parse Command Line Arguments ---
if [[ "$1" == "start" || "$1" == "stop" || "$1" == "status" || "$1" == "connect" || "$1" == "destroy" || "$1" == "set" ]]; then
    ACTION="$1"
    shift
else
    echo "Usage: $0 {start|stop|status|connect|destroy|set} [options]"
    echo "Options for lifecycle: --name NAME | --ram MB | --cpus INT | --iso PATH_TO_ISO | --snapshot"
    echo "Options for set:       --name NAME {--root-pass PASSWORD | --disable-cloud-init | --static-ip IP [/MASK] [--gateway GW] [--dns DNS]}"
    exit 1
fi

# ==============================================================================
# COMMAND PROCESSING: SUB-PARSER FOR "SET" ACTION
# ==============================================================================
if [ "$ACTION" == "set" ]; then
    ROOT_PASSWORD=""
    DISABLE_CLOUD_INIT=false
    STATIC_IP=""
    GATEWAY=""
    DNS=""
    OP_COUNT=0

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --name)               VM_NAME="$2"; shift 2 ;;
            --root-pass)          ROOT_PASSWORD="$2"; OP_COUNT=$((OP_COUNT + 1)); shift 2 ;;
            --disable-cloud-init) DISABLE_CLOUD_INIT=true; OP_COUNT=$((OP_COUNT + 1)); shift 1 ;;
            --static-ip)          STATIC_IP="$2"; OP_COUNT=$((OP_COUNT + 1)); shift 2 ;;
            --gateway)            GATEWAY="$2"; shift 2 ;;
            --dns)                DNS="$2"; shift 2 ;;
            *) echo "[!] Error: Unknown option $1 for set command."; exit 1 ;;
        esac
    done

    if [ -z "$VM_NAME" ]; then echo "[!] Error: --name is required."; exit 1; fi
    if [ "$OP_COUNT" -eq 0 ]; then echo "[!] Error: No operation flag specified."; exit 1; fi
    if [ "$OP_COUNT" -gt 1 ]; then echo "[!] Error: Multiple operations detected."; exit 1; fi

    DISK_IMG="./storage/${VM_NAME}.qcow2"
    if [ ! -f "$DISK_IMG" ]; then echo "[!] Error: Virtual disk not found at $DISK_IMG"; exit 1; fi

    # Agnostic process detection using the dynamic name parameter pattern
    if pgrep -f "qemu-system-.*-name $VM_NAME" > /dev/null; then
        echo "[!] Error: VM '${VM_NAME}' is currently running. Please stop it before modifying the disk."
        exit 1
    fi

    MOUNT_POINT="/mnt/vm_ctl_tmp"
    echo "[*] Initializing shared loopback block device wrapper..."
    modprobe nbd max_part=8 2>/dev/null
    NBD_DEV="/dev/nbd0"
    
    qemu-nbd --connect="${NBD_DEV}" "${DISK_IMG}"
    sleep 2

    ROOT_PARTITION=$(lsblk -lnp -o NAME,TYPE,SIZE -b "${NBD_DEV}" | awk '$2=="part" {print $1, $3}' | sort -k2 -nr | awk 'NR==1 {print $1}')
    if [ -z "$ROOT_PARTITION" ]; then
        echo "[!] Error: Failed to map target storage blocks inside the virtual machine disk."
        qemu-nbd --disconnect "${NBD_DEV}"
        exit 1
    fi

    echo "[*] Mounting root system mapping partition (${ROOT_PARTITION}) to ${MOUNT_POINT}..."
    mkdir -p "${MOUNT_POINT}"
    mount "${ROOT_PARTITION}" "${MOUNT_POINT}"

    if [ -n "$ROOT_PASSWORD" ]; then
        echo "[*] Injecting root password..."
        echo "root:${ROOT_PASSWORD}" | chroot "${MOUNT_POINT}" chpasswd
        EXEC_STATUS=$?
    elif [ "$DISABLE_CLOUD_INIT" = true ]; then
        echo "[*] Neutralizing cloud-init infrastructure components..."
        chroot "${MOUNT_POINT}" systemctl mask cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service 2>/dev/null
        EXEC_STATUS=$?
    elif [ -n "$STATIC_IP" ]; then
        set_static_ip "$VM_NAME" "$STATIC_IP" "$GATEWAY" "$DNS"
        EXEC_STATUS=$?
    fi

    echo "[*] Synchronizing file change metadata and safely unmounting workspace..."
    sync
    umount "${MOUNT_POINT}"
    qemu-nbd --disconnect "${NBD_DEV}"
    rmdir "${MOUNT_POINT}"

    if [ $EXEC_STATUS -eq 0 ]; then
        echo "[+] Operation successfully committed to the disk."
    else
        echo "[!] Warning: Task execution sequence reported an error status code."
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
        
        # Agnostic check matching any qemu binary architecture pattern
        pid=$(pgrep -f "qemu-system-.*-name $name" | head -n 1)

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

if [[ "$ACTION" == "start" || "$ACTION" == "stop" || "$ACTION" == "connect" ]]; then
    if [ -z "$VM_NAME" ]; then
        echo "ERROR: The --name parameter is mandatory for '$ACTION' action."
        exit 1
    fi
fi

DISK_IMG="./storage/${VM_NAME}.qcow2"
QMP_SOCKET="/tmp/qmp-${VM_NAME}.sock"
MON_SOCKET="/tmp/monitor-${VM_NAME}.sock"
SERIAL_SOCKET="/tmp/serial-${VM_NAME}.sock"

# ==============================================================================
# ACTION: CONNECT
# ==============================================================================
if [ "$ACTION" == "connect" ]; then
    pid=$(pgrep -f "qemu-system-.*-name $VM_NAME" | head -n 1)
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
    pid=$(pgrep -f "qemu-system-.*-name $VM_NAME" | head -n 1)
    if [ -n "$pid" ]; then
        echo "ERROR: VM '$VM_NAME' is currently RUNNING (PID: $pid)."
	echo "Please stop the virtual machine before destroying it: vm-ctl stop --name $VM_NAME"
        exit 1
    fi

    if [ ! -f "$DISK_IMG" ]; then
        echo "ERROR: No staged disk found for '$VM_NAME' at $DISK_IMG"
        exit 1
    fi

    echo -e "\e[31m⚠️  WARNING: You are about to permanently DELETE the VM '$VM_NAME'.\e[0m"
    read -p "Are you absolutely sure you want to proceed? (type 'yes' to confirm): " CONFIRM

    if [ "$CONFIRM" != "yes" ]; then
        echo "Destruction aborted. Your virtual machine remains intact."
        exit 0
    fi

    echo "Purging resources for VM: $VM_NAME..."
    rm -f "$QMP_SOCKET" "$MON_SOCKET" "$SERIAL_SOCKET" "$DISK_IMG"

    echo -e "\e[32m✔ Success:\e[0m Virtual machine '$VM_NAME' and its storage assets have been completely destroyed."
    exit 0
fi

# ==============================================================================
# ACTION: STOP
# ==============================================================================
if [ "$ACTION" == "stop" ]; then
    echo "Attempting graceful shutdown for VM: $VM_NAME..."
    if [ ! -S "$QMP_SOCKET" ]; then echo "ERROR: Control socket not found."; exit 1; fi
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
# ACTION: START (DYNAMIC HYBRID ROUTING ENGINE)
# ==============================================================================
if [ ! -f "$DISK_IMG" ]; then
    echo "ERROR: Storage disk image not found at target location: $DISK_IMG"
    echo "Please create the qcow2 image first using: qemu-img create -f qcow2 $DISK_IMG 20G"
    exit 1
fi

# 1. DYNAMIC GUEST ARCHITECTURE INSPECTION
# Try to extract from metadata, otherwise use an advanced fallback
GUEST_ARCH=$(qemu-img info "$DISK_IMG" | grep "architecture:" | awk '{print $2}' 2>/dev/null || true)

if [ -z "$GUEST_ARCH" ]; then
    # Improved fallback heuristic:
    # 1. Check if the file name contains x86_64, amd64 or x86
    if [[ "$VM_NAME" == *x86_64* || "$VM_NAME" == *amd64* || "$VM_NAME" == *x86* || "$(basename "$DISK_IMG")" == *amd64* || "$(basename "$DISK_IMG")" == *x86_64* ]]; then
        GUEST_ARCH="x86_64"
    # 2. Check if the file name contains arm64, aarch64 or variants
    elif [[ "$VM_NAME" == *aarch64* || "$VM_NAME" == *arm64* || "$(basename "$DISK_IMG")" == *aarch64* || "$(basename "$DISK_IMG")" == *arm64* ]]; then
        GUEST_ARCH="aarch64"
    else
        # 3. Ultimate safe boundary: Match host architecture to assume native run execution
        GUEST_ARCH="$HOST_ARCH"
        echo "[*] Warning: Unable to determine guest architecture from image. Assuming host native: ${GUEST_ARCH}"
    fi
fi

QEMU_BINARY=""
VM_MACHINE=""
UEFI_FW=""
CPU_PROFILE=""
ACCEL_ARGS=""

echo "[*] Host Environment: ${HOST_ARCH} | Target Guest Instance: ${GUEST_ARCH}"

if [[ "$GUEST_ARCH" == "x86_64" ]]; then
    QEMU_BINARY="qemu-system-x86_64"
    VM_MACHINE="q35"
    
    if [[ "$PKG_MANAGER" == "fedora" ]]; then
        UEFI_FW="/usr/share/edk2/ovmf/OVMF_CODE.fd"
    else
        UEFI_FW="/usr/share/OVMF/OVMF_CODE.fd"
    fi

    if [[ "$HOST_ARCH" == "x86_64" ]]; then
        # Native Hardware Virtualization on your x86_64 machine
        if [ ! -e /dev/kvm ]; then echo "ERROR: /dev/kvm unavailable."; exit 1; fi
        ACCEL_ARGS="-enable-kvm"
        CPU_PROFILE="host"
    else
        # Cross-Architecture Emulation via TCG Engine on your aarch64 machine
        ACCEL_ARGS="-tcg,thread=multi"
        CPU_PROFILE="qemu64"
    fi
else
    QEMU_BINARY="qemu-system-aarch64"
    VM_MACHINE="virt"
    
    if [[ "$PKG_MANAGER" == "fedora" ]]; then
        UEFI_FW="/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw"
    else
        UEFI_FW="/usr/share/AAVMF/AAVMF_CODE.fd"
    fi

    if [[ "$HOST_ARCH" == "aarch64" ]]; then
        # Native Hardware Virtualization on your aarch64 machine
        if [ ! -e /dev/kvm ]; then echo "ERROR: /dev/kvm unavailable."; exit 1; fi
        ACCEL_ARGS="-enable-kvm"
        CPU_PROFILE="host"
    else
        # Cross-Architecture Emulation via TCG Engine on your x86_64 machine
        ACCEL_ARGS="-tcg,thread=multi"
        CPU_PROFILE="cortex-a57"
    fi
fi

if [ ! -f "$UEFI_FW" ]; then
    echo "ERROR: UEFI firmware payload missing at target mapping path: $UEFI_FW"
    exit 1
fi

QEMU_ARGS=(
    $ACCEL_ARGS
    -machine "$VM_MACHINE"
    -name "$VM_NAME"
    -m "$RAM"
    -smp "$CPUS"
    -cpu "$CPU_PROFILE"
    -drive "if=pflash,format=raw,readonly=on,file=$UEFI_FW"
    -drive "file=$DISK_IMG,format=qcow2,if=none,id=drive0"
    -device "virtio-blk-pci,drive=drive0,id=blk0"
    -netdev bridge,id=vnet0,br=vm-ctl-br
    -device virtio-net-pci,netdev=vnet0
    -qmp "unix:$QMP_SOCKET,server,nowait"
    -monitor "unix:$MON_SOCKET,server,nowait"
    -vga none
    -display none
    -serial "unix:$SERIAL_SOCKET,server,nowait"
    -daemonize
)

if [ -n "$ISO_IMG" ]; then
    if [ ! -f "$ISO_IMG" ]; then echo "ERROR: ISO image not found at $ISO_IMG"; exit 1; fi
    QEMU_ARGS+=(-device virtio-scsi-pci -drive "file=$ISO_IMG,media=cdrom,if=none,id=cd0" -device scsi-cd,drive=cd0)
    echo "ISO attached: $ISO_IMG"
fi

if [ "$SNAPSHOT" = true ]; then
    QEMU_ARGS+=(-snapshot)
    echo "WARNING: Running in SNAPSHOT mode. Data changes will be discarded on stop."
fi

ensure_host_bridge || exit 1

echo "Launching virtual machine target footprint via ${QEMU_BINARY}..."
"$QEMU_BINARY" "${QEMU_ARGS[@]}"

if [ $? -eq 0 ]; then
    echo "VM '$VM_NAME' successfully initialized."
    echo "Control socket exposed at: $QMP_SOCKET"
    echo "Connect to console via: vm-ctl connect --name $VM_NAME"
else
    echo "ERROR: QEMU execution routing failed to initialize process properly."
fi
