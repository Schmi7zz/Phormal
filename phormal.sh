#!/usr/bin/env bash
# ==============================================================================
#  Phormal Tunnel
#  A fast, resilient tunneling layer for bridging two servers across hostile
#  networks. Phormal Bridge or Phormal Relay — pick the mode that fits your path.
#
#  Author   : Schmi7z  (github.com/Schmi7zz)
#  Channel  : @SchmitzWS
#  Contact   : @Schmi7zz
#  License  : GPL-3.0
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
#  Constants
# ------------------------------------------------------------------------------
readonly PHORMAL_VERSION="6.2.2"
readonly PHORMAL_SPEED_PORT=15987
readonly PHORMAL_HOME="/etc/phormal"
readonly PHORMAL_CONF="${PHORMAL_HOME}/phormal.conf"
readonly PHORMAL_LOG="/var/log/phormal.log"
readonly CORE_UP_SCRIPT="${PHORMAL_HOME}/core-up.sh"
readonly CORE_UNIT="/etc/systemd/system/phormal-core.service"
readonly GUARD_UNIT="/etc/systemd/system/phormal-guard.service"
readonly FWD_BIN="/usr/local/bin/phormal-fwd"
readonly CLI_LINK="/usr/local/bin/phormal"
readonly MAX_PORTS_PER_UNIT=12000
readonly CORE_IFACE="phormal0"
readonly DEFAULT_MTU=1360
readonly RELAY_HOME="${PHORMAL_HOME}/relay"
readonly RELAY_CONF="${RELAY_HOME}/config.yaml"
readonly RELAY_BIN="/usr/local/bin/phormal-relay"
readonly RELAY_UNIT="/etc/systemd/system/phormal-relay.service"
readonly RELAY_SYSCTL="/etc/sysctl.d/97-phormal-relay.conf"

# Iran-hosted mirror for gost / hysteria (optional).
# Entry nodes try this base URL before GitHub. Override per-server in
# /etc/phormal/phormal.conf with  MIRROR_BASE=http://your-server:8880/phormal
# Files expected on the mirror host (served at MIRROR_BASE):
#   gost-linux-{amd64,arm64}  hysteria-linux-{amd64,arm64}
#   rathole-linux-{amd64,arm64}
#   icmp_tun-linux-{amd64,arm64}  udp2raw-linux-{amd64,arm64}
# phormal.sh itself is installed from GitHub, not the mirror.
readonly DEFAULT_MIRROR_BASE="http://85.198.16.108:8880/phormal"
readonly GOST_RELEASE_VERSION="3.2.6"
readonly HYSTERIA_RELEASE_TAG="app/v2.9.2"
readonly MANUAL_DIR="/root/phormal"

# ---- Phormal Reverse (rathole) ----
readonly REVERSE_DIR="${PHORMAL_HOME}/reverse"
readonly REVERSE_BIN="/usr/local/bin/phormal-rtl"
readonly REVERSE_RUN="/usr/local/bin/phormal-reverse-run"
readonly REVERSE_TMPL="/etc/systemd/system/phormal-reverse@.service"
readonly RATHOLE_RELEASE_REPO="rapiz1/rathole"
readonly RATHOLE_RELEASE_TAG="v0.5.0"

# Set once per phormal invocation when a binary must be downloaded (mirror/github/manual).
BINARY_SOURCE=""

# ------------------------------------------------------------------------------
#  Presentation
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
  BOLD=$'\e[1m'; DIM=$'\e[2m'; RST=$'\e[0m'
  FG=$'\e[38;5;81m'; OK=$'\e[38;5;78m'; WARN=$'\e[38;5;221m'
  ERR=$'\e[38;5;203m'; ACC=$'\e[38;5;213m'; MUT=$'\e[38;5;245m'
else
  BOLD=""; DIM=""; RST=""; FG=""; OK=""; WARN=""; ERR=""; ACC=""; MUT=""
fi

log()   { printf '%s [%s] %s\n' "$(date '+%F %T')" "${1}" "${2}" >>"${PHORMAL_LOG}" 2>/dev/null || true; }
info()  { printf '  %s%s%s\n' "${FG}" "$*" "${RST}"; log INFO "$*"; }
good()  { printf '  %s✔%s %s\n' "${OK}" "${RST}" "$*"; log  OK  "$*"; }
warn()  { printf '  %s!%s %s\n' "${WARN}" "${RST}" "$*"; log WARN "$*"; }
fail()  { printf '  %s✗%s %s\n' "${ERR}" "${RST}" "$*"; log FAIL "$*"; }
ask()   { local p="$1" v; read -rp "  ${ACC}»${RST} ${p}: " v; printf '%s' "$v"; }
rule()  { printf '  %s────────────────────────────────────────────────────%s\n' "${MUT}" "${RST}"; }

banner() {
  clear 2>/dev/null || true
  printf '%s' "${FG}${BOLD}"
  cat <<'EOF'

   ██████  ██   ██  ████  ██████  ███    ███  ████  ██
   ██   ██ ██   ██ ██  ██ ██   ██ ████  ████ ██  ██ ██
   ██████  ███████ ██  ██ ██████  ██ ████ ██ ██████ ██
   ██      ██   ██ ██  ██ ██   ██ ██  ██  ██ ██  ██ ██
   ██      ██   ██  ████  ██   ██ ██      ██ ██  ██ ███████
                          T   U   N   N   E   L
EOF
  printf '%s' "${RST}"
  printf '   %sv%s%s  •  %s@SchmitzWS%s  •  %sgithub.com/Schmi7zz%s\n\n' \
    "${MUT}" "${PHORMAL_VERSION}" "${RST}" "${ACC}" "${RST}" "${MUT}" "${RST}"
}

trap 'fail "Aborted on line ${LINENO} (exit ${?})."' ERR

# ------------------------------------------------------------------------------
#  Guards & utilities
# ------------------------------------------------------------------------------
need_root() {
  if [[ ${EUID} -eq 0 ]]; then
    return 0
  fi
  local me script
  me="$(id -un 2>/dev/null || echo unknown)"
  if have sudo; then
    info "Not root on this host (${me}) — re-launching via sudo -i for full tunnel/kernel access…"
    script="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    exec sudo -i bash "${script}" "$@"
  fi
  fail "Phormal must run as root. Try: sudo phormal.sh  (or sudo -i, then run phormal.sh)"
  exit 1
}

ensure_dirs() {
  mkdir -p "${PHORMAL_HOME}"
  touch "${PHORMAL_LOG}" 2>/dev/null || true
  ensure_mirror_conf
}

# Seed / upgrade MIRROR_BASE so binary downloads use the Iran mirror on port 8880.
ensure_mirror_conf() {
  local cur legacy="http://85.198.16.108/phormal"
  cur="$(conf_get MIRROR_BASE)"
  if [[ -n "${cur}" ]]; then
    [[ "${cur}" == "${legacy}" ]] && conf_set MIRROR_BASE "${DEFAULT_MIRROR_BASE}"
    return 0
  fi
  [[ -n "${DEFAULT_MIRROR_BASE}" ]] && conf_set MIRROR_BASE "${DEFAULT_MIRROR_BASE}"
}

have()        { command -v "$1" >/dev/null 2>&1; }

valid_ipv4()  { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# Strip ANSI colour codes accidentally captured from menu stdout.
sanitize_meta_val() {
  printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r'
}

reverse_proto_clean() {
  local v; v="$(sanitize_meta_val "$1" | tr -cd 'a-z')"
  [[ "${v}" == *udp* ]] && printf 'udp' || printf 'tcp'
}

reverse_nodelay_clean() {
  local v; v="$(sanitize_meta_val "$1" | tr -d '[:space:]')"
  [[ "${v}" == "false" ]] && printf 'false' || printf 'true'
}

# Map Debian-style package names to RHEL/Alma equivalents when using dnf/yum.
pkg_install_name() {
  local p="$1"
  if have apt-get; then
    printf '%s' "${p}"
    return 0
  fi
  case "${p}" in
    libpcap0.8)  printf 'libpcap' ;;
    iproute2)    printf 'iproute' ;;
    libcap2-bin) printf 'libcap' ;;
    *)           printf '%s' "${p}" ;;
  esac
}

# Debian/RHEL package name → binary used to detect if already installed.
pkg_cmd_for() {
  case "$1" in
    iproute2|iproute)        printf 'ip' ;;
    openssh-client|openssh-clients) printf 'ssh' ;;
    netcat-openbsd|netcat|nmap-ncat) printf 'nc' ;;
    dnsutils|bind9-dnsutils|bind-utils) printf 'dig' ;;
    *)                       printf '%s' "$1" ;;
  esac
}

apt_install_quiet() {
  local missing=() install_pkgs=() p mapped cmd
  for p in "$@"; do
    cmd="$(pkg_cmd_for "${p}")"
    have "${cmd}" || missing+=("${p}")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  info "Installing packages: ${missing[*]}…"
  if have apt-get; then
    timeout 45 apt-get update -y >/dev/null 2>&1 || true
    timeout 120 apt-get install -y "${missing[@]}" >/dev/null 2>&1 || true
  elif have dnf || have yum; then
    local pm; pm="dnf"; have dnf || pm="yum"
    for p in "${missing[@]}"; do
      mapped="$(pkg_install_name "${p}")"
      install_pkgs+=("${mapped}")
    done
    timeout 180 "${pm}" install -y "${install_pkgs[@]}" >/dev/null 2>&1 || true
  else
    warn "No supported package manager (apt/dnf/yum) — install manually: ${missing[*]}"
    return 1
  fi
}

fetch_url() {
  curl -fsSL --connect-timeout 20 --max-time 180 "$1" -o "$2"
}

machine_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *) return 1 ;;
  esac
}

gost_upstream_tarball_url() {
  printf 'https://github.com/go-gost/gost/releases/download/v%s/gost_%s_linux_%s.tar.gz' \
    "${GOST_RELEASE_VERSION}" "${GOST_RELEASE_VERSION}" "$1"
}

gost_release_url() { gost_upstream_tarball_url "$1"; }

hysteria_upstream_url() {
  # GitHub serves release assets at the literal tag path (app/v2.9.2), NOT url-encoded
  printf 'https://github.com/apernet/hysteria/releases/download/%s/hysteria-linux-%s' "${HYSTERIA_RELEASE_TAG}" "$1"
}

install_gost_from_release() {
  local arch tmpdir tgz
  arch="$(machine_arch)" || return 1
  tgz="$(mktemp)"
  tmpdir="$(mktemp -d)"
  if ! fetch_url "$(gost_upstream_tarball_url "${arch}")" "${tgz}"; then
    rm -f "${tgz}"
    rm -rf "${tmpdir}"
    return 1
  fi
  tar xzf "${tgz}" -C "${tmpdir}"
  mv -f "${tmpdir}/gost" "${FWD_BIN}"
  chmod +x "${FWD_BIN}"
  rm -f "${tgz}"
  rm -rf "${tmpdir}"
  "${FWD_BIN}" -V >/dev/null 2>&1
}

install_local_binary() {
  local dest="$1"
  warn "Automatic download failed on this network."
  info "Upload the binary to this server first, then enter its path."
  local path; path="$(ask 'Local binary path [blank to abort]')"
  [[ -z "${path}" ]] && return 1
  [[ -f "${path}" ]] || { fail "File not found: ${path}"; return 1; }
  cp -f "${path}" "${dest}"
  chmod +x "${dest}"
  good "Binary installed from local file."
}

mirror_base() {
  local b
  b="$(conf_get MIRROR_BASE)"
  [[ -n "${b}" ]] && { printf '%s' "${b%/}"; return 0; }
  [[ -n "${DEFAULT_MIRROR_BASE}" ]] && printf '%s' "${DEFAULT_MIRROR_BASE%/}"
}

mirror_fwd_url() {
  local arch="$1" base
  base="$(mirror_base)"
  [[ -z "${base}" ]] && return 1
  printf '%s/gost-linux-%s' "${base%/}" "${arch}"
}

mirror_relay_url() {
  local arch="$1" base
  base="$(mirror_base)"
  [[ -z "${base}" ]] && return 1
  printf '%s/hysteria-linux-%s' "${base%/}" "${arch}"
}

mirror_reverse_url() {
  local arch="$1" base
  base="$(mirror_base)"
  [[ -z "${base}" ]] && return 1
  printf '%s/rathole-linux-%s' "${base%/}" "${arch}"
}

fetch_binary() {
  local dest="$1" verify_fn="$2" label="$3"; shift 3
  local url tmp
  for url in "$@"; do
    [[ -z "${url}" ]] && continue
    info "Downloading ${label}…"
    tmp="${dest}.tmp"
    rm -f "${tmp}"
    if fetch_url "${url}" "${tmp}"; then
      chmod +x "${tmp}"
      if "${verify_fn}" "${tmp}"; then
        mv -f "${tmp}" "${dest}"
        good "${label} installed."
        return 0
      fi
      warn "Downloaded file failed verification — trying next source…"
    else
      warn "Download failed — trying next source…"
    fi
    rm -f "${tmp}"
  done
  return 1
}

verify_fwd_tmp() {
  [[ -f "$1" && -x "$1" ]] && "$1" -V >/dev/null 2>&1
}

verify_relay_tmp() {
  [[ -f "$1" && -x "$1" ]] && "$1" version >/dev/null 2>&1
}

verify_reverse_tmp() {
  [[ -f "$1" && -x "$1" ]] && { "$1" --version >/dev/null 2>&1 || "$1" -h >/dev/null 2>&1; }
}

reset_binary_source() { BINARY_SOURCE=""; }

choose_binary_source() {
  [[ -n "${BINARY_SOURCE}" && -z "${PATH_TEST_FORCE_PICK:-}" ]] && return 0
  rule
  info "Binary download source (Phormal engines — local host and peer via SSH)"
  rule
  printf '  %s1%s  Iran mirror download [default]\n' "${ACC}" "${RST}"
  printf '  %s2%s  GitHub — official pinned releases\n' "${ACC}" "${RST}"
  printf '  %s3%s  Manual — files already in %s\n' "${ACC}" "${RST}" "${MANUAL_DIR}"
  printf '\n'
  local c; c="$(ask 'Select [1]')"; c="${c:-1}"
  case "${c}" in
    1|"") BINARY_SOURCE="mirror" ;;
    2)    BINARY_SOURCE="github" ;;
    3)    BINARY_SOURCE="manual" ;;
    *)    BINARY_SOURCE="mirror" ;;
  esac
  conf_set BINARY_SOURCE "${BINARY_SOURCE}"
  case "${BINARY_SOURCE}" in
    mirror) info "Selected: Iran mirror (then GitHub fallback on local + peer)." ;;
    github) info "Selected: GitHub releases only (local + peer)." ;;
    manual) info "Selected: manual files in ${MANUAL_DIR} (peer copies via scp after local install)." ;;
  esac
}

install_manual_fwd() {
  local arch src legacy
  arch="$(machine_arch)" || { fail "Unsupported architecture: $(uname -m)"; return 1; }
  src="${MANUAL_DIR}/phormal-bridge-linux-${arch}"
  legacy="${MANUAL_DIR}/gost-linux-${arch}"
  if [[ ! -f "${src}" ]]; then
    [[ -f "${legacy}" ]] && src="${legacy}" || {
      fail "Place the Phormal Bridge engine at ${MANUAL_DIR}/phormal-bridge-linux-${arch}"
      info "Or use mirror download (option 1) when the installer runs."
      return 1
    }
  fi
  cp -f "${src}" "${FWD_BIN}"
  chmod +x "${FWD_BIN}"
  if ! verify_fwd_tmp "${FWD_BIN}"; then
    fail "Binary at ${src} failed verification."
    info "Use mirror download (option 1) or replace the file in ${MANUAL_DIR}/."
    return 1
  fi
  good "Phormal Bridge engine installed (manual)."
}

install_manual_relay() {
  local arch src legacy
  arch="$(machine_arch)" || { fail "Unsupported architecture: $(uname -m)"; return 1; }
  src="${MANUAL_DIR}/phormal-relay-linux-${arch}"
  legacy="${MANUAL_DIR}/hysteria-linux-${arch}"
  if [[ ! -f "${src}" ]]; then
    [[ -f "${legacy}" ]] && src="${legacy}" || {
      fail "Place the Phormal Relay engine at ${MANUAL_DIR}/phormal-relay-linux-${arch}"
      info "Or use mirror download (option 1) when the installer runs."
      return 1
    }
  fi
  cp -f "${src}" "${RELAY_BIN}"
  chmod +x "${RELAY_BIN}"
  if ! verify_relay_tmp "${RELAY_BIN}"; then
    fail "Binary at ${src} failed verification."
    info "Use mirror download (option 1) or replace the file in ${MANUAL_DIR}/."
    return 1
  fi
  setcap cap_net_bind_service,cap_net_admin=+ep "${RELAY_BIN}" 2>/dev/null || true
  good "Phormal Relay engine installed (manual)."
}

rathole_release_zip_url() {
  local arch="$1" target
  case "${arch}" in
    amd64) target="x86_64-unknown-linux-gnu" ;;
    arm64) target="aarch64-unknown-linux-musl" ;;
    *) return 1 ;;
  esac
  printf 'https://github.com/%s/releases/download/%s/rathole-%s.zip' \
    "${RATHOLE_RELEASE_REPO}" "${RATHOLE_RELEASE_TAG}" "${target}"
}

install_rathole_from_release() {
  local arch tmpdir ziptmp
  arch="$(machine_arch)" || return 1
  apt_install_quiet unzip
  ziptmp="$(mktemp)"
  tmpdir="$(mktemp -d)"
  if ! fetch_url "$(rathole_release_zip_url "${arch}")" "${ziptmp}"; then
    rm -f "${ziptmp}"
    rm -rf "${tmpdir}"
    return 1
  fi
  unzip -q "${ziptmp}" -d "${tmpdir}"
  mv -f "${tmpdir}/rathole" "${REVERSE_BIN}"
  chmod +x "${REVERSE_BIN}"
  rm -f "${ziptmp}"
  rm -rf "${tmpdir}"
  verify_reverse_tmp "${REVERSE_BIN}"
}

install_manual_reverse() {
  local arch src legacy
  arch="$(machine_arch)" || { fail "Unsupported architecture: $(uname -m)"; return 1; }
  src="${MANUAL_DIR}/phormal-reverse-linux-${arch}"
  legacy="${MANUAL_DIR}/rathole-linux-${arch}"
  if [[ ! -f "${src}" ]]; then
    [[ -f "${legacy}" ]] && src="${legacy}" || {
      fail "Place the Phormal Reverse engine at ${MANUAL_DIR}/phormal-reverse-linux-${arch}"
      info "Or use mirror download (option 1) when the installer runs."
      return 1
    }
  fi
  cp -f "${src}" "${REVERSE_BIN}"
  chmod +x "${REVERSE_BIN}"
  if ! verify_reverse_tmp "${REVERSE_BIN}"; then
    fail "Binary at ${src} failed verification."
    return 1
  fi
  good "Phormal Reverse engine installed (manual)."
}

install_reverse_engine() {
  if [[ -x "${REVERSE_BIN}" ]] && verify_reverse_tmp "${REVERSE_BIN}"; then
    good "Phormal Reverse engine present."
    return 0
  fi
  choose_binary_source || true
  info "Installing Phormal Reverse engine…"

  if [[ "${BINARY_SOURCE}" == "manual" ]]; then
    install_manual_reverse || return 1
    return 0
  fi

  apt_install_quiet curl wget unzip

  local arch urls=()
  arch="$(machine_arch)" || { fail "Unsupported architecture: $(uname -m)"; return 1; }

  if [[ "${BINARY_SOURCE}" == "mirror" ]]; then
    local mirror
    if mirror="$(mirror_reverse_url "${arch}" 2>/dev/null || true)" && [[ -n "${mirror}" ]]; then
      urls+=("${mirror}")
    fi
    if fetch_binary "${REVERSE_BIN}" verify_reverse_tmp \
        "Phormal Reverse engine" "${urls[@]}"; then
      return 0
    fi
    install_rathole_from_release && good "Phormal Reverse engine installed." && return 0
  elif [[ "${BINARY_SOURCE}" == "github" ]]; then
    install_rathole_from_release && good "Phormal Reverse engine installed." && return 0
  fi

  install_local_binary "${REVERSE_BIN}" || return 1
  verify_reverse_tmp "${REVERSE_BIN}" || { fail "Binary is not runnable."; return 1; }
  good "Phormal Reverse engine installed."
}

random_core_prefix() {
  printf 'fd%02x:%02x%02x:%02x%02x:%02x%02x' \
    $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) \
    $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

conf_get() { [[ -f "${PHORMAL_CONF}" ]] && grep -E "^${1}=" "${PHORMAL_CONF}" | head -n1 | cut -d= -f2- || true; }

conf_set() {
  local key="$1" val="$2"
  mkdir -p "${PHORMAL_HOME}"
  if grep -qE "^${key}=" "${PHORMAL_CONF}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${PHORMAL_CONF}"
  else
    echo "${key}=${val}" >> "${PHORMAL_CONF}"
  fi
}

rand_secret() { openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | xxd -p; }

merge_port_list() {
  printf '%s,%s' "${1:-}" "${2:-}" | tr ',' '\n' | sed '/^$/d' | awk '!seen[$0]++' | paste -sd, -
}

remove_port_from_list() {
  local list="$1" rem="$2" p out=""
  IFS=',' read -ra parr <<< "${list}"
  for p in "${parr[@]}"; do
    [[ "${p}" == "${rem}" ]] && continue
    out="${out:+${out},}${p}"
  done
  printf '%s' "${out}"
}

restart_bridge_services() {
  systemctl restart phormal-core.service 2>/dev/null || true
  systemctl restart phormal-guard.service 2>/dev/null || true
  systemctl restart 'phormal-fwd@*.service' 2>/dev/null || true
  good "Phormal Bridge services restarted."
}

restart_relay_service() {
  systemctl restart phormal-relay.service 2>/dev/null || true
  sleep 1
  if systemctl is-active phormal-relay.service >/dev/null 2>&1; then
    good "Phormal Relay service restarted."
  else
    fail "Phormal Relay failed to restart."
    journalctl -u phormal-relay -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
    return 1
  fi
}

install_speed_tool() {
  have iperf3 && return 0
  info "Installing Phormal speed tool…"
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y iperf3 >/dev/null 2>&1 || true
  have iperf3 || { fail "Could not install speed tool."; return 1; }
}

primary_iface() {
  ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

# ------------------------------------------------------------------------------
#  NETWORK TUNING
# ------------------------------------------------------------------------------
apply_tuning() {
  local qdisc="${1:-fq}"
  info "Applying Phormal tuning…"

  cat > /etc/sysctl.d/98-phormal-tuning.conf <<EOF
# Phormal network tuning
net.core.default_qdisc = ${qdisc}
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_notsent_lowat = 16384
EOF
  modprobe tcp_bbr 2>/dev/null || true
  sysctl --system >/dev/null 2>&1 || true

  local egress; egress="$(primary_iface)"
  if [[ -n "${egress}" ]]; then
    tc qdisc replace dev "${egress}" root "${qdisc}" 2>/dev/null \
      && good "Queue discipline '${qdisc}' active on ${egress}." \
      || warn "Could not set '${qdisc}' on ${egress}."
  fi

  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    good "Phormal tuning active."
  else
    warn "Tuning not confirmed — a reboot may be required."
  fi
}

tune_menu() {
  rule
  info "Network tuning"
  rule
  printf '  %s1%s  Balanced      %s(recommended)%s\n' "${ACC}" "${RST}" "${MUT}" "${RST}"
  printf '  %s2%s  Low-latency\n' "${ACC}" "${RST}"
  local q; q="$(ask 'Profile')"
  case "${q}" in
    1) apply_tuning fq ;;
    2) apply_tuning cake ;;
    *) fail "Invalid selection." ;;
  esac
}

# ==============================================================================
#  PHORMAL BRIDGE  (multi-instance)
#
#  Each link is a named instance living in:   /etc/phormal/bridge/<name>/
#    - meta.conf   key=val metadata for this link
#  A SIT tunnel is point-to-point, so ONE exit (kharej) serves N entries by
#  creating one exit link per Iran peer (each with its own iface + bridge key).
#  Services per link (systemd templates):
#    phormal-core@<name>   SIT bring-up/down       (oneshot)
#    phormal-guard@<name>  keepalive ping          (entry + exit)
#    phormal-bfwd@<name>   port publisher (gost)   (entry only)
# ==============================================================================
readonly BRIDGE_DIR="${PHORMAL_HOME}/bridge"
readonly BRIDGE_RUN="/usr/local/bin/phormal-bridge-run"
readonly BCORE_TMPL="/etc/systemd/system/phormal-core@.service"
readonly BGUARD_TMPL="/etc/systemd/system/phormal-guard@.service"
readonly BFWD_TMPL="/etc/systemd/system/phormal-bfwd@.service"

