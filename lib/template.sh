#!/usr/bin/env bash

require_template_env() {
  require_config_file || return 1
  require_python3 || return 1
  mkdir -p "${TMP_DIR}"
}

rebuild_proxy_selector_in_file() {
  local file="$1"

  python3 - "${file}" <<'PY'
import json, sys

path = sys.argv[1]
cfg = json.load(open(path, 'r', encoding='utf-8'))
outbounds = cfg.setdefault("outbounds", [])

tags = []

# direct 放最前面，方便兜底
if any(ob.get("tag") == "direct" for ob in outbounds):
    tags.append("direct")

for ob in outbounds:
    tag = ob.get("tag", "")
    typ = ob.get("type", "")

    if not tag:
        continue
    if tag in ("direct", "block", "dns-out", "proxy", "auto"):
        continue
    if typ in ("selector", "urltest", "block", "dns"):
        continue

    if tag not in tags:
        tags.append(tag)

if not tags:
    tags = ["direct"]

default_tag = next((t for t in tags if t != "direct"), tags[0])

selector = None
for ob in outbounds:
    if ob.get("tag") == "proxy":
        selector = ob
        break

selector_obj = {
    "type": "selector",
    "tag": "proxy",
    "outbounds": tags,
    "default": default_tag,
    "interrupt_exist_connections": False
}

if selector is None:
    outbounds.append(selector_obj)
else:
    selector.clear()
    selector.update(selector_obj)

with open(path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
}

apply_template_config() {
  local tmp_file="$1"

  if ! check_config_file "${tmp_file}"; then
    err "配置校验失败，未写入正式配置"
    pause_enter
    return 1
  fi

  activate_config_file "${tmp_file}"

  if ! restart_singbox_service; then
    err "服务重启失败，可执行 journalctl -u sing-box -n 100 --no-pager 查看日志"
    pause_enter
    return 1
  fi

  return 0
}

rebuild_proxy_selector_now() {
  need_root
  require_template_env || return 1

  local tmp_file
  tmp_file="${TMP_DIR}/config.selector-rebuild.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  rebuild_proxy_selector_in_file "${tmp_file}" || {
    err "重建 proxy selector 失败"
    pause_enter
    return 1
  }

  if apply_template_config "${tmp_file}"; then
    ok "proxy selector 已重建"
  fi

  pause_enter
}

apply_route_template_mode() {
  local mode="$1"
  local title="$2"

  need_root
  require_template_env || return 1

  local tmp_file
  tmp_file="${TMP_DIR}/config.template-${mode}.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  rebuild_proxy_selector_in_file "${tmp_file}" || {
    err "重建 proxy selector 失败"
    pause_enter
    return 1
  }

  if ! python3 - "${tmp_file}" "${mode}" <<'PY'
import json, sys

path, mode = sys.argv[1], sys.argv[2]
cfg = json.load(open(path, 'r', encoding='utf-8'))

route = cfg.setdefault("route", {})

local_suffix_rule = {
    "domain_suffix": ["lan", "local", "home.arpa", "localhost"],
    "action": "route",
    "outbound": "direct"
}

private_rule = {
    "ip_is_private": True,
    "action": "route",
    "outbound": "direct"
}

if mode == "minimal":
    route["rules"] = [
        private_rule
    ]
    route["final"] = "proxy"

elif mode == "common":
    route["rules"] = [
        private_rule,
        local_suffix_rule
    ]
    route["final"] = "proxy"

elif mode == "global":
    route["rules"] = []
    route["final"] = "proxy"

elif mode == "direct-first":
    route["rules"] = [
        private_rule,
        local_suffix_rule
    ]
    route["final"] = "direct"

else:
    print(f"unknown mode: {mode}", file=sys.stderr)
    raise SystemExit(1)

with open(path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "写入模板失败"
    pause_enter
    return 1
  fi

  echo "准备应用模板：${title}"
  if ! confirm_default_yes "确认继续吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  if apply_template_config "${tmp_file}"; then
    ok "模板已应用：${title}"
  fi

  pause_enter
}

apply_template_minimal() {
  apply_route_template_mode "minimal" "最小模板（私网直连，其余走 proxy）"
}

apply_template_common() {
  apply_route_template_mode "common" "常用模板（私网+本地域名直连，其余走 proxy）"
}

