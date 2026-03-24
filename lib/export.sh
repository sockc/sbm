#!/usr/bin/env bash

require_config_file() {
  if [ ! -f "${CONFIG_DIR}/config.json" ]; then
    err "未找到 ${CONFIG_DIR}/config.json，请先部署 VLESS + Reality"
    return 1
  fi
}

require_meta_file() {
  if [ ! -f "${META_FILE}" ]; then
    err "未找到 ${META_FILE}，请先重新执行一次 VLESS + Reality 部署"
    return 1
  fi
}

require_python3() {
  if ! has_cmd python3; then
    err "缺少 python3，无法处理 JSON"
    return 1
  fi
}

list_vless_user_rows() {
  python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))

for ib in cfg.get("inbounds", []):
    if ib.get("type") == "vless" and ib.get("tag") == "vless-reality-in":
        for i, u in enumerate(ib.get("users", []), 1):
            print(f"{i}\t{u.get('name', '')}\t{u.get('uuid', '')}")
        break
PY
}

get_vless_user_by_index() {
  local idx="$1"
  python3 - "${CONFIG_DIR}/config.json" "$idx" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
idx = int(sys.argv[2])

for ib in cfg.get("inbounds", []):
    if ib.get("type") == "vless" and ib.get("tag") == "vless-reality-in":
        users = ib.get("users", [])
        if idx < 1 or idx > len(users):
            print("索引越界", file=sys.stderr)
            raise SystemExit(1)
        u = users[idx - 1]
        print(f"{u.get('name', '')}|{u.get('uuid', '')}")
        raise SystemExit(0)

print("未找到 vless-reality-in 入站", file=sys.stderr)
raise SystemExit(1)
PY
}

build_vless_uri() {
  local user_name="$1"
  local user_uuid="$2"

  python3 - "${META_FILE}" "$user_name" "$user_uuid" <<'PY'
import json, sys, urllib.parse

meta = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
name = sys.argv[2]
uuid = sys.argv[3]

host = str(meta["connect_host"])
port = int(meta["listen_port"])

if ":" in host and not host.startswith("["):
    host = f"[{host}]"

params = {
    "encryption": "none",
    "flow": meta.get("flow", "xtls-rprx-vision"),
    "security": meta.get("security", "reality"),
    "sni": meta["server_name"],
    "fp": meta.get("fingerprint", "chrome"),
    "pbk": meta["public_key"],
    "sid": meta["short_id"],
    "type": meta.get("type", "tcp"),
}

query = urllib.parse.urlencode(params)
fragment = urllib.parse.quote(name, safe="")
print(f"vless://{uuid}@{host}:{port}?{query}#{fragment}")
PY
}

show_vless_users_simple() {
  local found=0
  while IFS=$'\t' read -r idx name uuid; do
    [ -z "${idx}" ] && continue
    found=1
    printf '%-4s %-16s %s\n' "$idx" "$name" "$uuid"
  done < <(list_vless_user_rows)

  if [ "$found" -eq 0 ]; then
    echo "暂无用户"
  fi
}

export_single_user_uri() {
  require_config_file || return 1
  require_meta_file || return 1
  require_python3 || return 1

  echo "当前用户列表："
  show_vless_users_simple
  echo

  local idx user_line user_name user_uuid uri
  idx="$(prompt_default "请输入要导出的用户编号" "1")"

  user_line="$(get_vless_user_by_index "$idx")" || {
    err "读取用户失败"
    pause_enter
    return 1
  }

  user_name="${user_line%%|*}"
  user_uuid="${user_line##*|}"

  uri="$(build_vless_uri "$user_name" "$user_uuid")"

  echo
  echo "------ ${user_name} 的 VLESS Reality 链接 ------"
  echo "$uri"
  echo "----------------------------------------------"
  echo

  pause_enter
}

export_all_user_uris() {
  require_config_file || return 1
  require_meta_file || return 1
  require_python3 || return 1

  local found=0
  while IFS=$'\t' read -r idx name uuid; do
    [ -z "${idx}" ] && continue
    found=1
    echo "[$idx] ${name}"
    build_vless_uri "$name" "$uuid"
    echo
  done < <(list_vless_user_rows)

  if [ "$found" -eq 0 ]; then
    echo "暂无用户"
  fi

  pause_enter
}

