#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
main = root / "phormal.sh"
mod = root / "phormal-multilayer.bash"
text = main.read_text(encoding="utf-8").replace("\r\n", "\n")
mod_lines = mod.read_text(encoding="utf-8").replace("\r\n", "\n").splitlines()
# skip first 4 header lines of module file
mod_body = "\n".join(mod_lines[4:]).strip() + "\n"

marker = (
    "# ------------------------------------------------------------------------------\n"
    "#  Menu\n"
    "# ------------------------------------------------------------------------------"
)
if marker not in text:
    raise SystemExit("menu marker not found")
if "layer_autotest_main" in text:
    raise SystemExit("already merged")

text = text.replace('readonly PHORMAL_VERSION="5.2.0"', 'readonly PHORMAL_VERSION="5.3.0"')
old_mirror = (
    "#   rathole-linux-{amd64,arm64}  phormal-spoof-linux-{amd64,arm64}"
)
new_mirror = old_mirror + (
    "\n#   backhaul-linux-{amd64,arm64}  icmp_tun-linux-{amd64,arm64}  udp2raw-linux-{amd64,arm64}"
    "\n#   iodine-linux-{amd64,arm64}  iodined-linux-{amd64,arm64}  proxyforwarder-linux-{amd64,arm64}"
)
text = text.replace(old_mirror, new_mirror)

insert = (
    "\n# ------------------------------------------------------------------------------\n"
    "#  Multi-Layer Tunnels & Auto-Test\n"
    "# ------------------------------------------------------------------------------\n"
    + mod_body
    + "\n"
)
text = text.replace(marker, insert + marker)

old_menu = """    printf '\\n  %sMANAGE%s\\n' "${BOLD}" "${RST}"
    printf '   %s15%s  Status\\n' "${ACC}" "${RST}"
    printf '   %s16%s  Phormal tuning\\n' "${ACC}" "${RST}"
    printf '   %s17%s  Auto-refresh schedule\\n' "${ACC}" "${RST}"
    printf '   %s18%s  Uninstall\\n' "${ACC}" "${RST}"'"""

new_menu = """    printf '\\n  %sMULTI-LAYER%s  %s(auto-test + per-layer tunnels)%s\\n' "${BOLD}" "${RST}" "${MUT}" "${RST}"
    printf '   %s15%s  Auto-test path (SSH to peer)\\n' "${ACC}" "${RST}"
    printf '   %s16%s  Add a layer tunnel\\n' "${ACC}" "${RST}"
    printf '   %s17%s  Manage layer tunnels\\n' "${ACC}" "${RST}"
    printf '\\n  %sMANAGE%s\\n' "${BOLD}" "${RST}"
    printf '   %s18%s  Status\\n' "${ACC}" "${RST}"
    printf '   %s19%s  Phormal tuning\\n' "${ACC}" "${RST}"
    printf '   %s20%s  Auto-refresh schedule\\n' "${ACC}" "${RST}"
    printf '   %s21%s  Uninstall\\n' "${ACC}" "${RST}"'"""

text = text.replace(old_menu, new_menu)

old_case = """      14) manage_spoof_menu || true ;;
      15) status || true ;;
      16) tune_menu || true ;;
      17) schedule_refresh || true ;;
      18) purge || true ;;"""

new_case = """      14) manage_spoof_menu || true ;;
      15) layer_autotest_cli || true ;;
      16) layer_add_menu || true ;;
      17) manage_layer_menu || true ;;
      18) status || true ;;
      19) tune_menu || true ;;
      20) schedule_refresh || true ;;
      21) purge || true ;;"""

text = text.replace(old_case, new_case)

# purge: add layer cleanup before rm -rf PHORMAL_HOME
purge_marker = "  rm -rf \"${PHORMAL_HOME}\""
if purge_marker in text and "phormal-gre@" not in text.split(purge_marker)[0][-800:]:
    layer_purge = """  local lk ln
  for lk in gre icmp udp2raw btcp bwss dns fwd; do
    while read -r ln; do
      [[ -n "${ln}" ]] || continue
      systemctl stop "phormal-${lk}@${ln}" 2>/dev/null || true
      systemctl disable "phormal-${lk}@${ln}" 2>/dev/null || true
      [[ "${lk}" == gre ]] && ip link del "$(layer_meta_get gre "${ln}" IFACE 2>/dev/null || true)" 2>/dev/null || true
    done < <(layer_instances "${lk}" 2>/dev/null || true)
    rm -f "/etc/systemd/system/phormal-${lk}@.service"
  done
  rm -f "${LAYER_RUN}" "${LAYER_GRE_RUN}" "${LAYER_BACKHAUL_BIN}" "${LAYER_ICMP_BIN}" \\
    "${LAYER_UDP2RAW_BIN}" "${LAYER_IODINE_BIN}" "${LAYER_IODINED_BIN}" "${LAYER_FWD_BIN}"
"""
    text = text.replace(purge_marker, layer_purge + purge_marker)

main.write_text(text, encoding="utf-8", newline="\n")
print(f"merged -> {main} ({len(text.splitlines())} lines)")
