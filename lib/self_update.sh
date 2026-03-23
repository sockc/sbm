#!/usr/bin/env bash

get_install_source() {
  local meta_file="${BASE_DIR}/install.env"

  SBM_REPO_LOCAL="sockc/sbm"
  SBM_BRANCH_LOCAL="main"

  if [ -f "${meta_file}" ]; then
    # shellcheck disable=SC1090
    source "${meta_file}"
    [ -n "${SBM_REPO:-}" ] && SBM_REPO_LOCAL="${SBM_REPO}"
    [ -n "${SBM_BRANCH:-}" ] && SBM_BRANCH_LOCAL="${SBM_BRANCH}"
  fi
}

fetch_text() {
  local url="$1"

  if has_cmd curl; then
    curl -fsSL "$url"
    return $?
  fi

  if has_cmd wget; then
    wget -qO- "$url"
    return $?
  fi

  err "未找到 curl 或 wget"
  return 1
}

get_remote_sbm_version() {
  get_install_source

  local url
  url="https://raw.githubusercontent.com/${SBM_REPO_LOCAL}/${SBM_BRANCH_LOCAL}/lib/env.sh"

  fetch_text "$url" 2>/dev/null | awk -F'"' '
    /^SBM_VERSION=/ {
      print $2
      found=1
      exit
    }
    END {
      if (!found) exit 1
    }
  '
}

show_self_update_info() {
  get_install_source

  local remote_ver
  remote_ver="$(get_remote_sbm_version 2>/dev/null || true)"

  echo "当前脚本版本 : ${SBM_VERSION}"
  echo "安装来源仓库 : ${SBM_REPO_LOCAL}"
  echo "安装来源分支 : ${SBM_BRANCH_LOCAL}"
  echo "远端脚本版本 : ${remote_ver:-获取失败}"
}

run_self_update() {
  need_root
  mkdir -p "${TMP_DIR}"
  get_install_source

  local tmp_installer url
  url="https://raw.githubusercontent.com/${SBM_REPO_LOCAL}/${SBM_BRANCH_LOCAL}/install.sh"
  tmp_installer="${TMP_DIR}/sbm-install.sh"

  echo "准备从以下来源更新脚本："
  echo "仓库: ${SBM_REPO_LOCAL}"
  echo "分支: ${SBM_BRANCH_LOCAL}"
  echo

  if ! confirm_default_yes "确认执行脚本自更新吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  if ! fetch_text "$url" > "${tmp_installer}"; then
    err "下载远端 install.sh 失败"
    pause_enter
    return 1
  fi

  chmod +x "${tmp_installer}"

  if REPO="${SBM_REPO_LOCAL}" BRANCH="${SBM_BRANCH_LOCAL}" bash "${tmp_installer}"; then
    ok "脚本自更新完成"
  else
    err "脚本自更新失败"
    pause_enter
    return 1
  fi

  echo
  echo "建议重新执行一次：sbm"
  pause_enter
}

menu_self_update() {
  while true; do
    clear
    echo "======================================"
    echo "            脚本自更新"
    echo "======================================"
    echo "1. 查看当前/远端版本"
    echo "2. 执行脚本自更新"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-2]: " choice
    case "${choice:-}" in
      1) show_self_update_info; pause_enter ;;
      2) run_self_update ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
