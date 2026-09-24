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

.PHONY: help toolchain deps test test-p test-r lint fmt dev dev-keys chain-test build deploy clean go-build go-test agent-dev bot-dev docker sim agent-soak demo demo-stop

help: ## this list
	@grep -E "^[a-z-]+:.*## " $(MAKEFILE_LIST) | awk -F ":.*## " "{ printf \"  %-10s %s\\n\", \$$1, \$$2 }"

toolchain: ## build the pinned gno and gnokey ($(GNO_REF)) into $(GNO_STORE) (once)
	@if [ ! -x "$(GNO)" ]; then \
		echo "building gno $(GNO_REF) into $(GNO_STORE) (once)"; \
		mkdir -p "$(GNO_STORE)"; \
		GOBIN="$(GNO_STORE)" go install "github.com/gnolang/gno/gnovm/cmd/gno@$(GNO_REF)" || exit 1; \
	fi; \
	if [ ! -x "$(GNOKEY)" ]; then \
		echo "building gnokey $(GNO_REF) into $(GNO_STORE) (once; make deps reads the chain with it)"; \
		mkdir -p "$(GNO_STORE)"; \
		GOBIN="$(GNO_STORE)" go install "github.com/gnolang/gno/gno.land/cmd/gnokey@$(GNO_REF)" || exit 1; \
	fi; \
	if [ ! -d "$(GNOROOT)/gnovm/stdlibs" ]; then \
		echo "fetching the gno $(GNO_REF) sources for GNOROOT (stdlibs)"; \
		go mod download "github.com/gnolang/gno@$(GNO_REF)" || exit 1; \
	fi; \
	echo "gno: $(GNO)"; echo "gnokey: $(GNOKEY)"; echo "GNOROOT: $(GNOROOT)"

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

# Ports. The dev configs (configs/*.dev.toml, scripts/agent-soak.sh) and the
# documented chain-test invocation use 36657/38888, so that a second gnodev on
# the stock ports can coexist; run `make dev RPC=36657 WEB=38888` to match them.
RPC ?= 26657
WEB ?= 8888
DEV_PATHS ?= gno.land/r/clockwork/gnoracle/core,gno.land/r/clockwork/gnoracle/core/impl/v1,gno.land/r/clockwork/gnoracle/core/impl/v2,gno.land/r/clockwork/gnoracle/token,gno.land/r/clockwork/gnoracle/dao,gno.land/r/clockwork/gnoracle/dao/impl/v1,gno.land/r/clockwork/gnoracle/dao/impl/v2,gno.land/r/clockwork/gnoracle/dao/exec,gno.land/r/clockwork/gnoracle/kourtdev,gno.land/r/clockwork/gnoracle/kourt,gno.land/r/clockwork/gnoracle/kourt/impl/v1,gno.land/r/clockwork/gnoracle/kourt/impl/kourtv3,gno.land/r/clockwork/gnoracle/demo/reader

dev: toolchain deps ## local chain + gnoweb (RPC=36657 WEB=38888 matches the dev configs); do not edit the tree while it runs
	$(GNODEV) local -node-rpc-listener 127.0.0.1:$(RPC) -web-listener 127.0.0.1:$(WEB) -paths $(DEV_PATHS) -web-home /r/clockwork/gnoracle/core .

chain-test: ## drive a running gnodev through a feed lifecycle with gnokey (needs make dev in another shell)
	@./scripts/chain-test.sh

dev-keys: ## throwaway keybase with the public test1 key, for the local chain
	@./scripts/dev-keys.sh

build: ## build/ with paths rewritten to NS
	@./scripts/deploy.sh build

deploy: ## addpkg every package under NS (skips what is live)
	@./scripts/deploy.sh deploy

# ---- off-chain tools (Go): provider agent, notifier/cranker bot, operator CLI

go-build: ## build bin/gnoracle, bin/gnoracle-agent, bin/gnoracle-bot
	CGO_ENABLED=0 go build -o bin/ ./cmd/...

go-test: ## unit tests of the Go tools
	go test ./...

agent-dev: go-build ## run a provider agent (prov2) against the local chain on RPC=$(RPC)
	GNORACLE_KEY_PASSWORD=$${GNOKEY_PASSWORD:-devpassword} ./bin/gnoracle-agent -config configs/agent.dev.toml

bot-dev: go-build ## run the bot against the local chain, messages to the log
	GNORACLE_KEY_PASSWORD=$${GNOKEY_PASSWORD:-devpassword} ./bin/gnoracle-bot -config configs/bot.dev.toml

agent-soak: ## run several agents and the bot against the local chain for a few minutes and assert (needs chain-test first)
	@./scripts/agent-soak.sh

demo: ## the whole story on a local chain in a few minutes: feed, agents, a reader realm, a dispute, the DAO ballot, the Kourt claim (RESET=1 to start clean)
	@$(if $(filter command line,$(origin RPC)),RPC=$(RPC)) $(if $(filter command line,$(origin WEB)),WEB=$(WEB)) ./scripts/demo.sh

demo-stop: ## stop the agents, bot and pollers the demo left running (KEEP_CHAIN=1 leaves a chain the demo started)
	@./scripts/demo.sh stop

docker: ## build the gnoracle image with the three tools
	docker build -t gnoracle .

sim: ## regenerate docs/SIMULATION.md from the plan's parameters and measured gas
	go run ./sim > docs/SIMULATION.md

clean: ## remove build/, bin/, deps/ and the local download cache
	rm -rf build bin deps .gnohome
