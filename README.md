# NeXiS Hypervisor

![Version](https://img.shields.io/badge/version-1.0.8-blue) ![Platform](https://img.shields.io/badge/platform-Linux-lightgrey) ![Stack](https://img.shields.io/badge/stack-FastAPI%20%2B%20React-green)

A QEMU/KVM and LXC hypervisor management node for the NeXiS ecosystem. Runs a FastAPI daemon with a React + TypeScript web UI, exposes a full REST API for VM and container lifecycle management, and integrates with NeXiS Controller for SSO, centralised monitoring, and zero-config multi-node clustering.

---

## Ecosystem Overview

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

All Hypervisor nodes that are registered with the same Controller automatically form a cluster. One set of credentials reaches all nodes.

---

## Table of Contents

- [Architecture](#architecture)
- [Requirements](#requirements)
- [Installation](#installation)
- [First Access & Setup Wizard](#first-access--setup-wizard)
- [Configuration](#configuration)
- [Authentication](#authentication)
- [Features](#features)
  - [Virtual Machine Lifecycle](#virtual-machine-lifecycle-qemukvm-via-libvirt)
  - [LXC Container Lifecycle](#lxc-container-lifecycle)
  - [Storage Management](#storage-management)
  - [Network Management](#network-management)
  - [Metrics](#metrics)
  - [Clustering](#clustering)
  - [Controller Integration](#controller-integration-sso--status-feed)
- [API Reference](#api-reference)
- [Controller Status Feed](#controller-status-feed)
- [Service Management](#service-management)

---

## Architecture

| Layer | Technology |
|-------|------------|
| Backend | Python 3 · **FastAPI** · uvicorn |
| Frontend | **React + TypeScript** (Vite build), served as static files by the daemon |
| TLS | Self-signed certificate, auto-generated on first run (10-year validity) |
| Virtualisation | **libvirt / QEMU-KVM** for virtual machines |
| Containers | **LXC** for Linux containers |
| Console access | **noVNC** (WebSocket-based VNC proxy) |
| Storage | SQLite at `/etc/nexis-hypervisor/` |
| Service | systemd `nexis-hypervisor-daemon.service` |
| Auth | Bearer token · session TTL 90 days · SSO via NeXiS Controller |

The daemon listens on `https://0.0.0.0:8443`. Interactive API docs are available at `https://<node-ip>:8443/api/docs`.

TLS certificates are auto-generated (2048-bit RSA, 10-year validity) at `/etc/nexis-hypervisor/cert.pem` and `/etc/nexis-hypervisor/key.pem` on first start.

---

## Requirements

- Debian 12 (Bookworm) · x86_64
- Root / sudo access
- CPU with hardware virtualisation (Intel VT-x or AMD-V) enabled in BIOS/UEFI
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

The installer performs these steps:

1. Installs `qemu-kvm`, `libvirt`, `lxc`, `novnc`, Python 3, and Node.js 22
2. Enables and starts `libvirtd`; activates the default NAT network
3. Clones or updates the repository to `/opt/nexis-hypervisor`
4. Creates a Python virtual environment and installs daemon dependencies
5. Builds the React web UI (`npm ci && npm run build`)
6. Creates the data directory at `/etc/nexis-hypervisor/`
7. Opens port 8443 in ufw (if ufw is active)
8. Installs and starts `nexis-hypervisor-daemon.service`

---

## First Access & Setup Wizard

1. Open `https://<node-ip>:8443` in a browser
2. Accept the self-signed TLS certificate warning
3. The **setup wizard** appears and prompts for:
   - NeXiS Controller URL (e.g. `https://192.168.1.10:8443`)
   - Controller username
   - Controller password
4. The Hypervisor authenticates against the Controller (`POST /api/auth/login-via-controller`), then self-registers at the Controller's `/api/device/register`
5. The node appears in the Controller's **Hypervisor** tab

From this point, all logins to the Hypervisor are proxied to the Controller — no separate per-node passwords.

**Emergency local credentials** (used only if the Controller is unreachable):
```
Username: creator
Password: Asdf1234!   ← change immediately
```

---

## Configuration

| Path | Purpose |
|------|---------|
| `/opt/nexis-hypervisor/` | Application source, Python venv, built React web UI |
| `/etc/nexis-hypervisor/` | SQLite database, TLS certificate and private key, runtime config |
| `/etc/nexis-hypervisor/cert.pem` | Auto-generated TLS certificate |
| `/etc/nexis-hypervisor/key.pem` | Auto-generated TLS private key |
| `/etc/systemd/system/nexis-hypervisor-daemon.service` | systemd service unit |

---

## Authentication

### SSO via Controller

All login requests are forwarded to the paired NeXiS Controller via `POST /api/auth/login-via-controller`. The login page presents three fields: **Controller URL**, **Username**, and **Password**. If the Controller is reachable and credentials are valid, a local session token (90-day TTL) is issued.

### Local Fallback

If the Controller is unreachable, the local emergency account (`creator` / `Asdf1234!`) provides access. Change this password immediately after setup.

### API Authentication

All API endpoints require `Authorization: Bearer <token>` except:

- `GET /api/auth/status`
- `POST /api/auth/login`
- `POST /api/auth/login-via-controller`
- `POST /api/auth/setup`
- `POST /api/auth/setup/complete`

WebSocket console connections pass the token as a query parameter: `wss://<host>:8443/api/vms/{id}/console?token=<token>`

---

## Features

### Virtual Machine Lifecycle (QEMU/KVM via libvirt)

| Operation | Description |
|-----------|-------------|
| **Create** | Configurable vCPUs, memory, multi-disk (virtio/SATA/IDE/SCSI), multi-NIC, OS ISO, machine type (q35), CPU mode, display (VNC/SPICE), video model (QXL/VGA/virtio), boot order |
| **Start** | Boot the VM via ACPI |
| **Stop** | Graceful ACPI shutdown |
| **Force-stop** | Immediate destroy (equivalent to pulling the power) |
| **Reboot** | Graceful reboot |
| **Reset** | Hardware reset |
| **Suspend** | Pause execution (freeze in memory) |
| **Resume** | Unpause a suspended VM |
| **Delete** | Undefine domain and optionally remove associated storage |
| **Clone** | Full copy of a VM under a new name |
| **Template** | Mark or unmark a VM as a reusable template |
| **Deploy from template** | Provision a new VM from a template |
| **Backup** | Point-in-time disk backup |
| **Restore** | Restore from a backup |
| **Migrate** | Live or offline migration to another libvirt URI |
| **Hardware edit** | Hot-add disk or NIC; change vCPU count or memory allocation |
| **Snapshots** | Create, revert to, and delete named snapshots |
| **Console** | In-browser VNC console via noVNC (WebSocket) |
| **Serial console** | WebSocket-based serial console access |

### LXC Container Lifecycle

| Operation | Description |
|-----------|-------------|
| **Create** | New LXC container with configurable resources |
| **Start** | Start a stopped container |
| **Stop** | Stop a running container |
| **Restart** | Restart a container |
| **Delete** | Destroy a container and its storage |
| **Shell** | Interactive shell session via WebSocket terminal |
| **Status** | Running/stopped status and resource usage |

### Storage Management

- List and inspect libvirt storage pools and volumes
- Create and delete volumes within a pool
- **ISO catalogue**: upload, list, and delete installation media
- Per-pool volume management

### Network Management

- List all libvirt virtual networks
- Create and delete virtual networks
- Inspect per-network DHCP leases

### Metrics

The daemon exposes live host metrics at `GET /api/status` — the endpoint the Controller polls every 10 seconds to display utilisation stats in its Hypervisor page:

```json
{
  "cpu_percent": 12.3,
  "mem_percent": 45.6,
  "disk_percent": 23.1,
  "vms_total": 4,
  "vms_running": 2,
  "cts_total": 3,
  "cts_running": 1,
  "hostname": "hv01",
  "uptime_seconds": 86400
}
```

### Clustering

Multiple Hypervisor nodes registered with the same Controller automatically discover each other — no manual peering configuration required.

| Capability | Description |
|-----------|-------------|
| **Peer discovery** | `GET /api/cluster/peers` — queries the shared Controller for all registered Hypervisor nodes |
| **Aggregate VM view** | `GET /api/cluster/vms` — VMs from this node plus all remote peers |
| **Aggregate container view** | `GET /api/cluster/containers` — containers across all nodes |
| **Aggregate ISO view** | `GET /api/cluster/isos` — ISOs across all nodes |
| **Per-node proxy** | `GET /api/cluster/nodes/{id}/vms` and `GET /api/cluster/nodes/{id}/metrics` |
| **Remote VM actions** | `POST /api/cluster/nodes/{id}/vms/{vm_id}/{action}` |
| **Live migration** | `POST /api/cluster/migrate` — uses `virsh migrate --live --persistent --undefinesource` |
| **Cluster summary** | `GET /api/cluster/summary` — total resource counts and peer node list |

Direct live migration is also available: `POST /api/vms/{vm_id}/migrate` with `{ "target_uri": "qemu+ssh://...", "live": true }`.

### Controller Integration (SSO + Status Feed)

Pairing with a Controller (`POST /api/nexis/pair`) does three things:

1. Authenticates with the Controller and obtains a session token
2. Self-registers the node at `/api/device/register` on the Controller
3. Starts a background task that pushes host metrics to the Controller every 30 seconds

After pairing, all Hypervisor logins are SSO-proxied to the Controller. The Controller also polls `GET /api/status` on demand for the Hypervisor page dashboard.

---

## API Reference

All endpoints require `Authorization: Bearer <token>` unless noted. Interactive API docs: `https://<node-ip>:8443/api/docs`.

### Auth

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/auth/status` | Setup and pairing status · **public** |
| `POST` | `/api/auth/setup` | First-run wizard — connect to Controller · **public** |
| `POST` | `/api/auth/login` | Authenticate locally; returns Bearer token · **public** |
| `POST` | `/api/auth/login-via-controller` | SSO — validate credentials against Controller · **public** |
| `POST` | `/api/auth/logout` | Invalidate current session token |

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
| `POST` | `/api/vms/{id}/clone` | Clone to a new name |
| `POST` | `/api/vms/{id}/migrate` | Live or offline migration (`{ "target_uri": "...", "live": true }`) |
| `POST` | `/api/vms/{id}/backup` | Create a backup |
| `POST` | `/api/vms/{id}/template` | Mark as template |
| `DELETE` | `/api/vms/{id}/template` | Unmark template |
| `GET` | `/api/vms/{id}/hardware` | Get hardware configuration |
| `PATCH` | `/api/vms/{id}/hardware` | Edit hardware (vCPU, memory, disk, NIC) |
| `GET` | `/api/vms/{id}/snapshots` | List snapshots |
| `POST` | `/api/vms/{id}/snapshots` | Create snapshot |
| `POST` | `/api/vms/{id}/snapshots/{name}/restore` | Restore snapshot |
| `DELETE` | `/api/vms/{id}/snapshots/{name}` | Delete snapshot |
| `GET` | `/api/vms/templates` | List all VM templates |
| `GET` | `/api/vms/backups` | List all VM backups |

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
| `GET` | `/api/storage/pools/{name}/volumes` | List volumes in a pool |
| `POST` | `/api/storage/pools/{name}/volumes` | Create a volume |
| `DELETE` | `/api/storage/pools/{name}/volumes/{vol}` | Delete a volume |
| `GET` | `/api/storage/isos/list` | List ISO images |
| `POST` | `/api/storage/isos/upload` | Upload an ISO |
| `DELETE` | `/api/storage/isos/{filename}` | Delete an ISO |

### Network

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/network` | List virtual networks |
| `POST` | `/api/network` | Create a virtual network |
| `DELETE` | `/api/network/{name}` | Delete a virtual network |
| `GET` | `/api/network/{name}/leases` | List DHCP leases for a network |

### Metrics

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/status` | Full host + VM/container metrics snapshot (polled by Controller) |
| `GET` | `/api/metrics/current` | Live host metrics |

### Console

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/vms/{id}/console` | noVNC WebSocket console (`?token=<token>`) |

### Cluster

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/cluster/nodes` | List cluster nodes |
| `GET` | `/api/cluster/peers` | Discover peer Hypervisors via the shared Controller |
| `POST` | `/api/cluster/nodes/join` | Add a peer node |
| `DELETE` | `/api/cluster/nodes/{id}` | Remove a node |
| `POST` | `/api/cluster/nodes/heartbeat` | Node heartbeat |
| `GET` | `/api/cluster/vms` | All VMs across all nodes |
| `GET` | `/api/cluster/containers` | All containers across all nodes |
| `GET` | `/api/cluster/isos` | All ISOs across all nodes |
| `GET` | `/api/cluster/nodes/{id}/vms` | VMs on a specific node |
| `GET` | `/api/cluster/nodes/{id}/metrics` | Metrics from a specific node |
| `POST` | `/api/cluster/nodes/{id}/vms/{vm_id}/{action}` | VM action on a specific node |
| `POST` | `/api/cluster/migrate` | Live VM migration (`virsh migrate --live --persistent --undefinesource`) |
| `GET` | `/api/cluster/summary` | Total resource counts and peer list |

### Controller Integration

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/nexis/status` | Pairing status and metrics feed health |
| `POST` | `/api/nexis/pair` | Pair with a NeXiS Controller |
| `POST` | `/api/nexis/unpair` | Remove Controller pairing |
| `POST` | `/api/nexis/command` | Execute a natural language command relayed from the Controller |

### System

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/system/info` | Hostname, version, and uptime |
| `GET` | `/api/system/logs` | Recent action log entries |

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

## Service Management

```bash
# View real-time logs
journalctl -u nexis-hypervisor-daemon -f

# Check service status
systemctl status nexis-hypervisor-daemon

# Restart the service
systemctl restart nexis-hypervisor-daemon
```

The service unit is installed at `/etc/systemd/system/nexis-hypervisor-daemon.service`.
