# What is this?

[![Release](https://github.com/amentumcms/Collector-Browser-Extensions/actions/workflows/collect.yml/badge.svg?branch=main)](https://github.com/amentumcms/Collector-Browser-Extensions/actions/workflows/collect.yml)

This is a project that automatically collects and creates artifacts to ease in air-gapped transfer of useful browser extensions from the internet.

It runs actions as needed/manually, on GIT Commit Push, or automatically on Mondays at 00:00 

In this case, it:

- Collects Browser Extensions
- Collection Browser Extension Source

## Extensions include:

- Facebook's React Dev Tools:
- Redux DevTools: Redux DevTools for debugging application's state changes.
- Dark Reader: Dark Reader analyzes web pages and aims to reduce eyestrain.

## Building from Source

### Prerequisites

- Node.js (version pinned in `.nvmrc` — currently v22)
- Google Chrome or Chromium (for CRX packing via `--pack-extension`)
- Git (for submodule management)

### Quick Start

```bash
# Full build pipeline: sync submodules → install deps → build → pack CRX → checksums
make all
```

### Individual Targets

```bash
make submodules   # Sync git submodules
make deps         # Install Node.js dependencies deterministically
make build        # Build all extensions + pack CRX files
make checksums    # Generate SHA256 checksums
make verify       # Verify artifact checksums
make clean        # Remove build artifacts
make info         # Show build environment details
make help         # List all targets
```

### Output Structure

```
dist/
├── crx/              # Packed CRX files (for deployment)
│   ├── darkreader.crx
│   ├── react-devtools.crx
│   └── SHA256SUMS
├── unpacked/          # Unpacked extension directories (for development)
│   ├── darkreader/
│   └── react-devtools/
├── metadata/          # Build metadata and checksums
│   └── build-metadata.json
├── policy/            # Enterprise policy files (Chrome + Edge)
│   ├── chrome_policy.json
│   ├── edge_policy.json
│   └── update.xml
└── SHA256SUMS         # Master checksum file
```

### Build Reproducibility

Builds are reproducible through:
- **Node.js version pinning** via `.nvmrc`
- **Deterministic installs** via `npm ci` and `package-lock.json`
- **Build metadata** capturing git commit, date, and tool versions
- **SHA256 checksums** for all artifacts

To verify a build:
```bash
make verify            # Check all artifact checksums
cat dist/metadata/build-metadata.json  # Inspect build provenance
```

### Enterprise Deployment (Air-Gapped)

1. Run `make all` on a connected build machine
2. Copy `dist/crx/*.crx` and `dist/policy/update.xml` to the target:
   - **Linux:** `/opt/browser-extensions/chrome/`
   - **Windows:** `C:\browser-extensions\chrome\`
3. Deploy the appropriate policy JSON:
   - **Chrome:** `dist/policy/chrome_policy.json` → `/etc/opt/chrome/policies/managed/`
   - **Edge:** `dist/policy/edge_policy.json` → `/etc/opt/edge/policies/managed/`
4. Update the `version` attributes in `update.xml` to match your extension versions