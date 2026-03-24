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

apply_cache_files_to_runtime() {
  require_outbound_manage_env || return 1
  need_root

  local tmp_file
  tmp_file="${TMP_DIR}/config.apply-nodes.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "$@" <<'PY'
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

def is_generated_node(ob):
    tag = ob.get("tag", "")
    return re.fullmatch(r"node-\d+", tag or "") is not None

def is_generated_group(ob):
    tag = ob.get("tag", "")
    typ = ob.get("type", "")
    return (tag == "auto" and typ == "urltest") or (tag == "proxy" and typ == "selector")

preserved = []
existing_remote_tags = []

has_direct = False
for ob in outbounds:
    tag = ob.get("tag", "")
    typ = ob.get("type", "")

    if tag == "direct":
        has_direct = True

    if is_generated_node(ob) or is_generated_group(ob):
        continue

    preserved.append(ob)

    if typ in REMOTE_TYPES and tag:
        existing_remote_tags.append(tag)

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
all_candidate_tags = []
for tag in existing_remote_tags + node_tags:
    if tag not in all_candidate_tags:
        all_candidate_tags.append(tag)

new_outbounds = preserved + imported

if all_candidate_tags:
    new_outbounds.append({
        "type": "urltest",
        "tag": "自动选择",
        "outbounds": all_candidate_tags,
        "interrupt_exist_connections": False
    })

    selector_members = ["direct", "自动选择"] + all_candidate_tags
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

print(len(imported))
print(len(all_candidate_tags))
PY
  then
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
    print("未找到 proxy selector")
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
    print("未找到 proxy selector", file=sys.stderr)
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

delete_source() {
  require_outbound_manage_env || return 1

  show_outbound_sources
  echo

  local idx meta_path source_id cache_file
  idx="$(prompt_required "请输入要删除的节点源编号")"
  meta_path="$(get_source_meta_path_by_index "${idx}")"

  if [ -z "${meta_path}" ] || [ ! -f "${meta_path}" ]; then
    err "节点源编号无效"
    pause_enter
    return 1
  fi

  mapfile -t _src_meta < <(read_source_meta_fields "${meta_path}")
  source_id="${_src_meta[0]:-}"
  cache_file="${NODE_CACHE_DIR}/${source_id}.outbounds.json"

  echo "准备删除节点源：${_src_meta[1]:-}"
  if ! confirm_default_no "确认继续吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  rm -f "${meta_path}" "${cache_file}"
  ok "节点源已删除"
  pause_enter
}

menu_outbound_management() {
  while true; do
    clear
    echo "======================================"
    echo "              出站管理"
    echo "======================================"
    echo "1. 添加订阅 URL 源"
    echo "2. 导入本地 sing-box 文件"
    echo "3. 查看节点源"
    echo "4. 更新指定节点源"
    echo "5. 更新全部节点源"
    echo "6. 预览导入节点"
    echo "7. 应用指定节点源到当前策略组"
    echo "8. 应用全部节点源到当前策略组"
    echo "9. 查看当前已应用节点"
    echo "10. 查看当前手动切换组选择"
    echo "11. 切换手动切换组到指定节点"
    echo "12. 查看手动切换组可选节点"
    echo "13. 删除节点源"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-13]: " choice
    case "${choice:-}" in
      1) add_subscription_url_source ;;
      2) import_local_singbox_file_source ;;
      3) show_outbound_sources; pause_enter ;;
      4) update_one_source ;;
      5) update_all_sources ;;
      6) preview_source_nodes ;;
      7) apply_one_source_to_runtime ;;
      8) apply_all_sources_to_runtime ;;
      9) show_current_applied_nodes ;;
      10) show_current_proxy_selection ;;
      11) switch_proxy_selector ;;
      12) show_selector_candidates; pause_enter ;;
      13) delete_source ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
