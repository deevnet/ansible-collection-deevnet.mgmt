# deevnet.mgmt

Ansible collection for management plane services including centralized logging, monitoring, and observability infrastructure.

## Overview

This collection provides roles for deploying and configuring management services in the deevnet virtual control plane.

Management-plane workloads are **Ansible-only by design** — they carry no Terraform state. See
`architecture/substrate/management-plane/extended-services.md` §5.

### Roles

| Role | Purpose |
|------|---------|
| `proxmox_vm` | Clone a management-plane VM from a Packer-built Proxmox template |
| `vm_identity` | Allocate and audit VMID-derived MACs for management-plane VMs |
| `data_disk` | Guest-side half of a `proxmox_vm` data disk |
| `podman_service` | Run one container under systemd from an image pushed from the control node. Shared by every container role below. |
| `powerdns` | PowerDNS Authoritative serving per-tenant delegated zones (ADR-0004), in the identity VM |
| `minio` | Tenant Terraform state store (ADR-0007), in the provisioning VM |
| `deevnet_api` | The Deevnet API and its PostgreSQL database (ADR-0012), in the provisioning VM |
| `omada_controller` | The site's Omada controller (ADR-0009), in the network management VM |
| `mosquitto` | MQTT broker (to be replaced by VerneMQ in the messaging VM, ADR-0012 §8) |

Services are grouped into domain VMs on the management hypervisor, each on exactly one segment
(ADR-0013): network management and substrate observability on management; provisioning, identity
and tenant observability on Platform; device messaging on IoT Backend.

### Planned

- **Centralized Logging** - Log aggregation and analysis
- **Monitoring** - Grafana dashboards and metrics collection
- **Observability** - Unified visibility into infrastructure health

These land in the two observability VMs (ADR-0013 §5): substrate observability on management,
tenant observability on Platform.

## Requirements

- Ansible >= 2.14
- Target systems: Fedora/RHEL
- Collections: `ansible.posix`, `community.general`
- **On the control node**: `proxmoxer` and `requests`, required by `community.general.proxmox_kvm`.
  Note that `deevnet.net`'s `proxmox_node_network` role deliberately uses raw `ansible.builtin.uri`
  to avoid this dependency; `proxmox_vm` accepts it in exchange for not hand-rolling clone,
  cloud-init and lifecycle handling.

  ```bash
  pip install proxmoxer requests
  ```

## Installation

### From source (development)

```bash
# Clone the repository
git clone https://github.com/deevnet/ansible-collection-deevnet.mgmt.git
cd ansible-collection-deevnet.mgmt

# Install dependencies and build
make rebuild
```

### User-level install

```bash
make publish  # Installs to ~/.ansible/collections
```

## Usage

### Run the main playbook

```bash
# Apply all roles to configured hosts
make apply

# Or run directly
ansible-playbook playbooks/site.yml
```

### Limit to specific hosts

```bash
ansible-playbook playbooks/site.yml --limit management_plane   # create the VMs
ansible-playbook playbooks/site.yml --limit tenant_dns
ansible-playbook playbooks/site.yml --limit deevnet_api
```

## Collection Structure

```
deevnet.mgmt/
├── galaxy.yml              # Collection metadata
├── ansible.cfg             # Development configuration
├── Makefile                # Build automation
├── meta/runtime.yml        # Ansible version requirements
├── collections/            # External dependencies
│   └── requirements.yml
├── playbooks/
│   └── site.yml           # Main playbook
├── roles/                  # Collection roles (to be added)
└── plugins/                # Custom plugins (if needed)
```

## Makefile Targets

| Target | Description |
|--------|-------------|
| `deps` | Install Galaxy dependencies |
| `deps-force` | Force reinstall dependencies |
| `build` | Build collection tarball |
| `install-dev` | Install to project-local path |
| `install-user` | Install to user-level path |
| `rebuild` | deps + install-dev |
| `publish` | deps + install-user |
| `apply` | install-dev + run site.yml |
| `list` | Show installed collections |
| `clean-*` | Various cleanup targets |

## Dependencies

- `ansible.posix` >= 1.5.0

## License

MIT

## Author

Chris Deever
