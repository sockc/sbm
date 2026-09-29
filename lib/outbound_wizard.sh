#!/usr/bin/env bash

ow_mode_label() {
  case "$1" in
    smart) echo "智能分流" ;;
    global) echo "全局代理" ;;
    direct-first) echo "直连优先" ;;
    minimal) echo "最小配置" ;;
    *) echo "$1" ;;
  esac
}

ow_choose_mode() {
  local c
  while true; do
    echo >&2
    echo "请选择代理模式：" >&2
    echo "1. 智能分流（策略文件，推荐）" >&2
    echo "2. 全局代理" >&2
    echo "3. 直连优先" >&2
    echo "4. 最小配置" >&2
    echo "0. 返回" >&2
    read -r -p "请选择 [0-4]: " c
    case "${c:-}" in
      1) echo "smart"; return 0 ;;
      2) echo "global"; return 0 ;;
      3) echo "direct-first"; return 0 ;;
      4) echo "minimal"; return 0 ;;
      0) return 1 ;;
      *) echo "无效选项" >&2 ;;
    esac
  done
}

ow_selector_for_mode() {
  case "$1" in
    smart) echo "手动切换" ;;
    *) echo "proxy" ;;
  esac
}

ow_current_selector() {
  python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, sys
try:
    cfg=json.load(open(sys.argv[1],encoding="utf-8"))
except Exception:
    raise SystemExit(1)
for name in ("手动切换","proxy"):
    if any(x.get("type")=="selector" and x.get("tag")==name for x in cfg.get("outbounds",[])):
        print(name); raise SystemExit(0)
raise SystemExit(1)
PY
}

ow_current_default() {
  local tag="${1:-}"
  [ -n "${tag}" ] || tag="$(ow_current_selector 2>/dev/null || true)"
  [ -n "${tag}" ] || return 1
  python3 - "${CONFIG_DIR}/config.json" "${tag}" <<'PY'
import json,sys
cfg=json.load(open(sys.argv[1],encoding="utf-8")); tag=sys.argv[2]
for x in cfg.get("outbounds",[]):
    if x.get("type")=="selector" and x.get("tag")==tag:
        print(x.get("default","")); raise SystemExit(0)
raise SystemExit(1)
PY
}

ow_status() {
  local panel="未启用" sources="0/0" nodes="0" mode="未配置" current="未配置"
  mapfile -t s < <(get_outbound_status_info 2>/dev/null || true)
  panel="${s[0]:-未启用}"
  sources="${s[1]:-0/0}"
  nodes="${s[2]:-0}"
  case "${s[4]:-}" in
    策略文件|策略文件模板) mode="智能分流" ;;
    全局代理|全局代理模板) mode="全局代理" ;;
    直连优先|直连优先模板) mode="直连优先" ;;
    最小模板) mode="最小配置" ;;
    *) mode="${s[4]:-未配置}" ;;
  esac
  current="$(ow_current_default 2>/dev/null || true)"
  [ -n "${current}" ] || current="${s[5]:-未配置}"
  echo "节点源      : ${sources}"
  echo "缓存节点    : ${nodes}"
  echo "当前出口    : ${current}"
  echo "代理模式    : ${mode}"
  echo "Web 面板    : ${panel}"
}

