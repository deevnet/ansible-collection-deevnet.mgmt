# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is the `deevnet.mgmt` Ansible collection for management plane services. It provides roles for centralized logging, monitoring (Grafana), and observability infrastructure. The collection supports Fedora/RHEL systems.

Roles map to ADRs in `deevnet-docs`: `powerdns` (ADR-0004), `minio` (ADR-0007),
`deevnet_api` (ADR-0012, ADR-0015), `openbao` (ADR-0016), `omada_controller` (ADR-0009, ADR-0013). `logging` and
`grafana` are planned, not implemented.

## Rules that are easy to get wrong

- **No Terraform here.** Management-plane workloads are Ansible-only
  (`extended-services.md` §5). That is not an oversight to be corrected.
- **Addressing follows the segment.** A domain VM on management is addressed by
  DHCP reservation: the MAC is declared in inventory, the core router's Kea
  reservation pins the address to it, and the A record follows. Platform and
  IoT Backend have no DHCP pool, so VMs there set `dhcp_reservation: false` and
  take `static_ip`/`static_gateway`/`nameserver` through cloud-init. The derived
  MAC is still asserted either way.
- **One VM, one segment** (ADR-0013 §2). A domain that needs two segments is
  two VMs, never a second NIC.
- **Container roles go through `podman_service`.** It pushes the image tarball
  from the control node's image store (`/srv/deevnet-http/container-images`),
  loads it, creates the container from a recorded definition, and runs it
  under systemd. Don't reintroduce `get_url` from the artifact server: Platform
  and IoT Backend VMs have no path back to management under the zone policy.
- **Secrets reach containers through `podman_service_env`**, which becomes a
  root-only env file. Never put them in `podman_service_create_args`.
- **Never pin a template VMID.** Proxmox reassigns it on every image-factory
  rebuild. `proxmox_vm` matches the template by name prefix and takes the newest.
- **`powerdns` creates zones and keys, never records.** Records are tenant
  content, written by the tenant's own Terraform over RFC 2136 (ADR-0004). A
  TSIG key is bound to one tenant's zones, which is what makes the namespace
  boundary a control rather than a convention.
- **OpenBao is configured over its HTTP API with `ansible.builtin.uri`**, not
  `community.hashi_vault`, whose modules need `hvac`, which the Builder lacks.
  After first initialisation Ansible works through its own AppRole
  (`vault_openbao_ansible_*`); the root token is revoked in the same run.
- **The Deevnet API holds only its AppRole.** Its backend credentials are written
  into OpenBao KV by the `deevnet_api` role, never into its env file.
- **TSIG secrets are imported from the vault, not generated on the server.**
  A generated key would not survive a rebuild, and every tenant's Terraform
  would need re-issuing.

## Commands

Run `make help` for build targets. Note this collection splits install into
`install-dev` (project-local) and `install-user` (user-level) — there is no plain
`make install`. The playbook requires the external inventory at
`../ansible-inventory-deevnet/dvntm` (see `ansible.cfg`).

## Variable Conventions

When implementing roles, follow these patterns:
- `logging_*` - Logging role configuration
- `grafana_*` - Grafana role configuration
- Role-specific variables should be prefixed with the role name

## Notes

- All roles assume Fedora/RHEL (uses `dnf`, systemd)
- Remote user is `a_autoprov` with become enabled
- Inventory is external to this repo (see `ansible.cfg`)
- This collection is part of the deevnet virtual control plane alongside `deevnet.builder`
