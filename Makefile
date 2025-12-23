FLAKE ?= .
HOST ?= cgit
TARGET ?= root@git.sdko.net
FLAKE_REF := $(FLAKE)\#$(HOST)
NIX ?= nix

.PHONY: switch build update fmt help install

switch: ## Build and activate configuration on remote host
	$(NIX) run nixpkgs\#nixos-rebuild -- switch --flake $(FLAKE_REF) --target-host $(TARGET) --build-host $(TARGET) --sudo

build: ## Build configuration without activating
	$(NIX) build $(FLAKE)\#nixosConfigurations.$(HOST).config.system.build.toplevel

update: ## Update flake inputs
	$(NIX) flake update

fmt: ## Format Nix files
	$(NIX) fmt

install: ## Initial NixOS installation via nixos-anywhere
	$(NIX) run github:nix-community/nixos-anywhere -- --flake $(FLAKE_REF) $(TARGET)

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*##"; printf "Available targets:\\n"} /^[a-zA-Z0-9_.-]+:.*##/ {printf "  %-16s %s\\n", $$1, $$2}' $(MAKEFILE_LIST)