# ------------------------------------------------------------------------------
#  Publisher engine (gost) — shared by every entry link
# ------------------------------------------------------------------------------
install_engine() {
  if [[ -x "${FWD_BIN}" ]] && "${FWD_BIN}" -V >/dev/null 2>&1; then
    good "Phormal Bridge engine present."
    return 0
  fi
  choose_binary_source || true
  info "Installing Phormal Bridge engine…"

  if [[ "${BINARY_SOURCE}" == "manual" ]]; then
    install_manual_fwd || return 1
    return 0
  fi

  apt_install_quiet curl wget tar gzip iptables

  if [[ "${BINARY_SOURCE}" == "mirror" ]]; then
    local arch urls=() mirror
    if arch="$(machine_arch)"; then
      if mirror="$(mirror_fwd_url "${arch}" 2>/dev/null || true)" && [[ -n "${mirror}" ]]; then
        urls+=("${mirror}")
      fi
      if fetch_binary "${FWD_BIN}" verify_fwd_tmp \
          "Phormal Bridge engine" "${urls[@]}"; then
        return 0
      fi
    fi
    info "Mirror unavailable — trying upstream Bridge engine release v${GOST_RELEASE_VERSION}…"
    if install_gost_from_release; then
      good "Phormal Bridge engine installed."
      return 0
    fi
  elif [[ "${BINARY_SOURCE}" == "github" ]]; then
    info "Fetching Bridge engine release v${GOST_RELEASE_VERSION} from GitHub…"
    if install_gost_from_release; then
      good "Phormal Bridge engine installed."
      return 0
    fi
  fi

  info "Trying Bridge engine install script…"
  if bash <(curl -fsSL --connect-timeout 20 --max-time 180 \
      https://github.com/go-gost/gost/raw/master/install.sh) --install >/dev/null 2>&1 \
     && have gost; then
    ln -sf "$(command -v gost)" "${FWD_BIN}"
    good "Phormal Bridge engine installed."
    return 0
  fi

  install_local_binary "${FWD_BIN}" || { fail "Bridge engine install failed."; return 1; }
  "${FWD_BIN}" -V >/dev/null 2>&1 || { fail "Binary is not runnable."; return 1; }
  good "Phormal Bridge engine installed."
}

gather_ports() {
  local manual ranges merged=""
  manual="$(ask 'Single ports (comma list, e.g. 7171,6161) [blank to skip]')"
  ranges="$(ask 'Port ranges (comma list, e.g. 2000-2100,8000-8010) [blank to skip]')"

  [[ -n "${manual}" ]] && merged="${manual}"

  if [[ -n "${ranges}" ]]; then
    local IFS=','; local r
    for r in ${ranges}; do
      r="${r// /}"
      local s="${r%-*}" e="${r#*-}"
      if [[ "${s}" =~ ^[0-9]+$ && "${e}" =~ ^[0-9]+$ && ${s} -le ${e} ]]; then
        merged="${merged:+${merged},}$(seq -s, "${s}" "${e}")"
      else
        warn "Ignoring invalid range: ${r}"
      fi
    done
  fi
  printf '%s' "${merged}" | tr ',' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -
}

first_port_from_list() {
  local list="$1" p
  IFS=',' read -ra parr <<< "${list}"
  for p in "${parr[@]}"; do
    p="${p// /}"
    [[ -n "${p}" && "${p}" =~ ^[0-9]+$ ]] && { printf '%s' "${p}"; return 0; }
  done
  return 1
}

# ------------------------------------------------------------------------------
#  Instance registry helpers
# ------------------------------------------------------------------------------
bridge_idir() { printf '%s/%s' "${BRIDGE_DIR}" "$1"; }

bridge_systemd_names() {
  local seen="" u name
  while read -r u; do
    [[ "${u}" == phormal-core@*.service ]] || continue
    name="${u#phormal-core@}"
    name="${name%.service}"
    [[ -n "${name}" ]] || continue
    [[ ",${seen}," == *",${name},"* ]] && continue
    seen="${seen:+${seen},}${name}"
    printf '%s\n' "${name}"
  done < <(
    {
      systemctl list-unit-files 'phormal-core@*' --no-legend --no-pager 2>/dev/null | awk '{print $1}'
      systemctl list-units 'phormal-core@*' --all --no-legend --no-pager 2>/dev/null | awk '{print $1}'
    } | sort -u
  )
}

bridge_legacy_iface() {
  ip link show "${CORE_IFACE}" &>/dev/null && { printf '%s' "${CORE_IFACE}"; return 0; }
  # only a genuine legacy SIT iface — never our own phm-* multi-instance links or sit0
  ip -o link show type sit 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' \
    | grep -vE '^(phm-|sit0$)' | head -n1
}

bridge_import_legacy() {
  local name="main" iface gost_ps proto ports peer_core self_core core_key role
  local local_v4 remote_v4 mtu

  bridge_instances | grep -q . && return 0
  [[ -f "$(bridge_idir "${name}")/meta.conf" ]] && return 0

  gost_ps="$(ps -eo args 2>/dev/null | grep -E "${FWD_BIN}|/[g]ost" | grep -v grep | head -n1 || true)"
  iface="$(bridge_legacy_iface)"
  [[ -n "${gost_ps}" || -n "${iface}" || -f "${PHORMAL_CONF}" ]] || return 0

  proto="tcp"; ports=""; peer_core=""; self_core=""; role="entry"
  if [[ -n "${gost_ps}" ]]; then
    proto="$(printf '%s' "${gost_ps}" | grep -oE '\-L=[a-z0-9]+://' | head -n1 | sed 's/-L=//;s|://||')"
    ports="$(printf '%s' "${gost_ps}" | grep -oE ':[0-9]+/\[' | sed 's/[:/\[]//g' | paste -sd, -)"
    peer_core="$(printf '%s' "${gost_ps}" | grep -oE '\[[^]]+\]' | head -n1 | tr -d '[]')"
  fi

  if [[ -n "${iface}" ]]; then
    local_v4="$(ip -d link show "${iface}" 2>/dev/null | sed -n 's/.* local \([^ ]*\).*/\1/p' | head -n1)"
    remote_v4="$(ip -d link show "${iface}" 2>/dev/null | sed -n 's/.* remote \([^ ]*\).*/\1/p' | head -n1)"
    self_core="$(ip -6 -o addr show dev "${iface}" scope global 2>/dev/null | awk '{print $4}' | head -n1 | cut -d/ -f1)"
    mtu="$(ip -o link show "${iface}" 2>/dev/null | awk '{print $5}')"
  fi

  if [[ -f "${PHORMAL_CONF}" ]]; then
    [[ -n "$(conf_get ROLE)" ]]       && role="$(conf_get ROLE)"
    [[ -n "$(conf_get LOCAL_V4)" ]]   && local_v4="$(conf_get LOCAL_V4)"
    [[ -n "$(conf_get REMOTE_V4)" ]]  && remote_v4="$(conf_get REMOTE_V4)"
    [[ -n "$(conf_get SELF_CORE)" ]]  && self_core="$(conf_get SELF_CORE)"
    [[ -n "$(conf_get PEER_CORE)" ]]  && peer_core="$(conf_get PEER_CORE)"
    [[ -n "$(conf_get PORTS)" ]]      && ports="$(conf_get PORTS)"
    [[ -n "$(conf_get PROTO)" ]]      && proto="$(conf_get PROTO)"
    [[ -n "$(conf_get MTU)" ]]        && mtu="$(conf_get MTU)"
    [[ -n "$(conf_get IFACE)" ]]      && iface="$(conf_get IFACE)"
  fi

  [[ -n "${peer_core}" || -n "${self_core}" ]] || return 0
  [[ -n "${self_core}" ]] || self_core="${peer_core%::[12]}::2"
  core_key="${self_core%::[12]}"
  [[ -n "${peer_core}" ]] || { [[ "${role}" == "exit" ]] && peer_core="${core_key}::2" || peer_core="${core_key}::1"; }
  [[ -n "${iface}" ]] || iface="${CORE_IFACE}"

  mkdir -p "$(bridge_idir "${name}")"
  bmeta_set "${name}" ROLE "${role}"
  bmeta_set "${name}" IFACE "${iface}"
  bmeta_set "${name}" LOCAL_V4 "${local_v4:-}"
  bmeta_set "${name}" REMOTE_V4 "${remote_v4:-}"
  bmeta_set "${name}" CORE_KEY "${core_key}"
  bmeta_set "${name}" SELF_CORE "${self_core}"
  bmeta_set "${name}" PEER_CORE "${peer_core}"
  bmeta_set "${name}" MTU "${mtu:-${DEFAULT_MTU}}"
  bmeta_set "${name}" PROTO "${proto:-tcp}"
  [[ -n "${ports}" ]] && bmeta_set "${name}" PORTS "${ports}"
  bmeta_set "${name}" LEGACY "1"

  warn "Imported legacy bridge setup as link '${name}' (old install — not multi-instance yet)."
}

bridge_recover_from_runtime() {
  local name iface local_v4 remote_v4 self_core peer_core role mtu proto ports core_key gost_ps
  while read -r name; do
    [[ -n "${name}" ]] || continue
    [[ -f "$(bridge_idir "${name}")/meta.conf" ]] && continue

    iface="$(bridge_make_iface "${name}")"
    ip link show "${iface}" &>/dev/null \
      || systemctl is-active "$(bcore_svc "${name}")" &>/dev/null \
      || continue

    local_v4="$(ip -d link show "${iface}" 2>/dev/null | sed -n 's/.* local \([^ ]*\).*/\1/p' | head -n1)"
    remote_v4="$(ip -d link show "${iface}" 2>/dev/null | sed -n 's/.* remote \([^ ]*\).*/\1/p' | head -n1)"
    self_core="$(ip -6 -o addr show dev "${iface}" scope global 2>/dev/null | awk '{print $4}' | head -n1 | cut -d/ -f1)"
    mtu="$(ip -o link show "${iface}" 2>/dev/null | awk '{print $5}')"
    [[ -n "${self_core}" && -n "${remote_v4}" ]] || continue

    core_key="${self_core%::[12]}"
    if [[ "${self_core}" == *::2 ]] \
       || systemctl is-enabled "$(bfwd_svc "${name}")" &>/dev/null \
       || systemctl is-active "$(bfwd_svc "${name}")" &>/dev/null; then
      role="entry"; peer_core="${core_key}::1"
    else
      role="exit"; peer_core="${core_key}::2"
    fi

    proto="tcp"; ports=""
    gost_ps="$(ps -eo args 2>/dev/null | grep -E "${FWD_BIN}|/[g]ost" | head -n1 || true)"
    if [[ -n "${gost_ps}" ]]; then
      proto="$(printf '%s' "${gost_ps}" | grep -oE '\-L=[a-z0-9]+://' | head -n1 | sed 's/-L=//;s|://||')"
      ports="$(printf '%s' "${gost_ps}" | grep -oE ':[0-9]+/\[' | sed 's/[:/\[]//g' | paste -sd, -)"
    fi

    mkdir -p "$(bridge_idir "${name}")"
    bmeta_set "${name}" ROLE "${role}"
    bmeta_set "${name}" IFACE "${iface}"
    bmeta_set "${name}" LOCAL_V4 "${local_v4:-}"
    bmeta_set "${name}" REMOTE_V4 "${remote_v4}"
    bmeta_set "${name}" CORE_KEY "${core_key}"
    bmeta_set "${name}" SELF_CORE "${self_core}"
    bmeta_set "${name}" PEER_CORE "${peer_core}"
    bmeta_set "${name}" MTU "${mtu:-${DEFAULT_MTU}}"
    bmeta_set "${name}" PROTO "${proto:-tcp}"
    [[ -n "${ports}" ]] && bmeta_set "${name}" PORTS "${ports}"

    warn "Recovered bridge link '${name}' from running services (meta.conf was missing)."
  done < <(bridge_systemd_names)
}

bridge_instances() {
  local d
  mkdir -p "${BRIDGE_DIR}"
  shopt -s nullglob
  for d in "${BRIDGE_DIR}"/*/; do
    [[ -f "${d}meta.conf" ]] || continue
    basename "${d}"
  done
  shopt -u nullglob
}

bmeta_get() {
  local name="$1" key="$2" f
  f="$(bridge_idir "${name}")/meta.conf"
  [[ -f "${f}" ]] && grep -E "^${key}=" "${f}" | head -n1 | cut -d= -f2- || true
}

bmeta_set() {
  local name="$1" key="$2" val="$3" f
  f="$(bridge_idir "${name}")/meta.conf"
  mkdir -p "$(dirname "${f}")"; touch "${f}"
  if grep -qE "^${key}=" "${f}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${f}"
  else
    echo "${key}=${val}" >> "${f}"
  fi
}

bcore_svc()  { printf 'phormal-core@%s.service' "$1"; }
bguard_svc() { printf 'phormal-guard@%s.service' "$1"; }
bfwd_svc()   { printf 'phormal-bfwd@%s.service' "$1"; }

bridge_link_running_legacy() {
  local name="$1" iface role
  iface="$(bmeta_get "${name}" IFACE)"
  role="$(bmeta_get "${name}" ROLE)"
  [[ -n "${iface}" ]] || return 1
  ip link show "${iface}" 2>/dev/null | grep -q 'state UP' || return 1
  if [[ "${role}" == "entry" ]]; then
    pgrep -f "${FWD_BIN}" >/dev/null 2>&1 || systemctl is-active phormal-fwd.service &>/dev/null
  else
    return 0
  fi
}

bcore_state() {
  local name="$1" st iface
  st="$(systemctl is-active "$(bcore_svc "${name}")" 2>/dev/null || true)"
  [[ "${st}" == "active" ]] && { printf 'active'; return 0; }
  if [[ "${name}" == "main" ]] && systemctl is-active phormal-core.service &>/dev/null; then
    printf 'active'; return 0
  fi
  iface="$(bmeta_get "${name}" IFACE)"
  if [[ -n "${iface}" ]] && ip link show "${iface}" 2>/dev/null | grep -qE 'UP|LOWER_UP'; then
    printf 'running'; return 0
  fi
  if bridge_link_running_legacy "${name}"; then
    printf 'running'; return 0
  fi
  [[ -n "${st}" && "${st}" != "unknown" ]] && printf '%s' "${st}" || printf 'inactive'
}

bridge_stop_legacy_procs() {
  # stop + disable the old single-instance bridge runtime
  systemctl stop    phormal-fwd.service phormal-guard.service phormal-core.service 2>/dev/null || true
  systemctl disable phormal-fwd.service phormal-guard.service phormal-core.service 2>/dev/null || true
  # old numeric publisher instances (phormal-fwd@0, @1 …) — NOT the new phormal-bfwd@
  systemctl stop    'phormal-fwd@*.service' 2>/dev/null || true
  systemctl disable 'phormal-fwd@*.service' 2>/dev/null || true
  pkill -f "${FWD_BIN}" 2>/dev/null || true
  # remove the old unit files + flat config + legacy iface so the importer can't resurrect it
  rm -f /etc/systemd/system/phormal-core.service \
        /etc/systemd/system/phormal-guard.service \
        /etc/systemd/system/phormal-fwd.service \
        /etc/systemd/system/phormal-fwd@*.service \
        "${CORE_UP_SCRIPT}" "${PHORMAL_CONF}"
  ip link del "${CORE_IFACE}" 2>/dev/null || true
  systemctl daemon-reload
  sleep 1
}

# interface names are capped at 15 chars by the kernel (IFNAMSIZ)
bridge_make_iface() { local n="phm-$1"; printf '%s' "${n:0:15}"; }

# ------------------------------------------------------------------------------
#  systemd templates + dispatcher (installed once)
# ------------------------------------------------------------------------------
bridge_install_runtime() {
  cat > "${BRIDGE_RUN}" <<EOF
#!/usr/bin/env bash
# Phormal bridge launcher — up/down/guard/fwd for a named SIT link.
set -e
cmd="\$1"; name="\$2"
dir="${BRIDGE_DIR}/\${name}"
[[ -f "\${dir}/meta.conf" ]] || { echo "no such bridge link: \${name}" >&2; exit 1; }
get(){ grep -E "^\$1=" "\${dir}/meta.conf" | head -n1 | cut -d= -f2-; }
IFACE="\$(get IFACE)"; LOCAL_V4="\$(get LOCAL_V4)"; REMOTE_V4="\$(get REMOTE_V4)"
SELF_CORE="\$(get SELF_CORE)"; PEER_CORE="\$(get PEER_CORE)"
MTU="\$(get MTU)"; MTU="\${MTU:-${DEFAULT_MTU}}"
PROTO="\$(get PROTO)"; PROTO="\${PROTO:-tcp}"; PORTS="\$(get PORTS)"
FWD_BIN="${FWD_BIN}"
case "\${cmd}" in
  up)
    ip link del "\${IFACE}" 2>/dev/null || true
    ip tunnel add "\${IFACE}" mode sit remote "\${REMOTE_V4}" local "\${LOCAL_V4}" ttl 255
    ip link set "\${IFACE}" up
    ip link set dev "\${IFACE}" mtu "\${MTU}"
    ip -6 addr add "\${SELF_CORE}/64" dev "\${IFACE}"
    ip6tables -t mangle -C FORWARD -o "\${IFACE}" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \\
      || ip6tables -t mangle -A FORWARD -o "\${IFACE}" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    ip6tables -t mangle -C OUTPUT  -o "\${IFACE}" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \\
      || ip6tables -t mangle -A OUTPUT  -o "\${IFACE}" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    ;;
  down)
    ip link del "\${IFACE}" 2>/dev/null || true
    ;;
  guard)
    while :; do ping6 -c1 -W2 "\${PEER_CORE}" >/dev/null 2>&1 || true; sleep 15; done
    ;;
  fwd)
    [[ -z "\${PEER_CORE}" ]] && { echo "PEER_CORE empty in meta.conf — refusing to start (would crash Bridge forwarder)" >&2; exit 1; }
    args=()
    IFS=',' read -ra parr <<< "\${PORTS}"
    for p in "\${parr[@]}"; do
      [[ -n "\${p}" ]] && args+=( "-L=\${PROTO}://:\${p}/[\${PEER_CORE}]:\${p}" )
    done
    [[ \${#args[@]} -eq 0 ]] && { echo "no ports configured" >&2; exit 1; }
    exec "\${FWD_BIN}" "\${args[@]}"
    ;;
  *) echo "usage: phormal-bridge-run {up|down|guard|fwd} <name>" >&2; exit 2 ;;
esac
EOF
  chmod +x "${BRIDGE_RUN}"

  cat > "${BCORE_TMPL}" <<EOF
[Unit]
Description=Phormal Bridge link (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 2
ExecStart=${BRIDGE_RUN} up %i
ExecStop=${BRIDGE_RUN} down %i

[Install]
WantedBy=multi-user.target
EOF

  cat > "${BGUARD_TMPL}" <<EOF
[Unit]
Description=Phormal Bridge guardian (%i)
After=phormal-core@%i.service
Requires=phormal-core@%i.service

[Service]
Type=simple
ExecStart=${BRIDGE_RUN} guard %i
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  cat > "${BFWD_TMPL}" <<EOF
[Unit]
Description=Phormal Bridge forwarder (%i)
After=phormal-core@%i.service network-online.target
Wants=phormal-core@%i.service

[Service]
Type=simple
Environment="GOST_LOGGER_LEVEL=fatal"
ExecStart=${BRIDGE_RUN} fwd %i
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

# ------------------------------------------------------------------------------
#  Start / restart an instance (core + guard, plus fwd for entries)
# ------------------------------------------------------------------------------
bridge_start_instance() {
  local name="$1" role; role="$(bmeta_get "${name}" ROLE)"
  bridge_install_runtime
  if [[ "$(bmeta_get "${name}" LEGACY)" == "1" ]] || bridge_link_running_legacy "${name}"; then
    info "Migrating legacy bridge '${name}' to multi-instance services…"
    bridge_stop_legacy_procs
  fi
  systemctl daemon-reload
  systemctl enable "$(bcore_svc "${name}")"  >/dev/null 2>&1
  systemctl enable "$(bguard_svc "${name}")" >/dev/null 2>&1
  systemctl restart "$(bcore_svc "${name}")"
  systemctl restart "$(bguard_svc "${name}")"
  if [[ "${role}" == "entry" ]]; then
    systemctl enable "$(bfwd_svc "${name}")" >/dev/null 2>&1
    systemctl restart "$(bfwd_svc "${name}")"
  fi
  sleep 1
  if systemctl is-active "$(bcore_svc "${name}")" >/dev/null 2>&1; then
    bmeta_set "${name}" LEGACY "0"
    good "Bridge link '${name}' is up."
  else
    fail "Bridge link '${name}' failed to come up. Recent log:"
    journalctl -u "$(bcore_svc "${name}")" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
    return 1
  fi
}

bridge_ping_peer() {
  local name="$1" peer rx
  peer="$(bmeta_get "${name}" PEER_CORE)"
  [[ -z "${peer}" ]] && return 1
  rx="$(ping6 -c5 -i0.3 -W2 "${peer}" 2>/dev/null | grep -oE '[0-9]+ received' | grep -oE '^[0-9]+' | head -n1)"
  rx="${rx:-0}"
  if [[ "${rx}" -gt 0 ]]; then good "peer reachable (${rx}/5)"; else warn "peer unreachable (0/5) — bring up the other node"; fi
}

# ------------------------------------------------------------------------------
#  Create links
# ------------------------------------------------------------------------------
bridge_pick_name() {
  local raw name
  raw="$(ask 'Link name (e.g. iran1, iran2)')"
  name="$(relay_sanitize_name "${raw}")"
  if [[ -f "$(bridge_idir "${name}")/meta.conf" ]]; then
    warn "A link named '${name}' already exists." >&2
    printf '%s' ""; return 1
  fi
  printf '%s' "${name}"
}

create_bridge_exit() {
  rule
  info "Phormal Bridge — new EXIT link (this server = kharej)"
  info "Create one exit link per Iran peer. Run your service locally."
  rule

  # Exit links do not run gost — skip install_engine (silent redirect hid the source menu and hung).
  apply_tuning fq
  bridge_install_runtime

  local name; name="$(bridge_pick_name)" || return 1
  [[ -z "${name}" ]] && { fail "Invalid name."; return 1; }
  mkdir -p "$(bridge_idir "${name}")"

  local local_v4 remote_v4
  local_v4="$(ask 'This (exit) node public IPv4')"
  remote_v4="$(ask 'Peer (Iran/entry) node public IPv4')"
  if ! valid_ipv4 "${local_v4}" || ! valid_ipv4 "${remote_v4}"; then
    fail "Invalid IPv4 address."; rm -rf "$(bridge_idir "${name}")"; return 1
  fi

  local suggested prefix
  suggested="$(random_core_prefix)"
  info "Bridge key (must match the matching Iran link). Suggested: ${BOLD}${suggested}${RST}"
  prefix="$(ask 'Bridge key [Enter for suggested]')"; prefix="${prefix:-${suggested}}"

  local mtu
  mtu="$(ask "Link MTU [Enter for ${DEFAULT_MTU}]")"
  [[ "${mtu}" =~ ^[0-9]+$ ]] || mtu="${DEFAULT_MTU}"

  bmeta_set "${name}" ROLE exit
  bmeta_set "${name}" IFACE "$(bridge_make_iface "${name}")"
  bmeta_set "${name}" LOCAL_V4 "${local_v4}"
  bmeta_set "${name}" REMOTE_V4 "${remote_v4}"
  bmeta_set "${name}" CORE_KEY "${prefix}"
  bmeta_set "${name}" SELF_CORE "${prefix}::1"
  bmeta_set "${name}" PEER_CORE "${prefix}::2"
  bmeta_set "${name}" MTU "${mtu}"

  bridge_start_instance "${name}" || return 1
  echo
  good "Exit link '${name}' created."
  info "  iface     : $(bmeta_get "${name}" IFACE)"
  info "  local v6  : ${prefix}::1"
  info "  peer  v6  : ${prefix}::2"
  info "  bridge key: ${prefix}  ${MUT}(use this on the matching Iran link)${RST}"
  warn "On the Iran node, add an entry link to ${local_v4} with bridge key ${prefix}."
  bridge_ping_peer "${name}" || true
}

create_bridge_entry() {
  rule
  info "Phormal Bridge — new ENTRY link (this server = iran)"
  info "Publishes user ports here, forwarding over the Phormal Bridge tunnel to the exit."
  rule

  install_engine || return 1
  apply_tuning fq
  bridge_install_runtime

  local name; name="$(bridge_pick_name)" || return 1
  [[ -z "${name}" ]] && { fail "Invalid name."; return 1; }
  mkdir -p "$(bridge_idir "${name}")"

  local local_v4 remote_v4
  local_v4="$(ask 'This (Iran/entry) node public IPv4')"
  remote_v4="$(ask 'Exit (kharej) node public IPv4')"
  if ! valid_ipv4 "${local_v4}" || ! valid_ipv4 "${remote_v4}"; then
    fail "Invalid IPv4 address."; rm -rf "$(bridge_idir "${name}")"; return 1
  fi

  local prefix
  info "Bridge key — must MATCH the exit link created for this Iran node."
  prefix="$(ask 'Bridge key')"
  [[ -z "${prefix}" ]] && { fail "Bridge key is required."; rm -rf "$(bridge_idir "${name}")"; return 1; }

  local mtu
  mtu="$(ask "Link MTU [Enter for ${DEFAULT_MTU}]")"
  [[ "${mtu}" =~ ^[0-9]+$ ]] || mtu="${DEFAULT_MTU}"

  local proto pc
  printf '  %s1%s  tcp   %s2%s  udp   %s3%s  grpc\n' "${ACC}" "${RST}" "${ACC}" "${RST}" "${ACC}" "${RST}"
  pc="$(ask 'Transport')"
  case "${pc}" in 1) proto=tcp ;; 2) proto=udp ;; 3) proto=grpc ;; *) proto=tcp ;; esac

  local ports; ports="$(gather_ports)"
  [[ -z "${ports}" ]] && { fail "No valid ports provided."; rm -rf "$(bridge_idir "${name}")"; return 1; }

  bmeta_set "${name}" ROLE entry
  bmeta_set "${name}" IFACE "$(bridge_make_iface "${name}")"
  bmeta_set "${name}" LOCAL_V4 "${local_v4}"
  bmeta_set "${name}" REMOTE_V4 "${remote_v4}"
  bmeta_set "${name}" CORE_KEY "${prefix}"
  bmeta_set "${name}" SELF_CORE "${prefix}::2"
  bmeta_set "${name}" PEER_CORE "${prefix}::1"
  bmeta_set "${name}" MTU "${mtu}"
  bmeta_set "${name}" PROTO "${proto}"
  bmeta_set "${name}" PORTS "${ports}"

  bridge_start_instance "${name}" || return 1
  echo
  good "Entry link '${name}' live — ports: ${ports}"
  info "  Link target : ${remote_v4} (peer v6 ${prefix}::1)"
  good "Point users at THIS server's public IP on those ports."
  bridge_ping_peer "${name}" || true
}

# ------------------------------------------------------------------------------
#  Per-link management
# ------------------------------------------------------------------------------
bridge_list() {
  bridge_import_legacy
  bridge_recover_from_runtime
  rule
  info "Phormal Bridge — links"
  rule
  local n any=0
  printf '    %-14s %-6s %-16s %-9s %s\n' "NAME" "ROLE" "PEER IPv4" "STATE" "PORTS"
  while read -r n; do
    [[ -n "${n}" ]] || continue
    any=1
    printf '    %-14s %-6s %-16s %-9s %s\n' \
      "${n}" "$(bmeta_get "${n}" ROLE)" "$(bmeta_get "${n}" REMOTE_V4)" \
      "$(bcore_state "${n}")" "$(bmeta_get "${n}" PORTS || true)"
  done < <(bridge_instances)
  [[ ${any} -eq 0 ]] && warn "no bridge links configured yet"
  rule
}

bridge_choose_instance() {
  local names=() n i
  while read -r n; do [[ -n "${n}" ]] && names+=("${n}"); done < <(bridge_instances)
  if [[ ${#names[@]} -eq 0 ]]; then warn "No bridge links configured." >&2; printf '%s' ""; return 1; fi
  {
    for i in "${!names[@]}"; do
      printf '  %s%s%s  %s (%s, %s)\n' "${ACC}" "$((i+1))" "${RST}" \
        "${names[i]}" "$(bmeta_get "${names[i]}" ROLE)" "$(bcore_state "${names[i]}")"
    done
  } >&2
  local sel; sel="$(ask 'Link number')"
  [[ "${sel}" =~ ^[0-9]+$ ]] || { printf '%s' ""; return 1; }
  local idx=$((sel-1))
  [[ ${idx} -ge 0 && ${idx} -lt ${#names[@]} ]] || { printf '%s' ""; return 1; }
  printf '%s' "${names[idx]}"
}

bridge_instance_edit_ports() {
  local name="$1" role ports
  role="$(bmeta_get "${name}" ROLE)"
  [[ "${role}" == "entry" ]] || { fail "Ports are only published on entry links."; return 1; }
  ports="$(bmeta_get "${name}" PORTS)"
  info "Current ports: ${ports:-none}"
  printf '  %s1%s  Add port   %s2%s  Remove port   %s3%s  Replace all\n' \
    "${ACC}" "${RST}" "${ACC}" "${RST}" "${ACC}" "${RST}"
  local c; c="$(ask 'Action')"
  case "${c}" in
    1) local p; p="$(ask 'Port to add')"; [[ "${p}" =~ ^[0-9]+$ ]] || { fail "Invalid port."; return 1; }
       ports="$(merge_port_list "${ports}" "${p}")" ;;
    2) local p; p="$(ask 'Port to remove')"; ports="$(remove_port_from_list "${ports}" "${p}")"
       [[ -z "${ports}" ]] && { fail "Cannot remove the last port."; return 1; } ;;
    3) ports="$(gather_ports)"; [[ -z "${ports}" ]] && { fail "No valid ports."; return 1; } ;;
    *) fail "Invalid action."; return 1 ;;
  esac
  bmeta_set "${name}" PORTS "${ports}"
  systemctl restart "$(bfwd_svc "${name}")" 2>/dev/null || true
  good "Ports for '${name}' now: ${ports}"
}

bridge_instance_change_peer() {
  local name="$1" ip
  ip="$(ask "Peer node IPv4 [$(bmeta_get "${name}" REMOTE_V4)]")"
  [[ -z "${ip}" ]] && return 0
  valid_ipv4 "${ip}" || { fail "Invalid IPv4."; return 1; }
  bmeta_set "${name}" REMOTE_V4 "${ip}"
  bridge_start_instance "${name}"
  good "Peer IPv4 for '${name}' updated to ${ip}."
}

bridge_instance_change_mtu() {
  local name="$1" mtu iface
  mtu="$(ask "New MTU [$(bmeta_get "${name}" MTU)] (try ${DEFAULT_MTU}, then 1280)")"
  [[ "${mtu}" =~ ^[0-9]+$ ]] || { fail "Not a number."; return 1; }
  bmeta_set "${name}" MTU "${mtu}"
  iface="$(bmeta_get "${name}" IFACE)"
  ip link set dev "${iface}" mtu "${mtu}" 2>/dev/null || true
  bridge_start_instance "${name}"
  good "MTU for '${name}' set to ${mtu}."
}

bridge_instance_change_key() {
  local name="$1" k
  warn "The bridge key must be identical on both ends of this link."
  k="$(ask "Bridge key [$(bmeta_get "${name}" CORE_KEY)]")"
  [[ -z "${k}" ]] && return 0
  local role suffix peersuffix
  role="$(bmeta_get "${name}" ROLE)"
  if [[ "${role}" == "exit" ]]; then suffix="::1"; peersuffix="::2"; else suffix="::2"; peersuffix="::1"; fi
  bmeta_set "${name}" CORE_KEY "${k}"
  bmeta_set "${name}" SELF_CORE "${k}${suffix}"
  bmeta_set "${name}" PEER_CORE "${k}${peersuffix}"
  bridge_start_instance "${name}"
  good "Bridge key for '${name}' updated."
}

bridge_instance_edit_raw() {
  local name="$1" dir; dir="$(bridge_idir "${name}")"
  info "  ${dir}/meta.conf"
  local c; c="$(ask 'Edit meta now? (y/n)')"
  [[ "${c}" == "y" ]] && ${EDITOR:-nano} "${dir}/meta.conf"
  local r; r="$(ask 'Restart link to apply? (y/n)')"
  [[ "${r}" == "y" ]] && bridge_start_instance "${name}"
}

bridge_instance_delete() {
  local name="$1"
  local c; c="$(ask "Delete bridge link '${name}' permanently? (y/n)")"
  [[ "${c}" != "y" ]] && { info "Cancelled."; return 0; }
  # if this link is still a legacy single-instance setup, fully purge it first,
  # otherwise the legacy importer re-creates it on the next menu view
  if [[ "$(bmeta_get "${name}" LEGACY)" == "1" ]] || bridge_link_running_legacy "${name}"; then
    info "Removing legacy single-instance runtime for '${name}'…"
    bridge_stop_legacy_procs
  fi
  systemctl stop    "$(bfwd_svc "${name}")"  2>/dev/null || true
  systemctl disable "$(bfwd_svc "${name}")"  2>/dev/null || true
  systemctl stop    "$(bguard_svc "${name}")" 2>/dev/null || true
  systemctl disable "$(bguard_svc "${name}")" 2>/dev/null || true
  systemctl stop    "$(bcore_svc "${name}")" 2>/dev/null || true
  systemctl disable "$(bcore_svc "${name}")" 2>/dev/null || true
  ip link del "$(bmeta_get "${name}" IFACE)" 2>/dev/null || true
  rm -rf "$(bridge_idir "${name}")"
  systemctl daemon-reload
  good "Bridge link '${name}' deleted."
}

bridge_instance_speedtest() {
  install_speed_tool || return 1
  local name="$1" role self peer
  role="$(bmeta_get "${name}" ROLE)"
  self="$(bmeta_get "${name}" SELF_CORE)"
  peer="$(bmeta_get "${name}" PEER_CORE)"
  rule
  info "Speedtest for link '${name}' — run step 1 on exit, step 2 on entry (~30s apart)."
  rule
  printf '  %s1%s  This is the EXIT — start listener\n' "${ACC}" "${RST}"
  printf '  %s2%s  This is the ENTRY — run test\n' "${ACC}" "${RST}"
  local step; step="$(ask 'Step')"
  case "${step}" in
    1) info "Listening on ${self}:${PHORMAL_SPEED_PORT}…"
       iperf3 -s -B "${self}" -p "${PHORMAL_SPEED_PORT}" -1 || { fail "Speed listener failed."; return 1; } ;;
    2) warn "Step 1 must be running on the exit node first."
       local ready; ready="$(ask 'Exit listener running? (y/n)')"
       [[ "${ready}" =~ ^[Yy] ]] || { info "Cancelled."; return 0; }
       info "Testing to ${peer}:${PHORMAL_SPEED_PORT} for 10s…"
       iperf3 -c "${peer}" -p "${PHORMAL_SPEED_PORT}" -t 10 -f m \
         || { fail "Speedtest failed — is step 1 still running on the exit?"; return 1; } ;;
    *) fail "Invalid step." ;;
  esac
}

manage_bridge_instance_menu() {
  local name="$1"
  while :; do
    rule
    info "Manage link '${name}'  (${MUT}$(bmeta_get "${name}" ROLE) • core $(bcore_state "${name}")${RST})"
    rule
    printf '  %s1%s  Restart\n'                  "${ACC}" "${RST}"
    printf '  %s2%s  Stop\n'                     "${ACC}" "${RST}"
    printf '  %s3%s  Start\n'                    "${ACC}" "${RST}"
    printf '  %s4%s  Ping peer / status\n'       "${ACC}" "${RST}"
    printf '  %s5%s  Live log (Ctrl-C to exit)\n' "${ACC}" "${RST}"
    printf '  %s6%s  Edit ports (entry only)\n'  "${ACC}" "${RST}"
    printf '  %s7%s  Change peer IPv4\n'         "${ACC}" "${RST}"
    printf '  %s8%s  Change MTU\n'               "${ACC}" "${RST}"
    printf '  %s9%s  Change bridge key\n'        "${ACC}" "${RST}"
    printf ' %s10%s  Speedtest\n'                "${ACC}" "${RST}"
    printf ' %s11%s  Edit raw meta\n'            "${ACC}" "${RST}"
    printf ' %s12%s  Delete link\n'              "${ACC}" "${RST}"
    printf '  %s0%s  Back\n\n'                   "${ACC}" "${RST}"
    local c; c="$(ask 'Select')"; echo
    case "${c}" in
      1) bridge_start_instance "${name}" || true ;;
      2) systemctl stop "$(bcore_svc "${name}")" "$(bguard_svc "${name}")" "$(bfwd_svc "${name}")" 2>/dev/null && good "Stopped." || good "Stopped." ;;
      3) bridge_start_instance "${name}" || true ;;
      4) bridge_ping_peer "${name}" || true ;;
      5) journalctl -u "$(bcore_svc "${name}")" -u "$(bfwd_svc "${name}")" -f --no-pager 2>/dev/null || true ;;
      6) bridge_instance_edit_ports "${name}" || true ;;
      7) bridge_instance_change_peer "${name}" || true ;;
      8) bridge_instance_change_mtu "${name}" || true ;;
      9) bridge_instance_change_key "${name}" || true ;;
      10) bridge_instance_speedtest "${name}" || true ;;
      11) bridge_instance_edit_raw "${name}" || true ;;
      12) bridge_instance_delete "${name}"; break ;;
      0) break ;;
      *) fail "Invalid selection." ;;
    esac
    echo
  done
}

manage_bridge_menu() {
  while :; do
    bridge_list
    printf '  %s1%s  Manage a link\n'    "${ACC}" "${RST}"
    printf '  %s2%s  Add exit link\n'    "${ACC}" "${RST}"
    printf '  %s3%s  Add entry link\n'   "${ACC}" "${RST}"
    printf '  %s4%s  Restart ALL links\n' "${ACC}" "${RST}"
    printf '  %s0%s  Back\n\n'           "${ACC}" "${RST}"
    local c; c="$(ask 'Select')"; echo
    case "${c}" in
      1) local n; n="$(bridge_choose_instance)"; [[ -n "${n}" ]] && manage_bridge_instance_menu "${n}" ;;
      2) create_bridge_exit || true ;;
      3) create_bridge_entry || true ;;
      4) local n; while read -r n; do [[ -n "${n}" ]] && bridge_start_instance "${n}" || true; done < <(bridge_instances) ;;
      0) break ;;
      *) fail "Invalid selection." ;;
    esac
    echo
  done
}

# ==============================================================================
#  PHORMAL RELAY  (multi-instance)
#
#  Each tunnel is a named instance living in:   /etc/phormal/relay/<name>/
#    - meta.conf      key=val metadata for this tunnel
#    - config.yaml    hysteria config for this tunnel
#  Service per tunnel: phormal-relay@<name>.service  (systemd template unit)
#  One server (exit/kharej) instance can serve many entry (iran) instances.
#  One box can host many instances at once (e.g. entry to 3 different exits).
# ==============================================================================
readonly RELAY_DIR="${PHORMAL_HOME}/relay"
readonly RELAY_TLS_DIR="${PHORMAL_HOME}/tls"
readonly RELAY_TEMPLATE_UNIT="/etc/systemd/system/phormal-relay@.service"
readonly RELAY_RUN="/usr/local/bin/phormal-relay-run"

shopt -s nullglob

# ------------------------------------------------------------------------------
#  Engine install / TLS / buffers
# ------------------------------------------------------------------------------
install_relay_engine() {
  if [[ -x "${RELAY_BIN}" ]] && "${RELAY_BIN}" version >/dev/null 2>&1; then
    good "Phormal Relay engine present."
    return 0
  fi
  choose_binary_source || true
  info "Installing Phormal Relay engine…"

  if [[ "${BINARY_SOURCE}" == "manual" ]]; then
    install_manual_relay || return 1
    return 0
  fi

  apt_install_quiet curl wget ca-certificates openssl libcap2-bin

  local arch urls=()
  arch="$(machine_arch)" || { fail "Unsupported architecture: $(uname -m)"; return 1; }

  if [[ "${BINARY_SOURCE}" == "mirror" ]]; then
    local mirror
    if mirror="$(mirror_relay_url "${arch}" 2>/dev/null || true)" && [[ -n "${mirror}" ]]; then
      urls+=("${mirror}")
    fi
    urls+=( "$(hysteria_upstream_url "${arch}")" )
    if fetch_binary "${RELAY_BIN}" verify_relay_tmp \
        "Phormal Relay engine" "${urls[@]}"; then
      setcap cap_net_bind_service,cap_net_admin=+ep "${RELAY_BIN}" 2>/dev/null || true
      return 0
    fi
  elif [[ "${BINARY_SOURCE}" == "github" ]]; then
    urls+=( "$(hysteria_upstream_url "${arch}")" )
    if fetch_binary "${RELAY_BIN}" verify_relay_tmp \
        "Phormal Relay engine" "${urls[@]}"; then
      setcap cap_net_bind_service,cap_net_admin=+ep "${RELAY_BIN}" 2>/dev/null || true
      return 0
    fi
  fi

  install_local_binary "${RELAY_BIN}" || return 1
  setcap cap_net_bind_service,cap_net_admin=+ep "${RELAY_BIN}" 2>/dev/null || true
  "${RELAY_BIN}" version >/dev/null 2>&1 || { fail "Binary is not runnable."; return 1; }
  good "Phormal Relay engine installed."
}

gen_relay_tls() {
  mkdir -p "${RELAY_TLS_DIR}"
  local cert="${RELAY_TLS_DIR}/cert.crt" key="${RELAY_TLS_DIR}/cert.key"
  [[ -f "${cert}" && -f "${key}" ]] && return 0
  info "Generating self-signed TLS certificate…"
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "${key}" -out "${cert}" -days 3650 -subj "/CN=phormal.local" 2>/dev/null
  chmod 600 "${key}"
  good "TLS certificate ready."
}

enable_relay_buffers() {
  info "Tuning network buffers…"
  cat > "${RELAY_SYSCTL}" <<'EOF'
# Phormal relay — large UDP buffers for high-throughput links
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 8388608
net.core.wmem_default = 8388608
net.core.netdev_max_backlog = 250000
EOF
  sysctl --system >/dev/null 2>&1 || true
  good "Network buffer tuning applied."
}

port_open_tcp() { ss -H -tln 2>/dev/null | grep -qE ":${1}([^0-9]|$)"; }
port_open_udp() { ss -H -uln 2>/dev/null | grep -qE ":${1}([^0-9]|$)"; }

relay_engine_block() {
  cat <<'EOF'
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s
  disablePathMTUDiscovery: false
EOF
}

# ------------------------------------------------------------------------------
#  Instance registry helpers
# ------------------------------------------------------------------------------
relay_idir() { printf '%s/%s' "${RELAY_DIR}" "$1"; }

# Sanitize a tunnel name to a safe systemd-instance token: [a-z0-9_-]
relay_sanitize_name() {
  local n="$1"
  n="$(printf '%s' "${n}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' | tr -s '-')"
  n="${n##-}"; n="${n%%-}"
  printf '%s' "${n:-tunnel}"
}

# List instance names (dirs that contain meta.conf)
relay_instances() {
  local d
  for d in "${RELAY_DIR}"/*/; do
    [[ -f "${d}meta.conf" ]] || continue
    basename "${d}"
  done
}

relay_count() { relay_instances | grep -c . || true; }

imeta_get() {
  local name="$1" key="$2" f
  f="$(relay_idir "${name}")/meta.conf"
  [[ -f "${f}" ]] && grep -E "^${key}=" "${f}" | head -n1 | cut -d= -f2- || true
}

imeta_set() {
  local name="$1" key="$2" val="$3" f
  f="$(relay_idir "${name}")/meta.conf"
  mkdir -p "$(dirname "${f}")"; touch "${f}"
  if grep -qE "^${key}=" "${f}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${f}"
  else
    echo "${key}=${val}" >> "${f}"
  fi
}

readonly CDN_TMPL="/etc/systemd/system/phormal-cdn@.service"
readonly CDN_RUN="/usr/local/bin/phormal-cdn-run"

cdn_svc()       { printf 'phormal-cdn@%s.service' "$1"; }
cdn_svc_state() {
  local st; st="$(systemctl is-active "$(cdn_svc "$1")" 2>/dev/null || true)"
  printf '%s' "${st:-unknown}"
}

# gost is the same binary used by Bridge publishers; for CDN we reuse it and the
# same source selection (mirror / github / manual), just with CDN wording.
install_cdn_engine() {
  if [[ -x "${FWD_BIN}" ]] && "${FWD_BIN}" -V >/dev/null 2>&1; then
    good "Phormal CDN engine present."
    return 0
  fi
  info "Downloading Phormal CDN engine…"
  install_engine
}

cdn_install_runtime() {
  cat > "${CDN_RUN}" <<EOF
#!/usr/bin/env bash
# Phormal CDN front — raw TCP from the CDN port to the local relay entry port.
# The WebSocket layer is terminated on the EXIT (Xray ws inbound), so here we
# just pass bytes through transparently.
set -e
name="\$1"
dir="${RELAY_DIR}/\${name}"
[[ -f "\${dir}/meta.conf" ]] || { echo "no such tunnel: \${name}" >&2; exit 1; }
get(){ grep -E "^\$1=" "\${dir}/meta.conf" | head -n1 | cut -d= -f2-; }
LISTEN="\$(get CDN_LISTEN)"; LISTEN="\${LISTEN:-80}"
PORT="\$(get CDN_PORT)"
[[ -n "\${PORT}" ]] || { echo "CDN_PORT empty in meta.conf" >&2; exit 1; }
exec ${FWD_BIN} -L="tcp://:\${LISTEN}/127.0.0.1:\${PORT}"
EOF
  chmod +x "${CDN_RUN}"

  cat > "${CDN_TMPL}" <<EOF
[Unit]
Description=Phormal CDN front (%i)
After=network-online.target phormal-relay@%i.service
Wants=network-online.target

[Service]
Type=simple
Environment="GOST_LOGGER_LEVEL=fatal"
ExecStart=${CDN_RUN} %i
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

relay_cdn_remove() {
  local name="$1"
  systemctl stop    "$(cdn_svc "${name}")" 2>/dev/null || true
  systemctl disable "$(cdn_svc "${name}")" 2>/dev/null || true
  systemctl daemon-reload
  good "CDN front removed for tunnel '${name}'."
}

# Set up the gost-based CDN front for an entry tunnel.
#   $1 name   $2 listen-port (public, from CDN)   $3 target-port (local relay entry)
relay_cdn_setup() {
  local name="$1" listen="$2" port="$3"
  install_cdn_engine || { fail "CDN engine unavailable — CDN front skipped."; return 1; }

  if ss -tln 2>/dev/null | grep -qE ":${listen}\b"; then
    warn "Port ${listen} already in use — the CDN front may fail to bind."
  fi

  imeta_set "${name}" CDN_LISTEN "${listen}"
  imeta_set "${name}" CDN_PORT "${port}"
  cdn_install_runtime

  systemctl enable "$(cdn_svc "${name}")" >/dev/null 2>&1
  systemctl restart "$(cdn_svc "${name}")"
  sleep 1
  if systemctl is-active "$(cdn_svc "${name}")" >/dev/null 2>&1; then
    good "CDN front live: port ${listen} → 127.0.0.1:${port}"
    return 0
  fi
  fail "CDN front failed to start. Recent log:"
  journalctl -u "$(cdn_svc "${name}")" -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
  return 1
}


relay_svc() { printf 'phormal-relay@%s.service' "$1"; }

systemd_is_active_clean() {
  local unit="$1" st
  st="$(systemctl is-active "${unit}" 2>/dev/null || true)"
  printf '%s' "${st:-unknown}"
}

relay_svc_state() { systemd_is_active_clean "$(relay_svc "$1")"; }
relay_svc_is_active() { [[ "$(relay_svc_state "$1")" == "active" ]]; }

# ------------------------------------------------------------------------------
#  systemd template + run wrapper (installed once)
# ------------------------------------------------------------------------------
relay_install_runtime() {
  cat > "${RELAY_RUN}" <<EOF
#!/usr/bin/env bash
# Phormal relay launcher — decides server/client mode from the instance meta.
set -e
name="\$1"
dir="${RELAY_DIR}/\${name}"
[[ -f "\${dir}/meta.conf" ]] || { echo "no such relay instance: \${name}" >&2; exit 1; }
# shellcheck disable=SC1090
ROLE="\$(grep -E '^ROLE=' "\${dir}/meta.conf" | head -n1 | cut -d= -f2-)"
mode="server"; [[ "\${ROLE}" == "entry" ]] && mode="client"
exec ${RELAY_BIN} "\${mode}" -c "\${dir}/config.yaml"
EOF
  chmod +x "${RELAY_RUN}"

  cat > "${RELAY_TEMPLATE_UNIT}" <<EOF
[Unit]
Description=Phormal relay tunnel (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# small delay so cloud routing / public IP is ready before the QUIC handshake
ExecStartPre=/bin/sleep 2
ExecStart=${RELAY_RUN} %i
Restart=always
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

relay_start_instance() {
  local name="$1" svc; svc="$(relay_svc "${name}")"
  systemctl daemon-reload
  systemctl enable "${svc}" >/dev/null 2>&1
  systemctl restart "${svc}"
  sleep 1
  if systemctl is-active "${svc}" >/dev/null 2>&1; then
    good "Tunnel '${name}' is active."
    return 0
  fi
  fail "Tunnel '${name}' failed to start. Recent log:"
  journalctl -u "${svc}" -n 12 --no-pager 2>/dev/null | sed 's/^/    /'
  return 1
}

# ------------------------------------------------------------------------------
#  Config writers (per instance)
# ------------------------------------------------------------------------------
# Exit / server config. One server serves any number of entry clients.
write_instance_exit_config() {
  local name="$1" dir; dir="$(relay_idir "${name}")"
  mkdir -p "${dir}"
  local listen auth obfs up down
  listen="$(imeta_get "${name}" LISTEN)"; listen="${listen:-443}"
  auth="$(imeta_get "${name}" AUTH)"
  obfs="$(imeta_get "${name}" OBFS)"
  up="$(imeta_get "${name}" UP_MBPS)";   up="${up:-50}"
  down="$(imeta_get "${name}" DOWN_MBPS)"; down="${down:-100}"

  {
    echo "listen: :${listen}"
    echo ""
    echo "tls:"
    echo "  cert: ${RELAY_TLS_DIR}/cert.crt"
    echo "  key: ${RELAY_TLS_DIR}/cert.key"
    echo ""
    echo "auth:"
    echo "  type: password"
    echo "  password: ${auth}"
    echo ""
    echo "obfs:"
    echo "  type: salamander"
    echo "  salamander:"
    echo "    password: ${obfs}"
    echo ""
    echo "bandwidth:"
    echo "  up: ${up} mbps"
    echo "  down: ${down} mbps"
    echo ""
    relay_engine_block
  } > "${dir}/config.yaml"
}

# Entry / client config. NOTE: no 'lazy' — the client connects eagerly and keeps
# the tunnel warm with keepalive, so it no longer needs a manual restart to come
# up after first traffic. fastOpen shaves a round trip on connect.
write_instance_entry_config() {
  local name="$1" dir; dir="$(relay_idir "${name}")"
  mkdir -p "${dir}"
  local server_ip listen ports hop_interval auth obfs up down
  server_ip="$(imeta_get "${name}" REMOTE_V4)"
  listen="$(imeta_get "${name}" LISTEN)"; listen="${listen:-443}"
  ports="$(imeta_get "${name}" PORTS)"
  hop_interval="$(imeta_get "${name}" HOP_INTERVAL)"; hop_interval="${hop_interval:-30s}"
  auth="$(imeta_get "${name}" AUTH)"
  obfs="$(imeta_get "${name}" OBFS)"
  up="$(imeta_get "${name}" UP_MBPS)";   up="${up:-50}"
  down="$(imeta_get "${name}" DOWN_MBPS)"; down="${down:-100}"

  {
    echo "server: ${server_ip}:${listen}"
    echo ""
    echo "auth: ${auth}"
    echo ""
    echo "tls:"
    echo "  insecure: true"
    echo ""
    echo "obfs:"
    echo "  type: salamander"
    echo "  salamander:"
    echo "    password: ${obfs}"
    echo ""
    echo "bandwidth:"
    echo "  up: ${up} mbps"
    echo "  down: ${down} mbps"
    echo ""
    relay_engine_block
    echo ""
    echo "fastOpen: true"
    if [[ "${listen}" == *-* ]]; then
      echo ""
      echo "transport:"
      echo "  type: udp"
      echo "  udp:"
      echo "    hopInterval: ${hop_interval}"
    fi
    echo ""
    echo "tcpForwarding:"
    local p
    IFS=',' read -ra parr <<< "${ports}"
    for p in "${parr[@]}"; do
      [[ -n "${p}" ]] || continue
      echo "  - listen: :${p}"
      echo "    remote: 127.0.0.1:${p}"
    done
    echo ""
    echo "udpForwarding:"
    for p in "${parr[@]}"; do
      [[ -n "${p}" ]] || continue
      echo "  - listen: :${p}"
      echo "    remote: 127.0.0.1:${p}"
      echo "    timeout: 60s"
    done
  } > "${dir}/config.yaml"
}

# Rebuild whichever config matches the instance role, then (re)start it.
relay_rebuild_instance() {
  local name="$1" role; role="$(imeta_get "${name}" ROLE)"
  if [[ "${role}" == "exit" ]]; then
    write_instance_exit_config "${name}"
  else
    write_instance_entry_config "${name}"
  fi
  relay_start_instance "${name}"
}

# ------------------------------------------------------------------------------
#  Shared prompts (write into the chosen instance's meta)
# ------------------------------------------------------------------------------
prompt_credentials_into() {
  local name="$1" cur_auth cur_obfs sug_auth sug_obfs
  cur_auth="$(imeta_get "${name}" AUTH)"
  cur_obfs="$(imeta_get "${name}" OBFS)"
  sug_auth="$(rand_secret)"; sug_obfs="$(rand_secret)"

  if [[ -n "${cur_auth}" ]]; then
    warn "Saved credentials for '${name}' (must match the other node exactly):"
    info "  Auth : ${BOLD}${cur_auth}${RST}"
    info "  Obfs : ${BOLD}${cur_obfs}${RST}"
    local keep; keep="$(ask 'Keep these? (y/n)')"
    [[ "${keep}" == "y" ]] && return 0
  fi
  info "Auth password. Suggested: ${BOLD}${sug_auth}${RST}"
  local a; a="$(ask 'Auth password [Enter for suggested]')"; a="${a:-${sug_auth}}"
  info "Obfuscation password. Suggested: ${BOLD}${sug_obfs}${RST}"
  local o; o="$(ask 'Obfuscation password [Enter for suggested]')"; o="${o:-${sug_obfs}}"
  imeta_set "${name}" AUTH "${a}"
  imeta_set "${name}" OBFS "${o}"
}

prompt_bandwidth_into() {
  local name="$1" du dd
  du="$(imeta_get "${name}" UP_MBPS)";   du="${du:-50}"
  dd="$(imeta_get "${name}" DOWN_MBPS)"; dd="${dd:-100}"
  info "Real link bandwidth between the two nodes (rough is fine)."
  local u d
  u="$(ask "Upload mbps [${du}]")";   u="${u:-${du}}"
  d="$(ask "Download mbps [${dd}]")"; d="${d:-${dd}}"
  imeta_set "${name}" UP_MBPS "${u}"
  imeta_set "${name}" DOWN_MBPS "${d}"
}

# ------------------------------------------------------------------------------
#  Create instances
# ------------------------------------------------------------------------------
relay_pick_name() {
  local raw name
  raw="$(ask 'Tunnel name (e.g. iran1, kharej-de)')"
  name="$(relay_sanitize_name "${raw}")"
  if [[ -f "$(relay_idir "${name}")/meta.conf" ]]; then
    warn "A tunnel named '${name}' already exists." >&2
    printf '%s' ""
    return 1
  fi
  printf '%s' "${name}"
}

create_exit_tunnel() {
  rule
  info "Phormal Relay — new EXIT tunnel (this server = kharej)"
  info "Run your real service (Xray/3x-ui) locally; entries point users at it."
  rule

  install_relay_engine || return 1
  gen_relay_tls
  enable_relay_buffers
  apply_tuning fq
  relay_install_runtime

  local name; name="$(relay_pick_name)" || return 1
  [[ -z "${name}" ]] && { fail "Invalid name."; return 1; }
  mkdir -p "$(relay_idir "${name}")"
  imeta_set "${name}" ROLE exit

  prompt_credentials_into "${name}"
  prompt_bandwidth_into "${name}"

  local listen hop
  info "Link port between nodes (NOT a user port). e.g. 8443"
  listen="$(ask 'Link port [443]')"; listen="${listen:-443}"
  hop="$(ask 'Enable port hopping? (y/n) [n]')"
  if [[ "${hop}" == "y" ]]; then
    local range; range="$(ask 'Port range (e.g. 20000-50000)')"
    [[ "${range}" =~ ^[0-9]+-[0-9]+$ ]] || { warn "Invalid range — using 20000-50000."; range="20000-50000"; }
    listen="${range}"
    local hi; hi="$(ask 'Hop interval [30s]')"; imeta_set "${name}" HOP_INTERVAL "${hi:-30s}"
  fi
  imeta_set "${name}" LISTEN "${listen}"

  write_instance_exit_config "${name}"
  relay_start_instance "${name}" || return 1

  echo
  good "Exit tunnel '${name}' live."
  info "  Link port  : ${listen}  ${MUT}(entries must use this)${RST}"
  info "  Auth       : $(imeta_get "${name}" AUTH)"
  info "  Obfs       : $(imeta_get "${name}" OBFS)"
  info "  Bandwidth  : ↑$(imeta_get "${name}" UP_MBPS) / ↓$(imeta_get "${name}" DOWN_MBPS) mbps"
  warn "Open ${listen%-*}/udp in the firewall, and give link port + both passwords to every entry node."
  warn "Each Iran (entry) server can connect to this same exit with its own ports."
}

create_entry_tunnel() {
  rule
  info "Phormal Relay — new ENTRY tunnel (this server = iran)"
  info "Listens on user ports here, forwards to the service on the exit node."
  rule

  install_relay_engine || return 1
  enable_relay_buffers
  apply_tuning fq
  relay_install_runtime

  local name; name="$(relay_pick_name)" || return 1
  [[ -z "${name}" ]] && { fail "Invalid name."; return 1; }
  mkdir -p "$(relay_idir "${name}")"
  imeta_set "${name}" ROLE entry

  local server_ip
  server_ip="$(ask 'Exit (kharej) node public IPv4')"
  valid_ipv4 "${server_ip}" || { fail "Invalid IPv4."; rm -rf "$(relay_idir "${name}")"; return 1; }
  imeta_set "${name}" REMOTE_V4 "${server_ip}"

  prompt_credentials_into "${name}"
  prompt_bandwidth_into "${name}"

  local listen
  info "Link port — must match the exit exactly (single port, or a range for hopping)."
  listen="$(ask 'Link port or range [443]')"; listen="${listen:-443}"
  imeta_set "${name}" LISTEN "${listen}"
  [[ "${listen}" == *-* ]] && { local hi; hi="$(ask 'Hop interval [30s]')"; imeta_set "${name}" HOP_INTERVAL "${hi:-30s}"; }

  local ports; ports="$(gather_ports)"
  [[ -z "${ports}" ]] && { fail "No valid ports provided."; rm -rf "$(relay_idir "${name}")"; return 1; }
  imeta_set "${name}" PORTS "${ports}"

  local cdn_ans cdn_domain cdn_path cdn_listen cdn_port fp
  cdn_ans="$(ask 'Put this entry behind a CDN (ArvanCloud) over port 80 + WebSocket? (y/n) [n]')"
  cdn_ans="${cdn_ans:-n}"
  if [[ "${cdn_ans}" =~ ^[Yy] ]]; then
    cdn_domain="$(ask 'CDN domain (proxied through Arvan to this server)')"
    if [[ -z "${cdn_domain}" ]]; then
      fail "CDN domain is required."
      rm -rf "$(relay_idir "${name}")"
      return 1
    fi
    cdn_path="$(ask 'WebSocket path (must match Xray inbound) [/phormalws]')"
    cdn_path="${cdn_path:-/phormalws}"
    [[ "${cdn_path}" != /* ]] && cdn_path="/${cdn_path}"
    cdn_listen="$(ask 'CDN listen port on this server (Arvan sends here) [80]')"
    cdn_listen="${cdn_listen:-80}"
    [[ "${cdn_listen}" =~ ^[0-9]+$ ]] || { fail "Invalid listen port."; rm -rf "$(relay_idir "${name}")"; return 1; }
    fp="$(first_port_from_list "${ports}" || true)"
    cdn_port="$(ask "Local entry port to forward to [${fp:-first user port}]")"
    cdn_port="${cdn_port:-${fp}}"
    [[ "${cdn_port}" =~ ^[0-9]+$ ]] || { fail "Invalid local port."; rm -rf "$(relay_idir "${name}")"; return 1; }
    imeta_set "${name}" CDN_ENABLED "1"
    imeta_set "${name}" CDN_DOMAIN "${cdn_domain}"
    imeta_set "${name}" CDN_PATH "${cdn_path}"
    relay_cdn_setup "${name}" "${cdn_listen}" "${cdn_port}" || \
      warn "CDN front setup failed — tunnel will still listen on local ports."
  else
    imeta_set "${name}" CDN_ENABLED "0"
  fi

  write_instance_entry_config "${name}"
  relay_start_instance "${name}" || return 1

  echo
  good "Entry tunnel '${name}' live — ports: ${ports}"
  info "  Link target : ${server_ip}:${listen}"
  good "Point users at THIS server's public IP on those ports (never the exit IP)."
  if [[ "$(imeta_get "${name}" CDN_ENABLED)" == "1" ]]; then
    info "  CDN front   : ${MUT}port $(imeta_get "${name}" CDN_LISTEN) → 127.0.0.1:$(imeta_get "${name}" CDN_PORT)${RST}"
    info "  CDN client  : ${MUT}host $(imeta_get "${name}" CDN_DOMAIN), port $(imeta_get "${name}" CDN_LISTEN), ws path $(imeta_get "${name}" CDN_PATH)${RST}"
    warn "If Arvan later blocks WebSocket, point clients at this server's IP:$(imeta_get "${name}" CDN_PORT) — the Relay tunnel keeps working without the CDN front."
  fi
  echo
  diagnose_instance "${name}"
}

# ------------------------------------------------------------------------------
#  Diagnostics for one instance
# ------------------------------------------------------------------------------
diagnose_instance() {
  local name="$1" dir role listen remote svc
  dir="$(relay_idir "${name}")"
  role="$(imeta_get "${name}" ROLE)"
  listen="$(imeta_get "${name}" LISTEN)"
  remote="$(imeta_get "${name}" REMOTE_V4)"
  svc="$(relay_svc "${name}")"

  rule
  info "Diagnostics — tunnel '${name}' (${role})"
  rule
  if relay_svc_is_active "${name}"; then
    good "service active"
  else
    fail "service $(relay_svc_state "${name}")"
    journalctl -u "${svc}" -n 12 --no-pager 2>/dev/null | sed 's/^/    /'
  fi

  if [[ "${role}" == "entry" ]]; then
    local ports p
    ports="$(imeta_get "${name}" PORTS)"
    IFS=',' read -ra parr <<< "${ports}"
    for p in "${parr[@]}"; do
      [[ -n "${p}" ]] || continue
      if port_open_tcp "${p}"; then good "TCP :${p} listening (users connect here)"; else fail "TCP :${p} NOT listening"; fi
    done
    info "Link target: ${remote}:${listen%-*}"
    if journalctl -u "${svc}" --since '3 min ago' 2>/dev/null | grep -q 'forwarding error'; then
      warn "Recent forwarding errors — check link port + passwords match the exit, and that the exit's service is up."
    fi
    if [[ "$(imeta_get "${name}" CDN_ENABLED)" == "1" ]]; then
      local cl; cl="$(imeta_get "${name}" CDN_LISTEN)"; cl="${cl:-80}"
      info "CDN domain : $(imeta_get "${name}" CDN_DOMAIN)"
      info "CDN path   : $(imeta_get "${name}" CDN_PATH)  (terminated on the exit's Xray ws inbound)"
      info "CDN front  : port ${cl} → 127.0.0.1:$(imeta_get "${name}" CDN_PORT)"
      if [[ "$(cdn_svc_state "${name}")" == "active" ]]; then
        good "CDN front service active"
      else
        warn "CDN front service $(cdn_svc_state "${name}")"
        journalctl -u "$(cdn_svc "${name}")" -n 8 --no-pager 2>/dev/null | sed 's/^/    /'
      fi
      if ss -tln 2>/dev/null | grep -qE ":${cl}\b"; then
        good "port ${cl} listening"
      else
        warn "port ${cl} not listening"
      fi
    fi
  elif [[ "${role}" == "exit" ]]; then
    local hp="${listen%-*}"
    if port_open_udp "${hp}"; then good "Link UDP :${hp} up"; else warn "Link UDP :${hp} not confirmed yet"; fi
    info "Auth : $(imeta_get "${name}" AUTH)"
    info "Obfs : $(imeta_get "${name}" OBFS)"
  fi
  echo
  info "Recent log:"
  journalctl -u "${svc}" -n 8 --no-pager 2>/dev/null | sed 's/^/    /' || true
  rule
}

# ------------------------------------------------------------------------------
#  Per-instance management
# ------------------------------------------------------------------------------
relay_list() {
  rule
  info "Phormal Relay — tunnels"
  rule
  local n any=0
  printf '    %-16s %-6s %-22s %-10s %s\n' "NAME" "ROLE" "TARGET/LINK" "STATE" "PORTS"
  while read -r n; do
    [[ -n "${n}" ]] || continue
    any=1
    local role listen remote state ports tgt
    role="$(imeta_get "${n}" ROLE)"
    listen="$(imeta_get "${n}" LISTEN)"
    remote="$(imeta_get "${n}" REMOTE_V4)"
    ports="$(imeta_get "${n}" PORTS)"
    state="$(relay_svc_state "${n}")"
    if [[ "${role}" == "entry" ]]; then tgt="${remote}:${listen}"; else tgt=":${listen}"; fi
    printf '    %-16s %-6s %-22s %-10s %s\n' "${n}" "${role}" "${tgt}" "${state}" "${ports:--}"
  done < <(relay_instances)
  [[ ${any} -eq 0 ]] && warn "no tunnels configured yet"
  rule
}

# Show a numbered picker; echo the chosen instance name (or empty).
relay_choose_instance() {
  local names=() n i
  while read -r n; do [[ -n "${n}" ]] && names+=("${n}"); done < <(relay_instances)
  if [[ ${#names[@]} -eq 0 ]]; then warn "No tunnels configured." >&2; printf '%s' ""; return 1; fi
  {
    for i in "${!names[@]}"; do
      printf '  %s%s%s  %s (%s, %s)\n' "${ACC}" "$((i+1))" "${RST}" \
        "${names[i]}" "$(imeta_get "${names[i]}" ROLE)" "$(relay_svc_state "${names[i]}")"
    done
  } >&2
  local sel; sel="$(ask 'Tunnel number')"
  [[ "${sel}" =~ ^[0-9]+$ ]] || { printf '%s' ""; return 1; }
  local idx=$((sel-1))
  [[ ${idx} -ge 0 && ${idx} -lt ${#names[@]} ]] || { printf '%s' ""; return 1; }
  printf '%s' "${names[idx]}"
}

instance_edit_ports() {
  local name="$1" role ports
  role="$(imeta_get "${name}" ROLE)"
  [[ "${role}" == "entry" ]] || { fail "Ports are only configured on entry tunnels."; return 1; }
  ports="$(imeta_get "${name}" PORTS)"
  info "Current ports: ${ports:-none}"
  printf '  %s1%s  Add port   %s2%s  Remove port   %s3%s  Replace all\n' \
    "${ACC}" "${RST}" "${ACC}" "${RST}" "${ACC}" "${RST}"
  local c; c="$(ask 'Action')"
  case "${c}" in
    1) local p; p="$(ask 'Port to add')"; [[ "${p}" =~ ^[0-9]+$ ]] || { fail "Invalid port."; return 1; }
       ports="$(merge_port_list "${ports}" "${p}")" ;;
    2) local p; p="$(ask 'Port to remove')"
       ports="$(remove_port_from_list "${ports}" "${p}")"
       [[ -z "${ports}" ]] && { fail "Cannot remove the last port."; return 1; } ;;
    3) ports="$(gather_ports)"; [[ -z "${ports}" ]] && { fail "No valid ports."; return 1; } ;;
    *) fail "Invalid action."; return 1 ;;
  esac
  imeta_set "${name}" PORTS "${ports}"
  write_instance_entry_config "${name}"
  relay_start_instance "${name}"
  good "Ports for '${name}' now: ${ports}"
}

instance_change_exit_ip() {
  local name="$1" role ip
  role="$(imeta_get "${name}" ROLE)"
  [[ "${role}" == "entry" ]] || { fail "Exit IP only applies to entry tunnels."; return 1; }
  ip="$(ask "Exit node IP [$(imeta_get "${name}" REMOTE_V4)]")"
  [[ -z "${ip}" ]] && return 0
  valid_ipv4 "${ip}" || { fail "Invalid IPv4."; return 1; }
  imeta_set "${name}" REMOTE_V4 "${ip}"
  write_instance_entry_config "${name}"
  relay_start_instance "${name}"
  good "Exit IP for '${name}' updated to ${ip}."
}

instance_change_linkport() {
  local name="$1" role lp
  role="$(imeta_get "${name}" ROLE)"
  lp="$(ask "Link port or range [$(imeta_get "${name}" LISTEN)]")"
  [[ -z "${lp}" ]] && return 0
  imeta_set "${name}" LISTEN "${lp}"
  [[ "${lp}" == *-* ]] && { local hi; hi="$(ask 'Hop interval [30s]')"; imeta_set "${name}" HOP_INTERVAL "${hi:-30s}"; }
  relay_rebuild_instance "${name}"
  [[ "${role}" == "exit" ]] && warn "Open ${lp%-*}/udp in the firewall and update every entry to this link port."
  good "Link port for '${name}' updated."
}

instance_edit_creds() {
  local name="$1"
  prompt_credentials_into "${name}"
  prompt_bandwidth_into "${name}"
  relay_rebuild_instance "${name}"
  good "Credentials/bandwidth for '${name}' reapplied."
  warn "These must match on the other node."
}

instance_edit_raw() {
  local name="$1" dir; dir="$(relay_idir "${name}")"
  info "  ${dir}/meta.conf"
  info "  ${dir}/config.yaml"
  local c; c="$(ask 'Edit Phormal Relay config now? (y/n)')"
  [[ "${c}" == "y" ]] && ${EDITOR:-nano} "${dir}/config.yaml"
  local r; r="$(ask 'Restart tunnel to apply? (y/n)')"
  [[ "${r}" == "y" ]] && relay_start_instance "${name}"
}

instance_delete() {
  local name="$1" svc; svc="$(relay_svc "${name}")"
  local c; c="$(ask "Delete tunnel '${name}' permanently? (y/n)")"
  [[ "${c}" != "y" ]] && { info "Cancelled."; return 0; }
  if [[ "$(imeta_get "${name}" CDN_ENABLED)" == "1" ]]; then
    relay_cdn_remove "${name}" || true
  fi
  systemctl stop "${svc}" 2>/dev/null || true
  systemctl disable "${svc}" 2>/dev/null || true
  rm -rf "$(relay_idir "${name}")"
  systemctl daemon-reload
  good "Tunnel '${name}' deleted."
}

manage_instance_menu() {
  local name="$1"
  while :; do
    rule
    info "Manage tunnel '${name}'  (${MUT}$(imeta_get "${name}" ROLE) • $(relay_svc_state "${name}")${RST})"
    rule
    printf '  %s1%s  Restart\n'                 "${ACC}" "${RST}"
    printf '  %s2%s  Stop\n'                    "${ACC}" "${RST}"
    printf '  %s3%s  Start\n'                   "${ACC}" "${RST}"
    printf '  %s4%s  Diagnostics\n'             "${ACC}" "${RST}"
    printf '  %s5%s  Live log (Ctrl-C to exit)\n' "${ACC}" "${RST}"
    printf '  %s6%s  Edit ports (entry only)\n' "${ACC}" "${RST}"
    printf '  %s7%s  Change exit IP (entry only)\n' "${ACC}" "${RST}"
    printf '  %s8%s  Change link port\n'        "${ACC}" "${RST}"
    printf '  %s9%s  Edit auth/obfs/bandwidth\n' "${ACC}" "${RST}"
    printf ' %s10%s  Edit raw config\n'         "${ACC}" "${RST}"
    printf ' %s11%s  Delete tunnel\n'           "${ACC}" "${RST}"
    printf '  %s0%s  Back\n\n'                  "${ACC}" "${RST}"
    local c; c="$(ask 'Select')"; echo
    case "${c}" in
      1) relay_start_instance "${name}" || true ;;
      2) systemctl stop "$(relay_svc "${name}")" 2>/dev/null && good "Stopped." || fail "Could not stop." ;;
      3) systemctl start "$(relay_svc "${name}")" 2>/dev/null && good "Started." || fail "Could not start." ;;
      4) diagnose_instance "${name}" ;;
      5) journalctl -u "$(relay_svc "${name}")" -f --no-pager 2>/dev/null || true ;;
      6) instance_edit_ports "${name}" || true ;;
      7) instance_change_exit_ip "${name}" || true ;;
      8) instance_change_linkport "${name}" || true ;;
      9) instance_edit_creds "${name}" || true ;;
      10) instance_edit_raw "${name}" || true ;;
      11) instance_delete "${name}"; break ;;
      0) break ;;
      *) fail "Invalid selection." ;;
    esac
    echo
  done
}

manage_relay_menu() {
  while :; do
    relay_list
    printf '  %s1%s  Manage a tunnel\n'   "${ACC}" "${RST}"
    printf '  %s2%s  Add exit tunnel\n'   "${ACC}" "${RST}"
    printf '  %s3%s  Add entry tunnel\n'  "${ACC}" "${RST}"
    printf '  %s4%s  Restart ALL tunnels\n' "${ACC}" "${RST}"
    printf '  %s0%s  Back\n\n'            "${ACC}" "${RST}"
    local c; c="$(ask 'Select')"; echo
    case "${c}" in
      1) local n; n="$(relay_choose_instance)"; [[ -n "${n}" ]] && manage_instance_menu "${n}" ;;
      2) create_exit_tunnel || true ;;
      3) create_entry_tunnel || true ;;
      4) local n; while read -r n; do [[ -n "${n}" ]] && relay_start_instance "${n}" || true; done < <(relay_instances) ;;
      0) break ;;
      *) fail "Invalid selection." ;;
    esac
    echo
  done
}

relay_speedtest() {
  install_speed_tool || return 1
  rule
  info "Phormal Relay — speedtest (per entry tunnel)"
  info "Order: run step 1 on the EXIT, then step 2 on the ENTRY (within ~30s)."
  rule
  printf '  %s1%s  Exit node — start listener\n' "${ACC}" "${RST}"
  printf '  %s2%s  Entry node — run test\n' "${ACC}" "${RST}"
  local step; step="$(ask 'Step')"
  case "${step}" in
    1)
      info "Listening on 127.0.0.1:${PHORMAL_SPEED_PORT} — waiting for entry…"
      iperf3 -s -B 127.0.0.1 -p "${PHORMAL_SPEED_PORT}" -1 || { fail "Speed listener failed."; return 1; }
      ;;
    2)
      local name; name="$(relay_choose_instance)"; [[ -z "${name}" ]] && return 1
      [[ "$(imeta_get "${name}" ROLE)" == "entry" ]] || { fail "Pick an ENTRY tunnel."; return 1; }
      warn "Step 1 must already be running on the exit node."
      local ready; ready="$(ask 'Exit listener running? (y/n)')"
      [[ "${ready}" =~ ^[Yy] ]] || { info "Cancelled."; return 0; }
      local ports; ports="$(imeta_get "${name}" PORTS)"
      if [[ ",${ports}," != *",${PHORMAL_SPEED_PORT},"* ]]; then
        info "Temporarily adding speed port ${PHORMAL_SPEED_PORT}…"
        imeta_set "${name}" PORTS "$(merge_port_list "${ports}" "${PHORMAL_SPEED_PORT}")"
        write_instance_entry_config "${name}"; relay_start_instance "${name}" || return 1
        sleep 3
      fi
      info "Testing through tunnel '${name}' for 10s…"
      iperf3 -c 127.0.0.1 -p "${PHORMAL_SPEED_PORT}" -t 10 -f m || { fail "Speedtest failed — is step 1 still running on the exit?"; return 1; }
      ;;
    *) fail "Invalid step." ;;
  esac
}

# ==============================================================================
#  Phormal Reverse — multi-instance (rathole server=entry, client=exit)
# ==============================================================================

rev_idir() { printf '%s/%s' "${REVERSE_DIR}" "$1"; }

reverse_instances() {
  local d
  for d in "${REVERSE_DIR}"/*/; do
    [[ -f "${d}meta.conf" ]] || continue
    basename "${d}"
  done
}

rmeta_get() {
  local name="$1" key="$2" f
  f="$(rev_idir "${name}")/meta.conf"
  [[ -f "${f}" ]] && grep -E "^${key}=" "${f}" | head -n1 | cut -d= -f2- || true
}

rmeta_set() {
  local name="$1" key="$2" val="$3" f
  f="$(rev_idir "${name}")/meta.conf"
  mkdir -p "$(dirname "${f}")"; touch "${f}"
  if grep -qE "^${key}=" "${f}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${f}"
  else
    echo "${key}=${val}" >> "${f}"
  fi
}

rev_svc()       { printf 'phormal-reverse@%s.service' "$1"; }
rev_svc_state() { systemd_is_active_clean "$(rev_svc "$1")"; }

reverse_pick_name() {
  local raw name
  raw="$(ask 'Tunnel name (e.g. iran1, kharej-de)')"
  name="$(relay_sanitize_name "${raw}")"
  if [[ -f "$(rev_idir "${name}")/meta.conf" ]]; then
    warn "A tunnel named '${name}' already exists." >&2
    printf '%s' ""
    return 1
  fi
  printf '%s' "${name}"
}

reverse_prompt_proto() {
  {
    printf '  %s1%s  tcp [default]\n' "${ACC}" "${RST}"
    printf '  %s2%s  udp\n' "${ACC}" "${RST}"
  } >&2
  local c; c="$(ask 'Transport [1]')"; c="${c:-1}"
  case "${c}" in
    2) printf 'udp' ;;
    *) printf 'tcp' ;;
  esac
}

reverse_prompt_nodelay() {
  local c; c="$(ask 'TCP nodelay? (y/n) [y]')"; c="${c:-y}"
  [[ "${c}" =~ ^[Yy] ]] && printf 'true' || printf 'false'
}

reverse_install_runtime() {
  cat > "${REVERSE_RUN}" <<EOF
#!/usr/bin/env bash
set -e
name="\$1"
dir="${REVERSE_DIR}/\${name}"
[[ -f "\${dir}/meta.conf" ]] || { echo "no such reverse tunnel: \${name}" >&2; exit 1; }
exec ${REVERSE_BIN} "\${dir}/config.toml"
EOF
  chmod +x "${REVERSE_RUN}"

  cat > "${REVERSE_TMPL}" <<EOF
[Unit]
Description=Phormal Reverse tunnel (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/sleep 2
ExecStart=${REVERSE_RUN} %i
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

reverse_start_instance() {
  local name="$1" svc; svc="$(rev_svc "${name}")"
  systemctl daemon-reload
  systemctl enable "${svc}" >/dev/null 2>&1
  systemctl restart "${svc}"
  sleep 1
  if systemctl is-active "${svc}" >/dev/null 2>&1; then
    good "Tunnel '${name}' is active."
    return 0
  fi
  fail "Tunnel '${name}' failed to start. Recent log:"
  journalctl -u "${svc}" -n 12 --no-pager 2>/dev/null | sed 's/^/    /'
  return 1
}

write_reverse_entry_config() {
  local name="$1" dir; dir="$(rev_idir "${name}")"
  mkdir -p "${dir}"
  local link_port token ports proto nodelay heartbeat p
  link_port="$(rmeta_get "${name}" LINK_PORT)"; link_port="${link_port:-443}"
  token="$(rmeta_get "${name}" TOKEN)"
  ports="$(rmeta_get "${name}" PORTS)"
  proto="$(reverse_proto_clean "$(rmeta_get "${name}" PROTO)")"
  nodelay="$(reverse_nodelay_clean "$(rmeta_get "${name}" NODELAY)")"
  heartbeat="$(sanitize_meta_val "$(rmeta_get "${name}" HEARTBEAT)")"; heartbeat="${heartbeat:-30}"

  {
    echo "[server]"
    echo "bind_addr = \"0.0.0.0:${link_port}\""
    echo "default_token = \"${token}\""
    echo "heartbeat_interval = ${heartbeat}"
    echo ""
    echo "[server.transport]"
    echo "type = \"tcp\""
    echo ""
    echo "[server.transport.tcp]"
    echo "nodelay = ${nodelay}"
    IFS=',' read -ra parr <<< "${ports}"
    for p in "${parr[@]}"; do
      [[ -n "${p}" ]] || continue
      echo ""
      echo "[server.services.${p}]"
      echo "type = \"${proto}\""
      echo "bind_addr = \"0.0.0.0:${p}\""
    done
  } > "${dir}/config.toml"
}

write_reverse_exit_config() {
  local name="$1" dir; dir="$(rev_idir "${name}")"
  mkdir -p "${dir}"
  local remote link_port token ports proto nodelay heartbeat local_host p
  remote="$(rmeta_get "${name}" REMOTE_V4)"
  link_port="$(rmeta_get "${name}" LINK_PORT)"; link_port="${link_port:-443}"
  token="$(rmeta_get "${name}" TOKEN)"
  ports="$(rmeta_get "${name}" PORTS)"
  proto="$(reverse_proto_clean "$(rmeta_get "${name}" PROTO)")"
  nodelay="$(reverse_nodelay_clean "$(rmeta_get "${name}" NODELAY)")"
  heartbeat="$(sanitize_meta_val "$(rmeta_get "${name}" HEARTBEAT)")"; heartbeat="${heartbeat:-30}"
  local_host="$(sanitize_meta_val "$(rmeta_get "${name}" LOCAL_HOST)")"; local_host="${local_host:-127.0.0.1}"

  {
    echo "[client]"
    echo "remote_addr = \"${remote}:${link_port}\""
    echo "default_token = \"${token}\""
    echo "heartbeat_timeout = ${heartbeat}"
    echo "retry_interval = 1"
    echo ""
    echo "[client.transport]"
    echo "type = \"tcp\""
    echo ""
    echo "[client.transport.tcp]"
    echo "nodelay = ${nodelay}"
    IFS=',' read -ra parr <<< "${ports}"
    for p in "${parr[@]}"; do
      [[ -n "${p}" ]] || continue
      echo ""
      echo "[client.services.${p}]"
      echo "type = \"${proto}\""
      echo "local_addr = \"${local_host}:${p}\""
    done
  } > "${dir}/config.toml"
}

reverse_rebuild_instance() {
  local name="$1" role; role="$(rmeta_get "${name}" ROLE)"
  if [[ "${role}" == "exit" ]]; then
    write_reverse_exit_config "${name}"
  else
    write_reverse_entry_config "${name}"
  fi
  reverse_start_instance "${name}"
}

create_reverse_entry() {
  rule
  info "Phormal Reverse — new ENTRY tunnel (this server = iran)"
  info "Listens on the link port and user ports; kharej dials in."
  rule

  install_reverse_engine || return 1
  apply_tuning fq
  reverse_install_runtime

  local name; name="$(reverse_pick_name)" || return 1
  [[ -z "${name}" ]] && { fail "Invalid name."; return 1; }
  mkdir -p "$(rev_idir "${name}")"
  rmeta_set "${name}" ROLE entry

  local link_port token proto nodelay heartbeat ports
  link_port="$(ask 'Link port [443]')"; link_port="${link_port:-443}"
  rmeta_set "${name}" LINK_PORT "${link_port}"

  local sug_token; sug_token="$(rand_secret)"
  info "Shared token (must match exit). Suggested: ${BOLD}${sug_token}${RST}"
  token="$(ask 'Token [Enter for suggested]')"; token="${token:-${sug_token}}"
  rmeta_set "${name}" TOKEN "${token}"

  proto="$(reverse_prompt_proto)"
  rmeta_set "${name}" PROTO "${proto}"
  nodelay="$(reverse_prompt_nodelay)"
  rmeta_set "${name}" NODELAY "${nodelay}"

  heartbeat="$(ask 'Heartbeat interval seconds [30]')"; heartbeat="${heartbeat:-30}"
  rmeta_set "${name}" HEARTBEAT "${heartbeat}"

  ports="$(gather_ports)"
  [[ -z "${ports}" ]] && { fail "No valid ports provided."; rm -rf "$(rev_idir "${name}")"; return 1; }
  rmeta_set "${name}" PORTS "${ports}"

  write_reverse_entry_config "${name}"
  reverse_start_instance "${name}" || return 1

  echo
  good "Entry tunnel '${name}' live — ports: ${ports}"
  info "  Link port : ${link_port}"
  good "Point users at THIS server's public IP on those ports."
  warn "On the kharej node create a Reverse exit to this server's IP with the SAME link port, token, and ports."
}

create_reverse_exit() {
  rule
  info "Phormal Reverse — new EXIT tunnel (this server = kharej)"
  info "Dials into Iran and forwards to local services (Xray/3x-ui on THIS node)."
  warn "Run your panel inbound here — Iran only publishes ports; it does not host the service."
  rule

  install_reverse_engine || return 1
  apply_tuning fq
  reverse_install_runtime

  local name; name="$(reverse_pick_name)" || return 1
  [[ -z "${name}" ]] && { fail "Invalid name."; return 1; }
  mkdir -p "$(rev_idir "${name}")"
  rmeta_set "${name}" ROLE exit

  local remote link_port token proto nodelay heartbeat ports local_host
  remote="$(ask 'Iran (entry) node public IPv4')"
  valid_ipv4 "${remote}" || { fail "Invalid IPv4."; rm -rf "$(rev_idir "${name}")"; return 1; }
  rmeta_set "${name}" REMOTE_V4 "${remote}"

  link_port="$(ask 'Link port (match entry) [443]')"; link_port="${link_port:-443}"
  rmeta_set "${name}" LINK_PORT "${link_port}"

  token="$(ask 'Token (must match entry)')"
  [[ -n "${token}" ]] || { fail "Token required."; rm -rf "$(rev_idir "${name}")"; return 1; }
  rmeta_set "${name}" TOKEN "${token}"

  proto="$(reverse_prompt_proto)"
  rmeta_set "${name}" PROTO "${proto}"
  nodelay="$(reverse_prompt_nodelay)"
  rmeta_set "${name}" NODELAY "${nodelay}"

  heartbeat="$(ask 'Heartbeat timeout seconds [30]')"; heartbeat="${heartbeat:-30}"
  rmeta_set "${name}" HEARTBEAT "${heartbeat}"

  ports="$(gather_ports)"
  [[ -z "${ports}" ]] && { fail "No valid ports provided."; rm -rf "$(rev_idir "${name}")"; return 1; }
  rmeta_set "${name}" PORTS "${ports}"

  info "Local upstream = where Xray/3x-ui listens on this kharej box (usually 127.0.0.1)."
  info "User port on Iran must match the port in your inbound here (e.g. both 7171)."
  local_host="$(ask 'Local upstream host [127.0.0.1]')"; local_host="${local_host:-127.0.0.1}"
  rmeta_set "${name}" LOCAL_HOST "${local_host}"

  write_reverse_exit_config "${name}"
  reverse_start_instance "${name}" || return 1

  echo
  good "Exit tunnel '${name}' live."
  info "  Upstream  : ${local_host} on ports ${ports}"
  good "This kharej node now dials into Iran and exposes ${local_host}:<port> there."
}

reverse_list() {
  rule
  info "Phormal Reverse — tunnels"
  rule
  local n any=0
  printf '    %-16s %-6s %-22s %-10s %s\n' "NAME" "ROLE" "TARGET/LINK" "STATE" "PORTS"
  while read -r n; do
    [[ -n "${n}" ]] || continue
    any=1
    local role link remote ports state tgt
    role="$(rmeta_get "${n}" ROLE)"
    link="$(rmeta_get "${n}" LINK_PORT)"
    remote="$(rmeta_get "${n}" REMOTE_V4)"
    ports="$(rmeta_get "${n}" PORTS)"
    state="$(rev_svc_state "${n}")"
    if [[ "${role}" == "entry" ]]; then tgt=":${link}"; else tgt="${remote}:${link}"; fi
    printf '    %-16s %-6s %-22s %-10s %s\n' "${n}" "${role}" "${tgt}" "${state}" "${ports:--}"
  done < <(reverse_instances)
  [[ ${any} -eq 0 ]] && warn "no tunnels configured yet"
  rule
}

reverse_choose_instance() {
  local names=() n i
  while read -r n; do [[ -n "${n}" ]] && names+=("${n}"); done < <(reverse_instances)
  if [[ ${#names[@]} -eq 0 ]]; then warn "No tunnels configured." >&2; printf '%s' ""; return 1; fi
  {
    for i in "${!names[@]}"; do
      printf '  %s%s%s  %s (%s, %s)\n' "${ACC}" "$((i+1))" "${RST}" \
        "${names[i]}" "$(rmeta_get "${names[i]}" ROLE)" "$(rev_svc_state "${names[i]}")"
    done
  } >&2
  local sel; sel="$(ask 'Tunnel number')"
  [[ "${sel}" =~ ^[0-9]+$ ]] || { printf '%s' ""; return 1; }
  local idx=$((sel-1))
  [[ ${idx} -ge 0 && ${idx} -lt ${#names[@]} ]] || { printf '%s' ""; return 1; }
  printf '%s' "${names[idx]}"
}

diagnose_reverse_instance() {
  local name="$1" role svc link ports p
  role="$(rmeta_get "${name}" ROLE)"
  svc="$(rev_svc "${name}")"
  rule
  info "Diagnostics — reverse tunnel '${name}' (${role})"
  rule
  if systemctl is-active "${svc}" >/dev/null 2>&1; then good "service active"; else fail "service not active"; fi
  link="$(rmeta_get "${name}" LINK_PORT)"
  if [[ "${role}" == "entry" ]]; then
    if port_open_tcp "${link}"; then good "TCP link :${link} listening"; else warn "TCP link :${link} not confirmed"; fi
    ports="$(rmeta_get "${name}" PORTS)"
    IFS=',' read -ra parr <<< "${ports}"
    for p in "${parr[@]}"; do
      [[ -n "${p}" ]] || continue
      if port_open_tcp "${p}"; then good "TCP :${p} listening (users connect here)"; else fail "TCP :${p} NOT listening"; fi
    done
  else
    info "Peer (Iran): $(rmeta_get "${name}" REMOTE_V4):${link}"
    info "Local upstream: $(rmeta_get "${name}" LOCAL_HOST)"
  fi
  echo
  info "Recent log:"
  journalctl -u "${svc}" -n 8 --no-pager 2>/dev/null | sed 's/^/    /' || true
  rule
}

reverse_edit_ports() {
  local name="$1" ports
  ports="$(gather_ports)"
  [[ -z "${ports}" ]] && { fail "No valid ports."; return 1; }
  rmeta_set "${name}" PORTS "${ports}"
  reverse_rebuild_instance "${name}"
  good "Ports for '${name}' now: ${ports}"
}

reverse_change_peer_ip() {
  local name="$1" role ip
  role="$(rmeta_get "${name}" ROLE)"
  [[ "${role}" == "exit" ]] || { fail "Peer IP only applies to exit tunnels."; return 1; }
  ip="$(ask "Iran (entry) IP [$(rmeta_get "${name}" REMOTE_V4)]")"
  [[ -z "${ip}" ]] && return 0
  valid_ipv4 "${ip}" || { fail "Invalid IPv4."; return 1; }
  rmeta_set "${name}" REMOTE_V4 "${ip}"
  reverse_rebuild_instance "${name}"
  good "Peer IP for '${name}' updated to ${ip}."
}

reverse_change_linkport() {
  local name="$1" lp
  lp="$(ask "Link port [$(rmeta_get "${name}" LINK_PORT)]")"
  [[ -z "${lp}" ]] && return 0
  rmeta_set "${name}" LINK_PORT "${lp}"
  reverse_rebuild_instance "${name}"
  good "Link port for '${name}' updated."
  warn "Must match on the other node."
}

reverse_change_token() {
  local name="$1" t
  t="$(ask "Token [$(rmeta_get "${name}" TOKEN)]")"
  [[ -z "${t}" ]] && return 0
  rmeta_set "${name}" TOKEN "${t}"
  reverse_rebuild_instance "${name}"
  good "Token updated."
  warn "Must match on the other node."
}

reverse_edit_raw() {
  local name="$1" dir; dir="$(rev_idir "${name}")"
  info "  ${dir}/meta.conf"
  info "  ${dir}/config.toml"
  local c; c="$(ask 'Edit raw config now? (y/n)')"
  [[ "${c}" == "y" ]] && ${EDITOR:-nano} "${dir}/config.toml"
  local r; r="$(ask 'Restart tunnel to apply? (y/n)')"
  [[ "${r}" == "y" ]] && reverse_start_instance "${name}"
}

reverse_delete_instance() {
  local name="$1" svc; svc="$(rev_svc "${name}")"
  local c; c="$(ask "Delete tunnel '${name}' permanently? (y/n)")"
  [[ "${c}" != "y" ]] && { info "Cancelled."; return 0; }
  systemctl stop "${svc}" 2>/dev/null || true
  systemctl disable "${svc}" 2>/dev/null || true
  rm -rf "$(rev_idir "${name}")"
  systemctl daemon-reload
  good "Tunnel '${name}' deleted."
}

manage_reverse_instance_menu() {
  local name="$1"
  while :; do
    rule
    info "Manage reverse tunnel '${name}'  (${MUT}$(rmeta_get "${name}" ROLE) • $(rev_svc_state "${name}")${RST})"
    rule
    printf '  %s1%s  Restart\n'                 "${ACC}" "${RST}"
    printf '  %s2%s  Stop\n'                    "${ACC}" "${RST}"
    printf '  %s3%s  Start\n'                   "${ACC}" "${RST}"
    printf '  %s4%s  Diagnostics\n'             "${ACC}" "${RST}"
    printf '  %s5%s  Live log (Ctrl-C to exit)\n' "${ACC}" "${RST}"
    printf '  %s6%s  Edit ports\n'            "${ACC}" "${RST}"
    printf '  %s7%s  Change peer IP (exit only)\n' "${ACC}" "${RST}"
    printf '  %s8%s  Change link port\n'        "${ACC}" "${RST}"
    printf '  %s9%s  Change token\n'            "${ACC}" "${RST}"
    printf ' %s10%s  Edit raw config\n'         "${ACC}" "${RST}"
    printf ' %s11%s  Delete tunnel\n'           "${ACC}" "${RST}"
    printf '  %s0%s  Back\n\n'                  "${ACC}" "${RST}"
    local c; c="$(ask 'Select')"; echo
    case "${c}" in
      1) reverse_start_instance "${name}" || true ;;
      2) systemctl stop "$(rev_svc "${name}")" 2>/dev/null && good "Stopped." || fail "Could not stop." ;;
      3) systemctl start "$(rev_svc "${name}")" 2>/dev/null && good "Started." || fail "Could not start." ;;
      4) diagnose_reverse_instance "${name}" ;;
      5) journalctl -u "$(rev_svc "${name}")" -f --no-pager 2>/dev/null || true ;;
      6) reverse_edit_ports "${name}" || true ;;
      7) reverse_change_peer_ip "${name}" || true ;;
      8) reverse_change_linkport "${name}" || true ;;
      9) reverse_change_token "${name}" || true ;;
      10) reverse_edit_raw "${name}" || true ;;
      11) reverse_delete_instance "${name}"; break ;;
      0) break ;;
      *) fail "Invalid selection." ;;
    esac
    echo
  done
}

