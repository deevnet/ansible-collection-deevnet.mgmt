.PHONY: help default deps deps-force build install-dev install-user rebuild apply list \
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

# ---------- Inspection ----------
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
