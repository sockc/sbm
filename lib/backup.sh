#!/usr/bin/env bash

list_manual_backup_files() {
  ls -1t "${BACKUP_DIR}"/manual-*.tar.gz 2>/dev/null || true
}

show_manual_backups() {
  local found=0 idx=1 file
  echo "编号 文件名"
  echo "--------------------------------------------------"
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    found=1
    printf '%-4s %s\n' "$idx" "$(basename "$file")"
    idx=$((idx + 1))
  done < <(list_manual_backup_files)

  if [ "$found" -eq 0 ]; then
    echo "暂无手动备份"
  fi
  echo "--------------------------------------------------"
}

get_backup_path_by_index() {
  local idx="$1"
  list_manual_backup_files | sed -n "${idx}p"
}

restart_singbox_after_restore() {
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable sing-box >/dev/null 2>&1 || true
  systemctl restart sing-box
}

create_manual_backup() {
  need_root
  mkdir -p "${BACKUP_DIR}"

  local files=()
  local ts archive

  [ -f "${CONFIG_DIR}/config.json" ] && files+=("config.json")
  [ -f "${META_FILE}" ] && files+=("$(basename "${META_FILE}")")

  if [ "${#files[@]}" -eq 0 ]; then
    err "未找到可备份文件，请先完成部署"
    pause_enter
    return 1
  fi

  ts="$(date +%Y%m%d-%H%M%S)"
  archive="${BACKUP_DIR}/manual-${ts}.tar.gz"

  if tar -C "${CONFIG_DIR}" -czf "${archive}" "${files[@]}"; then
    ok "备份创建成功：${archive}"
  else
    err "创建备份失败"
  fi

  pause_enter
}

restore_manual_backup() {
  need_root
  mkdir -p "${TMP_DIR}"

  local idx archive restore_dir
  restore_dir="${TMP_DIR}/restore-backup"

  show_manual_backups
  echo

  idx="$(prompt_required "请输入要恢复的备份编号")"
  archive="$(get_backup_path_by_index "$idx")"

  if [ -z "${archive}" ] || [ ! -f "${archive}" ]; then
    err "备份编号无效"
    pause_enter
    return 1
  fi

  echo "准备恢复：$(basename "${archive}")"
  if ! confirm_default_no "确认继续吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  rm -rf "${restore_dir}"
  mkdir -p "${restore_dir}"

  if ! tar -xzf "${archive}" -C "${restore_dir}"; then
    err "解压备份失败"
    pause_enter
    return 1
  fi

  if [ ! -f "${restore_dir}/config.json" ]; then
    err "备份中未找到 config.json，无法恢复"
    pause_enter
    return 1
  fi

  if ! check_config_file "${restore_dir}/config.json"; then
    err "备份中的配置校验失败，已停止恢复"
    pause_enter
    return 1
  fi

  backup_current_config

  install -m 600 "${restore_dir}/config.json" "${CONFIG_DIR}/config.json"

  if [ -f "${restore_dir}/$(basename "${META_FILE}")" ]; then
    install -m 600 "${restore_dir}/$(basename "${META_FILE}")" "${META_FILE}"
  fi

  if ! restart_singbox_after_restore; then
    err "恢复后服务重启失败"
    pause_enter
    return 1
  fi

  ok "备份恢复成功"
  pause_enter
}

menu_backup_management() {
  while true; do
    clear
    echo "======================================"
    echo "          备份与恢复管理"
    echo "======================================"
    echo "1. 创建手动备份"
    echo "2. 查看备份列表"
    echo "3. 恢复手动备份"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-3]: " choice
    case "${choice:-}" in
      1) create_manual_backup ;;
      2) show_manual_backups; pause_enter ;;
      3) restore_manual_backup ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
