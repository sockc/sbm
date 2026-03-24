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
source "${BASE_DIR}/lib/outbound.sh"
source "${BASE_DIR}/lib/firewall.sh"
source "${BASE_DIR}/lib/backup.sh"
source "${BASE_DIR}/lib/self_update.sh"
source "${BASE_DIR}/lib/clash_api.sh"
source "${BASE_DIR}/lib/template.sh"

show_header() {
  clear
  echo "======================================"
  echo "        Sing-box Manager (sbm)"
  echo "======================================"
  echo "脚本版本: ${SBM_VERSION}"
  echo "推荐内核: ${DEFAULT_SINGBOX_VERSION}"
  echo "配置目录: ${CONFIG_DIR}"
  echo "--------------------------------------"
  ss -lntup 2>/dev/null | grep -E 'sing-box|:9066|:9090|:443|:8443' || true
  if command -v sing-box >/dev/null 2>&1; then
    echo "sing-box: 已安装 ($(sing-box version 2>/dev/null | head -n1 || echo unknown))"
  else
    echo "sing-box: 未安装"
  fi
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
    echo "1. 安装/升级 sing-box 内核"
    echo "2. 入站管理"
    echo "3. 用户管理"
    echo "4. 导出客户端 URI"
    echo "5. 出站管理"
    echo "6. 防火墙管理"
    echo "7. 备份与恢复"
    echo "8. 脚本自更新"
    echo "9. Clash API 管理"
    echo "10. 模板管理"
    echo "11. 服务状态"
    echo "0. 退出"
    echo

    read -r -p "请选择 [0-11]: " choice
    case "${choice:-}" in
      1) menu_install_core ;;
      2) menu_inbound_management ;;
      3) menu_user_management ;;
      4) menu_export_client ;;
      5) menu_outbound_management ;;
      6) menu_firewall_management ;;
      7) menu_backup_management ;;
      8) menu_self_update ;;
      9) menu_clash_api_management ;;
      10) menu_template_management ;;
      11) show_service_status; pause_enter ;;
      0) exit 0 ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

main_menu
