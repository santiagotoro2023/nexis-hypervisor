# Nexis Hypervisor

Bare-metal hypervisor management platform. Install from an ISO or directly on Debian 12, manage QEMU/KVM virtual machines and LXC containers through a web UI, and integrate with the Nexis Controller.

Part of the Nexis ecosystem alongside [nexis-controller](https://github.com/santiagotoro2023/nexis-controller) and [nexis-worker](https://github.com/santiagotoro2023/nexis-worker).

---

## Features

- VM management via QEMU/KVM: create, start, stop, reboot, delete, snapshot
- LXC container management: create, start, stop, restart, delete
- Browser VM console via noVNC with clipboard relay (Ctrl+Alt+V paste-in)
- Container shell via xterm.js WebSocket PTY
- Live metrics stream: CPU, RAM, disk, network I/O via SSE
- Storage pool and ISO image management
- Virtual bridge and VLAN configuration
- Controller integration: pairs with nexis-controller, pushes live status, receives voice commands and remote power operations
- First-boot setup wizard in the web UI
- Self-signed TLS with TOFU trust model
- Bearer token authentication with SQLite-backed sessions

## Stack

| Layer | Technology |
|-------|-----------|
| Frontend | React 18 + TypeScript + Vite + Tailwind CSS |
| Backend | Python 3.11 + FastAPI |
| Virtualisation | libvirt-python (QEMU/KVM) + LXC CLI |
| Console | noVNC (VM) + xterm.js + WebSocket (LXC shell) |
| Metrics | psutil |
| Auth / TLS | Bearer token + SQLite + cryptography lib |

## Install via ISO

Boot the installer ISO on a bare-metal machine or VM:

```bash
dd if=nexis-hypervisor-1.0.0-amd64.iso of=/dev/sdX bs=4M status=progress
```

Boot, wait for installation to complete, then access the web UI at `https://<host-ip>:8443`.

## Install on Existing Debian 12

```bash
curl -sSL https://raw.githubusercontent.com/santiagotoro2023/nexis-hypervisor/main/install.sh | sudo bash
```

## First Boot

1. Navigate to `https://<host-ip>:8443`
2. The setup wizard opens automatically on first access
3. Set the administrator access code and node hostname
4. Log in and connect to a Nexis Controller under **Controller Link**

## Versioning

`NX-HV · BUILD 1.0.0` -- tags follow `vMAJOR.MINOR.PATCH`. See [VERSIONING.md](.github/VERSIONING.md).

## Releases

Each tagged release produces:

- `nexis-hypervisor-X.X.X-amd64.iso` -- bootable installer ISO
- `nexis-hypervisor_X.X.X_amd64.deb` -- Debian package for existing installs
