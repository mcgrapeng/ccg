# Bailian 集成指南

用阿里百炼 Qwen 模型替换 Gemini。

## 快速开始

```bash
export BAILIAN_API_KEY="sk-6a4bceddf3634d3192dbd7b13117f76b"
export CCG_BAILIAN_MODEL="qwen-3.7"  # 可选
```

## 模型选择

| 模型 | 模式 | 输入 | 输出 |
|------|------|------|------|
| qwen-3.7 | quality | $0.30/1M | $0.90/1M |
| qwen-3.6 | balanced | $0.25/1M | $0.75/1M |
| qwen-3.6-plus | quality | $0.20/1M | $0.60/1M |
| qwen-3.5-sonnet | balanced | $0.15/1M | $0.45/1M |
| qwen-3.5-haiku | cost | $0.05/1M | $0.15/1M |

## 环境变量

```bash
# 必需
BAILIAN_API_KEY="sk-..."

# 可选
CCG_BAILIAN_MODEL="qwen-3.7"        # 覆盖默认模型
CCG_BAILIAN_TIMEOUT="120"           # 超时秒数 (默认: 120)
CCG_BAILIAN_TEMP="0.7"              # 温度 (默认: 0.7)
CCG_BAILIAN_MAX_TOKENS="4096"       # 最大 token (默认: 4096)
CCG_BAILIAN_RETRIES="3"             # 重试次数 (默认: 3)
```

## 使用方式

### 基础调用
```bash
source ccg.sh
eval "$(ccg_init)"
ccg_bailian "$CCG_BAILIAN_PROMPT" "$CCG_BAILIAN_RESULT"
```

### 带重试
```bash
_ccg_bailian_retry "$CCG_BAILIAN_PROMPT" "$CCG_BAILIAN_RESULT"
```

### 流式输出
```bash
ccg_bailian_stream "$CCG_BAILIAN_PROMPT"
```

## 模式选择

```bash
# 成本优先
export CCG_MODE=cost
# 使用: qwen-3.5-haiku

# 平衡 (默认)
export CCG_MODE=balanced
# 使用: qwen-3.6

# 质量优先
export CCG_MODE=quality
# 使用: qwen-3.7
```

## 集成到 CCG 主流程

在 CCG 的代码审查流程中，用 `ccg_bailian` 替换 `ccg_gemini`。

## API 端点

- **URL**: `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions`
- **格式**: OpenAI 兼容 API
- **认证**: Bearer token

