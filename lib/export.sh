#!/usr/bin/env bash

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

list_protocol_meta_files() {
  local protocol="$1"

  python3 - "${INBOUND_META_DIR}" "${protocol}" <<'PY'
import json, pathlib, sys

base = pathlib.Path(sys.argv[1])
protocol = sys.argv[2]

if not base.exists():
    raise SystemExit(0)

rows = []
for p in base.glob("*.json"):
    try:
        meta = json.loads(p.read_text(encoding='utf-8'))
    except Exception:
        continue
    if meta.get("protocol") == protocol:
        rows.append((p.stat().st_mtime, str(p)))

for _, path in sorted(rows, reverse=True):
    print(path)
PY
}

get_protocol_meta_by_index() {
  local protocol="$1"
  local idx="$2"
  list_protocol_meta_files "${protocol}" | sed -n "${idx}p"
}

show_protocol_meta_list() {
  local protocol="$1"
  local idx=1 found=0

  echo "编号 标签                     协议            端口"
  echo "--------------------------------------------------------"

  while IFS= read -r f; do
    [ -z "${f}" ] && continue
    found=1
    python3 - "$f" "$idx" <<'PY'
import json, sys
meta = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
idx = sys.argv[2]
print(f"{idx:<4} {meta.get('tag',''):<24} {meta.get('protocol',''):<14} {meta.get('listen_port','')}")
PY
    idx=$((idx + 1))
  done < <(list_protocol_meta_files "${protocol}")

  if [ "$found" -eq 0 ]; then
    echo "<暂无实例>"
  fi
  echo "--------------------------------------------------------"
}

select_protocol_meta_file() {
  local protocol="$1"
  local label="$2"
  local idx meta_file

  show_protocol_meta_list "${protocol}" >&2
  echo >&2
  idx="$(prompt_required "请输入要导出的 ${label} 编号")"
  meta_file="$(get_protocol_meta_by_index "${protocol}" "${idx}")"

  if [ -z "${meta_file}" ] || [ ! -f "${meta_file}" ]; then
    err "编号无效" >&2
    return 1
  fi

  printf '%s\n' "${meta_file}"
}

list_vless_user_rows_by_tag() {
  local reality_tag="$1"

  python3 - "${CONFIG_DIR}/config.json" "${reality_tag}" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
target_tag = sys.argv[2]

for ib in cfg.get("inbounds", []):
    if ib.get("type") == "vless" and ib.get("tag") == target_tag:
        for i, u in enumerate(ib.get("users", []), 1):
            print(f"{i}\t{u.get('name', '')}\t{u.get('uuid', '')}")
        break
PY
}

get_vless_user_by_index_and_tag() {
  local reality_tag="$1"
  local idx="$2"

  python3 - "${CONFIG_DIR}/config.json" "${reality_tag}" "${idx}" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
target_tag = sys.argv[2]
idx = int(sys.argv[3])

for ib in cfg.get("inbounds", []):
    if ib.get("type") == "vless" and ib.get("tag") == target_tag:
        users = ib.get("users", [])
        if idx < 1 or idx > len(users):
            print("索引越界", file=sys.stderr)
            raise SystemExit(1)
        u = users[idx - 1]
        print(f"{u.get('name', '')}|{u.get('uuid', '')}")
        raise SystemExit(0)

print("未找到指定 Reality 入站", file=sys.stderr)
raise SystemExit(1)
PY
}

show_vless_users_simple_by_tag() {
  local reality_tag="$1"
  local found=0

  while IFS=$'\t' read -r idx name uuid; do
    [ -z "${idx}" ] && continue
    found=1
    printf '%-4s %-18s %s\n' "$idx" "$name" "$uuid"
  done < <(list_vless_user_rows_by_tag "${reality_tag}")

  if [ "$found" -eq 0 ]; then
    echo "暂无用户"
  fi
}

build_reality_uri_from_meta() {
  local meta_file="$1"
  local user_name="$2"
  local user_uuid="$3"

  python3 - "${meta_file}" "${user_name}" "${user_uuid}" <<'PY'
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
    "security": "reality",
    "sni": meta["server_name"],
    "fp": meta.get("fingerprint", "chrome"),
    "pbk": meta["public_key"],
    "sid": meta["short_id"],
    "type": "tcp"
}

query = urllib.parse.urlencode(params)
fragment = urllib.parse.quote(name, safe="")
print(f"vless://{uuid}@{host}:{port}?{query}#{fragment}")
PY
}

