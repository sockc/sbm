#!/usr/bin/env bash

create_uninstall_backup() {
  need_root

  mkdir -p "${BACKUP_DIR}" "${TMP_DIR}"

  local ts backup_file
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_file="${BACKUP_DIR}/uninstall-${ts}.tar.gz"

  if ! tar -czf "${backup_file}" \
    -C / \
    etc/sing-box \
    usr/local/share/sbm 2>/dev/null; then
    warn "卸载前备份创建失败，已跳过"
    return 1
  fi

  ok "已创建卸载前备份：${backup_file}"
  return 0
}

stop_disable_singbox_service() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop sing-box.service 2>/dev/null || true
    systemctl disable sing-box.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
  fi
}

remove_singbox_service_files() {
  rm -f /etc/systemd/system/sing-box.service
  rm -f /usr/lib/systemd/system/sing-box.service
  rm -f /lib/systemd/system/sing-box.service
  systemctl daemon-reload 2>/dev/null || true
}

remove_singbox_binary() {
  rm -f /usr/local/bin/sing-box
  rm -f /usr/local/sbin/sing-box
  rm -f /usr/bin/sing-box
  rm -f /bin/sing-box
}

remove_sbm_entry() {
  rm -f /usr/local/sbin/sbm
  rm -f /usr/local/bin/sbm
}

remove_sbm_files() {
  rm -rf /usr/local/share/sbm
}

remove_singbox_config() {
  rm -rf /etc/sing-box
}

try_remove_package_singbox() {
  if command -v dpkg >/dev/null 2>&1 && dpkg -s sing-box >/dev/null 2>&1; then
    apt-get remove -y sing-box 2>/dev/null || true
    apt-get purge -y sing-box 2>/dev/null || true
  fi

  if command -v rpm >/dev/null 2>&1 && rpm -q sing-box >/dev/null 2>&1; then
    if command -v dnf >/dev/null 2>&1; then
      dnf remove -y sing-box 2>/dev/null || true
    elif command -v yum >/dev/null 2>&1; then
      yum remove -y sing-box 2>/dev/null || true
    fi
  fi
}

uninstall_script_only() {
  need_root

  echo "将执行："
  echo "1. 删除 sbm 菜单入口"
  echo "2. 删除 /usr/local/share/sbm"
  echo "3. 保留 sing-box 服务、内核与配置"
  echo

  if ! confirm_default_no "确认继续吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  remove_sbm_entry
  remove_sbm_files

  ok "已卸载脚本入口，sing-box 服务与配置已保留"
  echo
  echo "已删除："
  echo "  /usr/local/sbin/sbm"
  echo "  /usr/local/share/sbm"
  echo
}

uninstall_keep_config() {
  need_root

  echo "将执行："
  echo "1. 停止并禁用 sing-box.service"
  echo "2. 删除 sing-box 服务文件与二进制"
  echo "3. 删除 sbm 菜单入口与脚本目录"
  echo "4. 保留 /etc/sing-box 配置与备份"
  echo

  if ! confirm_default_no "确认继续吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  stop_disable_singbox_service
  try_remove_package_singbox
  remove_singbox_service_files
  remove_singbox_binary
  remove_sbm_entry
  remove_sbm_files

  ok "已卸载 sing-box 服务与脚本，配置已保留"
  echo
  echo "仍保留："
  echo "  /etc/sing-box"
  echo
}

uninstall_full() {
  need_root

  echo "将执行完整卸载："
  echo "1. 先自动创建卸载前备份"
  echo "2. 停止并禁用 sing-box.service"
  echo "3. 删除 sing-box 服务文件与二进制"
  echo "4. 删除 /etc/sing-box"
  echo "5. 删除 sbm 菜单入口与脚本目录"
  echo

  if ! confirm_default_no "确认继续吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  create_uninstall_backup || true
  stop_disable_singbox_service
  try_remove_package_singbox
  remove_singbox_service_files
  remove_singbox_binary
  remove_singbox_config
  remove_sbm_entry
  remove_sbm_files

  ok "已完整卸载 sing-box 与 sbm"
  echo
  echo "已删除："
  echo "  /etc/sing-box"
  echo "  /usr/local/share/sbm"
  echo "  /usr/local/sbin/sbm"
  echo
}

menu_uninstall() {
  while true; do
    clear
    echo "======================================"
    echo "               卸载管理"
    echo "======================================"
    echo "1. 仅卸载脚本入口（保留 sing-box 与配置）"
    echo "2. 卸载 sing-box 服务与脚本（保留配置）"
    echo "3. 完全卸载（自动备份后删除全部）"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-3]: " choice
    case "${choice:-}" in
      1) uninstall_script_only; exit 0 ;;
      2) uninstall_keep_config; exit 0 ;;
      3) uninstall_full; exit 0 ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
