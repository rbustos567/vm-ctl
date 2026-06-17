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