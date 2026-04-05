#!/usr/bin/env bash

require_outbound_manage_env() {
  require_python3 || return 1
  require_config_file || return 1
  mkdir -p "${TMP_DIR}" "${SOURCES_DIR}" "${NODE_CACHE_DIR}"
}

list_source_meta_files() {
  ls -1t "${SOURCES_DIR}"/source-*.json 2>/dev/null || true
}

get_source_meta_path_by_index() {
  local idx="$1"
  list_source_meta_files | sed -n "${idx}p"
}

default_next_source_name() {
  python3 - "${SOURCES_DIR}" <<'PY'
import glob, os, sys
files = glob.glob(os.path.join(sys.argv[1], "source-*.json"))
print(f"source{len(files) + 1}")
PY
}

next_source_id() {
  python3 - "${SOURCES_DIR}" <<'PY'
import glob, os, re, sys
nums = []
for path in glob.glob(os.path.join(sys.argv[1], "source-*.json")):
    m = re.search(r"source-(\d+)\.json$", os.path.basename(path))
    if m:
        nums.append(int(m.group(1)))
n = 1
while n in nums:
    n += 1
print(f"source-{n:03d}")
PY
}

read_source_meta_fields() {
  local meta_path="$1"
  python3 - "${meta_path}" <<'PY'
import json, sys
meta = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
print(meta.get("id", ""))
print(meta.get("name", ""))
print(meta.get("type", ""))
print(meta.get("location", ""))
print(meta.get("enabled", True))
print(meta.get("node_count", 0))
print(meta.get("last_update", ""))
PY
}

create_source_meta_file() {
  local meta_path="$1"
  local source_id="$2"
  local source_name="$3"
  local source_type="$4"
  local location="$5"

  python3 - "${meta_path}" "${source_id}" "${source_name}" "${source_type}" "${location}" <<'PY'
import json, sys
path, source_id, name, source_type, location = sys.argv[1:]
meta = {
    "id": source_id,
    "name": name,
    "type": source_type,
    "location": location,
    "enabled": True,
    "node_count": 0,
    "last_update": "",
}
with open(path, 'w', encoding='utf-8') as f:
    json.dump(meta, f, ensure_ascii=False, indent=2)
PY
}

update_source_meta_success() {
  local meta_path="$1"
  local node_count="$2"

  python3 - "${meta_path}" "${node_count}" "$(date -Iseconds)" <<'PY'
import json, sys
path, node_count, last_update = sys.argv[1], int(sys.argv[2]), sys.argv[3]
meta = json.load(open(path, 'r', encoding='utf-8'))
meta["node_count"] = node_count
meta["last_update"] = last_update
with open(path, 'w', encoding='utf-8') as f:
    json.dump(meta, f, ensure_ascii=False, indent=2)
PY
}

normalize_source_raw_to_cache() {
  local raw_file="$1"
  local cache_file="$2"

  python3 - "${raw_file}" "${cache_file}" <<'PY'
import json, sys

raw_path, cache_path = sys.argv[1], sys.argv[2]

SUPPORTED = {
    "socks",
    "http",
    "shadowsocks",
    "vmess",
    "trojan",
    "wireguard",
    "hysteria",
    "vless",
    "shadowtls",
    "tuic",
    "hysteria2",
    "anytls",
    "tor",
    "ssh",
    "naive",
}

data = json.load(open(raw_path, 'r', encoding='utf-8'))

if isinstance(data, dict):
    if isinstance(data.get("outbounds"), list):
        items = data["outbounds"]
    elif "type" in data:
        items = [data]
    else:
        print("输入内容不是可识别的 sing-box 配置/节点格式", file=sys.stderr)
        raise SystemExit(1)
elif isinstance(data, list):
    items = data
else:
    print("输入内容不是 JSON 对象或数组", file=sys.stderr)
    raise SystemExit(1)

result = []
for item in items:
    if not isinstance(item, dict):
        continue
    typ = item.get("type", "")
    if typ not in SUPPORTED:
        continue
    result.append(item)

with open(cache_path, 'w', encoding='utf-8') as f:
    json.dump(result, f, ensure_ascii=False, indent=2)

print(len(result))
PY
}

update_source_from_meta_path() {
  require_outbound_manage_env || return 1

  local meta_path="$1"
  local raw_file source_id source_name source_type location
  local cache_file count
  raw_file="${TMP_DIR}/source-raw.json"

  mapfile -t _src_meta < <(read_source_meta_fields "${meta_path}")
  source_id="${_src_meta[0]:-}"
  source_name="${_src_meta[1]:-}"
  source_type="${_src_meta[2]:-}"
  location="${_src_meta[3]:-}"

  if [ -z "${source_id}" ] || [ -z "${source_type}" ] || [ -z "${location}" ]; then
    err "节点源元数据无效：${meta_path}"
    return 1
  fi

  case "${source_type}" in
    url)
      if ! fetch_to_file "${location}" "${raw_file}"; then
        err "下载订阅失败：${location}"
        return 1
      fi
      ;;
    file)
      if [ ! -f "${location}" ]; then
        err "本地文件不存在：${location}"
        return 1
      fi
      cp -f "${location}" "${raw_file}"
      ;;
    *)
      err "未知节点源类型：${source_type}"
      return 1
      ;;
  esac

  cache_file="${NODE_CACHE_DIR}/${source_id}.outbounds.json"

  if ! count="$(normalize_source_raw_to_cache "${raw_file}" "${cache_file}")"; then
    err "解析 sing-box 节点失败：${source_name}"
    return 1
  fi

  update_source_meta_success "${meta_path}" "${count}" || return 1
  ok "节点源更新成功：${source_name}（${count} 个节点）"
  return 0
}

