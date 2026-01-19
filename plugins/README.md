# Plugins

This directory contains custom Ansible plugins for the `deevnet.mgmt` collection.

## Structure

```
plugins/
├── action/          # Action plugins
├── callback/        # Callback plugins
├── filter/          # Filter plugins
├── inventory/       # Inventory plugins
├── lookup/          # Lookup plugins
├── modules/         # Custom modules
└── module_utils/    # Shared module utilities
```

## Usage

Plugins in this collection are automatically available when the collection is installed. Reference them using the fully qualified collection name:

```yaml
# Example filter usage
- name: Example task
  debug:
    msg: "{{ some_var | deevnet.mgmt.custom_filter }}"
```

## Development

When adding new plugins, follow Ansible's plugin development guidelines and ensure proper documentation is included in each plugin file.
