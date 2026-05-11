# ──────────────────────────────────────────────────────────────────
# Makefile — Browser Extensions Build System
#
# Targets:
#   make all       — Full pipeline: submodules → deps → build → CRX → checksums
#   make submodules — Sync git submodules
#   make deps      — Install Node.js dependencies deterministically
#   make build     — Build all extensions and produce unpacked + CRX artifacts
#   make checksums — Generate SHA256 checksums for all artifacts
#   make clean     — Remove build artifacts
#   make verify    — Verify checksums of existing artifacts
#   make info      — Show build environment information
#
# Works locally (Linux/macOS) and in GitHub Actions CI.
# Designed for air-gapped environments — no network access at runtime.
# ──────────────────────────────────────────────────────────────────

# Use bash for all shell commands, with strict error handling
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

# ─── Variables ───────────────────────────────────────────────────
# Repository root (directory containing this Makefile)
REPO_ROOT := $(shell pwd)

# Output directory for all build artifacts
DIST_DIR := $(REPO_ROOT)/dist

# Node.js version pinned in .nvmrc
NODE_VERSION := $(shell cat .nvmrc 2>/dev/null || echo "22")

# Git metadata for build reproducibility
GIT_COMMIT := $(shell git rev-parse HEAD 2>/dev/null || echo "unknown")
GIT_SHORT  := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_DATE := $(shell date -u '+%Y-%m-%dT%H:%M:%SZ')

# Submodule directories (from .gitmodules)
# Note: react-devtools is archived and has no package.json — excluded from deps
SUBMODULES := darkreader redux-devtools redux-devtools-extension

# Chrome binary for CRX packing (override with CHROME_BIN env var)
CHROME_BIN ?= $(shell \
	for bin in google-chrome-stable google-chrome chromium-browser chromium; do \
		command -v $$bin 2>/dev/null && break; \
	done)

# ─── Phony targets ──────────────────────────────────────────────
.PHONY: all submodules deps build checksums clean verify info help

# ─── Default target ─────────────────────────────────────────────
# `make all` runs the full build pipeline in order:
#   1. Sync submodules (fetch extension source code)
#   2. Install dependencies deterministically
#   3. Build extensions, produce unpacked + CRX, generate checksums
all: submodules deps build checksums ## Full pipeline: submodules → deps → build → CRX → checksums
	@echo ""
	@echo "══════════════════════════════════════════════════════════"
	@echo "  Build complete!  Artifacts in: $(DIST_DIR)"
	@echo "  Git commit: $(GIT_SHORT)  Date: $(BUILD_DATE)"
	@echo "══════════════════════════════════════════════════════════"

# ─── Submodules ──────────────────────────────────────────────────
# Initialise and update all git submodules.
# --init handles first-time clone; --recursive handles nested submodules.
submodules: ## Sync git submodules
	@echo "[make] Syncing git submodules..."
	git submodule sync --recursive
	git submodule update --init --recursive
	@echo "[make] Submodules synced."

# ─── Dependencies ───────────────────────────────────────────────
# Install Node.js dependencies for each submodule that has a package.json.
# Uses `npm ci` when package-lock.json exists (deterministic, faster).
# Falls back to `npm install` otherwise.
deps: ## Install dependencies deterministically
	@echo "[make] Installing dependencies (Node $(NODE_VERSION))..."
	@echo "[make] Node: $$(node --version 2>/dev/null || echo 'NOT FOUND')"
	@echo "[make] npm:  $$(npm --version 2>/dev/null || echo 'NOT FOUND')"
	@for mod in $(SUBMODULES); do \
		if [ -f "$$mod/package.json" ]; then \
			echo "[make] Installing deps for $$mod..."; \
			if [ -f "$$mod/package-lock.json" ]; then \
				(cd "$$mod" && npm ci || { echo "[make] npm ci failed for $$mod, falling back to npm install"; npm install; }); \
			else \
				(cd "$$mod" && npm install); \
			fi; \
		else \
			echo "[make] SKIP $$mod (no package.json)"; \
		fi; \
	done
	@echo "[make] Dependencies installed."

# ─── Build ───────────────────────────────────────────────────────
# Build all extensions using the build script.
# The script handles:
#   - Building each extension from source
#   - Producing unpacked extension directories
#   - Packing CRX files using Chrome's --pack-extension
#   - Generating build metadata (commit, date, versions)
build: ## Build extensions + pack CRX files
	@echo "[make] Building extensions..."
	CHROME_BIN="$(CHROME_BIN)" ./build.sh "$(DIST_DIR)"

# ─── Checksums ───────────────────────────────────────────────────
# Generate SHA256 checksums for all CRX files in the dist directory.
# This provides integrity verification for air-gapped file transfer.
checksums: ## Generate SHA256 checksums
	@echo "[make] Generating checksums..."
	@if ls $(DIST_DIR)/crx/*.crx 1>/dev/null 2>&1; then \
		(cd "$(DIST_DIR)/crx" && sha256sum -b *.crx | tee SHA256SUMS); \
		echo "[make] CRX checksums: $(DIST_DIR)/crx/SHA256SUMS"; \
	else \
		echo "[make] No CRX files found — checksums skipped"; \
	fi
	@# Master checksum file covering all artifacts
	@find "$(DIST_DIR)" -type f \
		! -name 'SHA256SUMS' \
		! -name 'build-metadata.json' \
		-exec sha256sum -b {} + \
		| sed 's|$(DIST_DIR)/||' \
		| sort -k2 \
		| tee "$(DIST_DIR)/SHA256SUMS" >/dev/null
	@echo "[make] Master checksums: $(DIST_DIR)/SHA256SUMS"

# ─── Verify ──────────────────────────────────────────────────────
# Verify artifact integrity using previously generated checksums.
verify: ## Verify checksums of existing artifacts
	@echo "[make] Verifying checksums..."
	@if [ -f "$(DIST_DIR)/SHA256SUMS" ]; then \
		(cd "$(DIST_DIR)" && sha256sum -c SHA256SUMS); \
		echo "[make] All checksums verified OK"; \
	else \
		echo "[make] ERROR: $(DIST_DIR)/SHA256SUMS not found — run 'make all' first"; \
		exit 1; \
	fi

# ─── Info ────────────────────────────────────────────────────────
# Display build environment details for debugging and reproducibility.
info: ## Show build environment info
	@echo "══════════════════════════════════════════════════════════"
	@echo "  Build Environment"
	@echo "══════════════════════════════════════════════════════════"
	@echo "  Repo root:    $(REPO_ROOT)"
	@echo "  Dist dir:     $(DIST_DIR)"
	@echo "  Git commit:   $(GIT_COMMIT)"
	@echo "  Build date:   $(BUILD_DATE)"
	@echo "  Node.js:      $$(node --version 2>/dev/null || echo 'NOT FOUND')"
	@echo "  npm:          $$(npm --version 2>/dev/null || echo 'NOT FOUND')"
	@echo "  Chrome:       $(CHROME_BIN)"
	@echo "  OS:           $$(uname -s -r)"
	@echo "  Submodules:   $(SUBMODULES)"
	@echo "══════════════════════════════════════════════════════════"

# ─── Clean ───────────────────────────────────────────────────────
# Remove all build artifacts. Does NOT remove node_modules in submodules.
clean: ## Remove build artifacts
	@echo "[make] Cleaning $(DIST_DIR)..."
	rm -rf "$(DIST_DIR)"
	@echo "[make] Clean complete."

# ─── Help ────────────────────────────────────────────────────────
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
