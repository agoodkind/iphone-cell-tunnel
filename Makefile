# `make help` is the canonical source of truth for shared Swift targets.
# Project-specific commands stay in `Tools/cell-tunnel-dev.swift`.

# Source of truth for bundle identifiers and signing. The constants xcconfig is
# committed; the local xcconfig is gitignored (copy local.xcconfig.example to
# local.xcconfig and fill in DEVELOPMENT_TEAM).
-include Config/Constants.xcconfig
-include Config/local.xcconfig

CONFIG ?= Debug
CELL_TUNNEL_DEV := swift Tools/cell-tunnel-dev.swift
ACTIVATION_TARGET_USAGE := mac|iphone|iphone-simulator
BUILD_TARGET_USAGE := daemon|mac|mac-catalyst|iphone-simulator|iphone-device|iphone-device-compile|all

SWIFT_MK_MODULES := swift-build.mk xcconfig.mk

# xcconfig.mk consumes these. Each plan renders every *.template under the
# named templates dir into the named output dir before tuist generate runs,
# with the Make-visible xcconfig variables exported as [[KEY]] substitutions.
# Plan format: templates_dir:output_dir[:target_name]
XCCONFIG_RENDER_PLANS := \
	Templates/Swift:Sources/CellTunnelCore/Generated:CellTunnelCore \
	Templates/Plists:Derived/Generated/CellTunnelAgent:CellTunnelAgent
XCCONFIG_EXPORTED_VARS := \
	BUNDLE_ID_PREFIX \
	APP_GROUP_ID \
	AGENT_BUNDLE_ID \
	PROVIDER_BUNDLE_ID \
	PHONE_BUNDLE_ID \
	AGENT_MACH_SERVICE_NAME \
	AGENT_LAUNCH_AGENT_PLIST_NAME \
	AGENT_EXECUTABLE_NAME \
	AGENT_APP_BUNDLE_NAME \
	DEVELOPMENT_TEAM \
	CODE_SIGN_IDENTITY

SWIFT_BUILD_CMD ?= $(if $(strip $(TARGET)),$(CELL_TUNNEL_DEV) build $(TARGET) $(CONFIG),printf 'build: TARGET=$(BUILD_TARGET_USAGE) is required\n'; exit 1)
SWIFT_TEST_CMD ?= $(CELL_TUNNEL_DEV) test
SWIFT_RUN_CMD ?= $(if $(strip $(TARGET)),$(CELL_TUNNEL_DEV) activate $(TARGET) $(CONFIG),printf 'run: TARGET=$(ACTIVATION_TARGET_USAGE) is required\n'; exit 1)
SWIFT_GENERATE_CMD ?= $(MAKE) xcconfig-generate-project
# CellTunnelDev builds Xcode targets into build/DerivedData; the dead-code gate
# reads the index store from the same path so it scans every built Xcode target.
SWIFT_MK_DERIVED_DATA := $(CURDIR)/build/DerivedData
# Target-free coverage build for the dead-code gate. Builds the macOS agent and
# provider, the Mac Catalyst app branch, the iOS app branch plus extension on the
# simulator, and the iOS device app branch compiled sign-free, so every
# targetEnvironment branch (macCatalyst, simulator, and device) is analyzed with no
# device signing. SWIFT_BUILD_CMD itself requires a TARGET, so the gate uses this
# instead.
SWIFT_DEADCODE_BUILD_CMD := rm -rf "$(SWIFT_MK_DERIVED_DATA)" && $(CELL_TUNNEL_DEV) build mac $(CONFIG) && $(CELL_TUNNEL_DEV) build mac-catalyst $(CONFIG) && $(CELL_TUNNEL_DEV) build iphone-simulator $(CONFIG) && $(CELL_TUNNEL_DEV) build iphone-device-compile $(CONFIG)
SWIFT_CLEAN_CMD ?= $(CELL_TUNNEL_DEV) clean
SWIFT_DEPLOY_CMD ?= $(if $(strip $(TARGET)),$(CELL_TUNNEL_DEV) activate $(TARGET) $(CONFIG),printf 'deploy: TARGET=$(ACTIVATION_TARGET_USAGE) is required\n'; exit 1)
SWIFT_ANALYZE_CMD ?= $(CELL_TUNNEL_DEV) analyze
SWIFT_LOG_AUDIT_CMD ?= $(CELL_TUNNEL_DEV) log-audit

SWIFT_SOURCE_ROOTS := Apps Sources Tests Tools/CellTunnelCtl Tools/CellTunnelDev Tools/LoggingAudit
SWIFT_OWNED_SWIFT_FILES := $(shell find $(SWIFT_SOURCE_ROOTS) -path '*/.build/*' -prune -o -name '*.swift' -print)
SWIFT_PACKAGE_MANIFESTS := Package.swift Project.swift Tuist.swift Tuist/Package.swift Tools/Package.swift Tools/cell-tunnel-dev.swift
SWIFT_MK_EXCLUDE_PATHS := ^Derived/Generated/,^Tools/.build/

SWIFT_FORMAT_TARGETS ?= $(SWIFT_OWNED_SWIFT_FILES) $(SWIFT_PACKAGE_MANIFESTS)
SWIFTLINT_TARGETS ?= $(SWIFT_FORMAT_TARGETS)
SWIFTLINT_EXCLUDE_PATHS ?= $(SWIFT_MK_EXCLUDE_PATHS)
SWIFTCHECK_EXTRA_TARGETS ?= $(SWIFT_FORMAT_TARGETS)
SWIFTCHECK_EXTRA_EXCLUDE_PATHS ?= $(SWIFT_MK_EXCLUDE_PATHS)
PERIPHERY_EXCLUDE_PATHS ?= ^Derived/Generated/
PERIPHERY_ARGS ?= scan --config $(SWIFT_MK_PERIPHERY_CONFIG) --strict --report-exclude Derived/Generated/**

include bootstrap.mk

.DEFAULT_GOAL := check

.PHONY: format iphone-install install-mac smoke logs

format:
	@$(CELL_TUNNEL_DEV) format

iphone-install:
	@$(CELL_TUNNEL_DEV) activate iphone $(CONFIG)

install-mac:
	@$(CELL_TUNNEL_DEV) install-mac --config $(CONFIG)

smoke:
	@printf 'make smoke: run these in order against the smoke config\n'
	@printf '  Products/celltunnelctl status\n'
	@printf '  Products/celltunnelctl devices\n'
	@printf '  Products/celltunnelctl select <n>\n'
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