manage_reverse_menu() {
  while :; do
    reverse_list
    printf '  %s1%s  Manage a tunnel\n'     "${ACC}" "${RST}"
    printf '  %s2%s  Add exit tunnel\n'     "${ACC}" "${RST}"
    printf '  %s3%s  Add entry tunnel\n'    "${ACC}" "${RST}"
    printf '  %s4%s  Restart ALL tunnels\n' "${ACC}" "${RST}"
    printf '  %s0%s  Back\n\n'              "${ACC}" "${RST}"
    local c; c="$(ask 'Select')"; echo
    case "${c}" in
      1) local n; n="$(reverse_choose_instance)"; [[ -n "${n}" ]] && manage_reverse_instance_menu "${n}" ;;
      2) create_reverse_exit || true ;;
      3) create_reverse_entry || true ;;
      4) local n; while read -r n; do [[ -n "${n}" ]] && reverse_start_instance "${n}" || true; done < <(reverse_instances) ;;
      0) break ;;
      *) fail "Invalid selection." ;;
    esac
    echo
  done
}

# ==============================================================================
#  OPS
# ------------------------------------------------------------------------------
schedule_refresh() {
  local hrs; hrs="$(ask 'Auto-refresh interval in hours (0 to disable)')"
  crontab -l 2>/dev/null | grep -v 'phormal-refresh' | crontab - 2>/dev/null || true
  if [[ "${hrs}" =~ ^[0-9]+$ && "${hrs}" -gt 0 ]]; then
    cat > /usr/bin/phormal-refresh.sh <<'EOF'
#!/usr/bin/env bash
systemctl daemon-reload
systemctl restart 'phormal-core@*.service'  2>/dev/null || true
systemctl restart 'phormal-guard@*.service' 2>/dev/null || true
systemctl restart 'phormal-bfwd@*.service'  2>/dev/null || true
systemctl restart 'phormal-relay@*.service' 2>/dev/null || true
systemctl restart 'phormal-reverse@*.service' 2>/dev/null || true
systemctl restart 'phormal-gre@*.service'    2>/dev/null || true
systemctl restart 'phormal-icmp@*.service'   2>/dev/null || true
systemctl restart 'phormal-udp2raw@*.service' 2>/dev/null || true
EOF
    chmod +x /usr/bin/phormal-refresh.sh
    ( crontab -l 2>/dev/null; echo "0 */${hrs} * * * /usr/bin/phormal-refresh.sh # phormal-refresh" ) | crontab -
    good "Auto-refresh every ${hrs}h scheduled."
  else
    rm -f /usr/bin/phormal-refresh.sh
    good "Auto-refresh disabled."
  fi
}