show_outbound_sources() {
  require_outbound_manage_env || return 1

  local idx=1 found=0
  echo "编号 ID           名称             类型   节点数  最后更新"
  echo "--------------------------------------------------------------------------"

  while IFS= read -r meta_path; do
    [ -z "${meta_path}" ] && continue
    found=1
    mapfile -t _src_meta < <(read_source_meta_fields "${meta_path}")
    printf '%-4s %-12s %-16s %-6s %-7s %s\n' \
      "$idx" \
      "${_src_meta[0]:-}" \
      "${_src_meta[1]:-}" \
      "${_src_meta[2]:-}" \
      "${_src_meta[5]:-0}" \
      "${_src_meta[6]:-<未更新>}"
    idx=$((idx + 1))
  done < <(list_source_meta_files)

  if [ "$found" -eq 0 ]; then
    echo "暂无节点源"
  fi

  echo "--------------------------------------------------------------------------"
  echo
  echo "详细位置："

  idx=1
  while IFS= read -r meta_path; do
    [ -z "${meta_path}" ] && continue
    mapfile -t _src_meta < <(read_source_meta_fields "${meta_path}")
    echo "[$idx] ${_src_meta[1]:-} -> ${_src_meta[3]:-}"
    idx=$((idx + 1))
  done < <(list_source_meta_files)
}

add_subscription_url_source() {
  require_outbound_manage_env || return 1

  local source_name url source_id meta_path
  source_name="$(prompt_default "请输入节点源名称" "$(default_next_source_name)")"
  url="$(prompt_required "请输入 sing-box 订阅 URL")"
  source_id="$(next_source_id)"
  meta_path="${SOURCES_DIR}/${source_id}.json"

  create_source_meta_file "${meta_path}" "${source_id}" "${source_name}" "url" "${url}" || {
    err "创建节点源失败"
    pause_enter
    return 1
  }

  echo
  echo "已新增 URL 节点源：${source_name}"
  if confirm_default_yes "现在立即更新并解析该节点源吗？"; then
    update_source_from_meta_path "${meta_path}" || {
      pause_enter
      return 1
    }
  fi

  pause_enter
}

import_local_singbox_file_source() {
  require_outbound_manage_env || return 1

  local source_name file_path source_id meta_path
  source_name="$(prompt_default "请输入节点源名称" "$(default_next_source_name)")"
  file_path="$(prompt_required "请输入本地 sing-box 文件路径")"

  if [ ! -f "${file_path}" ]; then
    err "文件不存在：${file_path}"
    pause_enter
    return 1
  fi

  source_id="$(next_source_id)"
  meta_path="${SOURCES_DIR}/${source_id}.json"

  create_source_meta_file "${meta_path}" "${source_id}" "${source_name}" "file" "${file_path}" || {
    err "创建节点源失败"
    pause_enter
    return 1
  }

  echo
  echo "已新增本地文件节点源：${source_name}"
  if confirm_default_yes "现在立即更新并解析该节点源吗？"; then
    update_source_from_meta_path "${meta_path}" || {
      pause_enter
      return 1
    }
  fi

  pause_enter
}

update_one_source() {
  require_outbound_manage_env || return 1

  show_outbound_sources
  echo

  local idx meta_path
  idx="$(prompt_required "请输入要更新的节点源编号")"
  meta_path="$(get_source_meta_path_by_index "${idx}")"

  if [ -z "${meta_path}" ] || [ ! -f "${meta_path}" ]; then
    err "节点源编号无效"
    pause_enter
    return 1
  fi

  update_source_from_meta_path "${meta_path}" || {
    pause_enter
    return 1
  }

  pause_enter
}

update_all_sources() {
  require_outbound_manage_env || return 1

  local total=0 ok_count=0
  while IFS= read -r meta_path; do
    [ -z "${meta_path}" ] && continue
    total=$((total + 1))
    if update_source_from_meta_path "${meta_path}"; then
      ok_count=$((ok_count + 1))
    fi
  done < <(list_source_meta_files)

  echo
  echo "更新完成：${ok_count}/${total}"
  pause_enter
}

preview_source_nodes() {
  require_outbound_manage_env || return 1

  show_outbound_sources
  echo

  local idx meta_path source_id source_name cache_file
  idx="$(prompt_required "请输入要预览的节点源编号")"
  meta_path="$(get_source_meta_path_by_index "${idx}")"

  if [ -z "${meta_path}" ] || [ ! -f "${meta_path}" ]; then
    err "节点源编号无效"
    pause_enter
    return 1
  fi

  mapfile -t _src_meta < <(read_source_meta_fields "${meta_path}")
  source_id="${_src_meta[0]:-}"
  source_name="${_src_meta[1]:-}"
  cache_file="${NODE_CACHE_DIR}/${source_id}.outbounds.json"

  if [ ! -f "${cache_file}" ]; then
    err "尚未找到缓存节点，请先更新该节点源"
    pause_enter
    return 1
  fi

  echo "节点源：${source_name}"
  echo "缓存文件：${cache_file}"
  echo

  python3 - "${cache_file}" <<'PY'
import json, sys

items = json.load(open(sys.argv[1], 'r', encoding='utf-8'))

print("编号 类型         标签                  服务器")
print("----------------------------------------------------------------")

for i, ob in enumerate(items, 1):
    typ = ob.get("type", "")
    tag = ob.get("tag", "")
    server = ob.get("server", "") or ob.get("server_name", "") or ob.get("address", "") or ob.get("endpoint", "")
    port = ob.get("server_port", "") or ob.get("port", "")
    if server and port:
        endpoint = f"{server}:{port}"
    else:
        endpoint = server or "<未知>"
    print(f"{i:<4} {typ:<12} {tag[:20]:<22} {endpoint}")
print("----------------------------------------------------------------")
print(f"共 {len(items)} 个可导入节点")
PY

  pause_enter
}

collect_all_source_cache_files() {
  require_outbound_manage_env || return 1

  while IFS= read -r meta_path; do
    [ -z "${meta_path}" ] && continue
    mapfile -t _src_meta < <(read_source_meta_fields "${meta_path}")
    local source_id="${_src_meta[0]:-}"
    local cache_file="${NODE_CACHE_DIR}/${source_id}.outbounds.json"
    [ -f "${cache_file}" ] && printf '%s\n' "${cache_file}"
  done < <(list_source_meta_files)
}

