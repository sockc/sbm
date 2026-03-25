#!/usr/bin/env bash

SYSTEM_PROXY_TAG="system-proxy-in"
SYSTEM_PROXY_PROFILE="/etc/profile.d/sbm-system-proxy.sh"
SYSTEM_PROXY_APT="/etc/apt/apt.conf.d/80sbm-proxy"

require_system_proxy_env() {
  if [ ! -f "${CONFIG_DIR}/config.json" ]; then
    err "未找到 ${CONFIG_DIR}/config.json，请先部署基础配置"
    return 1
  fi
  if ! has_cmd python3; then
    err "缺少 python3，无法处理 JSON"
    return 1
  fi
}

get_system_proxy_info() {
  python3 - "${CONFIG_DIR}/config.json" "${SYSTEM_PROXY_TAG}" <<'PY'
import json, os, sys

cfg_path = sys.argv[1]
tag = sys.argv[2]

if not os.path.exists(cfg_path):
    print("false")
    print("")
    print("")
    print("false")
    raise SystemExit(0)

cfg = json.load(open(cfg_path, 'r', encoding='utf-8'))

for ib in cfg.get("inbounds", []):
    if ib.get("tag") == tag:
        print("true")
        print(ib.get("listen", ""))
        print(ib.get("listen_port", ""))
        print("true" if ib.get("set_system_proxy", False) else "false")
        raise SystemExit(0)

print("false")
print("")
print("")
print("false")
PY
}

write_system_proxy_env_files() {
  local port="$1"

  cat > "${SYSTEM_PROXY_PROFILE}" <<EOF
export http_proxy="http://127.0.0.1:${port}"
export https_proxy="http://127.0.0.1:${port}"
export HTTP_PROXY="http://127.0.0.1:${port}"
export HTTPS_PROXY="http://127.0.0.1:${port}"
export all_proxy="socks5h://127.0.0.1:${port}"
export ALL_PROXY="socks5h://127.0.0.1:${port}"
export no_proxy="127.0.0.1,localhost,::1"
export NO_PROXY="127.0.0.1,localhost,::1"
EOF

  chmod 644 "${SYSTEM_PROXY_PROFILE}" 2>/dev/null || true

  if [ -d /etc/apt/apt.conf.d ]; then
    cat > "${SYSTEM_PROXY_APT}" <<EOF
Acquire::http::Proxy "http://127.0.0.1:${port}";
Acquire::https::Proxy "http://127.0.0.1:${port}";
EOF
    chmod 644 "${SYSTEM_PROXY_APT}" 2>/dev/null || true
  fi
}

remove_system_proxy_env_files() {
  rm -f "${SYSTEM_PROXY_PROFILE}"
  rm -f "${SYSTEM_PROXY_APT}"
}

