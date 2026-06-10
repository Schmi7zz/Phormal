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
readonly PHORMAL_VERSION="4.1.0"
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
# /etc/phormal/phormal.conf with  MIRROR_BASE=http://your-server/phormal
# Files expected: gost-linux-amd64, gost-linux-arm64,
#                 hysteria-linux-amd64, hysteria-linux-arm64
readonly DEFAULT_MIRROR_BASE="http://85.198.16.108/phormal"
readonly GOST_RELEASE_VERSION="3.2.6"
readonly HYSTERIA_RELEASE_TAG="app/v2.9.2"
readonly MANUAL_DIR="/root/phormal"

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
  if [[ ${EUID} -ne 0 ]]; then
    fail "Phormal must run as root. Try: sudo phormal"
    exit 1
  fi
}

ensure_dirs() { mkdir -p "${PHORMAL_HOME}"; touch "${PHORMAL_LOG}" 2>/dev/null || true; }

have()        { command -v "$1" >/dev/null 2>&1; }

valid_ipv4()  { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

apt_install_quiet() {
  local missing=() p
  for p in "$@"; do have "${p}" || missing+=("${p}"); done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  info "Installing packages: ${missing[*]}…"
  timeout 45 apt-get update -y >/dev/null 2>&1 || true
  timeout 120 apt-get install -y "${missing[@]}" >/dev/null 2>&1 || true
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
  [[ -n "${b}" ]] && { printf '%s' "${b}"; return 0; }
  [[ -n "${DEFAULT_MIRROR_BASE}" ]] && printf '%s' "${DEFAULT_MIRROR_BASE}"
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

verify_fwd_tmp()   { [[ -x "$1" ]] && "$1" -V >/dev/null 2>&1; }
verify_relay_tmp() { [[ -x "$1" ]] && "$1" version >/dev/null 2>&1; }

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
      warn "Download failed: ${url}"
    fi
    rm -f "${tmp}"
  done
  return 1
}

reset_binary_source() { BINARY_SOURCE=""; }

choose_binary_source() {
  [[ -n "${BINARY_SOURCE}" ]] && return 0
  rule
  info "Binary download source (gost + hysteria)"
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
}

install_manual_fwd() {
  local arch src
  arch="$(machine_arch)" || { fail "Unsupported architecture: $(uname -m)"; return 1; }
  src="${MANUAL_DIR}/gost-linux-${arch}"
  if [[ ! -f "${src}" ]]; then
    fail "Place the gost binary at ${src}"
    info "Download it from: $(gost_release_url "${arch}")"
    return 1
  fi
  cp -f "${src}" "${FWD_BIN}"
  chmod +x "${FWD_BIN}"
  if ! verify_fwd_tmp "${FWD_BIN}"; then
    fail "Binary at ${src} failed verification."
    info "Download it from: $(gost_release_url "${arch}")"
    return 1
  fi
  good "Phormal publisher engine installed (manual)."
}

install_manual_relay() {
  local arch src
  arch="$(machine_arch)" || { fail "Unsupported architecture: $(uname -m)"; return 1; }
  src="${MANUAL_DIR}/hysteria-linux-${arch}"
  if [[ ! -f "${src}" ]]; then
    fail "Place the hysteria binary at ${src}"
    info "Download it from: $(hysteria_upstream_url "${arch}")"
    return 1
  fi
  cp -f "${src}" "${RELAY_BIN}"
  chmod +x "${RELAY_BIN}"
  if ! verify_relay_tmp "${RELAY_BIN}"; then
    fail "Binary at ${src} failed verification."
    info "Download it from: $(hysteria_upstream_url "${arch}")"
    return 1
  fi
  setcap cap_net_bind_service,cap_net_admin=+ep "${RELAY_BIN}" 2>/dev/null || true
  good "Phormal Relay engine installed (manual)."
}

random_core_prefix() {
  printf 'fd%02x:%02x%02x:%02x%02x:%02x%02x' \
    $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) \
    $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

conf_get() { [[ -f "${PHORMAL_CONF}" ]] && grep -E "^${1}=" "${PHORMAL_CONF}" | head -n1 | cut -d= -f2- || true; }

conf_set() {
  local key="$1" val="$2"
  ensure_dirs
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
    good "Phormal publisher engine present."
    return 0
  fi
  choose_binary_source || true
  info "Installing Phormal publisher engine…"

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
          "Phormal publisher engine (gost)" "${urls[@]}"; then
        return 0
      fi
    fi
    info "Mirror unavailable — trying upstream gost release v${GOST_RELEASE_VERSION}…"
    if install_gost_from_release; then
      good "Phormal publisher engine installed."
      return 0
    fi
  elif [[ "${BINARY_SOURCE}" == "github" ]]; then
    info "Fetching gost release v${GOST_RELEASE_VERSION} from GitHub…"
    if install_gost_from_release; then
      good "Phormal publisher engine installed."
      return 0
    fi
  fi

  info "Trying gost install script…"
  if bash <(curl -fsSL --connect-timeout 20 --max-time 180 \
      https://github.com/go-gost/gost/raw/master/install.sh) --install >/dev/null 2>&1 \
     && have gost; then
    ln -sf "$(command -v gost)" "${FWD_BIN}"
    good "Phormal publisher engine installed."
    return 0
  fi

  install_local_binary "${FWD_BIN}" || { fail "Publisher engine install failed."; return 1; }
  "${FWD_BIN}" -V >/dev/null 2>&1 || { fail "Binary is not runnable."; return 1; }
  good "Phormal publisher engine installed."
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
  local name="$1" st
  st="$(systemctl is-active "$(bcore_svc "${name}")" 2>/dev/null || true)"
  [[ "${st}" == "active" ]] && { printf 'active'; return 0; }
  if [[ "${name}" == "main" ]] && systemctl is-active phormal-core.service &>/dev/null; then
    printf 'active'; return 0
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
    [[ -z "\${PEER_CORE}" ]] && { echo "PEER_CORE empty in meta.conf — refusing to start (would crash gost)" >&2; exit 1; }
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
Description=Phormal Bridge publisher (%i)
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

  install_engine >/dev/null 2>&1 || true
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
  info "Publishes user ports here, forwarding over the SIT link to the exit."
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
        "Phormal Relay engine (hysteria)" "${urls[@]}"; then
      setcap cap_net_bind_service,cap_net_admin=+ep "${RELAY_BIN}" 2>/dev/null || true
      return 0
    fi
  elif [[ "${BINARY_SOURCE}" == "github" ]]; then
    urls+=( "$(hysteria_upstream_url "${arch}")" )
    if fetch_binary "${RELAY_BIN}" verify_relay_tmp \
        "Phormal Relay engine (hysteria)" "${urls[@]}"; then
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
cdn_svc_state() { systemctl is-active "$(cdn_svc "$1")" 2>/dev/null || echo unknown; }

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


relay_svc()        { printf 'phormal-relay@%s.service' "$1"; }
relay_svc_state()  { systemctl is-active "$(relay_svc "$1")" 2>/dev/null || echo unknown; }

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
  if [[ "$(relay_svc_state "${name}")" == "active" ]]; then
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
  local c; c="$(ask 'Edit raw hysteria config now? (y/n)')"
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

# ------------------------------------------------------------------------------
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
  rm -f /usr/bin/phormal-refresh.sh
  crontab -l 2>/dev/null | grep -v 'phormal-refresh' | crontab - 2>/dev/null || true
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
#  Menu
# ------------------------------------------------------------------------------
menu() {
  while :; do
    banner
    printf '  %sPHORMAL BRIDGE%s  %s(multi-tunnel)%s\n' "${BOLD}" "${RST}" "${MUT}" "${RST}"
    printf '    %s1%s  Add exit link\n' "${ACC}" "${RST}"
    printf '    %s2%s  Add entry link\n' "${ACC}" "${RST}"
    printf '    %s3%s  Manage links\n' "${ACC}" "${RST}"
    printf '    %s4%s  Speedtest\n' "${ACC}" "${RST}"
    printf '\n  %sPHORMAL RELAY%s  %s(multi-tunnel)%s\n' "${BOLD}" "${RST}" "${MUT}" "${RST}"
    printf '    %s5%s  Add exit tunnel\n' "${ACC}" "${RST}"
    printf '    %s6%s  Add entry tunnel\n' "${ACC}" "${RST}"
    printf '    %s7%s  Manage tunnels\n' "${ACC}" "${RST}"
    printf '    %s8%s  Speedtest\n' "${ACC}" "${RST}"
    printf '\n  %sMANAGE%s\n' "${BOLD}" "${RST}"
    printf '    %s9%s  Status\n' "${ACC}" "${RST}"
    printf '   %s10%s  Phormal tuning\n' "${ACC}" "${RST}"
    printf '   %s11%s  Auto-refresh schedule\n' "${ACC}" "${RST}"
    printf '   %s12%s  Uninstall\n' "${ACC}" "${RST}"
    printf '    %s0%s  Exit\n\n' "${ACC}" "${RST}"

    local choice; choice="$(ask 'Select')"
    echo
    case "${choice}" in
      1) create_bridge_exit || true ;;
      2) create_bridge_entry || true ;;
      3) manage_bridge_menu || true ;;
      4) local bn; bn="$(bridge_choose_instance)"; [[ -n "${bn}" ]] && bridge_instance_speedtest "${bn}" || true ;;
      5) create_exit_tunnel || true ;;
      6) create_entry_tunnel || true ;;
      7) manage_relay_menu || true ;;
      8) relay_speedtest || true ;;
      9) status || true ;;
      10) tune_menu || true ;;
      11) schedule_refresh || true ;;
      12) purge || true ;;
      0) good "Goodbye — @SchmitzWS"; exit 0 ;;
      *) fail "Invalid selection." ;;
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