update_all_sources_silent() {
  require_outbound_manage_env || return 1

  local total=0 ok_count=0
  while IFS= read -r meta_path; do
    [ -z "${meta_path}" ] && continue
    total=$((total + 1))
    if update_source_from_meta_path "${meta_path}"; then
      ok_count=$((ok_count + 1))
    fi
  done < <(list_source_meta_files)

  [ "${total}" -gt 0 ] || return 0
  [ "${ok_count}" -eq "${total}" ]
}

apply_cache_files_to_runtime_file() {
  local target_config="$1"
  shift

  python3 - "${target_config}" "$@" <<'PY'
import copy, json, re, sys

config_path = sys.argv[1]
cache_files = sys.argv[2:]

cfg = json.load(open(config_path, 'r', encoding='utf-8'))
outbounds = cfg.setdefault("outbounds", [])

REMOTE_TYPES = {
    "socks",
    "http",
    "shadowsocks",
    "vmess",
    "trojan",
    "wireguard",
    "hysteria",
    "vless",
    "shadowtls",
    "tuic",
    "hysteria2",
    "anytls",
    "tor",
    "ssh",
    "naive",
}

def is_generated_group(ob):
    typ = ob.get("type", "")
    return typ in ("selector", "urltest")

preserved = []
has_direct = False

for ob in outbounds:
    tag = ob.get("tag", "")
    typ = ob.get("type", "")

    if tag == "direct":
        has_direct = True

    if is_generated_group(ob):
        continue

    if typ in REMOTE_TYPES:
        continue

    preserved.append(ob)

if not has_direct:
    preserved.insert(0, {"type": "direct", "tag": "direct"})

RESERVED_TAGS = {"direct", "block", "proxy", "auto", "dns-out"}

def make_unique_tag(preferred, used_tags, fallback_index):
    tag = (preferred or "").strip()

    if not tag:
        tag = f"node-{fallback_index:03d}"

    if tag in RESERVED_TAGS:
        tag = f"{tag}-node"

    if tag not in used_tags:
        used_tags.add(tag)
        return tag

    base = tag
    n = 2
    while True:
        candidate = f"{base}-{n}"
        if candidate not in used_tags and candidate not in RESERVED_TAGS:
            used_tags.add(candidate)
            return candidate
        n += 1

used_tags = set()
for ob in preserved:
    tag = ob.get("tag", "")
    if tag:
        used_tags.add(tag)

imported = []
counter = 1

for cache_path in cache_files:
    items = json.load(open(cache_path, 'r', encoding='utf-8'))
    if not isinstance(items, list):
        continue

    for item in items:
        if not isinstance(item, dict):
            continue

        typ = item.get("type", "")
        if typ not in REMOTE_TYPES:
            continue

        new_item = copy.deepcopy(item)
        original_tag = str(new_item.get("tag", "")).strip()
        new_item["tag"] = make_unique_tag(original_tag, used_tags, counter)

        imported.append(new_item)
        counter += 1

node_tags = [ob["tag"] for ob in imported]

new_outbounds = preserved + imported

if node_tags:
    new_outbounds.append({
        "type": "urltest",
        "tag": "自动选择",
        "outbounds": node_tags,
        "interrupt_exist_connections": False
    })

    selector_members = ["direct", "自动选择"] + node_tags
    selector_default = "自动选择"
else:
    selector_members = ["direct"]
    selector_default = "direct"

new_outbounds.append({
    "type": "selector",
    "tag": "手动切换",
    "outbounds": selector_members,
    "default": selector_default,
    "interrupt_exist_connections": False
})

cfg["outbounds"] = new_outbounds
cfg.setdefault("route", {})["final"] = "手动切换"

with open(config_path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
}

apply_cache_files_to_runtime() {
  require_outbound_manage_env || return 1
  need_root

  local tmp_file
  tmp_file="${TMP_DIR}/config.apply-nodes.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! apply_cache_files_to_runtime_file "${tmp_file}" "$@"; then
    err "应用节点到策略组失败"
    pause_enter
    return 1
  fi

  if ! check_config_file "${tmp_file}"; then
    err "配置校验失败，未写入正式配置"
    pause_enter
    return 1
  fi

  activate_config_file "${tmp_file}"

  if ! restart_singbox_service; then
    err "服务重启失败"
    pause_enter
    return 1
  fi

  ok "节点已应用到当前策略组"
  pause_enter
}

apply_one_source_to_runtime() {
  require_outbound_manage_env || return 1

  show_outbound_sources
  echo

  local idx meta_path source_id cache_file
  idx="$(prompt_required "请输入要应用的节点源编号")"
  meta_path="$(get_source_meta_path_by_index "${idx}")"

  if [ -z "${meta_path}" ] || [ ! -f "${meta_path}" ]; then
    err "节点源编号无效"
    pause_enter
    return 1
  fi

  mapfile -t _src_meta < <(read_source_meta_fields "${meta_path}")
  source_id="${_src_meta[0]:-}"
  cache_file="${NODE_CACHE_DIR}/${source_id}.outbounds.json"

  if [ ! -f "${cache_file}" ]; then
    err "尚未找到缓存节点，请先更新该节点源"
    pause_enter
    return 1
  fi

  echo "准备将节点源 [${_src_meta[1]:-}] 应用到当前策略组"
  if ! confirm_default_yes "确认继续吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  apply_cache_files_to_runtime "${cache_file}"
}

apply_all_sources_to_runtime() {
  require_outbound_manage_env || return 1

  local cache_files=()
  while IFS= read -r meta_path; do
    [ -z "${meta_path}" ] && continue
    mapfile -t _src_meta < <(read_source_meta_fields "${meta_path}")
    local source_id="${_src_meta[0]:-}"
    local cache_file="${NODE_CACHE_DIR}/${source_id}.outbounds.json"
    [ -f "${cache_file}" ] && cache_files+=("${cache_file}")
  done < <(list_source_meta_files)

  if [ "${#cache_files[@]}" -eq 0 ]; then
    err "未找到可应用的节点缓存，请先更新节点源"
    pause_enter
    return 1
  fi

  echo "准备将全部节点源应用到当前策略组"
  if ! confirm_default_yes "确认继续吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  apply_cache_files_to_runtime "${cache_files[@]}"
}

show_current_applied_nodes() {
  require_outbound_manage_env || return 1

  python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
outbounds = cfg.get("outbounds", [])

REMOTE_TYPES = {
    "socks",
    "http",
    "shadowsocks",
    "vmess",
    "trojan",
    "wireguard",
    "hysteria",
    "vless",
    "shadowtls",
    "tuic",
    "hysteria2",
    "anytls",
    "tor",
    "ssh",
    "naive",
}

print("当前已应用节点：")
print("编号 标签         类型         服务器")
print("----------------------------------------------------------------")

idx = 1
for ob in outbounds:
    tag = ob.get("tag", "")
    typ = ob.get("type", "")

    if typ not in REMOTE_TYPES:
        continue
    if tag in ("direct", "block", "proxy", "auto", "dns-out"):
        continue

    server = ob.get("server", "") or ob.get("server_name", "") or ob.get("address", "") or ob.get("endpoint", "")
    port = ob.get("server_port", "") or ob.get("port", "")
    endpoint = f"{server}:{port}" if server and port else (server or "<未知>")
    print(f"{idx:<4} {tag:<12} {typ:<12} {endpoint}")
    idx += 1

if idx == 1:
    print("<暂无已应用节点>")

print("----------------------------------------------------------------")

selector = None
urltest = None
for ob in outbounds:
    if ob.get("tag") == "手动切换" and ob.get("type") == "selector":
        selector = ob
    if ob.get("tag") == "自动选择" and ob.get("type") == "urltest":
        urltest = ob

route_final = cfg.get("route", {}).get("final", "")
print(f"route.final : {route_final or '<空>'}")
if selector:
    print(f"手动切换    : {', '.join(selector.get('outbounds', []))}")
    print(f"默认节点     : {selector.get('default', '')}")
else:
    print("selector    : <未找到>")
if urltest:
    print(f"自动选择     : {', '.join(urltest.get('outbounds', []))}")
else:
    print("urltest     : <未找到>")
PY

  pause_enter
}

get_clash_api_runtime() {
  require_outbound_manage_env || return 1

  python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
clash = cfg.get("experimental", {}).get("clash_api", {})

controller = clash.get("external_controller", "")
secret = clash.get("secret", "")

print(controller)
print(secret)
PY
}
urlencode_text() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=''))
PY
}