ow_apply_simple_mode_file() {
  local file="$1" mode="$2"
  rebuild_proxy_selector_in_file "${file}" || return 1
  python3 - "${file}" "${mode}" <<'PY'
import json,sys
p,mode=sys.argv[1:]
cfg=json.load(open(p,encoding="utf-8"))
route=cfg.setdefault("route",{})
private={"ip_is_private":True,"action":"route","outbound":"direct"}
local={"domain_suffix":["lan","local","home.arpa","localhost"],"action":"route","outbound":"direct"}
if mode=="global":
    route["rules"]=[]; route["final"]="proxy"
elif mode=="minimal":
    route["rules"]=[private]; route["final"]="proxy"
elif mode=="direct-first":
    route["rules"]=[private,local]; route["final"]="direct"
else:
    raise SystemExit(1)
auto=any(x.get("type")=="urltest" and x.get("tag")=="自动选择" for x in cfg.get("outbounds",[]))
for x in cfg.get("outbounds",[]):
    if x.get("type")=="selector" and x.get("tag")=="proxy":
        members=list(x.get("outbounds",[]) or [])
        if auto and "自动选择" not in members:
            members.insert(1 if members and members[0]=="direct" else 0,"自动选择")
        x["outbounds"]=members
        if auto: x["default"]="自动选择"
        break
json.dump(cfg,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
PY
}

ow_apply_mode_file() {
  local file="$1" mode="$2"
  if [ "${mode}" = "smart" ]; then
    apply_policy_groups_file_to_config "${file}" "${POLICY_GROUPS_FILE}"
  else
    ow_apply_simple_mode_file "${file}" "${mode}"
  fi
}

ow_candidates() {
  local file="$1" tag="$2"
  python3 - "${file}" "${tag}" <<'PY'
import json,sys
cfg=json.load(open(sys.argv[1],encoding="utf-8")); tag=sys.argv[2]
for x in cfg.get("outbounds",[]):
    if x.get("type")=="selector" and x.get("tag")==tag:
        for i,v in enumerate(x.get("outbounds",[]) or [],1): print(f"{i}\t{v}")
        raise SystemExit(0)
raise SystemExit(1)
PY
}

ow_set_default() {
  local file="$1" tag="$2" target="$3"
  python3 - "${file}" "${tag}" "${target}" <<'PY'
import json,sys
p,tag,target=sys.argv[1:]
cfg=json.load(open(p,encoding="utf-8"))
for x in cfg.get("outbounds",[]):
    if x.get("type")=="selector" and x.get("tag")==tag:
        if target not in (x.get("outbounds",[]) or []): raise SystemExit(1)
        x["default"]=target; break
else: raise SystemExit(1)
json.dump(cfg,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
PY
}

ow_choose_default() {
  local file="$1" tag="$2" preferred="${3:-}" default_idx="1"
  local i item count=0
  echo "可选出口：" >&2
  echo "------------------------------------------" >&2
  while IFS=$'\t' read -r i item; do
    [ -n "${i}" ] || continue
    count=$((count+1))
    if [ -n "${preferred}" ] && [ "${item}" = "${preferred}" ]; then default_idx="${i}"; fi
    if [ -z "${preferred}" ] && [ "${item}" = "自动选择" ]; then default_idx="${i}"; fi
    printf '%-4s %s\n' "${i}" "${item}" >&2
  done < <(ow_candidates "${file}" "${tag}")
  echo "------------------------------------------" >&2
  [ "${count}" -gt 0 ] || return 1
  local c target
  c="$(prompt_default "请输入默认出口编号" "${default_idx}")"
  target="$(ow_candidates "${file}" "${tag}" | awk -F '\t' -v n="${c}" '$1==n{sub(/^[^\t]*\t/,"");print;exit}')"
  [ -n "${target}" ] || return 1
  echo "${target}"
}

ow_prepare_mode_default() {
  local file="$1" mode="$2" preferred="${3:-}"
  ow_apply_mode_file "${file}" "${mode}" || return 1
  local tag target
  tag="$(ow_selector_for_mode "${mode}")"
  if [ "${mode}" = "direct-first" ]; then
    target="direct"
  else
    target="$(ow_choose_default "${file}" "${tag}" "${preferred}")" || return 1
  fi
  ow_set_default "${file}" "${tag}" "${target}" || return 1
  printf '%s\t%s\n' "${tag}" "${target}"
}

ow_cache_files() {
  local replace="${1:-}" replacement="${2:-}" seen=0
  while IFS= read -r m; do
    [ -n "${m}" ] || continue
    mapfile -t a < <(read_source_meta_fields "${m}")
    local id="${a[0]:-}" enabled="${a[4]:-True}" f
    case "${enabled}" in False|false|0) continue ;; esac
    if [ -n "${replace}" ] && [ "${id}" = "${replace}" ]; then
      [ -n "${replacement}" ] && echo "${replacement}"
      seen=1
    else
      f="${NODE_CACHE_DIR}/${id}.outbounds.json"
      [ -f "${f}" ] && echo "${f}"
    fi
  done < <(list_source_meta_files)
  [ -n "${replacement}" ] && [ "${seen}" -eq 0 ] && echo "${replacement}"
}

ow_build_from_caches() {
  local file="$1" replace="${2:-}" replacement="${3:-}" caches=()
  while IFS= read -r f; do [ -n "${f}" ] && caches+=("${f}"); done < <(ow_cache_files "${replace}" "${replacement}")
  [ "${#caches[@]}" -gt 0 ] || return 1
  apply_cache_files_to_runtime_file "${file}" "${caches[@]}"
}

ow_apply_config() {
  local file="$1"
  check_config_file "${file}" || return 1
  activate_config_file "${file}"
  restart_singbox_service || return 1
}

ow_parse_source_temp() {
  local type="$1" loc="$2" raw="$3" cache="$4"
  case "${type}" in
    url) fetch_to_file "${loc}" "${raw}" || return 1 ;;
    file) [ -f "${loc}" ] || return 1; cp -f "${loc}" "${raw}" || return 1 ;;
    *) return 1 ;;
  esac
  normalize_source_raw_to_cache "${raw}" "${cache}"
}

