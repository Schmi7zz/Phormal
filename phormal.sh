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
readonly PHORMAL_VERSION="3.1.2"
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
  info "Installing Phormal Relay engine…"
  apt_install_quiet curl wget ca-certificates openssl libcap2-bin

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

  write_instance_entry_config "${name}"
  relay_start_instance "${name}" || return 1

  echo
  good "Entry tunnel '${name}' live — ports: ${ports}"
  info "  Link target : ${server_ip}:${listen}"
  good "Point users at THIS server's public IP on those ports (never the exit IP)."
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
#  BRIDGE — management (unchanged)
# ==============================================================================
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
      iperf3 -s -B "${bind}" -p "${PHORMAL_SPEED_PORT}" -1 || { fail "Speed listener failed."; return 1; }
      ;;
    2)
      local peer; peer="$(conf_get PEER_CORE)"
      [[ -z "${peer}" ]] && { fail "Configure entry node first."; return 1; }
      warn "Step 1 must be running on the exit node before you continue."
      local ready; ready="$(ask 'Exit listener running? (y/n)')"
      [[ "${ready}" =~ ^[Yy] ]] || { info "Cancelled."; return 0; }
      info "Testing to ${peer}:${PHORMAL_SPEED_PORT} for 10s…"
      iperf3 -c "${peer}" -p "${PHORMAL_SPEED_PORT}" -t 10 -f m \
        || { fail "Speedtest failed — is step 1 still running on the exit node?"; return 1; }
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
  # bridge forwarders
  for u in /etc/systemd/system/phormal-fwd@*.service; do
    [[ -e "${u}" ]] || continue
    local nm; nm="$(basename "${u}")"
    systemctl stop "${nm}" 2>/dev/null || true
    systemctl disable "${nm}" 2>/dev/null || true
  done
  rm -f /etc/systemd/system/phormal-fwd@*.service
  # relay instances (new template)
  local n
  while read -r n; do
    [[ -n "${n}" ]] || continue
    systemctl stop "$(relay_svc "${n}")" 2>/dev/null || true
    systemctl disable "$(relay_svc "${n}")" 2>/dev/null || true
  done < <(relay_instances)
  rm -f "${RELAY_TEMPLATE_UNIT}" "${RELAY_RUN}"
  # legacy single-instance relay + hysteria units
  systemctl stop phormal-relay.service phormal-hysteria.service 2>/dev/null || true
  systemctl disable phormal-relay.service phormal-hysteria.service 2>/dev/null || true
  rm -f "${RELAY_UNIT}" /etc/systemd/system/phormal-hysteria.service
  # bridge core/guard
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
    printf '\n  %sPHORMAL RELAY%s  %s(multi-tunnel)%s\n' "${BOLD}" "${RST}" "${MUT}" "${RST}"
    printf '    %s5%s  Add exit tunnel\n' "${ACC}" "${RST}"
    printf '    %s6%s  Add entry tunnel\n' "${ACC}" "${RST}"
    printf '    %s7%s  Manage tunnels\n' "${ACC}" "${RST}"
    printf '    %s8%s  Speedtest\n' "${ACC}" "${RST}"
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
      1) quick_deploy_bridge || true ;;
      2) deploy_bridge_core || true ;;
      3) deploy_bridge_forwarder || true ;;
      4) manage_bridge_menu || true ;;
      5) create_exit_tunnel || true ;;
      6) create_entry_tunnel || true ;;
      7) manage_relay_menu || true ;;
      8) relay_speedtest || true ;;
      9) status || true ;;
      10) tune_menu || true ;;
      11) retune_mtu || true ;;
      12) schedule_refresh || true ;;
      13) purge || true ;;
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
