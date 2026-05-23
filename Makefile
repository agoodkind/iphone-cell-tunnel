#
#  Makefile
#  CellTunnel
#
#  Thin aliases around the Swift-owned development tool.
#

CONFIG ?= Debug
CELL_TUNNEL_DEV := swift Tools/cell-tunnel-dev.swift

.PHONY: help generate build test lint format log-audit go-audit audit analyze clean run

help:
	@$(CELL_TUNNEL_DEV) help

generate:
	@$(CELL_TUNNEL_DEV) generate

build:
	@$(CELL_TUNNEL_DEV) build $(CONFIG)

test:
	@$(CELL_TUNNEL_DEV) test

lint:
	@$(CELL_TUNNEL_DEV) lint

format:
	@$(CELL_TUNNEL_DEV) format

log-audit:
	@$(CELL_TUNNEL_DEV) log-audit

go-audit:
	@$(CELL_TUNNEL_DEV) go-audit

audit:
	@$(CELL_TUNNEL_DEV) audit

analyze:
	@$(CELL_TUNNEL_DEV) analyze

clean:
	@$(CELL_TUNNEL_DEV) clean

run:
	@$(CELL_TUNNEL_DEV) run
