# `make help` is the canonical source of truth for shared Swift targets.
# Project-specific commands stay in `Tools/cell-tunnel-dev.swift`.

CONFIG ?= Debug
CELL_TUNNEL_DEV := swift Tools/cell-tunnel-dev.swift

SWIFT_MK_MODULES := swift-build.mk

SWIFT_BUILD_CMD ?= $(CELL_TUNNEL_DEV) build $(CONFIG)
SWIFT_TEST_CMD ?= $(CELL_TUNNEL_DEV) test
SWIFT_RUN_CMD ?= $(CELL_TUNNEL_DEV) run
SWIFT_GENERATE_CMD ?= $(CELL_TUNNEL_DEV) generate
SWIFT_CLEAN_CMD ?= $(CELL_TUNNEL_DEV) clean
SWIFT_ANALYZE_CMD ?= $(CELL_TUNNEL_DEV) analyze
SWIFT_AUDIT_EXTRA_CMD ?= $(CELL_TUNNEL_DEV) go-audit
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

.PHONY: format go-audit build-phone-device install-phone-device launch-phone-device \
        sign signing-check notary-setup notarize-check notarize

format:
	@$(CELL_TUNNEL_DEV) format

go-audit:
	@$(CELL_TUNNEL_DEV) go-audit

build-phone-device:
	@$(CELL_TUNNEL_DEV) build-phone-device $(CONFIG)

install-phone-device:
	@$(CELL_TUNNEL_DEV) install-phone-device $(CONFIG)

launch-phone-device:
	@$(CELL_TUNNEL_DEV) launch-phone-device

sign:
	@$(CELL_TUNNEL_DEV) sign $(CONFIG)

signing-check:
	@$(CELL_TUNNEL_DEV) signing-check

notary-setup:
	@$(CELL_TUNNEL_DEV) notary-setup

notarize-check:
	@$(CELL_TUNNEL_DEV) notarize-check

notarize:
	@$(CELL_TUNNEL_DEV) notarize $(CONFIG)
