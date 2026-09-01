# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is the `deevnet.mgmt` Ansible collection for management plane services. It provides roles for centralized logging, monitoring (Grafana), and observability infrastructure. The collection supports Fedora/RHEL systems.

## Repository Structure

```
repo-root/                 # Collection root = git repo root (Galaxy-compatible layout)
├── galaxy.yml             # Collection metadata (declares ansible.posix dependency)
├── meta/runtime.yml       # Ansible version requirement
├── ansible.cfg            # Development config (uses external inventory)
├── Makefile               # Build/install automation
├── playbooks/site.yml     # Main playbook
├── roles/
│   ├── proxmox_vm/        # Clone a mgmt-plane VM from a Packer template
│   ├── powerdns/          # Tenant authoritative DNS (ADR-0004)
│   ├── logging/           # (planned) Centralized log aggregation
│   ├── grafana/           # (planned) Grafana dashboards and monitoring
│   └── ...
└── plugins/               # Custom plugins (if needed)
```

## Rules that are easy to get wrong

- **No Terraform here.** Management-plane workloads are Ansible-only
  (`extended-services.md` §5). That is not an oversight to be corrected.
- **Management VMs are addressed by DHCP reservation, not static cloud-init.**
  The MAC is declared in inventory, the core router's Kea reservation pins the
  address to it, and the A record follows. Static `ipconfig` is the *tenant*
  pattern, correct there only because EVPN zones have no DHCP at all.
- **Never pin a template VMID.** Proxmox reassigns it on every image-factory
  rebuild. `proxmox_vm` matches the template by name prefix and takes the newest.
- **`powerdns` creates zones and keys, never records.** Records are tenant
  content, written by the tenant's own Terraform over RFC 2136 (ADR-0004). A
  TSIG key is bound to one tenant's zones, which is what makes the namespace
  boundary a control rather than a convention.
- **TSIG secrets are imported from the vault, not generated on the server.**
  A generated key would not survive a rebuild, and every tenant's Terraform
  would need re-issuing.

## Common Commands

Using the Makefile (recommended):
```bash
make deps      # Install ansible.posix dependency
make build     # Build collection tarball
make install-dev   # Install tarball to project-local path
make install-user  # Install tarball to user-level path
make rebuild   # deps + install-dev
make publish   # deps + install-user
make apply     # install-dev + run playbook
make list      # Show installed collections
```

Manual commands (from repo root):
```bash
ansible-galaxy collection build --force
ansible-galaxy collection install deevnet-mgmt-*.tar.gz --force
```

Run the main playbook (requires inventory at `../ansible-inventory-deevnet/dvntm`):
```bash
ansible-playbook playbooks/site.yml
```

Run against specific hosts (when roles are implemented):
```bash
ansible-playbook playbooks/site.yml --limit logging_servers
ansible-playbook playbooks/site.yml --limit monitoring_servers
ansible-playbook playbooks/site.yml --limit mgmt_plane
```

Syntax check:
```bash
ansible-playbook playbooks/site.yml --syntax-check
```

## Planned Roles

### logging
Centralized log aggregation service. Will likely include:
- Log collector configuration
- Log forwarding rules
- Retention policies

### grafana
Monitoring dashboards and visualization. Will likely include:
- Grafana server deployment
- Dashboard provisioning
- Data source configuration
- Alert rules

## Variable Conventions

When implementing roles, follow these patterns:
- `logging_*` - Logging role configuration
- `grafana_*` - Grafana role configuration
- Role-specific variables should be prefixed with the role name

### Inventory Groups
The playbook will expect these groups:
- `logging_servers` - Centralized log aggregation hosts
- `monitoring_servers` - Grafana and metrics collection hosts
- `mgmt_plane` - General management plane hosts

## Notes

- All roles assume Fedora/RHEL (uses `dnf`, systemd)
- Remote user is `a_autoprov` with become enabled
- Inventory is external to this repo (see `ansible.cfg`)
- This collection is part of the deevnet virtual control plane alongside `deevnet.builder`
