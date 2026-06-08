#!/usr/bin/env bash
# ==============================================================================
#  Phormal Tunnel
#  A fast, resilient tunneling layer for bridging two servers across hostile
#  networks. Builds an encrypted-friendly core link between an entry node and an
#  exit node, then multiplexes your service ports across it.
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
readonly PHORMAL_VERSION="1.0.0"
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

random_core_prefix() {
  printf 'fd%02x:%02x%02x:%02x%02x:%02x%02x' \
    $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) \
    $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

conf_get() { [[ -f "${PHORMAL_CONF}" ]] && grep -E "^${1}=" "${PHORMAL_CONF}" | head -n1 | cut -d= -f2- || true; }

# ------------------------------------------------------------------------------
#  CORE LINK  (entry <-> exit transport)
# ------------------------------------------------------------------------------
deploy_core() {
  rule
  info "Phormal Core — secure link between your entry and exit nodes"
  rule

  local mode
  printf '  %s1%s  Provision a new Core link\n' "${ACC}" "${RST}"
  printf '  %s2%s  Attach to an existing Core link\n' "${ACC}" "${RST}"
  mode="$(ask 'Select')"

  if [[ "${mode}" == "2" ]]; then
    local peer; peer="$(ask 'Existing peer Core address')"
    ensure_dirs
    { echo "ROLE=entry"; echo "PEER_CORE=${peer}"; } > "${PHORMAL_CONF}"
    good "Attached. Phormal will route through ${peer}."
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
  info "Core key (must match on both nodes). Suggested: ${BOLD}${suggested}${RST}"
  prefix="$(ask 'Core key [Enter for suggested]')"
  prefix="${prefix:-${suggested}}"

  local self_core peer_core
  self_core="${prefix}${self_suffix}"
  peer_core="${prefix}${peer_suffix}"

  ensure_dirs
  cat > "${PHORMAL_CONF}" <<EOF
ROLE=${role}
LOCAL_V4=${local_v4}
REMOTE_V4=${remote_v4}
CORE_KEY=${prefix}
SELF_CORE=${self_core}
PEER_CORE=${peer_core}
EOF

  cat > "${CORE_UP_SCRIPT}" <<EOF
#!/usr/bin/env bash
ip link del ${CORE_IFACE} 2>/dev/null || true
ip tunnel add ${CORE_IFACE} mode sit remote ${remote_v4} local ${local_v4} ttl 255
ip link set ${CORE_IFACE} up
ip link set dev ${CORE_IFACE} mtu 1400
ip -6 addr add ${self_core}/64 dev ${CORE_IFACE}
EOF
  chmod +x "${CORE_UP_SCRIPT}"

  cat > "${CORE_UNIT}" <<EOF
[Unit]
Description=Phormal Core link
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
Description=Phormal Core guardian (keepalive)
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

  systemctl daemon-reload
  systemctl enable --now phormal-core.service  >/dev/null 2>&1
  systemctl enable --now phormal-guard.service >/dev/null 2>&1

  good "Core link established."
  info "  local  : ${self_core}"
  info "  peer   : ${peer_core}"
  if ping6 -c2 -W3 "${peer_core}" >/dev/null 2>&1; then
    good "Peer reachable across the Core link."
  else
    warn "Peer not answering yet — bring up the other node, then re-check status."
  fi
}

# ------------------------------------------------------------------------------
#  FORWARDER  (entry node: publish service ports onto the Core link)
# ------------------------------------------------------------------------------
install_engine() {
  if [[ -x "${FWD_BIN}" ]] && "${FWD_BIN}" -V >/dev/null 2>&1; then
    good "Forwarding engine present."
    return 0
  fi
  info "Installing forwarding engine…"
  apt-get update -y  >/dev/null 2>&1 || true
  apt-get install -y curl wget tar gzip >/dev/null 2>&1 || true

  local tmp; tmp="$(mktemp -d)"
  if bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install >/dev/null 2>&1 \
     && have gost; then
    ln -sf "$(command -v gost)" "${FWD_BIN}"
    good "Engine installed."
  else
    fail "Engine install failed. Check connectivity and retry."
    rm -rf "${tmp}"; return 1
  fi
  rm -rf "${tmp}"
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

deploy_forwarder() {
  rule
  info "Phormal Forwarder — publish ports through the Core link"
  rule

  local peer; peer="$(conf_get PEER_CORE)"
  if [[ -n "${peer}" ]]; then
    info "Destination from Core config: ${BOLD}${peer}${RST}"
    local keep; keep="$(ask 'Use this destination? (y/n)')"
    [[ "${keep}" != "y" ]] && peer="$(ask 'Destination Core address')"
  else
    peer="$(ask 'Destination Core address')"
  fi
  [[ -z "${peer}" ]] && { fail "No destination supplied."; return 1; }

  local proto pc
  printf '  %s1%s tcp   %s2%s udp   %s3%s grpc\n' "${ACC}" "${RST}" "${ACC}" "${RST}" "${ACC}" "${RST}"
  pc="$(ask 'Transport')"
  case "${pc}" in 1) proto=tcp ;; 2) proto=udp ;; 3) proto=grpc ;; *) fail "Invalid transport."; return 1 ;; esac

  local ports; ports="$(gather_ports)"
  [[ -z "${ports}" ]] && { fail "No valid ports provided."; return 1; }

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
Description=Phormal Forwarder worker ${u}
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

  good "Forwarder live. Point your clients at this node's public IP on the published ports."
}