apply_template_global() {
  apply_route_template_mode "global" "全局代理模板（全部走 proxy）"
}

apply_template_direct_first() {
  apply_route_template_mode "direct-first" "直连优先模板（本地规则直连，默认 direct）"
}

show_template_status() {
  require_template_env || return 1

  python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
route = cfg.get("route", {})
rules = route.get("rules", [])
final = route.get("final", "")

selector = None
auto_selector = None
cn_selector = None

for ob in cfg.get("outbounds", []):
    if ob.get("tag") == "手动切换" and ob.get("type") == "selector":
        selector = ob
    if ob.get("tag") == "自动选择" and ob.get("type") == "urltest":
        auto_selector = ob
    if ob.get("tag") == "中国节点" and ob.get("type") == "selector":
        cn_selector = ob
        
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

template_name = "自定义/未知"
nr = normalize_rules(rules)

has_cn_proxy_rule = any(r.get("outbound") == "cn-proxy" for r in rules)
has_proxy_rule = any(r.get("outbound") == "proxy" for r in rules)

cn_selector = None
for ob in cfg.get("outbounds", []):
    if ob.get("tag") == "cn-proxy" and ob.get("type") == "selector":
        cn_selector = ob
        break

if nr == [private_rule] and final == "手动切换":
    template_name = "最小模板"
elif nr == [private_rule, local_rule] and final == "手动切换":
    template_name = "常用模板"
elif nr == [] and final == "手动切换":
    template_name = "全局代理模板"
elif nr == [private_rule, local_rule] and final == "direct":
    template_name = "直连优先模板"
elif final == "手动切换" and has_cn_proxy_rule and has_proxy_rule and cn_selector is not None:
    template_name = "策略文件模板"

print(f"当前模板        : {template_name}")
print(f"route.final     : {final or '<空>'}")

if selector:
    print(f"手动切换 默认   : {selector.get('default', '<空>')}")
    print(f"手动切换 成员   : {', '.join(selector.get('outbounds', [])) or '<空>'}")
else:
    print("手动切换 状态   : 未找到")

if auto_selector:
    print(f"自动选择 成员   : {', '.join(auto_selector.get('outbounds', [])) or '<空>'}")
else:
    print("自动选择 状态   : 未找到")

if cn_selector:
    print(f"中国节点 默认   : {cn_selector.get('default', '<空>')}")
    print(f"中国节点 成员   : {', '.join(cn_selector.get('outbounds', [])) or '<空>'}")
else:
    print("中国节点 状态   : 未找到")

print(f"规则数量        : {len(rules)}")
print("规则摘要        :")

if not rules:
    print("  <无规则>")
else:
    for i, r in enumerate(rules, 1):
        parts = []
        if r.get("ip_is_private") is True:
            parts.append("ip_is_private")
        ds = r.get("domain_suffix", [])
        if ds:
            parts.append("domain_suffix=" + ",".join(ds))
        cidr = r.get("ip_cidr", [])
        if cidr:
            parts.append("ip_cidr=" + ",".join(cidr))
        cond = " ; ".join(parts) if parts else "custom"
        print(f"  {i}. {cond} -> {r.get('outbound', '')}")
PY

  echo
  pause_enter
}

