#!/usr/bin/env bash

menu_install_core() {
  need_root

  while true; do
    clear
    echo "======================================"
    echo "        安装 / 升级 sing-box"
    echo "======================================"
    echo "1. 安装推荐稳定版 (${DEFAULT_SINGBOX_VERSION})"
    echo "2. 安装最新稳定版"
    echo "3. 安装指定版本"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-3]: " choice
    case "${choice:-}" in
      1)
        install_singbox_version "${DEFAULT_SINGBOX_VERSION}"
        pause_enter
        return
        ;;
      2)
        install_singbox_latest
        pause_enter
        return
        ;;
      3)
        local ver
        ver="$(prompt_required "请输入版本号，例如 1.13.3")"
        install_singbox_version "$ver"
        pause_enter
        return
        ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

cleanup_upstream_demo_inbound() {
  local cfg="${CONFIG_DIR}/config.json"
  local tmp removed was_active="false"

  [ -f "${cfg}" ] || return 0
  has_cmd python3 || return 0

  mkdir -p "${TMP_DIR}"
  tmp="${TMP_DIR}/config.cleanup-upstream-demo.json"
  cp -p "${cfg}" "${tmp}" || return 1

  removed="$(
    python3 - "${tmp}" <<'PY'
import json, sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

def is_upstream_demo(ib):
    if not isinstance(ib, dict):
        return False
    mux = ib.get("multiplex", {}) or {}
    return (
        ib.get("type") == "shadowsocks"
        and not str(ib.get("tag", "") or "")
        and ib.get("listen") == "::"
        and ib.get("listen_port") == 8080
        and ib.get("network") == "tcp"
        and ib.get("method") == "2022-blake3-aes-128-gcm"
        and ib.get("password") == "Gn1JUS14bLUHgv1cWDDp4A=="
        and mux.get("enabled") is True
        and mux.get("padding") is True
    )

inbounds = cfg.get("inbounds", [])
kept = [ib for ib in inbounds if not is_upstream_demo(ib)]
removed = len(inbounds) - len(kept)

if removed:
    cfg["inbounds"] = kept
    with open(path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)

print(removed)
PY
  )" || {
    rm -f -- "${tmp}"
    return 1
  }

  if [ "${removed}" -eq 0 ]; then
    rm -f -- "${tmp}"
    return 0
  fi

  if ! check_config_file "${tmp}" >/dev/null 2>&1; then
    warn "检测到 sing-box 官方示例 Shadowsocks 入站，但清理后的配置校验失败，已保持原配置"
    rm -f -- "${tmp}"
    return 1
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet sing-box.service 2>/dev/null; then
    was_active="true"
  fi

  activate_config_file "${tmp}"
  rm -f -- "${tmp}"

  if [ "${was_active}" = "true" ]; then
    if ! restart_singbox_service_safe; then
      err "清理官方示例 Shadowsocks 入站后服务重启失败，已尝试自动回滚"
      return 1
    fi
  else
    clear_config_rollback_point
  fi

  ok "已清理 sing-box 官方示例入站：Shadowsocks :::8080"
  return 0
}

download_singbox_installer() {
  local dst="${TMP_DIR}/sing-box-install.sh"
  mkdir -p "${TMP_DIR}"

  if ! fetch_to_file "https://sing-box.app/install.sh" "${dst}"; then
    err "下载 sing-box 官方安装脚本失败"
    return 1
  fi

  chmod 700 "${dst}" 2>/dev/null || true

  if ! bash -n "${dst}"; then
    err "sing-box 官方安装脚本语法检查失败，已停止执行"
    return 1
  fi

  printf '%s\n' "${dst}"
}

install_singbox_latest() {
  local installer
  installer="$(download_singbox_installer)" || return 1

  msg "开始安装最新稳定版..."
  if ! bash "${installer}"; then
    err "安装失败"
    return 1
  fi

  if ! has_cmd sing-box; then
    err "安装脚本执行完成，但系统中仍未找到 sing-box"
    return 1
  fi

  cleanup_upstream_demo_inbound || true
  ok "安装完成：$(sing-box version 2>/dev/null | head -n1)"
}

install_singbox_version() {
  local ver="$1"
  local installer

  if ! [[ "${ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z._-]+)?$ ]]; then
    err "版本号格式无效：${ver}"
    return 1
  fi

  installer="$(download_singbox_installer)" || return 1

  msg "开始安装 sing-box ${ver} ..."
  if ! bash "${installer}" -- --version "${ver}"; then
    err "安装失败: ${ver}"
    return 1
  fi

  if ! has_cmd sing-box; then
    err "安装脚本执行完成，但系统中仍未找到 sing-box"
    return 1
  fi

  cleanup_upstream_demo_inbound || true
  ok "安装完成: $(sing-box version 2>/dev/null | head -n1)"
}
