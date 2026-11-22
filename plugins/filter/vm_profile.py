"""Filter plugins for checking VMs against the VM hardware profile (ADR-0046).

The profile is declared once in inventory (`deevnet_vm_profile`). These are pure
functions over what the Proxmox API reports for each VM (`proxmox_vm_info`
with `config: current`), so the comparison is testable without a hypervisor
and the same from any control node.

Each VM gets one result:
  compliant   matches the profile
  exception   differs only where its inventory entry declares, with the reason
  drift       differs anywhere else; each difference is named
"""

import re

# What Proxmox uses when a VM's configuration leaves a key out. A profile value
# is compared with the effective value, so an absent key is not a difference
# when the profile asks for the default.
PROXMOX_DEFAULTS = {
    'scsihw': 'lsi',
    'bios': 'seabios',
    'machine': 'i440fx',
    'cpu': 'default',
    'iothread': '0',
    'discard': 'ignore',
    'cache': 'none',
}

DISK_KEY = re.compile(r'^(scsi|sata|ide|virtio)(\d+)$')
NET_KEY = re.compile(r'^net(\d+)$')
NET_MODELS = ('virtio', 'e1000', 'e1000e', 'rtl8139', 'vmxnet3')


def _options(value):
    """Split a Proxmox drive or NIC string into its volume and its options."""
    parts = str(value).split(',')
    opts = {}
    for part in parts[1:]:
        if '=' in part:
            k, v = part.split('=', 1)
            opts[k] = v
    return parts[0], opts


def _machine(value):
    """Reduce a machine type to its family: q35 or i440fx (Proxmox's default)."""
    if not value:
        return PROXMOX_DEFAULTS['machine']
    value = str(value)
    if 'q35' in value:
        return 'q35'
    return 'i440fx'


def _agent(value):
    if value is None:
        return False
    value = str(value)
    if value in ('1', 'true', 'True'):
        return True
    _, opts = _options('x,' + value)
    return opts.get('enabled') in ('1', 'true') or value.startswith('1,') or value.startswith('enabled=1')


def _effective(profile):
    """The profile with every value as a string the API's values compare to."""
    disk = profile.get('disk', {}) or {}
    machine = profile.get('machine') or PROXMOX_DEFAULTS['machine']
    return {
        'scsihw': str(profile.get('scsihw', PROXMOX_DEFAULTS['scsihw'])),
        'disk_bus': str(profile.get('disk_bus', 'scsi')),
        'iothread': str(disk.get('iothread', PROXMOX_DEFAULTS['iothread'])),
        'discard': str(disk.get('discard', PROXMOX_DEFAULTS['discard'])),
        'cache': str(disk.get('cache', PROXMOX_DEFAULTS['cache'])),
        'net_model': str(profile.get('net_model', 'virtio')),
        'cpu': str(profile.get('cpu', PROXMOX_DEFAULTS['cpu'])),
        'bios': str(profile.get('bios', PROXMOX_DEFAULTS['bios'])),
        'machine': _machine(machine),
        'agent': bool(profile.get('agent', True)),
    }


def vm_hardware(config):
    """Read the profile's parts from one VM's configuration.

    Returns a list of (part, observed) pairs. A part that occurs once per disk
    or NIC is named after it ('scsi0 iothread', 'net0 model').
    """
    config = config or {}
    seen = [
        ('scsihw', str(config.get('scsihw', PROXMOX_DEFAULTS['scsihw']))),
        ('cpu', str(config.get('cpu', PROXMOX_DEFAULTS['cpu'])).split(',')[0]),
        ('bios', str(config.get('bios', PROXMOX_DEFAULTS['bios']))),
        ('machine', _machine(config.get('machine'))),
        ('agent', _agent(config.get('agent'))),
    ]
    for key in sorted(config):
        m = DISK_KEY.match(key)
        if m:
            volume, opts = _options(config[key])
            if opts.get('media') == 'cdrom' or volume == 'none':
                continue
            seen.append(('%s bus' % key, m.group(1)))
            for opt in ('iothread', 'discard', 'cache'):
                seen.append(('%s %s' % (key, opt), str(opts.get(opt, PROXMOX_DEFAULTS[opt]))))
            continue
        m = NET_KEY.match(key)
        if m:
            first, _ = _options(config[key])
            model = first.split('=', 1)[0]
            seen.append(('%s model' % key, model if model in NET_MODELS else first))
    return seen


def _expected(part, want):
    """What the profile (with any exception applied) says for one part."""
    if part.endswith(' bus'):
        return want['disk_bus']
    if part.endswith(' model'):
        return want['net_model']
    last = part.split(' ')[-1]
    return want[last]


def vm_profile_check(vms, profile, exceptions=None):
    """Check every VM the Proxmox API reported against the profile.

    Args:
        vms: proxmox_vm_info's `proxmox_vms` entries, each with `config`.
        profile: the inventory's `deevnet_vm_profile`.
        exceptions: VM name -> its `vm_profile_exceptions` (profile keys it
            differs in, plus `reason`).

    Returns:
        One dict per VM, sorted by node and VMID: vmid, name, node,
        template, result, reason, and diffs (each 'part: is X, profile Y').
    """
    exceptions = exceptions or {}
    base = _effective(profile or {})
    results = []
    for vm in vms or []:
        if vm.get('type', 'qemu') != 'qemu':
            continue
        name = vm.get('name', '')
        exc = exceptions.get(name) or {}
        override = {k: v for k, v in exc.items() if k != 'reason'}
        merged = dict(profile or {})
        if 'disk' in override:
            merged['disk'] = dict((profile or {}).get('disk', {}) or {}, **override.pop('disk'))
        merged.update(override)
        want = _effective(merged)

        drift, excepted = [], []
        for part, observed in vm_hardware(vm.get('config')):
            expected = _expected(part, want)
            if observed == expected:
                if expected != _expected(part, base):
                    excepted.append(part)
                continue
            drift.append('%s: is %s, profile %s' % (part, observed, expected))

        if drift:
            result = 'drift'
        elif excepted:
            result = 'exception'
        else:
            result = 'compliant'
        results.append({
            'vmid': int(vm.get('vmid', 0)),
            'name': name,
            'node': vm.get('node', ''),
            'template': bool(vm.get('template')),
            'result': result,
            'reason': exc.get('reason', '') if result == 'exception' or (exc and drift) else '',
            'diffs': drift,
        })
    return sorted(results, key=lambda r: (r['node'], r['vmid']))


class FilterModule:
    def filters(self):
        return {
            'vm_profile_check': vm_profile_check,
        }
