#!/usr/bin/env bash

gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
    return 0
  fi
  if has_cmd uuidgen; then
    uuidgen
    return 0
  fi
  python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
}

gen_short_id() {
  if has_cmd openssl; then
    openssl rand -hex 4
    return 0
  fi
  od -An -N4 -tx1 /dev/urandom | tr -d ' \n'
}

gen_reality_keypair() {
  local out private_key public_key

  out="$(sing-box generate reality-keypair 2>/dev/null || true)"
  private_key="$(printf '%s\n' "$out" | awk -F': *' '/[Pp]rivate/ {print $2; exit}')"
  public_key="$(printf '%s\n' "$out" | awk -F': *' '/[Pp]ublic/ {print $2; exit}')"

  if [ -z "$private_key" ] || [ -z "$public_key" ]; then
    err "生成 Reality 密钥失败"
    return 1
  fi

  printf '%s|%s\n' "$private_key" "$public_key"
}

detect_connect_host() {
  local ip=""
  if has_cmd curl; then
    ip="$(curl -4fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
  elif has_cmd wget; then
    ip="$(wget -qO- --timeout=3 https://api.ipify.org 2>/dev/null || true)"
  fi

  if [ -n "$ip" ]; then
    printf '%s\n' "$ip"
    return 0
  fi

  hostname -I 2>/dev/null | awk '{print $1}'
}

restart_singbox_service() {
  systemctl daemon-reload || true
  systemctl enable sing-box >/dev/null 2>&1 || true
  systemctl restart sing-box
}

deploy_vless_reality() {
  need_root

  if ! has_cmd sing-box; then
    err "未检测到 sing-box，请先安装内核"
    pause_enter
    return 1
  fi

  mkdir -p "${CONFIG_DIR}" "${BACKUP_DIR}" "${TMP_DIR}"

  local listen_addr listen_port user_name user_uuid
  local server_name handshake_server handshake_port
  local short_id keys private_key public_key
  local connect_host tcp_fast_open config_tmp tfo_json
  local default_host

  default_host="$(detect_connect_host)"
  [ -z "$default_host" ] && default_host="YOUR_SERVER_IP"

  listen_addr="$(prompt_listen_addr="$(prompt_default "请输入监听地址" "0.0.0.0")"
  listen_port="$(prompt_listen_port)"
  user_name="$(prompt_default "请输入用户备注" "user1")"
  user_uuid="$(prompt_default "请输入 UUID" "$(gen_uuid)")"
  server_name="$(prompt_default "请输入伪装域名 server_name" "www.cloudflare.com")"
  handshake_server="$(prompt_default "请输入 Reality 握手目标域名" "$server_name")"
  handshake_port="$(prompt_default "请输入 Reality 握手目标端口" "443")"
  short_id="$(prompt_default "请输入 short_id" "$(gen_short_id)")"
  connect_host="$(prompt_default "请输入客户端连接地址" "$default_host")"

  if confirm_default_no "开启 TCP Fast Open 吗？"; then
    tcp_fast_open="true"
  else
    tcp_fast_open="false"
  fi

  keys="$(gen_reality_keypair)" || {
    pause_enter
    return 1
  }
  private_key="${keys%%|*}"
  public_key="${keys##*|}"

  echo
  echo "========== 配置预览 =========="
  echo "监听地址       : ${listen_addr}"
  echo "监听端口       : ${listen_port}"
  echo "用户备注       : ${user_name}"
  echo "UUID           : ${user_uuid}"
  echo "server_name    : ${server_name}"
  echo "握手目标       : ${handshake_server}:${handshake_port}"
  echo "short_id       : ${short_id}"
  echo "连接地址       : ${connect_host}"
  echo "TCP Fast Open  : ${tcp_fast_open}"
  echo "=============================="
  echo

  if ! confirm_default_yes "确认写入并重启 sing-box 吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  config_tmp="${TMP_DIR}/config.json"

  cat > "${config_tmp}" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "${listen_addr}",
      "listen_port": ${listen_port},
      "tcp_fast_open": ${tcp_fast_open},
      "users": [
        {
          "name": "${user_name}",
          "uuid": "${user_uuid}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${server_name}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${handshake_server}",
            "server_port": ${handshake_port}
          },
          "private_key": "${private_key}",
          "short_id": [
            "${short_id}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "final": "direct"
  }
}
EOF

  if ! check_config_file "${config_tmp}"; then
    err "配置校验失败，未覆盖正式配置"
    pause_enter
    return 1
  fi

  activate_config_file "${config_tmp}"

  if ! restart_singbox_service; then
    err "服务重启失败，可执行 journalctl -u sing-box -n 100 --no-pager 查看日志"
    pause_enter
    return 1
  fi

  ok "VLESS + Reality 部署完成"
  echo
  echo "------ 客户端关键参数 ------"
  echo "地址        : ${connect_host}"
  echo "端口        : ${listen_port}"
  echo "UUID        : ${user_uuid}"
  echo "流控        : xtls-rprx-vision"
  echo "传输        : tcp"
  echo "TLS         : reality"
  echo "SNI         : ${server_name}"
  echo "Public Key  : ${public_key}"
  echo "Short ID    : ${short_id}"
  echo "备注        : ${user_name}"
  echo "----------------------------"
  echo

  pause_enter
}

menu_deploy_vless_reality() {
  deploy_vless_reality
}
is_valid_ip() {
  local addr="$1"

  [ "$addr" = "::" ] && return 0
  [ "$addr" = "0.0.0.0" ] && return 0

  python3 - "$addr" <<'PY'
import sys, ipaddress
try:
    ipaddress.ip_address(sys.argv[1])
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
}

prompt_listen_addr() {
  local addr
  while true; do
    addr="$(prompt_default "请输入监听地址" "0.0.0.0")"
    if is_valid_ip "$addr"; then
      printf '%s\n' "$addr"
      return 0
    fi
    echo "输入无效：监听地址必须是 IPv4/IPv6 地址，例如 0.0.0.0 或 ::"
  done
}

prompt_listen_port() {
  local port
  while true; do
    port="$(prompt_default "请输入监听端口" "443")"
    case "$port" in
      ''|*[!0-9]*)
        echo "输入无效：端口必须是 1-65535 的数字"
        ;;
      *)
        if [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
          printf '%s\n' "$port"
          return 0
        fi
        echo "输入无效：端口必须是 1-65535"
        ;;
    esac
  done
}
