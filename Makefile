.PHONY: help default deps deps-force build check install-dev install-user rebuild apply list \
        vm-identity vm-identity-assign admit unadmit remove-tenant purge-tenant-state rotate-wifi-key reissue-state-secret reconcile \
        backup-status backup-now backup-dry-run backup-verify backup-restore backup-drive \
        bao-status bao-open bao-close bao-seal-migrate bao-rotate-shares \
        publish clean-deps clean-project deep-clean all

# ---------- Config ----------
COLLECTION_NAME ?= deevnet-mgmt
REQS           ?= collections/requirements.yml
DEPS_STAMP     ?= .deps.stamp

# User-level collections (shared across repos)
USER_COLLECTIONS_PATH    ?= $(HOME)/.ansible/collections

# Project-local collections (this repo only)
PROJECT_COLLECTIONS_PATH ?= ./.ansible/collections

default: help

help:
	@printf "%s\n" \
"Targets:" \
"" \
"  deps" \
"      Install Galaxy dependency collections at the user level (~/.ansible/collections)" \
"      Only runs when collections/requirements.yml changes" \
"" \
"  deps-force" \
"      Force reinstall Galaxy dependency collections at the user level" \
"" \
"  build" \
"      Build the local collection into a versioned .tar.gz artifact" \
"" \
"  check" \
"      Syntax-check every playbook, with no inventory or vault (CI runs this)" \
"" \
"  install-dev" \
"      Build and install the collection into ./.ansible/collections (this repo only)" \
"" \
"  install-user" \
"      Build and install the collection into ~/.ansible/collections (for other repos)" \
"" \
"  publish" \
"      deps + build + install-user (user-level publish, not system-wide)" \
"" \
"  rebuild" \
"      deps + install-dev" \
"" \
"  apply" \
"      install-dev + run playbooks/site.yml using local collections first" \
"" \
"  vm-identity" \
"      Audit management-plane VM identity and report the next free VMID" \
"" \
"  vm-identity-assign" \
"      vm-identity + allocate identity for management VMs that have none" \
"" \
"  admit NAME=<name> [MAC=AA-BB-CC-00-11-22]" \
"      Admit a tenant name: writes the handover details to ~/<name>-admission.txt (0600)" \
"" \
"  reconcile NAME=<name>|--all" \
"      Re-ensure tenants through the API (repairs what it owns, Grafana data sources included)" \
"" \
"  bao-status" \
"      Whether OpenBao is sealed or open" \
"" \
"  bao-open [WITHOUT_VAULT=1]" \
"      Open a work session: the vault's share and one of yours (two without the vault)" \
"" \
"  bao-close" \
"      Seal OpenBao (a restart), ending the work session" \
"" \
"  bao-rotate-shares [WITHOUT_VAULT=1]" \
"      In a work session: three new unseal shares, the old ones void, every pair proven; writes .openbao/<host>-shares.json" \
"" \
"  bao-seal-migrate" \
"      Once (CHG-0053): the static seal to three Shamir shares, every pair proven; writes .openbao/<host>-shares.json" \
"" \
"  backup-status" \
"      The last good backup (fails when one is overdue)" \
"" \
"  backup-now" \
"      Back up now, whatever the interval" \
"" \
"  backup-dry-run" \
"      Build an archive with no drive" \
"" \
"  backup-verify [SOURCE=drive|dry-run]" \
"      Decrypt the newest archive with the key from the vault and check it against its manifest" \
"" \
"  backup-restore CONFIRM=<host> [ARCHIVE=<name>]" \
"      Restore the newest (or named) archive into a rebuilt host whose registry and bucket are empty" \
"" \
"  backup-drive SERIAL=<serial>" \
"      ERASE the USB drive with that serial and make it a backup drive (asks for the serial again)" \
"" \
"  unadmit NAME=<name>" \
"      Revoke an admission that was never used (its Wi-Fi key stops working)" \
"" \
"  rotate-wifi-key NAME=<name> [KEY=admission]" \
"      Rotate a tenant's Wi-Fi key (new password, same key): writes ~/<name>-wifi-<key>.txt (0600)" \
"" \
"  reissue-state-secret NAME=<name>" \
"      A new state-store secret for a tenant (the old one stops working): writes ~/<name>-state-secret.txt (0600)" \
"" \
"  remove-tenant NAME=<name>" \
"      Take a tenant out of service: its workloads, the tenant, then its Terraform state" \
"" \
"  purge-tenant-state NAME=<name>" \
"      Remove a deleted tenant's leftover Terraform state, every version" \
"" \
"  list" \
"      Show installed collections in project and user paths" \
"" \
"  clean-deps" \
"      Remove dependency stamp (forces deps next time)" \
"" \
"  clean-project" \
"      Remove project-local collection install" \
"" \
"  deep-clean" \
"      Remove project + user collections and deps stamp"