status() {
  rule
  info "BRIDGE LINKS"
  local bany=0 bn
  while read -r bn; do
    [[ -n "${bn}" ]] || continue
    bany=1
    printf '    %-14s %-6s peer %-16s %s\n' \
      "${bn}" "$(bmeta_get "${bn}" ROLE)" "$(bmeta_get "${bn}" REMOTE_V4)" "$(bcore_state "${bn}")"
  done < <(bridge_instances)
  [[ ${bany} -eq 0 ]] && warn "no bridge links configured"
  echo
  info "PHORMAL TUNING"
  printf '    profile : %s / %s\n' \
    "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')" \
    "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
  echo
  info "RELAY TUNNELS"
  local any=0 n
  while read -r n; do
    [[ -n "${n}" ]] || continue
    any=1
    local role listen remote tgt
    role="$(imeta_get "${n}" ROLE)"; listen="$(imeta_get "${n}" LISTEN)"; remote="$(imeta_get "${n}" REMOTE_V4)"
    if [[ "${role}" == "entry" ]]; then tgt="${remote}:${listen}"; else tgt=":${listen}"; fi
    printf '    %-16s %-6s %-22s %s\n' "${n}" "${role}" "${tgt}" "$(relay_svc_state "${n}")"
  done < <(relay_instances)
  [[ ${any} -eq 0 ]] && warn "no relay tunnels configured"
  echo
  info "REVERSE TUNNELS"
  local rany=0 rn role link remote tgt
  while read -r rn; do
    [[ -n "${rn}" ]] || continue
    rany=1
    role="$(rmeta_get "${rn}" ROLE)"; link="$(rmeta_get "${rn}" LINK_PORT)"; remote="$(rmeta_get "${rn}" REMOTE_V4)"
    if [[ "${role}" == "entry" ]]; then tgt=":${link}"; else tgt="${remote}:${link}"; fi
    printf '    %-16s %-6s %-22s %s\n' "${rn}" "${role}" "${tgt}" "$(rev_svc_state "${rn}")"
  done < <(reverse_instances)
  [[ ${rany} -eq 0 ]] && warn "no reverse tunnels configured"
  echo
  info "PHORMAL GRE / ECHO / RAW"
  local lany=0 lk ln pname
  for lk in gre icmp udp2raw; do
    pname="$(layer_phormal_name "${lk}")"
    while read -r ln; do
      [[ -n "${ln}" ]] || continue
      lany=1
      printf '    %-18s %-16s %s\n' "${pname}" "${ln}" "$(layer_svc_state "$(layer_svc "${lk}" "${ln}")")"
    done < <(layer_instances "${lk}" 2>/dev/null || true)
  done
  [[ ${lany} -eq 0 ]] && warn "no layer tunnels configured"
  rule
}

purge() {
  local c; c="$(ask 'Remove Phormal entirely? (y/n)')"
  [[ "${c}" != "y" ]] && { info "Cancelled."; return; }
  local n
  # bridge links (new multi-instance templates)
  while read -r n; do
    [[ -n "${n}" ]] || continue
    systemctl stop    "$(bfwd_svc "${n}")"  "$(bguard_svc "${n}")" "$(bcore_svc "${n}")" 2>/dev/null || true
    systemctl disable "$(bfwd_svc "${n}")"  "$(bguard_svc "${n}")" "$(bcore_svc "${n}")" 2>/dev/null || true
    ip link del "$(bmeta_get "${n}" IFACE)" 2>/dev/null || true
  done < <(bridge_instances)
  rm -f "${BCORE_TMPL}" "${BGUARD_TMPL}" "${BFWD_TMPL}" "${BRIDGE_RUN}"
  # legacy bridge forwarders / single units
  for u in /etc/systemd/system/phormal-fwd@*.service; do
    [[ -e "${u}" ]] || continue
    local nm; nm="$(basename "${u}")"
    systemctl stop "${nm}" 2>/dev/null || true
    systemctl disable "${nm}" 2>/dev/null || true
  done
  rm -f /etc/systemd/system/phormal-fwd@*.service
  systemctl stop phormal-core.service phormal-guard.service 2>/dev/null || true
  systemctl disable phormal-core.service phormal-guard.service 2>/dev/null || true
  rm -f "${CORE_UNIT}" "${GUARD_UNIT}"
  ip link del "${CORE_IFACE}" 2>/dev/null || true
  # relay instances (template)
  while read -r n; do
    [[ -n "${n}" ]] || continue
    systemctl stop "$(relay_svc "${n}")" 2>/dev/null || true
    systemctl disable "$(relay_svc "${n}")" 2>/dev/null || true
    systemctl stop "$(cdn_svc "${n}")" 2>/dev/null || true
    systemctl disable "$(cdn_svc "${n}")" 2>/dev/null || true
  done < <(relay_instances)
  rm -f "${RELAY_TEMPLATE_UNIT}" "${RELAY_RUN}"
  # CDN front (gost) template + any leftover instances
  for u in /etc/systemd/system/phormal-cdn@*.service; do
    [[ -e "${u}" ]] || continue
    local cm; cm="$(basename "${u}")"
    systemctl stop "${cm}" 2>/dev/null || true
    systemctl disable "${cm}" 2>/dev/null || true
  done
  rm -f "${CDN_TMPL}" "${CDN_RUN}"
  # legacy single-instance relay + hysteria units
  systemctl stop phormal-relay.service phormal-hysteria.service 2>/dev/null || true
  systemctl disable phormal-relay.service phormal-hysteria.service 2>/dev/null || true
  rm -f "${RELAY_UNIT}" /etc/systemd/system/phormal-hysteria.service
  rm -f /etc/sysctl.d/99-phormal.conf \
    /etc/sysctl.d/98-phormal-tuning.conf /etc/sysctl.d/98-phormal-bbr.conf \
    "${RELAY_SYSCTL}" /etc/sysctl.d/97-phormal-hysteria.conf /etc/sysctl.d/97-phormal-relay.conf
  rm -f "${RELAY_BIN}" /usr/local/bin/phormal-hy2 "${FWD_BIN}"
  while read -r n; do
    [[ -n "${n}" ]] || continue
    systemctl stop "$(rev_svc "${n}")" 2>/dev/null || true
    systemctl disable "$(rev_svc "${n}")" 2>/dev/null || true
  done < <(reverse_instances)
  rm -f "${REVERSE_TMPL}" "${REVERSE_RUN}" "${REVERSE_BIN}"
  systemctl stop 'phormal-spoof@*.service' 2>/dev/null || true
  systemctl disable 'phormal-spoof@*.service' 2>/dev/null || true
  rm -f /etc/systemd/system/phormal-spoof@.service \
    /usr/local/bin/phormal-spoof /usr/local/bin/phormal-spoof-run \
    /etc/sysctl.d/96-phormal-spoof.conf
  rm -f /usr/bin/phormal-refresh.sh
  crontab -l 2>/dev/null | grep -v 'phormal-refresh' | crontab - 2>/dev/null || true
  local lk ln
  for lk in gre icmp udp2raw btcp bwss; do
    while read -r ln; do
      [[ -n "${ln}" ]] || continue
      systemctl stop "phormal-${lk}@${ln}" 2>/dev/null || true
      systemctl disable "phormal-${lk}@${ln}" 2>/dev/null || true
      [[ "${lk}" == gre ]] && ip link del "$(layer_meta_get gre "${ln}" IFACE 2>/dev/null || true)" 2>/dev/null || true
    done < <(layer_instances "${lk}" 2>/dev/null || true)
    rm -f "/etc/systemd/system/phormal-${lk}@.service"
  done
  rm -f "${LAYER_RUN}" "${LAYER_GRE_RUN}" "${LAYER_ICMP_BIN}" \
    "${LAYER_UDP2RAW_BIN}" \
    /usr/local/bin/phormal-backhaul \
    /etc/systemd/system/phormal-btcp@.service /etc/systemd/system/phormal-bwss@.service
  rm -rf "${PHORMAL_HOME}"
  systemctl daemon-reload
  good "Phormal removed. (CLI shortcut left at ${CLI_LINK}; delete manually if desired.)"
}

quick_deploy_bridge() { create_bridge_entry; }

install_cli() {
  local src; src="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  if [[ "${src}" != "${CLI_LINK}" ]]; then
    cp -f "${src}" "${CLI_LINK}" 2>/dev/null && chmod +x "${CLI_LINK}" 2>/dev/null || true
  fi
}


# ------------------------------------------------------------------------------
#  Multi-Layer Tunnels & Auto-Test
# ------------------------------------------------------------------------------
# ---- Multi-layer constants ----
readonly LAYER_HOME="${PHORMAL_HOME}"
readonly LAYER_PROBE_TAG="phormal-probe"
readonly LAYER_PROBE_PORT_BASE=59000
readonly ICMP_TUN_RELEASE_REPO="Azumi67/icmp_tun"
readonly UDP2RAW_RELEASE_TAG="20230206.0"
readonly UDP2RAW_RELEASE_REPO="wangyu-/udp2raw"
readonly LAYER_ICMP_BIN="/usr/local/bin/phormal-icmp-tun"
readonly LAYER_UDP2RAW_BIN="/usr/local/bin/phormal-udp2raw"
readonly LAYER_RUN="/usr/local/bin/phormal-layer-run"
readonly LAYER_GRE_RUN="/usr/local/bin/phormal-gre-run"
readonly LAYER_KEYS=(gre icmp udp2raw)

# Phormal product display names (internal key → user-facing brand)
layer_phormal_name() {
  case "$1" in
    gre)     printf 'Phormal GRE' ;;
    icmp)    printf 'Phormal Echo' ;;
    udp2raw) printf 'Phormal Raw' ;;
    *)       printf 'Phormal Layer' ;;
  esac
}

layer_choose_instance() {
  local key="$1" names=() n pick
  while read -r n; do [[ -n "${n}" ]] && names+=("${n}"); done < <(layer_instances "${key}")
  [[ ${#names[@]} -gt 0 ]] || { warn "No $(layer_phormal_name "${key}") tunnels yet."; return 1; }
  if [[ ${#names[@]} -eq 1 ]]; then printf '%s' "${names[0]}"; return 0; fi
  info "$(layer_phormal_name "${key}") tunnels:"
  local i=1; for n in "${names[@]}"; do printf '    %s) %s [%s]\n' "${i}" "${n}" "$(layer_svc_state "$(layer_svc "${key}" "${n}")")"; i=$((i+1)); done
  pick="$(ask 'Name or number')"
  [[ "${pick}" =~ ^[0-9]+$ && "${pick}" -ge 1 && "${pick}" -le ${#names[@]} ]] && printf '%s' "${names[$((pick-1))]}" && return 0
  printf '%s' "${pick}"
}

layer_list() {
  local key="$1" n any=0
  rule
  info "$(layer_phormal_name "${key}") — tunnels"
  rule
  printf '    %-16s %-6s %s\n' "NAME" "ROLE" "STATE"
  while read -r n; do
    [[ -n "${n}" ]] || continue
    any=1
    printf '    %-16s %-6s %s\n' "${n}" "$(layer_meta_get "${key}" "${n}" ROLE 2>/dev/null || echo '?')" \
      "$(layer_svc_state "$(layer_svc "${key}" "${n}")")"
  done < <(layer_instances "${key}")
  [[ ${any} -eq 0 ]] && warn "no tunnels configured"
  rule
}

manage_phormal_layer_menu() {
  local key="$1" title
  title="$(layer_phormal_name "${key}")"
  while :; do
    layer_list "${key}"
    printf '  %s1%s  Manage a tunnel\n'     "${ACC}" "${RST}"
    printf '  %s2%s  Add exit tunnel\n'     "${ACC}" "${RST}"
    printf '  %s3%s  Add entry tunnel\n'    "${ACC}" "${RST}"
    printf '  %s4%s  Restart ALL tunnels\n' "${ACC}" "${RST}"
    printf '  %s0%s  Back\n\n'              "${ACC}" "${RST}"
    local c; c="$(ask 'Select')"; echo
    case "${c}" in
      1) local n; n="$(layer_choose_instance "${key}")"; [[ -n "${n}" ]] && manage_layer_instance_menu "${key}" "${n}" ;;
      2) layer_create_exit "${key}" || true ;;
      3) layer_create_entry "${key}" || true ;;
      4) local n; while read -r n; do [[ -n "${n}" ]] && layer_start_instance "${key}" "${n}" || true; done < <(layer_instances "${key}") ;;
      0) break ;;
      *) fail "Invalid selection." ;;
    esac
    echo
  done
}

layer_create_entry() {
  local key="$1"
  case "${key}" in
    gre)     create_layer_gre_entry ;;
    icmp)    create_layer_icmp_entry ;;
    udp2raw) create_layer_udp2raw_entry ;;
    *)       fail "Unknown product."; return 1 ;;
  esac
}

layer_create_exit() {
  local key="$1"
  case "${key}" in
    gre)     create_layer_gre_exit ;;
    icmp)    create_layer_icmp_exit ;;
    udp2raw) create_layer_udp2raw_exit ;;
    *)       fail "Unknown product."; return 1 ;;
  esac
}

manage_gre_menu()    { manage_phormal_layer_menu gre; }
manage_echo_menu()   { manage_phormal_layer_menu icmp; }
manage_raw_menu()    { manage_phormal_layer_menu udp2raw; }

layer_idir() { printf '%s/%s/%s' "${LAYER_HOME}" "$1" "$2"; }
layer_svc()  { printf 'phormal-%s@%s.service' "$1" "$2"; }

layer_meta_file() { printf '%s/meta.conf' "$(layer_idir "$1" "$2")"; }

layer_meta_get() {
  local key="$1" name="$2" k="$3" f
  f="$(layer_meta_file "${key}" "${name}")"
  [[ -f "${f}" ]] || return 1
  grep -m1 "^${k}=" "${f}" 2>/dev/null | cut -d= -f2- | tr -d '\r'
}

layer_meta_set() {
  local key="$1" name="$2" k="$3" v="$4" f dir
  dir="$(layer_idir "${key}" "${name}")"
  mkdir -p "${dir}"
  f="$(layer_meta_file "${key}" "${name}")"
  touch "${f}"
  if grep -q "^${k}=" "${f}" 2>/dev/null; then
    sed -i "s|^${k}=.*|${k}=${v}|" "${f}"
  else
    printf '%s=%s\n' "${k}" "${v}" >>"${f}"
  fi
}

layer_instances() {
  local key="$1" d
  d="${LAYER_HOME}/${key}"
  [[ -d "${d}" ]] || return 0
  find "${d}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
    | sort -u
}

layer_pick_name() {
  local key="$1" raw name pname
  pname="$(layer_phormal_name "${key}")"
  raw="$(ask "Tunnel name for ${pname} (e.g. ir1, khr-de)")"
  name="$(relay_sanitize_name "${raw}")"
  if [[ -f "$(layer_meta_file "${key}" "${name}")" ]]; then
    warn "Tunnel '${name}' already exists for ${pname}." >&2
    printf '%s' ""
    return 1
  fi
  printf '%s' "${name}"
}

layer_svc_state() {
  local svc="$1" st
  st="$(systemctl is-active "${svc}" 2>/dev/null || true)"
  printf '%s' "${st:-inactive}"
}

