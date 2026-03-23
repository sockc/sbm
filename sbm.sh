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

show_header() {
  clear
  echo "======================================"
  echo "        Sing-box Manager (sbm)"
  echo "======================================"
  echo "脚本版本: ${SBM_VERSION}"
  echo "推荐内核: ${DEFAULT_SINGBOX_VERSION}"
  echo "配置目录: ${CONFIG_DIR}"
  echo "--------------------------------------"
  if command -v sing-box >/dev/null 2>&1; then
    echo "sing-box: 已安装 ($(sing-box version 2>/dev/null | head -n1 || echo unknown))"
  else
    echo "sing-box: 未安装"
  fi
  echo "======================================"
}

main_menu() {
  while true; do
    show_header
    echo "1. 安装/升级 sing-box 内核"
    echo "2. 部署 VLESS + Reality（占位）"
    echo "3. 出站管理（占位）"
    echo "4. 服务状态"
    echo "0. 退出"
    echo

    read -r -p "请选择 [0-4]: " choice
    case "${choice:-}" in
      1) menu_install_core ;;
      2) echo "暂未实现"; pause_enter ;;
      3) echo "暂未实现"; pause_enter ;;
      4) show_service_status; pause_enter ;;
      0) exit 0 ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

show_service_status() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^sing-box\.service'; then
    systemctl --no-pager --full status sing-box || true
  else
    echo "系统中未发现 sing-box.service"
  fi
}

main_menu
