#!/bin/sh
# ZeroServer Community Cloud Agent installer (ZSC-117).
#
#   curl -fsSL https://raw.githubusercontent.com/zeroserver-cc/zsc-agent-runner/main/install.sh | sh
#
# Downloads the standalone zsc-agent binary for this OS/arch from the GitHub
# Releases of zeroserver-cc/zsc-agent-runner (public), verifies its checksum, installs it to
# /usr/local/bin/zsc-agent, fetches the matching-arch frpc next to it, and
# registers the agent as a service (systemd on Linux, launchd on macOS).
# No Node.js required. Idempotent.
#
# Env overrides:
#   ZSC_AGENT_VERSION     release tag to install (default: latest)
#   ZSC_AGENT_INSTALL_DIR install dir for the binary (default: /usr/local/bin)
#   ZSC_AGENT_LIB_DIR     dir for frpc (default: /usr/local/lib/zsc-agent)
#   ZSC_AGENT_NO_SERVICE  set to 1 to skip the service install step
#   FRP_VERSION           frp version for frpc (default: 0.61.1)
#   BACKEND_URL           backend API base (default: https://api.zeroserver.cc/api/v1;
#                         override for a self-hosted/local backend)
set -eu

REPO="zeroserver-cc/zsc-agent-runner"
BIN_NAME="zsc-agent"
INSTALL_DIR="${ZSC_AGENT_INSTALL_DIR:-/usr/local/bin}"
LIB_DIR="${ZSC_AGENT_LIB_DIR:-/usr/local/lib/zsc-agent}"
FRP_VERSION="${FRP_VERSION:-0.61.1}"

info() { printf '\033[0;36m==>\033[0m %s\n' "$1"; }
err() { printf '\033[0;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

if command -v curl >/dev/null 2>&1; then
  dl() { curl -fsSL "$1" -o "$2"; }
  dl_stdout() { curl -fsSL "$1"; }
elif command -v wget >/dev/null 2>&1; then
  dl() { wget -qO "$2" "$1"; }
  dl_stdout() { wget -qO- "$1"; }
else
  err "neither curl nor wget found"
fi

sudo_if_needed() {
  # $1 = directory that must be writable; remaining args = command to run
  dir="$1"
  shift
  if [ -w "$dir" ] 2>/dev/null; then
    "$@"
  else
    sudo "$@"
  fi
}

# --- detect OS/arch ----------------------------------------------------------
os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Linux) plat="linux"; frpos="linux" ;;
  Darwin) plat="macos"; frpos="darwin" ;;
  *) err "unsupported OS: $os" ;;
esac
case "$arch" in
  x86_64 | amd64) a="x64"; frparch="amd64" ;;
  arm64 | aarch64) a="arm64"; frparch="arm64" ;;
  *) err "unsupported arch: $arch" ;;
esac
asset="${BIN_NAME}-${plat}-${a}"

# --- resolve version ---------------------------------------------------------
version="${ZSC_AGENT_VERSION:-}"
if [ -z "$version" ]; then
  info "Resolving latest release of ${REPO}..."
  version="$(dl_stdout "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep '"tag_name"' | head -n1 | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
  [ -n "$version" ] || err "could not resolve latest release tag (set ZSC_AGENT_VERSION)"
fi
info "Installing $REPO $version ($asset)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- download agent binary + checksum ---------------------------------------
base="https://github.com/${REPO}/releases/download/${version}"
dl "${base}/${asset}" "${tmp}/${BIN_NAME}" || err "failed to download ${asset} (published for ${plat}-${a}?)"
if dl "${base}/${asset}.sha256" "${tmp}/${asset}.sha256" 2>/dev/null; then
  info "Verifying checksum..."
  expected="$(awk '{print $1}' "${tmp}/${asset}.sha256")"
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "${tmp}/${BIN_NAME}" | awk '{print $1}')"
  else
    actual="$(shasum -a 256 "${tmp}/${BIN_NAME}" | awk '{print $1}')"
  fi
  [ "$expected" = "$actual" ] || err "checksum mismatch (expected $expected, got $actual)"
