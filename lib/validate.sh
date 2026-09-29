#!/usr/bin/env bash

SBM_LAST_CONFIG_BACKUP=""

check_config_file() {
  local file="$1"
  sing-box check -c "$file"
}

backup_current_config() {
  mkdir -p "${BACKUP_DIR}"
  chmod 700 "${BACKUP_DIR}" 2>/dev/null || true

  if [ -f "${CONFIG_DIR}/config.json" ]; then
    local backup
    backup="${BACKUP_DIR}/config.$(date +%Y%m%d-%H%M%S)-$$.json"
    cp -p "${CONFIG_DIR}/config.json" "${backup}"
    chmod 600 "${backup}" 2>/dev/null || true
    printf '%s\n' "${backup}"
  fi
}

activate_config_file() {
  local src="$1"
  local backup=""

  mkdir -p "${CONFIG_DIR}"
  chmod 700 "${CONFIG_DIR}" 2>/dev/null || true

  if [ -f "${CONFIG_DIR}/config.json" ]; then
    backup="$(backup_current_config)"
  fi

  install -m 600 "$src" "${CONFIG_DIR}/config.json"
  SBM_LAST_CONFIG_BACKUP="${backup}"
}

clear_config_rollback_point() {
  SBM_LAST_CONFIG_BACKUP=""
}

rollback_last_config() {
  local backup="${SBM_LAST_CONFIG_BACKUP:-}"

  if [ -z "${backup}" ] || [ ! -f "${backup}" ]; then
    return 1
  fi

  warn "新配置启动失败，正在自动恢复上一份配置：$(basename "${backup}")"
  install -m 600 "${backup}" "${CONFIG_DIR}/config.json"
  SBM_LAST_CONFIG_BACKUP=""
  return 0
}

restart_singbox_service_safe() {
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable sing-box >/dev/null 2>&1 || true

  if systemctl restart sing-box && systemctl is-active --quiet sing-box; then
    clear_config_rollback_point
    return 0
  fi

  if rollback_last_config; then
    systemctl restart sing-box >/dev/null 2>&1 || true
    if systemctl is-active --quiet sing-box; then
      err "新配置未能启动，已自动回滚到上一份可用配置"
    else
      err "新配置启动失败；已恢复旧配置文件，但 sing-box 仍未能正常启动"
    fi
  fi

  return 1
}
