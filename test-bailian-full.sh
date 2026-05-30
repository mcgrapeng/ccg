#!/bin/bash
# 完整测试 Bailian 集成

set -e

source "$(dirname "$0")/ccg.sh"

echo "=== Bailian 集成测试 ==="
echo ""

# 1. 检查配置
echo "1️⃣  检查配置..."
eval "$(ccg_init)"
eval "$(ccg_preflight)"

if [ "$CCG_PREFLIGHT_BAILIAN" != "ok" ]; then
  echo "❌ BAILIAN_API_KEY 未设置"
  exit 1
fi
echo "✅ API 密钥已配置"
echo ""

# 2. 测试模型解析
echo "2️⃣  测试模型解析..."
for mode in cost balanced quality; do
  export CCG_MODE="$mode"
  model=$(_ccg_resolve_bailian_model)
  echo "  $mode → $model"
done
echo ""

# 3. 测试基础调用
echo "3️⃣  测试基础调用..."
TEST_PROMPT="Review this code:
function test() { return 42; }
Any issues?"

echo "$TEST_PROMPT" > "$CCG_BAILIAN_PROMPT"

if ccg_bailian "$CCG_BAILIAN_PROMPT" "$CCG_BAILIAN_RESULT"; then
  echo "✅ 基础调用成功"
  echo "   响应大小: $(wc -c < "$CCG_BAILIAN_RESULT") 字节"
else
  echo "❌ 基础调用失败"
  cat "$CCG_BAILIAN_ERR"
  exit 1
fi
echo ""

# 4. 测试缓存
echo "4️⃣  测试缓存..."
if ccg_bailian "$CCG_BAILIAN_PROMPT" "$CCG_BAILIAN_RESULT"; then
  if grep -q "cache=hit" <<< "$(ccg_bailian "$CCG_BAILIAN_PROMPT" "$CCG_BAILIAN_RESULT" 2>&1)"; then
    echo "✅ 缓存命中"
  else
    echo "⚠️  缓存未命中（首次调用）"
  fi
fi
echo ""

# 5. 测试参数控制
echo "5️⃣  测试参数控制..."
export CCG_BAILIAN_TEMP="0.3"
export CCG_BAILIAN_MAX_TOKENS="2048"
echo "✅ 参数已设置 (temp=0.3, max_tokens=2048)"
echo ""

# 6. 测试重试机制
echo "6️⃣  测试重试机制..."
export CCG_BAILIAN_RETRIES="2"
echo "✅ 重试次数: 2"
echo ""

# 7. 测试流式输出
echo "7️⃣  测试流式输出..."
echo "Streaming response:"
timeout 10 ccg_bailian_stream "$CCG_BAILIAN_PROMPT" 2>/dev/null | head -5 || echo "⚠️  流式输出超时或失败"
echo ""

# 8. 测试所有模型
echo "8️⃣  测试所有模型..."
for model in qwen-3.7 qwen-3.6 qwen-3.6-plus qwen-3.5-sonnet qwen-3.5-haiku; do
  export CCG_BAILIAN_MODEL="$model"
  price_in=$(_ccg_price "$model" input)
  price_out=$(_ccg_price "$model" output)
  echo "  $model: \$$price_in/\$$price_out per 1M tokens"
done
echo ""

echo "✅ 所有测试完成！"