# ---------- Deps ----------
$(DEPS_STAMP): $(REQS)
	ansible-galaxy collection install -r "$(REQS)" -p "$(USER_COLLECTIONS_PATH)"
	touch "$(DEPS_STAMP)"

deps: $(DEPS_STAMP)

deps-force:
	ansible-galaxy collection install -r "$(REQS)" --force -p "$(USER_COLLECTIONS_PATH)"
	touch "$(DEPS_STAMP)"

# ---------- Build ----------
build:
	ansible-galaxy collection build --force

# ---------- Check ----------
# Every playbook, parsed against localhost alone: no inventory, no vault.
check:
	@set -e; for p in $$(find playbooks -name '*.yml' | sort); do \
	  echo "syntax-check $$p"; \
	  ANSIBLE_HOST_PATTERN_MISMATCH=ignore ANSIBLE_LOCALHOST_WARNING=false \
	    ansible-playbook -i localhost, --syntax-check "$$p" >/dev/null; \
	done

# ---------- Install lanes ----------
install-dev: build
	@mkdir -p "$(PROJECT_COLLECTIONS_PATH)"
	@tarball="$$(ls -1t "$(COLLECTION_NAME)"-*.tar.gz 2>/dev/null | head -1)"; \
	test -n "$$tarball"; \
	echo "Installing tarball (dev): $$tarball"; \
	ansible-galaxy collection install "$$tarball" --force -p "$(PROJECT_COLLECTIONS_PATH)"

install-user: build
	@mkdir -p "$(USER_COLLECTIONS_PATH)"
	@tarball="$$(ls -1t "$(COLLECTION_NAME)"-*.tar.gz 2>/dev/null | head -1)"; \
	test -n "$$tarball"; \
	echo "Installing tarball (user): $$tarball"; \
	ansible-galaxy collection install "$$tarball" --force -p "$(USER_COLLECTIONS_PATH)"

# ---------- Workflows ----------
rebuild: deps install-dev

publish: deps install-user
	@echo "Published $(COLLECTION_NAME) to $(USER_COLLECTIONS_PATH)"

apply: install-dev
	@ANSIBLE_COLLECTIONS_PATH="$(PROJECT_COLLECTIONS_PATH):$(USER_COLLECTIONS_PATH)" \
	  ansible-playbook playbooks/site.yml

# Audit management-plane VM identity and report the next free VMID. Read-only:
# it surveys every hypervisor and every MAC in inventory, and writes nothing.
vm-identity: install-dev
	@ANSIBLE_COLLECTIONS_PATH="$(PROJECT_COLLECTIONS_PATH):$(USER_COLLECTIONS_PATH)" \
	  ansible-playbook playbooks/vm-identity.yml

# Same, then allocate identity for any management VM that has none, writing a
# generated identity.yml into the inventory repo. Run the opnsense_dhcp role
# against the core router before building a newly allocated VM.
vm-identity-assign: install-dev
	@ANSIBLE_COLLECTIONS_PATH="$(PROJECT_COLLECTIONS_PATH):$(USER_COLLECTIONS_PATH)" \
	  ansible-playbook playbooks/vm-identity.yml -e vm_identity_assign=true

# ---------- Inspection ----------
# Tenant admission (runbook: Tenant Admission). The operator token is read
# from the API container over SSH; see scripts/tenant-admission.sh.
admit:
	@./scripts/tenant-admission.sh admit "$(NAME)" "$(MAC)"

unadmit:
	@./scripts/tenant-admission.sh unadmit "$(NAME)"

# Re-ensure a tenant (or every tenant: NAME=--all) through the API, e.g. after
# the CA its Grafana data sources carry has changed (CHG-0031).
reconcile:
	@./scripts/tenant-reconcile.sh $(NAME)

# OpenBao work sessions (ADR-0042 §2, CHG-0053). It is sealed outside them.
BAO_PLAY = ANSIBLE_COLLECTIONS_PATH="$(PROJECT_COLLECTIONS_PATH):$(USER_COLLECTIONS_PATH)" \
	  ansible-playbook

