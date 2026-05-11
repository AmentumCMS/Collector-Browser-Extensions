#!/usr/bin/env bash
# build.sh — Build all browser extensions from source submodules,
#             produce unpacked extensions, pack CRX files, and generate checksums.
#
# Usage:  ./build.sh [DIST_DIR]
#   DIST_DIR defaults to ./dist
#
# Requirements:
#   - Node.js (version pinned in .nvmrc)
#   - Google Chrome or Chromium (for --pack-extension)
#   - Git submodules already initialised
#
# This script is designed to work in both CI (GitHub Actions) and
# air-gapped local environments. It does NOT require network access
# at runtime — all dependencies must be pre-installed or cached.
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="${1:-${REPO_ROOT}/dist}"
UNPACKED_DIR="${DIST_DIR}/unpacked"
CRX_DIR="${DIST_DIR}/crx"
META_DIR="${DIST_DIR}/metadata"

# Find Chrome/Chromium binary — prefer stable, fall back to chromium
find_chrome() {
  for bin in google-chrome-stable google-chrome chromium-browser chromium; do
    if command -v "${bin}" >/dev/null 2>&1; then
      echo "${bin}"
      return 0
    fi
  done
  echo ""
  return 1
}

CHROME_BIN="${CHROME_BIN:-$(find_chrome || true)}"

# ─── Helpers ─────────────────────────────────────────────────────
log()  { printf '[build] %s\n' "$*"; }
die()  { printf '[build] ERROR: %s\n' "$*" >&2; exit 1; }
hr()   { printf '%.0s─' {1..60}; printf '\n'; }

# ─── Pre-flight checks ──────────────────────────────────────────
command -v node >/dev/null 2>&1 || die "node is not installed"
command -v npm  >/dev/null 2>&1 || die "npm is not installed"
log "Node $(node --version)  npm $(npm --version)"

if [ -z "${CHROME_BIN}" ]; then
  log "WARNING: Chrome/Chromium not found — CRX packing will be skipped"
  log "  Set CHROME_BIN env var or install google-chrome-stable"
fi

# ─── Prepare output directories ─────────────────────────────────
rm -rf "${DIST_DIR}"
mkdir -p "${UNPACKED_DIR}" "${CRX_DIR}" "${META_DIR}"

# ─── Build metadata ─────────────────────────────────────────────
GIT_COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo 'unknown')"
GIT_BRANCH="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
BUILD_DATE="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
NODE_VER="$(node --version)"

cat > "${META_DIR}/build-metadata.json" <<EOF
{
  "git_commit": "${GIT_COMMIT}",
  "git_branch": "${GIT_BRANCH}",
  "build_date": "${BUILD_DATE}",
  "node_version": "${NODE_VER}",
  "npm_version": "$(npm --version)",
  "chrome_bin": "${CHROME_BIN:-none}",
  "builder": "${USER:-ci}"
}
EOF
log "Build metadata written to ${META_DIR}/build-metadata.json"

