#!/usr/bin/env bash
# install.sh — Smart installer for yac.vim
#
# Logic:
#   1. If zig >= 0.15.0 is available → build from source
#   2. Otherwise → download prebuilt binary from GitHub Release
#
# Usage (vim-plug):
#   Plug 'loyalpartner/yac.vim', { 'do': 'bash scripts/install.sh' }

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$PLUGIN_DIR/zig-out/bin"
MIN_ZIG_VERSION="0.15.0"
REPO="loyalpartner/yac.vim"

# --- Helpers ---

log() { echo "[yac.vim] $*"; }
err() { echo "[yac.vim] ERROR: $*" >&2; }

# Compare semver: returns 0 if $1 >= $2
version_ge() {
  printf '%s\n%s' "$2" "$1" | sort -V -C
}

detect_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"

  case "$os" in
    linux)  os="linux" ;;
    darwin) os="darwin" ;;
    *)      err "Unsupported OS: $os"; exit 1 ;;
  esac

  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *)             err "Unsupported architecture: $arch"; exit 1 ;;
  esac

  echo "${os}-${arch}"
}

# --- Build from source ---

build_from_source() {
  log "Building yacd from source with zig..."
  cd "$PLUGIN_DIR"
  zig build -Doptimize=ReleaseFast
  if [ -x "$BIN_DIR/yacd" ]; then
    log "Build successful: $BIN_DIR/yacd"
    return 0
  else
    err "Build failed: $BIN_DIR/yacd not found"
    return 1
  fi
}

# --- Download prebuilt binary ---

download_binary() {
  local platform="$1"
  local binary_name="yacd-${platform}"

  # Find latest release tag
  local tag
  tag="$(curl -sL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep '"tag_name"' | head -1 | sed 's/.*: "\(.*\)".*/\1/')"

  if [ -z "$tag" ]; then
    err "Could not determine latest release tag"
    return 1
  fi

  local url="https://github.com/$REPO/releases/download/${tag}/${binary_name}"
  log "Downloading $binary_name from release $tag..."

  mkdir -p "$BIN_DIR"
  if curl -LSsf "$url" -o "$BIN_DIR/yacd"; then
    chmod +x "$BIN_DIR/yacd"
    log "Download successful: $BIN_DIR/yacd"
    return 0
  else
    err "Download failed: $url"
    err "Please install Zig >= $MIN_ZIG_VERSION and re-run, or download manually."
    return 1
  fi
}

# --- Main ---

main() {
  # Check for zig
  if command -v zig &>/dev/null; then
    local zig_version
    zig_version="$(zig version 2>/dev/null || echo "0.0.0")"
    log "Found zig $zig_version"

    if version_ge "$zig_version" "$MIN_ZIG_VERSION"; then
      build_from_source
      return $?
    else
      log "Zig $zig_version < $MIN_ZIG_VERSION, downloading prebuilt binary..."
    fi
  else
    log "Zig not found, downloading prebuilt binary..."
  fi

  local platform
  platform="$(detect_platform)"
  download_binary "$platform"
}

main "$@"