export_single_user_uri() {
  require_config_file || return 1
  require_python3 || return 1

  local meta_file reality_tag idx user_line user_name user_uuid uri

  meta_file="$(select_protocol_meta_file "vless-reality" "Reality")" || {
    pause_enter
    return 1
  }

  reality_tag="$(python3 - "${meta_file}" <<'PY'
import json, sys
meta = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
print(meta.get("tag", ""))
PY
)"

  echo
  echo "当前 Reality 实例：${reality_tag}"
  echo "当前用户列表："
  show_vless_users_simple_by_tag "${reality_tag}"
  echo

  idx="$(prompt_default "请输入要导出的用户编号" "1")"
  user_line="$(get_vless_user_by_index_and_tag "${reality_tag}" "${idx}")" || {
    err "读取用户失败"
    pause_enter
    return 1
  }

  user_name="${user_line%%|*}"
  user_uuid="${user_line##*|}"

  uri="$(build_reality_uri_from_meta "${meta_file}" "${user_name}" "${user_uuid}")" || {
    err "生成 Reality URI 失败"
    pause_enter
    return 1
  }

  echo
  echo "------ ${user_name} 的 Reality 链接 ------"
  echo "${uri}"
  echo "-----------------------------------------"
  echo

  pause_enter
}

export_all_user_uris() {
  require_config_file || return 1
  require_python3 || return 1

  local meta_file reality_tag found=0

  meta_file="$(select_protocol_meta_file "vless-reality" "Reality")" || {
    pause_enter
    return 1
  }

  reality_tag="$(python3 - "${meta_file}" <<'PY'
import json, sys
meta = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
print(meta.get("tag", ""))
PY
)"

  while IFS=$'\t' read -r idx name uuid; do
    [ -z "${idx}" ] && continue
    found=1
    echo "[$idx] ${name}"
    build_reality_uri_from_meta "${meta_file}" "${name}" "${uuid}"
    echo
  done < <(list_vless_user_rows_by_tag "${reality_tag}")

  if [ "$found" -eq 0 ]; then
    echo "暂无用户"
  fi

  pause_enter
}

build_hy2_uri() {
  local meta_file="$1"

  python3 - "${meta_file}" <<'PY'
import json, sys, urllib.parse

meta = json.load(open(sys.argv[1], 'r', encoding='utf-8'))

host = str(meta["connect_host"])
port = int(meta["listen_port"])
password = str(meta["password"])
sni = str(meta["server_name"])
obfs_password = str(meta.get("obfs_password", "") or "")
cert_mode = str(meta.get("cert_mode", "1"))
tag = str(meta.get("user_name", meta.get("tag", "hy2")))

if ":" in host and not host.startswith("["):
    host = f"[{host}]"

auth = urllib.parse.quote(password, safe="")
params = {"sni": sni}

if obfs_password:
    params["obfs"] = "salamander"
    params["obfs-password"] = obfs_password

if cert_mode == "2":
    params["insecure"] = "1"

query = urllib.parse.urlencode(params)
print(f"hysteria2://{auth}@{host}:{port}/?{query}#{urllib.parse.quote(tag)}")
PY
}

build_hy2_singbox_json() {
  local meta_file="$1"

  python3 - "${meta_file}" <<'PY'
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
  local meta_file uri

  meta_file="$(select_protocol_meta_file "hysteria2" "Hysteria2")" || {
    pause_enter
    return 1
  }

  uri="$(build_hy2_uri "${meta_file}")" || {
    err "生成 Hysteria2 URI 失败"
    pause_enter
    return 1
  }

  echo
  echo "------ Hysteria2 URI ------"
  echo "${uri}"
  echo "---------------------------"
  echo
  pause_enter
}

export_hy2_singbox_json() {
  local meta_file

  meta_file="$(select_protocol_meta_file "hysteria2" "Hysteria2")" || {
    pause_enter
    return 1
  }

  echo
  echo "------ Hysteria2 sing-box 客户端 JSON ------"
  build_hy2_singbox_json "${meta_file}" || {
    err "生成 Hysteria2 客户端 JSON 失败"
    pause_enter
    return 1
  }
  echo
  echo "-------------------------------------------"
  echo

  pause_enter
}

