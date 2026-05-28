# `make help` is the canonical source of truth for shared Swift targets.
# Project-specific commands stay in `Tools/cell-tunnel-dev.swift`.

CONFIG ?= Debug
CELL_TUNNEL_DEV := swift Tools/cell-tunnel-dev.swift
ACTIVATION_TARGET_USAGE := mac|iphone|iphone-simulator
BUILD_TARGET_USAGE := daemon|mac|iphone-simulator|iphone-device|all

SWIFT_MK_MODULES := swift-build.mk

SWIFT_BUILD_CMD ?= $(if $(strip $(TARGET)),$(CELL_TUNNEL_DEV) build $(TARGET) $(CONFIG),printf 'build: TARGET=$(BUILD_TARGET_USAGE) is required\n'; exit 1)
SWIFT_TEST_CMD ?= $(CELL_TUNNEL_DEV) test
SWIFT_RUN_CMD ?= $(if $(strip $(TARGET)),$(CELL_TUNNEL_DEV) activate $(TARGET) $(CONFIG),printf 'run: TARGET=$(ACTIVATION_TARGET_USAGE) is required\n'; exit 1)
SWIFT_GENERATE_CMD ?= $(CELL_TUNNEL_DEV) generate
SWIFT_CLEAN_CMD ?= $(CELL_TUNNEL_DEV) clean
SWIFT_DEPLOY_CMD ?= $(if $(strip $(TARGET)),$(CELL_TUNNEL_DEV) activate $(TARGET) $(CONFIG),printf 'deploy: TARGET=$(ACTIVATION_TARGET_USAGE) is required\n'; exit 1)
SWIFT_ANALYZE_CMD ?= $(CELL_TUNNEL_DEV) analyze
SWIFT_LOG_AUDIT_CMD ?= $(CELL_TUNNEL_DEV) log-audit

SWIFT_SOURCE_ROOTS := Apps Sources Tests Tools/CellTunnelCtl Tools/CellTunnelDev Tools/LoggingAudit
SWIFT_GENERATED_SOURCE_ROOTS := Sources/CellTunnelCore/Generated
SWIFT_OWNED_SWIFT_FILES := $(shell find $(SWIFT_SOURCE_ROOTS) -path '*/.build/*' -prune -o -path '$(SWIFT_GENERATED_SOURCE_ROOTS)' -prune -o -name '*.swift' -print)
SWIFT_PACKAGE_MANIFESTS := Package.swift Project.swift Tuist.swift Tuist/Package.swift Tools/Package.swift Tools/cell-tunnel-dev.swift
SWIFT_MK_EXCLUDE_PATHS := ^Sources/CellTunnelCore/Generated/,^Tools/.build/

SWIFT_FORMAT_TARGETS ?= $(SWIFT_OWNED_SWIFT_FILES) $(SWIFT_PACKAGE_MANIFESTS)
SWIFTLINT_TARGETS ?= $(SWIFT_FORMAT_TARGETS)
SWIFTLINT_EXCLUDE_PATHS ?= $(SWIFT_MK_EXCLUDE_PATHS)
SWIFTCHECK_EXTRA_TARGETS ?= $(SWIFT_FORMAT_TARGETS)
SWIFTCHECK_EXTRA_EXCLUDE_PATHS ?= $(SWIFT_MK_EXCLUDE_PATHS)
PERIPHERY_EXCLUDE_PATHS ?= ^Sources/CellTunnelCore/Generated/
PERIPHERY_ARGS ?= scan --config $(SWIFT_MK_PERIPHERY_CONFIG) --strict --report-exclude Sources/CellTunnelCore/Generated/**

include bootstrap.mk

.DEFAULT_GOAL := check

.PHONY: format iphone-install smoke logs

format:
	@$(CELL_TUNNEL_DEV) format

iphone-install:
	@$(CELL_TUNNEL_DEV) activate iphone $(CONFIG)

smoke:
	@printf 'make smoke: run these in order against the smoke config\n'
	@printf '  Products/celltunnelctl status\n'
	@printf '  Products/celltunnelctl start-discovery\n'
	@printf '  Products/celltunnelctl discover\n'
	@printf '  Products/celltunnelctl select <service-id-from-discover>\n'
	@printf '  Products/celltunnelctl start --config "%s"\n' "/Users/agoodkind/Desktop/wireguard-export/example.com only.conf"
	@printf '  ping -c 5 208.67.222.222\n'
	@printf '  ping6 -c 5 2620:119:35::35\n'
	@printf '  curl -v https://208.67.222.222/\n'
	@printf "  curl -v -g 'https://[2620:119:35::35]/'\n"
	@printf 'TODO: graduate this sequence into a celltunnelctl smoke subcommand\n'

logs:
	@printf 'make logs: open two terminals\n'
	@printf '  terminal 1 (mac agent):    log stream --predicate %s\n' "'subsystem == \"io.goodkind.celltunnel\"'"
	@printf '  terminal 2 (iphone):       $(CELL_TUNNEL_DEV) iphone-logs --app\n'
	@printf 'TODO: graduate this into a cell-tunnel-dev logs subcommand that streams both\n'
