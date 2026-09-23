# Gnoracle: an Oracle DAO on gno.land.
#
# THE TOOLCHAIN IS PINNED. gnoland-1 runs gno v1.2.0 and the interrealm rules
# move between releases, so the suites run against a gno built from that tag,
# with GNOROOT pointing at the same source in the Go module cache (its stdlibs
# and examples are what the chain has). `make toolchain` builds it once.
GNO_REF   ?= v1.2.0
GNO_STORE ?= $(HOME)/.cache/gno-toolchains/$(GNO_REF)
GNO       ?= $(GNO_STORE)/gno
GNOROOT   ?= $(shell go env GOMODCACHE)/github.com/gnolang/gno@$(GNO_REF)
export GNOROOT
# A repo-local download cache: the shared one under ~/Library/Application Support/gno
# holds copies from older releases that the v1.2.0 preprocessor rejects.
GNOHOME   ?= $(CURDIR)/.gnohome
export GNOHOME
GNODEV    ?= $(GNO_STORE)/gnodev
GNOKEY    ?= $(GNO_STORE)/gnokey
export GNOKEY

# Deployment target. The source is written for the namespace "clockwork" and
# `make build` rewrites it to NS; the decided mainnet namespace is the deployer
# address (see docs/IMPLEMENTATION_PLAN.md §16).
NS ?= g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm
export NS

PKGS := ./gno.land/...

.PHONY: help toolchain deps test test-p test-r lint fmt dev dev-keys chain-test build deploy clean

help: ## this list
	@grep -E "^[a-z-]+:.*## " $(MAKEFILE_LIST) | awk -F ":.*## " "{ printf \"  %-10s %s\\n\", \$$1, \$$2 }"

toolchain: ## build the pinned gno ($(GNO_REF)) into $(GNO_STORE) (once)
	@if [ ! -x "$(GNO)" ]; then \
		echo "building gno $(GNO_REF) into $(GNO_STORE) (once)"; \
		mkdir -p "$(GNO_STORE)"; \
		GOBIN="$(GNO_STORE)" go install "github.com/gnolang/gno/gnovm/cmd/gno@$(GNO_REF)" || exit 1; \
	fi; \
	echo "gno: $(GNO)"; echo "GNOROOT: $(GNOROOT)"

deps: ## mirror on-chain dependencies into deps/ (needed for the realms, not the pure packages)
	@./scripts/deps.sh

test: toolchain deps ## run every suite under gno.land/
	$(GNO) test $(PKGS)

test-p: toolchain deps ## pure packages only
	$(GNO) test ./gno.land/p/...

test-r: toolchain deps ## realms only
	$(GNO) test ./gno.land/r/...

lint: toolchain deps ## gno lint
	$(GNO) lint $(PKGS)

fmt: toolchain ## gno fmt, in place
	$(GNO) fmt -w $(PKGS)

# Ports: override when another local chain already holds the defaults,
# e.g. make dev RPC=36657 WEB=38888 (chain-test then needs REMOTE=http://127.0.0.1:36657).
RPC ?= 26657
WEB ?= 8888

dev: toolchain deps ## local chain + gnoweb at http://127.0.0.1:$(WEB)/r/clockwork/gnoracle/core
	$(GNODEV) local -node-rpc-listener 127.0.0.1:$(RPC) -web-listener 127.0.0.1:$(WEB) -paths gno.land/r/clockwork/gnoracle/core,gno.land/r/clockwork/gnoracle/core/impl/v1 -web-home /r/clockwork/gnoracle/core .

chain-test: ## drive a running gnodev through a feed lifecycle with gnokey (needs make dev in another shell)
	@./scripts/chain-test.sh

dev-keys: ## throwaway keybase with the public test1 key, for the local chain
	@./scripts/dev-keys.sh

build: ## build/ with paths rewritten to NS
	@./scripts/deploy.sh build

deploy: ## addpkg every package under NS (skips what is live)
	@./scripts/deploy.sh deploy

clean: ## remove build/, deps/ and the local download cache
	rm -rf build deps .gnohome
