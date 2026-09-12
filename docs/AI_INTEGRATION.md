# AI 接口接入

首页或 AI 教练 → AI 接口设置 → 选择服务商、模型并填写 API Key → 测试连接 → 保存并返回。在挥杆工作台打开 AI 教练，点击“解读本次挥杆”或输入问题。

支持 OpenAI Chat Completions、Claude Messages、Gemini OpenAI 兼容接口、DeepSeek 和自定义 HTTPS OpenAI 兼容地址。新配置默认 DeepSeek / deepseek-flash，已有配置保留用户模型。可切换 Flash、Pro 和深入分析；实际模型权限由服务商决定。

Key 仅保存到设备 Keychain，绑定服务商和地址；不写入源码、日志或分析文件。不跟随 HTTP 重定向。连接测试和对话会调用真实 API 并可能产生费用。

## 数据与回答

请求包含当前挥杆所有分析帧的指标、手腕轨迹、可用值统计、缺失原因、关键帧来源、检测质量、适用教练规则、当前帧关节以及最近 20 条有效历史消息。旧分析版本消息和未连接时保存的问题不会自动发送。视频、其他挥杆、显示补全坐标和全程原始关节点不上传；内容超限明确报错。

自动阶段为候选，需要逐帧复核。未复核时 AI 优先帮助确认选片、阶段和可见度，不能据此诊断下杆顺序等动作问题；缺失指标不补数值。全程统计与关键帧数值分开解释，不编造标准角度、评分或进步比较。提示词约束不能保证每次回答完全正确，仍需结合视频复核。

支持连续提问、停止生成、失败重试、本地历史、连接测试及认证、额度、超时提示。DeepSeek 默认关闭思考、最多 2048 输出 token；深入分析启用低档思考、最多 8192 token。

## 开发验证

核心 Swift Package 和 iOS 集成测试覆盖请求参数、错误处理、历史过滤、裁剪播放时钟、保存与重试。真实 API 测试 `LiveDeepSeekTests` 默认跳过；仅在真机设置 `COACHME_LIVE_DEEPSEEK=1` 后，使用设备保存的 Key 和最新挥杆执行一次请求。回答及不含密钥的摘要写入 App diagnostics，供人工检查。

## 官方接口

- [OpenAI](https://developers.openai.com/api/reference/resources/chat)
- [Claude](https://platform.claude.com/docs/en/api/messages/create)
- [Gemini](https://ai.google.dev/gemini-api/docs/openai)
- [DeepSeek](https://api-docs.deepseek.com/api/create-chat-completion/)
- [DeepSeek 模型](https://api-docs.deepseek.com/quick_start/pricing/)
