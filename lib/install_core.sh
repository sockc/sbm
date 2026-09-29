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

  ok "安装完成: $(sing-box version 2>/dev/null | head -n1)"
}
