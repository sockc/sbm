#!/usr/bin/env bash

prompt_default() {
  local prompt="$1"
  local default_value="$2"
  local input

  read -r -p "${prompt} [默认: ${default_value}]: " input
  if [ -z "${input}" ]; then
    printf '%s\n' "$default_value"
  else
    printf '%s\n' "$input"
  fi
}

prompt_required() {
  local prompt="$1"
  local input
  while true; do
    read -r -p "${prompt}: " input
    [ -n "$input" ] && { printf '%s\n' "$input"; return 0; }
    echo "此项不能为空"
  done
}

confirm_default_yes() {
  local prompt="$1"
  local input
  read -r -p "${prompt} [Y/n]: " input
  case "${input:-Y}" in
    Y|y|YES|yes) return 0 ;;
    *) return 1 ;;
  esac
}

confirm_default_no() {
  local prompt="$1"
  local input
  read -r -p "${prompt} [y/N]: " input
  case "${input:-N}" in
    Y|y|YES|yes) return 0 ;;
    *) return 1 ;;
  esac
}
