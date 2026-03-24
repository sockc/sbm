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

  if has_cmd python3; then
    python3 -c 'import uuid; print(uuid.uuid4())'
    return 0
  fi

  err "无法生成 UUID：缺少 /proc、uuidgen 或 python3"
  return 1
}

gen_short_id() {
  if has_cmd openssl; then
    openssl rand -hex 4
    return 0
  fi

  od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
}

gen_reality_keypair() {
  local out private_key public_key

  out="$(sing-box generate reality-keypair 2>/dev/null)" || {
    err "执行 sing-box generate reality-keypair 失败"
    return 1
  }

  private_key="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}')"
  public_key="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /public/  {print $2; exit}')"

  if [ -z "$private_key" ] || [ -z "$public_key" ]; then
    err "解析 Reality 密钥失败"
    printf '%s\n' "$out"
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

is_valid_ip() {
  local addr="$1"

  [ "$addr" = "::" ] && return 0
  [ "$addr" = "0.0.0.0" ] && return 0

  if has_cmd python3; then
    python3 - "$addr" <<'PY'
import sys, ipaddress
try:
    ipaddress.ip_address(sys.argv[1])
    raise SystemExit(0)
except Exception:
    raise SystemExit(1)
PY
    return $?
  fi

  case "$addr" in
    *[!0-9a-fA-F:.]*|'') return 1 ;;
    *) return 0 ;;
  esac
}

