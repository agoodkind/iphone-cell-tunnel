# `make help` is the canonical source of truth for shared Swift targets.
# Project-specific commands stay in `Tools/cell-tunnel-dev.swift`.

# Source of truth for bundle identifiers and signing. The constants xcconfig is
# committed; the local xcconfig is gitignored (copy local.xcconfig.example to
# local.xcconfig and fill in DEVELOPMENT_TEAM).
-include Config/Constants.xcconfig
-include Config/local.xcconfig

CONFIG ?= Debug
CELL_TUNNEL_DEV := swift Tools/cell-tunnel-dev.swift

SWIFT_MK_MODULES := swift-build.mk xcconfig.mk

# xcconfig.mk consumes these. Each plan renders every *.template under the
# named templates dir into the named output dir before tuist generate runs,
# with the Make-visible xcconfig variables exported as [[KEY]] substitutions.
# Plan format: templates_dir:output_dir[:target_name]
XCCONFIG_RENDER_PLANS := \
	Templates/Swift:Sources/CellTunnelCore/Generated:CellTunnelCore \
	Templates/Plists:Generated/CellTunnelAgent:CellTunnelAgent
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

# Named Make targets alias into CellTunnelDev. That tool owns GatedBuild, so these
# wrappers must not nest `$(MAKE) build TARGET=...`: swift.mk exports SWIFT_BUILD_CMD,
# and a parent with empty TARGET freezes the usage failure into the child environment.
SWIFT_NAMED_BUILD_HINT := use make build-mac|build-catalyst|build-iphone|build-iphone-sim|build-daemon
SWIFT_NAMED_RUN_HINT := use make run-catalyst|run-iphone|run-iphone-sim
SWIFT_BUILD_CMD ?= printf 'build: use a named target (%s)\n' '$(SWIFT_NAMED_BUILD_HINT)'; exit 1
SWIFT_TEST_CMD ?= $(CELL_TUNNEL_DEV) test
SWIFT_RUN_CMD ?= printf 'run: use a named target (%s)\n' '$(SWIFT_NAMED_RUN_HINT)'; exit 1
# The dev tool's `generate` installs Tuist dependencies and renders the project; it is
# idempotent via its fingerprint check. The dev tool (CellTunnelDev) depends on
# CellTunnelCore, which needs the rendered Config.generated.swift, so on a fresh checkout
# (CI, a clean worktree) the dev tool cannot compile to run the very generate that would
# produce that file. Break the bootstrap cycle by rendering the generated config first
# through xcconfig-generate-config, which runs swift-mk render-batch and has no
# CellTunnelCore dependency, then run the dev tool for the Tuist install and generate.
SWIFT_GENERATE_CMD ?= $(MAKE) SWIFT_MK_SKIP_FETCH=1 xcconfig-generate-config && $(CELL_TUNNEL_DEV) generate
SWIFT_MK_DERIVED_DATA := $(CURDIR)/build/DerivedData
# The engine derives and owns the coverage build from these normal inputs. The
# prebuild builds the WireGuard bridge before each engine-driven xcodebuild.
SWIFT_XCODE_WORKSPACE := CellTunnel.xcworkspace
SWIFT_XCODE_GENERATOR := tuist
SWIFT_XCODE_COVERAGE_CONFIGURATION := $(CONFIG)
SWIFT_XCODE_PREBUILD_CMD := $(CELL_TUNNEL_DEV) prebuild
SWIFT_CLEAN_CMD ?= $(CELL_TUNNEL_DEV) clean
SWIFT_DEPLOY_CMD ?= printf 'deploy: use make iphone-install|install-mac\n'; exit 1
SWIFT_ANALYZE_CMD ?= $(CELL_TUNNEL_DEV) analyze

# Tuist forwards only TUIST_* variables into manifest evaluation, so Project.swift
# cannot read PROVISIONING_PROFILE_SPECIFIER directly. swift-mk's reusable CI sets
# that variable in the signed build's environment once it installs the Developer ID
# provisioning profiles, so mirror its presence into TUIST_DEVELOPER_ID_SIGNING; the
# manifest then pins each macOS NetworkExtension target to its profile. The dead-code
# coverage build and local builds leave PROVISIONING_PROFILE_SPECIFIER empty, so this
# stays unset and their signing is unchanged.
ifneq ($(strip $(PROVISIONING_PROFILE_SPECIFIER)),)
export TUIST_DEVELOPER_ID_SIGNING := 1
endif

# Signing verification for product builds lives in CellTunnelDev's GatedBuild path.
# These variables remain for any residual engine verify hooks that still read them;
# named build aliases do not go through bare `make build`.
SWIFT_MK_VERIFY_WORKSPACE := CellTunnel.xcworkspace
SWIFT_MK_VERIFY_SCHEME := CellTunnelAgent
SWIFT_MK_VERIFY_CONFIGURATION := $(CONFIG)
SWIFT_MK_VERIFY_XCCONFIG := Config/local.xcconfig
SWIFT_MK_VERIFY_SIGNING_PATHS := Products/$(CONFIG)/CellTunnelAgent.app Products/$(CONFIG)/CellTunnelTunnelProvider.appex

