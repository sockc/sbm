#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/usr/local/share/sbm"

# shellcheck disable=SC1091
source "${BASE_DIR}/lib/env.sh"
# shellcheck disable=SC1091
source "${BASE_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${BASE_DIR}/lib/input.sh"
# shellcheck disable=SC1091
source "${BASE_DIR}/lib/install_core.sh"
# shellcheck disable=SC1091
source "${BASE_DIR}/lib/validate.sh"
# shellcheck disable=SC1091
source "${BASE_DIR}/lib/inbound.sh"
# shellcheck disable=SC1091
source "${BASE_DIR}/lib/export.sh"
# shellcheck disable=SC1091
source "${BASE_DIR}/lib/user.sh"
# shellcheck disable=SC1091
source "${BASE_DIR}/lib/outbound.sh"
# shellcheck disable=SC1091
source "${BASE_DIR}/lib/firewall.sh"
# shellcheck disable=SC1091
source "${BASE_DIR}/lib/backup.sh"
# shellcheck disable=SC1091
source "${BASE_DIR}/lib/self_update.sh"
# shellcheck disable=SC1091
source "${BASE_DIR}/lib/clash_api.sh"
# shellcheck disable=SC1091
source "${BASE_DIR}/lib/template.sh"
# shellcheck disable=SC1091
source "${BASE_DIR}/lib/uninstall.sh"
# shellcheck disable=SC1091
source "${BASE_DIR}/lib/system_proxy.sh"

init_colors() {
  if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'

    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_MAGENTA=$'\033[35m'
    C_CYAN=$'\033[36m'
    C_WHITE=$'\033[37m'

    C_BRED=$'\033[91m'
    C_BGREEN=$'\033[92m'
    C_BYELLOW=$'\033[93m'
    C_BBLUE=$'\033[94m'
    C_BMAGENTA=$'\033[95m'
    C_BCYAN=$'\033[96m'
  else
    C_RESET=""
    C_BOLD=""
    C_DIM=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_MAGENTA=""
    C_CYAN=""
    C_WHITE=""
    C_BRED=""
    C_BGREEN=""
    C_BYELLOW=""
    C_BBLUE=""
    C_BMAGENTA=""
    C_BCYAN=""
  fi
}

paint() {
  local color="$1"
  shift
  printf "%b%s%b" "${color}" "$*" "${C_RESET}"
}

status_color() {
  case "${1:-}" in
    active) printf "%s" "${C_BGREEN}" ;;
    inactive|deactivating) printf "%s" "${C_YELLOW}" ;;
    failed|dead) printf "%s" "${C_BRED}" ;;
    activating|reloading) printf "%s" "${C_BYELLOW}" ;;
    enabled) printf "%s" "${C_BGREEN}" ;;
    disabled) printf "%s" "${C_YELLOW}" ;;
    *) printf "%s" "${C_BCYAN}" ;;
  esac
}

ui_status_color() {
  local s="${1:-}"

  if [ "${s}" = "已启用" ]; then
    printf "%s" "${C_BGREEN}"
  elif [ "${s}" = "已启用（无 UI）" ]; then
    printf "%s" "${C_BYELLOW}"
  elif [ "${s}" = "配置异常" ]; then
    printf "%s" "${C_BRED}"
  elif [ "${s}" = "未启用" ] || [ "${s}" = "<空>" ]; then
    printf "%s" "${C_YELLOW}"
  else
    printf "%s" "${C_BCYAN}"
  fi
}

print_status_row() {
  local lkey="$1"
  local lval="$2"
  local rkey="$3"
  local rval="$4"
  local lcolor="${5:-${C_RESET}}"
  local rcolor="${6:-${C_RESET}}"

  printf "%b%-10s%b %b%-14s%b  %b%-10s%b %b%s%b\n" \
    "${C_BCYAN}" "${lkey}" "${C_RESET}" \
    "${lcolor}" "${lval}" "${C_RESET}" \
    "${C_BCYAN}" "${rkey}" "${C_RESET}" \
    "${rcolor}" "${rval}" "${C_RESET}"
}

