# 自定义 OpenAI 兼容模型

Typefree 现在支持把语音识别和语音润色分别指向任意 **OpenAI 兼容** 服务。原有火山引擎和阿里百炼配置不变；在「设置 → 模型」中选择「自定义」即可填写配置。

## 语音润色 / 长按问答

在「语音优化」中选择「自定义」，填写：

| 字段 | 说明 |
|---|---|
| API 地址 | OpenAI 兼容的 Chat Completions 基础地址，例如 `https://api.openai.com/v1`；也可以填写完整的 `/chat/completions` 地址 |
| API Key | 服务商密钥；本地无鉴权服务可以留空 |
| 模型 ID | 服务商实际使用的模型名称 |
| 认证头 | 默认 `Authorization`（自动添加 `Bearer`）；需要 `X-API-Key` 等原始值时填写对应头名 |
| 附加参数 JSON | 可选；服务商需要额外字段时填写 JSON 对象 |

保存的 API Key 只进入 macOS 钥匙串，不会写入 `config.json`。远程服务请使用 HTTPS；明文 HTTP 仅允许 `localhost` / `127.x` 回环地址。自定义润色模型也会用于「长按问 AI」的多轮问答。

示例配置（API Key 不放这里）：

```json
{
  "polish_provider": "custom",
  "custom_polish_endpoint": "https://api.openai.com/v1",
  "custom_polish_model": "gpt-4o-mini"
}
```

也支持环境变量：

```text
CUSTOM_POLISH_ENDPOINT=https://api.openai.com/v1
CUSTOM_POLISH_MODEL=gpt-4o-mini
CUSTOM_POLISH_API_KEY=sk-...
CUSTOM_POLISH_AUTH_HEADER=Authorization
```

## 语音识别

在「语音识别」中选择「自定义」，填写 API 地址、模型 ID 和可选 API Key，然后选择请求格式：

| 请求格式 | 适用接口 |
|---|---|
| 转写接口（multipart） | OpenAI 兼容 `POST /audio/transcriptions` |
| 对话接口（原始 Base64） | OpenAI 风格 Chat Completions 的 `input_audio.data` |
| 对话接口（Data URL） | Qwen / DashScope 风格的 `input_audio.data` Data URL |

自定义识别卡片还提供“附加参数 JSON（可选）”，例如 `{"language":"zh"}`；转写接口会作为 multipart 字段发送，Chat 接口会合并到 JSON 请求体。

示例：

```json
{
  "bigasr_version": "custom",
  "custom_asr_endpoint": "https://api.openai.com/v1",
  "custom_asr_model": "gpt-4o-transcribe",
  "custom_asr_request_format": "transcriptions"
}
```

Qwen ASR 示例：

```json
{
  "bigasr_version": "custom",
  "custom_asr_endpoint": "https://dashscope.aliyuncs.com/compatible-mode/v1",
  "custom_asr_model": "qwen3-asr-flash",
  "custom_asr_request_format": "chatDataURL"
}
```

环境变量对应为 `CUSTOM_ASR_ENDPOINT`、`CUSTOM_ASR_MODEL`、`CUSTOM_ASR_API_KEY`、`CUSTOM_ASR_AUTH_HEADER` 和 `CUSTOM_ASR_REQUEST_FORMAT`。

## 高级参数

如果服务需要非标准 JSON 字段，可以在本地配置中设置 `custom_polish_extra_body` 或 `custom_asr_extra_body`，内容必须是 JSON 对象。例如：

```json
{
  "custom_polish_extra_body": "{\"top_p\":0.8}"
}
```

核心字段（`model`、`messages`、音频输入等）由 App 生成，额外参数不能覆盖它们。

## 兼容范围

这里的「任意」指遵循 OpenAI 兼容协议的模型/服务，而不是所有厂商的原生私有协议。原生 Anthropic Messages、Gemini generateContent 等协议需要单独的请求适配器；不能仅靠填写 URL 推断其完全不同的请求格式。
