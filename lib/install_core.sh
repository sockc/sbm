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

install_singbox_latest() {
  msg "开始安装最新稳定版..."
  bash -c "$(curl -fsSL https://sing-box.app/install.sh)" || {
    err "安装失败"
    return 1
  }
  ok "安装完成"
}

install_singbox_version() {
  local ver="$1"
  msg "开始安装 sing-box ${ver} ..."
  bash -c "$(curl -fsSL https://sing-box.app/install.sh)" -- --version "$ver" || {
    err "安装失败: ${ver}"
    return 1
  }
  ok "安装完成: ${ver}"
}
