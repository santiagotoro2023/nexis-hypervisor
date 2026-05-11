# NeXiS Hypervisor

A QEMU/KVM and LXC hypervisor management node for the NeXiS ecosystem. Runs a FastAPI daemon with a React web UI, exposes a full REST API for VM and container lifecycle management, and integrates with NeXiS Controller for SSO, centralised monitoring, and cross-node clustering.

---

## Ecosystem

```
NeXiS Controller  — central intelligence · SSO · management plane
        ↕ SSO + device registration + metrics polling
NeXiS Hypervisor  — one per compute node  ← you are here
        ↑
NeXiS Worker      — Android / Linux / Windows desktop client
```

| Repo | Role |
|------|------|
| [nexis-controller](https://github.com/santiagotoro2023/nexis-controller) | Central AI assistant · SSO provider · management plane |
| **nexis-hypervisor** | Per-node VM and container management |
| [nexis-worker](https://github.com/santiagotoro2023/nexis-worker) | Mobile and desktop client |

---

## What's New in v1.0.8

- **SSO login via Controller** — the login page now has three fields (Controller URL, Username, Password); authentication is delegated to `POST /api/auth/login-via-controller` which validates credentials against the paired NeXiS Controller and issues a local session on success
- **Auto-clustering** — Hypervisor nodes that are registered with the same Controller automatically discover each other via `GET /api/cluster/peers`; `GET /api/cluster/vms` aggregates VMs across all discovered peers; live VM migration between peers is available at `POST /api/cluster/migrate` (uses `virsh migrate --live --persistent --undefinesource`)
- **Controller metrics polling** — `GET /api/status` (introduced in v1.0.7) returns `cpu_percent`, `mem_percent`, `disk_percent`, `vms_total`, `vms_running`, `cts_total`, `cts_running`; this is the endpoint the Controller polls on demand to display live utilisation stats in its Hypervisor page

---

## What It Is

NeXiS Hypervisor is a self-contained daemon that wraps libvirt/QEMU-KVM and LXC behind a clean REST API and a dark-themed React web UI. It handles the full lifecycle of virtual machines and Linux containers on a single physical host, and can be joined with other Hypervisor nodes into a cluster — all coordinated through a shared NeXiS Controller.

---

## Architecture

| Layer | Technology |
|-------|------------|
| Daemon | Python 3 · FastAPI · uvicorn |
| TLS | Self-signed certificate, auto-generated on first run (10-year validity) |
| Virtualisation | libvirt / QEMU-KVM for VMs · LXC for containers |
| Console access | noVNC (WebSocket-based VNC proxy) |
| Storage | SQLite at `/etc/nexis-hypervisor/` |
| Web UI | React (built with Vite), served as static files by the daemon |
| Service | systemd `nexis-hypervisor-daemon.service` |
| Auth | Bearer token · session TTL 90 days · SSO via NeXiS Controller |

The daemon listens on `https://0.0.0.0:8443` by default. TLS certificates are generated automatically at `/etc/nexis-hypervisor/` if not already present.

---

## Features

### Virtual Machine Lifecycle (QEMU/KVM via libvirt)

| Operation | Description |
|-----------|-------------|
| Create | Configurable vCPUs, memory, multi-disk (virtio/SATA/IDE/SCSI), multi-NIC, OS ISO, machine type (q35), CPU mode, display (VNC/SPICE), video (QXL/VGA/virtio), boot order |
| Start / Stop / Force-stop | ACPI shutdown or immediate destroy |
| Reboot / Reset | Graceful reboot or hardware reset |
| Suspend / Resume | Pause and unpause execution |
| Delete | Remove domain and associated storage |
| Clone | Full copy of a VM under a new name |
| Template | Mark/unmark a VM as a reusable template |
| Backup | Point-in-time backup of VM disk |
| Migrate | Live or offline migration to another libvirt URI |
| Hardware edit | Hot-add disk, NIC; change vCPU count or memory |
| Snapshots | Create, restore, and delete named snapshots |
| Console | In-browser VNC console via noVNC WebSocket |

### LXC Container Lifecycle

- Create, start, stop, restart, delete containers
- Interactive shell via WebSocket terminal
- Status monitoring

### Storage Management

- List and manage libvirt storage pools and volumes
- ISO catalogue: upload, list, and delete installation media
- Per-pool volume creation and deletion

### Network Management

- List libvirt networks
- Create and delete virtual networks
- Per-network DHCP lease inspection

### Metrics

- Live host metrics: CPU %, memory %, disk %, network throughput
- VM count (total / running) and container count (total / running)
- Uptime
- Metrics exposed at `GET /api/status` in the format the Controller polls

### Clustering

Multiple Hypervisor nodes that are all paired to the same Controller automatically form a cluster visible from the Controller's Hypervisor page. Within a Hypervisor node itself, the cluster API (`/api/cluster`) lets nodes peer directly:

- **Peer discovery:** `GET /api/cluster/peers` — discovers sibling nodes registered with the same Controller
- **Node registration:** `POST /api/cluster/nodes/join`
- **Heartbeat:** `POST /api/cluster/nodes/heartbeat`
- **Aggregate VM view:** `GET /api/cluster/vms` — VMs from local + all remote nodes
- **Aggregate container view:** `GET /api/cluster/containers`
- **Aggregate ISO view:** `GET /api/cluster/isos`
- **Per-node proxy:** `GET /api/cluster/nodes/{id}/vms`, `GET /api/cluster/nodes/{id}/metrics`
- **Remote VM actions:** `POST /api/cluster/nodes/{id}/vms/{vm_id}/{action}`
- **Live migration:** `POST /api/cluster/migrate` — uses `virsh migrate --live --persistent --undefinesource`

VM live migration between nodes is also available directly: `POST /api/vms/{vm_id}/migrate` with `{ "target_uri": "qemu+ssh://...", "live": true }`.

### Controller Integration (SSO + Status Feed)

Pairing with a Controller (`POST /api/nexis/pair`) does three things:

1. Authenticates with the Controller and obtains a token
2. Self-registers the node at `/api/devices/register` on the Controller
3. Starts a background task that pushes host metrics to the Controller every 30 seconds

All subsequent logins to the Hypervisor are proxied to the Controller (SSO) via `POST /api/auth/login-via-controller`. The login UI has three fields: Controller URL, Username, and Password. A local emergency fallback account is available if the Controller is unreachable.

---

## Requirements

- Debian 12 (Bookworm) · x86_64
- Root / sudo access
- CPU with hardware virtualisation (Intel VT-x / AMD-V), enabled in BIOS/UEFI
- Internet connection for installation

---

## Installation

```bash
curl -sSL https://raw.githubusercontent.com/santiagotoro2023/nexis-hypervisor/main/install-nexis-hypervisor.sh | sudo bash
```

Or from a local clone:

```bash
git clone https://github.com/santiagotoro2023/nexis-hypervisor
sudo bash nexis-hypervisor/install-nexis-hypervisor.sh
```

The installer:
1. Installs `qemu-kvm`, `libvirt`, `lxc`, `novnc`, Python 3, and Node.js 22
2. Enables and starts `libvirtd`, activates the default NAT network
3. Clones / updates the repository to `/opt/nexis-hypervisor`
4. Creates a Python venv and installs daemon dependencies
5. Builds the React web UI (`npm ci && npm run build`)
6. Creates the data directory at `/etc/nexis-hypervisor/`
7. Opens port 8443 in ufw (if present)
8. Installs and starts `nexis-hypervisor-daemon.service`

---

## First Access

1. Open `https://<node-ip>:8443` in a browser
2. Accept the self-signed TLS certificate
3. The setup wizard prompts for the NeXiS Controller URL, username, and password
4. The node authenticates against the Controller (SSO) and self-registers
5. The node appears in the Controller's **Hypervisor** tab

Default emergency local credentials (only used if Controller is unreachable):
```
Username: creator
Password: Asdf1234!   ← change immediately
```

---

## Authentication

All login requests are forwarded to the paired NeXiS Controller (`POST /api/auth/login-via-controller`). The login page presents three fields — Controller URL, Username, and Password. If the Controller is reachable and the credentials are valid, a local session token (90-day TTL) is issued. If the Controller is unreachable, the local fallback account provides emergency access.

API requests must include `Authorization: Bearer <token>` on all endpoints except:
- `GET /api/auth/status`
- `POST /api/auth/login`
- `POST /api/auth/login-via-controller`
- `POST /api/auth/setup`
- `POST /api/auth/setup/complete`

WebSocket console connections pass the token as a query parameter: `?token=<token>`.

---

## Configuration

| Path | Purpose |
|------|--------|
| `/opt/nexis-hypervisor/` | Application source, Python venv, built web UI |
| `/etc/nexis-hypervisor/` | SQLite database, TLS certificate and key, runtime config |
| `/etc/systemd/system/nexis-hypervisor-daemon.service` | Service unit |

The daemon auto-generates a self-signed TLS certificate (2048-bit RSA, 10-year validity) at `/etc/nexis-hypervisor/cert.pem` and `/etc/nexis-hypervisor/key.pem` on first start if they do not exist.

---

## API

All endpoints require `Authorization: Bearer <token>` unless noted. Interactive API docs are available at `https://<node-ip>:8443/api/docs`.

### Auth

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/auth/status` | Setup/pairing status · public |
| `POST` | `/api/auth/setup` | First-run wizard — connect to Controller · public |
| `POST` | `/api/auth/login` | Authenticate locally · returns Bearer token · public |
| `POST` | `/api/auth/login-via-controller` | SSO login — validate credentials against Controller · public |
| `POST` | `/api/auth/logout` | Invalidate session token |

### Virtual Machines

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/vms` | List all VMs |
| `POST` | `/api/vms` | Create a VM |
| `GET` | `/api/vms/{id}` | Get VM details |
| `DELETE` | `/api/vms/{id}` | Delete a VM |
| `POST` | `/api/vms/{id}/start` | Start |
| `POST` | `/api/vms/{id}/stop` | ACPI shutdown |
| `POST` | `/api/vms/{id}/force-stop` | Immediate destroy |
| `POST` | `/api/vms/{id}/reboot` | Reboot |
| `POST` | `/api/vms/{id}/reset` | Hardware reset |
| `POST` | `/api/vms/{id}/suspend` | Suspend |
| `POST` | `/api/vms/{id}/resume` | Resume |
| `POST` | `/api/vms/{id}/clone` | Clone to new name |
| `POST` | `/api/vms/{id}/migrate` | Live/offline migration |
| `POST` | `/api/vms/{id}/backup` | Create backup |
| `POST` | `/api/vms/{id}/template` | Mark as template |
| `DELETE` | `/api/vms/{id}/template` | Unmark template |
| `GET` | `/api/vms/{id}/hardware` | Get hardware config |
| `PATCH` | `/api/vms/{id}/hardware` | Edit hardware (vCPU/mem/disk/NIC) |
| `GET` | `/api/vms/{id}/snapshots` | List snapshots |
| `POST` | `/api/vms/{id}/snapshots` | Create snapshot |
| `POST` | `/api/vms/{id}/snapshots/{name}/restore` | Restore snapshot |
| `DELETE` | `/api/vms/{id}/snapshots/{name}` | Delete snapshot |
| `GET` | `/api/vms/templates` | List templates |
| `GET` | `/api/vms/backups` | List backups |

### Containers

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/containers` | List LXC containers |
| `POST` | `/api/containers` | Create container |
| `POST` | `/api/containers/{id}/start` | Start |
| `POST` | `/api/containers/{id}/stop` | Stop |
| `POST` | `/api/containers/{id}/restart` | Restart |
| `DELETE` | `/api/containers/{id}` | Delete |
| `GET` | `/api/containers/{id}/shell` | Interactive shell (WebSocket) |

### Storage

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/storage/pools` | List storage pools |
| `GET` | `/api/storage/pools/{name}/volumes` | List volumes in pool |
| `POST` | `/api/storage/pools/{name}/volumes` | Create volume |
| `DELETE` | `/api/storage/pools/{name}/volumes/{vol}` | Delete volume |
| `GET` | `/api/storage/isos/list` | List ISO images |
| `POST` | `/api/storage/isos/upload` | Upload ISO |
| `DELETE` | `/api/storage/isos/{filename}` | Delete ISO |

### Network

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/network` | List virtual networks |
| `POST` | `/api/network` | Create network |
| `DELETE` | `/api/network/{name}` | Delete network |
| `GET` | `/api/network/{name}/leases` | DHCP leases |

### Metrics

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/status` | Host + VM/container metrics snapshot (polled by Controller) |
| `GET` | `/api/metrics/current` | Live host metrics |

### Console

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/vms/{id}/console` | noVNC console WebSocket (`?token=`) |

### Cluster

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/cluster/nodes` | List cluster nodes |
| `GET` | `/api/cluster/peers` | Discover peer hypervisors registered with the same Controller |
| `POST` | `/api/cluster/nodes/join` | Add a peer node |
| `DELETE` | `/api/cluster/nodes/{id}` | Remove a node |
| `POST` | `/api/cluster/nodes/heartbeat` | Node heartbeat |
| `GET` | `/api/cluster/vms` | All VMs across all nodes |
| `GET` | `/api/cluster/containers` | All containers across all nodes |
| `GET` | `/api/cluster/isos` | All ISOs across all nodes |
| `GET` | `/api/cluster/nodes/{id}/vms` | VMs on specific node |
| `GET` | `/api/cluster/nodes/{id}/metrics` | Metrics from specific node |
| `POST` | `/api/cluster/nodes/{id}/vms/{vm_id}/{action}` | VM action on specific node |
| `POST` | `/api/cluster/migrate` | Live migration via virsh (`--live --persistent --undefinesource`) |
| `GET` | `/api/cluster/summary` | Node count and status summary |

### Controller Integration

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/nexis/status` | Pairing status and feed health |
| `POST` | `/api/nexis/pair` | Pair with a NeXiS Controller |
| `POST` | `/api/nexis/unpair` | Remove pairing |
| `POST` | `/api/nexis/command` | Execute natural language command from Controller |

### System

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/system/info` | Hostname, version, uptime |
| `GET` | `/api/system/logs` | Recent action log |

---

## Controller Status Feed

After pairing, the daemon pushes a metrics payload to the Controller every 30 seconds:

```json
{
  "device_id": "nexis-hypervisor",
  "type": "hypervisor",
  "status": {
    "cpu_percent": 12.4,
    "memory_percent": 45.1,
    "vm_count": 4,
    "vm_running": 2,
    "container_count": 3,
    "container_running": 1,
    "hostname": "node1"
  }
}
```

The `GET /api/status` endpoint returns a richer snapshot for the Controller to pull on demand:

```json
{
  "cpu_percent": 12.4,
  "mem_percent": 45.1,
  "disk_percent": 61.0,
  "vms_total": 4,
  "vms_running": 2,
  "cts_total": 3,
  "cts_running": 1,
  "hostname": "node1",
  "uptime_seconds": 86400,
  "mem_used_gb": 14.4,
  "mem_total_gb": 32.0,
  "disk_used_gb": 122.0,
  "disk_total_gb": 200.0,
  "net_sent_mbps": 0.5,
  "net_recv_mbps": 1.2
}
```

---

## Logs

```bash
journalctl -u nexis-hypervisor-daemon -f
```