clash_api_request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"

  local controller secret
  mapfile -t _clash_runtime < <(get_clash_api_runtime)
  controller="${_clash_runtime[0]:-}"
  secret="${_clash_runtime[1]:-}"

  if [ -z "${controller}" ]; then
    err "Clash API 未启用，请先到 Clash API 管理里开启"
    return 1
  fi

  local url="http://${controller}${path}"

  if has_cmd curl; then
    if [ -n "${secret}" ]; then
      if [ -n "${body}" ]; then
        curl -fsSL -X "${method}" \
          -H "Authorization: Bearer ${secret}" \
          -H "Content-Type: application/json" \
          -d "${body}" \
          "${url}"
      else
        curl -fsSL -X "${method}" \
          -H "Authorization: Bearer ${secret}" \
          "${url}"
      fi
    else
      if [ -n "${body}" ]; then
        curl -fsSL -X "${method}" \
          -H "Content-Type: application/json" \
          -d "${body}" \
          "${url}"
      else
        curl -fsSL -X "${method}" "${url}"
      fi
    fi
    return $?
  fi

  if has_cmd wget; then
    err "当前未实现 wget 版 Clash API 请求，请安装 curl"
    return 1
  fi

  err "未找到 curl"
  return 1
}

show_selector_candidates() {
  require_outbound_manage_env || return 1

  python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
selector = None

for ob in cfg.get("outbounds", []):
    if ob.get("tag") == "手动切换" and ob.get("type") == "selector":
        selector = ob
        break

if not selector:
    print("未找到 手动切换 selector")
    raise SystemExit(1)

members = selector.get("outbounds", [])
print("可切换节点：")
print("编号 标签")
print("------------------------------")
for i, tag in enumerate(members, 1):
    print(f"{i:<4} {tag}")
print("------------------------------")
PY
}

get_selector_member_by_index() {
  local idx="$1"
  python3 - "${CONFIG_DIR}/config.json" "$idx" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
idx = int(sys.argv[2])

selector = None
for ob in cfg.get("outbounds", []):
    if ob.get("tag") == "手动切换" and ob.get("type") == "selector":
        selector = ob
        break

if not selector:
    print("未找到 手动切换 selector", file=sys.stderr)
    raise SystemExit(1)

members = selector.get("outbounds", [])
if idx < 1 or idx > len(members):
    print("编号超出范围", file=sys.stderr)
    raise SystemExit(1)

print(members[idx - 1])
PY
}

show_current_proxy_selection() {
  require_outbound_manage_env || return 1

  local selector_name selector_path resp
  selector_name="手动切换"
  selector_path="/proxies/$(urlencode_text "${selector_name}")"

  if ! resp="$(clash_api_request "GET" "${selector_path}")"; then
    err "读取当前 手动切换 组状态失败"
    pause_enter
    return 1
  fi

  RESP_JSON="${resp}" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["RESP_JSON"])
print("当前手动切换组状态：")
print(f"name   : {data.get('name', '<空>')}")
print(f"type   : {data.get('type', '<空>')}")
print(f"now    : {data.get('now', '<空>')}")
all_items = data.get('all', [])
if all_items:
    print("all    : " + ", ".join(str(x) for x in all_items))
PY

  echo
  pause_enter
}

switch_proxy_selector() {
  require_outbound_manage_env || return 1

  show_selector_candidates
  echo

  local idx target body selector_name selector_path
  idx="$(prompt_required "请输入要切换到的节点编号")"
  target="$(get_selector_member_by_index "${idx}")" || {
    err "读取节点失败"
    pause_enter
    return 1
  }

  echo "准备切换 手动切换 组到：${target}"
  if ! confirm_default_yes "确认继续吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  body="$(python3 - "${target}" <<'PY'
import json, sys
print(json.dumps({"name": sys.argv[1]}, ensure_ascii=False))
PY
)"

  selector_name="手动切换"
  selector_path="/proxies/$(urlencode_text "${selector_name}")"

  if ! clash_api_request "PUT" "${selector_path}" "${body}" >/dev/null; then
    err "切换 手动切换 组失败"
    pause_enter
    return 1
  fi

  ok "已切换到：${target}"
  echo
  show_current_proxy_selection
}

