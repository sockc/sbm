#!/usr/bin/env bash

ensure_backup_root() {
  mkdir -p "${SBM_BACKUP_ROOT}"
  chmod 700 "${SBM_BACKUP_ROOT}" 2>/dev/null || true
}

backup_manifest_json() {
  local kind="$1"
  local path="$2"

  python3 - "${path}" "${kind}" "${SBM_VERSION}" <<'PY'
import json, os, platform, sys
path, kind, version = sys.argv[1:]
data = {
    "format": 2,
    "kind": kind,
    "sbm_version": version,
    "created_at": __import__("datetime").datetime.now().astimezone().isoformat(),
    "hostname": platform.node(),
    "machine": platform.machine(),
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY
  chmod 600 "${path}" 2>/dev/null || true
}

create_backup_archive() {
  local kind="${1:-manual}"

  need_root
  require_python3 || return 1
  ensure_backup_root
  mkdir -p "${TMP_DIR}"

  local ts archive manifest
  local -a entries=()

  ts="$(date +%Y%m%d-%H%M%S)"
  archive="${SBM_BACKUP_ROOT}/${kind}-${ts}.tar.gz"
  manifest="${TMP_DIR}/manifest-${kind}-${ts}.json"

  [ -d "${CONFIG_DIR}" ] && entries+=("${CONFIG_DIR#/}")
  [ -d "${INBOUND_META_DIR}" ] && entries+=("${INBOUND_META_DIR#/}")
  [ -d "${BASE_DIR}/realm-meta" ] && entries+=("${BASE_DIR#/}/realm-meta")
  [ -f "${BASE_DIR}/outbound-proxy-state.json" ] && entries+=("${BASE_DIR#/}/outbound-proxy-state.json")
  [ -f "${BASE_DIR}/policy-groups.json" ] && entries+=("${BASE_DIR#/}/policy-groups.json")
  [ -f "${BASE_DIR}/install.env" ] && entries+=("${BASE_DIR#/}/install.env")
  if [ -n "${REALM_ETC_DIR:-}" ] && [ -d "${REALM_ETC_DIR}" ]; then
    entries+=("${REALM_ETC_DIR#/}")
  elif [ -d /etc/realm ]; then
    entries+=("etc/realm")
  fi

  if [ "${#entries[@]}" -eq 0 ]; then
    err "未找到可备份的 SBM/sing-box 状态"
    return 1
  fi

  backup_manifest_json "${kind}" "${manifest}" || return 1

  # /etc/sing-box/backup 是旧版备份目录，避免把历史归档再次套进新备份。
  if ! tar       --exclude='etc/sing-box/backup'       -C "${TMP_DIR}" -czf "${archive}" "$(basename "${manifest}")"       -C / "${entries[@]}"; then
    rm -f "${archive}"
    err "创建备份失败"
    return 1
  fi

  chmod 600 "${archive}" 2>/dev/null || true

  if has_cmd sha256sum; then
    (
      cd "${SBM_BACKUP_ROOT}"
      sha256sum "$(basename "${archive}")" > "$(basename "${archive}").sha256"
      chmod 600 "$(basename "${archive}").sha256" 2>/dev/null || true
    )
  fi

  printf '%s\n' "${archive}"
}

list_manual_backup_files() {
  ensure_backup_root
  {
    ls -1t "${SBM_BACKUP_ROOT}"/manual-*.tar.gz 2>/dev/null || true
    # 兼容 0.2.3.x 及更早版本留下的旧备份。
    ls -1t "${BACKUP_DIR}"/manual-*.tar.gz 2>/dev/null || true
  } | awk '!seen[$0]++'
}

show_manual_backups() {
  local found=0 idx=1 file
  echo "编号 文件名"
  echo "--------------------------------------------------"
  while IFS= read -r file; do
    [ -z "${file}" ] && continue
    found=1
    printf '%-4s %s\n' "${idx}" "${file}"
    idx=$((idx + 1))
  done < <(list_manual_backup_files)

  if [ "${found}" -eq 0 ]; then
    echo "暂无手动备份"
  fi
  echo "--------------------------------------------------"
}

get_backup_path_by_index() {
  local idx="$1"
  list_manual_backup_files | sed -n "${idx}p"
}

verify_backup_archive() {
  local archive="$1"
  local checksum="${archive}.sha256"

  if [ -f "${checksum}" ] && has_cmd sha256sum; then
    if ! (cd "$(dirname "${archive}")" && sha256sum -c "$(basename "${checksum}")"); then
      err "备份 SHA256 校验失败"
      return 1
    fi
  fi

  if ! tar -tzf "${archive}" >/dev/null 2>&1; then
    err "备份压缩包损坏或格式无效"
    return 1
  fi

  if tar -tzf "${archive}" | awk '
      /^\// {bad=1}
      /(^|\/)\.\.($|\/)/ {bad=1}
      END {exit bad ? 0 : 1}
    '; then
    err "备份中存在不安全路径，拒绝恢复"
    return 1
  fi

  return 0
}

restart_singbox_after_restore() {
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable sing-box >/dev/null 2>&1 || true
  systemctl restart sing-box && systemctl is-active --quiet sing-box
}

create_manual_backup() {
  local archive
  archive="$(create_backup_archive manual)" || {
    pause_enter
    return 1
  }

  ok "备份创建成功：${archive}"
  if [ -f "${archive}.sha256" ]; then
    echo "校验文件：${archive}.sha256"
  fi
  pause_enter
}

restore_tree_if_present() {
  local root="$1"
  local rel="$2"
  local src="${root}/${rel}"
  local dst="/${rel}"

  [ -e "${src}" ] || return 0

  if [ -d "${src}" ]; then
    mkdir -p "${dst}"
    cp -a "${src}/." "${dst}/"
  else
    mkdir -p "$(dirname "${dst}")"
    cp -a "${src}" "${dst}"
  fi
}

restore_manual_backup() {
  need_root
  require_python3 || {
    pause_enter
    return 1
  }
  mkdir -p "${TMP_DIR}"

  local idx archive restore_dir old_config pre_archive
  show_manual_backups
  echo

  idx="$(prompt_required "请输入要恢复的备份编号")"
  archive="$(get_backup_path_by_index "${idx}")"

  if [ -z "${archive}" ] || [ ! -f "${archive}" ]; then
    err "备份编号无效"
    pause_enter
    return 1
  fi

  echo "准备恢复：${archive}"
  if ! confirm_default_no "确认继续吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  verify_backup_archive "${archive}" || {
    pause_enter
    return 1
  }

  restore_dir="${TMP_DIR}/restore-${RANDOM}-$$"
  mkdir -p "${restore_dir}"
  chmod 700 "${restore_dir}" 2>/dev/null || true

  if ! tar -xzf "${archive}" -C "${restore_dir}"; then
    err "解压备份失败"
    pause_enter
    return 1
  fi

  # V2 备份路径；旧版备份仍可能把 config.json 放在归档根目录。
  local candidate_config=""
  if [ -f "${restore_dir}/etc/sing-box/config.json" ]; then
    candidate_config="${restore_dir}/etc/sing-box/config.json"
  elif [ -f "${restore_dir}/config.json" ]; then
    candidate_config="${restore_dir}/config.json"
  fi

  if [ -z "${candidate_config}" ]; then
    err "备份中未找到 config.json，无法恢复"
    pause_enter
    return 1
  fi

  if ! check_config_file "${candidate_config}"; then
    err "备份中的 sing-box 配置校验失败，已停止恢复"
    pause_enter
    return 1
  fi

  old_config="${TMP_DIR}/pre-restore-config.json"
  [ -f "${CONFIG_DIR}/config.json" ] && cp -p "${CONFIG_DIR}/config.json" "${old_config}" || true

  pre_archive="$(create_backup_archive pre-restore 2>/dev/null || true)"
  [ -n "${pre_archive}" ] && echo "已创建恢复前快照：${pre_archive}"

  if [ -d "${restore_dir}/etc/sing-box" ]; then
    mkdir -p "${CONFIG_DIR}"
    cp -a "${restore_dir}/etc/sing-box/." "${CONFIG_DIR}/"
  else
    install -m 600 "${candidate_config}" "${CONFIG_DIR}/config.json"
    [ -f "${restore_dir}/reality-meta.json" ] && install -m 600 "${restore_dir}/reality-meta.json" "${META_FILE}" || true
  fi

  for rel in     "usr/local/share/sbm/meta"     "usr/local/share/sbm/realm-meta"     "usr/local/share/sbm/outbound-proxy-state.json"     "usr/local/share/sbm/policy-groups.json"     "usr/local/share/sbm/install.env"     "etc/realm"; do
    restore_tree_if_present "${restore_dir}" "${rel}"
  done

  chmod 600 "${CONFIG_DIR}/config.json" 2>/dev/null || true
  chmod 700 "${INBOUND_META_DIR}" "${SOURCES_DIR}" "${NODE_CACHE_DIR}" 2>/dev/null || true
  [ -d "${INBOUND_META_DIR}" ] && find "${INBOUND_META_DIR}" -type f -exec chmod 600 {} + 2>/dev/null || true

  if ! restart_singbox_after_restore; then
    err "恢复后的配置未能正常启动"
    if [ -f "${old_config}" ]; then
      warn "正在自动恢复恢复操作前的 config.json"
      install -m 600 "${old_config}" "${CONFIG_DIR}/config.json"
      systemctl restart sing-box >/dev/null 2>&1 || true
    fi
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
    echo "          备份与恢复管理 V2"
    echo "======================================"
    echo "备份目录：${SBM_BACKUP_ROOT}"
    echo
    echo "1. 创建完整手动备份"
    echo "2. 查看备份列表"
    echo "3. 校验并恢复备份"
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
