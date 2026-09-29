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
  local tmp

  tmp="$(mktemp "${TMP_DIR:-/tmp}/sbm-fetch.XXXXXX")" || return 1

  cleanup_fetch_tmp() {
    rm -f -- "${tmp}" 2>/dev/null || true
  }

  if has_cmd curl; then
    # 每次尝试都写入独立临时文件；失败响应不会污染下一次重试的输出。
    if env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
          -u all_proxy -u ALL_PROXY -u no_proxy -u NO_PROXY \
          curl --noproxy '*' --retry 1 --connect-timeout 10 -fsSL "$url" -o "${tmp}"; then
      cat "${tmp}"
      cleanup_fetch_tmp
      return 0
    fi

    : > "${tmp}"
    if curl --retry 2 --connect-timeout 15 -fsSL "$url" -o "${tmp}"; then
      cat "${tmp}"
      cleanup_fetch_tmp
      return 0
    fi

    cleanup_fetch_tmp
    return 1
  fi

  if has_cmd wget; then
    if env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
          -u all_proxy -u ALL_PROXY -u no_proxy -u NO_PROXY \
          wget -e use_proxy=no -T 15 -qO "${tmp}" "$url"; then
      cat "${tmp}"
      cleanup_fetch_tmp
      return 0
    fi

    : > "${tmp}"
    if wget -T 20 -qO "${tmp}" "$url"; then
      cat "${tmp}"
      cleanup_fetch_tmp
      return 0
    fi

    cleanup_fetch_tmp
    return 1
  fi

  cleanup_fetch_tmp
  err "未找到 curl 或 wget"
  return 1
}

get_remote_commit_sha() {
  get_install_source

  local sha=""
  local git_url="https://github.com/${SBM_REPO_LOCAL}.git"

  # 优先使用 git ls-remote，避免把脚本更新强绑定到 api.github.com。
  if has_cmd git; then
    sha="$(
      env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
          -u all_proxy -u ALL_PROXY -u no_proxy -u NO_PROXY \
          git ls-remote "${git_url}" "refs/heads/${SBM_BRANCH_LOCAL}" 2>/dev/null \
        | awk 'NR==1 {print $1}'
    )"
    if [[ "${sha}" =~ ^[0-9a-fA-F]{40}$ ]]; then
      printf '%s\n' "${sha,,}"
      return 0
    fi

    sha="$(
      git ls-remote "${git_url}" "refs/heads/${SBM_BRANCH_LOCAL}" 2>/dev/null \
        | awk 'NR==1 {print $1}'
    )"
    if [[ "${sha}" =~ ^[0-9a-fA-F]{40}$ ]]; then
      printf '%s\n' "${sha,,}"
      return 0
    fi
  fi

  local url json
  url="https://api.github.com/repos/${SBM_REPO_LOCAL}/commits/${SBM_BRANCH_LOCAL}"
  json="$(fetch_text "${url}" 2>/dev/null)" || return 1

  if has_cmd python3; then
    sha="$(
      REMOTE_COMMIT_JSON="${json}" python3 - <<'PY'
import json, os
data = json.loads(os.environ["REMOTE_COMMIT_JSON"])
print(str(data.get("sha", "") or ""))
PY
    )"
  else
    sha="$(printf '%s\n' "${json}" | sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F]\{40\}\)".*/\1/p' | head -n1)"
  fi

  if [[ "${sha}" =~ ^[0-9a-fA-F]{40}$ ]]; then
    printf '%s\n' "${sha,,}"
    return 0
  fi

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
  local remote_sha installed_ref
  remote_sha="$(get_remote_commit_sha 2>/dev/null || true)"
  installed_ref="${SBM_INSTALLED_REF:-}"
  if [ -f "${BASE_DIR}/install.env" ]; then
    # shellcheck disable=SC1090
    source "${BASE_DIR}/install.env"
    installed_ref="${SBM_INSTALLED_REF:-${installed_ref}}"
  fi

  echo "安装来源分支 : ${SBM_BRANCH_LOCAL}"
  echo "当前固定提交 : ${installed_ref:-旧版本未记录}"
  echo "远端最新提交 : ${remote_sha:-获取失败}"
  echo "远端脚本版本 : ${remote_ver:-获取失败}"
}

run_self_update() {
  need_root
  mkdir -p "${TMP_DIR}"
  get_install_source

  local tmp_installer url remote_sha update_ref
  remote_sha="$(get_remote_commit_sha 2>/dev/null || true)"
  if [ -n "${remote_sha}" ]; then
    update_ref="${remote_sha}"
  else
    update_ref="${SBM_BRANCH_LOCAL}"
    warn "无法解析远端固定 commit，将回退到分支 ${SBM_BRANCH_LOCAL} 更新"
    warn "安装器仍会先完整下载并校验，再切换现有版本"
  fi

  url="https://raw.githubusercontent.com/${SBM_REPO_LOCAL}/${update_ref}/install.sh"
  tmp_installer="${TMP_DIR}/sbm-install.sh"

  echo "准备从以下来源更新脚本："
  echo "仓库: ${SBM_REPO_LOCAL}"
  echo "分支: ${SBM_BRANCH_LOCAL}"
  if [ -n "${remote_sha}" ]; then
    echo "固定提交: ${remote_sha}"
  else
    echo "更新来源: ${SBM_BRANCH_LOCAL}（commit 解析失败，使用兼容模式）"
  fi
  echo

  if ! confirm_default_yes "确认执行脚本自更新吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  if ! fetch_text "$url" > "${tmp_installer}"; then
    err "下载远端 install.sh 失败"
    echo
    echo "提示："
    echo "1. 请先检查当前 shell 是否残留 http_proxy / https_proxy / all_proxy"
    echo "2. 可手动执行：unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY"
    pause_enter
    return 1
  fi

  chmod 700 "${tmp_installer}"

  if ! bash -n "${tmp_installer}"; then
    err "下载到的 install.sh 语法检查失败，已停止更新"
    pause_enter
    return 1
  fi

  if REPO="${SBM_REPO_LOCAL}" BRANCH="${SBM_BRANCH_LOCAL}" REF="${update_ref}" bash "${tmp_installer}"; then
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
