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
readonly PHORMAL_VERSION="2.1.2"
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

# ------------------------------------------------------------------------------
#  PHORMAL BRIDGE
# ------------------------------------------------------------------------------
write_core_files() {
  local local_v4="$1" remote_v4="$2" self_core="$3" peer_core="$4" mtu="$5"

  cat > "${CORE_UP_SCRIPT}" <<EOF
#!/usr/bin/env bash
ip link del ${CORE_IFACE} 2>/dev/null || true
ip tunnel add ${CORE_IFACE} mode sit remote ${remote_v4} local ${local_v4} ttl 255
ip link set ${CORE_IFACE} up
ip link set dev ${CORE_IFACE} mtu ${mtu}
ip -6 addr add ${self_core}/64 dev ${CORE_IFACE}

ip6tables -t mangle -C FORWARD -o ${CORE_IFACE} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
  || ip6tables -t mangle -A FORWARD -o ${CORE_IFACE} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
ip6tables -t mangle -C OUTPUT  -o ${CORE_IFACE} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
  || ip6tables -t mangle -A OUTPUT  -o ${CORE_IFACE} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
EOF
  chmod +x "${CORE_UP_SCRIPT}"

  cat > "${CORE_UNIT}" <<EOF
[Unit]
Description=Phormal Bridge link
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${CORE_UP_SCRIPT}
ExecStop=/sbin/ip link del ${CORE_IFACE}

[Install]
WantedBy=multi-user.target
EOF

  cat > "${GUARD_UNIT}" <<EOF
[Unit]
Description=Phormal Bridge guardian (keepalive)
After=phormal-core.service
Requires=phormal-core.service

[Service]
Type=simple
ExecStart=/usr/bin/env bash -c 'while :; do ping6 -c1 -W2 ${peer_core} >/dev/null 2>&1; sleep 15; done'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

deploy_bridge_core() {
  rule
  info "Phormal Bridge — link between entry and exit"
  rule

  local mode
  printf '  %s1%s  Provision a new link\n' "${ACC}" "${RST}"
  printf '  %s2%s  Attach to an existing link\n' "${ACC}" "${RST}"
  mode="$(ask 'Select')"

  if [[ "${mode}" == "2" ]]; then
    local peer; peer="$(ask 'Existing peer Phormal address')"
    ensure_dirs
    { echo "TRANSPORT=bridge"; echo "ROLE=entry"; echo "PEER_CORE=${peer}"; } > "${PHORMAL_CONF}"
    good "Attached. Phormal Bridge will route through ${peer}."
    return 0
  fi

  local role role_choice self_suffix peer_suffix
  printf '  %s1%s  Exit node     %s(foreign / clean uplink)%s\n' "${ACC}" "${RST}" "${MUT}" "${RST}"
  printf '  %s2%s  Entry node    %s(local / restricted uplink)%s\n' "${ACC}" "${RST}" "${MUT}" "${RST}"
  role_choice="$(ask 'Node role')"
  case "${role_choice}" in
    1) role="exit";  self_suffix="::1"; peer_suffix="::2" ;;
    2) role="entry"; self_suffix="::2"; peer_suffix="::1" ;;
    *) fail "Unknown role."; return 1 ;;
  esac

  local local_v4 remote_v4
  local_v4="$(ask 'This node public IPv4')"
  remote_v4="$(ask 'Peer node public IPv4')"
  if ! valid_ipv4 "${local_v4}" || ! valid_ipv4 "${remote_v4}"; then
    fail "Invalid IPv4 address."; return 1
  fi

  local suggested prefix
  suggested="$(random_core_prefix)"
  info "Bridge key (must match on both nodes). Suggested: ${BOLD}${suggested}${RST}"
  prefix="$(ask 'Bridge key [Enter for suggested]')"
  prefix="${prefix:-${suggested}}"

  local mtu
  info "Link MTU. Lower = more resilient on congested paths. Default ${DEFAULT_MTU}."
  mtu="$(ask "MTU [Enter for ${DEFAULT_MTU}]")"
  [[ "${mtu}" =~ ^[0-9]+$ ]] || mtu="${DEFAULT_MTU}"

  local self_core peer_core
  self_core="${prefix}${self_suffix}"
  peer_core="${prefix}${peer_suffix}"

  ensure_dirs
  cat > "${PHORMAL_CONF}" <<EOF
TRANSPORT=bridge
ROLE=${role}
LOCAL_V4=${local_v4}
REMOTE_V4=${remote_v4}
CORE_KEY=${prefix}
SELF_CORE=${self_core}
PEER_CORE=${peer_core}
CORE_MTU=${mtu}
EOF

  apt-get install -y iptables >/dev/null 2>&1 || true
  write_core_files "${local_v4}" "${remote_v4}" "${self_core}" "${peer_core}" "${mtu}"

  systemctl daemon-reload
  systemctl enable --now phormal-core.service  >/dev/null 2>&1
  systemctl enable --now phormal-guard.service >/dev/null 2>&1
  apply_tuning fq

  good "Bridge link established (MTU ${mtu})."
  info "  local  : ${self_core}"
  info "  peer   : ${peer_core}"
  local rx
  rx="$(ping6 -c5 -i0.3 -W2 "${peer_core}" 2>/dev/null | grep -oE '[0-9]+ received' | grep -oE '^[0-9]+' || echo 0)"
  if [[ "${rx:-0}" -gt 0 ]]; then
    good "Peer reachable (${rx}/5)."
  else
    warn "Peer not answering yet — bring up the other node, then check status."
  fi
}

retune_mtu() {
  local mtu; mtu="$(ask "New MTU (try ${DEFAULT_MTU}, then 1280 if uploads stall)")"
  [[ "${mtu}" =~ ^[0-9]+$ ]] || { fail "Not a number."; return 1; }
  ip link set dev "${CORE_IFACE}" mtu "${mtu}" 2>/dev/null \
    && good "Live MTU set to ${mtu} on ${CORE_IFACE}." \
    || { fail "Could not set MTU (is the Bridge link up?)"; return 1; }
  if [[ -f "${CORE_UP_SCRIPT}" ]]; then
    sed -i "s/mtu [0-9]\+/mtu ${mtu}/" "${CORE_UP_SCRIPT}"
    conf_set CORE_MTU "${mtu}"
    good "Persisted across reboots."
  fi
}