# ------------------------------------------------------------------------------
#  TUNING / OPS
# ------------------------------------------------------------------------------
enable_bbr() {
  info "Enabling BBR congestion control…"
  cat > /etc/sysctl.d/98-phormal-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl --system >/dev/null 2>&1 || true
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    good "BBR active."
  else
    warn "BBR could not be confirmed (kernel may need a reboot)."
  fi
}

schedule_refresh() {
  local hrs; hrs="$(ask 'Auto-refresh interval in hours (0 to disable)')"
  crontab -l 2>/dev/null | grep -v 'phormal-refresh' | crontab - 2>/dev/null || true
  if [[ "${hrs}" =~ ^[0-9]+$ && "${hrs}" -gt 0 ]]; then
    cat > /usr/bin/phormal-refresh.sh <<'EOF'
#!/usr/bin/env bash
systemctl daemon-reload
systemctl restart 'phormal-fwd@*.service' 2>/dev/null || true
systemctl restart phormal-guard.service 2>/dev/null || true
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
  info "CORE LINK"
  if [[ -f "${PHORMAL_CONF}" ]]; then
    local role self peer
    role="$(conf_get ROLE)"; self="$(conf_get SELF_CORE)"; peer="$(conf_get PEER_CORE)"
    printf '    role    : %s\n' "${role:-?}"
    [[ -n "${self}" ]] && printf '    local   : %s\n' "${self}"
    [[ -n "${peer}" ]] && printf '    peer    : %s\n' "${peer}"
    if [[ -n "${peer}" ]]; then
      if ping6 -c1 -W2 "${peer}" >/dev/null 2>&1; then good "peer reachable"; else warn "peer unreachable"; fi
    fi
  else
    warn "no Core link configured"
  fi
  echo
  info "FORWARDER WORKERS"
  local found=0 u name st
  for u in /etc/systemd/system/phormal-fwd@*.service; do
    [[ -e "${u}" ]] || continue
    found=1; name="$(basename "${u}" .service)"
    st="$(systemctl is-active "${name}" 2>/dev/null || echo unknown)"
    printf '    %-22s : %s\n' "${name}" "${st}"
  done
  [[ ${found} -eq 0 ]] && warn "no forwarder workers configured"
  rule
}

purge() {
  local c; c="$(ask 'Remove Phormal entirely? (y/n)')"
  [[ "${c}" != "y" ]] && { info "Cancelled."; return; }
  systemctl stop    'phormal-fwd@*.service' 2>/dev/null || true
  systemctl disable 'phormal-fwd@*.service' 2>/dev/null || true
  rm -f /etc/systemd/system/phormal-fwd@*.service
  for s in phormal-guard phormal-core; do
    systemctl stop "${s}.service" 2>/dev/null || true
    systemctl disable "${s}.service" 2>/dev/null || true
  done
  ip link del "${CORE_IFACE}" 2>/dev/null || true
  rm -f "${CORE_UNIT}" "${GUARD_UNIT}" /etc/sysctl.d/99-phormal.conf /etc/sysctl.d/98-phormal-bbr.conf
  rm -f /usr/bin/phormal-refresh.sh
  crontab -l 2>/dev/null | grep -v 'phormal-refresh' | crontab - 2>/dev/null || true
  rm -rf "${PHORMAL_HOME}"
  systemctl daemon-reload
  good "Phormal removed. (CLI shortcut left at ${CLI_LINK}; delete manually if desired.)"
}

quick_deploy() {
  deploy_core || { fail "Core step failed."; return; }
  local role; role="$(conf_get ROLE)"
  if [[ "${role}" == "exit" ]]; then
    echo
    info "This is the EXIT node — no forwarder needed here."
    info "Make sure your service listens on the ports you intend to publish,"
    info "then run Phormal on the ENTRY node to expose them."
  else
    echo
    local g; g="$(ask 'Configure the forwarder now? (y/n)')"
    [[ "${g}" == "y" ]] && deploy_forwarder
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
    printf '  %sDEPLOY%s\n' "${BOLD}" "${RST}"
    printf '    %s1%s  Quick deploy        %s(Core link + forwarder)%s\n' "${ACC}" "${RST}" "${MUT}" "${RST}"
    printf '    %s2%s  Core link only\n' "${ACC}" "${RST}"
    printf '    %s3%s  Forwarder only      %s(entry node)%s\n' "${ACC}" "${RST}" "${MUT}" "${RST}"
    printf '\n  %sMANAGE%s\n' "${BOLD}" "${RST}"
    printf '    %s4%s  Add / publish more ports\n' "${ACC}" "${RST}"
    printf '    %s5%s  Status\n' "${ACC}" "${RST}"
    printf '    %s6%s  Enable BBR\n' "${ACC}" "${RST}"
    printf '    %s7%s  Auto-refresh schedule\n' "${ACC}" "${RST}"
    printf '    %s8%s  Uninstall\n' "${ACC}" "${RST}"
    printf '    %s9%s  Exit\n\n' "${ACC}" "${RST}"

    local choice; choice="$(ask 'Select')"
    echo
    case "${choice}" in
      1) quick_deploy ;;
      2) deploy_core ;;
      3) deploy_forwarder ;;
      4) deploy_forwarder ;;
      5) status ;;
      6) enable_bbr ;;
      7) schedule_refresh ;;
      8) purge ;;
      9) good "Goodbye — @SchmitzWS"; exit 0 ;;
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
