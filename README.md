# vm-ctl

A lightweight, dependency-clean, and headless QEMU/KVM virtualization orchestrator framework written in Bash. Designed specifically for managing aarch64 and x86_64 virtual machines and edge environments without the overhead of heavy virtualization management daemons.

---------------------

## Features

* **Headless Infrastructure Context:** Optimized to start, manage, and audit lightweight VMs through serial socket abstraction and terminal redirection (`socat`).
* **KVM Native Performance:** Leverages direct hardware acceleration (`-enable-kvm`) for near-metal performance on ARM64 architectures.
* **Dynamic Resource Allocation:** Scale CPU cores and RAM configurations on the fly between VM boots without modifying the underlying storage.
* **Automated Installation Lifecycle:** Includes a production-ready `install.sh` that validates binary dependencies, ensures UEFI compliance, and sets up a global binary execution context.

----------------------

## Directory Structure

```text
vm-ctl/
├── .gitignore       # Keeps storage images and temporary sockets out of source control
├── README.md        # Project documentation
├── install.sh       # Automated installer
└── vm-ctl.sh        # The VM manager script
└── isos/            # Stores linux ISOs
└── images/          # Stores disks from existing VMs
```
----------------------


```text
## Quick Start: Deploying a Cloud Image (Recommended)

Instead of installing an OS manually via an ISO, the fastest way to spin up a lightweight, production-ready virtual machine is using official **Cloud Images** (`.qcow2`). 

Since Cloud Images are secure by default and do not come with a pre-configured password, we will use `libguestfs-tools` to inject our credentials and disable initial metadata timeouts before the first boot.

1. Download the official ARM64 Cloud Image (Debian 12)
curl -L -o ./storage/debian-test.qcow2 https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2

2. Provision Root Credentials (Natively injects password into the root partition)
./vm-ctl.sh set --name debian-test --root-pass "YourSecurePassword"

3. Disable cloud-init (Prevents dynamic systemd metadata block timeouts)
./vm-ctl.sh set --name debian-test --disable-cloud-init

4. Inject Static IP Address Profile (Automatically detects the host uplink interface, hooks into the local hardware bridge vmctl-br, and maps the correct target guest interface dynamically)
/vm-ctl.sh set --name debian-test --static-ip "192.168.1.24/24" --gateway "192.168.1.1" --dns "1.1.1.1"

5. Launch virtual machine
vm-ctl start --name debian-test --ram 1024 --cpus 1

6. Verify Network Operations (Since the VM is connected to the network bridge, it shares your local network segment. You can ping or SSH directly into it from the host or any device on your LAN)
ping 192.168.1.24
ssh root@192.168.1.24

7. Connect to the interactive Serial Console of VM
vm-ctl connect --name debian-test

8. Login to VM using root and the newly set root password: YourSecurePassword

9. To quit from terminal session of VM press: Ctrl+O

10. Check status of your VM:
vm-ctl status

11. Stop the VM:
vm-ctl stop --name debian-test

```
--------------------------------

## Quick Start creating VM through a ISO

```text
1. Installation
Clone the repository and run installer script with root privileges to satisfy host layout requirements:
git clone git@github.com:rbustos567/vm-ctl.git
cd vm-ctl
chmod +x install.sh
sudo ./install.sh

2. Prepare Storage & Boot Media
Move your target OS installation ISOs into the newly initialized staging area:
# Example: Stage Alpine Linux or Debian ARM64 ISO
mv ~/Downloads/alpine-virt.iso ./isos/

3. Start up a headless VM
Launch an instance specifying resource allocation bounds and binding the install media:
vm-ctl start --name alpine-lab --ram 1024 --cpus 2 --iso ./isos/alpine-virt.iso

4. Connect via Serial Console
Interact with the native Linux kernel console socket stream securely:
vm-ctl connect --name alpine-lab

5. Follow instructions to install alpine OS on VM

6. Once finished, gracefully powerdown the VM:
vm-ctl stop --name alpine-lab

7. Start again VM but without need of ISO
vm-ctl start --name alpine-lab --ram 1024 --cpus 2

8. Connect via Serial Console
Interact again with the native Linux kernel console socket stream securely:
vm-ctl connect --name alpine-lab

9. Check running instances status:
vm-ctl status

10. Gracefully powerdown your instance
vm-ctl stop --name alpine-lab
```
----------------------

> [!NOTE]
> **Filesystem & Host Kernel Restrictions (ARM64 / SBC Focus)**
>
> This script relies on `qemu-nbd` and native host mount capabilities to inject credentials and disable services. 
> * **Supported Filesystems:** Tested and fully operational on Cloud Images using **`ext4`** (e.g., official Debian, Ubuntu, and Alpine images).
> * **XFS Limitations:** Enterprise Linux distributions (such as AlmaLinux, Rocky Linux, or Fedora Cloud) format their root partitions using **`XFS`** by default. If your host system is an ARM64 Single Board Computer (like the Orange Pi 6 Plus running custom vendor kernels such as `6.1.x-cix`), the host kernel may lack native XFS compilation or module support. 
> * **Workaround:** If running on a stripped-down kernel, please use the **`ext4`** generic cloud image variants provided by the respective distributions (e.g., AlmaLinux GenericCloud-vfat-ext4 flavor) to allow seamless native partitioning manipulation.

