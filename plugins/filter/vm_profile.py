"""The vm_profile_check filter: VMs against the VM hardware profile (ADR-0046).

The comparison itself is deevnet.builder's module_utils/vm_profile.py, the one
the health watcher on the Builder also runs, so `make vm-profile` and the
watcher cannot disagree. See there for what each result means.
"""

from ansible_collections.deevnet.builder.plugins.module_utils.vm_profile import vm_profile_check


class FilterModule:
    def filters(self):
        return {
            'vm_profile_check': vm_profile_check,
        }
