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

show_header() {
  clear

  local svc_status="未安装"
  local sb_version="未安装"
  local ui_status="未启用"
  local ui_url="<空>"

  if command -v sing-box >/dev/null 2>&1; then
    sb_version="$(sing-box version 2>/dev/null | head -n1 || echo unknown)"
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl cat sing-box.service >/dev/null 2>&1; then
    svc_status="$(systemctl is-active sing-box.service 2>/dev/null || true)"
  fi

  if [ -f "${CONFIG_DIR}/config.json" ] && command -v python3 >/dev/null 2>&1; then
    mapfile -t _ui_info < <(get_header_ui_info)
    ui_status="${_ui_info[0]:-未启用}"
    ui_url="${_ui_info[1]:-<空>}"
  fi

  echo "======================================"
  echo "        Sing-box Manager (sbm)"
  echo "======================================"
  echo "脚本版本 : ${SBM_VERSION}"
  echo "sing-box : ${sb_version}"
  echo "服务状态 : ${svc_status}"
  echo "UI状态   : ${ui_status}"
  echo "UI地址   : ${ui_url}"
  echo "======================================"
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

  echo "======================================"
  echo "            服务状态"
  echo "======================================"
  echo "服务名称 : ${unit}"
  echo "运行状态 : ${active:-unknown}"
  echo "开机启动 : ${enabled:-unknown}"
  echo "主进程PID: ${mainpid:-0}"
  echo "--------------------------------------"

  systemctl --no-pager --full status "${unit}" || true
}

main_menu() {
  while true; do
    show_header
    echo "1.  安装/升级"
    echo "2.  入站管理"
    echo "3.  用户管理"
    echo "4.  导出URI"
    echo "5.  出站管理"
    echo "6.  面板管理"
    echo "7.  分流模板"
    echo "8.  防火墙管理"
    echo "9.  备份与恢复"
    echo "10. 服务状态"
    echo "11. 更新脚本"
    echo "0.  退出"
    echo

    read -r -p "请选择 [0-11]: " choice
    case "${choice:-}" in
      1) menu_install_core ;;
      2) menu_inbound_management ;;
      3) menu_user_management ;;
      4) menu_export_client ;;
      5) menu_outbound_management ;;
      6) menu_clash_api_management ;;
      7) menu_template_management ;;
      8) menu_firewall_management ;;
      9) menu_backup_management ;;
      10) show_service_status; pause_enter ;;
      11) menu_self_update ;;
      0) exit 0 ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

main_menu
