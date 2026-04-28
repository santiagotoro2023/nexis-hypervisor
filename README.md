# NeXiS Hypervisor

Compute node agent for the NeXiS ecosystem. Install on any Debian 12 machine to expose its QEMU/KVM virtual machines and LXC containers through a secure web interface. Pairs with [NeXiS Controller](https://github.com/santiagotoro2023/nexis-controller) for centralised multi-node management.

---

## Ecosystem

```
┌──────────────────────────────────────────────────────────────┐
│  NeXiS Controller   — central management plane · SSO         │
│    ↕ authenticated API                                        │
│  NeXiS Hypervisor   — one per compute node (you are here)    │
└──────────────────────────────────────────────────────────────┘
        ↑
  NeXiS Worker  — Android / desktop client
```

| Repo | Role |
|------|------|
| [nexis-controller](https://github.com/santiagotoro2023/nexis-controller) | Manages multiple hypervisor nodes, provides SSO |
| **nexis-hypervisor** | Runs on each compute node; exposes VMs, containers, and storage |
| [nexis-worker](https://github.com/santiagotoro2023/nexis-worker) | Mobile and desktop client for the controller and hypervisors |

Hypervisors can be used standalone or paired with a Controller. When paired, the Controller's SSO session is accepted — users authenticate once and reach all nodes.

---

## Capabilities

**Virtual Machines (QEMU/KVM)**
- Create, start, stop, reboot, delete VMs with configurable vCPU, RAM, and disk
- Snapshot management
- Browser-based VNC console via noVNC

**Containers (LXC)**
- Create, start, stop, restart, delete containers
- Interactive shell via xterm.js WebSocket PTY

**Infrastructure**
- Storage pool and ISO image management
- Virtual network and bridge configuration
- Live resource metrics (CPU, RAM, disk, network I/O) streamed via SSE

**Security**
- Self-signed TLS on port 8443 (TOFU trust model)
- Bearer token authentication with SQLite-backed sessions
- First-boot setup wizard enforces credential change on first access

---

## Requirements

- Debian 12 (Bookworm) · x86_64
- Root / sudo access
- Internet connectivity (for installation)
- CPU with hardware virtualisation (Intel VT-x / AMD-V) for KVM

---

## Installation

```bash
curl -sSL https://raw.githubusercontent.com/santiagotoro2023/nexis-hypervisor/main/install-nexis-hypervisor.sh | sudo bash
```

Or clone first and run locally:

```bash
git clone https://github.com/santiagotoro2023/nexis-hypervisor
sudo bash nexis-hypervisor/install-nexis-hypervisor.sh
```

The installer:
1. Installs system packages (qemu-kvm, libvirt, lxc, novnc, python3)
2. Clones / updates the repository to `/opt/nexis-hypervisor`
3. Creates a Python virtual environment and installs daemon dependencies
4. Builds the web interface
5. Installs and starts `nexis-hypervisor-daemon.service`

---

## First Access

1. Open `https://<host-ip>:8443` in a browser
2. Accept the self-signed certificate
3. The setup wizard runs automatically on first visit — set a hostname and access code
4. Default credentials: **`creator` / `Asdf1234!`** — change immediately

---

## Pairing with NeXiS Controller

1. In the hypervisor web UI, navigate to **Controller Link**
2. Enter the Controller URL and a pairing token (generated in the Controller admin panel)
3. Once paired, the Controller's SSO sessions are accepted — no separate login required from connected clients

---

## API

The daemon exposes a REST API at `https://<host>:8443/api/`. All endpoints except auth require a `Bearer <token>` header.

| Prefix | Description |
|--------|-------------|
| `GET /api/auth/status` | Setup and auth status (public) |
| `POST /api/auth/login` | Authenticate; returns session token |
| `GET /api/vms` | List virtual machines |
| `POST /api/vms` | Create virtual machine |
| `POST /api/vms/{id}/start\|stop\|reboot` | VM power control |
| `GET /api/vms/{id}/console` | VNC WebSocket (noVNC) |
| `GET /api/containers` | List containers |
| `POST /api/containers` | Create container |
| `GET /api/containers/{id}/shell` | Shell WebSocket (xterm.js) |
| `GET /api/storage` | Storage pools and volumes |
| `GET /api/network` | Virtual networks |
| `GET /api/metrics/stream` | SSE metrics stream |
| `GET /api/system/info` | Hostname and build version |
| `GET /api/nexis/status` | Controller pairing status |

Interactive API docs: `https://<host>:8443/api/docs`

---

## Configuration

| Environment Variable | Default | Description |
|----------------------|---------|-------------|
| `NEXIS_DATA` | `/etc/nexis-hypervisor` | Config and database directory |
| `NEXIS_PORT` | `8443` | HTTPS listen port |
| `NEXIS_HOST` | `0.0.0.0` | Bind address |
| `NEXIS_ISO_DIR` | `/var/lib/libvirt/images` | ISO storage path |

Runtime configuration (pairing, hostname) is stored in `/etc/nexis-hypervisor/config.json`.

---

## Stack

| Layer | Technology |
|-------|-----------|
| Frontend | React 18 · TypeScript · Vite · Tailwind CSS |
| Backend | Python 3.11 · FastAPI · uvicorn |
| Virtualisation | libvirt-python (QEMU/KVM) · LXC CLI |
| Console | noVNC (VM) · xterm.js + WebSocket PTY (container) |
| Auth / TLS | Bearer token · SQLite · `cryptography` library |
| Metrics | psutil |