OUTBOUND_PROXY_STATE_FILE="${BASE_DIR}/outbound-proxy-state.json"

save_outbound_proxy_state() {
  local src_file="$1"
  local state_file="${2:-${OUTBOUND_PROXY_STATE_FILE}}"

  python3 - "${src_file}" "${state_file}" <<'PY'
import json, sys

cfg_path, state_path = sys.argv[1], sys.argv[2]
cfg = json.load(open(cfg_path, 'r', encoding='utf-8'))

route = cfg.get("route", {})
selectors = {}

for ob in cfg.get("outbounds", []):
    if ob.get("type") == "selector":
        tag = str(ob.get("tag", "") or "")
        if tag:
            selectors[tag] = {
                "default": ob.get("default", ""),
                "outbounds": ob.get("outbounds", [])
            }

state = {
    "route_final": route.get("final", ""),
    "selectors": selectors
}

with open(state_path, 'w', encoding='utf-8') as f:
    json.dump(state, f, ensure_ascii=False, indent=2)
PY
}

disable_outbound_proxy() {
  need_root

  if ! require_config_file; then
    pause_enter
    return 1
  fi

  local tmp_file
  tmp_file="${TMP_DIR}/config.disable-outbound.json"
  mkdir -p "${TMP_DIR}"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! save_outbound_proxy_state "${CONFIG_DIR}/config.json" "${OUTBOUND_PROXY_STATE_FILE}"; then
    err "保存当前出站状态失败"
    pause_enter
    return 1
  fi

  if ! python3 - "${tmp_file}" <<'PY'
import json, sys

path = sys.argv[1]
cfg = json.load(open(path, 'r', encoding='utf-8'))

route = cfg.setdefault("route", {})
route["final"] = "direct"

for ob in cfg.get("outbounds", []):
    if ob.get("type") == "selector":
        outs = ob.get("outbounds", [])
        if "direct" in outs:
            ob["default"] = "direct"

with open(path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "关闭出站代理失败"
    pause_enter
    return 1
  fi

  if ! check_config_file "${tmp_file}"; then
    err "配置校验失败，未覆盖正式配置"
    pause_enter
    return 1
  fi

  echo "将执行以下操作："
  echo "1. 保存当前出站状态"
  echo "2. route.final 改为 direct"
  echo "3. 所有 selector 默认值尽量切到 direct"
  echo
  if ! confirm_default_yes "确认关闭出站代理吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  activate_config_file "${tmp_file}"

  if ! restart_singbox_service; then
    err "服务重启失败，可执行 journalctl -u sing-box -n 100 --no-pager 查看日志"
    pause_enter
    return 1
  fi

  ok "已关闭出站代理，当前默认直连"
  pause_enter
}

restore_outbound_proxy() {
  need_root

  if ! require_config_file; then
    pause_enter
    return 1
  fi

  if [ ! -f "${OUTBOUND_PROXY_STATE_FILE}" ]; then
    err "未找到可恢复的出站状态记录：${OUTBOUND_PROXY_STATE_FILE}"
    pause_enter
    return 1
  fi

  local tmp_file
  tmp_file="${TMP_DIR}/config.restore-outbound.json"
  mkdir -p "${TMP_DIR}"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "${OUTBOUND_PROXY_STATE_FILE}" <<'PY'
import json, sys

cfg_path, state_path = sys.argv[1], sys.argv[2]
cfg = json.load(open(cfg_path, 'r', encoding='utf-8'))
state = json.load(open(state_path, 'r', encoding='utf-8'))

route = cfg.setdefault("route", {})
route["final"] = state.get("route_final", route.get("final", "direct"))

selector_state = state.get("selectors", {})

for ob in cfg.get("outbounds", []):
    if ob.get("type") != "selector":
        continue
    tag = str(ob.get("tag", "") or "")
    if tag not in selector_state:
        continue

    saved = selector_state[tag]
    saved_default = saved.get("default", "")
    current_outbounds = ob.get("outbounds", [])

    if saved_default and saved_default in current_outbounds:
        ob["default"] = saved_default

with open(cfg_path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "恢复出站代理失败"
    pause_enter
    return 1
  fi

  if ! check_config_file "${tmp_file}"; then
    err "配置校验失败，未覆盖正式配置"
    pause_enter
    return 1
  fi

  echo "将恢复："
  echo "1. route.final"
  echo "2. 各 selector 之前保存的默认值"
  echo
  if ! confirm_default_yes "确认恢复上次出站状态吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  activate_config_file "${tmp_file}"

  if ! restart_singbox_service; then
    err "服务重启失败，可执行 journalctl -u sing-box -n 100 --no-pager 查看日志"
    pause_enter
    return 1
  fi

  ok "已恢复上次出站状态"
  pause_enter
}

list_selector_groups() {
  python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
rows = []

for ob in cfg.get("outbounds", []):
    if ob.get("type") != "selector":
        continue

    tag = str(ob.get("tag", "") or "")
    if not tag:
        continue

    if tag in ("proxy", "direct", "block", "dns-out"):
        continue

    default = str(ob.get("default", "") or "")
    outs = ob.get("outbounds", []) or []
    rows.append((tag, default, len(outs)))

for i, (tag, default, count) in enumerate(rows, 1):
    print(f"{i}\t{tag}\t{default}\t{count}")
PY
}

get_selector_tag_by_index() {
  local idx="$1"
  python3 - "${CONFIG_DIR}/config.json" "${idx}" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
idx = int(sys.argv[2])

rows = []
for ob in cfg.get("outbounds", []):
    if ob.get("type") != "selector":
        continue
    tag = str(ob.get("tag", "") or "")
    if not tag or tag in ("proxy", "direct", "block", "dns-out"):
        continue
    rows.append(tag)

if idx < 1 or idx > len(rows):
    raise SystemExit(1)

print(rows[idx - 1])
PY
}

show_selector_groups() {
  echo "编号 策略组                   当前默认               候选数"
  echo "--------------------------------------------------------------"
  local found=0
  while IFS=$'\t' read -r idx tag default count; do
    [ -z "${idx}" ] && continue
    found=1
    printf '%-4s %-24s %-20s %s\n' "${idx}" "${tag}" "${default:-<空>}" "${count}"
  done < <(list_selector_groups)

  if [ "${found}" -eq 0 ]; then
    echo "<暂无可切换策略组>"
  fi
  echo "--------------------------------------------------------------"
}

list_selector_candidates_by_tag() {
  local tag="$1"
  python3 - "${CONFIG_DIR}/config.json" "${tag}" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
tag = sys.argv[2]

for ob in cfg.get("outbounds", []):
    if ob.get("type") == "selector" and str(ob.get("tag", "") or "") == tag:
        current = str(ob.get("default", "") or "")
        for i, item in enumerate(ob.get("outbounds", []) or [], 1):
            marker = "*" if item == current else " "
            print(f"{i}\t{item}\t{marker}")
        raise SystemExit(0)

raise SystemExit(1)
PY
}

get_selector_candidate_by_index() {
  local tag="$1"
  local idx="$2"
  python3 - "${CONFIG_DIR}/config.json" "${tag}" "${idx}" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
tag = sys.argv[2]
idx = int(sys.argv[3])

for ob in cfg.get("outbounds", []):
    if ob.get("type") == "selector" and str(ob.get("tag", "") or "") == tag:
        outs = ob.get("outbounds", []) or []
        if idx < 1 or idx > len(outs):
            raise SystemExit(1)
        print(outs[idx - 1])
        raise SystemExit(0)

raise SystemExit(1)
PY
}

show_selector_candidates_for_group() {
  require_config_file || {
    pause_enter
    return 1
  }

  clear
  echo "======================================"
  echo "           查看策略组可选节点"
  echo "======================================"
  show_selector_groups
  echo

  local idx tag
  idx="$(prompt_required "请输入要查看的策略组编号")"
  tag="$(get_selector_tag_by_index "${idx}")" || {
    err "编号无效"
    pause_enter
    return 1
  }

  echo
  echo "策略组：${tag}"
  echo "--------------------------------------------------------------"
  while IFS=$'\t' read -r n item marker; do
    [ -z "${n}" ] && continue
    if [ "${marker}" = "*" ]; then
      printf '%-4s %-32s %s\n' "${n}" "${item}" "<当前>"
    else
      printf '%-4s %s\n' "${n}" "${item}"
    fi
  done < <(list_selector_candidates_by_tag "${tag}")
  echo "--------------------------------------------------------------"

  pause_enter
}

switch_selector_group() {
  need_root
  require_config_file || {
    pause_enter
    return 1
  }

  clear
  echo "======================================"
  echo "             切换指定策略组"
  echo "======================================"
  show_selector_groups
  echo

  local idx tag candidate_idx candidate tmp_file
  idx="$(prompt_required "请输入要切换的策略组编号")"
  tag="$(get_selector_tag_by_index "${idx}")" || {
    err "编号无效"
    pause_enter
    return 1
  }

  echo
  echo "策略组：${tag}"
  echo "--------------------------------------------------------------"
  while IFS=$'\t' read -r n item marker; do
    [ -z "${n}" ] && continue
    if [ "${marker}" = "*" ]; then
      printf '%-4s %-32s %s\n' "${n}" "${item}" "<当前>"
    else
      printf '%-4s %s\n' "${n}" "${item}"
    fi
  done < <(list_selector_candidates_by_tag "${tag}")
  echo "--------------------------------------------------------------"

  candidate_idx="$(prompt_required "请输入要切换到的节点编号")"
  candidate="$(get_selector_candidate_by_index "${tag}" "${candidate_idx}")" || {
    err "节点编号无效"
    pause_enter
    return 1
  }

  tmp_file="${TMP_DIR}/config.switch-selector.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "${tag}" "${candidate}" <<'PY'
import json, sys

cfg_path, tag, candidate = sys.argv[1:]
cfg = json.load(open(cfg_path, 'r', encoding='utf-8'))

for ob in cfg.get("outbounds", []):
    if ob.get("type") == "selector" and str(ob.get("tag", "") or "") == tag:
        outs = ob.get("outbounds", []) or []
        if candidate not in outs:
            raise SystemExit(1)
        ob["default"] = candidate
        break
else:
    raise SystemExit(1)

with open(cfg_path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "切换策略组失败"
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

  ok "已切换：${tag} -> ${candidate}"
  pause_enter
}

menu_outbound_source_management() {
  while true; do
    clear
    echo "======================================"
    echo "             节点源管理"
    echo "======================================"
    echo "1. 添加订阅 URL 源"
    echo "2. 导入本地 sing-box 文件"
    echo "3. 查看节点源"
    echo "4. 更新指定节点源"
    echo "5. 更新全部节点源"
    echo "6. 预览导入节点"
    echo "7. 应用指定节点源到当前策略组"
    echo "8. 应用全部节点源到当前策略组"
    echo "9. 删除节点源"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-9]: " choice
    case "${choice:-}" in
      1) add_subscription_url_source ;;
      2) import_local_singbox_file_source ;;
      3) show_outbound_sources; pause_enter ;;
      4) update_one_source ;;
      5) update_all_sources ;;
      6) preview_source_nodes ;;
      7) apply_one_source_to_runtime ;;
      8) apply_all_sources_to_runtime ;;
      9) delete_source ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

