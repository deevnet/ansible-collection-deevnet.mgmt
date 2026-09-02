"""Filter plugins for management-plane VM identity allocation.

A management VM's MAC is derived from its Proxmox VMID rather than invented,
so adding a management VM is "allocate a VMID" and everything else follows.
These are pure functions: the derivation is testable without a hypervisor, and
identical on every run from any control node.
"""

# The MAC suffix is three octets, so this is the largest encodable VMID.
VMID_CEILING = 0xFFFFFF


def vmid_to_mac(vmid, namespace):
    """Derive a deterministic MAC from a Proxmox VMID.

    The suffix is the VMID big-endian across three octets, so a MAC reads back
    to its VM at a glance in the PVE UI.

    Args:
        vmid: Proxmox VMID (int or numeric string), 1..16777215.
        namespace: The three-octet prefix, e.g. '02:de:20'.

    Returns:
        A lowercase colon-separated MAC, e.g. vmid 200 -> '02:de:20:00:00:c8'.

    Raises:
        ValueError: If the VMID is outside the encodable range, or the
            namespace is not three hex octets.
    """
    vmid = int(vmid)
    if not 0 < vmid <= VMID_CEILING:
        raise ValueError(
            'vmid %d out of range: must be 1-%d to fit three MAC octets'
            % (vmid, VMID_CEILING)
        )

    namespace = str(namespace).lower()
    octets = namespace.split(':')
    if len(octets) != 3 or not all(
        len(o) == 2 and all(c in '0123456789abcdef' for c in o) for o in octets
    ):
        raise ValueError(
            "mac namespace %r is not three hex octets like '02:de:20'"
            % namespace
        )

    return '%s:%02x:%02x:%02x' % (
        namespace, vmid >> 16, (vmid >> 8) & 0xFF, vmid & 0xFF
    )


def free_vmids(used, start, end, count=1):
    """Return the lowest `count` VMIDs in [start, end] that are not in `used`.

    Allocating the whole batch in one call is deliberate: two new hosts in a
    single run must not be handed the same ID.

    Args:
        used: Iterable of VMIDs already taken, anywhere in the substrate.
        start: First VMID of the allocation range, inclusive.
        end: Last VMID of the allocation range, inclusive.
        count: How many free VMIDs to return.

    Returns:
        A list of `count` ints, ascending.

    Raises:
        ValueError: If the range does not hold `count` free VMIDs.
    """
    taken = {int(v) for v in used}
    found = []
    for candidate in range(int(start), int(end) + 1):
        if candidate not in taken:
            found.append(candidate)
            if len(found) == int(count):
                return found

    raise ValueError(
        'only %d free VMIDs in %s-%s, need %d - widen deevnet_mgmt_vmid_range'
        % (len(found), start, end, count)
    )


class FilterModule:
    def filters(self):
        return {
            'vmid_to_mac': vmid_to_mac,
            'free_vmids': free_vmids,
        }
