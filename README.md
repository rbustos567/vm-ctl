# vm-ctl

A lightweight, dependency-clean, and headless QEMU/KVM virtualization orchestrator framework written in Bash. Designed specifically for managing ARM64 and x86_64 virtual machines on single-board computers (like the Orange Pi 6 Plus) and edge environments without the overhead of heavy virtualization management daemons.

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

----------------------

# Quick Start

1. Installation
Clone the repository and run installer script with root privileges to satisfy host layout requirements:

git clone [https://github.com/your-username/vm-ctl.git](https://github.com/your-username/vm-ctl.git)
cd vm-ctl
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

socat -,raw,echo=0 UNIX-CONNECT:/tmp/serial-alpine-lab.sock

5. Follow instructions to install alpine OS

6. Once finished, gracefully powerdown the VM:

vm-ctl stop --name alpine-lab

7. Start again VM but without need of ISO
vm-ctl start --name alpine-lab --ram 1024 --cpus 2

8. Connect via Serial Console
Interact with the native Linux kernel console socket stream securely:

socat -,raw,echo=0 UNIX-CONNECT:/tmp/serial-alpine-lab.sock

9. Check running instances status:
vm-ctl status

10. Gracefully powerdown your instance
vm-ctl stop --name alpine-lab

