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
