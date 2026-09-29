#!/usr/bin/env bash

# Simplified node and routing menus for SBM 0.2.9.x.
# Existing low-level functions remain available through Advanced.

show_route_policy_summary_simple() {
  require_outbound_manage_env || return 1

  python3 - "${CONFIG_DIR}/config.json" <<'PY'
import json, sys

cfg=json.load(open(sys.argv[1],encoding="utf-8"))
route=cfg.get("route",{})
rules=route.get("rules",[]) or []
final=str(route.get("final","") or "")

outbounds=cfg.get("outbounds",[]) or []
selectors=[x for x in outbounds if x.get("type")=="selector"]
urltests=[x for x in outbounds if x.get("type")=="urltest"]

mode="自定义"
if final=="手动切换" and (
    route.get("rule_set")
    or any("rule_set" in r for r in rules)
    or any(str(r.get("outbound","") or "") not in ("","direct","proxy","手动切换") for r in rules)
):
    mode="智能分流"
elif final=="proxy" and not rules:
    mode="全局代理"
elif final=="proxy" and len(rules)==1 and rules[0].get("ip_is_private") is True:
    mode="最小配置"
elif final=="direct":
    mode="直连优先"

default="<未设置>"
for name in ("手动切换","proxy"):
    for x in selectors:
        if str(x.get("tag","") or "")==name:
            default=str(x.get("default","") or "<未设置>")
            break
    if default!="<未设置>":
        break

print(f"当前模式 : {mode}")
print(f"默认出口 : {default if default else '<未设置>'}")
print(f"策略组   : {len(selectors)}")
print(f"自动测速 : {'已启用' if urltests else '未启用'}")
print(f"分流规则 : {len(rules)}")
PY
}

menu_node_update_simple() {
  while true; do
    clear
    echo "======================================"
    echo "             更新订阅"
    echo "======================================"
    echo "1. 更新指定订阅"
    echo "2. 更新全部订阅"
    echo "0. 返回"
    echo
    local choice
    read -r -p "请选择 [0-2]: " choice
    case "${choice:-}" in
      1) update_one_source ;;
      2) update_all_sources ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

menu_node_view_simple() {
  while true; do
    clear
    echo "======================================"
    echo "             查看节点"
    echo "======================================"
    echo "1. 查看订阅列表"
    echo "2. 查看某个订阅的节点"
    echo "3. 查看当前已应用节点"
    echo "0. 返回"
    echo
    local choice
    read -r -p "请选择 [0-3]: " choice
    case "${choice:-}" in
      1) show_outbound_sources; pause_enter ;;
      2) preview_source_nodes ;;
      3) show_current_applied_nodes ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

menu_node_advanced_simple() {
  while true; do
    clear
    echo "======================================"
    echo "            节点高级操作"
    echo "======================================"
    echo "1. 导入本地 sing-box 文件"
    echo "2. 应用指定订阅到当前配置"
    echo "3. 应用全部订阅到当前配置"
    echo "4. 查看当前已应用节点"
    echo "0. 返回"
    echo
    local choice
    read -r -p "请选择 [0-4]: " choice
    case "${choice:-}" in
      1) import_local_singbox_file_source ;;
      2) apply_one_source_to_runtime ;;
      3) apply_all_sources_to_runtime ;;
      4) show_current_applied_nodes ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

menu_outbound_source_management() {
  while true; do
    clear
    echo "======================================"
    echo "              节点管理"
    echo "======================================"
    echo "1. 查看订阅"
    echo "2. 添加订阅"
    echo "3. 更新订阅"
    echo "4. 查看节点"
    echo "5. 删除订阅"
    echo "6. 高级操作"
    echo "0. 返回"
    echo
    local choice
    read -r -p "请选择 [0-6]: " choice
    case "${choice:-}" in
      1) show_outbound_sources; pause_enter ;;
      2) add_subscription_url_source ;;
      3) menu_node_update_simple ;;
      4) menu_node_view_simple ;;
      5) delete_source ;;
      6) menu_node_advanced_simple ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

apply_smart_routing_simple() {
  echo "智能分流会根据当前 policy-groups.json 重新生成策略组和分流规则。"
  echo "订阅节点与 Web 面板设置会保留。"
  echo
  if ! confirm_default_yes "确认应用智能分流吗？"; then
    warn "已取消"
    pause_enter
    return 0
  fi

  if apply_policy_groups_file_silent; then
    ok "智能分流已应用"
  else
    err "智能分流应用失败"
    pause_enter
    return 1
  fi
  pause_enter
}

menu_strategy_groups_simple() {
  while true; do
    clear
    echo "======================================"
    echo "              策略组"
    echo "======================================"
    echo "1. 切换指定策略组"
    echo "2. 查看策略组可选节点"
    echo "3. 快速切换默认出口"
    echo "0. 返回"
    echo
    local choice
    read -r -p "请选择 [0-3]: " choice
    case "${choice:-}" in
      1) switch_selector_group ;;
      2) show_selector_candidates_for_group ;;
      3)
        if declare -F ow_switch_node >/dev/null 2>&1; then
          ow_switch_node
        else
          switch_proxy_selector
        fi
        ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

menu_route_advanced_simple() {
  while true; do
    clear
    echo "======================================"
    echo "            路由高级设置"
    echo "======================================"
    echo "1. 应用旧版“常用模板”"
    echo "2. 查看完整策略状态"
    echo "3. 查看策略文件"
    echo "4. 重建 proxy selector"
    echo "5. 原始模板管理"
    echo "0. 返回"
    echo
    local choice
    read -r -p "请选择 [0-5]: " choice
    case "${choice:-}" in
      1) apply_template_common ;;
      2) show_template_status ;;
      3) show_policy_groups_file ;;
      4) rebuild_proxy_selector_now ;;
      5) menu_template_management ;;
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
    show_route_policy_summary_simple
    echo
    echo "1. 查看当前分流状态"
    echo "2. 智能分流"
    echo "3. 全局代理"
    echo "4. 直连优先"
    echo "5. 最小配置"
    echo "6. 策略组"
    echo "7. 高级设置"
    echo "0. 返回"
    echo
    local choice
    read -r -p "请选择 [0-7]: " choice
    case "${choice:-}" in
      1)
        clear
        echo "======================================"
        echo "            当前分流状态"
        echo "======================================"
        show_route_policy_summary_simple
        echo
        pause_enter
        ;;
      2) apply_smart_routing_simple ;;
      3) apply_template_global ;;
      4) apply_template_direct_first ;;
      5) apply_template_minimal ;;
      6) menu_strategy_groups_simple ;;
      7) menu_route_advanced_simple ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}