# ------------------------------------------------------------------------------
#  PHORMAL BRIDGE — port publisher
# ------------------------------------------------------------------------------
install_engine() {
  if [[ -x "${FWD_BIN}" ]] && "${FWD_BIN}" -V >/dev/null 2>&1; then
    good "Phormal publisher engine present."
    return 0
  fi
  info "Installing Phormal publisher engine…"
  apt_install_quiet curl wget tar gzip

  if bash <(curl -fsSL --connect-timeout 20 --max-time 180 \
      https://github.com/go-gost/gost/raw/master/install.sh) --install >/dev/null 2>&1 \
     && have gost; then
    ln -sf "$(command -v gost)" "${FWD_BIN}"
    good "Phormal publisher engine installed."
    return 0
  fi
  fail "Publisher engine install failed. Check connectivity and retry."
  return 1
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

deploy_bridge_forwarder() {
  rule
  info "Phormal Bridge — publish ports"
  rule

  local peer; peer="$(conf_get PEER_CORE)"
  if [[ -n "${peer}" ]]; then
    info "Destination from config: ${BOLD}${peer}${RST}"
    local keep; keep="$(ask 'Use this destination? (y/n)')"
    [[ "${keep}" != "y" ]] && peer="$(ask 'Destination Phormal address')"
  else
    peer="$(ask 'Destination Phormal address')"
  fi
  [[ -z "${peer}" ]] && { fail "No destination supplied."; return 1; }

  local proto pc
  printf '  %s1%s  tcp   %s2%s  udp   %s3%s  grpc\n' "${ACC}" "${RST}" "${ACC}" "${RST}" "${ACC}" "${RST}"
  pc="$(ask 'Transport')"
  case "${pc}" in 1) proto=tcp ;; 2) proto=udp ;; 3) proto=grpc ;; *) fail "Invalid transport."; return 1 ;; esac

  local ports; ports="$(gather_ports)"
  [[ -z "${ports}" ]] && { fail "No valid ports provided."; return 1; }

  conf_set BRIDGE_PROTO "${proto}"
  conf_set BRIDGE_PORTS "${ports}"
  apply_bridge_publisher "${peer}" "${proto}" "${ports}"
}

