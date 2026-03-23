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
for ob in cfg.get("outbounds", []):
    if ob.get("tag") == "proxy" and ob.get("type") == "selector":
        selector = ob
        break

def normalize_rules(rules):
    result = []
    for r in rules:
        item = {}
        if r.get("ip_is_private") is True:
            item["ip_is_private"] = True
        if "domain_suffix" in r:
            item["domain_suffix"] = sorted(r.get("domain_suffix", []))
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

if nr == [private_rule] and final == "proxy":
    template_name = "最小模板"
elif nr == [private_rule, local_rule] and final == "proxy":
    template_name = "常用模板"
elif nr == [] and final == "proxy":
    template_name = "全局代理模板"
elif nr == [private_rule, local_rule] and final == "direct":
    template_name = "直连优先模板"

print(f"当前模板        : {template_name}")
print(f"route.final     : {final or '<空>'}")

if selector:
    print(f"selector 默认   : {selector.get('default', '<空>')}")
    print(f"selector 成员   : {', '.join(selector.get('outbounds', [])) or '<空>'}")
else:
    print("selector 状态   : 未找到 tag=proxy 的 selector")

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
        cond = " ; ".join(parts) if parts else "custom"
        print(f"  {i}. {cond} -> {r.get('outbound', '')}")
PY

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
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-6]: " choice
    case "${choice:-}" in
      1) rebuild_proxy_selector_now ;;
      2) apply_template_minimal ;;
      3) apply_template_common ;;
      4) apply_template_global ;;
      5) apply_template_direct_first ;;
      6) show_template_status ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