else
  info "No checksum published; skipping verification."
fi
chmod +x "${tmp}/${BIN_NAME}"

# --- ad-hoc codesign on Apple Silicon ---------------------------------------
# Apple Silicon SIGKILLs unsigned arm64 Mach-O binaries at exec. The release
# pipeline signs the published binary, but re-sign here too (belt and suspenders)
# while it still lives in the writable temp dir - signing in the root-owned
# install dir would fail. Intel macOS runs unsigned binaries fine, so gate on
# arm64. Best-effort: warn, never fail.
if [ "$plat" = "macos" ] && [ "$a" = "arm64" ] && command -v codesign >/dev/null 2>&1; then
  info "Ad-hoc signing the binary for Apple Silicon..."
  xattr -c "${tmp}/${BIN_NAME}" 2>/dev/null || true
  if ! codesign -s - -f "${tmp}/${BIN_NAME}" >/dev/null 2>&1; then
    info "codesign failed. If 'zsc-agent' is killed on launch, run:"
    info "  c=\$(mktemp) && cp \"${INSTALL_DIR}/${BIN_NAME}\" \"\$c\" && xattr -c \"\$c\" && codesign -s - -f \"\$c\" && sudo cp \"\$c\" \"${INSTALL_DIR}/${BIN_NAME}\""
  fi
fi

# --- fetch frpc for this arch ------------------------------------------------
# frpc is spawned as a child process, so it lives on disk (not in the binary).
info "Fetching frpc ${FRP_VERSION} (${frpos}/${frparch})..."
frp_archive="frp_${FRP_VERSION}_${frpos}_${frparch}.tar.gz"
dl "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${frp_archive}" "${tmp}/${frp_archive}" \
  || err "failed to download frpc ${frp_archive}"
tar -xzf "${tmp}/${frp_archive}" -C "$tmp"
frpc_src="${tmp}/frp_${FRP_VERSION}_${frpos}_${frparch}/frpc"
[ -f "$frpc_src" ] || err "frpc not found inside ${frp_archive}"
chmod +x "$frpc_src"

# --- install binary + frpc (sudo only if needed) ----------------------------
target="${INSTALL_DIR}/${BIN_NAME}"
sudo_if_needed "$(dirname "$INSTALL_DIR")" mkdir -p "$INSTALL_DIR"
sudo_if_needed "$INSTALL_DIR" mv "${tmp}/${BIN_NAME}" "$target"
sudo_if_needed "$INSTALL_DIR" chmod +x "$target"

sudo_if_needed "$(dirname "$LIB_DIR")" mkdir -p "$LIB_DIR"
sudo_if_needed "$LIB_DIR" mv "$frpc_src" "${LIB_DIR}/frpc"
sudo_if_needed "$LIB_DIR" chmod +x "${LIB_DIR}/frpc"

info "Installed $BIN_NAME to $target and frpc to ${LIB_DIR}/frpc"

# --- register service --------------------------------------------------------
if [ "${ZSC_AGENT_NO_SERVICE:-0}" = "1" ]; then
  printf '\nSkipping service install (ZSC_AGENT_NO_SERVICE=1).\nRun \033[1msudo %s install-service\033[0m when ready.\n' "$BIN_NAME"
else
  info "Registering the agent as a service..."
  # Pass the actual frpc location so the service persists it (matters when
  # ZSC_AGENT_LIB_DIR points frpc somewhere other than the default path).
  # Forward BACKEND_URL when the caller set one, so the service persists it
  # (curl ... | BACKEND_URL=https://my-backend sh). Otherwise the agent uses its
  # production default.
  if sudo ${BACKEND_URL:+BACKEND_URL="$BACKEND_URL"} FRPC_BINARY_PATH="${LIB_DIR}/frpc" "$target" install-service; then
    info "Agent service installed."
  else
    printf '\nService install did not complete (Docker required, run as root).\n'
    printf 'Once Docker is running, finish with: \033[1msudo %s install-service\033[0m\n' "$BIN_NAME"
  fi
fi