apply_bridge_publisher() {
  local peer="$1" proto="$2" ports="$3"

  install_engine || return 1

  sysctl -w net.ipv4.ip_local_port_range="1024 65535" >/dev/null 2>&1 || true
  echo 'net.ipv4.ip_local_port_range = 1024 65535' > /etc/sysctl.d/99-phormal.conf

  IFS=',' read -ra parr <<< "${ports}"
  local count=${#parr[@]}
  local units=$(( (count + MAX_PORTS_PER_UNIT - 1) / MAX_PORTS_PER_UNIT ))
  info "Publishing ${BOLD}${count}${RST} port(s) over ${units} worker(s)…"

  local u
  for ((u=0; u<units; u++)); do
    local unit="/etc/systemd/system/phormal-fwd@${u}.service"
    local exec="ExecStart=${FWD_BIN}"
    local i
    for ((i=u*MAX_PORTS_PER_UNIT; i<(u+1)*MAX_PORTS_PER_UNIT && i<count; i++)); do
      exec+=" -L=${proto}://:${parr[i]}/[${peer}]:${parr[i]}"
    done
    cat > "${unit}" <<EOF
[Unit]
Description=Phormal Bridge publisher ${u}
After=network.target phormal-core.service
Wants=network.target

[Service]
Type=simple
Environment="GOST_LOGGER_LEVEL=fatal"
${exec}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable "phormal-fwd@${u}.service" >/dev/null 2>&1
    systemctl daemon-reload
    systemctl restart "phormal-fwd@${u}.service"
  done

  good "Phormal Bridge publisher live."
}

redeploy_bridge_publisher() {
  local peer proto ports
  peer="$(conf_get PEER_CORE)"
  proto="$(conf_get BRIDGE_PROTO)"
  ports="$(conf_get BRIDGE_PORTS)"
  [[ -z "${peer}" || -z "${ports}" ]] && { fail "Phormal Bridge publisher not configured."; return 1; }
  [[ -z "${proto}" ]] && proto="tcp"
  apply_bridge_publisher "${peer}" "${proto}" "${ports}"
}

# ------------------------------------------------------------------------------
#  PHORMAL RELAY
# ------------------------------------------------------------------------------
install_relay_engine() {
  if [[ -x "${RELAY_BIN}" ]] && "${RELAY_BIN}" version >/dev/null 2>&1; then
    good "Phormal Relay engine present."
    return 0
  fi
  info "Installing Phormal Relay engine…"
  apt_install_quiet curl wget ca-certificates openssl

  local arch urls url
  arch="$(machine_arch)" || { fail "Unsupported architecture: $(uname -m)"; return 1; }

  urls=(
    "https://download.hysteria.network/app/latest/hysteria-linux-${arch}"
    "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${arch}"
  )

  for url in "${urls[@]}"; do
    info "Downloading engine (timeout 3 min)…"
    if fetch_url "${url}" "${RELAY_BIN}.tmp"; then
      chmod +x "${RELAY_BIN}.tmp"
      mv -f "${RELAY_BIN}.tmp" "${RELAY_BIN}"
      setcap cap_net_bind_service,cap_net_admin=+ep "${RELAY_BIN}" 2>/dev/null || true
      good "Phormal Relay engine installed."
      return 0
    fi
    warn "Download failed — trying next source…"
    rm -f "${RELAY_BIN}.tmp"
  done

  install_local_binary "${RELAY_BIN}" || return 1
  setcap cap_net_bind_service,cap_net_admin=+ep "${RELAY_BIN}" 2>/dev/null || true
  "${RELAY_BIN}" version >/dev/null 2>&1 || { fail "Binary is not runnable."; return 1; }
  good "Phormal Relay engine installed."
}

gen_relay_tls() {
  mkdir -p "${RELAY_HOME}"
  local cert="${RELAY_HOME}/cert.crt" key="${RELAY_HOME}/cert.key"
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

port_open_tcp() {
  local port="$1"
  ss -H -tln 2>/dev/null | grep -qE ":${port}([^0-9]|$)"
}

port_open_udp() {
  local port="$1"
  ss -H -ulnp 2>/dev/null | grep -qE ":${port}([^0-9]|$)"
}

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

gather_relay_credentials() {
  local suggested_auth suggested_obfs saved=0
  suggested_auth="$(rand_secret)"
  suggested_obfs="$(rand_secret)"

  if [[ -n "$(conf_get RELAY_AUTH)" ]]; then
    RELAY_AUTH="$(conf_get RELAY_AUTH)"
    RELAY_OBFS="$(conf_get RELAY_OBFS)"
    saved=1
  elif [[ -n "$(conf_get HY2_AUTH)" ]]; then
    RELAY_AUTH="$(conf_get HY2_AUTH)"
    RELAY_OBFS="$(conf_get HY2_OBFS)"
    saved=1
  fi

  if [[ ${saved} -eq 1 ]]; then
    warn "Saved credentials found — they must match the other node exactly."
    info "  Auth : ${BOLD}${RELAY_AUTH}${RST}"
    info "  Obfs : ${BOLD}${RELAY_OBFS}${RST}"
    local keep; keep="$(ask 'Use these? (y/n)')"
    [[ "${keep}" == "y" ]] && return 0
  fi

  info "Auth password. Suggested: ${BOLD}${suggested_auth}${RST}"
  RELAY_AUTH="$(ask 'Auth password [Enter for suggested]')"
  RELAY_AUTH="${RELAY_AUTH:-${suggested_auth}}"

  info "Obfuscation password. Suggested: ${BOLD}${suggested_obfs}${RST}"
  RELAY_OBFS="$(ask 'Obfuscation password [Enter for suggested]')"
  RELAY_OBFS="${RELAY_OBFS:-${suggested_obfs}}"
}

gather_relay_bandwidth() {
  local def_up def_down
  def_up="$(conf_get RELAY_UP_MBPS)"; def_up="${def_up:-$(conf_get HY2_UP_MBPS)}"
  def_up="${def_up:-50}"
  def_down="$(conf_get RELAY_DOWN_MBPS)"; def_down="${def_down:-$(conf_get HY2_DOWN_MBPS)}"
  def_down="${def_down:-100}"

  info "Enter your real link bandwidth between the two nodes."
  RELAY_UP_MBPS="$(ask "Upload mbps [${def_up}]")"
  RELAY_UP_MBPS="${RELAY_UP_MBPS:-${def_up}}"
  RELAY_DOWN_MBPS="$(ask "Download mbps [${def_down}]")"
  RELAY_DOWN_MBPS="${RELAY_DOWN_MBPS:-${def_down}}"
}

gather_relay_link_port() {
  RELAY_PORT_HOP="0"
  RELAY_HOP_INTERVAL="30s"

  local def
  def="$(conf_get RELAY_LISTEN)"
  [[ -z "${def}" ]] && def="$(conf_get HY2_LISTEN)"
  def="${def:-443}"

  info "Link port between nodes (not your user/client port)."
  RELAY_LISTEN="$(ask "Link port [${def}]")"
  RELAY_LISTEN="${RELAY_LISTEN:-${def}}"

  local hop; hop="$(ask 'Enable port hopping? (y/n) [n]')"
  [[ "${hop}" != "y" ]] && return 0

  RELAY_PORT_HOP="1"
  local range; range="$(ask 'Port range (e.g. 20000-50000)')"
  if [[ "${range}" =~ ^[0-9]+-[0-9]+$ ]]; then
    RELAY_LISTEN="${range}"
  else
    warn "Invalid range — using 20000-50000."
    RELAY_LISTEN="20000-50000"
  fi
  RELAY_HOP_INTERVAL="$(ask 'Hop interval [30s]')"
  RELAY_HOP_INTERVAL="${RELAY_HOP_INTERVAL:-30s}"
}

write_relay_systemd() {
  local mode="$1"
  cat > "${RELAY_UNIT}" <<EOF
[Unit]
Description=Phormal relay (${mode})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${RELAY_BIN} ${mode} -c ${RELAY_CONF}
Restart=always
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable phormal-relay.service >/dev/null 2>&1
  systemctl restart phormal-relay.service
  sleep 1
  if ! systemctl is-active phormal-relay.service >/dev/null 2>&1; then
    warn "Relay service failed to start. Recent log:"
    journalctl -u phormal-relay -n 12 --no-pager 2>/dev/null | sed 's/^/    /'
    return 1
  fi
}

save_relay_conf() {
  ensure_dirs
  conf_set TRANSPORT relay
  conf_set RELAY_AUTH "${RELAY_AUTH}"
  conf_set RELAY_OBFS "${RELAY_OBFS}"
  conf_set RELAY_UP_MBPS "${RELAY_UP_MBPS}"
  conf_set RELAY_DOWN_MBPS "${RELAY_DOWN_MBPS}"
  conf_set RELAY_LISTEN "${RELAY_LISTEN:-443}"
  conf_set RELAY_PORT_HOP "${RELAY_PORT_HOP:-0}"
  conf_set RELAY_HOP_INTERVAL "${RELAY_HOP_INTERVAL:-30s}"
}

write_relay_exit_config() {
  RELAY_LISTEN="${RELAY_LISTEN:-$(conf_get RELAY_LISTEN)}"
  RELAY_AUTH="${RELAY_AUTH:-$(conf_get RELAY_AUTH)}"
  RELAY_OBFS="${RELAY_OBFS:-$(conf_get RELAY_OBFS)}"
  RELAY_UP_MBPS="${RELAY_UP_MBPS:-$(conf_get RELAY_UP_MBPS)}"
  RELAY_DOWN_MBPS="${RELAY_DOWN_MBPS:-$(conf_get RELAY_DOWN_MBPS)}"
  mkdir -p "${RELAY_HOME}"
  cat > "${RELAY_CONF}" <<EOF
listen: :${RELAY_LISTEN}

tls:
  cert: ${RELAY_HOME}/cert.crt
  key: ${RELAY_HOME}/cert.key

auth:
  type: password
  password: ${RELAY_AUTH}

obfs:
  type: salamander
  salamander:
    password: ${RELAY_OBFS}

bandwidth:
  up: ${RELAY_UP_MBPS} mbps
  down: ${RELAY_DOWN_MBPS} mbps

speedTest: true

$(relay_engine_block)
EOF
}

write_relay_entry_config() {
  local server_ip="$1" listen="$2" ports="$3" hop_interval="${4:-30s}"
  RELAY_AUTH="${RELAY_AUTH:-$(conf_get RELAY_AUTH)}"
  RELAY_OBFS="${RELAY_OBFS:-$(conf_get RELAY_OBFS)}"
  RELAY_UP_MBPS="${RELAY_UP_MBPS:-$(conf_get RELAY_UP_MBPS)}"
  RELAY_DOWN_MBPS="${RELAY_DOWN_MBPS:-$(conf_get RELAY_DOWN_MBPS)}"
  mkdir -p "${RELAY_HOME}"
  {
    echo "server: ${server_ip}:${listen}"
    echo ""
    echo "auth: ${RELAY_AUTH}"
    echo ""
    echo "tls:"
    echo "  insecure: true"
    echo ""
    echo "obfs:"
    echo "  type: salamander"
    echo "  salamander:"
    echo "    password: ${RELAY_OBFS}"
    echo ""
    echo "bandwidth:"
    echo "  up: ${RELAY_UP_MBPS} mbps"
    echo "  down: ${RELAY_DOWN_MBPS} mbps"
    echo ""
    relay_engine_block
    echo ""
    if [[ "${listen}" == *-* ]]; then
      cat <<EOF
transport:
  type: udp
  udp:
    hopInterval: ${hop_interval}
EOF
    fi
    echo ""
    echo "lazy: true"
    echo ""
    echo "tcpForwarding:"
    local p
    IFS=',' read -ra parr <<< "${ports}"
    for p in "${parr[@]}"; do
      echo "  - listen: :${p}"
      echo "    remote: 127.0.0.1:${p}"
    done
    echo ""
    echo "udpForwarding:"
    for p in "${parr[@]}"; do
      echo "  - listen: :${p}"
      echo "    remote: 127.0.0.1:${p}"
      echo "    timeout: 60s"
    done
  } > "${RELAY_CONF}"
}

deploy_relay_exit() {
  rule
  info "Phormal Relay — exit node"
  info "Run your service locally on the ports you will publish."
  rule

  install_relay_engine || return 1
  gen_relay_tls
  enable_relay_buffers
  apply_tuning fq

  gather_relay_credentials
  gather_relay_bandwidth
  gather_relay_link_port

  write_relay_exit_config
  save_relay_conf
  conf_set RELAY_ROLE exit
  write_relay_systemd server || return 1

  good "Phormal Relay live on link port ${RELAY_LISTEN}"
  info "  Link port         : ${RELAY_LISTEN}  ${MUT}(entry must use this — not user ports like 6161)${RST}"
  info "  Auth password     : ${RELAY_AUTH}"
  info "  Obfuscation pass  : ${RELAY_OBFS}"
  info "  Link bandwidth    : ↑${RELAY_UP_MBPS} / ↓${RELAY_DOWN_MBPS} mbps"
  [[ "${RELAY_PORT_HOP}" == "1" ]] && info "  Port hopping      : ${RELAY_LISTEN}"
  warn "Copy link port + both passwords to the entry node."
  echo
  relay_diagnose
}

deploy_relay_entry() {
  rule
  info "Phormal Relay — entry node"
  info "Listens on user ports, forwards to your service on the exit node."
  rule

  install_relay_engine || return 1
  enable_relay_buffers
  apply_tuning fq

  local server_ip
  server_ip="$(conf_get REMOTE_V4)"
  if [[ -n "${server_ip}" ]]; then
    info "Exit node IP from config: ${BOLD}${server_ip}${RST}"
    local keep; keep="$(ask 'Use this IP? (y/n)')"
    [[ "${keep}" != "y" ]] && server_ip="$(ask 'Exit node public IPv4')"
  else
    server_ip="$(ask 'Exit node public IPv4')"
  fi
  if ! valid_ipv4 "${server_ip}"; then
    fail "Invalid IPv4 address."; return 1
  fi

  gather_relay_credentials
  gather_relay_bandwidth

  local listen saved_listen hop_interval
  saved_listen="$(conf_get RELAY_LISTEN)"
  [[ -z "${saved_listen}" ]] && saved_listen="$(conf_get HY2_LISTEN)"
  listen="${saved_listen:-443}"
  if [[ -z "${saved_listen}" ]]; then
    info "Link port on exit — must match exit node exactly (NOT your user port 6161)."
    listen="$(ask 'Link port or range [443]')"
    listen="${listen:-443}"
  else
    info "Link port from saved config: ${BOLD}${listen}${RST}"
    local relisten; relisten="$(ask 'Keep this link port? (y/n)')"
    [[ "${relisten}" != "y" ]] && listen="$(ask 'Link port or range')"
  fi
  if [[ "${listen}" == *-* ]]; then
    info "Port hopping enabled — rotating across ${listen}"
  fi

  hop_interval="$(conf_get RELAY_HOP_INTERVAL)"
  [[ -z "${hop_interval}" ]] && hop_interval="$(conf_get HY2_HOP_INTERVAL)"
  hop_interval="${hop_interval:-30s}"

  local ports; ports="$(gather_ports)"
  [[ -z "${ports}" ]] && { fail "No valid ports provided."; return 1; }

  RELAY_LISTEN="${listen}"
  RELAY_PORT_HOP="0"
  [[ "${listen}" == *-* ]] && RELAY_PORT_HOP="1"
  RELAY_HOP_INTERVAL="${hop_interval}"

  write_relay_entry_config "${server_ip}" "${listen}" "${ports}" "${hop_interval}"
  save_relay_conf
  conf_set RELAY_ROLE entry
  conf_set RELAY_PORTS "${ports}"
  conf_set REMOTE_V4 "${server_ip}"

  write_relay_systemd client || return 1

  IFS=',' read -ra parr <<< "${ports}"
  local count=${#parr[@]}
  good "Phormal Relay live — ${count} port(s) published."
  info "  Link target       : ${server_ip}:${listen}"
  info "  Link bandwidth    : ↑${RELAY_UP_MBPS} / ↓${RELAY_DOWN_MBPS} mbps"
  info "  Published ports   : ${ports}"
  good "Point your users at this node's public IP on those ports."
  warn "Your client must use this entry node's IP — not the exit IP."
  echo
  relay_diagnose
}

relay_diagnose() {
  rule
  info "Phormal Relay — diagnostics"
  rule

  if [[ ! -f "${RELAY_CONF}" ]]; then
    warn "No relay config at ${RELAY_CONF}"
    return 1
  fi

  local r_role r_remote r_listen
  r_role="$(conf_get RELAY_ROLE)"
  [[ -z "${r_role}" ]] && r_role="$(conf_get HY2_ROLE)"
  r_remote="$(conf_get REMOTE_V4)"
  r_listen="$(conf_get RELAY_LISTEN)"
  [[ -z "${r_listen}" ]] && r_listen="$(conf_get HY2_LISTEN)"

  local svc; svc="$(systemctl is-active phormal-relay.service 2>/dev/null || echo unknown)"
  if [[ "${svc}" == "active" ]]; then
    good "phormal-relay.service is active"
  else
    fail "phormal-relay.service is ${svc}"
    journalctl -u phormal-relay -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
  fi

  if [[ "${r_role}" == "entry" ]]; then
    info "Entry checks"
    local pub_ports
    pub_ports="$(grep -E '^\s+-\s+listen:\s+:' "${RELAY_CONF}" 2>/dev/null \
      | sed 's/.*://;s/[^0-9].*//' | sort -un | paste -sd, -)"
    if [[ -n "${pub_ports}" ]]; then
      local p
      IFS=',' read -ra parr <<< "${pub_ports}"
      for p in "${parr[@]}"; do
        if port_open_tcp "${p}"; then
          good "TCP :${p} listening (users connect here)"
        else
          fail "TCP :${p} not listening"
        fi
      done
    fi
    if [[ -n "${r_remote}" && -n "${r_listen}" ]]; then
      local hop_port="${r_listen%-*}"
      info "Link target: ${r_remote}:${hop_port}"
      if journalctl -u phormal-relay --since '5 min ago' 2>/dev/null \
         | grep -q 'TCP forwarding error'; then
        warn "Recent forwarding errors in log — check link port + passwords match exit"
        info "  → journalctl -u phormal-relay -n 20"
      elif journalctl -u phormal-relay --since '2 min ago' 2>/dev/null \
         | grep -qE 'TCP forwarding listening|UDP forwarding listening'; then
        good "Relay publisher ready"
      fi
    fi
    info "Client address must be this server's public IP, port(s): ${pub_ports:-?}"
  elif [[ "${r_role}" == "exit" ]]; then
    info "Exit checks"
    local hop_port="${r_listen%-*}"
    if port_open_udp "${hop_port}" \
       || journalctl -u phormal-relay --since '30 min ago' 2>/dev/null \
          | grep -qF "\"listen\": \":${hop_port}\""; then
      good "Link port ${hop_port} up"
    else
      warn "Link port ${hop_port} not confirmed — check: journalctl -u phormal-relay -n 10"
    fi
    info "Make sure your service listens on the published port(s)."
    local rp p
    rp="$(conf_get RELAY_PORTS)"
    if [[ -n "${rp}" ]]; then
      IFS=',' read -ra parr <<< "${rp}"
      for p in "${parr[@]}"; do
        if port_open_tcp "${p}"; then
          good "TCP :${p} listening (service)"
        else
          warn "Nothing on TCP :${p} - start your service on this port"
        fi
      done
    fi
    info "Auth : $(conf_get RELAY_AUTH)"
    info "Obfs : $(conf_get RELAY_OBFS)"
    warn "Give these two passwords to the entry node."
  fi

  echo
  info "Recent relay log"
  journalctl -u phormal-relay -n 8 --no-pager 2>/dev/null | sed 's/^/    /' || warn "no log entries"
  rule
}

bridge_rewrite_config() {
  info "  ${PHORMAL_CONF}"
  info "  ${CORE_UP_SCRIPT}"
  local c; c="$(ask 'Open main config in editor? (y/n)')"
  [[ "${c}" == "y" ]] && ${EDITOR:-nano} "${PHORMAL_CONF}"
  local r; r="$(ask 'Rebuild from config and restart? (y/n)')"
  [[ "${r}" == "y" ]] && bridge_rebuild_from_conf
}

bridge_rebuild_from_conf() {
  local local_v4 remote_v4 self_core peer_core mtu
  local_v4="$(conf_get LOCAL_V4)"
  remote_v4="$(conf_get REMOTE_V4)"
  self_core="$(conf_get SELF_CORE)"
  peer_core="$(conf_get PEER_CORE)"
  mtu="$(conf_get CORE_MTU)"; mtu="${mtu:-${DEFAULT_MTU}}"
  [[ -z "${local_v4}" || -z "${remote_v4}" || -z "${self_core}" || -z "${peer_core}" ]] \
    && { fail "Bridge link incomplete in config."; return 1; }
  write_core_files "${local_v4}" "${remote_v4}" "${self_core}" "${peer_core}" "${mtu}"
  systemctl restart phormal-core.service phormal-guard.service 2>/dev/null || true
  redeploy_bridge_publisher 2>/dev/null || true
  good "Phormal Bridge rebuilt from config."
}

bridge_change_addresses() {
  local lv rv
  lv="$(ask "This node IP [$(conf_get LOCAL_V4)]")"
  rv="$(ask "Peer node IP [$(conf_get REMOTE_V4)]")"
  [[ -n "${lv}" ]] && conf_set LOCAL_V4 "${lv}"
  [[ -n "${rv}" ]] && conf_set REMOTE_V4 "${rv}"
  bridge_rebuild_from_conf
}

bridge_add_port() {
  local ports new
  ports="$(conf_get BRIDGE_PORTS)"
  new="$(ask 'Port to add')"
  [[ "${new}" =~ ^[0-9]+$ ]] || { fail "Invalid port."; return 1; }
  conf_set BRIDGE_PORTS "$(merge_port_list "${ports}" "${new}")"
  redeploy_bridge_publisher
}

bridge_remove_port() {
  local ports rem
  ports="$(conf_get BRIDGE_PORTS)"
  info "Current ports: ${ports:-none}"
  rem="$(ask 'Port to remove')"
  ports="$(remove_port_from_list "${ports}" "${rem}")"
  [[ -z "${ports}" ]] && { fail "Cannot remove last port."; return 1; }
  conf_set BRIDGE_PORTS "${ports}"
  redeploy_bridge_publisher
}

bridge_speedtest() {
  install_speed_tool || return 1
  rule
  info "Phormal Bridge — speedtest"
  info "Order: run step 1 on exit, then step 2 on entry (within ~30s)."
  rule
  printf '  %s1%s  Exit node — start listener\n' "${ACC}" "${RST}"
  printf '  %s2%s  Entry node — run test\n' "${ACC}" "${RST}"
  local step; step="$(ask 'Step')"
  case "${step}" in
    1)
      local bind; bind="$(conf_get SELF_CORE)"
      [[ -z "${bind}" ]] && { fail "Configure exit node first."; return 1; }
      info "Listening on ${bind}:${PHORMAL_SPEED_PORT}…"
      iperf3 -s -B "${bind}" -p "${PHORMAL_SPEED_PORT}" -1 \
        || { fail "Speed listener failed."; return 1; }
      ;;
    2)
      local peer; peer="$(conf_get PEER_CORE)"
      [[ -z "${peer}" ]] && { fail "Configure entry node first."; return 1; }
      warn "Step 1 must be running on the exit node before you continue."
      local ready; ready="$(ask 'Exit listener running? (y/n)')"
      [[ "${ready}" =~ ^[Yy] ]] || { info "Cancelled."; return 0; }
      info "Testing to ${peer}:${PHORMAL_SPEED_PORT} for 10s…"
      if ! iperf3 -c "${peer}" -p "${PHORMAL_SPEED_PORT}" -t 10 -f m; then
        fail "Speedtest failed — is step 1 still running on the exit node?"
        return 1
      fi
      ;;
    *) fail "Invalid step." ;;
  esac
}

