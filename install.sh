#!/usr/bin/env bash
set -euo pipefail
umask 077

REPO="${REPO:-sockc/sbm}"
BRANCH="${BRANCH:-main}"
REF="${REF:-${BRANCH}}"
SOURCE_REF=""

INSTALL_DIR="/usr/local/share/sbm"
BIN_PATH="/usr/local/sbin/sbm"
PARENT_DIR="/usr/local/share"

FILES=(
  "sbm.sh"
  "lib/env.sh"
  "lib/common.sh"
  "lib/input.sh"
  "lib/install_core.sh"
  "lib/validate.sh"
  "lib/inbound.sh"
  "lib/export.sh"
  "lib/user.sh"
  "lib/inbound_manager.sh"
  "lib/outbound.sh"
  "lib/firewall.sh"
  "lib/backup.sh"
  "lib/self_update.sh"
  "lib/clash_api.sh"
  "lib/web_panel.sh"
  "lib/template.sh"
  "lib/outbound_wizard.sh"
  "lib/uninstall.sh"
  "lib/system_proxy.sh"
  "lib/realm_relay.sh"
)

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

die() {
  echo "错误：$*" >&2
  exit 1
}

fetch_to() {
  local url="$1"
  local dst="$2"

  mkdir -p "$(dirname "$dst")"

  if need_cmd curl; then
    curl --retry 2 --connect-timeout 15 -fsSL "$url" -o "$dst"
  elif need_cmd wget; then
    wget -T 20 -qO "$dst" "$url"
  else
    die "未找到 curl 或 wget"
  fi
}

resolve_source_ref() {
  if [[ "${REF}" =~ ^[0-9a-fA-F]{40}$ ]]; then
    SOURCE_REF="${REF,,}"
    return 0
  fi

  local sha=""
  local git_url="https://github.com/${REPO}.git"

  if need_cmd git; then
    sha="$(
      env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
          -u all_proxy -u ALL_PROXY -u no_proxy -u NO_PROXY \
          git ls-remote "${git_url}" "refs/heads/${REF}" 2>/dev/null \
        | awk 'NR==1 {print $1}'
    )"
    if [[ "${sha}" =~ ^[0-9a-fA-F]{40}$ ]]; then
      SOURCE_REF="${sha,,}"
      return 0
    fi

    sha="$(
      git ls-remote "${git_url}" "refs/heads/${REF}" 2>/dev/null \
        | awk 'NR==1 {print $1}'
    )"
    if [[ "${sha}" =~ ^[0-9a-fA-F]{40}$ ]]; then
      SOURCE_REF="${sha,,}"
      return 0
    fi
  fi

  local meta_file
  meta_file="$(mktemp "/tmp/sbm-ref.XXXXXX")"

  if fetch_to "https://api.github.com/repos/${REPO}/commits/${REF}" "${meta_file}"; then
    sha="$(
      python3 - "${meta_file}" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    print(str(data.get("sha", "") or ""))
except Exception:
    print("")
PY
    )"
  fi

  rm -f "${meta_file}"

  if [[ "${sha}" =~ ^[0-9a-fA-F]{40}$ ]]; then
    SOURCE_REF="${sha,,}"
    return 0
  fi

  # 最后兼容回退：仍使用 staging + 完整校验，避免因为 GitHub API 不可达而完全无法更新。
  SOURCE_REF="${REF}"
  echo "警告：无法解析固定 commit，将直接使用来源 ${REF}" >&2
}

validate_stage() {
  local stage="$1"
  local file

  for file in "${FILES[@]}"; do
    [ -s "${stage}/${file}" ] || die "下载文件为空：${file}"
    bash -n "${stage}/${file}" || die "Shell 语法检查失败：${file}"
  done

  if [ ! -s "${stage}/policy-groups.json" ]; then
    die "policy-groups.json 不存在或为空"
  fi

  python3 - "${stage}/policy-groups.json" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    json.load(f)
PY
}