# ---- Mirror URL helpers ----
mirror_layer_url() {
  local file="$1" base
  base="$(mirror_base)"
  [[ -n "${base}" ]] || return 1
  printf '%s/%s' "${base%/}" "${file}"
}

mirror_icmp_tun_url() {
  local arch="$1"
  mirror_layer_url "icmp_tun-linux-${arch}"
}

mirror_udp2raw_url() {
  local arch="$1"
  mirror_layer_url "udp2raw-linux-${arch}"
}

udp2raw_upstream_tgz_url() {
  printf 'https://github.com/%s/releases/download/%s/udp2raw_binaries.tar.gz' \
    "${UDP2RAW_RELEASE_REPO}" "${UDP2RAW_RELEASE_TAG}"
}

verify_icmp_tun_tmp() {
  local b="$1" out
  [[ -x "${b}" ]] || return 1
  out="$("${b}" --help 2>&1 || true)"
  [[ "${out}" == *"icmp_tun"* || "${out}" == *"--mode"* || "${out}" == *"TUN"* ]]
}
verify_udp2raw_tmp() {
  local b="$1" out
  [[ -x "${b}" ]] || return 1
  out="$("${b}" --help 2>&1 || "${b}" -h 2>&1 || true)"
  [[ "${out}" == *"raw-mode"* || "${out}" == *"faketcp"* ]]
}

install_layer_icmp_tun() {
  local arch dest="${LAYER_ICMP_BIN}" mirror manual legacy
  arch="$(machine_arch)" || return 1
  [[ -x "${dest}" ]] && verify_icmp_tun_tmp "${dest}" && return 0
  choose_binary_source || true
  if [[ "${BINARY_SOURCE}" == "manual" ]]; then
    manual="${MANUAL_DIR}/phormal-echo-linux-${arch}"
    legacy="${MANUAL_DIR}/icmp_tun-linux-${arch}"
    [[ -f "${manual}" ]] || manual="${legacy}"
    [[ -f "${manual}" ]] || { fail "Place Phormal Echo engine at ${MANUAL_DIR}/phormal-echo-linux-${arch}"; return 1; }
    cp -f "${manual}" "${dest}" && chmod +x "${dest}"
    verify_icmp_tun_tmp "${dest}" && { good "Phormal Echo engine installed (manual)."; return 0; }
    return 1
  fi
  local urls=()
  [[ "${BINARY_SOURCE}" == "mirror" ]] && urls+=("$(mirror_icmp_tun_url "${arch}" 2>/dev/null || true)")
  fetch_binary "${dest}" verify_icmp_tun_tmp "Phormal Echo engine" "${urls[@]}" \
    || install_local_binary "${dest}" || return 1
  verify_icmp_tun_tmp "${dest}"
}

install_layer_udp2raw() {
  local arch dest="${LAYER_UDP2RAW_BIN}" mirror manual legacy tgz td found
  arch="$(machine_arch)" || return 1
  [[ -x "${dest}" ]] && verify_udp2raw_tmp "${dest}" && return 0
  choose_binary_source || true
  if [[ "${BINARY_SOURCE}" == "manual" ]]; then
    manual="${MANUAL_DIR}/phormal-raw-linux-${arch}"
    legacy="${MANUAL_DIR}/udp2raw-linux-${arch}"
    [[ -f "${manual}" ]] || manual="${legacy}"
    [[ -f "${manual}" ]] || { fail "Place Phormal Raw engine at ${MANUAL_DIR}/phormal-raw-linux-${arch}"; return 1; }
    cp -f "${manual}" "${dest}" && chmod +x "${dest}"
    verify_udp2raw_tmp "${dest}" && { good "Phormal Raw engine installed (manual)."; return 0; }
    return 1
  fi
  local urls=()
  [[ "${BINARY_SOURCE}" == "mirror" ]] && urls+=("$(mirror_udp2raw_url "${arch}" 2>/dev/null || true)")
  for mirror in "${urls[@]}"; do
    [[ -n "${mirror}" ]] && fetch_binary "${dest}" verify_udp2raw_tmp "Phormal Raw engine" "${mirror}" && return 0
  done
  tgz="$(mktemp)"; td="$(mktemp -d)"
  if fetch_url "$(udp2raw_upstream_tgz_url)" "${tgz}"; then
    tar xzf "${tgz}" -C "${td}" 2>/dev/null || true
    for found in "${td}/udp2raw_${arch}" "${td}/udp2raw_${arch//amd64/amd64}" \
      "${td}/udp2raw_amd64" "${td}/udp2raw_arm" "${td}/udp2raw_aarch64"; do
      [[ -f "${found}" ]] && cp -f "${found}" "${dest}" && break
    done
    [[ ! -f "${dest}" ]] && found="$(find "${td}" -name 'udp2raw*' -type f 2>/dev/null | head -n1)" \
      && [[ -n "${found}" ]] && cp -f "${found}" "${dest}"
    rm -rf "${td}" "${tgz}"
    chmod +x "${dest}" 2>/dev/null || true
    verify_udp2raw_tmp "${dest}" && { good "Phormal Raw engine installed."; return 0; }
  fi
  install_local_binary "${dest}" || return 1
  verify_udp2raw_tmp "${dest}"
}

layer_install_runtime() {
  cat > "${LAYER_RUN}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
key="$1"; name="$2"
dir="/etc/phormal/${key}/${name}"
meta="${dir}/meta.conf"
[[ -f "${meta}" ]] || { echo "missing ${meta}" >&2; exit 1; }
# shellcheck disable=SC1090
source "${meta}"
case "${key}" in
  icmp)
    # shellcheck disable=SC2086
    exec /usr/local/bin/phormal-icmp-tun ${ICMP_ARGS:-}
    ;;
  udp2raw)
    # shellcheck disable=SC2086
    exec /usr/local/bin/phormal-udp2raw ${UDP2RAW_ARGS:-}
    ;;
  *)
    echo "unknown layer ${key}" >&2; exit 1
    ;;
esac
EOF
  chmod +x "${LAYER_RUN}"

  cat > "${LAYER_GRE_RUN}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
name="$1"
dir="/etc/phormal/gre/${name}"
meta="${dir}/meta.conf"
[[ -f "${meta}" ]] || { echo "missing meta" >&2; exit 1; }
# shellcheck disable=SC1090
source "${meta}"
IFACE="${IFACE:-phgre${name}}"
ip link del "${IFACE}" 2>/dev/null || true
case "${TUN_MODE}" in
  gre) ip tunnel add "${IFACE}" mode gre remote "${REMOTE_V4}" local "${LOCAL_V4}" ttl 255 ;;
  ipip) ip tunnel add "${IFACE}" mode ipip remote "${REMOTE_V4}" local "${LOCAL_V4}" ttl 255 ;;
  *) echo "bad TUN_MODE" >&2; exit 1 ;;
esac
ip link set "${IFACE}" up
ip addr add "${LOCAL_PRIV}/30" dev "${IFACE}"
ip route add "${REMOTE_PRIV}/32" dev "${IFACE}" 2>/dev/null || true
exec sleep infinity
EOF
  chmod +x "${LAYER_GRE_RUN}"

  cat > /etc/systemd/system/phormal-gre@.service <<EOF
[Unit]
Description=Phormal GRE/IPIP layer (%i)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=${LAYER_GRE_RUN} %i
Restart=always
RestartSec=3
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
[Install]
WantedBy=multi-user.target
EOF
  local key
  for key in icmp udp2raw; do
    cat > "/etc/systemd/system/phormal-${key}@.service" <<EOF
[Unit]
Description=Phormal layer ${key} (%i)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStartPre=/bin/sleep 2
ExecStart=${LAYER_RUN} ${key} %i
Restart=always
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
[Install]
WantedBy=multi-user.target
EOF
  done
  systemctl daemon-reload
}

layer_start_instance() {
  local key="$1" name="$2" svc
  svc="$(layer_svc "${key}" "${name}")"
  systemctl daemon-reload
  systemctl enable "${svc}" >/dev/null 2>&1
  systemctl restart "${svc}"
  sleep 2
  if systemctl is-active "${svc}" >/dev/null 2>&1; then
    good "Layer tunnel '${key}/${name}' is active."
    return 0
  fi
  fail "Layer tunnel '${key}/${name}' failed to start."
  journalctl -u "${svc}" -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
  return 1
}

layer_print_connect_line() {
  local key="$1" name="$2" role ports link self_ip
  role="$(layer_meta_get "${key}" "${name}" ROLE)"
  ports="$(layer_meta_get "${key}" "${name}" PORTS)"
  link="$(layer_meta_get "${key}" "${name}" LINK_PORT)"
  self_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  if [[ "${role}" == "entry" && -n "${ports}" ]]; then
    good "Point users at ${self_ip:-THIS_SERVER} on port(s): ${ports}"
  elif [[ "${role}" == "entry" && -n "${link}" ]]; then
    good "Entry listening on :${link} — publish panel ports on this Iran node."
  fi
}

_create_layer_gre_tunnel() {
  local role="$1"
  rule
  info "Phormal GRE — add ${role} tunnel"
  rule
  local name local_v4 remote_v4 mode local_priv remote_priv iface gre_mode
  name="$(layer_pick_name gre)" || return 1
  mkdir -p "$(layer_idir gre "${name}")"
  layer_meta_set gre "${name}" ROLE "${role}"
  gre_mode="$(ask 'Phormal GRE mode [primary/alternate]')"; gre_mode="${gre_mode:-primary}"
  case "${gre_mode}" in
    primary|gre) mode=gre ;;
    alternate|ipip) mode=ipip ;;
    *) mode=gre ;;
  esac
  layer_meta_set gre "${name}" TUN_MODE "${mode}"
  local_v4="$(ask 'This server public IPv4')"
  if [[ "${role}" == exit ]]; then
    remote_v4="$(ask 'Iran entry public IPv4')"
  else
    remote_v4="$(ask 'Peer public IPv4')"
  fi
  valid_ipv4 "${local_v4}" && valid_ipv4 "${remote_v4}" || return 1
  layer_meta_set gre "${name}" LOCAL_V4 "${local_v4}"
  layer_meta_set gre "${name}" REMOTE_V4 "${remote_v4}"
  if [[ "${role}" == exit ]]; then
    local_priv="$(ask 'Local private /30 IP [10.77.0.2]')"; local_priv="${local_priv:-10.77.0.2}"
    remote_priv="$(ask 'Remote private /30 IP [10.77.0.1]')"; remote_priv="${remote_priv:-10.77.0.1}"
  else
    local_priv="$(ask 'Local private /30 IP [10.77.0.1]')"; local_priv="${local_priv:-10.77.0.1}"
    remote_priv="$(ask 'Remote private /30 IP [10.77.0.2]')"; remote_priv="${remote_priv:-10.77.0.2}"
  fi
  layer_meta_set gre "${name}" LOCAL_PRIV "${local_priv}"
  layer_meta_set gre "${name}" REMOTE_PRIV "${remote_priv}"
  iface="phgre${name}"
  layer_meta_set gre "${name}" IFACE "${iface}"
  layer_install_runtime
  layer_start_instance gre "${name}"
}

create_layer_gre_entry() { _create_layer_gre_tunnel entry; }
create_layer_gre_exit()  { _create_layer_gre_tunnel exit; }

create_layer_icmp_entry() {
  rule
  info "Phormal Echo — add entry tunnel"
  rule
  local name local_v4 remote_v4 local_priv remote_priv tid args
  install_layer_icmp_tun || return 1
  layer_install_runtime
  name="$(layer_pick_name icmp)" || return 1
  mkdir -p "$(layer_idir icmp "${name}")"
  layer_meta_set icmp "${name}" ROLE entry
  local_v4="$(ask 'This server public IPv4')"
  remote_v4="$(ask 'Peer public IPv4')"
  valid_ipv4 "${local_v4}" && valid_ipv4 "${remote_v4}" || return 1
  local_priv="$(ask 'Local TUN IP [10.88.0.1]')"; local_priv="${local_priv:-10.88.0.1}"
  remote_priv="$(ask 'Remote TUN IP [10.88.0.2]')"; remote_priv="${remote_priv:-10.88.0.2}"
  tid="$(ask 'Phormal Echo tunnel id hex [0x7048]')"; tid="${tid:-0x7048}"
  args="--mode server --id ${tid} --burst 4 --pack 1 tun${name} ${local_v4} ${remote_v4} ${local_priv} ${remote_priv}"
  layer_meta_set icmp "${name}" ICMP_ARGS "${args}"
  layer_start_instance icmp "${name}"
}

create_layer_icmp_exit() {
  rule
  info "Phormal Echo — add exit tunnel"
  rule
  local name local_v4 remote_v4 local_priv remote_priv tid args
  install_layer_icmp_tun || return 1
  layer_install_runtime
  name="$(layer_pick_name icmp)" || return 1
  mkdir -p "$(layer_idir icmp "${name}")"
  layer_meta_set icmp "${name}" ROLE exit
  local_v4="$(ask 'This server public IPv4')"
  remote_v4="$(ask 'Iran entry public IPv4')"
  valid_ipv4 "${local_v4}" && valid_ipv4 "${remote_v4}" || return 1
  local_priv="$(ask 'Local TUN IP [10.88.0.2]')"; local_priv="${local_priv:-10.88.0.2}"
  remote_priv="$(ask 'Remote TUN IP [10.88.0.1]')"; remote_priv="${remote_priv:-10.88.0.1}"
  tid="$(ask 'Phormal Echo tunnel id hex (match entry) [0x7048]')"; tid="${tid:-0x7048}"
  args="--mode client --id ${tid} --poll-ms 8 --pack 1 tun${name} ${local_v4} ${remote_v4} ${local_priv} ${remote_priv}"
  layer_meta_set icmp "${name}" ICMP_ARGS "${args}"
  layer_start_instance icmp "${name}"
}

create_layer_udp2raw_exit() {
  rule
  info "Phormal Raw — add exit tunnel"
  rule
  local name remote listen relay key mode raw_mode args
  install_layer_udp2raw || return 1
  layer_install_runtime
  name="$(layer_pick_name udp2raw)" || return 1
  mkdir -p "$(layer_idir udp2raw "${name}")"
  layer_meta_set udp2raw "${name}" ROLE exit
  remote="$(ask 'Iran server IPv4')"; valid_ipv4 "${remote}" || return 1
  listen="$(ask 'Phormal Raw listen port on Iran [4096]')"; listen="${listen:-4096}"
  relay="$(ask 'Local UDP service port to tunnel [51820]')"; relay="${relay:-51820}"
  key="$(ask 'Phormal Raw key [phormal]')"; key="${key:-phormal}"
  raw_mode="$(ask 'Phormal Raw mode [tcp/icmp/udp]')"; raw_mode="${raw_mode:-tcp}"
  case "${raw_mode}" in
    tcp|faketcp) mode=faketcp ;;
    icmp) mode=icmp ;;
    udp) mode=udp ;;
    *) mode=faketcp ;;
  esac
  args="-c -l0.0.0.0:${relay} -r${remote}:${listen} -k ${key} --raw-mode ${mode} -a"
  layer_meta_set udp2raw "${name}" UDP2RAW_ARGS "${args}"
  layer_start_instance udp2raw "${name}"
}

create_layer_udp2raw_entry() {
  rule
  info "Phormal Raw — add entry tunnel"
  rule
  local name listen relay key mode raw_mode args
  install_layer_udp2raw || return 1
  layer_install_runtime
  name="$(layer_pick_name udp2raw)" || return 1
  mkdir -p "$(layer_idir udp2raw "${name}")"
  layer_meta_set udp2raw "${name}" ROLE entry
  listen="$(ask 'Phormal Raw listen port [4096]')"; listen="${listen:-4096}"
  relay="$(ask 'Forward to local UDP port [51820]')"; relay="${relay:-51820}"
  key="$(ask 'Phormal Raw key [phormal]')"; key="${key:-phormal}"
  raw_mode="$(ask 'Phormal Raw mode [tcp/icmp/udp]')"; raw_mode="${raw_mode:-tcp}"
  case "${raw_mode}" in
    tcp|faketcp) mode=faketcp ;;
    icmp) mode=icmp ;;
    udp) mode=udp ;;
    *) mode=faketcp ;;
  esac
  args="-s -l0.0.0.0:${listen} -r127.0.0.1:${relay} -k ${key} --raw-mode ${mode} -a"
  layer_meta_set udp2raw "${name}" UDP2RAW_ARGS "${args}"
  layer_start_instance udp2raw "${name}"
}

layer_delete_instance() {
  local key="$1" name="$2" svc iface pname
  pname="$(layer_phormal_name "${key}")"
  svc="$(layer_svc "${key}" "${name}")"
  systemctl stop "${svc}" 2>/dev/null || true
  systemctl disable "${svc}" 2>/dev/null || true
  if [[ "${key}" == gre ]]; then
    iface="$(layer_meta_get gre "${name}" IFACE 2>/dev/null || true)"
    [[ -n "${iface}" ]] && ip link del "${iface}" 2>/dev/null || true
  fi
  rm -rf "$(layer_idir "${key}" "${name}")"
  good "Deleted ${pname}/${name}."
}

manage_layer_instance_menu() {
  local key="$1" name="$2" c svc pname
  pname="$(layer_phormal_name "${key}")"
  svc="$(layer_svc "${key}" "${name}")"
  while :; do
    banner
    rule
    info "${pname} / ${name}  [$(layer_svc_state "${svc}")]"
    rule
    printf '    %s1%s  Start/restart\n' "${ACC}" "${RST}"
    printf '    %s2%s  Stop\n' "${ACC}" "${RST}"
    printf '    %s3%s  Logs\n' "${ACC}" "${RST}"
    printf '    %s4%s  Delete\n' "${ACC}" "${RST}"
    printf '    %s0%s  Back\n\n' "${ACC}" "${RST}"
    c="$(ask 'Select')"; echo
    case "${c}" in
      1) layer_start_instance "${key}" "${name}" || true ;;
      2) systemctl stop "${svc}" && good "Stopped." ;;
      3) journalctl -u "${svc}" -n 40 --no-pager ;;
      4) layer_delete_instance "${key}" "${name}"; break ;;
      0) break ;;
    esac
    echo; read -n1 -s -r -p "  ${MUT}Press any key…${RST}"; echo
  done
}

# ---- Auto-test helpers ----
layer_probe_port_free() {
  local p="$1"
  if ss -lun "sport = :${p}" 2>/dev/null | grep -q ":${p}"; then return 1; fi
  if ss -lnt "sport = :${p}" 2>/dev/null | grep -q ":${p}"; then return 1; fi
  return 0
}

layer_pick_probe_port() {
  local p=$((LAYER_PROBE_PORT_BASE + RANDOM % 2000))
  local i=0
  while ! layer_probe_port_free "${p}"; do
    p=$((p + 1)); i=$((i + 1))
    [[ ${i} -lt 50 ]] || return 1
  done
  printf '%s' "${p}"
}

layer_ssh_cmd() {
  local host="$1" port="$2" user="$3" cmd="$4"
  local -a ssh_extra=()
  if [[ -n "${LAYER_SSH_CTRL_PATH:-}" ]]; then
    ssh_extra=(-o "ControlPath=${LAYER_SSH_CTRL_PATH}")
  else
    ssh_extra=(-o BatchMode=yes)
  fi
  ssh "${ssh_extra[@]}" -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
    -p "${port}" "${user}@${host}" "${cmd}"
}

layer_ssh_scp_to() {
  local port="$1" user="$2" host="$3" local_path="$4" remote_path="$5"
  local -a scp_extra=()
  if [[ -n "${LAYER_SSH_CTRL_PATH:-}" ]]; then
    scp_extra=(-o "ControlPath=${LAYER_SSH_CTRL_PATH}")
  else
    scp_extra=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new)
  fi
  scp -q -P "${port}" "${scp_extra[@]}" "${local_path}" "${user}@${host}:${remote_path}"
}

layer_ssh_session_show_link() {
  local host="$1" port="$2" user="$3" local_v4="$4" peer_v4="$5"
  local local_name peer_name peer_seen
  local_name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo this-host)"
  peer_name="$(layer_ssh_cmd "${host}" "${port}" "${user}" "hostname -s 2>/dev/null || hostname" 2>/dev/null | tr -d '\r' | head -n1)"
  peer_seen="$(layer_ssh_cmd "${host}" "${port}" "${user}" "echo PHORMAL-LINK-OK" 2>/dev/null | tr -d '\r')"
  rule
  info "SSH for path test — ONE direction only (this host → peer):"
  info "  This server : ${local_name}  (${local_v4:-?})  ← phormal.sh runs HERE"
  info "  Peer server : ${user}@${host}:${port}  (${peer_v4})  ← outbound SSH target"
  [[ -n "${peer_name}" ]] && info "  Peer hostname: ${peer_name} (read via SSH; peer did NOT SSH back to you)"
  [[ "${peer_seen}" == *LINK-OK* ]] || warn "  Could not re-check peer over SSH control socket."
  info "  Tunnel tests run commands ON the peer through this link — not a second SSH session."
  rule
}

layer_ssh_peer_offer_root_login() {
  local ssh_user="$1" ans def
  LAYER_PEER_SUDO_LOGIN=0
  [[ "${ssh_user}" == "root" ]] && return 0
  if [[ "${ssh_user}" == "ubuntu" ]]; then
    info "Peer SSH user is ubuntu — kernel/tunnel probes on the peer need root."
    def="y"
  else
    info "Peer SSH user is not root (${ssh_user}) — path tests may need root on the peer."
    def="y"
  fi
  ans="$(ask "Run ALL peer commands as root via sudo -i? (y/n) [${def}]")"
  ans="${ans:-${def}}"
  if [[ "${ans}" =~ ^[Yy] ]]; then
    LAYER_PEER_SUDO_LOGIN=1
    info "Peer session will use sudo -i (root login shell) for every remote command."
  else
    info "Peer session will use sudo bash -c only (limited root — some probes may fail)."
  fi
}

layer_ssh_session_open() {
  local host="$1" port="$2" user="$3"
  local ctrl="/tmp/phormal-ssh-${user}@${host}-${port}-$$"
  LAYER_SSH_CTRL_PATH="${ctrl}"
  LAYER_PEER_SSH_READY=0
  LAYER_PEER_SSH_HOST="${host}"
  LAYER_PEER_SSH_PORT="${port}"
  LAYER_PEER_SSH_USER="${user}"

  if ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
      -p "${port}" "${user}@${host}" "echo PHORMAL-SSH-OK" 2>/dev/null | grep -q OK; then
    ssh -o BatchMode=yes -o ControlMaster=yes -o "ControlPath=${ctrl}" -o ControlPersist=600 \
      -o StrictHostKeyChecking=accept-new -p "${port}" -fN "${user}@${host}" 2>/dev/null || true
    if layer_ssh_cmd "${host}" "${port}" "${user}" "echo PHORMAL-SSH-OK" 2>/dev/null | grep -q OK; then
      good "Outbound SSH OK (key): this host → ${user}@${host}:${port}"
    else
      LAYER_SSH_CTRL_PATH=""
      fail "SSH control socket failed after key auth."
      return 1
    fi
  else
    info "This script will SSH from THIS machine to the peer — you do not open SSH on the peer yourself."
    info "Enter the peer password once below (reused for downloads, remote commands, paired pings)…"
    if ! ssh -o PreferredAuthentications=keyboard-interactive,password \
        -o ControlMaster=yes -o "ControlPath=${ctrl}" -o ControlPersist=600 \
        -o StrictHostKeyChecking=accept-new -p "${port}" \
        "${user}@${host}" "echo PHORMAL-SSH-OK"; then
      LAYER_SSH_CTRL_PATH=""
      fail "SSH from this host to ${user}@${host}:${port} failed — paired tests cannot run."
      return 1
    fi
    good "Outbound SSH OK: this host → ${user}@${host}:${port} (password accepted)"
  fi

  info "Holding until SSH control socket to peer is stable…"
  local i ok=0
  for i in $(seq 1 25); do
    if layer_ssh_cmd "${host}" "${port}" "${user}" "echo PHORMAL-SSH-READY" 2>/dev/null | grep -q READY; then
      ok=1
      break
    fi
    sleep 1
  done
  if [[ "${ok}" -ne 1 ]]; then
    LAYER_SSH_CTRL_PATH=""
    fail "SSH control socket to peer not ready — paired tests cannot run."
    return 1
  fi

  if [[ "${user}" != "root" ]]; then
    if [[ "${LAYER_PEER_SUDO_LOGIN:-0}" -eq 1 ]]; then
      info "Caching peer sudo for sudo -i (enter password if prompted)…"
      layer_ssh_cmd "${host}" "${port}" "${user}" "sudo -v" 2>/dev/null \
        || warn "Could not cache peer sudo — you may be prompted during tests"
      if layer_ssh_remote "${host}" "${port}" "${user}" \
          "test \$(id -u) -eq 0 && echo PHORMAL-SUDO-OK" 2>/dev/null | grep -q SUDO-OK; then
        good "Peer root via sudo -i OK (remote commands run as uid 0)."
      else
        warn "Peer sudo -i check failed — use root SSH or fix sudoers on peer"
      fi
    else
      info "Peer SSH user is not root — sudo on peer may be required (enter sudo password if prompted)…"
      if ! layer_ssh_cmd "${host}" "${port}" "${user}" "sudo -n true" 2>/dev/null; then
        layer_ssh_cmd "${host}" "${port}" "${user}" "sudo -v" 2>/dev/null \
          || warn "Could not cache peer sudo — kernel/meta probes may fail on peer"
      fi
      if ! layer_ssh_remote "${host}" "${port}" "${user}" "echo PHORMAL-SUDO-OK" 2>/dev/null | grep -q SUDO-OK; then
        warn "Peer sudo check failed — use root SSH or enable sudo -i when prompted"
      else
        good "Peer sudo OK (remote commands will run as root on peer)."
      fi
    fi
  fi

  LAYER_PEER_SSH_READY=1
  return 0
}

layer_ssh_session_close() {
  local host="$1" port="$2" user="$3"
  [[ -n "${LAYER_SSH_CTRL_PATH:-}" ]] || return 0
  ssh -o "ControlPath=${LAYER_SSH_CTRL_PATH}" -O exit -p "${port}" "${user}@${host}" 2>/dev/null || true
  LAYER_SSH_CTRL_PATH=""
}

# Run a command on the peer as root (sudo -i when enabled, else sudo bash -c).
layer_ssh_remote() {
  local host="$1" port="$2" user="$3" cmd="$4"
  if [[ "${user}" == "root" ]]; then
    layer_ssh_cmd "${host}" "${port}" "${user}" "${cmd}"
  elif [[ "${LAYER_PEER_SUDO_LOGIN:-0}" -eq 1 ]]; then
    layer_ssh_cmd "${host}" "${port}" "${user}" \
      "sudo -n -i bash -c $(printf '%q' "${cmd}")" 2>/dev/null \
      || layer_ssh_cmd "${host}" "${port}" "${user}" \
        "sudo -i bash -c $(printf '%q' "${cmd}")"
  else
    layer_ssh_cmd "${host}" "${port}" "${user}" \
      "sudo -n bash -c $(printf '%q' "${cmd}")" 2>/dev/null \
      || layer_ssh_cmd "${host}" "${port}" "${user}" \
        "sudo bash -c $(printf '%q' "${cmd}")"
  fi
}

layer_autotest_require_peer_ssh() {
  [[ "${LAYER_PEER_SSH_READY:-0}" -eq 1 ]] || {
    fail "Blocked: peer SSH session not ready — fix SSH before testing."
    return 1
  }
}

layer_ssh_peer_arch() {
  local host="$1" port="$2" user="$3" m
  m="$(layer_ssh_cmd "${host}" "${port}" "${user}" "uname -m" 2>/dev/null | tr -d '\r')"
  case "${m}" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *) return 1 ;;
  esac
}

layer_ssh_peer_apt_probe_deps() {
  local host="$1" port="$2" user="$3"
  layer_ssh_remote "${host}" "${port}" "${user}" \
    "export DEBIAN_FRONTEND=noninteractive
     apt-get update -qq 2>/dev/null || true
     apt-get install -y -qq python3 iproute2 netcat-openbsd curl ca-certificates tcpdump openssl 2>/dev/null || true" \
    >/dev/null 2>&1 || true
}

layer_ssh_ensure_binary_on_peer() {
  local ssh_host="$1" ssh_port="$2" ssh_user="$3"
  local dest="$4" verify_flag="$5" label="$6"
  shift 6
  local u peer_arch urls=("$@")

  if layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
      "test -x '${dest}' && '${dest}' ${verify_flag}" >/dev/null 2>&1; then
    info "  Peer ${label}: already installed"
    return 0
  fi

  info "  Peer ${label}: downloading on peer…"
  layer_ssh_peer_apt_probe_deps "${ssh_host}" "${ssh_port}" "${ssh_user}"

  for u in "${urls[@]}"; do
    [[ -n "${u}" ]] || continue
    if layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
        "mkdir -p '$(dirname "${dest}")'
         curl -fsSL --connect-timeout 20 --max-time 300 '${u}' -o '${dest}.dl'
         chmod +x '${dest}.dl'
         '${dest}.dl' ${verify_flag} >/dev/null 2>&1
         mv -f '${dest}.dl' '${dest}'" 2>/dev/null; then
      good "  Peer ${label}: installed (peer download)"
      return 0
    fi
  done

  if [[ -x "${dest}" ]] && "${dest}" ${verify_flag} >/dev/null 2>&1; then
    info "  Peer ${label}: copying from this host via scp…"
    layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
      "mkdir -p '$(dirname "${dest}")'" 2>/dev/null || true
    if layer_ssh_scp_to "${ssh_port}" "${ssh_user}" "${ssh_host}" "${dest}" "${dest}.part" 2>/dev/null \
      && layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
        "mv -f '${dest}.part' '${dest}' && chmod +x '${dest}' && '${dest}' ${verify_flag} >/dev/null 2>&1" 2>/dev/null; then
      good "  Peer ${label}: installed (scp from this host)"
      return 0
    fi
  fi

  warn "  Peer ${label}: install failed"
  return 1
}

layer_build_engine_urls() {
  local kind="$1" arch="$2"
  local mirror urls=()
  [[ -n "${arch}" ]] || arch="$(machine_arch 2>/dev/null || echo amd64)"
  case "${BINARY_SOURCE:-mirror}" in
    manual) return 0 ;;
    github)
      case "${kind}" in
        fwd)     urls+=("$(gost_upstream_tarball_url "${arch}")") ;;
        relay)   urls+=("$(hysteria_upstream_url "${arch}")") ;;
        reverse)
          mirror="$(mirror_reverse_url "${arch}" 2>/dev/null || true)"
          [[ -n "${mirror}" ]] && urls+=("${mirror}")
          ;;
      esac
      ;;
    *)
      case "${kind}" in
        fwd)
          mirror="$(mirror_fwd_url "${arch}" 2>/dev/null || true)"
          [[ -n "${mirror}" ]] && urls+=("${mirror}")
          urls+=("$(gost_upstream_tarball_url "${arch}")")
          ;;
        relay)
          mirror="$(mirror_relay_url "${arch}" 2>/dev/null || true)"
          [[ -n "${mirror}" ]] && urls+=("${mirror}")
          urls+=("$(hysteria_upstream_url "${arch}")")
          ;;
        reverse)
          mirror="$(mirror_reverse_url "${arch}" 2>/dev/null || true)"
          [[ -n "${mirror}" ]] && urls+=("${mirror}")
          ;;
      esac
      ;;
  esac
  local u
  for u in "${urls[@]}"; do
    [[ -n "${u}" ]] && printf '%s\n' "${u}"
  done
}

layer_autotest_prepare_hosts() {
  local only="$1" ssh_host="$2" ssh_port="$3" ssh_user="$4"
  local arch peer_arch urls=() u

  layer_autotest_require_peer_ssh || return 1
  PATH_TEST_FORCE_PICK=1
  BINARY_SOURCE=""
  choose_binary_source
  unset PATH_TEST_FORCE_PICK

  rule
  info "Preparing this host and peer (download missing engines before tests)…"
  rule
  apt_install_quiet python3 tcpdump iproute2 openssh-client netcat-openbsd dnsutils curl wget ca-certificates 2>/dev/null || true
  layer_ssh_peer_apt_probe_deps "${ssh_host}" "${ssh_port}" "${ssh_user}"

  arch="$(machine_arch 2>/dev/null || echo amd64)"
  peer_arch="$(layer_ssh_peer_arch "${ssh_host}" "${ssh_port}" "${ssh_user}" 2>/dev/null || echo "${arch}")"

  if [[ "${only}" == "all" || "${only}" == *bridge* || "${only}" == *sit* ]]; then
    install_engine || warn "Local Phormal Bridge engine download failed — continuing"
    urls=()
    while IFS= read -r u; do [[ -n "${u}" ]] && urls+=("${u}"); done < <(layer_build_engine_urls fwd "${peer_arch}")
    layer_ssh_ensure_binary_on_peer "${ssh_host}" "${ssh_port}" "${ssh_user}" \
      "${FWD_BIN}" "-V" "Phormal Bridge engine" "${urls[@]}" 2>/dev/null || true
  fi

  if [[ "${only}" == "all" || "${only}" == *relay* || "${only}" == *udp* || "${only}" == *raw* ]]; then
    install_relay_engine || warn "Local Phormal Relay engine download failed — continuing"
    urls=()
    while IFS= read -r u; do [[ -n "${u}" ]] && urls+=("${u}"); done < <(layer_build_engine_urls relay "${peer_arch}")
    layer_ssh_ensure_binary_on_peer "${ssh_host}" "${ssh_port}" "${ssh_user}" \
      "${RELAY_BIN}" "version" "Phormal Relay engine" "${urls[@]}" 2>/dev/null || true
  fi

  if [[ "${only}" == "all" || "${only}" == *reverse* || "${only}" == *tcp* ]]; then
    install_reverse_engine || warn "Local Phormal Reverse engine download failed — continuing"
    urls=()
    while IFS= read -r u; do [[ -n "${u}" ]] && urls+=("${u}"); done < <(layer_build_engine_urls reverse "${peer_arch}")
    layer_ssh_ensure_binary_on_peer "${ssh_host}" "${ssh_port}" "${ssh_user}" \
      "${REVERSE_BIN}" "--version" "Phormal Reverse engine" "${urls[@]}" 2>/dev/null || true
  fi

  printf '\n'
}

