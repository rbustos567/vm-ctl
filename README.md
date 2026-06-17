# vm-ctl

A lightweight, dependency-clean, and headless QEMU/KVM virtualization orchestrator framework written in Bash. Designed specifically for managing ARM64 and x86_64 virtual machines on single-board computers (like the Orange Pi 6 Plus) and edge environments without the overhead of heavy virtualization management daemons.

---

## Features

* **Headless Infrastructure Context:** Optimized to start, manage, and audit lightweight VMs through serial socket abstraction and terminal redirection (`socat`).
* **KVM Native Performance:** Leverages direct hardware acceleration (`-enable-kvm`) for near-metal performance on ARM64 architectures.
* **Dynamic Resource Allocation:** Scale CPU cores and RAM configurations on the fly between VM boots without modifying the underlying storage.
* **Automated Installation Lifecycle:** Includes a production-ready `install.sh` that validates binary dependencies, ensures UEFI compliance, and sets up a global binary execution context.

---

## 📦 Directory Structure

```text
vm-ctl/
├── .gitignore       # Keeps storage images and temporary sockets out of source control
├── README.md        # Project documentation
├── install.sh       # Automated installer
└── vm-ctl.sh        # The VM manager script