enable_system_proxy() {
  need_root
  require_system_proxy_env || {
    pause_enter
    return 1
  }

  local listen_addr listen_port tmp_file
  listen_addr="127.0.0.1"
  listen_port="$(prompt_default "请输入系统代理本地端口" "7890")"

  echo
  echo "将启用系统代理："
  echo "类型        : mixed (HTTP + SOCKS)"
  echo "监听地址    : ${listen_addr}"
  echo "监听端口    : ${listen_port}"
  echo "环境变量文件: ${SYSTEM_PROXY_PROFILE}"
  if [ -d /etc/apt/apt.conf.d ]; then
    echo "APT 代理文件 : ${SYSTEM_PROXY_APT}"
  fi
  echo

  if ! confirm_default_yes "确认继续吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  tmp_file="${TMP_DIR}/config.system-proxy.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "${SYSTEM_PROXY_TAG}" "${listen_addr}" "${listen_port}" <<'PY'
import json, sys

cfg_path, tag, listen_addr, listen_port = sys.argv[1:]
cfg = json.load(open(cfg_path, 'r', encoding='utf-8'))
inbounds = cfg.setdefault("inbounds", [])

obj = {
    "type": "mixed",
    "tag": tag,
    "listen": listen_addr,
    "listen_port": int(listen_port),
    "set_system_proxy": True
}

replaced = False
for i, ib in enumerate(inbounds):
    if ib.get("tag") == tag:
        inbounds[i] = obj
        replaced = True
        break

if not replaced:
    inbounds.append(obj)

with open(cfg_path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "写入系统代理配置失败"
    pause_enter
    return 1
  fi

  if ! check_config_file "${tmp_file}"; then
    err "配置校验失败，未覆盖正式配置"
    pause_enter
    return 1
  fi

  activate_config_file "${tmp_file}"

  if ! restart_singbox_service; then
    err "服务重启失败，可执行 journalctl -u sing-box -n 100 --no-pager 查看日志"
    pause_enter
    return 1
  fi

  write_system_proxy_env_files "${listen_port}"

  ok "系统代理已启用"
  echo
  echo "HTTP 代理 : http://127.0.0.1:${listen_port}"
  echo "SOCKS 代理: socks5h://127.0.0.1:${listen_port}"
  echo
  echo "说明："
  echo "1. 新开的 shell 会自动带上代理环境变量"
  echo "2. 当前 shell 如需立即生效，可执行："
  echo "   source ${SYSTEM_PROXY_PROFILE}"
  echo

  pause_enter
}

disable_system_proxy() {
  need_root
  require_system_proxy_env || {
    pause_enter
    return 1
  }

  if ! confirm_default_yes "确认关闭系统代理吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  local tmp_file
  tmp_file="${TMP_DIR}/config.system-proxy.disable.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "${SYSTEM_PROXY_TAG}" <<'PY'
import json, sys

cfg_path, tag = sys.argv[1:]
cfg = json.load(open(cfg_path, 'r', encoding='utf-8'))
inbounds = cfg.get("inbounds", [])
cfg["inbounds"] = [ib for ib in inbounds if ib.get("tag") != tag]

with open(cfg_path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "移除系统代理入站失败"
    pause_enter
    return 1
  fi

  if ! check_config_file "${tmp_file}"; then
    err "配置校验失败，未覆盖正式配置"
    pause_enter
    return 1
  fi

  activate_config_file "${tmp_file}"

  if ! restart_singbox_service; then
    err "服务重启失败，可执行 journalctl -u sing-box -n 100 --no-pager 查看日志"
    pause_enter
    return 1
  fi

  remove_system_proxy_env_files

  ok "系统代理已关闭"
  echo
  echo "提示：当前 shell 里如果还有旧代理变量，可手动执行："
  echo "unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY"
  echo

  pause_enter
}

show_system_proxy_status() {
  require_system_proxy_env || {
    pause_enter
    return 1
  }

  mapfile -t _sys_proxy_info < <(get_system_proxy_info)

  local enabled="${_sys_proxy_info[0]:-false}"
  local listen_addr="${_sys_proxy_info[1]:-}"
  local listen_port="${_sys_proxy_info[2]:-}"
  local set_system_proxy="${_sys_proxy_info[3]:-false}"

  echo "======================================"
  echo "             系统代理状态"
  echo "======================================"
  if [ "${enabled}" != "true" ]; then
    echo "状态              : 未启用"
  else
    echo "状态              : 已启用"
    echo "监听地址          : ${listen_addr}:${listen_port}"
    echo "类型              : mixed (HTTP + SOCKS)"
    echo "set_system_proxy   : ${set_system_proxy}"
    echo "HTTP 代理          : http://${listen_addr}:${listen_port}"
    echo "SOCKS 代理         : socks5h://${listen_addr}:${listen_port}"
  fi

  if [ -f "${SYSTEM_PROXY_PROFILE}" ]; then
    echo "Shell 环境文件     : 已写入"
  else
    echo "Shell 环境文件     : 未写入"
  fi

  if [ -f "${SYSTEM_PROXY_APT}" ]; then
    echo "APT 代理文件       : 已写入"
  else
    echo "APT 代理文件       : 未写入"
  fi

  echo "======================================"
  pause_enter
}

menu_system_proxy() {
  while true; do
    clear
    echo "======================================"
    echo "             系统代理管理"
    echo "======================================"
    echo "1. 启用系统代理"
    echo "2. 关闭系统代理"
    echo "3. 查看状态"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-3]: " choice
    case "${choice:-}" in
      1) enable_system_proxy ;;
      2) disable_system_proxy ;;
      3) show_system_proxy_status ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
