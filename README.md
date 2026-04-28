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
3. Complete the setup wizard — enter your NeXiS Controller URL, username, and password
4. The node registers itself with the Controller and SSO is activated

> **Emergency access**: if the Controller is unreachable, `creator` / `Asdf1234!` provides local fallback.

---

## Cluster Setup

All nodes managed via a single NeXiS Controller. The Controller aggregates VMs across every paired hypervisor node. There is no manual per-node cluster join — pairing a node with the Controller is sufficient.

---

## Connecting to the Controller

1. Run the setup wizard on first open — enter Controller URL + credentials
2. The node authenticates against the Controller and registers itself
3. All subsequent logins use Controller SSO
4. Workers see VMs from all paired nodes via the Controller's `/api/hyp/*` proxy

---

## API

All endpoints require `Authorization: Bearer <token>`.

| Endpoint | Description |
|----------|-------------|
| `POST /api/auth/setup` | Connect node to Controller (first-run, public) |
| `POST /api/auth/login` | Authenticate via Controller SSO or local fallback |
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
| Auth | Controller SSO · Bearer token · local emergency fallback |
| Realtime | Server-Sent Events |
| Web UI | React 18 · TypeScript · Vite · Tailwind CSS |
| Service | systemd `nexis-hypervisor-daemon.service` |