SWIFT_SOURCE_ROOTS := Apps Sources Tests Tools/CellTunnelCtl Tools/CellTunnelDev
SWIFT_OWNED_SWIFT_FILES := $(shell find $(SWIFT_SOURCE_ROOTS) -path '*/.build/*' -prune -o -name '*.swift' -print)
SWIFT_PACKAGE_MANIFESTS := Package.swift Project.swift Tuist.swift Tuist/Package.swift Tools/Package.swift Tools/cell-tunnel-dev.swift
SWIFT_MK_EXCLUDE_PATHS := ^Generated/,^Tools/.build/

SWIFT_FORMAT_TARGETS ?= $(SWIFT_OWNED_SWIFT_FILES) $(SWIFT_PACKAGE_MANIFESTS)
SWIFTLINT_TARGETS ?= $(SWIFT_FORMAT_TARGETS)
SWIFTLINT_EXCLUDE_PATHS ?= $(SWIFT_MK_EXCLUDE_PATHS)
SWIFTCHECK_EXTRA_TARGETS ?= $(SWIFT_FORMAT_TARGETS)
SWIFTCHECK_EXTRA_EXCLUDE_PATHS ?= $(SWIFT_MK_EXCLUDE_PATHS)
PERIPHERY_EXCLUDE_PATHS ?= ^Generated/
PERIPHERY_ARGS ?= scan --config $(SWIFT_MK_PERIPHERY_CONFIG) --strict --report-exclude Generated/**

include bootstrap.mk

.DEFAULT_GOAL := check

.PHONY: format iphone-install install-mac smoke logs \
	build-mac build-catalyst build-iphone build-iphone-sim build-daemon \
	run-catalyst run-iphone run-iphone-sim \
	relay-up relay-reload relay-status relay-down \
	mac-logs iphone-logs

help::
	@printf '\n%s\n' 'Cell Tunnel:'
	@printf '  %-40s %s\n' 'build-mac' 'build the Mac agent'
	@printf '  %-40s %s\n' 'build-catalyst' 'build the Mac Catalyst app'
	@printf '  %-40s %s\n' 'build-iphone' 'build the iPhone app for a device'
	@printf '  %-40s %s\n' 'build-iphone-sim' 'build the iPhone app for the simulator'
	@printf '  %-40s %s\n' 'build-daemon' 'build the Mac agent daemon only'
	@printf '  %-40s %s\n' 'run-catalyst' 'build, install, and launch the Mac Catalyst app'
	@printf '  %-40s %s\n' 'run-iphone' 'build, install, and launch the iPhone app on a device'
	@printf '  %-40s %s\n' 'run-iphone-sim' 'build, install, and launch the iPhone app in the simulator'
	@printf '  %-40s %s\n' 'install-mac' 'install the Mac agent into /Applications/CellTunnel'
	@printf '  %-40s %s\n' 'iphone-install' 'install and launch the iPhone app'
	@printf '  %-40s %s\n' 'relay-up WG_CONFIG=<path>' 'bring the relay tunnel up end to end'
	@printf '  %-40s %s\n' 'relay-reload WG_CONFIG=<path>' 'reload the running tunnel config in place'
	@printf '  %-40s %s\n' 'relay-status' 'print tunnel status with a drift verdict'
	@printf '  %-40s %s\n' 'relay-down' 'stop the relay tunnel'
	@printf '  %-40s %s\n' 'mac-logs' 'show or stream Mac agent and tunnel-provider logs'
	@printf '  %-40s %s\n' 'iphone-logs' 'show the iPhone unified log for the project subsystem'
	@printf '  %-40s %s\n' 'format' 'format Swift sources via CellTunnelDev'
	@printf '  %-40s %s\n' 'smoke' 'print the manual smoke sequence (not yet automated)'
	@printf '  %-40s %s\n' 'logs' 'print how to open Mac and iPhone log streams'

build-mac: generate
	@$(CELL_TUNNEL_DEV) build mac $(CONFIG)

build-catalyst: generate
	@$(CELL_TUNNEL_DEV) build mac-catalyst $(CONFIG)

build-iphone: generate
	@$(CELL_TUNNEL_DEV) build iphone-device $(CONFIG)

build-iphone-sim: generate
	@$(CELL_TUNNEL_DEV) build iphone-simulator $(CONFIG)

build-daemon: generate
	@$(CELL_TUNNEL_DEV) build daemon $(CONFIG)

run-catalyst: generate
	@$(CELL_TUNNEL_DEV) activate mac-catalyst $(CONFIG)

run-iphone: generate
	@$(CELL_TUNNEL_DEV) activate iphone $(CONFIG)

run-iphone-sim: generate
	@$(CELL_TUNNEL_DEV) activate iphone-simulator $(CONFIG)

format: generate
	@$(CELL_TUNNEL_DEV) format

iphone-install: generate
	@$(CELL_TUNNEL_DEV) activate iphone $(CONFIG)

install-mac: generate
	@$(CELL_TUNNEL_DEV) build mac $(CONFIG)
	@$(CELL_TUNNEL_DEV) install-mac --config $(CONFIG)

relay-up: generate
	@$(CELL_TUNNEL_DEV) relay-up --config "$(WG_CONFIG)"

relay-reload: generate
	@$(CELL_TUNNEL_DEV) relay-reload --config "$(WG_CONFIG)"

relay-status: generate
	@$(CELL_TUNNEL_DEV) relay-status

relay-down: generate
	@$(CELL_TUNNEL_DEV) relay-down

mac-logs: generate
	@$(CELL_TUNNEL_DEV) mac-logs

iphone-logs: generate
	@$(CELL_TUNNEL_DEV) iphone-logs

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
