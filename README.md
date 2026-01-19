# deevnet.mgmt

Ansible collection for management plane services including centralized logging, monitoring, and observability infrastructure.

## Overview

This collection provides roles for deploying and configuring management services in the deevnet virtual control plane:

- **Centralized Logging** - Log aggregation and analysis
- **Monitoring** - Grafana dashboards and metrics collection
- **Observability** - Unified visibility into infrastructure health

## Requirements

- Ansible >= 2.14
- Target systems: Fedora/RHEL

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
ansible-playbook playbooks/site.yml --limit logging_servers
ansible-playbook playbooks/site.yml --limit monitoring_servers
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