manage_bridge_menu() {
  grep -qE '^PEER_CORE=' "${PHORMAL_CONF}" 2>/dev/null || { fail "Phormal Bridge not deployed."; return 1; }
  while :; do
    rule
    info "Phormal Bridge — manage"
    rule
    printf '  %s1%s  Restart services\n' "${ACC}" "${RST}"
    printf '  %s2%s  Rewrite config files\n' "${ACC}" "${RST}"
    printf '  %s3%s  Rebuild link from config\n' "${ACC}" "${RST}"
    printf '  %s4%s  Add port\n' "${ACC}" "${RST}"
    printf '  %s5%s  Remove port\n' "${ACC}" "${RST}"
    printf '  %s6%s  Change node addresses\n' "${ACC}" "${RST}"
    printf '  %s7%s  Speedtest\n' "${ACC}" "${RST}"
    printf '  %s0%s  Back\n\n' "${ACC}" "${RST}"
    local c; c="$(ask 'Select')"
    echo
    case "${c}" in
      1) restart_bridge_services ;;
      2) bridge_rewrite_config ;;
      3) bridge_rebuild_from_conf ;;
      4) bridge_add_port ;;
      5) bridge_remove_port ;;
      6) bridge_change_addresses ;;
      7) bridge_speedtest ;;
      0) break ;;
      *) fail "Invalid selection." ;;
    esac
    echo
  done
}

