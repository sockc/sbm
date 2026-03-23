#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-yourname/singbox-manager}"
BRANCH="${BRANCH:-main}"

INSTALL_DIR="/usr/local/share/sbm"
BIN_PATH="/usr/local/sbin/sbm"

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

fetch() {
  local url="$1"
  if need_cmd curl; then
    curl -fsSL "$url"
  elif need_cmd wget; then
    wget -qO- "$url"
  else
    echo "错误：未找到 curl 或 wget"
    exit 1
  fi
}

install_file() {
  local src_url="$1"
  local dst="$2"
  mkdir -p "$(dirname "$dst")"
  fetch "$src_url" > "$dst"
  chmod +x "$dst"
}

main() {
  echo "==> 安装 sbm 脚本..."

  mkdir -p "$INSTALL_DIR/lib" "$INSTALL_DIR/templates/inbounds" "$INSTALL_DIR/templates/outbounds"

  install_file "https://raw.githubusercontent.com/${REPO}/${BRANCH}/sbm.sh" "$INSTALL_DIR/sbm.sh"
  install_file "https://raw.githubusercontent.com/${REPO}/${BRANCH}/lib/env.sh" "$INSTALL_DIR/lib/env.sh"
  install_file "https://raw.githubusercontent.com/${REPO}/${BRANCH}/lib/common.sh" "$INSTALL_DIR/lib/common.sh"
  install_file "https://raw.githubusercontent.com/${REPO}/${BRANCH}/lib/input.sh" "$INSTALL_DIR/lib/input.sh"
  install_file "https://raw.githubusercontent.com/${REPO}/${BRANCH}/lib/install_core.sh" "$INSTALL_DIR/lib/install_core.sh"

  cat > "$BIN_PATH" <<'EOF'
#!/usr/bin/env bash
exec /usr/local/share/sbm/sbm.sh "$@"
EOF
  chmod +x "$BIN_PATH"

  echo
  echo "安装完成"
  echo "命令入口: $BIN_PATH"
  echo "运行方式: sbm"
}

main "$@"
