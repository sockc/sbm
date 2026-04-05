#!/usr/bin/env bash

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