relay_rewrite_config() {
  local role; role="$(conf_get RELAY_ROLE)"
  [[ -z "${role}" ]] && { fail "Phormal Relay not configured."; return 1; }
  info "  ${PHORMAL_CONF}"
  info "  ${RELAY_CONF}"
  local c; c="$(ask 'Edit main config? (y/n)')"
  [[ "${c}" == "y" ]] && ${EDITOR:-nano} "${PHORMAL_CONF}"
  local y; y="$(ask 'Edit relay config? (y/n)')"
  [[ "${y}" == "y" ]] && ${EDITOR:-nano} "${RELAY_CONF}"
  if [[ "${role}" == "exit" ]]; then
    write_relay_exit_config
    write_relay_systemd server
  else
    local hop; hop="$(conf_get RELAY_HOP_INTERVAL)"; hop="${hop:-30s}"
    write_relay_entry_config "$(conf_get REMOTE_V4)" "$(conf_get RELAY_LISTEN)" "$(conf_get RELAY_PORTS)" "${hop}"
    write_relay_systemd client
  fi
  good "Phormal Relay configs saved and service restarted."
}

relay_reapply_settings() {
  local role; role="$(conf_get RELAY_ROLE)"
  [[ -z "${role}" ]] && { fail "Phormal Relay not configured."; return 1; }
  gather_relay_credentials
  gather_relay_bandwidth
  if [[ "${role}" == "exit" ]]; then
    gather_relay_link_port
    write_relay_exit_config
    save_relay_conf
    write_relay_systemd server
  else
    local listen hop
    listen="$(conf_get RELAY_LISTEN)"
    hop="$(conf_get RELAY_HOP_INTERVAL)"; hop="${hop:-30s}"
    RELAY_LISTEN="${listen}"
    write_relay_entry_config "$(conf_get REMOTE_V4)" "${listen}" "$(conf_get RELAY_PORTS)" "${hop}"
    save_relay_conf
    write_relay_systemd client
  fi
  good "Phormal Relay settings reapplied."
}

