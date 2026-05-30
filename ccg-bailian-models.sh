#!/bin/bash
# CCG Bailian Multi-Model Support
# Supports: Qwen 3.6/3.7, DeepSeek V4, Kimi K2.6, GLM 5.1, Mimo v2.5-pro
# All models follow Alibaba Bailian API protocol (OpenAI-compatible)

# ============================================================
# Model Registry: Bailian Platform Models
# ============================================================
_ccg_bailian_models() {
  cat <<'EOF'
# Qwen Series
qwen-3.7:0.30:0.90:quality:Qwen 3.7 (质量优先)
qwen-3.6:0.25:0.75:balanced:Qwen 3.6 (平衡)
qwen-3.6-plus:0.20:0.60:balanced:Qwen 3.6 Plus
qwen-3.5-sonnet:0.15:0.45:balanced:Qwen 3.5 Sonnet
qwen-3.5-haiku:0.05:0.15:cost:Qwen 3.5 Haiku (成本优先)

# DeepSeek Series
deepseek-v4:0.35:1.05:quality:DeepSeek V4 (高性能)
deepseek-v4-lite:0.18:0.54:balanced:DeepSeek V4 Lite

# Kimi Series
kimi-k2.6:0.32:0.96:quality:Kimi K2.6 (长文本)
kimi-k2.6-lite:0.16:0.48:balanced:Kimi K2.6 Lite

# GLM Series
glm-5.1:0.28:0.84:quality:GLM 5.1 (多模态)
glm-5.1-lite:0.14:0.42:balanced:GLM 5.1 Lite

# Mimo Series
mimo-v2.5-pro:0.22:0.66:balanced:Mimo v2.5 Pro
mimo-v2.5:0.11:0.33:cost:Mimo v2.5
EOF
}

# ============================================================
# Get model pricing
# ============================================================
_ccg_bailian_price() {
  local model="$1" field="${2:-input}"
  local line
  line=$(_ccg_bailian_models | grep "^${model}:" | head -1)
  if [ -z "$line" ]; then
    echo "0"
    return 1
  fi
  local in_price out_price
  in_price=$(printf '%s' "$line" | cut -d: -f2)
  out_price=$(printf '%s' "$line" | cut -d: -f3)
  case "$field" in
    input)  echo "$in_price" ;;
    output) echo "$out_price" ;;
    *)      echo "0" ;;
  esac
}

# ============================================================
# Get model tier (cost|balanced|quality)
# ============================================================
_ccg_bailian_tier() {
  local model="$1"
  local line
  line=$(_ccg_bailian_models | grep "^${model}:" | head -1)
  [ -n "$line" ] && printf '%s' "$line" | cut -d: -f4
}

# ============================================================
# List available models
# ============================================================
_ccg_bailian_list() {
  _ccg_bailian_models | grep -v '^#' | awk -F: '{printf "%-20s %s\n", $1, $5}'
}

# ============================================================
# Resolve model by mode (cost|balanced|quality)
# ============================================================
_ccg_resolve_bailian_model_by_mode() {
  local mode="${1:-balanced}"
  local line
  case "$mode" in
    cost)
      line=$(_ccg_bailian_models | grep ':cost:' | head -1)
      ;;
    quality)
      line=$(_ccg_bailian_models | grep ':quality:' | head -1)
      ;;
    *)
      line=$(_ccg_bailian_models | grep ':balanced:' | head -1)
      ;;
  esac
  [ -n "$line" ] && printf '%s' "$line" | cut -d: -f1
}

# ============================================================
# Validate model exists
# ============================================================
_ccg_bailian_model_exists() {
  local model="$1"
  _ccg_bailian_models | grep -q "^${model}:" && return 0 || return 1
}

# ============================================================
# Get model description
# ============================================================
_ccg_bailian_model_desc() {
  local model="$1"
  local line
  line=$(_ccg_bailian_models | grep "^${model}:" | head -1)
  [ -n "$line" ] && printf '%s' "$line" | cut -d: -f5
}