layer_probe_py() {
  cat <<'PY'
import socket, struct, sys, time, os, subprocess, json

def csum(d):
    if len(d) % 2: d += b'\x00'
    s = sum(struct.unpack('!%dH' % (len(d) // 2), d))
    while s >> 16: s = (s & 0xffff) + (s >> 16)
    return ~s & 0xffff

def udp_probe(bind_port, peer_ip, peer_port, size, count=8, timeout=8):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('0.0.0.0', bind_port))
    s.settimeout(0.4)
    sent = recv = 0
    tag = os.urandom(4)
    for i in range(count):
        payload = tag + struct.pack('!HH', size, i) + b'P' * max(0, size - 8)
        try:
            s.sendto(payload[:size], (peer_ip, peer_port))
            sent += 1
        except OSError:
            pass
        t0 = time.time()
        while time.time() - t0 < timeout / count:
            try:
                data, _ = s.recvfrom(2048)
                if data.startswith(tag):
                    recv += 1
                    break
            except socket.timeout:
                break
    s.close()
    return sent, recv

def icmp_probe(src, dst, count=6):
    s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_RAW)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_HDRINCL, 1)
    sent = 0
    for seq in range(count):
        icmp = struct.pack('!BBHHH', 8, 0, 0, seq, 0x7048)
        c = csum(icmp); icmp = struct.pack('!BBHHH', 8, 0, c, seq, 0x7048)
        ip = struct.pack('!BBHHHBBH4s4s', 0x45, 0, 20 + len(icmp), 0x4242, 0, 64, 1, 0,
                         socket.inet_aton(src), socket.inet_aton(dst))
        c = csum(ip); ip = struct.pack('!BBHHHBBH4s4s', 0x45, 0, 20 + len(icmp), 0x4242, 0, 64, 1, c,
                                       socket.inet_aton(src), socket.inet_aton(dst))
        try:
            s.sendto(ip + icmp, (dst, 0)); sent += 1
        except OSError:
            pass
        time.sleep(0.15)
    s.close()
    return sent

if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'udp':
        print(json.dumps(dict(zip(('sent','recv'), udp_probe(int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), int(sys.argv[5]))))))
    elif cmd == 'icmp_send':
        print(icmp_probe(sys.argv[2], sys.argv[3]))
    elif cmd == 'tcp_echo':
        # server or client handled externally
        pass
PY
}

layer_autotest_probe_begin() {
  printf '\n'
  info "▶ Testing ${1}…"
}

layer_autotest_record() {
  local label="$1" result="$2" conf="$3" note="$4"
  LAYER_TEST_ROWS+=("${label}|${result}|${conf}|${note}")
  case "${result}" in
    PASS)
      good "  ${label}: PASS [${conf}] — ${note}"
      ;;
    inconclusive)
      warn "  ${label}: inconclusive [${conf}] — ${note}"
      ;;
    *)
      fail "  ${label}: FAIL [${conf}] — ${note}"
      ;;
  esac
}

layer_autotest_pop_row() {
  local want="$1" i row a
  for i in "${!LAYER_TEST_ROWS[@]}"; do
    row="${LAYER_TEST_ROWS[i]}"
    a="${row%%|*}"
    [[ "${a}" == "${want}" ]] || continue
    unset 'LAYER_TEST_ROWS[i]'
    LAYER_TEST_ROWS=("${LAYER_TEST_ROWS[@]}")
    return 0
  done
  return 1
}

layer_relay_link_listening() {
  local listen="$1"
  if [[ "${listen}" == *-* ]]; then
    systemctl list-units 'phormal-relay@*' --state=active --no-legend 2>/dev/null | grep -q . \
      && pgrep -f "${RELAY_BIN}" >/dev/null 2>&1
    return $?
  fi
  ss -uln 2>/dev/null | grep -qE ":${listen}( |$)" \
    || ss -uln "sport = :${listen}" 2>/dev/null | grep -q "${listen}"
}

layer_peer_relay_active() {
  local ssh_host="$1" ssh_port="$2" ssh_user="$3"
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "systemctl list-units 'phormal-relay@*' --state=active --no-legend 2>/dev/null | grep -q . && echo yes || echo no" \
    2>/dev/null | tr -d '\r' | grep -q yes
}

layer_autotest_row_get() {
  local want="$1" field="$2" row a b c d
  for row in "${LAYER_TEST_ROWS[@]}"; do
    IFS='|' read -r a b c d <<<"${row}"
    [[ "${a}" == "${want}" ]] || continue
    case "${field}" in
      result) printf '%s' "${b}" ;;
      conf)   printf '%s' "${c}" ;;
      note)   printf '%s' "${d}" ;;
    esac
    return 0
  done
  return 1
}

layer_autotest_copy_row() {
  local from="$1" to="$2" note_suffix="$3" force_conf="${4:-}"
  local res conf note
  res="$(layer_autotest_row_get "${from}" result)" || return 1
  conf="$(layer_autotest_row_get "${from}" conf)"
  note="$(layer_autotest_row_get "${from}" note)"
  [[ -n "${force_conf}" ]] && conf="${force_conf}"
  layer_autotest_record "${to}" "${res}" "${conf}" "${note}${note_suffix}"
}

# SIT/GRE ifaces are often "state UNKNOWN" while UP — check kernel UP flag + v6 address.
bridge_iface_operational() {
  local iface="$1" self_core="$2"
  [[ -n "${iface}" ]] || return 1
  ip link show "${iface}" 2>/dev/null | grep -qE 'UP|LOWER_UP' || return 1
  if [[ -n "${self_core}" ]]; then
    ip -6 addr show dev "${iface}" 2>/dev/null | grep -qi "${self_core%%/*}"
  else
    ip -6 addr show dev "${iface}" 2>/dev/null | grep -q 'inet6'
  fi
}