relay_change_exit_ip() {
  [[ "$(conf_get RELAY_ROLE)" != "entry" ]] && { fail "Only on entry node."; return 1; }
  local ip; ip="$(ask "Exit node IP [$(conf_get REMOTE_V4)]")"
  [[ -z "${ip}" ]] && return 0
  valid_ipv4 "${ip}" || { fail "Invalid IPv4."; return 1; }
  conf_set REMOTE_V4 "${ip}"
  local hop; hop="$(conf_get RELAY_HOP_INTERVAL)"; hop="${hop:-30s}"
  write_relay_entry_config "${ip}" "$(conf_get RELAY_LISTEN)" "$(conf_get RELAY_PORTS)" "${hop}"
  write_relay_systemd client
  good "Exit node IP updated."
}

relay_add_port() {
  [[ "$(conf_get RELAY_ROLE)" != "entry" ]] && { fail "Only on entry node."; return 1; }
  local ports new hop
  ports="$(conf_get RELAY_PORTS)"
  new="$(ask 'Port to add')"
  [[ "${new}" =~ ^[0-9]+$ ]] || { fail "Invalid port."; return 1; }
  ports="$(merge_port_list "${ports}" "${new}")"
  conf_set RELAY_PORTS "${ports}"
  hop="$(conf_get RELAY_HOP_INTERVAL)"; hop="${hop:-30s}"
  write_relay_entry_config "$(conf_get REMOTE_V4)" "$(conf_get RELAY_LISTEN)" "${ports}" "${hop}"
  write_relay_systemd client
  good "Port ${new} added."
}