apply_policy_groups_file_silent() {
  need_root
  require_template_env || return 1

  if [ ! -f "${POLICY_GROUPS_FILE}" ]; then
    err "未找到策略文件：${POLICY_GROUPS_FILE}"
    return 1
  fi

  local tmp_file
  tmp_file="${TMP_DIR}/config.policy-groups.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "${POLICY_GROUPS_FILE}" <<'PY'
import json, sys

config_path, policy_path = sys.argv[1], sys.argv[2]
cfg = json.load(open(config_path, 'r', encoding='utf-8'))
policy = json.load(open(policy_path, 'r', encoding='utf-8'))

outbounds = cfg.setdefault("outbounds", [])
route = cfg.setdefault("route", {})

REMOTE_TYPES = {
    "socks", "http", "shadowsocks", "vmess", "trojan", "wireguard", "hysteria",
    "vless", "shadowtls", "tuic", "hysteria2", "anytls", "tor", "ssh", "naive"
}
RESERVED = {"direct", "block", "dns-out"}

preserved = []
remote_tags = []

has_direct = False
for ob in outbounds:
    tag = ob.get("tag", "")
    typ = ob.get("type", "")

    if tag == "direct":
        has_direct = True

    if typ in ("selector", "urltest"):
        continue

    preserved.append(ob)

    if typ in REMOTE_TYPES and tag and tag not in RESERVED:
        remote_tags.append(tag)

if not has_direct:
    preserved.insert(0, {"type": "direct", "tag": "direct"})

def resolve_members(members, all_nodes):
    result = []
    for item in members:
        if item == "ALL_NODES":
            for tag in all_nodes:
                if tag not in result:
                    result.append(tag)
        elif item.startswith("MATCH:"):
            needle = item.split(":", 1)[1]
            for tag in all_nodes:
                if needle in tag and tag not in result:
                    result.append(tag)
        else:
            if item == "自动选择" and not all_nodes:
                continue
            if item not in result:
                result.append(item)
    return result

generated = []

if remote_tags:
    generated.append({
        "type": "urltest",
        "tag": "自动选择",
        "outbounds": remote_tags,
        "interrupt_exist_connections": False
    })

groups = policy.get("groups", {})

for group_name, group_cfg in groups.items():
    gtype = group_cfg.get("type", "selector")
    members = resolve_members(group_cfg.get("members", []), remote_tags)

    if not remote_tags:
        members = [m for m in members if m != "自动选择"]

    if not members:
        members = ["direct"]

    obj = {
        "type": gtype,
        "tag": group_name,
        "outbounds": members,
        "interrupt_exist_connections": False
    }

    default = group_cfg.get("default", "")
    if gtype == "selector":
        obj["default"] = default if default in members else members[0]

    generated.append(obj)

cfg["outbounds"] = preserved + generated

rules_cfg = policy.get("rules", {})

private_rule = {
    "ip_is_private": True,
    "action": "route",
    "outbound": "direct"
}

rules = [private_rule]

direct_suffix = rules_cfg.get("direct_domain_suffix", [])
if direct_suffix:
    rules.append({
        "domain_suffix": direct_suffix,
        "action": "route",
        "outbound": "direct"
    })

for outbound_tag, suffixes in rules_cfg.get("route_groups", {}).items():
    if suffixes:
        rules.append({
            "domain_suffix": suffixes,
            "action": "route",
            "outbound": outbound_tag
        })

for outbound_tag, cidrs in rules_cfg.get("route_ip_cidr_groups", {}).items():
    if cidrs:
        rules.append({
            "ip_cidr": cidrs,
            "action": "route",
            "outbound": outbound_tag
        })

route["rules"] = rules
route["final"] = rules_cfg.get("final", "手动切换")

with open(config_path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "根据策略文件生成配置失败"
    return 1
  fi

  if ! check_config_file "${tmp_file}"; then
    err "配置校验失败，未写入正式配置"
    return 1
  fi

  activate_config_file "${tmp_file}"

  if ! restart_singbox_service; then
    err "服务重启失败，可执行 journalctl -u sing-box -n 100 --no-pager 查看日志"
    return 1
  fi

  return 0
}

apply_policy_groups_file_to_config() {
  local target_config="$1"
  local policy_file="${2:-${POLICY_GROUPS_FILE}}"

  if [ ! -f "${policy_file}" ]; then
    err "未找到策略文件：${policy_file}"
    return 1
  fi

  python3 - "${target_config}" "${policy_file}" <<'PY'
import json, sys

config_path, policy_path = sys.argv[1], sys.argv[2]
cfg = json.load(open(config_path, 'r', encoding='utf-8'))
policy = json.load(open(policy_path, 'r', encoding='utf-8'))

outbounds = cfg.setdefault("outbounds", [])
route = cfg.setdefault("route", {})

REMOTE_TYPES = {
    "socks", "http", "shadowsocks", "vmess", "trojan", "wireguard", "hysteria",
    "vless", "shadowtls", "tuic", "hysteria2", "anytls", "tor", "ssh", "naive"
}
RESERVED = {"direct", "block", "dns-out"}

preserved = []
remote_tags = []

has_direct = False
for ob in outbounds:
    tag = ob.get("tag", "")
    typ = ob.get("type", "")

    if tag == "direct":
        has_direct = True

    if typ in ("selector", "urltest"):
        continue

    preserved.append(ob)

    if typ in REMOTE_TYPES and tag and tag not in RESERVED:
        remote_tags.append(tag)

if not has_direct:
    preserved.insert(0, {"type": "direct", "tag": "direct"})

def resolve_members(members, all_nodes):
    result = []
    for item in members:
        if item == "ALL_NODES":
            for tag in all_nodes:
                if tag not in result:
                    result.append(tag)
        elif item.startswith("MATCH:"):
            needle = item.split(":", 1)[1]
            for tag in all_nodes:
                if needle in tag and tag not in result:
                    result.append(tag)
        else:
            if item == "自动选择" and not all_nodes:
                continue
            if item not in result:
                result.append(item)
    return result

generated = []

if remote_tags:
    generated.append({
        "type": "urltest",
        "tag": "自动选择",
        "outbounds": remote_tags,
        "interrupt_exist_connections": False
    })

groups = policy.get("groups", {})

for group_name, group_cfg in groups.items():
    gtype = group_cfg.get("type", "selector")
    members = resolve_members(group_cfg.get("members", []), remote_tags)

    if not remote_tags:
        members = [m for m in members if m != "自动选择"]

    if not members:
        members = ["direct"]

    obj = {
        "type": gtype,
        "tag": group_name,
        "outbounds": members,
        "interrupt_exist_connections": False
    }

    default = group_cfg.get("default", "")
    if gtype == "selector":
        obj["default"] = default if default in members else members[0]

    generated.append(obj)

cfg["outbounds"] = preserved + generated

rules_cfg = policy.get("rules", {})

private_rule = {
    "ip_is_private": True,
    "action": "route",
    "outbound": "direct"
}

rules = [private_rule]

direct_suffix = rules_cfg.get("direct_domain_suffix", [])
if direct_suffix:
    rules.append({
        "domain_suffix": direct_suffix,
        "action": "route",
        "outbound": "direct"
    })

for outbound_tag, suffixes in rules_cfg.get("route_groups", {}).items():
    if suffixes:
        rules.append({
            "domain_suffix": suffixes,
            "action": "route",
            "outbound": outbound_tag
        })

for outbound_tag, cidrs in rules_cfg.get("route_ip_cidr_groups", {}).items():
    if cidrs:
        rules.append({
            "ip_cidr": cidrs,
            "action": "route",
            "outbound": outbound_tag
        })

route["rules"] = rules
route["final"] = rules_cfg.get("final", "手动切换")

with open(config_path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
}

apply_policy_groups_file_silent() {
  need_root
  require_template_env || return 1

  local tmp_file
  tmp_file="${TMP_DIR}/config.policy-groups.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! apply_policy_groups_file_to_config "${tmp_file}" "${POLICY_GROUPS_FILE}"; then
    err "根据策略文件生成配置失败"
    return 1
  fi

  if ! check_config_file "${tmp_file}"; then
    err "配置校验失败，未写入正式配置"
    return 1
  fi

  activate_config_file "${tmp_file}"

  if ! restart_singbox_service; then
    err "服务重启失败，可执行 journalctl -u sing-box -n 100 --no-pager 查看日志"
    return 1
  fi

  return 0
}

apply_policy_groups_file() {
  if apply_policy_groups_file_silent; then
    ok "策略文件已应用"
  else
    pause_enter
    return 1
  fi

  pause_enter
}

  local tmp_file
  tmp_file="${TMP_DIR}/config.policy-groups.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp_file}"

  if ! python3 - "${tmp_file}" "${POLICY_GROUPS_FILE}" <<'PY'
import json, sys

config_path, policy_path = sys.argv[1], sys.argv[2]
cfg = json.load(open(config_path, 'r', encoding='utf-8'))
policy = json.load(open(policy_path, 'r', encoding='utf-8'))

outbounds = cfg.setdefault("outbounds", [])
route = cfg.setdefault("route", {})

REMOTE_TYPES = {
    "socks", "http", "shadowsocks", "vmess", "trojan", "wireguard", "hysteria",
    "vless", "shadowtls", "tuic", "hysteria2", "anytls", "tor", "ssh", "naive"
}
RESERVED = {"direct", "block", "dns-out"}

preserved = []
remote_tags = []

has_direct = False
for ob in outbounds:
    tag = ob.get("tag", "")
    typ = ob.get("type", "")

    if tag == "direct":
        has_direct = True

    if typ in ("selector", "urltest"):
        continue

    preserved.append(ob)

    if typ in REMOTE_TYPES and tag and tag not in RESERVED:
        remote_tags.append(tag)

if not has_direct:
    preserved.insert(0, {"type": "direct", "tag": "direct"})

def resolve_members(members, all_nodes):
    result = []
    for item in members:
        if item == "ALL_NODES":
            for tag in all_nodes:
                if tag not in result:
                    result.append(tag)

        elif item.startswith("MATCH:"):
            needle = item.split(":", 1)[1]
            for tag in all_nodes:
                if needle in tag and tag not in result:
                    result.append(tag)

        else:
            if item == "自动选择" and not all_nodes:
                continue
            if item not in result:
                result.append(item)
    return result

generated = []

if remote_tags:
    generated.append({
        "type": "urltest",
        "tag": "自动选择",
        "outbounds": remote_tags,
        "interrupt_exist_connections": False
    })

groups = policy.get("groups", {})

for group_name, group_cfg in groups.items():
    gtype = group_cfg.get("type", "selector")
    members = resolve_members(group_cfg.get("members", []), remote_tags)

    if not remote_tags:
        members = [m for m in members if m != "自动选择"]

    if not members:
        members = ["direct"]

    obj = {
        "type": gtype,
        "tag": group_name,
        "outbounds": members,
        "interrupt_exist_connections": False
    }

    default = group_cfg.get("default", "")
    if gtype == "selector":
        obj["default"] = default if default in members else members[0]

    generated.append(obj)

cfg["outbounds"] = preserved + generated

rules_cfg = policy.get("rules", {})

private_rule = {
    "ip_is_private": True,
    "action": "route",
    "outbound": "direct"
}

rules = [private_rule]

direct_suffix = rules_cfg.get("direct_domain_suffix", [])
if direct_suffix:
    rules.append({
        "domain_suffix": direct_suffix,
        "action": "route",
        "outbound": "direct"
    })

for outbound_tag, suffixes in rules_cfg.get("route_groups", {}).items():
    if suffixes:
        rules.append({
            "domain_suffix": suffixes,
            "action": "route",
            "outbound": outbound_tag
        })

for outbound_tag, cidrs in rules_cfg.get("route_ip_cidr_groups", {}).items():
    if cidrs:
        rules.append({
            "ip_cidr": cidrs,
            "action": "route",
            "outbound": outbound_tag
        })

route["rules"] = rules
route["final"] = rules_cfg.get("final", "手动切换")

with open(config_path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PY
  then
    err "根据策略文件生成配置失败"
    pause_enter
    return 1
  fi

  if apply_template_config "${tmp_file}"; then
    ok "策略文件已应用"
  fi

  pause_enter
}

show_policy_groups_file() {
  if [ ! -f "${POLICY_GROUPS_FILE}" ]; then
    echo "未找到：${POLICY_GROUPS_FILE}"
  else
    echo "策略文件路径：${POLICY_GROUPS_FILE}"
    echo
    sed -n '1,220p' "${POLICY_GROUPS_FILE}"
  fi
  echo
  pause_enter
}

menu_template_management() {
  while true; do
    clear
    echo "======================================"
    echo "              模板管理"
    echo "======================================"
    echo "1. 初始化/重建 proxy selector"
    echo "2. 应用最小模板"
    echo "3. 应用常用模板"
    echo "4. 应用全局代理模板"
    echo "5. 应用直连优先模板"
    echo "6. 查看当前模板状态"
    echo "7. 应用策略文件"
    echo "8. 查看策略文件"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-8]: " choice
    case "${choice:-}" in
      1) rebuild_proxy_selector_now ;;
      2) apply_template_minimal ;;
      3) apply_template_common ;;
      4) apply_template_global ;;
      5) apply_template_direct_first ;;
      6) show_template_status ;;
      7) apply_policy_groups_file ;;
      8) show_policy_groups_file ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