show_vmess_meta_list() {
  local idx=1 found=0
  echo "编号 标签                     传输      端口"
  echo "--------------------------------------------------------"

  while IFS= read -r f; do
    [ -z "${f}" ] && continue
    found=1
    python3 - "$f" "$idx" <<'PY'
import json, sys
meta = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
idx = sys.argv[2]
print(f"{idx:<4} {meta.get('tag',''):<24} {meta.get('transport_type',''):<8} {meta.get('listen_port','')}")
PY
    idx=$((idx + 1))
  done < <(list_protocol_meta_files "vmess")

  if [ "$found" -eq 0 ]; then
    echo "<暂无 VMess 实例>"
  fi
  echo "--------------------------------------------------------"
}

build_vmess_uri() {
  local meta_file="$1"

  python3 - "${meta_file}" <<'PY'
import base64, json, sys

meta = json.load(open(sys.argv[1], 'r', encoding='utf-8'))

transport_type = str(meta.get("transport_type", "ws"))
tls_enabled = str(meta.get("tls_enabled", "false"))
server_name = str(meta.get("server_name", "") or "")
host = str(meta.get("host", "") or "")
path = str(meta.get("path", "/") or "/")

obj = {
    "v": "2",
    "ps": str(meta.get("user_name", meta.get("tag", "vmess"))),
    "add": str(meta["connect_host"]),
    "port": str(meta["listen_port"]),
    "id": str(meta["uuid"]),
    "aid": "0",
    "scy": "auto",
    "net": transport_type,
    "type": "none",
    "host": host,
    "path": path,
    "tls": "tls" if tls_enabled == "true" else "",
    "sni": server_name if tls_enabled == "true" else ""
}

raw = json.dumps(obj, ensure_ascii=False, separators=(',', ':')).encode()
print("vmess://" + base64.b64encode(raw).decode())
PY
}

build_vmess_singbox_json() {
  local meta_file="$1"

  python3 - "${meta_file}" <<'PY'
import json, sys

meta = json.load(open(sys.argv[1], 'r', encoding='utf-8'))

transport_type = str(meta.get("transport_type", "ws"))
tls_enabled = str(meta.get("tls_enabled", "false"))
server_name = str(meta.get("server_name", "") or "")
host = str(meta.get("host", "") or "")
path = str(meta.get("path", "/") or "/")
method = str(meta.get("method", "GET") or "GET")
cert_mode = str(meta.get("cert_mode", "0"))

outbound = {
    "type": "vmess",
    "tag": "vmess-out",
    "server": str(meta["connect_host"]),
    "server_port": int(meta["listen_port"]),
    "uuid": str(meta["uuid"]),
    "security": "auto",
    "alter_id": 0
}

if transport_type == "http":
    transport = {
        "type": "http",
        "path": path,
        "method": method
    }
    if host:
        transport["host"] = [host]
else:
    transport = {
        "type": "ws",
        "path": path
    }
    if host:
        transport["headers"] = {"Host": host}

outbound["transport"] = transport

if tls_enabled == "true":
    tls = {
        "enabled": True,
        "server_name": server_name
    }
    if cert_mode == "2":
        tls["insecure"] = True
    outbound["tls"] = tls

print(json.dumps({"outbounds": [outbound]}, ensure_ascii=False, indent=2))
PY
}

export_vmess_uri() {
  local meta_file idx uri

  show_vmess_meta_list
  echo
  idx="$(prompt_required "请输入要导出的 VMess 编号")"
  meta_file="$(get_protocol_meta_by_index "vmess" "${idx}")"

  if [ -z "${meta_file}" ] || [ ! -f "${meta_file}" ]; then
    err "编号无效"
    pause_enter
    return 1
  fi

  uri="$(build_vmess_uri "${meta_file}")" || {
    err "生成 VMess URI 失败"
    pause_enter
    return 1
  }

  echo
  echo "------ VMess URI ------"
  echo "${uri}"
  echo "-----------------------"
  echo
  pause_enter
}

export_vmess_singbox_json() {
  local meta_file idx

  show_vmess_meta_list
  echo
  idx="$(prompt_required "请输入要导出的 VMess 编号")"
  meta_file="$(get_protocol_meta_by_index "vmess" "${idx}")"

  if [ -z "${meta_file}" ] || [ ! -f "${meta_file}" ]; then
    err "编号无效"
    pause_enter
    return 1
  fi

  echo
  echo "------ VMess sing-box 客户端 JSON ------"
  build_vmess_singbox_json "${meta_file}" || {
    err "生成 VMess 客户端 JSON 失败"
    pause_enter
    return 1
  }
  echo
  echo "----------------------------------------"
  echo

  pause_enter
}