relay_remove_port() {
  [[ "$(conf_get RELAY_ROLE)" != "entry" ]] && { fail "Only on entry node."; return 1; }
  local ports rem hop
  ports="$(conf_get RELAY_PORTS)"
  info "Current ports: ${ports:-none}"
  rem="$(ask 'Port to remove')"
  ports="$(remove_port_from_list "${ports}" "${rem}")"
  [[ -z "${ports}" ]] && { fail "Cannot remove last port."; return 1; }
  conf_set RELAY_PORTS "${ports}"
  hop="$(conf_get RELAY_HOP_INTERVAL)"; hop="${hop:-30s}"
  write_relay_entry_config "$(conf_get REMOTE_V4)" "$(conf_get RELAY_LISTEN)" "${ports}" "${hop}"
  write_relay_systemd client
  good "Port ${rem} removed."
}

relay_enable_speedtest_server() {
  [[ "$(conf_get RELAY_ROLE)" != "exit" ]] && return 1
  if grep -qE '^speedTest:\s*true' "${RELAY_CONF}" 2>/dev/null; then
    good "Speedtest support already enabled on exit."
    return 0
  fi
  info "Enabling built-in speedtest on exit…"
  write_relay_exit_config
  write_relay_systemd server || return 1
  good "Exit ready for entry-node speedtests."
}

relay_speedtest() {
  install_relay_engine || return 1
  local role; role="$(conf_get RELAY_ROLE)"
  rule
  info "Phormal Relay — speedtest"
  rule

  if [[ "${role}" == "exit" ]]; then
    info "Speedtest runs from the entry node — nothing to start here."
    relay_enable_speedtest_server || return 1
    info "Now run Speedtest on the entry node (Manage → 8)."
    return 0
  fi

  if [[ "${role}" != "entry" ]]; then
    fail "Phormal Relay role unknown."
    return 1
  fi

  if ! "${RELAY_BIN}" speedtest --help >/dev/null 2>&1; then
    fail "Relay engine too old for built-in speedtest (need 2.3+)."
    return 1
  fi

  info "Testing link to exit node (10s each direction)…"
  info "Both nodes must keep phormal-relay running."
  if ! "${RELAY_BIN}" speedtest -c "${RELAY_CONF}" --duration 10s; then
    fail "Speedtest failed."
    warn "On exit: Manage → 8 Speedtest once to enable support, then retry here."
    return 1
  fi
}

manage_relay_menu() {
  [[ -f "${RELAY_CONF}" ]] || { fail "Phormal Relay not deployed."; return 1; }
  while :; do
    rule
    info "Phormal Relay — manage"
    rule
    printf '  %s1%s  Restart service\n' "${ACC}" "${RST}"
    printf '  %s2%s  Rewrite config files\n' "${ACC}" "${RST}"
    printf '  %s3%s  Reapply settings\n' "${ACC}" "${RST}"
    printf '  %s4%s  Add port\n' "${ACC}" "${RST}"
    printf '  %s5%s  Remove port\n' "${ACC}" "${RST}"
    printf '  %s6%s  Change exit node IP\n' "${ACC}" "${RST}"
    printf '  %s7%s  Diagnostics\n' "${ACC}" "${RST}"
    printf '  %s8%s  Speedtest\n' "${ACC}" "${RST}"
    printf '  %s0%s  Back\n\n' "${ACC}" "${RST}"
    local c; c="$(ask 'Select')"
    echo
    case "${c}" in
      1) restart_relay_service || true ;;
      2) relay_rewrite_config || true ;;
      3) relay_reapply_settings || true ;;
      4) relay_add_port || true ;;
      5) relay_remove_port || true ;;
      6) relay_change_exit_ip || true ;;
      7) relay_diagnose || true ;;
      8) relay_speedtest || true ;;
      0) break ;;
      *) fail "Invalid selection." ;;
    esac
    echo
  done
}

