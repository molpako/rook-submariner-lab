SHELL := /usr/bin/env bash

.PHONY: all setup clusters prepare-libvirt-network preload-images preload-rook-images preload-submariner-images preload-app-images submariner globalnet-test rook mirror sync sample verify profiles sync-kubeconfig clean-clusters reset

all: setup clusters preload-images submariner globalnet-test rook mirror sample sync verify

setup:
	./scripts/00-setup.sh

profiles:
	@./scripts/80-profile-list.sh

sync-kubeconfig:
	./scripts/82-sync-kubeconfig.sh

clean-clusters:
	./scripts/90-clean-clusters.sh

reset:
	$(MAKE) clean-clusters
	$(MAKE) all

clusters: prepare-libvirt-network
	./scripts/10-create-clusters.sh

prepare-libvirt-network:
	./scripts/12-prepare-libvirt-network.sh

preload-images:
	./scripts/18-preload-images.sh all

preload-rook-images:
	./scripts/18-preload-images.sh rook

preload-submariner-images:
	./scripts/18-preload-images.sh submariner

preload-app-images:
	./scripts/18-preload-images.sh app

submariner: preload-submariner-images
	./scripts/20-install-submariner.sh

globalnet-test: preload-app-images
	./scripts/47-validate-globalnet.sh

rook: preload-rook-images
	./scripts/30-install-rook.sh

mirror:
	./scripts/40-configure-rbd-mirror.sh

sync:
	./scripts/48-sync-rbd-mirror.sh

sample: preload-app-images
	./scripts/45-deploy-sample.sh

verify:
	./scripts/50-verify.sh
