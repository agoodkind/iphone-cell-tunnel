# `make help` is the canonical source of truth for every Go target this module
# supports. Do not add project-local lint, deadcode, audit, fmt, vet, or
# staticcheck targets here. They duplicate the central go-makefile pipeline.

BINARY := celltunneld
CMD    := ./cmd/celltunneld

DIST_DIR := ../Products
CODESIGN_IDENTITY := -

GO_MK_MODULES := go-build.mk go-release.mk

include bootstrap.mk

.DEFAULT_GOAL := check