menu_outbound_proxy_switch() {
  while true; do
    clear
    echo "======================================"
    echo "            出站代理开关"
    echo "======================================"
    echo "1. 关闭出站代理（默认直连）"
    echo "2. 恢复上次出站状态"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-2]: " choice
    case "${choice:-}" in
      1) disable_outbound_proxy ;;
      2) restore_outbound_proxy ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

menu_route_policy_management() {
  while true; do
    clear
    echo "======================================"
    echo "              路由策略"
    echo "======================================"
    echo "1. 查看当前策略状态"
    echo "2. 切换指定策略组"
    echo "3. 查看指定策略组可选节点"
    echo "4. 快速切换手动切换组"
    echo "5. 应用预设模板"
    echo "6. 应用策略文件"
    echo "7. 查看策略文件"
    echo "8. 重建策略组"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-8]: " choice
    case "${choice:-}" in
      1) show_template_status ;;
      2) switch_selector_group ;;
      3) show_selector_candidates_for_group ;;
      4) switch_proxy_selector ;;
      5) menu_route_template_shortcuts ;;
      6) apply_policy_groups_file ;;
      7) show_policy_groups_file ;;
      8) rebuild_proxy_selector_now ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

menu_route_template_shortcuts() {
  while true; do
    clear
    echo "======================================"
    echo "              预设模板"
    echo "======================================"
    echo "1. 最小模板"
    echo "2. 常用模板"
    echo "3. 全局代理模板"
    echo "4. 直连优先模板"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-4]: " choice
    case "${choice:-}" in
      1) apply_template_minimal ;;
      2) apply_template_common ;;
      3) apply_template_global ;;
      4) apply_template_direct_first ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