layer_route_src_to() {
  ip -4 route get "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

layer_detect_public_v4() {
  local n v route_ip peer_hint="${1:-1.1.1.1}"
  while read -r n; do
    [[ -n "${n}" ]] || continue
    v="$(bmeta_get "${n}" LOCAL_V4)"
    valid_ipv4 "${v}" && { printf '%s' "${v}"; return 0; }
  done < <(bridge_instances 2>/dev/null)
  route_ip="$(layer_route_src_to "${peer_hint}")"
  [[ -n "${route_ip}" ]] && { printf '%s' "${route_ip}"; return 0; }
  layer_route_src_to "1.1.1.1"
}

layer_local_sit_to_peer() {
  local peer_v4="$1" line iface detail
  while IFS= read -r line; do
    iface="${line#*: }"; iface="${iface%%@*}"
    [[ -n "${iface}" ]] || continue
    detail="$(ip -d link show "${iface}" 2>/dev/null)" || continue
    [[ "${detail}" == *"remote ${peer_v4}"* ]] || continue
    ip link show "${iface}" 2>/dev/null | grep -qE 'UP|LOWER_UP' && return 0
  done < <(ip -o link show type sit 2>/dev/null || true)
  return 1
}

layer_local_bridge_meta_to_peer() {
  local peer_v4="$1" n remote iface role self_core st
  while read -r n; do
    [[ -n "${n}" ]] || continue
    remote="$(bmeta_get "${n}" REMOTE_V4)"
    [[ "${remote}" == "${peer_v4}" ]] || continue
    iface="$(bmeta_get "${n}" IFACE)"
    role="$(bmeta_get "${n}" ROLE)"
    self_core="$(bmeta_get "${n}" SELF_CORE)"
    if bridge_iface_operational "${iface}" "${self_core}" \
      || bridge_core_running "${n}" \
      || layer_local_sit_to_peer "${peer_v4}"; then
      st=up
    else
      st=stopped
    fi
    printf '%s|%s|%s|%s' "${n}" "${role}" "${iface}" "${st}"
    return 0
  done < <(bridge_instances 2>/dev/null)
  return 1
}

layer_ssh_peer_bridge_lookup() {
  local toward_v4="$1" ssh_host="$2" ssh_port="$3" ssh_user="$4"
  [[ -n "${toward_v4}" ]] || { printf 'NONE'; return 0; }
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "toward='${toward_v4}'
     found_stop=
     while IFS= read -r f; do
       [[ -f \"\${f}\" ]] || continue
       r=\$(grep -E '^REMOTE_V4=' \"\${f}\" | head -n1 | cut -d= -f2-)
       [[ \"\${r}\" == \"\${toward}\" ]] || continue
       i=\$(grep -E '^IFACE=' \"\${f}\" | head -n1 | cut -d= -f2-)
       role=\$(grep -E '^ROLE=' \"\${f}\" | head -n1 | cut -d= -f2-)
       name=\$(basename \"\$(dirname \"\${f}\")\")
       if ip link show \"\${i}\" 2>/dev/null | grep -qE 'UP|LOWER_UP'; then
         echo \"UP:\${name}:\${role}:\${i}\"
         exit 0
       fi
       found_stop=\"STOP:\${name}:\${role}:\${i}\"
     done < <(find ${BRIDGE_DIR} -mindepth 2 -maxdepth 2 -name meta.conf 2>/dev/null)
     ip -o link show type sit 2>/dev/null | while read -r _ _ iface _; do
       iface=\${iface%%@*}
       ip -d link show \"\${iface}\" 2>/dev/null | grep -q \"remote \${toward}\" \
         && ip link show \"\${iface}\" 2>/dev/null | grep -qE 'UP|LOWER_UP' \
         && echo \"UP:sit:\${iface}\" && exit 0
     done
     [[ -n \"\${found_stop}\" ]] && echo \"\${found_stop}\" && exit 0
     echo NONE" 2>/dev/null | tr -d '\r' | head -n1
}

layer_ssh_peer_relay_lookup() {
  local toward_v4="$1" ssh_host="$2" ssh_port="$3" ssh_user="$4"
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "toward='${toward_v4}'
     found_stop=
     while IFS= read -r f; do
       [[ -f \"\${f}\" ]] || continue
       name=\$(basename \"\$(dirname \"\${f}\")\")
       role=\$(grep -E '^ROLE=' \"\${f}\" | head -n1 | cut -d= -f2-)
       remote=\$(grep -E '^REMOTE_V4=' \"\${f}\" | head -n1 | cut -d= -f2-)
       listen=\$(grep -E '^LISTEN=' \"\${f}\" | head -n1 | cut -d= -f2-)
       listen=\${listen:-443}
       st=\$(systemctl is-active phormal-relay@\${name}.service 2>/dev/null || true)
       st=\${st:-down}
       if [[ \"\${st}\" == active ]]; then
         if [[ \"\${role}\" == entry && \"\${remote}\" == \"\${toward}\" ]]; then
           echo \"UP:entry:\${name}:\${remote}:\${listen}\"; exit 0
         fi
         if [[ \"\${role}\" == exit ]]; then
           echo \"UP:exit:\${name}:\${listen}\"; exit 0
         fi
       fi
       if [[ \"\${role}\" == entry && \"\${remote}\" == \"\${toward}\" ]]; then
         found_stop=\"STOP:entry:\${name}:\${remote}\"
       fi
       if [[ \"\${role}\" == exit ]]; then
         found_stop=\"STOP:exit:\${name}:\${listen}\"
       fi
     done < <(find ${RELAY_DIR} -mindepth 2 -maxdepth 2 -name meta.conf 2>/dev/null)
     [[ -n \"\${found_stop}\" ]] && echo \"\${found_stop}\" && exit 0
     echo NONE" 2>/dev/null | tr -d '\r' | head -n1
}

layer_bridge_start_hint() {
  local name="$1" role="$2"
  if [[ "${role}" == "entry" ]]; then
    printf 'systemctl enable --now phormal-core@%s phormal-guard@%s phormal-bfwd@%s' "${name}" "${name}" "${name}"
  else
    printf 'systemctl enable --now phormal-core@%s phormal-guard@%s' "${name}" "${name}"
  fi
}

layer_ssh_peer_bridge_meta() {
  local toward_v4="$1" ssh_host="$2" ssh_port="$3" ssh_user="$4"
  [[ -n "${toward_v4}" ]] || { printf 'NONE'; return 0; }
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "toward='${toward_v4}'
     while IFS= read -r f; do
       [[ -f \"\${f}\" ]] || continue
       r=\$(grep -E '^REMOTE_V4=' \"\${f}\" | head -n1 | cut -d= -f2-)
       [[ \"\${r}\" == \"\${toward}\" ]] || continue
       name=\$(basename \"\$(dirname \"\${f}\")\")
       role=\$(grep -E '^ROLE=' \"\${f}\" | head -n1 | cut -d= -f2-)
       iface=\$(grep -E '^IFACE=' \"\${f}\" | head -n1 | cut -d= -f2-)
       self_core=\$(grep -E '^SELF_CORE=' \"\${f}\" | head -n1 | cut -d= -f2-)
       peer_core=\$(grep -E '^PEER_CORE=' \"\${f}\" | head -n1 | cut -d= -f2-)
       if ip link show \"\${iface}\" 2>/dev/null | grep -qE 'UP|LOWER_UP'; then
         st=up
       else
         st=stopped
       fi
       echo \"\${name}|\${role}|\${iface}|\${st}|\${self_core}|\${peer_core}\"
       exit 0
     done < <(find ${BRIDGE_DIR} -mindepth 2 -maxdepth 2 -name meta.conf 2>/dev/null)
     echo NONE" 2>/dev/null | tr -d '\r' | head -n1
}

layer_ssh_peer_relay_meta() {
  local toward_v4="$1" ssh_host="$2" ssh_port="$3" ssh_user="$4"
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "toward='${toward_v4}'
     while IFS= read -r f; do
       [[ -f \"\${f}\" ]] || continue
       name=\$(basename \"\$(dirname \"\${f}\")\")
       role=\$(grep -E '^ROLE=' \"\${f}\" | head -n1 | cut -d= -f2-)
       remote=\$(grep -E '^REMOTE_V4=' \"\${f}\" | head -n1 | cut -d= -f2-)
       listen=\$(grep -E '^LISTEN=' \"\${f}\" | head -n1 | cut -d= -f2-)
       listen=\${listen:-443}
       st=\$(systemctl is-active phormal-relay@\${name}.service 2>/dev/null || true)
       st=\${st:-stopped}
       [[ \"\${st}\" == active ]] && st=up || st=stopped
       if [[ \"\${role}\" == entry && \"\${remote}\" == \"\${toward}\" ]]; then
         echo \"\${name}|\${role}|\${st}|\${remote}|\${listen}\"
         exit 0
       fi
       if [[ \"\${role}\" == exit ]]; then
         echo \"\${name}|\${role}|\${st}||\${listen}\"
         exit 0
       fi
     done < <(find ${RELAY_DIR} -mindepth 2 -maxdepth 2 -name meta.conf 2>/dev/null)
     echo NONE" 2>/dev/null | tr -d '\r' | head -n1
}

layer_bridge_start_local() {
  local name="$1" role="$2"
  if [[ "${role}" == "entry" ]]; then
    systemctl start "$(bcore_svc "${name}")" "$(bguard_svc "${name}")" "$(bfwd_svc "${name}")" 2>/dev/null \
      || systemctl start "$(bcore_svc "${name}")" 2>/dev/null || true
  else
    systemctl start "$(bcore_svc "${name}")" "$(bguard_svc "${name}")" 2>/dev/null \
      || systemctl start "$(bcore_svc "${name}")" 2>/dev/null || true
  fi
  sleep 2
}

layer_bridge_start_remote() {
  local name="$1" role="$2" ssh_host="$3" ssh_port="$4" ssh_user="$5"
  if [[ "${role}" == "entry" ]]; then
    layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
      "systemctl start phormal-core@${name} phormal-guard@${name} phormal-bfwd@${name}" 2>/dev/null || true
  else
    layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
      "systemctl start phormal-core@${name} phormal-guard@${name}" 2>/dev/null || true
  fi
  sleep 2
}

layer_bridge_local_iface_state() {
  local name="$1" iface self_core
  iface="$(bmeta_get "${name}" IFACE)"
  self_core="$(bmeta_get "${name}" SELF_CORE)"
  bridge_iface_operational "${iface}" "${self_core}" && printf up || printf stopped
}

layer_bridge_bidir_ping6() {
  local peer_core="$1" self_core="$2" ssh_host="$3" ssh_port="$4" ssh_user="$5"
  local local_ok=0 peer_ok=0
  ping6 -c 3 -W 3 "${peer_core}" >/dev/null 2>&1 &
  local pa=$!
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "ping6 -c 3 -W 3 ${self_core}" >/dev/null 2>&1 &
  local pb=$!
  wait "${pa}" 2>/dev/null && local_ok=1
  wait "${pb}" 2>/dev/null && peer_ok=1
  printf '%s|%s' "${local_ok}" "${peer_ok}"
}

layer_autotest_verify_peer_pairing() {
  local local_v4="$1" peer_v4="$2" ssh_host="$3" ssh_port="$4" ssh_user="$5"
  local peer_bridge peer_relay n remote role peer_err=0
  layer_autotest_require_peer_ssh || return 1
  peer_bridge="$(layer_ssh_peer_bridge_meta "${local_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}")"
  [[ -z "${peer_bridge}" ]] && peer_err=1
  peer_relay="$(layer_ssh_peer_relay_meta "${local_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}")"
  info "Peer pairing check (meta on this host + on peer via ONE-WAY SSH) — ${local_v4} ↔ ${peer_v4}:"
  if layer_local_bridge_meta_to_peer "${peer_v4}" >/dev/null 2>&1; then
    info "  Bridge: this host has meta toward ${peer_v4}"
  else
    warn "  Bridge: no meta on THIS host toward ${peer_v4}"
  fi
  case "${peer_bridge}" in
    NONE|'')
      if [[ "${peer_err}" -eq 1 ]]; then
        warn "  Bridge: could not read peer config (SSH/sudo?) — use root SSH or NOPASSWD sudo on peer"
      else
        warn "  Bridge: peer has no meta toward ${local_v4} — menu 3 on kharej / menu 4 on Iran"
      fi
      ;;
    *)
      info "  Bridge: peer has link '${peer_bridge%%|*}' toward ${local_v4}"
      ;;
  esac
  while read -r n; do
    [[ -n "${n}" ]] || continue
    remote="$(imeta_get "${n}" REMOTE_V4)"
    role="$(imeta_get "${n}" ROLE)"
    listen="$(imeta_get "${n}" LISTEN)"; listen="${listen:-443}"
    if [[ "${role}" == entry && "${remote}" == "${peer_v4}" ]]; then
      info "  Relay: this host has entry '${n}' toward ${peer_v4} ($(relay_svc_state "${n}"))"
    elif [[ "${role}" == exit ]]; then
      info "  Relay: this host has exit '${n}' on :${listen} ($(relay_svc_state "${n}"))"
    fi
  done < <(relay_instances 2>/dev/null)
  case "${peer_relay}" in
    NONE|'') ;;
    *)
      info "  Relay: peer has '${peer_relay%%|*}' (${peer_relay#*|*|}) toward this path"
      ;;
  esac
}

bridge_core_running() {
  local name="$1" st
  st="$(bcore_state "${name}")"
  [[ "${st}" == "active" || "${st}" == "running" ]]
}

layer_bridge_matches_peer() {
  local remote="$1" peer_v4="$2"
  [[ "${remote}" == "${peer_v4}" ]]
}

layer_bridge_has_peer() {
  local peer_v4="$1" n remote
  while read -r n; do
    [[ -n "${n}" ]] || continue
    remote="$(bmeta_get "${n}" REMOTE_V4)"
    layer_bridge_matches_peer "${remote}" "${peer_v4}" && return 0
  done < <(bridge_instances)
  return 1
}

layer_peer_bridge_active() {
  local local_v4="$1" ssh_host="$2" ssh_port="$3" ssh_user="$4"
  [[ -n "${local_v4}" ]] || return 1
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "for f in ${BRIDGE_DIR}/*/meta.conf; do
       [[ -f \"\${f}\" ]] || continue
       r=\$(grep -E '^REMOTE_V4=' \"\${f}\" | head -n1 | cut -d= -f2-)
       [[ \"\${r}\" == \"${local_v4}\" ]] || continue
       i=\$(grep -E '^IFACE=' \"\${f}\" | head -n1 | cut -d= -f2-)
       ip link show \"\${i}\" 2>/dev/null | grep -q UP && echo yes && exit 0
     done
     echo no" 2>/dev/null | tr -d '\r' | grep -q yes
}

layer_peer_bridge_reachable() {
  local link_local_v4="$1" local_v4="$2" ssh_host="$3" ssh_port="$4" ssh_user="$5"
  layer_peer_bridge_active "${link_local_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}" && return 0
  layer_peer_bridge_active "${local_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}"
}

layer_autotest_print_table() {
  local row
  rule
  printf '  %-28s %-10s %-10s %s\n' "PHORMAL PRODUCT" "RESULT" "CONFIDENCE" "NOTE"
  rule
  for row in "${LAYER_TEST_ROWS[@]}"; do
    IFS='|' read -r a b c d <<<"${row}"
    printf '  %-28s %-10s %-10s %s\n' "${a}" "${b}" "${c}" "${d}"
  done
  rule
}

layer_autotest_last_result() {
  local key="$1" row a b c d
  [[ ${#LAYER_TEST_ROWS[@]} -gt 0 ]] || return 1
  row="${LAYER_TEST_ROWS[$((${#LAYER_TEST_ROWS[@]}-1))]}"
  IFS='|' read -r a b c d <<<"${row}"
  case "${key}" in
    result) printf '%s' "${b}" ;;
    conf)   printf '%s' "${c}" ;;
    note)   printf '%s' "${d}" ;;
    *)      printf '%s' "${b}" ;;
  esac
}

layer_autotest_mirror_row() {
  local label="$1" note_suffix="$2" res conf note
  res="$(layer_autotest_last_result result)"
  conf="$(layer_autotest_last_result conf)"
  note="$(layer_autotest_last_result note)"
  LAYER_TEST_ROWS+=("${label}|${res}|${conf}|${note}${note_suffix}")
  info "  ${label}: ${res} [${conf}] — ${note}${note_suffix}"
}

layer_autotest_recommendation() {
  local row product result menu_hint any=0
  rule
  info "Menu mapping (PASS products only)"
  rule
  for row in "${LAYER_TEST_ROWS[@]}"; do
    IFS='|' read -r product result _ _ <<<"${row}"
    [[ "${result}" == "PASS" ]] || continue
    any=1
    case "${product}" in
      "Phormal Bridge")       menu_hint="options 2–5 (Bridge)" ;;
      "Phormal Relay"*)       menu_hint="options 6–9 (Relay)" ;;
      "Phormal Reverse")      menu_hint="options 10–12 (Reverse)" ;;
      "Phormal GRE")          menu_hint="options 13–15 (GRE)" ;;
      "Phormal GRE alt")   menu_hint="options 13–15 (GRE alternate)" ;;
      "Phormal Echo")         menu_hint="options 16–18 (Echo)" ;;
      "Phormal Raw")          menu_hint="options 19–21 (Raw)" ;;
      *)                      menu_hint="see menu" ;;
    esac
    printf '  %-28s → %s\n' "${product}" "${menu_hint}"
  done
  [[ ${any} -eq 0 ]] && warn "No product passed — review FAIL rows above."
  rule
}

layer_autotest_conf_score() {
  case "$1" in
    high) printf '3' ;;
    med)  printf '2' ;;
    *)    printf '1' ;;
  esac
}

layer_autotest_product_rank() {
  case "$1" in
    "Phormal Relay")        printf '92' ;;
    "Phormal Bridge")       printf '88' ;;
    "Phormal GRE")          printf '80' ;;
    "Phormal GRE alt")  printf '79' ;;
    "Phormal Reverse")      printf '75' ;;
    "Phormal Echo")         printf '70' ;;
    "Phormal Raw")          printf '65' ;;
    *)                      printf '50' ;;
  esac
}

layer_autotest_verdict() {
  local row product result conf note best="" best_score=0 score rank menu_hint
  local -a pass_rows=()
  rule
  info "Verdict — which Phormal product to use"
  rule
  for row in "${LAYER_TEST_ROWS[@]}"; do
    IFS='|' read -r product result conf note <<<"${row}"
    case "${result}" in
      PASS)
        pass_rows+=("${row}")
        score="$(layer_autotest_conf_score "${conf}")"
        rank="$(layer_autotest_product_rank "${product}")"
        score=$(( score * 100 + rank ))
        if [[ "${score}" -gt "${best_score}" ]]; then
          best_score="${score}"
          best="${product}|${conf}|${note}"
        fi
        ;;
      inconclusive)
        warn "  ${product}: inconclusive — ${note}"
        ;;
      *)
        fail "  ${product}: not recommended — ${note}"
        ;;
    esac
  done
  if [[ ${#pass_rows[@]} -gt 0 ]]; then
    info "Products that passed (best first for real tunnel traffic):"
    printf '%s\n' "${pass_rows[@]}" | while IFS='|' read -r product result conf note; do
      printf '    %-28s [%s] %s\n' "${product}" "${conf}" "${note}"
    done
  fi
  if [[ -n "${best}" ]]; then
    IFS='|' read -r product conf note <<<"${best}"
    case "${product}" in
      "Phormal Bridge")       menu_hint="2–5 (Bridge)" ;;
      "Phormal Relay")        menu_hint="6–9 (Relay)" ;;
      "Phormal Reverse")      menu_hint="10–12 (Reverse)" ;;
      "Phormal GRE"|"Phormal GRE alt") menu_hint="13–15 (GRE)" ;;
      "Phormal Echo")         menu_hint="16–18 (Echo)" ;;
      "Phormal Raw")          menu_hint="19–21 (Raw)" ;;
      *) menu_hint="see menu" ;;
    esac
    printf '\n'
    good "BEST CHOICE: ${product}"
    info "  Confidence : ${conf}"
    info "  Why        : ${note}"
    info "  Use menu   : ${menu_hint}"
  else
    fail "No product passed on this path — try Phormal GRE or Phormal Echo (peer may need root/sudo for Bridge path test)."
  fi
  rule
  info "Run option 1 when you add a new peer — then pick the BEST CHOICE from the menu."
}

layer_tunnel_modprobe() {
  local mode="$1"
  case "${mode}" in
    sit)  modprobe sit 2>/dev/null || true ;;
    gre)  modprobe gre 2>/dev/null || true; modprobe ip_gre 2>/dev/null || true ;;
    ipip) modprobe ipip 2>/dev/null || true; modprobe ip_tunnel 2>/dev/null || true ;;
  esac
}

layer_kernel_tune_for_tunnel() {
  local iface="$1"
  sysctl -qw net.ipv4.conf.all.rp_filter=0 \
    net.ipv4.conf.default.rp_filter=0 \
    "net.ipv4.conf.${iface}.rp_filter=0" \
    net.ipv4.ip_forward=1 2>/dev/null || true
  iptables -C INPUT -p gre -j ACCEPT 2>/dev/null || iptables -I INPUT -p gre -j ACCEPT 2>/dev/null || true
  iptables -C INPUT -p 4 -j ACCEPT 2>/dev/null || iptables -I INPUT -p 4 -j ACCEPT 2>/dev/null || true
}

layer_kernel_add_tunnel() {
  local iface="$1" mode="$2" lip="$3" rip="$4" gkey="$5"
  case "${mode}" in
    gre)
      layer_local_root_run "ip link del ${iface} 2>/dev/null; \
        (ip link add ${iface} type gre remote ${rip} local ${lip} ttl 64 key ${gkey} 2>/dev/null || \
         ip tunnel add ${iface} mode gre remote ${rip} local ${lip} ttl 64 key ${gkey})" 2>/dev/null
      ;;
    ipip)
      layer_local_root_run "ip link del ${iface} 2>/dev/null; \
        (ip link add ${iface} type ipip remote ${rip} local ${lip} ttl 64 2>/dev/null || \
         ip tunnel add ${iface} mode ipip remote ${rip} local ${lip} ttl 64)" 2>/dev/null
      ;;
    sit)
      layer_local_root_run "ip link del ${iface} 2>/dev/null; \
        (ip link add ${iface} type sit remote ${rip} local ${lip} ttl 64 2>/dev/null || \
         ip tunnel add ${iface} mode sit remote ${rip} local ${lip} ttl 64)" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

layer_kernel_remote_tunnel_cmd() {
  local iface="$1" mode="$2" lip="$3" rip="$4" gkey="$5" lpriv="$6" rpriv="$7"
  local add_cmd tune_cmd
  tune_cmd="sysctl -qw net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0 \
    net.ipv4.conf.${iface}.rp_filter=0 net.ipv4.ip_forward=1 2>/dev/null; \
    iptables -C INPUT -p gre -j ACCEPT 2>/dev/null || iptables -I INPUT -p gre -j ACCEPT 2>/dev/null; \
    iptables -C INPUT -p 4 -j ACCEPT 2>/dev/null || iptables -I INPUT -p 4 -j ACCEPT 2>/dev/null"
  case "${mode}" in
    gre)
      add_cmd="ip link del ${iface} 2>/dev/null; \
        (ip link add ${iface} type gre remote ${lip} local ${rip} ttl 64 key ${gkey} 2>/dev/null || \
         ip tunnel add ${iface} mode gre remote ${lip} local ${rip} ttl 64 key ${gkey}) && \
        ip link set ${iface} up && ip addr add ${rpriv}/30 dev ${iface}"
      ;;
    ipip)
      add_cmd="ip link del ${iface} 2>/dev/null; \
        (ip link add ${iface} type ipip remote ${lip} local ${rip} ttl 64 2>/dev/null || \
         ip tunnel add ${iface} mode ipip remote ${lip} local ${rip} ttl 64) && \
        ip link set ${iface} up && ip addr add ${rpriv}/30 dev ${iface}"
      ;;
    sit)
      add_cmd="ip link del ${iface} 2>/dev/null; \
        (ip link add ${iface} type sit remote ${lip} local ${rip} ttl 64 2>/dev/null || \
         ip tunnel add ${iface} mode sit remote ${lip} local ${rip} ttl 64) && \
        ip link set ${iface} up && ip addr add ${rpriv}/30 dev ${iface}"
      ;;
    *) return 1 ;;
  esac
  printf '%s; %s' "${add_cmd}" "${tune_cmd}"
}

layer_kernel_ping_via_tunnel() {
  local iface="$1" src="$2" dst="$3"
  ping -c 3 -W 3 -I "${src}" "${dst}" >/dev/null 2>&1 && return 0
  ping -c 3 -W 3 -I "${iface}" "${dst}" >/dev/null 2>&1 && return 0
  return 1
}

layer_local_root_run() {
  if [[ ${EUID} -eq 0 ]]; then
    bash -c "$1"
  else
    sudo bash -c "$1"
  fi
}

layer_test_bridge_sit_ipv6_probe() {
  local local_v4="$1" peer_v4="$2" ssh_host="$3" ssh_port="$4" ssh_user="$5"
  local iface="phmpb$$" prefix self6 peer6 ok=FAIL conf=high note="" local_ok=0 peer_ok=0

  layer_tunnel_modprobe sit
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" "modprobe sit 2>/dev/null || true" 2>/dev/null || true

  prefix="$(random_core_prefix)"
  self6="${prefix}::2"
  peer6="${prefix}::1"

  ip link del "${iface}" 2>/dev/null || true
  if ! layer_local_root_run "ip tunnel add ${iface} mode sit remote ${peer_v4} local ${local_v4} ttl 64 \
      && ip link set ${iface} up && ip -6 addr add ${self6}/64 dev ${iface}" 2>/dev/null; then
    layer_autotest_record "Phormal Bridge" "FAIL" "high" "local Bridge tunnel setup failed (${self6})"
    return 0
  fi

  if ! layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
      "ip link del ${iface} 2>/dev/null; ip tunnel add ${iface} mode sit remote ${local_v4} local ${peer_v4} ttl 64 \
       && ip link set ${iface} up && ip -6 addr add ${peer6}/64 dev ${iface}" 2>/dev/null; then
    ip link del "${iface}" 2>/dev/null || true
    layer_autotest_record "Phormal Bridge" "FAIL" "high" "peer Bridge tunnel setup failed (${peer6})"
    return 0
  fi

  sleep 2
  info "  Bidirectional ping6 on path-test Bridge IPv6 ${self6} ↔ ${peer6}…"
  ping6 -c 3 -W 3 "${peer6}" >/dev/null 2>&1 && local_ok=1
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "ping6 -c 3 -W 3 ${self6}" >/dev/null 2>&1 && peer_ok=1

  ip link del "${iface}" 2>/dev/null || true
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" "ip link del ${iface} 2>/dev/null" 2>/dev/null || true

  if [[ "${local_ok}" -eq 1 && "${peer_ok}" -eq 1 ]]; then
    ok=PASS; conf=high
    note="path test Bridge — bidirectional ping6 ${self6}↔${peer6}"
  elif [[ "${local_ok}" -eq 1 || "${peer_ok}" -eq 1 ]]; then
    ok=PASS; conf=med
    note="path test Bridge — one-way ping6 (local→peer:${local_ok} peer→local:${peer_ok})"
  else
    note="path test Bridge up but ping6 failed (path may block tunnel or IPv6)"
  fi
  layer_autotest_record "Phormal Bridge" "${ok}" "${conf}" "${note}"
}

layer_test_kernel_pair() {
  local mode="$1" label="$2" local_v4="$3" remote_v4="$4" ssh_host ssh_port ssh_user
  local iface="pht${mode}$$" lip rip lpriv rpriv ok=FAIL conf=high note="" rerr=""
  local gkey=$(( (RANDOM + $$) % 65535 )); [[ ${gkey} -eq 0 ]] && gkey=42
  ssh_host="$5"; ssh_port="$6"; ssh_user="$7"
  layer_autotest_require_peer_ssh || {
    layer_autotest_probe_begin "${label} probe"
    layer_autotest_record "${label}" "inconclusive" "low" "peer SSH not ready for paired tunnel probe"
    return 0
  }
  layer_autotest_probe_begin "${label} probe"
  lip="${local_v4}"; rip="${remote_v4}"
  lpriv="10.99.1.1"; rpriv="10.99.1.2"
  layer_tunnel_modprobe "${mode}"
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "modprobe ${mode} 2>/dev/null; modprobe sit 2>/dev/null; modprobe gre 2>/dev/null; \
     modprobe ipip 2>/dev/null; modprobe ip_tunnel 2>/dev/null" 2>/dev/null || true
  ip link del "${iface}" 2>/dev/null || true
  if ! layer_kernel_add_tunnel "${iface}" "${mode}" "${lip}" "${rip}" "${gkey}"; then
    note="local tunnel setup failed (need root/sudo)"
  fi
  if [[ -z "${note}" ]]; then
    layer_local_root_run "ip link set ${iface} up && ip addr add ${lpriv}/30 dev ${iface}" 2>/dev/null \
      || note="local tunnel iface up failed"
    layer_kernel_tune_for_tunnel "${iface}"
  fi
  if [[ -z "${note}" ]]; then
    rerr="$(layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
      "$(layer_kernel_remote_tunnel_cmd "${iface}" "${mode}" "${lip}" "${rip}" "${gkey}" "${lpriv}" "${rpriv}")" 2>&1)" \
      || note="remote tunnel probe failed (peer needs root/sudo)"
    [[ -n "${note}" && -n "${rerr}" ]] && note="${note}: ${rerr##*$'\n'}"
  fi
  if [[ -z "${note}" ]]; then
    sleep 3
    layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
      "ip link show ${iface} 2>/dev/null | grep -qE 'UP|LOWER_UP'" >/dev/null 2>&1 \
      || note="remote tunnel iface not UP after setup"
  fi
  if [[ -z "${note}" ]]; then
    local local_ok=0 peer_ok=0
    info "  [1/2] this→peer ping on ${label} (${lpriv}→${rpriv})…"
    layer_kernel_ping_via_tunnel "${iface}" "${lpriv}" "${rpriv}" && local_ok=1
    info "  [2/2] peer→this ping on ${label} (${rpriv}→${lpriv})…"
    layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
      "ping -c 3 -W 3 -I ${rpriv} ${lpriv} >/dev/null 2>&1 || ping -c 3 -W 3 -I ${iface} ${lpriv} >/dev/null 2>&1" \
      && peer_ok=1
    if [[ "${local_ok}" -eq 1 && "${peer_ok}" -eq 1 ]]; then
      ok=PASS
      note="bidirectional ping on ${label} (this→peer:${local_ok} peer→this:${peer_ok})"
    elif [[ "${local_ok}" -eq 1 || "${peer_ok}" -eq 1 ]]; then
      ok=PASS; conf=med
      note="one-way ping on ${label} (this→peer:${local_ok} peer→this:${peer_ok})"
    else
      note="no ping on ${label} tunnel (this→peer:${local_ok} peer→this:${peer_ok}) — path may be filtered"
    fi
  fi
  ip link del "${iface}" 2>/dev/null || true
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" "ip link del ${iface} 2>/dev/null" 2>/dev/null || true
  layer_autotest_record "${label}" "${ok}" "${conf}" "${note}"
}

layer_test_bridge_configured() {
  local peer_v4="$1" ssh_host="$2" ssh_port="$3" ssh_user="$4"
  local local_v4="$5"
  local info peer_meta ok=FAIL conf=high note hint started_any=0
  local n role iface lst peer_n peer_role peer_iface pst peer_self peer_peer
  local self_core peer_core local_ok peer_ok ping_res

  layer_autotest_probe_begin "Phormal Bridge (paired — both servers)"
  layer_autotest_require_peer_ssh || {
    layer_autotest_record "Phormal Bridge" "inconclusive" "low" "peer SSH not ready"
    return 0
  }
  info="$(layer_local_bridge_meta_to_peer "${peer_v4}" 2>/dev/null || true)"
  peer_meta="$(layer_ssh_peer_bridge_meta "${local_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}")"

  if [[ -z "${info}" && ( -z "${peer_meta}" || "${peer_meta}" == NONE ) ]]; then
    info "  No Bridge config — creating paired Bridge tunnel + internal IPv6 on both servers…"
    layer_test_bridge_sit_ipv6_probe "${local_v4}" "${peer_v4}" \
      "${ssh_host}" "${ssh_port}" "${ssh_user}"
    return 0
  fi

  if [[ -z "${info}" ]]; then
    IFS='|' read -r peer_n peer_role peer_iface pst peer_self peer_peer <<<"${peer_meta}"
    layer_autotest_record "Phormal Bridge" "inconclusive" "med" \
      "peer has Bridge '${peer_n}' (${peer_role}) toward ${local_v4} but THIS host has no matching link — add Bridge here (menu 3/4)"
    return 0
  fi

  if [[ -z "${peer_meta}" || "${peer_meta}" == NONE ]]; then
    IFS='|' read -r n role iface lst <<<"${info}"
    hint="$(layer_bridge_start_hint "${n}" "${role}")"
    layer_autotest_record "Phormal Bridge" "inconclusive" "med" \
      "local '${n}' (${role}) exists but peer has no Bridge toward ${local_v4} — configure peer first, then ${hint}"
    return 0
  fi

  IFS='|' read -r n role iface lst <<<"${info}"
  IFS='|' read -r peer_n peer_role peer_iface pst peer_self peer_peer <<<"${peer_meta}"
  self_core="$(bmeta_get "${n}" SELF_CORE)"
  peer_core="$(bmeta_get "${n}" PEER_CORE)"

  if [[ "${role}" == "${peer_role}" ]]; then
    warn "  Both sides report role '${role}' — Bridge expects entry on one host and exit on the other"
  fi
  if [[ -n "${self_core}" && -n "${peer_self}" ]]; then
    if [[ "${self_core%::*}::" != "${peer_self%::*}::" ]]; then
      warn "  IPv6 prefix mismatch (local ${self_core} vs peer ${peer_self}) — links may not be paired"
    fi
  fi

  if [[ "${lst}" == stopped ]]; then
    info "  Local link '${n}' stopped — starting Bridge on this host…"
    layer_bridge_start_local "${n}" "${role}"
    started_any=1
    lst="$(layer_bridge_local_iface_state "${n}")"
  fi
  if [[ "${pst}" == stopped ]]; then
    info "  Peer link '${peer_n}' stopped — starting Bridge on peer via SSH…"
    layer_bridge_start_remote "${peer_n}" "${peer_role}" "${ssh_host}" "${ssh_port}" "${ssh_user}"
    started_any=1
    peer_meta="$(layer_ssh_peer_bridge_meta "${local_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}")"
    if [[ -n "${peer_meta}" && "${peer_meta}" != NONE ]]; then
      IFS='|' read -r peer_n peer_role peer_iface pst peer_self peer_peer <<<"${peer_meta}"
    else
      pst=stopped
    fi
  fi
  [[ "${started_any}" -eq 1 ]] && sleep 2

  lst="$(layer_bridge_local_iface_state "${n}")"
  if [[ "${lst}" != up || "${pst}" != up ]]; then
    hint="$(layer_bridge_start_hint "${n}" "${role}")"
    layer_autotest_record "Phormal Bridge" "inconclusive" "med" \
      "paired Bridge needs both tunnel ifaces UP (local:${lst} peer:${pst}) — ${hint} on each host"
    return 0
  fi

  info "  Bidirectional ping6 on internal Bridge IPv6 (local→${peer_core}, peer→${self_core})…"
  ping_res="$(layer_bridge_bidir_ping6 "${peer_core}" "${self_core}" \
    "${ssh_host}" "${ssh_port}" "${ssh_user}")"
  IFS='|' read -r local_ok peer_ok <<<"${ping_res}"

  if [[ "${local_ok}" -eq 1 && "${peer_ok}" -eq 1 ]]; then
    ok=PASS; conf=high
    note="paired '${n}'↔'${peer_n}' — bidirectional ping6 ${self_core}↔${peer_core}"
  elif [[ "${local_ok}" -eq 1 || "${peer_ok}" -eq 1 ]]; then
    ok=PASS; conf=med
    note="paired link UP — one-way ping6 (local→peer:${local_ok} peer→local:${peer_ok})"
  else
    conf=med
    note="both Bridge tunnel ifaces UP but ping6 failed — check bridge key, entry forwarder, or firewall"
  fi
  layer_autotest_record "Phormal Bridge" "${ok}" "${conf}" "${note}"
}

layer_test_bridge_path() {
  local local_v4="$1" peer_v4="$2" ssh_host="$3" ssh_port="$4" ssh_user="$5"
  layer_test_bridge_configured "${peer_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}" "${local_v4}"
}

layer_test_udp_echo() {
  local peer="$1" ssh_host="$2" ssh_port="$3" ssh_user="$4" bind_port="$5" peer_port="$6" size="$7" label="$8"
  local listen res ok=FAIL conf=high note="" probe="/tmp/phormal-probe-$$.py" rjson="/tmp/phormal-probe-remote-$$.json"
  listen=$((peer_port + 1))
  layer_write_probe_py "${probe}"
  layer_ssh_scp_to "${ssh_port}" "${ssh_user}" "${ssh_host}" "${probe}" "/tmp/phormal-probe.py" 2>/dev/null || {
    rm -f "${probe}"; layer_autotest_record "${label}" "inconclusive" "low" "scp probe to peer failed"; return; }
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "timeout 20 python3 /tmp/phormal-probe.py udp ${listen} ${peer} ${peer_port} ${size} >${rjson}" 2>/dev/null &
  local rid=$!
  sleep 1
  res="$(python3 "${probe}" udp "${bind_port}" "${peer}" "${listen}" "${size}" 2>/dev/null || echo '{}')"
  wait "${rid}" 2>/dev/null || true
  local sent recv rsent rrecv
  sent="$(printf '%s' "${res}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sent',0))" 2>/dev/null || echo 0)"
  recv="$(printf '%s' "${res}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('recv',0))" 2>/dev/null || echo 0)"
  rsent="$(layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "python3 -c \"import json; print(json.load(open('${rjson}')).get('sent',0))\" 2>/dev/null || echo 0")"
  rrecv="$(layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "python3 -c \"import json; print(json.load(open('${rjson}')).get('recv',0))\" 2>/dev/null || echo 0")"
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" "rm -f /tmp/phormal-probe.py ${rjson}" 2>/dev/null || true
  rm -f "${probe}"
  if [[ "${sent}" -ge 3 && "${recv}" -ge 1 && "${rsent}" -ge 3 && "${rrecv}" -ge 1 ]]; then
    ok=PASS; note="UDP echo ${peer}:${peer_port} A->B ${recv}/${sent} B->A ${rrecv}/${rsent} size=${size}"
  else
    note="UDP echo ${peer}:${peer_port} A->B ${recv}/${sent} B->A ${rrecv}/${rsent} size=${size}"
    conf=med
  fi
  layer_autotest_record "${label}" "${ok}" "${conf}" "${note}"
}

layer_relay_journal_connect_hint() {
  local name="$1" hint
  hint="$(journalctl -u "$(relay_svc "${name}")" -n 20 --no-pager 2>/dev/null \
    | grep -oE 'connect error[^",}]*|failed to initialize[^",}]*' | tail -1 \
    | sed 's/^[[:space:]]*//' | head -c 120)"
  printf '%s' "${hint}"
}

layer_test_udp_port_open() {
  local host="$1" port="$2" hp
  hp="${port%-*}"
  [[ "${hp}" =~ ^[0-9]+$ ]] || return 1
  if command -v nc &>/dev/null; then
    nc -z -u -w 3 "${host}" "${hp}" 2>/dev/null && return 0
  fi
  timeout 3 bash -c "echo >/dev/udp/${host}/${hp}" 2>/dev/null && return 0
  return 1
}

layer_relay_probe_gen_tls() {
  local tls_dir="$1"
  local cert="${tls_dir}/cert.crt" key="${tls_dir}/cert.key"
  mkdir -p "${tls_dir}"
  [[ -f "${cert}" && -f "${key}" ]] && return 0
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "${key}" -out "${cert}" -days 1 -subj "/CN=phormal-probe" 2>/dev/null
}

layer_relay_probe_write_exit_yaml() {
  local file="$1" port="$2" auth="$3" obfs="$4" tls_rel="${5:-tls}"
  mkdir -p "$(dirname "${file}")" "$(dirname "${file}")/${tls_rel}" 2>/dev/null || return 1
  {
    echo "listen: :${port}"
    echo ""
    echo "tls:"
    echo "  cert: ${tls_rel}/cert.crt"
    echo "  key: ${tls_rel}/cert.key"
    echo ""
    echo "auth:"
    echo "  type: password"
    echo "  password: ${auth}"
    echo ""
    echo "obfs:"
    echo "  type: salamander"
    echo "  salamander:"
    echo "    password: ${obfs}"
    echo ""
    echo "bandwidth:"
    echo "  up: 50 mbps"
    echo "  down: 50 mbps"
    echo ""
    relay_engine_block
  } > "${file}"
}

layer_relay_probe_write_entry_yaml() {
  local file="$1" server_ip="$2" port="$3" auth="$4" obfs="$5" socks_port="${6:-}"
  mkdir -p "$(dirname "${file}")" 2>/dev/null || return 1
  [[ -n "${socks_port}" ]] || socks_port=$((port + 10000))
  {
    echo "server: ${server_ip}:${port}"
    echo ""
    echo "auth: ${auth}"
    echo ""
    echo "tls:"
    echo "  insecure: true"
    echo ""
    echo "obfs:"
    echo "  type: salamander"
    echo "  salamander:"
    echo "    password: ${obfs}"
    echo ""
    echo "bandwidth:"
    echo "  up: 50 mbps"
    echo "  down: 50 mbps"
    echo ""
    relay_engine_block
    echo ""
    echo "fastOpen: true"
    echo ""
    echo "socks5:"
    echo "  listen: 127.0.0.1:${socks_port}"
  } > "${file}"
}

layer_relay_probe_peer_prepare_dir() {
  local ssh_host="$1" ssh_port="$2" ssh_user="$3" pdir="$4"
  layer_ssh_cmd "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "rm -rf '${pdir}' 2>/dev/null; mkdir -p '${pdir}/tls'" 2>/dev/null
}

layer_relay_probe_peer_push_tls() {
  local ssh_host="$1" ssh_port="$2" ssh_user="$3" pdir="$4" staging="$5"
  layer_relay_probe_gen_tls "${staging}" || return 1
  layer_ssh_cmd "${ssh_host}" "${ssh_port}" "${ssh_user}" "mkdir -p '${pdir}/tls'" 2>/dev/null || return 1
  layer_ssh_scp_to "${ssh_port}" "${ssh_user}" "${ssh_host}" "${staging}/cert.crt" "${pdir}/tls/cert.crt" 2>/dev/null || return 1
  layer_ssh_scp_to "${ssh_port}" "${ssh_user}" "${ssh_host}" "${staging}/cert.key" "${pdir}/tls/cert.key" 2>/dev/null || return 1
  if layer_ssh_cmd "${ssh_host}" "${ssh_port}" "${ssh_user}" \
      "test -s '${pdir}/tls/cert.crt' && test -s '${pdir}/tls/cert.key'" 2>/dev/null; then
    return 0
  fi
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "command -v openssl >/dev/null 2>&1 || (export DEBIAN_FRONTEND=noninteractive; apt-get update -qq 2>/dev/null; apt-get install -y -qq openssl 2>/dev/null); \
     mkdir -p '${pdir}/tls'; \
     openssl req -x509 -nodes -newkey rsa:2048 -keyout '${pdir}/tls/cert.key' -out '${pdir}/tls/cert.crt' -days 1 -subj '/CN=phormal-probe' 2>/dev/null; \
     chmod -R a+rX '${pdir}/tls' 2>/dev/null; \
     test -s '${pdir}/tls/cert.crt' && test -s '${pdir}/tls/cert.key'" 2>/dev/null
}

layer_relay_probe_port_in_use() {
  local port="$1"
  ss -H -uln "sport = :${port}" 2>/dev/null | grep -q . && return 0
  ss -H -tln "sport = :${port}" 2>/dev/null | grep -q . && return 0
  return 1
}

layer_relay_probe_peer_port_in_use() {
  local port="$1" ssh_host="$2" ssh_port="$3" ssh_user="$4"
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "ss -H -uln 'sport = :${port}' 2>/dev/null | grep -q . || \
     ss -H -tln 'sport = :${port}' 2>/dev/null | grep -q ." 2>/dev/null
}

layer_relay_probe_port_udp_in_use() {
  local port="$1"
  ss -H -uln 2>/dev/null | grep -qE ":${port}([^0-9]|$)" && return 0
  ss -H -uln "sport = :${port}" 2>/dev/null | grep -q . && return 0
  return 1
}

layer_relay_probe_local_hysteria_listening() {
  local port="$1"
  ss -H -uln 2>/dev/null | grep -qE ":${port}([^0-9]|$)" && pgrep -f "${RELAY_BIN}" >/dev/null 2>&1
}

layer_relay_probe_peer_hysteria_listening() {
  local port="$1" ssh_host="$2" ssh_port="$3" ssh_user="$4"
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "ss -H -uln 'sport = :${port}' 2>/dev/null | grep -q . && \
     { pgrep -f '${RELAY_BIN}' >/dev/null 2>&1 || pgrep -fi hysteria >/dev/null 2>&1 || \
       ss -H -ulnp 'sport = :${port}' 2>/dev/null | grep -qiE 'hysteria|phormal-relay'; }" 2>/dev/null
}

layer_relay_probe_peer_ensure_bind_cap() {
  local ssh_host="$1" ssh_port="$2" ssh_user="$3"
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "test -x '${RELAY_BIN}' && setcap cap_net_bind_service,cap_net_admin=+ep '${RELAY_BIN}' 2>/dev/null || true" \
    2>/dev/null || true
}

layer_relay_probe_ensure_local_bind_cap() {
  [[ -x "${RELAY_BIN}" ]] || return 0
  if [[ ${EUID} -eq 0 ]]; then
    setcap cap_net_bind_service,cap_net_admin=+ep "${RELAY_BIN}" 2>/dev/null || true
  elif have sudo; then
    sudo -n setcap cap_net_bind_service,cap_net_admin=+ep "${RELAY_BIN}" 2>/dev/null \
      || sudo setcap cap_net_bind_service,cap_net_admin=+ep "${RELAY_BIN}" 2>/dev/null \
      || true
  fi
}

layer_relay_probe_resolve_port() {
  local server_on_peer="$1" ssh_host="$2" ssh_port="$3" ssh_user="$4"
  local port fallback
  server_on_peer="${server_on_peer:-0}"
  port="${PHORMAL_RELAY_PROBE_PORT:-443}"
  if [[ ! "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    port=443
  fi
  if [[ "${server_on_peer}" -eq 1 ]]; then
    if layer_relay_probe_peer_port_in_use "${port}" "${ssh_host}" "${ssh_port}" "${ssh_user}"; then
      if layer_relay_probe_peer_hysteria_listening "${port}" "${ssh_host}" "${ssh_port}" "${ssh_user}"; then
        printf '%s' "${port}"
        return 0
      fi
      fallback=$((47000 + ($$ % 2000)))
      warn "  Relay probe: peer port ${port} in use (not Phormal Relay) — using non-production UDP port ${fallback}" >&2
      printf '%s' "${fallback}"
      return 0
    fi
  elif layer_relay_probe_port_udp_in_use "${port}"; then
    if pgrep -f "${RELAY_BIN}" >/dev/null 2>&1; then
      printf '%s' "${port}"
      return 0
    fi
    fallback=$((47000 + ($$ % 2000)))
    warn "  Relay probe: UDP port ${port} in use (not ${RELAY_BIN}) — using non-production UDP port ${fallback}" >&2
    printf '%s' "${fallback}"
    return 0
  elif layer_relay_probe_port_in_use "${port}"; then
    printf '%s' "${port}"
    return 0
  fi
  printf '%s' "${port}"
}

layer_relay_probe_server_log_ready() {
  local log="$1"
  [[ -f "${log}" ]] || return 1
  grep -qE 'server up and running|server mode|listening on|Hysteria server' "${log}" 2>/dev/null
}

layer_relay_probe_peer_server_log_ready() {
  local ssh_host="$1" ssh_port="$2" ssh_user="$3" pdir="$4"
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "grep -qE 'server up and running|server mode|listening on|Hysteria server' '${pdir}/srv.log' 2>/dev/null" 2>/dev/null
}

layer_relay_probe_start_local_server() {
  local dir="$1" pid
  pkill -f "${dir}/exit.yaml" 2>/dev/null || true
  : >"${dir}/srv.log"
  rm -f "${dir}/srv.pid"
  if [[ ${EUID} -eq 0 ]]; then
    setsid "${RELAY_BIN}" server -c "${dir}/exit.yaml" >>"${dir}/srv.log" 2>&1 < /dev/null &
    disown 2>/dev/null || true
    echo $! >"${dir}/srv.pid"
  elif have sudo; then
    sudo -n bash -c "setsid '${RELAY_BIN}' server -c '${dir}/exit.yaml' >>'${dir}/srv.log' 2>&1 < /dev/null & echo \$! >'${dir}/srv.pid'" 2>/dev/null \
      || sudo bash -c "setsid '${RELAY_BIN}' server -c '${dir}/exit.yaml' >>'${dir}/srv.log' 2>&1 < /dev/null & echo \$! >'${dir}/srv.pid'"
  else
    setsid "${RELAY_BIN}" server -c "${dir}/exit.yaml" >>"${dir}/srv.log" 2>&1 < /dev/null &
    disown 2>/dev/null || true
    echo $! >"${dir}/srv.pid"
  fi
  sleep 2
  pid="$(cat "${dir}/srv.pid" 2>/dev/null || true)"
  printf '%s' "${pid}"
}

layer_relay_probe_peer_start_server() {
  local ssh_host="$1" ssh_port="$2" ssh_user="$3" pdir="$4"
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "pkill -f '${pdir}/exit.yaml' 2>/dev/null || true
     cd '${pdir}' || { echo 'FATAL cannot cd ${pdir}' >>srv.log; exit 0; }
     : >srv.log
     if [[ ! -x '${RELAY_BIN}' ]]; then echo 'FATAL hysteria missing at ${RELAY_BIN}' >>srv.log; exit 0; fi
     if [[ ! -s exit.yaml ]]; then echo 'FATAL exit.yaml missing' >>srv.log; exit 0; fi
     if [[ ! -s tls/cert.crt ]]; then echo 'FATAL tls/cert.crt missing' >>srv.log; exit 0; fi
     setcap cap_net_bind_service,cap_net_admin=+ep '${RELAY_BIN}' 2>/dev/null || true
     setsid '${RELAY_BIN}' server -c exit.yaml >>srv.log 2>&1 < /dev/null &
     echo \$! >srv.pid
     sleep 3" 2>/dev/null || true
}

layer_relay_probe_peer_server_ready() {
  local ssh_host="$1" ssh_port="$2" ssh_user="$3" pdir="$4" port="$5"
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "for i in \$(seq 1 30); do
       grep -qE 'server up and running|server mode|listening on|Hysteria server' '${pdir}/srv.log' 2>/dev/null && exit 0
       ss -H -uln 'sport = :${port}' 2>/dev/null | grep -q . && exit 0
       ss -H -tln 'sport = :${port}' 2>/dev/null | grep -q . && exit 0
       [[ -f '${pdir}/srv.pid' ]] && kill -0 \$(cat '${pdir}/srv.pid' 2>/dev/null) 2>/dev/null && \
         grep -qE 'server up and running|server mode|listening on|Hysteria server' '${pdir}/srv.log' 2>/dev/null && exit 0
       sleep 1
     done
     exit 1" 2>/dev/null
}

layer_relay_probe_peer_srv_error() {
  local ssh_host="$1" ssh_port="$2" ssh_user="$3" pdir="$4" tail diag
  tail="$(layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "tail -n 5 '${pdir}/srv.log' 2>/dev/null | tr '\n' ' '" 2>/dev/null | tr -d '\r' | head -c 200)"
  if [[ -z "${tail}" ]]; then
    diag="$(layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
      "pid=\$(cat '${pdir}/srv.pid' 2>/dev/null); \
       if [[ -n \"\${pid}\" ]] && kill -0 \"\${pid}\" 2>/dev/null; then echo \"srv.pid \${pid} alive\"; \
       elif ss -H -uln 2>/dev/null | grep -qE ':443([^0-9]|$)'; then echo 'UDP :443 bound (no log)'; \
       else echo 'srv.log empty — peer start failed (check '"${RELAY_BIN}"' on peer)'; fi" 2>/dev/null | tr -d '\r' | head -c 160)"
    printf '%s' "${diag}"
    return 0
  fi
  printf '%s' "${tail}"
}

layer_relay_probe_local_srv_tail() {
  local log="$1"
  tail -n 5 "${log}" 2>/dev/null | tr '\n' ' ' | tr -d '\r' | head -c 200
}

layer_relay_probe_run_local_bg() {
  local log="$1"; shift
  if [[ ${EUID} -eq 0 ]]; then
    "$@" >>"${log}" 2>&1 &
  elif have sudo; then
    sudo -n "$@" >>"${log}" 2>&1 & 2>/dev/null \
      || sudo "$@" >>"${log}" 2>&1 &
  else
    "$@" >>"${log}" 2>&1 &
  fi
  printf '%s' "$!"
}

layer_relay_probe_peer_ensure_tls() {
  local ssh_host="$1" ssh_port="$2" ssh_user="$3" tls_dir="$4"
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "command -v openssl >/dev/null 2>&1 || (export DEBIAN_FRONTEND=noninteractive; apt-get update -qq 2>/dev/null; apt-get install -y -qq openssl 2>/dev/null); \
     mkdir -p '${tls_dir}'; \
     if [[ ! -s '${tls_dir}/cert.crt' || ! -s '${tls_dir}/cert.key' ]]; then \
       openssl req -x509 -nodes -newkey rsa:2048 -keyout '${tls_dir}/cert.key' -out '${tls_dir}/cert.crt' -days 1 -subj '/CN=phormal-probe' 2>/dev/null; \
     fi; \
     chmod -R a+rX '${tls_dir}' 2>/dev/null; \
     test -s '${tls_dir}/cert.crt' && test -s '${tls_dir}/cert.key'" 2>/dev/null
}

layer_relay_probe_peer_tail_log() {
  local ssh_host="$1" ssh_port="$2" ssh_user="$3" log="$4" n="${5:-3}"
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "tail -n ${n} '${log}' 2>/dev/null | tr '\n' ' '" 2>/dev/null | tr -d '\r' | head -c 140
}

layer_relay_probe_wait_server_log() {
  local log="$1" port="${2:-}" i
  for i in $(seq 1 30); do
    layer_relay_probe_server_log_ready "${log}" && return 0
    if [[ -n "${port}" ]] && { ss -H -uln "sport = :${port}" 2>/dev/null | grep -q . \
      || ss -H -tln "sport = :${port}" 2>/dev/null | grep -q .; }; then
      return 0
    fi
    sleep 1
  done
  return 1
}

layer_relay_probe_wait_client_log() {
  local log="$1" pid="$2" i
  for i in $(seq 1 15); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      [[ -f "${log}" ]] && grep -qi FATAL "${log}" 2>/dev/null && return 1
      return 1
    fi
    [[ -f "${log}" ]] && grep -qiE 'connected|established|ready|listening|client mode' "${log}" 2>/dev/null && return 0
    [[ ${i} -ge 8 ]] && [[ -f "${log}" ]] && ! grep -qi FATAL "${log}" 2>/dev/null && return 0
    sleep 1
  done
  kill "${pid}" 2>/dev/null || true
  return 1
}

layer_relay_probe_cleanup_local() {
  local dir="$1"
  [[ -z "${dir}" || ! -d "${dir}" ]] && return 0
  [[ -f "${dir}/cli.pid" ]] && kill "$(cat "${dir}/cli.pid" 2>/dev/null)" 2>/dev/null || true
  [[ -f "${dir}/srv.pid" ]] && kill "$(cat "${dir}/srv.pid" 2>/dev/null)" 2>/dev/null || true
  pkill -f "${dir}/" 2>/dev/null || true
  rm -rf "${dir}"
}

layer_relay_probe_synthetic_fini() {
  local dir="$1" pdir="$2" ssh_host="$3" ssh_port="$4" ssh_user="$5"
  kill "${LAYER_RELAY_PROBE_SRV_PID:-}" 2>/dev/null || true
  kill "${LAYER_RELAY_PROBE_CLI_PID:-}" 2>/dev/null || true
  LAYER_RELAY_PROBE_SRV_PID=""
  LAYER_RELAY_PROBE_CLI_PID=""
  layer_relay_probe_cleanup_peer "${ssh_host}" "${ssh_port}" "${ssh_user}" "${pdir}"
  layer_relay_probe_cleanup_local "${dir}"
}

layer_relay_probe_cleanup_peer() {
  local ssh_host="$1" ssh_port="$2" ssh_user="$3" pdir="$4"
  [[ -z "${pdir}" ]] && return 0
  layer_ssh_cmd "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "pkill -f '${pdir}/' 2>/dev/null; rm -rf '${pdir}'" 2>/dev/null || true
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "[[ -f '${pdir}/cli.pid' ]] && kill \$(cat '${pdir}/cli.pid') 2>/dev/null; \
     [[ -f '${pdir}/srv.pid' ]] && kill \$(cat '${pdir}/srv.pid') 2>/dev/null; \
     pkill -f '${pdir}/entry.yaml' 2>/dev/null; pkill -f '${pdir}/exit.yaml' 2>/dev/null; \
     rm -rf '${pdir}'" 2>/dev/null || true
}

layer_local_relay_toward_peer() {
  local peer_v4="$1" n role remote found_exit=""
  while read -r n; do
    [[ -n "${n}" ]] || continue
    role="$(imeta_get "${n}" ROLE)"
    remote="$(imeta_get "${n}" REMOTE_V4)"
    if [[ "${role}" == entry && "${remote}" == "${peer_v4}" ]]; then
      printf '%s|entry' "${n}"
      return 0
    fi
    [[ "${role}" == exit ]] && found_exit="${n}"
  done < <(relay_instances 2>/dev/null)
  [[ -n "${found_exit}" ]] && { printf '%s|exit' "${found_exit}"; return 0; }
  return 1
}

layer_test_relay_synthetic_probe() {
  local local_v4="$1" peer_v4="$2" ssh_host="$3" ssh_port="$4" ssh_user="$5"
  local probe_id="phmr$$"
  local dir="/tmp/phormal-relay-probe-${probe_id}"
  local pdir="/tmp/phormal-relay-probe-${probe_id}"
  local port socks_port auth obfs tls_dir ok=FAIL conf=high note=""
  local entry_v4 exit_v4 local_is_entry cli_pid err_detail connected=0 relay_probe_existing=0
  local stored_iran stored_kharej ans

  install_relay_engine 2>/dev/null || true
  if [[ ! -x "${RELAY_BIN}" ]]; then
    layer_autotest_record "Phormal Relay" "inconclusive" "low" "hysteria binary missing on this host"
    return 0
  fi

  stored_iran="$(conf_get IRAN_V4)"
  stored_kharej="$(conf_get KHAREJ_V4)"
  [[ -z "${stored_iran}" && ( "${local_v4}" == "188.213.198.246" || "${peer_v4}" == "188.213.198.246" ) ]] && stored_iran="188.213.198.246"
  [[ -z "${stored_kharej}" && ( "${local_v4}" == "91.107.250.174" || "${peer_v4}" == "91.107.250.174" ) ]] && stored_kharej="91.107.250.174"
  if [[ "${local_v4}" == "${stored_iran}" && -n "${stored_kharej}" ]]; then
    entry_v4="${local_v4}"; exit_v4="${stored_kharej}"; local_is_entry=1
  elif [[ "${local_v4}" == "${stored_kharej}" && -n "${stored_iran}" ]]; then
    entry_v4="${stored_iran}"; exit_v4="${local_v4}"; local_is_entry=0
  elif [[ "${peer_v4}" == "${stored_kharej}" && -n "${stored_iran}" ]]; then
    entry_v4="${local_v4}"; exit_v4="${peer_v4}"; local_is_entry=1
  elif [[ "${peer_v4}" == "${stored_iran}" && -n "${stored_kharej}" ]]; then
    entry_v4="${peer_v4}"; exit_v4="${local_v4}"; local_is_entry=0
  else
    info "  Relay layout: Iran = entry (client), Kharej = exit (Relay server)."
    ans="$(ask "Is phormal running on IRAN entry now? (y/n) [y]")"
    ans="${ans:-y}"
    if [[ "${ans}" =~ ^[Yy] ]]; then
      entry_v4="${local_v4}"; exit_v4="${peer_v4}"; local_is_entry=1
      conf_set IRAN_V4 "${local_v4}"
      conf_set KHAREJ_V4 "${peer_v4}"
    else
      entry_v4="${peer_v4}"; exit_v4="${local_v4}"; local_is_entry=0
      conf_set IRAN_V4 "${peer_v4}"
      conf_set KHAREJ_V4 "${local_v4}"
    fi
  fi

  layer_relay_probe_cleanup_peer "${ssh_host}" "${ssh_port}" "${ssh_user}" "${pdir}"
  layer_relay_probe_cleanup_local "${dir}"

  auth="$(rand_secret)"
  obfs="$(rand_secret)"
  if ! mkdir -p "${dir}/tls" "${dir}/peer-tls-staging"; then
    layer_autotest_record "Phormal Relay" "inconclusive" "low" "cannot create probe workspace ${dir}"
    return 0
  fi
  layer_relay_probe_gen_tls "${dir}/tls" || true

  if [[ "${local_is_entry}" -eq 1 ]]; then
    port="$(layer_relay_probe_resolve_port 1 "${ssh_host}" "${ssh_port}" "${ssh_user}")"
  else
    port="$(layer_relay_probe_resolve_port 0 "${ssh_host}" "${ssh_port}" "${ssh_user}")"
  fi
  if [[ ! "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    port=443
  fi

  if [[ "${local_is_entry}" -eq 0 ]] && layer_relay_probe_local_hysteria_listening "${port}"; then
    info "  Kharej exit already listening on UDP :${port} — Relay path open (production)"
    relay_probe_existing=1
    connected=1
  fi

  socks_port=$((port + 10000))
  if (( socks_port > 65000 )); then
    socks_port=$((10000 + port % 50001))
    (( socks_port > 60000 )) && socks_port=60000
    (( socks_port < 10000 )) && socks_port=10000
  fi

  info "  Path test Relay — Iran entry ${entry_v4} → Kharej exit ${exit_v4} (UDP :${port})…"
  if [[ "${local_is_entry}" -eq 1 ]]; then
    layer_relay_probe_peer_ensure_bind_cap "${ssh_host}" "${ssh_port}" "${ssh_user}"
  else
    layer_relay_probe_ensure_local_bind_cap
  fi

  if [[ "${local_is_entry}" -eq 1 ]]; then
    if layer_relay_probe_peer_hysteria_listening "${port}" "${ssh_host}" "${ssh_port}" "${ssh_user}"; then
      info "  Kharej exit already listening on UDP :${port} — Relay path open (existing)"
      relay_probe_existing=1
      connected=1
    fi
  fi

  if [[ "${local_is_entry}" -eq 1 && "${relay_probe_existing}" -eq 0 ]]; then
    if ! layer_relay_probe_write_entry_yaml "${dir}/entry.yaml" "${exit_v4}" "${port}" "${auth}" "${obfs}" "${socks_port}" \
        || ! layer_relay_probe_write_exit_yaml "${dir}/peer-exit.yaml" "${port}" "${auth}" "${obfs}" "tls"; then
      layer_autotest_record "Phormal Relay" "inconclusive" "low" "failed to write Relay probe configs"
      layer_relay_probe_synthetic_fini "${dir}" "${pdir}" "${ssh_host}" "${ssh_port}" "${ssh_user}"
      return 0
    fi
    layer_relay_probe_peer_prepare_dir "${ssh_host}" "${ssh_port}" "${ssh_user}" "${pdir}"
    if ! layer_relay_probe_peer_push_tls "${ssh_host}" "${ssh_port}" "${ssh_user}" "${pdir}" "${dir}/peer-tls-staging"; then
      layer_autotest_record "Phormal Relay" "FAIL" "high" "path test Relay — Kharej exit TLS failed"
      layer_relay_probe_synthetic_fini "${dir}" "${pdir}" "${ssh_host}" "${ssh_port}" "${ssh_user}"
      return 0
    fi
    if ! layer_ssh_scp_to "${ssh_port}" "${ssh_user}" "${ssh_host}" "${dir}/peer-exit.yaml" "${pdir}/exit.yaml" 2>/dev/null; then
      layer_autotest_record "Phormal Relay" "FAIL" "high" "path test Relay — scp exit.yaml to Kharej failed"
      layer_relay_probe_synthetic_fini "${dir}" "${pdir}" "${ssh_host}" "${ssh_port}" "${ssh_user}"
      return 0
    fi
    layer_ssh_cmd "${ssh_host}" "${ssh_port}" "${ssh_user}" "chmod -R a+rX '${pdir}' 2>/dev/null" 2>/dev/null || true
    layer_relay_probe_peer_start_server "${ssh_host}" "${ssh_port}" "${ssh_user}" "${pdir}"
    if ! layer_relay_probe_peer_server_ready "${ssh_host}" "${ssh_port}" "${ssh_user}" "${pdir}" "${port}"; then
      err_detail="Kharej exit did not start on :${port}"
      peer_srv_tail="$(layer_relay_probe_peer_srv_error "${ssh_host}" "${ssh_port}" "${ssh_user}" "${pdir}")"
      [[ -n "${peer_srv_tail}" ]] && err_detail="${err_detail} — ${peer_srv_tail}"
    else
      if [[ ${EUID} -eq 0 ]]; then
        cli_pid="$(layer_relay_probe_run_local_bg "${dir}/cli.log" bash -c "'${RELAY_BIN}' client -c '${dir}/entry.yaml'")"
      elif have sudo; then
        cli_pid="$(layer_relay_probe_run_local_bg "${dir}/cli.log" sudo bash -c "'${RELAY_BIN}' client -c '${dir}/entry.yaml'")"
      else
        cli_pid="$(layer_relay_probe_run_local_bg "${dir}/cli.log" bash -c "'${RELAY_BIN}' client -c '${dir}/entry.yaml'")"
      fi
      LAYER_RELAY_PROBE_CLI_PID="${cli_pid}"
      echo "${cli_pid}" > "${dir}/cli.pid"
      if layer_relay_probe_wait_client_log "${dir}/cli.log" "${cli_pid}"; then
        connected=1
      else
        err_detail="$(grep -oE 'connect error[^",}]*|FATAL[^",}]*|no mode specified' "${dir}/cli.log" 2>/dev/null | tail -1 | head -c 120)"
        [[ -z "${err_detail}" ]] && err_detail="Iran entry client did not connect to Kharej exit"
      fi
      kill "${cli_pid}" 2>/dev/null || true
      LAYER_RELAY_PROBE_CLI_PID=""
    fi
    layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
      "[[ -f '${pdir}/srv.pid' ]] && kill \$(cat '${pdir}/srv.pid') 2>/dev/null; pkill -f '${pdir}/' 2>/dev/null" 2>/dev/null || true
  elif [[ "${local_is_entry}" -eq 0 && "${relay_probe_existing}" -eq 0 ]]; then
    if ! layer_relay_probe_write_exit_yaml "${dir}/exit.yaml" "${port}" "${auth}" "${obfs}" "tls" \
        || ! layer_relay_probe_write_entry_yaml "${dir}/peer-entry.yaml" "${exit_v4}" "${port}" "${auth}" "${obfs}" "${socks_port}"; then
      layer_autotest_record "Phormal Relay" "inconclusive" "low" "failed to write Relay probe configs"
      layer_relay_probe_synthetic_fini "${dir}" "${pdir}" "${ssh_host}" "${ssh_port}" "${ssh_user}"
      return 0
    fi
    info "  Starting Kharej exit locally on UDP :${port}…"
    cli_pid="$(layer_relay_probe_start_local_server "${dir}")"
    LAYER_RELAY_PROBE_SRV_PID="${cli_pid}"
    if ! layer_relay_probe_wait_server_log "${dir}/srv.log" "${port}"; then
      err_detail="Kharej exit did not start locally on :${port}"
      srv_tail="$(layer_relay_probe_local_srv_tail "${dir}/srv.log")"
      [[ -n "${srv_tail}" ]] && err_detail="${err_detail} — ${srv_tail}"
    else
      info "  Running Iran entry client on peer via SSH…"
      layer_ssh_cmd "${ssh_host}" "${ssh_port}" "${ssh_user}" "mkdir -p '${pdir}'" 2>/dev/null || true
      if ! layer_ssh_scp_to "${ssh_port}" "${ssh_user}" "${ssh_host}" "${dir}/peer-entry.yaml" "${pdir}/entry.yaml" 2>/dev/null; then
        err_detail="scp entry.yaml to Iran peer failed"
      else
        layer_ssh_cmd "${ssh_host}" "${ssh_port}" "${ssh_user}" "chmod a+r '${pdir}/entry.yaml' 2>/dev/null" 2>/dev/null || true
        layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
          "pkill -f '${pdir}/entry.yaml' 2>/dev/null || true; \
           : >'${pdir}/cli.log'; \
           cd '${pdir}' && setsid '${RELAY_BIN}' client -c entry.yaml >>cli.log 2>&1 < /dev/null & \
           echo \$! >cli.pid; sleep 1" 2>/dev/null || true
        sleep 1
        if layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
            "for i in \$(seq 1 12); do \
               [[ -f '${pdir}/cli.pid' ]] && kill -0 \$(cat '${pdir}/cli.pid') 2>/dev/null || break; \
               grep -qiE 'connected|established|ready|listening|client mode' '${pdir}/cli.log' 2>/dev/null && exit 0; \
               grep -qi FATAL '${pdir}/cli.log' 2>/dev/null && exit 1; \
               [[ \${i} -ge 10 ]] && ! grep -qi FATAL '${pdir}/cli.log' 2>/dev/null && exit 0; \
               sleep 1; \
             done; exit 1" 2>/dev/null; then
          connected=1
        else
          err_detail="$(layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
            "grep -oE 'connect error[^\",}]*|FATAL[^\",}]*|no mode specified' '${pdir}/cli.log' 2>/dev/null | tail -1 | head -c 120" 2>/dev/null | tr -d '\r')"
          [[ -z "${err_detail}" ]] && err_detail="Iran entry on peer did not connect to local Kharej exit"
        fi
      fi
    fi
    kill "${LAYER_RELAY_PROBE_SRV_PID:-}" 2>/dev/null || true
    LAYER_RELAY_PROBE_SRV_PID=""
  fi

  if [[ "${connected}" -eq 1 ]]; then
    ok=PASS
    if [[ "${relay_probe_existing}" -eq 1 ]]; then
      conf=high
      note="Kharej exit already listening on :${port} — Relay path open (production)"
    else
      conf=high
      note="path test Relay — Iran entry ${entry_v4} → Kharej exit ${exit_v4} OK (:${port})"
    fi
  else
    ok=FAIL; conf=high
    note="path test Relay — Iran→Kharej failed"
    [[ -n "${err_detail}" ]] && note="${note} — ${err_detail}"
    if grep -qi 'connect error\|timeout' <<<"${err_detail}"; then
      note="${note} (UDP may be filtered on this path)"
    fi
  fi
  layer_autotest_record "Phormal Relay" "${ok}" "${conf}" "${note}"
  layer_relay_probe_synthetic_fini "${dir}" "${pdir}" "${ssh_host}" "${ssh_port}" "${ssh_user}"
}

layer_relay_autotest_systemd_pair() {
  local local_v4="$1" peer_v4="$2" ssh_host="$3" ssh_port="$4" ssh_user="$5"
  local local_n peer_n
  local_n="$(systemctl list-units --type=service --state=active --no-legend 'phormal-relay@*' 2>/dev/null \
    | awk '{print $1}' | sed 's/phormal-relay@//;s/\.service//' | head -n1)"
  peer_n="$(layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "systemctl list-units --type=service --state=active --no-legend 'phormal-relay@*' 2>/dev/null \
     | awk '{print \$1}' | sed 's/phormal-relay@//;s/\.service//' | head -n1" 2>/dev/null | tr -d '\r')"
  if [[ -n "${local_n}" && -n "${peer_n}" ]]; then
    layer_autotest_record "Phormal Relay" "PASS" "med" \
      "configured Relay — phormal-relay@${local_n} (this host) and phormal-relay@${peer_n} (peer) both active"
    return 0
  fi
  return 1
}

layer_test_relay_path() {
  local local_v4="$1" peer_v4="$2" ssh_host="$3" ssh_port="$4" ssh_user="$5"
  local n role remote listen st peer_info peer_meta ok=FAIL conf=high note=""
  local peer_n peer_role peer_st peer_listen started_any=0 err_hint udp_ok=0

  layer_autotest_probe_begin "Phormal Relay (Iran entry → Kharej exit)"
  layer_autotest_require_peer_ssh || {
    layer_autotest_record "Phormal Relay" "inconclusive" "low" "peer SSH not ready"
    return 0
  }
  local local_pair peer_meta_early peer_info
  local_pair="$(layer_local_relay_toward_peer "${peer_v4}" 2>/dev/null || true)"
  peer_meta_early="$(layer_ssh_peer_relay_meta "${local_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}")"
  peer_info="$(layer_ssh_peer_relay_lookup "${local_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}")"
  case "${peer_info}" in
    UP:*)
      ok=PASS; conf=med
      note="peer Relay active (${peer_info#UP:})"
      [[ -n "${local_pair}" ]] && note="${note}; local Relay also configured"
      layer_autotest_record "Phormal Relay" "${ok}" "${conf}" "${note}"
      info "  (UDP echo skipped — configured Relay seen on peer via SSH)"
      return 0
      ;;
    STOP:*)
      layer_autotest_record "Phormal Relay" "inconclusive" "med" \
        "peer Relay '${peer_info#STOP:}' configured but STOPPED — systemctl enable --now phormal-relay@<name> on peer"
      info "  (UDP echo skipped — Relay meta on peer but service not active)"
      return 0
      ;;
  esac
  if [[ -z "${local_pair}" && ( -z "${peer_meta_early}" || "${peer_meta_early}" == NONE ) ]]; then
    if layer_relay_autotest_systemd_pair "${local_v4}" "${peer_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}"; then
      return 0
    fi
    info "  No Relay config — path test probe (Iran entry → Kharej exit)…"
    layer_test_relay_synthetic_probe "${local_v4}" "${peer_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}"
    return 0
  fi
  while read -r n; do
    [[ -n "${n}" ]] || continue
    role="$(imeta_get "${n}" ROLE)"
    remote="$(imeta_get "${n}" REMOTE_V4)"
    listen="$(imeta_get "${n}" LISTEN)"; listen="${listen:-443}"
    st="$(relay_svc_state "${n}")"
    case "${role}" in
      entry)
        [[ "${remote}" == "${peer_v4}" ]] || continue
        peer_meta="$(layer_ssh_peer_relay_meta "${local_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}")"
        if [[ -z "${peer_meta}" || "${peer_meta}" == NONE ]]; then
          layer_autotest_record "Phormal Relay" "inconclusive" "med" \
            "local entry '${n}' toward ${peer_v4} but peer has no Relay exit — install exit on peer (menu 6)"
          info "  (UDP echo skipped — Relay needs entry+exit pair)"
          return 0
        fi
        IFS='|' read -r peer_n peer_role peer_st _ peer_listen <<<"${peer_meta}"
        [[ "${peer_role}" == exit ]] || warn "  Peer Relay role is '${peer_role}' — expected exit for entry '${n}'"
        if ! relay_svc_is_active "${n}"; then
          info "  Local Relay '${n}' is ${st} — starting on this host…"
          systemctl start "phormal-relay@${n}" 2>/dev/null || true
          started_any=1
          sleep 3
          st="$(relay_svc_state "${n}")"
        fi
        if [[ "${peer_st}" != up ]]; then
          info "  Peer Relay '${peer_n}' not active — starting on peer via SSH…"
          layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
            "systemctl start phormal-relay@${peer_n}" 2>/dev/null || true
          started_any=1
          sleep 2
          peer_meta="$(layer_ssh_peer_relay_meta "${local_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}")"
          IFS='|' read -r peer_n peer_role peer_st _ peer_listen <<<"${peer_meta}"
        fi
        [[ "${started_any}" -eq 1 ]] && sleep 2
        info "  Probing UDP to Relay exit ${peer_v4}:${listen%-*}…"
        layer_test_udp_port_open "${peer_v4}" "${listen}" && udp_ok=1
        if relay_svc_is_active "${n}" && [[ "${peer_st}" == up ]]; then
          ok=PASS; conf=high
          note="paired entry '${n}' ↔ exit '${peer_n}' — both phormal-relay@ active (${peer_v4}:${listen})"
        elif relay_svc_is_active "${n}"; then
          ok=PASS; conf=med
          note="local entry active but peer exit not running (peer:${peer_st})"
        elif [[ "${peer_st}" == up ]]; then
          err_hint="$(layer_relay_journal_connect_hint "${n}")"
          ok=FAIL; conf=high
          if [[ -n "${err_hint}" ]]; then
            note="entry '${n}' cannot reach exit ${peer_v4}:${listen} — ${err_hint}"
          else
            note="entry '${n}' not connected (service ${st}) while exit '${peer_n}' is up on peer"
          fi
          if [[ "${udp_ok}" -eq 0 ]]; then
            note="${note}; UDP ${peer_v4}:${listen%-*} may be filtered from here"
          fi
        else
          err_hint="$(layer_relay_journal_connect_hint "${n}")"
          if [[ -n "${err_hint}" ]]; then
            ok=FAIL; conf=high
            note="paired Relay configured but entry failed — ${err_hint}"
          else
            layer_autotest_record "Phormal Relay" "inconclusive" "med" \
              "paired Relay configured but both sides down (local:${st} peer:${peer_st}) — systemctl enable --now phormal-relay@${n} and on peer phormal-relay@${peer_n}"
            info "  (UDP echo skipped — start both sides)"
            return 0
          fi
        fi
        layer_autotest_record "Phormal Relay" "${ok}" "${conf}" "${note}"
        info "  (UDP echo skipped — Relay does not echo arbitrary UDP)"
        return 0
        ;;
      exit)
        peer_meta="$(layer_ssh_peer_relay_meta "${local_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}")"
        if ! relay_svc_is_active "${n}"; then
          info "  Local Relay exit '${n}' is ${st} — starting…"
          systemctl start "phormal-relay@${n}" 2>/dev/null || true
          sleep 2
          st="$(relay_svc_state "${n}")"
        fi
        if [[ -n "${peer_meta}" && "${peer_meta}" != NONE ]]; then
          IFS='|' read -r peer_n peer_role peer_st _ peer_listen <<<"${peer_meta}"
          if relay_svc_is_active "${n}" && [[ "${peer_st}" == up ]]; then
            ok=PASS; conf=high
            note="paired exit '${n}' ↔ entry '${peer_n}' — both phormal-relay@ active"
          elif relay_svc_is_active "${n}"; then
            ok=PASS; conf=med
            note="exit '${n}' active; peer entry '${peer_n}' is ${peer_st}"
          elif [[ "${peer_st}" == up ]]; then
            ok=FAIL; conf=med
            note="peer entry '${peer_n}' active but local exit '${n}' is ${st}"
          else
            ok=FAIL; conf=med
            note="exit '${n}' and peer entry '${peer_n}' both down (local:${st} peer:${peer_st})"
          fi
        elif relay_svc_is_active "${n}"; then
          ok=PASS; conf=med
          note="exit '${n}' — phormal-relay@${n} listening (no matching peer entry seen via SSH)"
        else
          layer_autotest_record "Phormal Relay" "inconclusive" "med" \
            "local exit '${n}' configured but service is ${st} — systemctl enable --now phormal-relay@${n}"
          return 0
        fi
        layer_autotest_record "Phormal Relay" "${ok}" "${conf}" "${note}"
        info "  (UDP echo skipped — Relay exit is up on this host)"
        return 0
        ;;
    esac
  done < <(relay_instances 2>/dev/null)
  while read -r n; do
    [[ -n "${n}" ]] || continue
    remote="$(imeta_get "${n}" REMOTE_V4)"
    role="$(imeta_get "${n}" ROLE)"
    st="$(relay_svc_state "${n}")"
    case "${role}" in
      entry) [[ "${remote}" == "${peer_v4}" ]] || continue ;;
      exit) ;;
      *) continue ;;
    esac
    relay_svc_is_active "${n}" && continue
    err_hint="$(layer_relay_journal_connect_hint "${n}")"
    if [[ -n "${err_hint}" ]]; then
      layer_autotest_record "Phormal Relay" "FAIL" "high" \
        "Relay '${n}' (${role}) configured but not connected — ${err_hint}"
    else
      layer_autotest_record "Phormal Relay" "inconclusive" "med" \
        "Relay '${n}' (${role}) configured but service is ${st} — systemctl enable --now phormal-relay@${n}"
    fi
    info "  (UDP echo skipped — tunnel configured but service not active)"
    return 0
  done < <(relay_instances 2>/dev/null)
  if layer_relay_autotest_systemd_pair "${local_v4}" "${peer_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}"; then
    return 0
  fi
  warn "  No paired Relay meta matched — running path test Relay probe…"
  layer_test_relay_synthetic_probe "${local_v4}" "${peer_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}"
}

layer_write_probe_py() {
  local dest="$1"
  layer_probe_py >"${dest}"
  chmod 755 "${dest}"
}

layer_test_udp_sizes() {
  local peer="$1" ssh_host="$2" ssh_port="$3" ssh_user="$4" size="$5" label="$6" port
  apt_install_quiet python3 2>/dev/null || true
  port="$(layer_pick_probe_port)" || { layer_autotest_record "${label}" "inconclusive" "low" "no free port"; return; }
  layer_test_udp_echo "${peer}" "${ssh_host}" "${ssh_port}" "${ssh_user}" "${port}" $((port + 1)) "${size}" "${label}"
}

layer_test_tcp_one_way() {
  local dir="$1" local_v4="$2" peer_v4="$3" ssh_host="$4" ssh_port="$5" ssh_user="$6" port="$7"
  local reply="/tmp/phormal-tcp-${dir}-$$"
  rm -f "${reply}"
  case "${dir}" in
    forward)
      layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
        "timeout 14 bash -c 'printf OK-FWD | nc -l -p ${port} -q 2'" 2>/dev/null &
      sleep 1
      if printf '' | timeout 7 nc -w 5 "${peer_v4}" "${port}" 2>/dev/null | grep -q OK-FWD; then
        rm -f "${reply}"
        return 0
      fi
      ;;
    reverse)
      timeout 14 nc -l -p "${port}" >"${reply}" 2>/dev/null &
      local lid=$!
      sleep 1
      layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
        "printf REV-REV | nc -w 5 ${local_v4} ${port}" >/dev/null 2>&1 &
      wait "${lid}" 2>/dev/null || true
      sleep 1
      if grep -q REV-REV "${reply}" 2>/dev/null; then
        rm -f "${reply}"
        return 0
      fi
      ;;
  esac
  rm -f "${reply}"
  return 1
}

layer_test_tcp_bidir() {
  local local_v4="$1" peer_v4="$2" ssh_host="$3" ssh_port="$4" ssh_user="$5" label="$6"
  local port_fwd port_rev ok=FAIL conf=high note="" fwd_ok=0 rev_ok=0

  layer_autotest_require_peer_ssh || {
    layer_autotest_probe_begin "${label}"
    layer_autotest_record "${label}" "inconclusive" "low" "peer SSH not ready for TCP probe"
    return 0
  }
  [[ -n "${local_v4}" ]] || local_v4="$(layer_detect_public_v4 "${peer_v4}")"

  layer_autotest_probe_begin "${label} (TCP both ways — always tests this host ↔ peer)"
  info "  Endpoints: this host ${local_v4} ↔ peer ${peer_v4}"

  port_fwd="$(layer_pick_probe_port)" || {
    layer_autotest_record "${label}" "inconclusive" "low" "no free port for this→peer"
    return 0
  }
  info "  [1/2] this→peer (${local_v4} → ${peer_v4}) on :${port_fwd}…"
  if layer_test_tcp_one_way forward "${local_v4}" "${peer_v4}" \
      "${ssh_host}" "${ssh_port}" "${ssh_user}" "${port_fwd}"; then
    fwd_ok=1
    good "  this→peer: OK"
  else
    fail "  this→peer: FAIL"
  fi

  port_rev="$(layer_pick_probe_port)" || {
    layer_autotest_record "${label}" "inconclusive" "low" "no free port for peer→this"
    return 0
  }
  while [[ "${port_rev}" == "${port_fwd}" ]]; do
    port_rev="$(layer_pick_probe_port)" || break
  done
  info "  [2/2] peer→this (${peer_v4} → ${local_v4}) on :${port_rev}…"
  if layer_test_tcp_one_way reverse "${local_v4}" "${peer_v4}" \
      "${ssh_host}" "${ssh_port}" "${ssh_user}" "${port_rev}"; then
    rev_ok=1
    good "  peer→this: OK"
  else
    fail "  peer→this: FAIL"
  fi

  if [[ "${fwd_ok}" -eq 1 && "${rev_ok}" -eq 1 ]]; then
    ok=PASS; conf=high
    note="bidirectional TCP — this→peer OK, peer→this OK (:${port_fwd}/:${port_rev})"
  elif [[ "${fwd_ok}" -eq 1 || "${rev_ok}" -eq 1 ]]; then
    ok=PASS; conf=med
    note="one-way TCP only — this→peer:${fwd_ok} peer→this:${rev_ok} (asymmetric path; Reverse may work one direction only)"
  else
    note="both TCP directions failed — this→peer and peer→this"
    conf=med
  fi
  layer_autotest_record "${label}" "${ok}" "${conf}" "${note}"
}

layer_autotest_main() {
  local only="${1:-all}" ssh_host ssh_port ssh_user local_v4 peer_v4
  local def_host def_port def_user
  LAYER_TEST_ROWS=()
  LAYER_SSH_CTRL_PATH=""
  rule
  info "Phormal Path Test — Bridge, Relay, Reverse, GRE, Echo, Raw"
  info "Run on ONE server only (Iran or kharej). You enter peer SSH here — no second terminal on the peer."
  info "Non-root peer (e.g. ubuntu): you will be asked to use sudo -i so probes run as root on the peer."
  info "Relay probe: Iran entry (menu 7) → Kharej exit (menu 6) — production layout only."
  rule
  apt_install_quiet python3 tcpdump iproute2 openssh-client netcat-openbsd dnsutils 2>/dev/null || true
  have python3 || { fail "python3 required."; return 1; }
  def_host="$(conf_get PATH_TEST_SSH_HOST)"
  def_port="$(conf_get PATH_TEST_SSH_PORT)"; def_port="${def_port:-22}"
  def_user="$(conf_get PATH_TEST_SSH_USER)"; def_user="${def_user:-root}"
  if [[ -n "${def_host}" ]]; then
    ssh_host="$(ask "Peer SSH host (IP or hostname) [${def_host}]")"
    ssh_host="${ssh_host:-${def_host}}"
    ssh_port="$(ask "Peer SSH port [${def_port}]")"; ssh_port="${ssh_port:-${def_port}}"
    ssh_user="$(ask "Peer SSH user [${def_user}]")"; ssh_user="${ssh_user:-${def_user}}"
  else
    ssh_host="$(ask 'Peer SSH host (IP or hostname)')"
    ssh_port="$(ask 'Peer SSH port [22]')"; ssh_port="${ssh_port:-22}"
    ssh_user="$(ask 'Peer SSH user [root]')"; ssh_user="${ssh_user:-root}"
  fi
  peer_v4="${ssh_host}"
  valid_ipv4 "${peer_v4}" || peer_v4="$(getent ahostsv4 "${ssh_host}" 2>/dev/null | awk '{print $1; exit}')"
  [[ -n "${peer_v4}" ]] || { fail "Cannot resolve peer."; return 1; }
  layer_ssh_peer_offer_root_login "${ssh_user}"
  local_v4="$(layer_detect_public_v4 "${peer_v4}")"
  info "This host toward ${peer_v4} uses source IP ${local_v4:-?} — run from Iran or kharej where tunnels live."
  layer_ssh_session_open "${ssh_host}" "${ssh_port}" "${ssh_user}" || return 1
  layer_ssh_session_show_link "${ssh_host}" "${ssh_port}" "${ssh_user}" "${local_v4}" "${peer_v4}"
  info "Outbound SSH only (this → peer). Peer is controlled remotely — no SSH from peer to this host."
  conf_set PATH_TEST_SSH_HOST "${ssh_host}"
  conf_set PATH_TEST_SSH_PORT "${ssh_port}"
  conf_set PATH_TEST_SSH_USER "${ssh_user}"
  sysctl -w net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
  layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
    "sysctl -w net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0" >/dev/null 2>&1 || true
  layer_autotest_prepare_hosts "${only}" "${ssh_host}" "${ssh_port}" "${ssh_user}" || return 1
  printf '\n'
  layer_autotest_verify_peer_pairing "${local_v4}" "${peer_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}"
  printf '\n'
  [[ "${only}" == "all" || "${only}" == *bridge* || "${only}" == *sit* ]] && \
    layer_test_bridge_path "${local_v4}" "${peer_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}"
  [[ "${only}" == "all" || "${only}" == *gre* ]] && \
    layer_test_kernel_pair gre "Phormal GRE" "${local_v4}" "${peer_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}"
  [[ "${only}" == "all" || "${only}" == *ipip* ]] && \
    layer_test_kernel_pair ipip "Phormal GRE alt" "${local_v4}" "${peer_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}"

  if [[ "${only}" == "all" || "${only}" == *echo* || "${only}" == *icmp* ]]; then
    local pcap pcap2 ok=FAIL note="" probe="/tmp/phormal-probe-$$.py" peer_ok=0 local_ok=0
    layer_autotest_probe_begin "Phormal Echo"
    pcap="$(mktemp)"; pcap2="$(mktemp)"
    layer_write_probe_py "${probe}"
    layer_ssh_scp_to "${ssh_port}" "${ssh_user}" "${ssh_host}" "${probe}" "/tmp/phormal-probe.py" 2>/dev/null || true
    timeout 18 tcpdump -ni any -c 5 "icmp and src host ${peer_v4}" >"${pcap}" 2>&1 &
    local td=$!
    sleep 1
    layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" \
      "python3 /tmp/phormal-probe.py icmp_send ${peer_v4} ${local_v4} >/dev/null" 2>/dev/null || true
    wait "${td}" 2>/dev/null || true
    grep -q "ICMP echo request" "${pcap}" 2>/dev/null && peer_ok=1
    timeout 18 tcpdump -ni any -c 5 "icmp and src host ${local_v4}" >"${pcap2}" 2>&1 &
    td=$!
    sleep 1
    python3 "${probe}" icmp_send "${local_v4}" "${peer_v4}" >/dev/null 2>&1 || true
    wait "${td}" 2>/dev/null || true
    grep -q "ICMP echo request" "${pcap2}" 2>/dev/null && local_ok=1
    rm -f "${pcap}" "${pcap2}" "${probe}"
    layer_ssh_remote "${ssh_host}" "${ssh_port}" "${ssh_user}" "rm -f /tmp/phormal-probe.py" 2>/dev/null || true
    if [[ "${peer_ok}" -eq 1 && "${local_ok}" -eq 1 ]]; then ok=PASS; note="bidirectional Echo probe"
    elif [[ "${peer_ok}" -eq 1 || "${local_ok}" -eq 1 ]]; then ok=PASS; note="one-way Echo OK"; else note="no Echo path"; fi
    layer_autotest_record "Phormal Echo" "${ok}" "high" "${note}"
  fi

  [[ "${only}" == "all" || "${only}" == *relay* || "${only}" == *udp* ]] && \
    layer_test_relay_path "${local_v4}" "${peer_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}"

  if [[ "${only}" == *raw* && "${only}" != "all" ]]; then
    layer_autotest_probe_begin "Phormal Raw"
    layer_test_udp_sizes "${peer_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}" 1400 "Phormal Raw"
  elif [[ "${only}" == "all" || "${only}" == *raw* ]]; then
    local relay_res
    relay_res="$(layer_autotest_row_get "Phormal Relay" result 2>/dev/null || true)"
    if [[ "${relay_res}" == "PASS" ]]; then
      layer_autotest_copy_row "Phormal Relay" "Phormal Raw" " — same UDP path as Relay"
    elif [[ "${relay_res}" == "inconclusive" ]]; then
      layer_autotest_probe_begin "Phormal Raw"
      layer_autotest_record "Phormal Raw" "inconclusive" "low" "depends on Relay UDP path — configure Relay first"
    else
      layer_autotest_probe_begin "Phormal Raw"
      layer_test_udp_sizes "${peer_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}" 1400 "Phormal Raw"
    fi
  fi

  if [[ "${only}" == "all" || "${only}" == *reverse* || "${only}" == *tcp* ]]; then
    layer_test_tcp_bidir "${local_v4}" "${peer_v4}" "${ssh_host}" "${ssh_port}" "${ssh_user}" "Phormal Reverse"
  fi

  printf '\n'
  layer_autotest_print_table
  layer_autotest_recommendation
  layer_autotest_verdict
  layer_ssh_session_close "${ssh_host}" "${ssh_port}" "${ssh_user}"
}

layer_autotest_cli() {
  local only="all"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --only) only="${2:-all}"; shift 2 ;;
      --all) only="all"; shift ;;
      *) shift ;;
    esac
  done
  layer_autotest_main "${only}"
}

phormal_path_test_menu() {
  rule
  info "Phormal Path Test — option 1"
  info "Tests Bridge, Relay, Reverse, GRE, Echo, Raw."
  rule
  layer_autotest_cli
}

# ------------------------------------------------------------------------------
#  Menu
# ------------------------------------------------------------------------------
menu() {
  while :; do
    banner
    printf '\n  %sPHORMAL PATH TEST%s\n' "${BOLD}" "${RST}"
    printf '    %s1%s  Run path auto-test (SSH to peer — try every product)\n' "${ACC}" "${RST}"
    printf '\n  %sPHORMAL BRIDGE%s\n' "${BOLD}" "${RST}"
    printf '    %s2%s  Add exit link\n' "${ACC}" "${RST}"
    printf '    %s3%s  Add entry link\n' "${ACC}" "${RST}"
    printf '    %s4%s  Manage links\n' "${ACC}" "${RST}"
    printf '    %s5%s  Speedtest\n' "${ACC}" "${RST}"
    printf '\n  %sPHORMAL RELAY%s\n' "${BOLD}" "${RST}"
    printf '    %s6%s  Add exit tunnel\n' "${ACC}" "${RST}"
    printf '    %s7%s  Add entry tunnel\n' "${ACC}" "${RST}"
    printf '    %s8%s  Manage tunnels\n' "${ACC}" "${RST}"
    printf '    %s9%s  Speedtest\n' "${ACC}" "${RST}"
    printf '\n  %sPHORMAL REVERSE%s\n' "${BOLD}" "${RST}"
    printf '   %s10%s  Add exit tunnel\n' "${ACC}" "${RST}"
    printf '   %s11%s  Add entry tunnel\n' "${ACC}" "${RST}"
    printf '   %s12%s  Manage tunnels\n' "${ACC}" "${RST}"
    printf '\n  %sPHORMAL GRE%s\n' "${BOLD}" "${RST}"
    printf '   %s13%s  Add exit tunnel\n' "${ACC}" "${RST}"
    printf '   %s14%s  Add entry tunnel\n' "${ACC}" "${RST}"
    printf '   %s15%s  Manage tunnels\n' "${ACC}" "${RST}"
    printf '\n  %sPHORMAL ECHO%s\n' "${BOLD}" "${RST}"
    printf '   %s16%s  Add exit tunnel\n' "${ACC}" "${RST}"
    printf '   %s17%s  Add entry tunnel\n' "${ACC}" "${RST}"
    printf '   %s18%s  Manage tunnels\n' "${ACC}" "${RST}"
    printf '\n  %sPHORMAL RAW%s\n' "${BOLD}" "${RST}"
    printf '   %s19%s  Add exit tunnel\n' "${ACC}" "${RST}"
    printf '   %s20%s  Add entry tunnel\n' "${ACC}" "${RST}"
    printf '   %s21%s  Manage tunnels\n' "${ACC}" "${RST}"
    printf '\n  %sMANAGE%s\n' "${BOLD}" "${RST}"
    printf '   %s22%s  Status\n' "${ACC}" "${RST}"
    printf '   %s23%s  Phormal tuning\n' "${ACC}" "${RST}"
    printf '   %s24%s  Auto-refresh schedule\n' "${ACC}" "${RST}"
    printf '   %s25%s  Uninstall\n' "${ACC}" "${RST}"
    printf '    %s0%s  Exit\n\n' "${ACC}" "${RST}"

    local choice; choice="$(ask 'Select')"
    echo
    case "${choice}" in
      1)  phormal_path_test_menu || true ;;
      2)  create_bridge_exit || true ;;
      3)  create_bridge_entry || true ;;
      4)  manage_bridge_menu || true ;;
      5)  local bn; bn="$(bridge_choose_instance)"; [[ -n "${bn}" ]] && bridge_instance_speedtest "${bn}" || true ;;
      6)  create_exit_tunnel || true ;;
      7)  create_entry_tunnel || true ;;
      8)  manage_relay_menu || true ;;
      9)  relay_speedtest || true ;;
      10) create_reverse_exit || true ;;
      11) create_reverse_entry || true ;;
      12) manage_reverse_menu || true ;;
      13) create_layer_gre_exit || true ;;
      14) create_layer_gre_entry || true ;;
      15) manage_gre_menu || true ;;
      16) create_layer_icmp_exit || true ;;
      17) create_layer_icmp_entry || true ;;
      18) manage_echo_menu || true ;;
      19) create_layer_udp2raw_exit || true ;;
      20) create_layer_udp2raw_entry || true ;;
      21) manage_raw_menu || true ;;
      22) status || true ;;
      23) tune_menu || true ;;
      24) schedule_refresh || true ;;
      25) purge || true ;;
      0)  good "Goodbye — @SchmitzWS"; exit 0 ;;
      *)  fail "Invalid selection." ;;
    esac
    echo; read -n1 -s -r -p "  ${MUT}Press any key to continue…${RST}"; echo
  done
}

# ------------------------------------------------------------------------------
#  Entry
# ------------------------------------------------------------------------------
need_root
ensure_dirs
install_cli
menu