quick_deploy_relay() {
  rule
  info "Phormal Relay — quick deploy"
  rule

  local role_choice
  printf '  %s1%s  Exit node\n' "${ACC}" "${RST}"
  printf '  %s2%s  Entry node\n' "${ACC}" "${RST}"
  role_choice="$(ask 'Node role')"

  case "${role_choice}" in
    1) deploy_relay_exit ;;
    2) deploy_relay_entry ;;
    *) fail "Unknown role."; return 1 ;;
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
systemctl restart 'phormal-fwd@*.service' 2>/dev/null || true
systemctl restart phormal-guard.service 2>/dev/null || true
systemctl restart phormal-relay.service 2>/dev/null || true
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
  info "BRIDGE"
  if grep -qE '^PEER_CORE=' "${PHORMAL_CONF}" 2>/dev/null; then
    local role self peer mtu
    role="$(conf_get ROLE)"; self="$(conf_get SELF_CORE)"; peer="$(conf_get PEER_CORE)"; mtu="$(conf_get CORE_MTU)"
    printf '    role    : %s\n' "${role:-?}"
    [[ -n "${self}" ]] && printf '    local   : %s\n' "${self}"
    [[ -n "${peer}" ]] && printf '    peer    : %s\n' "${peer}"
    [[ -n "${mtu}"  ]] && printf '    mtu     : %s\n' "${mtu}"
    if [[ -n "${peer}" ]]; then
      local rx
      rx="$(ping6 -c5 -i0.3 -W2 "${peer}" 2>/dev/null | grep -oE '[0-9]+ received' | grep -oE '^[0-9]+' || echo 0)"
      if [[ "${rx:-0}" -gt 0 ]]; then good "peer reachable (${rx}/5)"; else warn "peer unreachable (0/5)"; fi
    fi
  else
    warn "no Bridge link configured"
  fi
  echo
  info "PHORMAL TUNING"
  printf '    profile : %s / %s\n' \
    "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')" \
    "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
  echo
  info "BRIDGE FORWARDERS"
  local found=0 u name st
  for u in /etc/systemd/system/phormal-fwd@*.service; do
    [[ -e "${u}" ]] || continue
    found=1; name="$(basename "${u}" .service)"
    st="$(systemctl is-active "${name}" 2>/dev/null || echo unknown)"
    printf '    %-22s : %s\n' "${name}" "${st}"
  done
  [[ ${found} -eq 0 ]] && warn "no forwarder workers configured"
  echo
  info "RELAY"
  if [[ -f "${RELAY_CONF}" ]]; then
    local r_role r_listen r_remote
    r_role="$(conf_get RELAY_ROLE)"
    [[ -z "${r_role}" ]] && r_role="$(conf_get HY2_ROLE)"
    r_listen="$(conf_get RELAY_LISTEN)"
    [[ -z "${r_listen}" ]] && r_listen="$(conf_get HY2_LISTEN)"
    r_remote="$(conf_get REMOTE_V4)"
    printf '    role    : %s\n' "${r_role:-?}"
    [[ -n "${r_listen}" ]] && printf '    link    : %s\n' "${r_listen}"
    [[ -n "${r_remote}" ]] && printf '    exit ip : %s\n' "${r_remote}"
    local r_st; r_st="$(systemctl is-active phormal-relay.service 2>/dev/null || echo unknown)"
    printf '    service : %s\n' "${r_st}"
    if [[ "${r_st}" == "active" ]]; then good "relay running"; else warn "relay not active"; fi
  else
    warn "no relay configured"
  fi
  rule
}

purge() {
  local c; c="$(ask 'Remove Phormal entirely? (y/n)')"
  [[ "${c}" != "y" ]] && { info "Cancelled."; return; }
  systemctl stop    'phormal-fwd@*.service' 2>/dev/null || true
  systemctl disable 'phormal-fwd@*.service' 2>/dev/null || true
  rm -f /etc/systemd/system/phormal-fwd@*.service
  systemctl stop phormal-relay.service 2>/dev/null || true
  systemctl disable phormal-relay.service 2>/dev/null || true
  systemctl stop phormal-hysteria.service 2>/dev/null || true
  systemctl disable phormal-hysteria.service 2>/dev/null || true
  rm -f "${RELAY_UNIT}" /etc/systemd/system/phormal-hysteria.service
  for s in phormal-guard phormal-core; do
    systemctl stop "${s}.service" 2>/dev/null || true
    systemctl disable "${s}.service" 2>/dev/null || true
  done
  ip link del "${CORE_IFACE}" 2>/dev/null || true
  rm -f "${CORE_UNIT}" "${GUARD_UNIT}" /etc/sysctl.d/99-phormal.conf \
    /etc/sysctl.d/98-phormal-tuning.conf /etc/sysctl.d/98-phormal-bbr.conf \
    "${RELAY_SYSCTL}" /etc/sysctl.d/97-phormal-hysteria.conf /etc/sysctl.d/97-phormal-relay.conf
  rm -f "${RELAY_BIN}" /usr/local/bin/phormal-hy2
  rm -f /usr/bin/phormal-refresh.sh
  crontab -l 2>/dev/null | grep -v 'phormal-refresh' | crontab - 2>/dev/null || true
  rm -rf "${PHORMAL_HOME}"
  systemctl daemon-reload
  good "Phormal removed. (CLI shortcut left at ${CLI_LINK}; delete manually if desired.)"
}

quick_deploy_bridge() {
  deploy_bridge_core || { fail "Bridge step failed."; return; }
  local role; role="$(conf_get ROLE)"
  if [[ "${role}" == "exit" ]]; then
    echo
    info "Exit node ready — run your service on the ports you will publish."
    info "Deploy the entry node next to expose them."
  else
    echo
    local g; g="$(ask 'Publish ports now? (y/n)')"
    [[ "${g}" == "y" ]] && deploy_bridge_forwarder
  fi
}

install_cli() {
  # Make `phormal` runnable from anywhere after first run
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
    printf '  %sPHORMAL BRIDGE%s\n' "${BOLD}" "${RST}"
    printf '    %s1%s  Quick deploy\n' "${ACC}" "${RST}"
    printf '    %s2%s  Link only\n' "${ACC}" "${RST}"
    printf '    %s3%s  Port publisher only\n' "${ACC}" "${RST}"
    printf '    %s4%s  Manage\n' "${ACC}" "${RST}"
    printf '\n  %sPHORMAL RELAY%s\n' "${BOLD}" "${RST}"
    printf '    %s5%s  Quick deploy\n' "${ACC}" "${RST}"
    printf '    %s6%s  Exit node only\n' "${ACC}" "${RST}"
    printf '    %s7%s  Entry node only\n' "${ACC}" "${RST}"
    printf '    %s8%s  Manage\n' "${ACC}" "${RST}"
    printf '\n  %sMANAGE%s\n' "${BOLD}" "${RST}"
    printf '    %s9%s  Status\n' "${ACC}" "${RST}"
    printf '   %s10%s  Phormal tuning\n' "${ACC}" "${RST}"
    printf '   %s11%s  Adjust Bridge MTU\n' "${ACC}" "${RST}"
    printf '   %s12%s  Auto-refresh schedule\n' "${ACC}" "${RST}"
    printf '   %s13%s  Uninstall\n' "${ACC}" "${RST}"
    printf '    %s0%s  Exit\n\n' "${ACC}" "${RST}"

    local choice; choice="$(ask 'Select')"
    echo
    case "${choice}" in
      1) quick_deploy_bridge ;;
      2) deploy_bridge_core ;;
      3) deploy_bridge_forwarder ;;
      4) manage_bridge_menu ;;
      5) quick_deploy_relay ;;
      6) deploy_relay_exit ;;
      7) deploy_relay_entry ;;
      8) manage_relay_menu ;;
      9) status ;;
      10) tune_menu ;;
      11) retune_mtu ;;
      12) schedule_refresh ;;
      13) purge ;;
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