bao-status: install-dev
	@$(BAO_PLAY) playbooks/openbao-session.yml -e openbao_session_action=status

bao-open: install-dev
	@$(BAO_PLAY) playbooks/openbao-session.yml -e openbao_session_action=open \
	  $(if $(WITHOUT_VAULT),-e openbao_session_without_vault=true)

bao-close: install-dev
	@$(BAO_PLAY) playbooks/openbao-session.yml -e openbao_session_action=close

# Once: the static seal to Shamir, keeping every secret (CHG-0053).
bao-seal-migrate: install-dev
	@$(BAO_PLAY) playbooks/openbao-seal-migrate.yml

# In a work session: three new shares, the old ones void, every pair proven.
bao-rotate-shares: install-dev
	@$(BAO_PLAY) playbooks/openbao-rotate-shares.yml \
	  $(if $(WITHOUT_VAULT),-e openbao_session_without_vault=true)

# Backup to the attached drive (CHG-0039). The role installs the job and the timer that runs it when one is due
# (site.yml --tags backup); these run it, check it and read an archive back.
BACKUP_PLAY = ANSIBLE_COLLECTIONS_PATH="$(PROJECT_COLLECTIONS_PATH):$(USER_COLLECTIONS_PATH)" \
	  ansible-playbook playbooks/backup.yml

backup-status: install-dev
	@$(BACKUP_PLAY) -e backup_action=status

backup-now: install-dev
	@$(BACKUP_PLAY) -e backup_action=run

backup-dry-run: install-dev
	@$(BACKUP_PLAY) -e backup_action=dry-run

backup-verify: install-dev
	@$(BACKUP_PLAY) -e backup_action=verify -e backup_verify_source=$(or $(SOURCE),drive)

# Into a host its roles have just rebuilt; refuses a registry or bucket that is
# not empty. Followed by: make reconcile NAME=--all
backup-restore: install-dev
	@$(BACKUP_PLAY) -e backup_action=restore -e backup_restore_confirm=$(CONFIRM) \
	  $(if $(ARCHIVE),-e backup_restore_archive=$(ARCHIVE),)

# Erases the drive named by SERIAL and makes it a backup drive; asks for the
# serial to be typed back.
backup-drive: install-dev
	@test -n "$(SERIAL)" || { echo "usage: make backup-drive SERIAL=<serial>"; exit 2; }
	@ANSIBLE_COLLECTIONS_PATH="$(PROJECT_COLLECTIONS_PATH):$(USER_COLLECTIONS_PATH)" \
	  ansible-playbook playbooks/backup-drive.yml -e backup_drive_serial=$(SERIAL)

# A new password for a tenant's Wi-Fi key; KEY defaults to the DVNTM-TD key
# the tenant was admitted with (runbook: Tenant Admission).
rotate-wifi-key:
	@./scripts/tenant-wifi-key.sh rotate "$(NAME)" "$(or $(KEY),admission)"

# A new state-store secret for a tenant that has lost the keys to its own state
# (CHG-0060). The old one stops working; the tenant must not restore from its
# old state afterwards (runbook: Lost State or Credentials).
reissue-state-secret:
	@./scripts/tenant-state-secret.sh reissue "$(NAME)"

# Tenant removal (runbook: Tenant Removal). Both ask for the name to be typed back.
remove-tenant:
	@./scripts/tenant-removal.sh remove "$(NAME)"

purge-tenant-state:
	@./scripts/tenant-removal.sh purge-state "$(NAME)"

list:
	@echo "== Project collections ($(PROJECT_COLLECTIONS_PATH)) =="
	@ANSIBLE_COLLECTIONS_PATH="$(PROJECT_COLLECTIONS_PATH)" ansible-galaxy collection list || true
	@echo
	@echo "== User collections ($(USER_COLLECTIONS_PATH)) =="
	@ANSIBLE_COLLECTIONS_PATH="$(USER_COLLECTIONS_PATH)" ansible-galaxy collection list || true

# ---------- Cleanup ----------
clean-deps:
	rm -f "$(DEPS_STAMP)"

clean-project:
	rm -rf "$(PROJECT_COLLECTIONS_PATH)"

deep-clean: clean-project
	rm -rf "$(USER_COLLECTIONS_PATH)"
	rm -f "$(DEPS_STAMP)"

all: rebuild apply
