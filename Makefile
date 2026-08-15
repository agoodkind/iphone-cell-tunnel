# `make help` is the canonical source of truth for shared Swift targets.
# Project-specific commands stay in `Tools/cell-tunnel-dev.swift`.

# Source of truth for bundle identifiers and signing. The constants xcconfig is
# committed; the local xcconfig is gitignored (copy local.xcconfig.example to
# local.xcconfig and fill in DEVELOPMENT_TEAM).
-include Config/Constants.xcconfig
-include Config/local.xcconfig

CONFIG ?= Debug
CELL_TUNNEL_DEV := swift Tools/cell-tunnel-dev.swift

# Release artifacts for the shared release pipeline. A person downloads these, so both
# halves ship: the agent bundle carries the packet tunnel extension inside it, and the
# Catalyst app is what they open. Each travels as an archive because a signed bundle
# copied as a directory tree arrives without its signature.
#
# The name carries ARTIFACT_VERSION, which a publishing run stamps from the release tag
# and a pull request rehearsal sets to a placeholder. RELEASE_TAG is the fallback for a
# caller that supplies only that. Reading RELEASE_TAG alone named the rehearsal's
# archives `CellTunnelAgent-.zip`, because the rehearsal runs inside the verify job and
# no stage there stamps a tag.
SWIFT_MK_RELEASE_ARTIFACT_VERSION = $${ARTIFACT_VERSION:-$${RELEASE_TAG}}
SWIFT_MK_RELEASE_BUILD_CMD := mkdir -p dist \
	&& $(CELL_TUNNEL_DEV) build mac Release \
	&& $(CELL_TUNNEL_DEV) build mac-catalyst Release \
	&& ditto -c -k --keepParent Products/Release/CellTunnelAgent.app \
		dist/CellTunnelAgent-$(SWIFT_MK_RELEASE_ARTIFACT_VERSION).zip \
	&& ditto -c -k --keepParent Products/Release-maccatalyst/CellTunnelPhone.app \
		dist/CellTunnelPhone-$(SWIFT_MK_RELEASE_ARTIFACT_VERSION).zip

SWIFT_MK_MODULES := swift-build.mk xcconfig.mk swift-release.mk

# Build identity rendered into the generated Swift, so a running binary and every log
# line say which build they came from. A publishing run supplies MARKETING_VERSION,
# CURRENT_PROJECT_VERSION, and RELEASE_TAG from the pipeline's release metadata; a
# local build falls back to these values and to what git reports. The engine's
# render-batch substitutes named variables only and never runs git itself, so the git
# values are computed here.
MARKETING_VERSION ?= 0.0.0
CURRENT_PROJECT_VERSION ?= 0
RELEASE_TAG ?=
GIT_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
GIT_VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
GIT_DIRTY := $(shell git diff --quiet 2>/dev/null && echo false || echo true)
GIT_BRANCH := $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)

# Tuist forwards only TUIST_* variables into manifest evaluation, so the manifest reads
# the version through these rather than from the build settings directly.
export TUIST_MARKETING_VERSION := $(MARKETING_VERSION)
export TUIST_CURRENT_PROJECT_VERSION := $(CURRENT_PROJECT_VERSION)

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
	CODE_SIGN_IDENTITY \
	MARKETING_VERSION \
	CURRENT_PROJECT_VERSION \
	RELEASE_TAG \
	GIT_COMMIT \
	GIT_VERSION \
	GIT_DIRTY \
	GIT_BRANCH