# ─── Build function ─────────────────────────────────────────────
# build_extension <name> <submodule_dir> [build_cmd]
#   Installs deps, runs build, copies output to dist/unpacked/<name>
build_extension() {
  local name="$1"
  local src_dir="$2"
  local build_cmd="${3:-}"

  hr
  log "Building: ${name} (${src_dir})"

  if [ ! -d "${src_dir}" ]; then
    log "SKIP: ${src_dir} not found (submodule may not be initialised)"
    return 0
  fi

  # Check for package.json — if present, install deps and build
  if [ -f "${src_dir}/package.json" ]; then
    log "Installing dependencies (npm ci or npm install)..."
    if [ -f "${src_dir}/package-lock.json" ]; then
      (cd "${src_dir}" && npm ci || { log "npm ci failed, falling back to npm install"; npm install; })
    else
      (cd "${src_dir}" && npm install)
    fi

    if [ -n "${build_cmd}" ]; then
      log "Running build: ${build_cmd}"
      if ! (cd "${src_dir}" && eval "${build_cmd}"); then
        log "WARNING: build command '${build_cmd}' failed for ${name}"
      fi
    else
      # Try common build scripts in order
      for cmd in "npm run build" "npm run build:chrome" "npm run build:extension"; do
        local script_name
        script_name="$(echo "${cmd}" | sed 's/npm run //')"
        if (cd "${src_dir}" && node -e "
          var p = require('./package.json');
          process.exit(p.scripts && p.scripts['${script_name}'] ? 0 : 1);
        " 2>/dev/null); then
          log "Running: ${cmd}"
          if ! (cd "${src_dir}" && eval "${cmd}"); then
            log "WARNING: ${cmd} failed for ${name}"
          fi
          break
        fi
      done
    fi
  fi

  # Copy built extension to unpacked dir
  # Look for common output directories (order matters — prefer more specific paths)
  local out_dir=""
  for candidate in \
    build/release/chrome-mv3 \
    build/release/chrome \
    build/chrome \
    build/extension \
    build \
    dist \
    extension/chrome \
    out; do
    if [ -d "${src_dir}/${candidate}" ]; then
      # Verify it looks like an extension (has manifest.json)
      if [ -f "${src_dir}/${candidate}/manifest.json" ]; then
        out_dir="${src_dir}/${candidate}"
        break
      fi
    fi
  done

  # Fall back to src dir itself if it has manifest.json
  if [ -z "${out_dir}" ] && [ -f "${src_dir}/manifest.json" ]; then
    out_dir="${src_dir}"
  fi

  if [ -n "${out_dir}" ]; then
    log "Copying unpacked extension from ${out_dir}"
    cp -r "${out_dir}" "${UNPACKED_DIR}/${name}"
  else
    log "WARNING: No extension output found for ${name} (no manifest.json in any candidate dir)"
    return 0
  fi

  # Pack CRX if Chrome is available
  if [ -n "${CHROME_BIN}" ] && [ -d "${UNPACKED_DIR}/${name}" ]; then
    pack_crx "${name}"
  fi

  log "Done: ${name}"
}

# ─── CRX packing ────────────────────────────────────────────────
# pack_crx <name>
#   Uses Chrome's --pack-extension to create a CRX file
pack_crx() {
  local name="$1"
  local ext_dir="${UNPACKED_DIR}/${name}"
  local key_file="${REPO_ROOT}/.keys/${name}.pem"

  log "Packing CRX: ${name}"

  # Build the pack command
  local pack_args="--pack-extension=${ext_dir}"
  if [ -f "${key_file}" ]; then
    pack_args="${pack_args} --pack-extension-key=${key_file}"
    log "  Using existing key: ${key_file}"
  else
    log "  No key found — Chrome will generate a new one"
  fi

  # Chrome outputs the CRX next to the source directory
  # Note: --pack-extension is a utility mode; --headless=new for modern Chrome
  if ! "${CHROME_BIN}" --no-sandbox --headless=new ${pack_args} 2>&1; then
    # Fall back to legacy --headless flag for older Chrome versions
    if ! "${CHROME_BIN}" --no-sandbox --headless ${pack_args} 2>&1; then
      # Try without --headless at all (pack-extension doesn't need a display)
      if ! "${CHROME_BIN}" --no-sandbox ${pack_args} 2>&1; then
        log "WARNING: CRX packing failed for ${name}"
        return 0
      fi
    fi
  fi

  # Move CRX and key to dist
  local crx_output="${UNPACKED_DIR}/${name}.crx"
  local pem_output="${UNPACKED_DIR}/${name}.pem"

  if [ -f "${crx_output}" ]; then
    mv "${crx_output}" "${CRX_DIR}/${name}.crx"
    log "  CRX: ${CRX_DIR}/${name}.crx"
  fi

  # Save generated key for reproducible future builds
  if [ -f "${pem_output}" ] && [ ! -f "${key_file}" ]; then
    mkdir -p "${REPO_ROOT}/.keys"
    mv "${pem_output}" "${key_file}"
    log "  Key saved: ${key_file}"
  elif [ -f "${pem_output}" ]; then
    rm -f "${pem_output}"
  fi
}

# ─── Build each extension ───────────────────────────────────────
# darkreader — has its own build system
# Output goes to build/release/chrome-mv3/ (or build/release/chrome/ for MV2)
build_extension "darkreader" "${REPO_ROOT}/darkreader" "npm run build"

# react-devtools — Facebook's React Developer Tools
# Source lives in the facebook/react monorepo at packages/react-devtools-extensions/
# Requires pre-built React packages (built via `yarn build-for-devtools` in Makefile).
# Build produces chrome extension at react/packages/react-devtools-extensions/chrome/build/unpacked/
REACT_DEVTOOLS_DIR="${REPO_ROOT}/react/packages/react-devtools-extensions"
if [ -d "${REACT_DEVTOOLS_DIR}" ]; then
  hr
  log "Building: react-devtools (${REACT_DEVTOOLS_DIR})"

  # Install devtools extension deps
  if [ -f "${REACT_DEVTOOLS_DIR}/package.json" ]; then
    log "Installing react-devtools-extensions dependencies..."
    (cd "${REPO_ROOT}/react" && yarn install --frozen-lockfile 2>/dev/null || yarn install)
  fi

  # Build the Chrome extension
  log "Running: yarn build:chrome"
  if (cd "${REACT_DEVTOOLS_DIR}" && NODE_ENV=production node ./chrome/build 2>&1); then
    # Output is at chrome/build/unpacked/ with manifest.json inside
    local_out="${REACT_DEVTOOLS_DIR}/chrome/build/unpacked"
    if [ -d "${local_out}" ] && [ -f "${local_out}/manifest.json" ]; then
      log "Copying unpacked extension from ${local_out}"
      cp -r "${local_out}" "${UNPACKED_DIR}/react-devtools"
      # Pack CRX if Chrome is available
      if [ -n "${CHROME_BIN}" ] && [ -d "${UNPACKED_DIR}/react-devtools" ]; then
        pack_crx "react-devtools"
      fi
      log "Done: react-devtools"
    else
      log "WARNING: react-devtools build completed but no unpacked extension found at ${local_out}"
    fi
  else
    log "WARNING: react-devtools build failed"
  fi
else
  log "SKIP: react-devtools (react submodule not found at ${REPO_ROOT}/react)"
fi

# redux-devtools — Redux DevTools (monorepo with pre-built extension)
# Pre-built extension lives in extension/chrome/
build_extension "redux-devtools" "${REPO_ROOT}/redux-devtools" ""

# redux-devtools-extension — standalone Redux DevTools extension
# Build output goes to build/extension/
build_extension "redux-devtools-extension" "${REPO_ROOT}/redux-devtools-extension" "npm run build:extension"

# ─── Generate checksums ─────────────────────────────────────────
hr
log "Generating SHA256 checksums..."

# Checksum CRX files
if ls "${CRX_DIR}"/*.crx 1>/dev/null 2>&1; then
  (cd "${CRX_DIR}" && sha256sum -b *.crx | tee "${CRX_DIR}/SHA256SUMS")
  log "CRX checksums: ${CRX_DIR}/SHA256SUMS"
else
  log "No CRX files to checksum"
fi

# Checksum unpacked directories (tar then hash for reproducibility)
for ext_dir in "${UNPACKED_DIR}"/*/; do
  if [ -d "${ext_dir}" ]; then
    ext_name="$(basename "${ext_dir}")"
    tar cf - -C "${UNPACKED_DIR}" "${ext_name}" 2>/dev/null \
      | sha256sum | sed "s|-|${ext_name}.tar|" \
      >> "${META_DIR}/unpacked-SHA256SUMS"
  fi
done

if [ -f "${META_DIR}/unpacked-SHA256SUMS" ]; then
  log "Unpacked checksums: ${META_DIR}/unpacked-SHA256SUMS"
fi

# ─── Copy policy files to dist ──────────────────────────────────
if [ -d "${REPO_ROOT}/policy" ]; then
  cp -r "${REPO_ROOT}/policy" "${DIST_DIR}/policy"
  log "Policy files copied to ${DIST_DIR}/policy"
fi

# ─── Summary ─────────────────────────────────────────────────────
hr
log "Build complete!"
log ""
log "Artifacts in ${DIST_DIR}:"
if command -v tree >/dev/null 2>&1; then
  tree -L 3 "${DIST_DIR}"
else
  find "${DIST_DIR}" -type f | head -50
fi
log ""
log "Build metadata:"
cat "${META_DIR}/build-metadata.json"