require_hy2_meta_file() {
  local hy2_meta="${BASE_DIR}/hy2-meta.json"
  if [ ! -f "${hy2_meta}" ]; then
    err "未找到 ${hy2_meta}，请先部署 Hysteria2"
    return 1
  fi
}

build_hy2_uri() {
  local hy2_meta="${BASE_DIR}/hy2-meta.json"

  python3 - "${hy2_meta}" <<'PY'
import json, sys, urllib.parse

meta = json.load(open(sys.argv[1], 'r', encoding='utf-8'))

host = str(meta["connect_host"])
port = int(meta["listen_port"])
password = str(meta["password"])
sni = str(meta["server_name"])
obfs_password = str(meta.get("obfs_password", "") or "")
cert_mode = str(meta.get("cert_mode", "1"))

if ":" in host and not host.startswith("["):
    host = f"[{host}]"

auth = urllib.parse.quote(password, safe="")
params = {"sni": sni}

if obfs_password:
    params["obfs"] = "salamander"
    params["obfs-password"] = obfs_password

# 自签证书为了方便导入，默认给 URI 加 insecure=1
if cert_mode == "2":
    params["insecure"] = "1"

query = urllib.parse.urlencode(params)
print(f"hysteria2://{auth}@{host}:{port}/?{query}")
PY
}

build_hy2_singbox_json() {
  local hy2_meta="${BASE_DIR}/hy2-meta.json"

  python3 - "${hy2_meta}" <<'PY'
import json, sys

meta = json.load(open(sys.argv[1], 'r', encoding='utf-8'))

host = meta["connect_host"]
port = int(meta["listen_port"])
password = meta["password"]
sni = meta["server_name"]
obfs_password = meta.get("obfs_password", "") or ""
cert_mode = str(meta.get("cert_mode", "1"))

out = {
    "outbounds": [
        {
            "type": "hysteria2",
            "tag": "hy2-out",
            "server": host,
            "server_port": port,
            "password": password,
            "tls": {
                "enabled": True,
                "server_name": sni
            }
        }
    ]
}

if cert_mode == "2":
    out["outbounds"][0]["tls"]["insecure"] = True

if obfs_password:
    out["outbounds"][0]["obfs"] = {
        "type": "salamander",
        "password": obfs_password
    }

print(json.dumps(out, ensure_ascii=False, indent=2))
PY
}

export_hy2_uri() {
  require_hy2_meta_file || { pause_enter; return 1; }

  local uri
  uri="$(build_hy2_uri)" || {
    err "生成 Hysteria2 URI 失败"
    pause_enter
    return 1
  }

  echo
  echo "------ Hysteria2 URI ------"
  echo "${uri}"
  echo "---------------------------"
  echo
  echo "说明：如果你用的是自签证书，这里已默认附带 insecure=1，便于直接导入。"
  echo

  pause_enter
}

export_hy2_singbox_json() {
  require_hy2_meta_file || { pause_enter; return 1; }

  echo
  echo "------ Hysteria2 sing-box 客户端 JSON ------"
  build_hy2_singbox_json || {
    err "生成 Hysteria2 客户端 JSON 失败"
    pause_enter
    return 1
  }
  echo
  echo "-------------------------------------------"
  echo

  pause_enter
}

menu_export_client() {
  while true; do
    clear
    echo "======================================"
    echo "          导出客户端配置"
    echo "======================================"
    echo "1. 导出单个用户 VLESS URI"
    echo "2. 导出全部用户 VLESS URI"
    echo "3. 导出 Hysteria2 URI"
    echo "4. 导出 Hysteria2 sing-box JSON"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-4]: " choice
    case "${choice:-}" in
      1) export_single_user_uri ;;
      2) export_all_user_uris ;;
      3) export_hy2_uri ;;
      4) export_hy2_singbox_json ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
