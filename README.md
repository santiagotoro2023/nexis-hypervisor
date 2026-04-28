# NeXiS Hypervisor

Per-node compute management for the NeXiS ecosystem. Provides a web interface and API for KVM/QEMU virtual machines and LXC containers, with cluster-aware unified views and full Controller integration.

---

## Ecosystem

```
┌──────────────────────────────────────────────────────────────┐
│  NeXiS Controller   — AI assistant · SSO provider            │
│    ↕ authenticated API + LLM tool calls                      │
│  NeXiS Hypervisor   — one per compute node (you are here)    │
└──────────────────────────────────────────────────────────────┘
        ↑
  NeXiS Worker  — Android / Linux desktop client
```

| Repo | Role |
|------|------|
| [nexis-controller](https://github.com/santiagotoro2023/nexis-controller) | Central AI assistant · SSO provider · management plane |
| **nexis-hypervisor** | Per-node KVM/LXC management — you are here |
| [nexis-worker](https://github.com/santiagotoro2023/nexis-worker) | Android and desktop client |

---

## Capabilities

**Virtual Machines (KVM/QEMU)**
- Provision, start, stop, reboot, force-stop, delete
- VNC console with clipboard sync (paste from host)
- Snapshots — create, restore, delete
- Clone VM · Convert to template · Backup disk · Live migrate

**Containers (LXC)**
- Create, start, stop, delete LXC containers
- Browser-attached shell

**Cluster**
- Multi-node clustering — unified VM/container view across all nodes
- Per-node filter tabs or all-nodes aggregate view
- Remote VM actions (start/stop on any node from any node's UI)

**Storage**
- Local directory and NFS storage pool management
- ISO library — upload, delete, catalog download
- ISO catalog — one-click download of Ubuntu, Debian, Alpine, Rocky, FreeBSD, TrueNAS, and more
- Cross-cluster ISO visibility

**System**
- One-click web UI update (git pull → pip → npm → restart, streamed live)
- Controller pairing and SSO

**Controller Integration**
- Pair with NeXiS Controller for unified SSO across all nodes
- Controller LLM issues VM actions as tool calls (start, stop, create, snapshot, migrate)
- 30-second status feed to Controller

---

## Requirements

- Debian 12 (Bookworm) or Ubuntu 22.04+ · x86_64
- Root / sudo access
- KVM-capable CPU (`egrep -c '(vmx|svm)' /proc/cpuinfo` > 0)

---

## Installation

```bash
curl -sSL https://raw.githubusercontent.com/santiagotoro2023/nexis-hypervisor/main/install-nexis-hypervisor.sh | sudo bash
```

The installer handles: packages, libvirt, QEMU, LXC, Python venv, web UI build, systemd service.

---

## First Access

1. Open `https://<host-ip>:8443`
2. Accept the self-signed certificate
3. Complete the setup wizard (set credentials, optionally link Controller)
4. Default: `creator` / `Asdf1234!` — change on first login

---

## Cluster Setup

1. Install the hypervisor on each node
2. On the primary node go to **Cluster → Add Node**
3. Enter the remote node's URL and its API token
4. All nodes' VMs appear in the unified **Virtual Instances** view

---

## Pairing with the Controller

1. In the Controller web UI, go to **Nodes → Add Hypervisor**
2. Enter this node's URL and API token (found in this node's **System** page)
3. The node appears in the Controller — Workers can manage VMs via Controller SSO

---

## API

All endpoints require `Authorization: Bearer <token>`.

| Endpoint | Description |
|----------|-------------|
| `POST /api/auth/login` | Authenticate (public) |
| `GET /api/vms` | List local VMs |
| `POST /api/vms` | Create VM |
| `POST /api/vms/{id}/start\|stop\|reboot` | Power operations |
| `POST /api/vms/{id}/clone` | Clone VM |
| `POST /api/vms/{id}/backup` | Backup VM disk |
| `POST /api/vms/{id}/migrate` | Live migrate |
| `GET /api/vms/templates` | List templates |
| `GET /api/vms/{id}/snapshots` | List snapshots |
| `POST /api/vms/{id}/snapshots` | Create snapshot |
| `GET /api/containers` | List LXC containers |
| `GET /api/storage/pools` | List storage pools |
| `POST /api/storage/pools` | Add pool (local/NFS) |
| `GET /api/storage/catalog` | ISO catalog |
| `POST /api/storage/isos/fetch` | Download ISO (SSE) |
| `GET /api/cluster/vms` | All VMs across cluster |
| `POST /api/cluster/nodes/join` | Add cluster node |
| `GET /api/metrics/stream` | Live metrics (SSE) |
| `GET /api/system/info` | Hostname / version |
| `POST /api/system/update` | Apply update (SSE) |
| `GET /api/nexis/status` | Controller pairing status |

---

## Stack

| Layer | Technology |
|-------|-----------|
| Daemon | Python 3.11 · FastAPI · uvicorn |
| Virtualisation | libvirt · QEMU/KVM · LXC |
| Console | noVNC (WebSocket VNC proxy) |
| Auth | Bearer token · SHA-256 · SQLite |
| Realtime | Server-Sent Events |
| Web UI | React 18 · TypeScript · Vite · Tailwind CSS |
| Service | systemd `nexis-hypervisor-daemon.service` |