# Named Make targets alias into CellTunnelDev. Engine `make build` compiles every
# platform through CellTunnelDev `build all`. Prefer a named alias when you want
# one platform. Do not nest `$(MAKE) build-*` inside SWIFT_BUILD_CMD: swift.mk
# exports that command into child environments.
SWIFT_NAMED_RUN_HINT := use make run-catalyst|run-iphone|run-iphone-sim
SWIFT_BUILD_CMD ?= $(CELL_TUNNEL_DEV) build all $(CONFIG)
SWIFT_VERIFY_BUILD_CMD ?= $(CELL_TUNNEL_DEV) build all $(CONFIG)
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
# cannot read PROVISIONING_PROFILE_SPECIFIER directly. The engine's release path sets
# that variable once it installs the Developer ID provisioning profiles, so mirror its
# presence into TUIST_DEVELOPER_ID_SIGNING; the manifest then signs Developer ID and
# pins each macOS NetworkExtension target to its Managed DeveloperID profile. The CI
# distribution build sets TUIST_DISTRIBUTION_SIGNING through ci.yml instead. The
# dead-code coverage build and local builds leave PROVISIONING_PROFILE_SPECIFIER
# empty, so this stays unset and their signing is unchanged.
#
# Scoped to release-build rather than exported globally, because one CI job now runs
# the verify stages and the release stage in sequence and the shared gate exports
# PROVISIONING_PROFILE_SPECIFIER into every stage. A global export put the verify
# build in Developer ID mode while it signed Apple Distribution, and Xcode refused
# with "provisioning profile does not include signing certificate".
ifneq ($(strip $(PROVISIONING_PROFILE_SPECIFIER)),)
release-build: export TUIST_DEVELOPER_ID_SIGNING := 1
endif

# The Verify gate builds every platform through SWIFT_VERIFY_BUILD_CMD and verifies
# the actual signed output. SWIFT_MK_VERIFY_SIGNING_ROOTS makes the engine discover
# every runnable .app the build dropped under Products and check each one's signature,
# so the Mac agent, the Catalyst app, and the iPhone device app are all confirmed
# signed with the team and not ad-hoc, without listing paths. The engine skips the
# iPhone simulator app, which is ad-hoc by design.
#
# The pre-build settings check (SWIFT_MK_VERIFY_WORKSPACE/SCHEME) is intentionally
# unset: under automatic App Store Connect API-key signing the identity resolves at
# build time, so static xcodebuild -showBuildSettings reports CODE_SIGN_IDENTITY = -
# for targets that Xcode signs at build time. The signed identity is knowable only
# after the build, which the products check inspects directly.
SWIFT_MK_VERIFY_SIGNING_ROOTS := Products
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

.PHONY: format iphone-install install-mac smoke logs ci-provision \
	build-all build-mac build-catalyst build-iphone build-iphone-sim build-daemon \
	run-catalyst run-iphone run-iphone-sim \
	relay-up relay-reload relay-status relay-down \
	mac-logs iphone-logs

# CI signing provisioning. CI and unregistered machines cannot use development
# provisioning (it requires a registered device), so this creates or renews one App
# Store distribution profile per target with the App Store Connect API key and installs
# it, for a manual-signed build. The engine runs this as the Verify job's setup step,
# before the build, with APPLE_NOTARY_* in the environment. See fastlane/Fastfile.
ci-provision:
	@command -v bundle >/dev/null 2>&1 || gem install bundler --no-document
	@bundle install --quiet
	@bundle exec fastlane ios ci_provision

help::
	@printf '\n%s\n' 'Cell Tunnel:'
	@printf '  %-40s %s\n' 'build-all' 'build every platform (same as make build)'
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
	@printf '  %-40s %s\n' 'smoke WG_CONFIG=<path> PEER=<n>' 'run agent smoke plus connectivity probes'
	@printf '  %-40s %s\n' 'logs' 'stream Mac and iPhone celltunnel logs together'

build-all: generate
	@$(CELL_TUNNEL_DEV) build all $(CONFIG)

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

smoke: generate
	@test -n "$(WG_CONFIG)" || (printf 'smoke: set WG_CONFIG=<wireguard.conf>\n'; exit 1)
	@test -n "$(PEER)" || (printf 'smoke: set PEER=<1-based peer index>\n'; exit 1)
	@$(CELL_TUNNEL_DEV) build daemon $(CONFIG)
	@"$(CURDIR)/Products/celltunnelctl" \
		smoke --config "$(WG_CONFIG)" --peer "$(PEER)"

logs: generate
	@$(CELL_TUNNEL_DEV) logs