print_outbound_status_line() {
  local l1="$1" v1="$2" l2="$3" v2="$4"
  printf "%-10s %-14s %-10s %s\n" "${l1}" "${v1}" "${l2}" "${v2}"
}

get_outbound_status_info() {
  python3 - "${CONFIG_DIR}/config.json" "${SOURCES_DIR}" "${NODE_CACHE_DIR}" <<'PY'
import glob
import ipaddress
import json
import os
import sys

config_path, sources_dir, node_cache_dir = sys.argv[1], sys.argv[2], sys.argv[3]

REMOTE_TYPES = {
    "socks", "http", "shadowsocks", "vmess", "trojan", "wireguard", "hysteria",
    "vless", "shadowtls", "tuic", "hysteria2", "anytls", "tor", "ssh", "naive"
}

def safe_load_json(path, default):
    try:
        with open(path, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return default

cfg = safe_load_json(config_path, {})
outbounds = cfg.get("outbounds", [])
route = cfg.get("route", {})
rules = route.get("rules", [])
final = str(route.get("final", "") or "")

# ---------- 面板状态 ----------
panel_status = "未启用"
clash = cfg.get("experimental", {}).get("clash_api", {}) if isinstance(cfg, dict) else {}
controller = str(clash.get("external_controller", "") or "")
if controller:
    host = controller
    if controller.startswith("[") and "]:" in controller:
        host = controller.rsplit(":", 1)[0]
    elif ":" in controller:
        host = controller.rsplit(":", 1)[0]

    host = host.strip("[]")

    if host in ("127.0.0.1", "localhost", "::1"):
        panel_status = "本机"
    elif host in ("0.0.0.0", "::"):
        panel_status = "公网"
    else:
        try:
            ip = ipaddress.ip_address(host)
            panel_status = "局域网" if ip.is_private else "自定义"
        except Exception:
            panel_status = "自定义"

# ---------- 节点源 ----------
source_meta_files = sorted(glob.glob(os.path.join(sources_dir, "source-*.json")))
source_total = len(source_meta_files)
source_ready = 0

for meta_path in source_meta_files:
    meta = safe_load_json(meta_path, {})
    source_id = str(meta.get("id", "") or "")
    if not source_id:
        continue
    cache_file = os.path.join(node_cache_dir, f"{source_id}.outbounds.json")
    if os.path.isfile(cache_file):
        source_ready += 1

source_summary = f"{source_ready}/{source_total}"

# ---------- 缓存节点 ----------
cache_nodes = 0
for cache_path in glob.glob(os.path.join(node_cache_dir, "*.outbounds.json")):
    data = safe_load_json(cache_path, [])
    if isinstance(data, list):
        cache_nodes += sum(1 for x in data if isinstance(x, dict))

# ---------- 已应用节点 ----------
applied_nodes = 0
for ob in outbounds:
    typ = str(ob.get("type", "") or "")
    tag = str(ob.get("tag", "") or "")
    if typ in REMOTE_TYPES and tag not in ("direct", "block", "dns-out"):
        applied_nodes += 1

# ---------- 当前模板 ----------
def normalize_rules(rules):
    result = []
    for r in rules:
        item = {}
        if r.get("ip_is_private") is True:
            item["ip_is_private"] = True
        if "domain_suffix" in r:
            item["domain_suffix"] = sorted(r.get("domain_suffix", []))
        if "ip_cidr" in r:
            item["ip_cidr"] = sorted(r.get("ip_cidr", []))
        if "rule_set" in r:
            rs = r.get("rule_set", [])
            if isinstance(rs, list):
                item["rule_set"] = sorted(rs)
            else:
                item["rule_set"] = [rs]
        item["action"] = r.get("action", "")
        item["outbound"] = r.get("outbound", "")
        result.append(item)
    return result

local_rule = {
    "domain_suffix": sorted(["lan", "local", "home.arpa", "localhost"]),
    "action": "route",
    "outbound": "direct"
}

private_rule = {
    "ip_is_private": True,
    "action": "route",
    "outbound": "direct"
}

nr = normalize_rules(rules)
template_name = "自定义"

has_rule_set_cfg = bool(route.get("rule_set"))
has_rule_set_rule = any("rule_set" in r for r in rules)
has_ip_cidr_rule = any("ip_cidr" in r for r in rules)
has_custom_group_rule = any(
    str(r.get("outbound", "") or "") not in ("", "direct", "proxy", "手动切换")
    for r in rules
)

if nr == [private_rule] and final == "proxy":
    template_name = "最小模板"
elif nr == [private_rule, local_rule] and final == "proxy":
    template_name = "常用模板"
elif nr == [] and final == "proxy":
    template_name = "全局代理"
elif nr == [private_rule, local_rule] and final == "direct":
    template_name = "直连优先"
elif final == "手动切换" and (has_rule_set_cfg or has_rule_set_rule or has_ip_cidr_rule or has_custom_group_rule):
    template_name = "策略文件"

# ---------- 出站代理 ----------
if final == "direct":
    outbound_status = "未开启"
elif applied_nodes > 0:
    outbound_status = "已开启"
elif final:
    outbound_status = "异常"
else:
    outbound_status = "未开启"

# ---------- 中国流量 ----------
cn_flow = "未配置"
for ob in outbounds:
    if ob.get("type") == "selector" and str(ob.get("tag", "") or "") in ("🏠 中国流量", "中国流量"):
        cn_flow = str(ob.get("default", "") or "<空>")
        break

print(panel_status)
print(source_summary)
print(str(cache_nodes))
print(str(applied_nodes))
print(template_name)
print(final or "<空>")
print(outbound_status)
print(cn_flow)
PY
}

outbound_value_color() {
  local key="$1"
  local value="$2"

  case "${key}" in
    panel)
      case "${value}" in
        未启用) printf "%s" "${C_YELLOW}" ;;
        本机|局域网|公网|自定义) printf "%s" "${C_BGREEN}" ;;
        *) printf "%s" "${C_BCYAN}" ;;
      esac
      ;;
    source)
      case "${value}" in
        0/0) printf "%s" "${C_YELLOW}" ;;
        */*)
          local left="${value%/*}"
          local right="${value#*/}"
          if [ "${right}" = "0" ]; then
            printf "%s" "${C_YELLOW}"
          elif [ "${left}" = "${right}" ]; then
            printf "%s" "${C_BGREEN}"
          else
            printf "%s" "${C_BYELLOW}"
          fi
          ;;
        *)
          printf "%s" "${C_BCYAN}"
          ;;
      esac
      ;;
    cache|applied)
      case "${value}" in
        0|""|"<空>") printf "%s" "${C_YELLOW}" ;;
        *) printf "%s" "${C_BGREEN}" ;;
      esac
      ;;
    template)
      case "${value}" in
        策略文件|策略文件模板) printf "%s" "${C_BGREEN}" ;;
        最小模板|常用模板|全局代理|全局代理模板|直连优先) printf "%s" "${C_BCYAN}" ;;
        自定义|未知|自定义/未知) printf "%s" "${C_BYELLOW}" ;;
        *) printf "%s" "${C_BCYAN}" ;;
      esac
      ;;
    final)
      case "${value}" in
        direct) printf "%s" "${C_YELLOW}" ;;
        手动切换|proxy) printf "%s" "${C_BGREEN}" ;;
        "<空>"|"") printf "%s" "${C_YELLOW}" ;;
        *) printf "%s" "${C_BCYAN}" ;;
      esac
      ;;
    outbound)
      case "${value}" in
        已开启) printf "%s" "${C_BGREEN}" ;;
        未开启) printf "%s" "${C_YELLOW}" ;;
        异常) printf "%s" "${C_BRED}" ;;
        *) printf "%s" "${C_BCYAN}" ;;
      esac
      ;;
    cnflow)
      case "${value}" in
        direct) printf "%s" "${C_BGREEN}" ;;
        未配置|"<空>"|"") printf "%s" "${C_YELLOW}" ;;
        *) printf "%s" "${C_BCYAN}" ;;
      esac
      ;;
    *)
      printf "%s" "${C_RESET}"
      ;;
  esac
}