menu_row() {
  local n1="$1"
  local t1="$2"
  local n2="${3:-}"
  local t2="${4:-}"

  if [ -n "${n2}" ]; then
    printf "%b%-3s%b %-16s  %b%-3s%b %s\n" \
      "${C_BCYAN}${C_BOLD}" "${n1}." "${C_RESET}" "${t1}" \
      "${C_BCYAN}${C_BOLD}" "${n2}." "${C_RESET}" "${t2}"
  else
    printf "%b%-3s%b %s\n" \
      "${C_BCYAN}${C_BOLD}" "${n1}." "${C_RESET}" "${t1}"
  fi
}

get_header_ui_info() {
  python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, os, sys

cfg_path = sys.argv[1]

if not os.path.exists(cfg_path):
    print("未启用")
    print("<空>")
    raise SystemExit(0)

try:
    cfg = json.load(open(cfg_path, 'r', encoding='utf-8'))
except Exception:
    print("配置异常")
    print("<空>")
    raise SystemExit(0)

clash = cfg.get("experimental", {}).get("clash_api", {})
controller = str(clash.get("external_controller", "") or "")
ui_dir = str(clash.get("external_ui", "") or "")

if not controller:
    print("未启用")
    print("<空>")
    raise SystemExit(0)

if not ui_dir:
    print("已启用（无 UI）")
    print("<空>")
    raise SystemExit(0)

host = controller
port = ""

if controller.startswith("["):
    if "]:" in controller:
        host, port = controller.rsplit(":", 1)
else:
    if ":" in controller:
        host, port = controller.rsplit(":", 1)

if host in ("127.0.0.1", "localhost", "::1", "[::1]"):
    ui_url = f"http://127.0.0.1:{port}/ui/" if port else "<空>"
elif host in ("0.0.0.0", "::", "[::]"):
    ui_url = f"http://服务器IP:{port}/ui/" if port else "<空>"
else:
    ui_url = f"http://{host}:{port}/ui/" if port else "<空>"

print("已启用")
print(ui_url)
PY
}

get_header_system_proxy_info() {
  python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, os, sys

cfg_path = sys.argv[1]
tag = "system-proxy-in"

if not os.path.exists(cfg_path):
    print("未启用")
    print("<空>")
    raise SystemExit(0)

try:
    cfg = json.load(open(cfg_path, 'r', encoding='utf-8'))
except Exception:
    print("配置异常")
    print("<空>")
    raise SystemExit(0)

for ib in cfg.get("inbounds", []):
    if ib.get("tag") == tag and ib.get("type") == "mixed":
        listen = str(ib.get("listen", "127.0.0.1") or "127.0.0.1")
        port = str(ib.get("listen_port", "") or "")
        endpoint = f"{listen}:{port}" if port else listen
        print("已启用")
        print(endpoint)
        raise SystemExit(0)

print("未启用")
print("<空>")
PY
}

get_header_inbound_count() {
  python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, os, sys

cfg_path = sys.argv[1]

if not os.path.exists(cfg_path):
    print("0")
    raise SystemExit(0)

try:
    cfg = json.load(open(cfg_path, 'r', encoding='utf-8'))
except Exception:
    print("0")
    raise SystemExit(0)

count = 0
for ib in cfg.get("inbounds", []):
    tag = str(ib.get("tag", "") or "")
    typ = str(ib.get("type", "") or "")
    if tag == "system-proxy-in":
        continue
    if typ in ("vless", "vmess", "hysteria2", "tuic"):
        count += 1

print(count)
PY
}

