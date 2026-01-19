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
├── playbooks/site.yml     # Main playbook (placeholder for future roles)
├── roles/                 # Collection roles (empty - to be developed)
│   ├── logging/           # (planned) Centralized log aggregation
│   ├── grafana/           # (planned) Grafana dashboards and monitoring
│   └── ...
└── plugins/               # Custom plugins (if needed)
```

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