prompt_listen_addr() {
  local addr
  while true; do
    addr="$(prompt_default "请输入监听地址" "0.0.0.0")"
    if is_valid_ip "$addr"; then
      printf '%s\n' "$addr"
      return 0
    fi
    echo "输入无效：监听地址必须是 IP，例如 0.0.0.0 或 ::"
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

restart_singbox_service() {
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable sing-box >/dev/null 2>&1 || true
  systemctl restart sing-box
}

save_reality_meta() {
  local connect_host="$1"
  local listen_port="$2"
  local server_name="$3"
  local public_key="$4"
  local short_id="$5"

  cat > "${META_FILE}" <<JSON
{
  "connect_host": "${connect_host}",
  "listen_port": ${listen_port},
  "server_name": "${server_name}",
  "public_key": "${public_key}",
  "short_id": "${short_id}",
  "flow": "xtls-rprx-vision",
  "type": "tcp",
  "security": "reality",
  "fingerprint": "${DEFAULT_CLIENT_FP}"
}
JSON

  chmod 600 "${META_FILE}" 2>/dev/null || true
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
  local connect_host tcp_fast_open config_tmp
  local default_host

  default_host="$(detect_connect_host)"
  [ -z "$default_host" ] && default_host="YOUR_SERVER_IP"

  listen_addr="$(prompt_listen_addr)"
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

  cat > "${config_tmp}" <<JSON
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
JSON

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
  
  save_reality_meta "${connect_host}" "${listen_port}" "${server_name}" "${public_key}" "${short_id}"

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

gen_password() {
  if has_cmd openssl; then
    openssl rand -hex 12
    return 0
  fi

  if has_cmd python3; then
    python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(18))
PY
    return 0
  fi

  echo "pass-$(date +%s)"
}

prompt_port_default() {
  local prompt="$1"
  local default_port="$2"
  local port

  while true; do
    port="$(prompt_default "${prompt}" "${default_port}")"
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

show_current_inbounds() {
  if [ ! -f "${CONFIG_DIR}/config.json" ]; then
    echo "未找到 ${CONFIG_DIR}/config.json"
    pause_enter
    return 1
  fi

  python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
inbounds = cfg.get("inbounds", [])

print("当前入站：")
print("编号 标签                 类型         监听地址")
print("----------------------------------------------------------------")

idx = 1
for ib in inbounds:
    tag = ib.get("tag", "")
    typ = ib.get("type", "")
    listen = ib.get("listen", "")
    port = ib.get("listen_port", "")
    endpoint = f"{listen}:{port}" if listen and port else f"{listen or '<空>'}:{port or '<空>'}"
    print(f"{idx:<4} {tag:<20} {typ:<12} {endpoint}")
    idx += 1

if idx == 1:
    print("<暂无入站>")

print("----------------------------------------------------------------")
PY

  pause_enter
}

save_hy2_meta() {
  local connect_host="$1"
  local listen_port="$2"
  local user_name="$3"
  local password="$4"
  local server_name="$5"
  local obfs_password="$6"
  local up_mbps="$7"
  local down_mbps="$8"

  cat > "${BASE_DIR}/hy2-meta.json" <<JSON
{
  "connect_host": "${connect_host}",
  "listen_port": ${listen_port},
  "user_name": "${user_name}",
  "password": "${password}",
  "server_name": "${server_name}",
  "obfs_password": "${obfs_password}",
  "up_mbps": ${up_mbps},
  "down_mbps": ${down_mbps}
}
JSON

  chmod 600 "${BASE_DIR}/hy2-meta.json" 2>/dev/null || true
}

deploy_hysteria2() {
  need_root

  if ! has_cmd sing-box; then
    err "未检测到 sing-box，请先安装内核"
    pause_enter
    return 1
  fi

  mkdir -p "${CONFIG_DIR}" "${BACKUP_DIR}" "${TMP_DIR}"

  local listen_addr listen_port user_name password
  local cert_path key_path connect_host server_name
  local up_mbps down_mbps obfs_password use_obfs
  local default_host tmp_file backend

  default_host="$(detect_connect_host)"
  [ -z "${default_host}" ] && default_host="YOUR_SERVER_IP_OR_DOMAIN"

  listen_addr="$(prompt_listen_addr)"
  listen_port="$(prompt_port_default "请输入 Hysteria2 监听端口" "8443")"
  user_name="$(prompt_default "请输入 Hysteria2 用户备注" "hy2-user1")"
  password="$(prompt_default "请输入 Hysteria2 密码" "$(gen_password)")"
  connect_host="$(prompt_default "请输入客户端连接地址" "${default_host}")"
  server_name="$(prompt_required "请输入客户端 server_name / SNI（证书域名）")"
  cert_path="$(prompt_required "请输入 TLS 证书路径 certificate_path")"
  key_path="$(prompt_required "请输入 TLS 私钥路径 key_path")"
  up_mbps="$(prompt_default "请输入上行带宽 up_mbps" "100")"
  down_mbps="$(prompt_default "请输入下行带宽 down_mbps" "100")"

  if [ ! -f "${cert_path}" ]; then
    err "证书文件不存在：${cert_path}"
    pause_enter
    return 1
  fi

  if [ ! -f "${key_path}" ]; then
    err "私钥文件不存在：${key_path}"
    pause_enter
    return 1
  fi

  if confirm_default_no "启用 salamander obfs 吗？"; then
    use_obfs="true"
    obfs_password="$(prompt_default "请输入 obfs 密码" "$(gen_password)")"
  else
    use_obfs="false"
    obfs_password=""
  fi

  echo
  echo "========== Hysteria2 配置预览 =========="
  echo "监听地址       : ${listen_addr}"
  echo "监听端口       : ${listen_port}/udp"
  echo "用户备注       : ${user_name}"
  echo "密码           : ${password}"
  echo "客户端连接地址 : ${connect_host}"
  echo "客户端 SNI     : ${server_name}"
  echo "证书路径       : ${cert_path}"
  echo "私钥路径       : ${key_path}"
  echo "up_mbps        : ${up_mbps}"
  echo "down_mbps      : ${down_mbps}"
  echo "obfs           : ${use_obfs}"
  if [ "${use_obfs}" = "true" ]; then
    echo "obfs_password  : ${obfs_password}"
  fi
  echo "========================================"
  echo

  if ! confirm_default_yes "确认写入并重启 sing-box 吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  tmp_file="${TMP_DIR}/config.hy2.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" \
    "${listen_addr}" "${listen_port}" "${user_name}" "${password}" \
    "${cert_path}" "${key_path}" "${up_mbps}" "${down_mbps}" \
    "${use_obfs}" "${obfs_password}" <<'PY'
import json, sys

(
    path, listen_addr, listen_port, user_name, password,
    cert_path, key_path, up_mbps, down_mbps,
    use_obfs, obfs_password
) = sys.argv[1:]

cfg = json.load(open(path, 'r', encoding='utf-8'))
inbounds = cfg.setdefault("inbounds", [])

hy2_obj = {
    "type": "hysteria2",
    "tag": "hy2-in",
    "listen": listen_addr,
    "listen_port": int(listen_port),
    "up_mbps": int(up_mbps),
    "down_mbps": int(down_mbps),
    "users": [
        {
            "name": user_name,
            "password": password
        }
    ],
    "tls": {
        "enabled": True,
        "certificate_path": cert_path,
        "key_path": key_path
    }
}

if use_obfs == "true":
    hy2_obj["obfs"] = {
        "type": "salamander",
        "password": obfs_password
    }

replaced = False
for i, ib in enumerate(inbounds):
    if ib.get("tag") == "hy2-in":
        inbounds[i] = hy2_obj
        replaced = True
        break

if not replaced:
    inbounds.append(hy2_obj)

with open(path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "写入 Hysteria2 入站失败"
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

  save_hy2_meta "${connect_host}" "${listen_port}" "${user_name}" "${password}" "${server_name}" "${obfs_password}" "${up_mbps}" "${down_mbps}"

  ok "Hysteria2 部署完成"
  echo
  echo "------ Hysteria2 客户端关键参数 ------"
  echo "地址        : ${connect_host}"
  echo "端口        : ${listen_port}"
  echo "用户名备注  : ${user_name}"
  echo "密码        : ${password}"
  echo "SNI         : ${server_name}"
  echo "协议        : hysteria2"
  echo "传输        : UDP / QUIC"
  echo "up/down     : ${up_mbps}/${down_mbps} Mbps"
  if [ "${use_obfs}" = "true" ]; then
    echo "obfs        : salamander"
    echo "obfs密码    : ${obfs_password}"
  fi
  echo "--------------------------------------"
  echo
  echo "注意：如果你用官方 Hysteria2 客户端，常见的 userpass 实际要填成 <用户名>:<密码> 的组合。"
  echo

  if declare -F detect_firewall_backend >/dev/null 2>&1 && declare -F fw_open_port >/dev/null 2>&1; then
    backend="$(detect_firewall_backend)"
    if [ "${backend}" != "none" ]; then
      if confirm_default_yes "是否一键放行 ${listen_port}/udp 到防火墙？"; then
        if fw_open_port "${backend}" "${listen_port}" "udp"; then
          ok "已放行 ${listen_port}/udp"
        else
          err "放行 ${listen_port}/udp 失败"
        fi
      fi
    fi
  fi

  pause_enter
}

menu_deploy_hysteria2() {
  deploy_hysteria2
}

menu_inbound_management() {
  while true; do
    clear
    echo "======================================"
    echo "              入站管理"
    echo "======================================"
    echo "1. 部署/重装 VLESS + Reality"
    echo "2. 部署/重装 Hysteria2"
    echo "3. 查看当前入站"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-3]: " choice
    case "${choice:-}" in
      1) menu_deploy_vless_reality ;;
      2) menu_deploy_hysteria2 ;;
      3) show_current_inbounds ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