show_header() {
  clear

  local svc_status="未安装"
  local sb_version="未安装"
  local ui_status="未启用"
  local proxy_status="未启用"
  local inbound_count="0"
  local svc_color ui_color proxy_color

  if command -v sing-box >/dev/null 2>&1; then
    sb_version="$(sing-box version 2>/dev/null | head -n1 | sed -E 's/^sing-box version[[:space:]]+//; s/[[:space:]].*$//' || echo unknown)"
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl cat sing-box.service >/dev/null 2>&1; then
    svc_status="$(systemctl is-active sing-box.service 2>/dev/null || true)"
  fi

  if [ -f "${CONFIG_DIR}/config.json" ] && command -v python3 >/dev/null 2>&1; then
    mapfile -t _ui_info < <(get_header_ui_info)
    ui_status="${_ui_info[0]:-未启用}"

    mapfile -t _proxy_info < <(get_header_system_proxy_info)
    proxy_status="${_proxy_info[0]:-未启用}"

    inbound_count="$(get_header_inbound_count 2>/dev/null || echo 0)"
  fi

  svc_color="$(status_color "${svc_status}")"
  ui_color="$(ui_status_color "${ui_status}")"
  proxy_color="$(ui_status_color "${proxy_status}")"

  echo "$(paint "${C_BMAGENTA}${C_BOLD}" "======================================")"
  echo "$(paint "${C_BMAGENTA}${C_BOLD}" "        Sing-box Manager (sbm)")"
  echo "$(paint "${C_BMAGENTA}${C_BOLD}" "======================================")"

  print_status_row "脚本版本 :" "${SBM_VERSION}" "内核版本 :" "${sb_version}"
  print_status_row "服务状态 :" "${svc_status}" "入站数量 :" "${inbound_count}" "${svc_color}" "${C_RESET}"
  print_status_row "UI状态   :" "${ui_status}" "本地代理 :" "${proxy_status}" "${ui_color}" "${proxy_color}"

  echo "$(paint "${C_BMAGENTA}${C_BOLD}" "======================================")"
}

show_service_status() {
  local unit="sing-box.service"

  if ! command -v systemctl >/dev/null 2>&1; then
    echo "当前系统未检测到 systemd"
    return 1
  fi

  if ! systemctl cat "${unit}" >/dev/null 2>&1; then
    echo "系统中未发现 ${unit}"
    return 1
  fi

  local active enabled mainpid
  active="$(systemctl is-active "${unit}" 2>/dev/null || true)"
  enabled="$(systemctl is-enabled "${unit}" 2>/dev/null || true)"
  mainpid="$(systemctl show -p MainPID --value "${unit}" 2>/dev/null || true)"

  echo "$(paint "${C_BMAGENTA}${C_BOLD}" "======================================")"
  echo "$(paint "${C_BMAGENTA}${C_BOLD}" "            服务状态")"
  echo "$(paint "${C_BMAGENTA}${C_BOLD}" "======================================")"
  printf "%b%-10s%b %s\n" "${C_BCYAN}" "服务名称 :" "${C_RESET}" "${unit}"
  printf "%b%-10s%b %b%s%b\n" "${C_BCYAN}" "运行状态 :" "${C_RESET}" "$(status_color "${active}")" "${active:-unknown}" "${C_RESET}"
  printf "%b%-10s%b %b%s%b\n" "${C_BCYAN}" "开机启动 :" "${C_RESET}" "$(status_color "${enabled}")" "${enabled:-unknown}" "${C_RESET}"
  printf "%b%-10s%b %s\n" "${C_BCYAN}" "主进程PID:" "${C_RESET}" "${mainpid:-0}"
  echo "$(paint "${C_DIM}" "--------------------------------------")"

  systemctl --no-pager --full status "${unit}" || true
}

main_menu() {
  while true; do
    show_header
    menu_row "1" "安装/升级"    "2" "入站管理"
    menu_row "3" "出站管理"     "4" "本地代理"
    menu_row "5" "防火墙管理"   "6" "备份与恢复"
    menu_row "7" "服务状态"     "8" "更新脚本"
    menu_row "9" "卸载"         "0" "退出"
    echo

    read -r -p "请选择 [0-9]: " choice
    case "${choice:-}" in
      1) menu_install_core ;;
      2) menu_inbound_management ;;
      3) menu_outbound_management ;;
      4) menu_system_proxy ;;
      5) menu_firewall_management ;;
      6) menu_backup_management ;;
      7) show_service_status; pause_enter ;;
      8) menu_self_update ;;
      9) menu_uninstall ;;
      0) exit 0 ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

init_colors
main_menu