print_outbound_status_line() {
  local l1="$1" v1="$2" k1="$3"
  local l2="$4" v2="$5" k2="$6"
  local c1 c2

  # 获取动态颜色
  c1="$(outbound_value_color "${k1}" "${v1}")"
  c2="$(outbound_value_color "${k2}" "${v2}")"

  # 使用 \033[26G 进行绝对定位对齐
  echo -e " ${C_BCYAN}${l1}${C_RESET} ${c1}${v1}${C_RESET}\033[26G${C_BCYAN}${l2}${C_RESET} ${c2}${v2}${C_RESET}"
}

show_outbound_status_header() {
  local panel_status="未启用"
  local source_summary="0/0"
  local cache_nodes="0"
  local applied_nodes="0"
  local template_name="自定义"
  local final_outbound="<空>"
  local outbound_status="未开启"
  local cn_flow="未配置"

  if [ -f "${CONFIG_DIR}/config.json" ] && has_cmd python3; then
    mapfile -t _outbound_info < <(get_outbound_status_info)
    panel_status="${_outbound_info[0]:-未启用}"
    source_summary="${_outbound_info[1]:-0/0}"
    cache_nodes="${_outbound_info[2]:-0}"
    applied_nodes="${_outbound_info[3]:-0}"
    template_name="${_outbound_info[4]:-自定义}"
    final_outbound="${_outbound_info[5]:-<空>}"
    outbound_status="${_outbound_info[6]:-未开启}"
    cn_flow="${_outbound_info[7]:-未配置}"
  fi

  echo "$(paint "${C_BMAGENTA}${C_BOLD}" "======================================")"
  echo "$(paint "${C_BMAGENTA}${C_BOLD}" "              出站管理")"
  echo "$(paint "${C_BMAGENTA}${C_BOLD}" "======================================")"
  
  # 调用新版函数，颜色和对齐兼得
  print_outbound_status_line "面板状态 :" "${panel_status}"   "panel"    "节点源   :" "${source_summary}" "source"
  print_outbound_status_line "缓存节点 :" "${cache_nodes}"    "cache"    "已应用   :" "${applied_nodes}" "applied"
  print_outbound_status_line "当前模板 :" "${template_name}"  "template" "默认出口 :" "${final_outbound}" "final"
  print_outbound_status_line "出站代理 :" "${outbound_status}" "outbound" "中国流量 :" "${cn_flow}" "cnflow"
  
  echo "$(paint "${C_BMAGENTA}${C_BOLD}" "======================================")"
}

menu_outbound_management() {
  while true; do
    clear
    show_outbound_status_header
    echo "1. 节点管理"
    echo "2. 路由策略"
    echo "3. 面板管理"
    echo "4. 出站开关"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-4]: " choice
    case "${choice:-}" in
      1) menu_outbound_source_management ;;
      2) menu_route_policy_management ;;
      3) menu_clash_api_management ;;
      4) menu_outbound_proxy_switch ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
