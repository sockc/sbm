#!/usr/bin/env bash

# Security defaults for all sbm runtime-created files.
# Individual modules may tighten permissions further, but must not loosen them.
umask 077

SBM_LOCK_FD=""
SBM_LOCK_DIR=""

cleanup_runtime_security() {
  if [ -n "${SBM_LOCK_DIR:-}" ] && [ -d "${SBM_LOCK_DIR}" ]; then
    rmdir "${SBM_LOCK_DIR}" 2>/dev/null || true
  fi
  if [ -n "${TMP_DIR:-}" ] && [[ "${TMP_DIR}" == /tmp/sbm.* ]] && [ -d "${TMP_DIR}" ]; then
    rm -rf -- "${TMP_DIR}"
  fi
}

acquire_sbm_lock() {
  local lock_file="/run/lock/sbm.lock"
  [ -d /run/lock ] || lock_file="/tmp/sbm-global.lock"

  if has_cmd flock; then
    exec 9>"${lock_file}"
    if ! flock -n 9; then
      err "检测到另一个 sbm 实例正在运行，请先退出另一个会话后再试"
      return 1
    fi
    SBM_LOCK_FD="9"
    return 0
  fi

  SBM_LOCK_DIR="${lock_file}.d"
  if ! mkdir "${SBM_LOCK_DIR}" 2>/dev/null; then
    err "检测到另一个 sbm 实例正在运行（或存在遗留锁：${SBM_LOCK_DIR}）"
    return 1
  fi
}

init_runtime_security() {
  umask 077

  local base_tmp="${TMPDIR:-/tmp}"
  TMP_DIR="$(mktemp -d "${base_tmp%/}/sbm.XXXXXX")" || {
    err "创建安全临时目录失败"
    return 1
  }
  chmod 700 "${TMP_DIR}" 2>/dev/null || true
  export TMP_DIR

  mkdir -p "${INBOUND_META_DIR}" "${SOURCES_DIR}" "${NODE_CACHE_DIR}" 2>/dev/null || true
  chmod 700 "${INBOUND_META_DIR}" "${SOURCES_DIR}" "${NODE_CACHE_DIR}" 2>/dev/null || true

  acquire_sbm_lock || return 1
  trap cleanup_runtime_security EXIT
  trap 'cleanup_runtime_security; exit 130' INT TERM
}

msg()  { echo -e "[*] $*"; }
ok()   { echo -e "[+] $*"; }
warn() { echo -e "[!] $*"; }
err()  { echo -e "[-] $*" >&2; }

pause_enter() {
  echo
  read -r -p "按回车继续..." _
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 运行"
    exit 1
  fi
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

fetch_to_file() {
  local url="$1"
  local dst="$2"

  mkdir -p "$(dirname "$dst")"

  if has_cmd curl; then
    curl -fsSL "$url" -o "$dst"
  elif has_cmd wget; then
    wget -qO "$dst" "$url"
  else
    err "未找到 curl 或 wget"
    return 1
  fi
}

detect_lan_ip() {
  local ip_addr=""

  if has_cmd ip; then
    ip_addr="$(
      ip -4 -o addr show up scope global 2>/dev/null \
      | awk '{print $4}' \
      | cut -d/ -f1 \
      | awk '
          /^10\./ {print; exit}
          /^192\.168\./ {print; exit}
          /^172\.(1[6-9]|2[0-9]|3[0-1])\./ {print; exit}
        '
    )"
    if [ -n "${ip_addr}" ]; then
      printf '%s\n' "${ip_addr}"
      return 0
    fi
  fi

  if has_cmd hostname; then
    ip_addr="$(
      hostname -I 2>/dev/null \
      | tr ' ' '\n' \
      | awk '
          /^10\./ {print; exit}
          /^192\.168\./ {print; exit}
          /^172\.(1[6-9]|2[0-9]|3[0-1])\./ {print; exit}
        '
    )"
    if [ -n "${ip_addr}" ]; then
      printf '%s\n' "${ip_addr}"
      return 0
    fi
  fi

  return 1
}

detect_tailscale_ip() {
  local ip_addr=""

  if has_cmd tailscale; then
    ip_addr="$(tailscale ip -4 2>/dev/null | awk 'NF{print; exit}')"
    if [ -n "${ip_addr}" ]; then
      printf '%s\n' "${ip_addr}"
      return 0
    fi
  fi

  if has_cmd ip; then
    ip_addr="$(
      ip -4 -o addr show dev tailscale0 scope global 2>/dev/null \
      | awk '{print $4}' \
      | cut -d/ -f1 \
      | awk 'NF{print; exit}'
    )"
    if [ -n "${ip_addr}" ]; then
      printf '%s\n' "${ip_addr}"
      return 0
    fi
  fi

  return 1
}


require_config_file() {
  if [ ! -f "${CONFIG_DIR}/config.json" ]; then
    err "未找到 ${CONFIG_DIR}/config.json，请先部署入站实例"
    return 1
  fi
}

require_python3() {
  if ! has_cmd python3; then
    err "缺少 python3，无法处理 JSON"
    return 1
  fi
}

mask_secret() {
  local value="${1:-}"
  local len="${#value}"
  if [ "${len}" -le 8 ]; then
    printf '%s\n' "********"
  else
    printf '%s****%s\n' "${value:0:4}" "${value: -4}"
  fi
}

mask_url() {
  local value="${1:-}"
  if [ -z "${value}" ]; then
    printf '%s\n' ""
    return 0
  fi

  if has_cmd python3; then
    python3 - "${value}" <<'PY'
import sys
from urllib.parse import urlsplit, urlunsplit

raw = sys.argv[1]
try:
    p = urlsplit(raw)
    if p.scheme not in ("http", "https"):
        print(raw)
        raise SystemExit(0)
    host = p.hostname or ""
    port = f":{p.port}" if p.port else ""
    netloc = host + port
    path = p.path
    if len(path) > 48:
        path = path[:24] + "…" + path[-16:]
    print(urlunsplit((p.scheme, netloc, path, "", "")))
except Exception:
    print("<已隐藏>")
PY
  else
    printf '%s\n' "<已隐藏>"
  fi
}
