#!/usr/bin/env bash

SYSTEM_PROXY_TAG="system-proxy-in"

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

cleanup_legacy_system_proxy_env() {
  rm -f /etc/profile.d/sbm-system-proxy.sh
  rm -f /etc/apt/apt.conf.d/80sbm-proxy
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
    raise SystemExit(0)

cfg = json.load(open(cfg_path, 'r', encoding='utf-8'))

for ib in cfg.get("inbounds", []):
    if ib.get("tag") == tag and ib.get("type") == "mixed":
        print("true")
        print(ib.get("listen", "127.0.0.1"))
        print(ib.get("listen_port", ""))
        raise SystemExit(0)

print("false")
print("")
print("")
PY
}

enable_system_proxy() {
  need_root
  require_system_proxy_env || {
    pause_enter
    return 1
  }

  local listen_addr listen_port tmp_file
  listen_addr="127.0.0.1"
  listen_port="$(prompt_default "请输入本地代理端口" "7890")"

  echo
  echo "将启用本地代理入口："
  echo "类型        : mixed (HTTP + SOCKS)"
  echo "监听地址    : ${listen_addr}"
  echo "监听端口    : ${listen_port}"
  echo "说明        : 仅创建本地代理入口，不修改系统全局代理环境"
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
    "listen_port": int(listen_port)
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
    err "写入本地代理配置失败"
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

  cleanup_legacy_system_proxy_env

  ok "本地代理入口已启用"
  echo
  echo "HTTP 代理 : http://127.0.0.1:${listen_port}"
  echo "SOCKS 代理: socks5h://127.0.0.1:${listen_port}"
  echo
  echo "测试方法示例："
  echo "curl -x http://127.0.0.1:${listen_port} https://ifconfig.me"
  echo

  pause_enter
}

disable_system_proxy() {
  need_root
  require_system_proxy_env || {
    pause_enter
    return 1
  }

  if ! confirm_default_yes "确认关闭本地代理入口吗？"; then
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
    err "移除本地代理入站失败"
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

  cleanup_legacy_system_proxy_env

  ok "本地代理入口已关闭"
  echo
  echo "如果你当前 shell 里还残留旧代理变量，可手动执行："
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

  echo "======================================"
  echo "             本地代理状态"
  echo "======================================"
  if [ "${enabled}" != "true" ]; then
    echo "状态              : 未启用"
  else
    echo "状态              : 已启用"
    echo "监听地址          : ${listen_addr}:${listen_port}"
    echo "类型              : mixed (HTTP + SOCKS)"
    echo "HTTP 代理          : http://${listen_addr}:${listen_port}"
    echo "SOCKS 代理         : socks5h://${listen_addr}:${listen_port}"
  fi
  echo "======================================"
  pause_enter
}

menu_system_proxy() {
  while true; do
    clear
    echo "======================================"
    echo "             本地代理管理"
    echo "======================================"
    echo "1. 启用本地代理入口"
    echo "2. 关闭本地代理入口"
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
