#!/usr/bin/env bash

check_config_file() {
  local file="$1"
  sing-box check -c "$file"
}

backup_current_config() {
  mkdir -p "${BACKUP_DIR}"
  if [ -f "${CONFIG_DIR}/config.json" ]; then
    cp -f "${CONFIG_DIR}/config.json" "${BACKUP_DIR}/config.$(date +%Y%m%d-%H%M%S).json"
  fi
}

activate_config_file() {
  local src="$1"
  mkdir -p "${CONFIG_DIR}"
  backup_current_config
  install -m 600 "$src" "${CONFIG_DIR}/config.json"
}