main() {
  [ "$(id -u)" -eq 0 ] || die "请使用 root 运行"
  need_cmd python3 || die "缺少 python3；sbm 的配置处理依赖 Python 3，请先安装"

  echo "==> 安装/升级 sbm"
  echo "仓库: ${REPO}"
  echo "来源: ${REF}"

  resolve_source_ref
  echo "固定提交: ${SOURCE_REF}"

  mkdir -p "${PARENT_DIR}" "$(dirname "${BIN_PATH}")"

  local stage old_dir file
  stage="$(mktemp -d "${PARENT_DIR}/.sbm.new.XXXXXX")"
  old_dir="${PARENT_DIR}/.sbm.old.$$"

  cleanup() {
    if [ -n "${stage:-}" ] && [ -d "${stage}" ]; then
      rm -rf -- "${stage}" 2>/dev/null || true
    fi
    if [ -n "${old_dir:-}" ] && [ -d "${old_dir}" ]; then
      rm -rf -- "${old_dir}" 2>/dev/null || true
    fi
    return 0
  }
  trap cleanup EXIT

  # 先继承现有运行状态/元数据，再覆盖本次发布文件。
  if [ -d "${INSTALL_DIR}" ]; then
    cp -a "${INSTALL_DIR}/." "${stage}/"
  fi

  for file in "${FILES[@]}"; do
    fetch_to "https://raw.githubusercontent.com/${REPO}/${SOURCE_REF}/${file}" "${stage}/${file}"
    chmod 755 "${stage}/${file}"
  done

  # 用户已经自定义过策略文件时不覆盖；首次安装才从仓库获取。
  if [ ! -f "${stage}/policy-groups.json" ]; then
    fetch_to "https://raw.githubusercontent.com/${REPO}/${SOURCE_REF}/policy-groups.json" "${stage}/policy-groups.json"
  fi
  chmod 600 "${stage}/policy-groups.json" 2>/dev/null || true

  validate_stage "${stage}"

  cat > "${stage}/install.env" <<EOF
SBM_REPO="${REPO}"
SBM_BRANCH="${BRANCH}"
SBM_INSTALLED_REF="${SOURCE_REF}"
EOF
  chmod 600 "${stage}/install.env"

  # 收紧已有状态目录/敏感文件权限。
  for d in "${stage}/meta" "${stage}/realm-meta"; do
    [ -d "${d}" ] && chmod 700 "${d}" 2>/dev/null || true
  done
  [ -d "${stage}/meta" ] && find "${stage}/meta" -type f -exec chmod 600 {} + 2>/dev/null || true
  [ -d "${stage}/realm-meta" ] && find "${stage}/realm-meta" -type f -exec chmod 600 {} + 2>/dev/null || true

  # 同一文件系统内通过目录 rename 完成切换，避免下载一半造成混装。
  if [ -d "${INSTALL_DIR}" ]; then
    mv "${INSTALL_DIR}" "${old_dir}"
  fi

  if ! mv "${stage}" "${INSTALL_DIR}"; then
    [ -d "${old_dir}" ] && mv "${old_dir}" "${INSTALL_DIR}" || true
    die "切换新版本失败，已尝试恢复旧版本"
  fi
  stage=""

  if [ -d "${old_dir}" ]; then
    rm -rf -- "${old_dir}"
    old_dir=""
  fi

  local tmp_bin
  tmp_bin="$(mktemp "$(dirname "${BIN_PATH}")/.sbm-bin.XXXXXX")"
  cat > "${tmp_bin}" <<'EOF'
#!/usr/bin/env bash
exec /usr/local/share/sbm/sbm.sh "$@"
EOF
  chmod 755 "${tmp_bin}"
  mv -f "${tmp_bin}" "${BIN_PATH}"

  echo
  echo "安装完成"
  echo "命令入口: ${BIN_PATH}"
  echo "运行方式: sbm"
}

main "$@"