ow_configure_source() {
  local kind="$1" meta="" id name type loc
  if [ "${kind}" = "new" ]; then
    name="$(prompt_default "请输入订阅名称" "$(default_next_source_name)")"
    loc="$(prompt_required "请输入 sing-box 订阅 URL")"
    type="url"; id="$(next_source_id)"
  else
    show_outbound_sources
    echo
    local idx
    idx="$(prompt_required "请输入订阅编号")"
    meta="$(get_source_meta_path_by_index "${idx}")"
    [ -f "${meta}" ] || { err "订阅编号无效"; pause_enter; return 1; }
    mapfile -t a < <(read_source_meta_fields "${meta}")
    id="${a[0]:-}"; name="${a[1]:-}"; type="${a[2]:-}"; loc="${a[3]:-}"
  fi

  local raw="${TMP_DIR}/ow-raw.json" cache="${TMP_DIR}/ow-cache.json" count
  echo "正在获取并解析：${name}"
  count="$(ow_parse_source_temp "${type}" "${loc}" "${raw}" "${cache}")" || {
    err "订阅获取或解析失败"; pause_enter; return 1;
  }
  [ "${count}" -gt 0 ] || { err "没有可用节点"; pause_enter; return 1; }
  echo "已解析：${count} 个节点"

  local mode tmp preferred="" oldsel result tag target
  oldsel="$(ow_current_selector 2>/dev/null || true)"
  [ "${kind}" = "existing" ] && preferred="$(ow_current_default "${oldsel}" 2>/dev/null || true)"
  mode="$(ow_choose_mode)" || return 0
  tmp="${TMP_DIR}/config.outbound-wizard.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp}"
  ow_build_from_caches "${tmp}" "${id}" "${cache}" || { err "生成节点配置失败"; pause_enter; return 1; }
  result="$(ow_prepare_mode_default "${tmp}" "${mode}" "${preferred}")" || { err "生成策略失败"; pause_enter; return 1; }
  IFS=$'\t' read -r tag target <<<"${result}"
  check_config_file "${tmp}" >/dev/null 2>&1 || { err "配置校验失败"; pause_enter; return 1; }

  echo
  echo "========== 出站配置确认 =========="
  echo "订阅       : ${name}"
  echo "地址       : $(mask_url "${loc}")"
  echo "节点       : ${count}"
  echo "代理模式   : $(ow_mode_label "${mode}")"
  echo "默认出口   : ${target}"
  echo "Web 面板   : 保持当前设置"
  echo "================================="
  echo
  confirm_default_yes "确认应用吗？" || { warn "已取消"; pause_enter; return 0; }

  local final_cache="${NODE_CACHE_DIR}/${id}.outbounds.json"
  if [ "${kind}" = "new" ]; then
    meta="${SOURCES_DIR}/${id}.json"
    create_source_meta_file "${meta}" "${id}" "${name}" "url" "${loc}" || return 1
    install -m 600 "${cache}" "${final_cache}" || { rm -f "${meta}"; return 1; }
    update_source_meta_success "${meta}" "${count}" || true
    chmod 600 "${meta}" 2>/dev/null || true
  fi

  if ! ow_apply_config "${tmp}"; then
    [ "${kind}" = "new" ] && rm -f "${meta}" "${final_cache}"
    err "应用失败，配置已尝试自动回滚"
    pause_enter
    return 1
  fi

  if [ "${kind}" = "existing" ]; then
    install -m 600 "${cache}" "${final_cache}" || warn "缓存写回失败"
    update_source_meta_success "${meta}" "${count}" || warn "节点源状态写回失败"
  fi
  ok "快速配置完成：${name} / $(ow_mode_label "${mode}") / ${target}"
  pause_enter
}