build_tuic_uri() {
  local meta_file="$1"

  python3 - "${meta_file}" <<'PY'
import json, sys
from urllib.parse import quote, urlencode

meta = json.load(open(sys.argv[1], 'r', encoding='utf-8'))

host = str(meta["connect_host"])
port = int(meta["listen_port"])
uuid = str(meta["uuid"])
password = str(meta["password"])
sni = str(meta["server_name"])
congestion_control = str(meta.get("congestion_control", "cubic") or "cubic")
cert_mode = str(meta.get("cert_mode", "1"))
tag = str(meta.get("user_name", meta.get("tag", "tuic")))

if ":" in host and not host.startswith("["):
    host = f"[{host}]"

params = {
    "sni": sni,
    "congestion_control": congestion_control,
    "udp_relay_mode": "native"
}

if cert_mode == "2":
    params["allow_insecure"] = "1"

userinfo = f"{quote(uuid, safe='')}:{quote(password, safe='')}"
name = quote(tag, safe='')
query = urlencode(params)
print(f"tuic://{userinfo}@{host}:{port}?{query}#{name}")
PY
}

build_tuic_singbox_json() {
  local meta_file="$1"

  python3 - "${meta_file}" <<'PY'
import json, sys

meta = json.load(open(sys.argv[1], 'r', encoding='utf-8'))

cert_mode = str(meta.get("cert_mode", "1"))
zero_rtt = str(meta.get("zero_rtt_handshake", "false")).lower() == "true"

outbound = {
    "type": "tuic",
    "tag": "tuic-out",
    "server": str(meta["connect_host"]),
    "server_port": int(meta["listen_port"]),
    "uuid": str(meta["uuid"]),
    "password": str(meta["password"]),
    "congestion_control": str(meta.get("congestion_control", "cubic") or "cubic"),
    "udp_relay_mode": "native",
    "zero_rtt_handshake": zero_rtt,
    "heartbeat": str(meta.get("heartbeat", "10s") or "10s"),
    "tls": {
        "enabled": True,
        "server_name": str(meta["server_name"])
    }
}

if cert_mode == "2":
    outbound["tls"]["insecure"] = True

print(json.dumps({"outbounds": [outbound]}, ensure_ascii=False, indent=2))
PY
}

export_tuic_uri() {
  local meta_file uri

  meta_file="$(select_protocol_meta_file "tuic" "TUIC")" || {
    pause_enter
    return 1
  }

  uri="$(build_tuic_uri "${meta_file}")" || {
    err "生成 TUIC URI 失败"
    pause_enter
    return 1
  }

  echo
  echo "------ TUIC URI ------"
  echo "${uri}"
  echo "----------------------"
  echo
  pause_enter
}

export_tuic_singbox_json() {
  local meta_file

  meta_file="$(select_protocol_meta_file "tuic" "TUIC")" || {
    pause_enter
    return 1
  }

  echo
  echo "------ TUIC sing-box 客户端 JSON ------"
  build_tuic_singbox_json "${meta_file}" || {
    err "生成 TUIC 客户端 JSON 失败"
    pause_enter
    return 1
  }
  echo
  echo "---------------------------------------"
  echo

  pause_enter
}

show_uri_and_qr() {
  local title="$1"
  local uri="$2"

  [ -z "${uri}" ] && return 0

  echo
  echo "------ ${title} ------"
  echo "${uri}"
  echo "----------------------"

  if has_cmd qrencode; then
    echo
    echo "二维码："
    qrencode -t ANSIUTF8 "${uri}" || true
  else
    echo
    echo "提示：未检测到 qrencode，仅显示 URI。"
    echo "Debian/Ubuntu 可安装：apt-get install -y qrencode"
  fi

  echo
}

menu_export_client() {
  while true; do
    clear
    echo "======================================"
    echo "            导出客户端配置"
    echo "======================================"
    echo "1. 导出单个用户 Reality URI"
    echo "2. 导出指定 Reality 实例全部用户 URI"
    echo "3. 导出 Hysteria2 URI"
    echo "4. 导出 Hysteria2 sing-box JSON"
    echo "5. 导出 VMess URI"
    echo "6. 导出 VMess sing-box JSON"
    echo "7. 导出 TUIC URI"
    echo "8. 导出 TUIC sing-box JSON"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-8]: " choice
    case "${choice:-}" in
      1) export_single_user_uri ;;
      2) export_all_user_uris ;;
      3) export_hy2_uri ;;
      4) export_hy2_singbox_json ;;
      5) export_vmess_uri ;;
      6) export_vmess_singbox_json ;;
      7) export_tuic_uri ;;
      8) export_tuic_singbox_json ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
