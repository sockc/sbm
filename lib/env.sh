#!/usr/bin/env bash

SBM_VERSION="0.2.1.0"
DEFAULT_SINGBOX_VERSION="1.13.3"

PROJECT_NAME="sbm"
BASE_DIR="/usr/local/share/sbm"
CONFIG_DIR="/etc/sing-box"
BACKUP_DIR="${CONFIG_DIR}/backup"
TMP_DIR="/tmp/sbm"
INBOUND_META_DIR="${BASE_DIR}/meta/inbounds"
SOURCES_DIR="${CONFIG_DIR}/sources"
NODE_CACHE_DIR="${CONFIG_DIR}/node-cache"
META_FILE="${BASE_DIR}/reality-meta.json"
POLICY_GROUPS_FILE="${BASE_DIR}/policy-groups.json"
DEFAULT_CLIENT_FP="chrome"
