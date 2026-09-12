# AI 接口接入

首页或 AI 教练 → AI 接口设置 → 选择服务商、模型并填写 API Key → 测试连接 → 保存并返回。在挥杆工作台打开 AI 教练，点击“解读本次挥杆”或输入问题。

支持 OpenAI Chat Completions、Claude Messages、Gemini OpenAI 兼容接口、DeepSeek 和自定义 HTTPS OpenAI 兼容地址。新配置默认 DeepSeek / deepseek-flash，文本请求保留用户模型；发送截图时 DeepSeek 使用支持图片的 deepseek-flash。可切换 Flash、Pro 和深入分析；实际模型权限由服务商决定。

Key 仅保存到设备 Keychain，绑定服务商和地址；不写入源码、日志或分析文件。不跟随 HTTP 重定向。连接测试和对话会调用真实 API 并可能产生费用。

## 数据与回答

请求包含当前挥杆所有分析帧的指标、手腕轨迹、可用值统计、缺失原因、已复核阶段和未复核取样时间、检测质量、适用教练规则、当前帧关节以及最近 20 条有效历史消息。旧分析版本消息和未连接时保存的问题不会自动发送。默认开启“让教练看动作截图”：每次发送最多 13 张按时间排序的原视频 JPEG，最长边 1280，携带实际取帧时间；已复核图片带阶段名，未复核图片只提示自动取样、不附阶段猜测；没有关键帧时使用 13 张选段取样图，并明确阶段未知。截图准备失败会中止发送并提示重试，不会假装看过图。可在设置关闭截图发送。完整视频、其他挥杆、显示补全坐标和全程原始关节点不上传；内容超限明确报错。

画面优先、数据辅助。AI 采用资深教练带课的语气，聚焦一两个可见动作与可执行练习，不向用户念指标报告、不冒充持证教练。自动阶段为候选，以画面核对；静态图片不能证明完整动态顺序、速度和触球结果。遮挡或图片不覆盖一次挥杆时，自然说明并帮助选图。提示词约束不能保证每次回答完全正确，仍需结合视频复核。

支持连续提问、停止生成、失败重试、本地历史、连接测试及认证、额度、超时提示。DeepSeek 默认关闭思考、最多 2048 输出 token；深入分析启用低档思考、最多 8192 token。

## 开发验证

核心 Swift Package 和 iOS 集成测试覆盖请求参数、错误处理、历史过滤、裁剪播放时钟、保存与重试。真实 API 测试 `LiveDeepSeekTests` 默认跳过；仅在真机设置 `COACHME_LIVE_DEEPSEEK=1` 后，使用设备保存的 Key、最新挥杆和真实截图执行一次请求。回答及不含密钥的摘要写入 App diagnostics，供人工检查。

## 官方接口

- [OpenAI](https://developers.openai.com/api/reference/resources/chat)
- [Claude](https://platform.claude.com/docs/en/api/messages/create)
- [Gemini](https://ai.google.dev/gemini-api/docs/openai)
- [DeepSeek](https://api-docs.deepseek.com/api/create-chat-completion/)
- [DeepSeek 看图](https://api-docs.deepseek.com/guides/vision/)
- [DeepSeek 模型](https://api-docs.deepseek.com/quick_start/pricing/)

截图顺序：准备、上杆下段、上杆中段、上杆顶点、下杆中段、击球、收杆；每两个阶段中间增加一个按原视频时间取样的过渡画面，共 13 张。旧六阶段记录的上杆下段以准备到上杆中段的时间中点补位，保持未复核，不冒充模型检测。取帧使用真实视频帧，不插帧生成画面。