ow_switch_node() {
  local tag
  tag="$(ow_current_selector 2>/dev/null || true)"
  [ -n "${tag}" ] || { err "当前没有可切换策略组，请先完成快速配置"; pause_enter; return 1; }

  echo "策略组：${tag}"
  ow_candidates "${CONFIG_DIR}/config.json" "${tag}"
  local idx target
  idx="$(prompt_required "请输入要切换到的出口编号")"
  target="$(ow_candidates "${CONFIG_DIR}/config.json" "${tag}" | awk -F '\t' -v n="${idx}" '$1==n{sub(/^[^\t]*\t/,"");print;exit}')"
  [ -n "${target}" ] || { err "编号无效"; pause_enter; return 1; }
  confirm_default_yes "确认切换到 ${target} 吗？" || return 0

  local body path
  body="$(python3 - "${target}" <<'PY'
import json,sys
print(json.dumps({"name":sys.argv[1]},ensure_ascii=False))
PY
)"
  path="/proxies/$(urlencode_text "${tag}")"
  if clash_api_request "PUT" "${path}" "${body}" >/dev/null 2>&1; then
    local tmp="${TMP_DIR}/config.live-selector.json"
    cp -f "${CONFIG_DIR}/config.json" "${tmp}"
    if ow_set_default "${tmp}" "${tag}" "${target}" && check_config_file "${tmp}" >/dev/null 2>&1; then
      backup_current_config >/dev/null 2>&1 || true
      install -m 600 "${tmp}" "${CONFIG_DIR}/config.json"
      clear_config_rollback_point
    fi
    ok "已实时切换到：${target}（无需重启）"
  else
    warn "Clash API 不可用，改用配置切换并重启。"
    local tmp="${TMP_DIR}/config.switch-selector.json"
    cp -f "${CONFIG_DIR}/config.json" "${tmp}"
    ow_set_default "${tmp}" "${tag}" "${target}" || return 1
    ow_apply_config "${tmp}" || { err "切换失败"; pause_enter; return 1; }
    ok "已切换到：${target}"
  fi
  pause_enter
}

ow_change_mode() {
  local mode tmp oldsel preferred result tag target
  oldsel="$(ow_current_selector 2>/dev/null || true)"
  preferred="$(ow_current_default "${oldsel}" 2>/dev/null || true)"
  mode="$(ow_choose_mode)" || return 0
  tmp="${TMP_DIR}/config.outbound-mode.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp}"
  result="$(ow_prepare_mode_default "${tmp}" "${mode}" "${preferred}")" || { err "生成模式失败"; pause_enter; return 1; }
  IFS=$'\t' read -r tag target <<<"${result}"
  echo "代理模式：$(ow_mode_label "${mode}")"
  echo "默认出口：${target}"
  confirm_default_yes "确认应用吗？" || return 0
  ow_apply_config "${tmp}" || { err "应用失败"; pause_enter; return 1; }
  ok "代理模式已修改"
  pause_enter
}

ow_repair() {
  local n mode tmp oldsel preferred result tag target
  n="$(ow_cache_files | grep -c . || true)"
  [ "${n}" -gt 0 ] || { err "没有可用节点缓存"; pause_enter; return 1; }
  echo "将使用全部启用节点源缓存重新生成出站配置。"
  echo "可用缓存：${n}"
  mode="$(ow_choose_mode)" || return 0
  oldsel="$(ow_current_selector 2>/dev/null || true)"
  preferred="$(ow_current_default "${oldsel}" 2>/dev/null || true)"
  tmp="${TMP_DIR}/config.outbound-repair.json"
  cp -f "${CONFIG_DIR}/config.json" "${tmp}"
  ow_build_from_caches "${tmp}" || { err "节点重建失败"; pause_enter; return 1; }
  result="$(ow_prepare_mode_default "${tmp}" "${mode}" "${preferred}")" || { err "策略重建失败"; pause_enter; return 1; }
  IFS=$'\t' read -r tag target <<<"${result}"
  echo "代理模式：$(ow_mode_label "${mode}")"
  echo "默认出口：${target}"
  confirm_default_no "确认重新生成出站配置吗？" || return 0
  ow_apply_config "${tmp}" || { err "重建失败"; pause_enter; return 1; }
  ok "出站配置已重新生成"
  pause_enter
}

menu_outbound_quick_config() {
  while true; do
    clear
    echo "======================================"
    echo "           出站快速配置"
    echo "======================================"
    ow_status
    echo
    echo "1. 新增一个订阅并开始配置"
    echo "2. 使用已有订阅重新配置"
    echo "3. 只切换当前节点"
    echo "4. 只修改代理模式"
    echo "5. 修复/重新生成出站配置"
    echo "0. 返回"
    echo
    local c
    read -r -p "请选择 [0-5]: " c
    case "${c:-}" in
      1) ow_configure_source "new" ;;
      2) ow_configure_source "existing" ;;
      3) ow_switch_node ;;
      4) ow_change_mode ;;
      5) ow_repair ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

menu_outbound_management() {
  while true; do
    clear
    show_outbound_status_header
    echo "1. 快速配置"
    echo "2. 节点管理"
    echo "3. 路由策略"
    echo "4. Web 面板"
    echo "5. 出站开关"
    echo "0. 返回"
    echo
    local c
    read -r -p "请选择 [0-5]: " c
    case "${c:-}" in
      1) menu_outbound_quick_config ;;
      2) menu_outbound_source_management ;;
      3) menu_route_policy_management ;;
      4) menu_clash_api_management ;;
      5) menu_outbound_proxy_switch ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
