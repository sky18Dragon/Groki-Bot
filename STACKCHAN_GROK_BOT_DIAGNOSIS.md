# StackChan 接入 Grok Bot：问题与进度记录

更新日期：2026-10-15（Australia/Sydney）  
项目基线：`fb49073`，ESP-IDF 5.5.3  
设备：M5Stack StackChan，CoreS3 + M5/Takao 底座；最近使用的串口为 `/dev/cu.usbmodem2101`

## 当前状态

- CoreS3 已能启动并显示 Groki 画面，原先的黑屏与反复蜂鸣已解除。Wi-Fi、BLE 设置和 XiaoZhi 地址曾配置成功。
- Grok Bot 桌面应用中的目标智能体是“小张”。本机 HTTP 代理目前仍监听 `127.0.0.1:18770`；设备侧 XiaoZhi 网关应监听 `8765`，**本次记录时该端口没有监听进程**。因此最新串口日志中的 `Error connecting to host 192.168.9.236:8765` 与当前网关未运行一致。
- 先前在网关运行时，“Hi 小张”唤醒词曾命中，Gemini Live 曾生成回复，设备也曾收到 `tts start` 与音频数据。但用户听不到回答，旧版固件播放时出现 `ALLOC_FAIL size=512`，同时 DMA 最大连续空块只有 432–480 字节。
- **最新固件已经编译并刷入，但语音播放尚未验证成功。** 最新串口监测期间没有再记录到 `ALLOC_FAIL` 或 `task_wdt`，也没有记录到 `speaker ready`、`speaking` 或用户听到声音。那段时间 WebSocket 频繁断开，之后网关又停止，播放路径没有得到有效覆盖。
- 尚无证据证明设备语音消息已完整进入 Grok Bot 智能体“小张”并返回可听的回答。不能把 Gemini Live 自身的回复或 `/debug/inject-text` 的接受结果视为端到端成功。

## 固件进度与证据

| 阶段 | 处理 | 实测结果 |
| --- | --- | --- |
| 初始命令行刷写 | 从本仓库构建 CoreS3 固件并刷写 | 黑屏、蜂鸣恢复为 Groki 画面。 |
| 内部 RAM 预留 96 KiB | `CONFIG_SPIRAM_MALLOC_RESERVE_INTERNAL=98304`，只刷写应用分区 | 仍无声；播放时 `ALLOC_FAIL size=512`，DMA 最大连续空块约 480 字节。 |
| 最新固件 | 播放环形缓冲每段从 4096 降为 2048 个样本；降低 XiaoZhi 模式喇叭 DMA 缓冲数量；CPU 设为 240 MHz；增加喇叭初始化与入队失败日志；发送任务主动让出 CPU | **已完成构建、`app-flash` 和写入哈希校验。** 启动时记录 `seg_buf reserved early: 3x4096 B internal`。未在成功播放时完成复测。 |

最新固件的 `build-local2-cores3/stackchan_idf.bin` 大小为 `0x3347b0` 字节，4 MiB 应用分区余量约 20%。`/private/tmp/groki-build4.log` 末尾为 `Project build complete`；`/private/tmp/groki-flash4.log` 末尾有 `Hash of data verified` 和复位完成。刷写命令使用 `app-flash`，没有擦除整片 Flash，以保留设备设置。上述 `/private/tmp` 日志属于临时文件，后续可能被系统清理。

最新固件的第一次串口监测见相邻工作目录 `../stackchan-diagnostics/firmware4-serial.log`：启动后内部 RAM 空闲约 20–21 KiB，DMA 最大连续空块约 5–6 KiB；曾发生多次 XiaoZhi 握手和随后 `audio send failed`。连接回收阶段 DMA 最大连续空块约 17 KiB。这比旧版播放时的 480 字节好，但测量场景不同，**不能据此判定播放故障已经修复**。

第二次串口日志 `../stackchan-diagnostics/firmware4-retest.log` 中，设备反复报告无法连接 `192.168.9.236:8765`。在旧网关会话停止后，本机检查确认 8765/8766 没有监听进程。重启网关的第一次尝试因包装脚本标准输入关闭而立即退出；已将 `../run_stackchan_gateway.py` 改为保持子进程标准输入管道，随后重启操作因用户要求暂停而中止，尚未验证该修正。Grok Bot HTTP 代理 18770 仍在监听。

## 当前工作区改动

- `sdkconfig.defaults.cores3`：保留 96 KiB 内部 RAM 预留；将 CoreS3 CPU 频率设为 240 MHz。
- `main/conversation_task.hpp`：三块播放缓存各由 8 KiB 减为 4 KiB，共减少约 12 KiB 内部 RAM 占用。
- `main/app_main.cpp`：XiaoZhi 模式的喇叭 DMA 缓冲数量从 16 降到 8，并保留启动和音频诊断逻辑。
- `main/conversation_task.cpp`：切换到喇叭时显式检查 `M5.Speaker.begin()`；记录 DMA 状态；检查 `playRaw()` 入队失败和麦克风录音失败。
- `components/M5Unified` 子模块：现有本地修改包含喇叭重采样状态、RTC 初始化以及 `Speaker_Class.cpp` 中 `playRaw()` 对初始化/任务创建失败返回 `false` 的修正。该子模块为脏工作区，勿直接重置。
- `components/conversation/xiaozhi_client.cpp`：每个编码后的发送块之间 `vTaskDelay(1)`，让调度器有机会运行空闲任务。
- `gateway/stackchan_mcp/gbot_client.py`、`gbot_http_proxy.py`：修正 CLI `--json` 参数位置，并以明确的智能体 ID 选择“小张”。
- `gateway/stackchan_mcp/gemini_live_bridge.py`：加入 `STACKCHAN_GEMINI_GOOGLE_SEARCH` 开关；本机关闭 Google Search 工具后，Gemini Live 曾能连接并生成回复。
- `gateway/tests/` 中相关代理和 Gemini 测试已更新，先前通过；最新固件没有在有效语音回复场景下通过设备验收。

`gateway/.env` 含 Gemini 密钥、StackChan 令牌及本机配置；本记录故意不写入其值，也不应将其提交到 Git。

## 仍需排查的问题

1. **恢复网关并稳定连接。** 先启动 `../run_stackchan_gateway.py`，确认 8765 监听、设备可持续连接，检查为何网关运行时仍出现频繁 WebSocket 断开和 `audio send failed`。包装脚本的标准输入修正尚未实测。
2. **验证真正的播放路径。** 在串口记录运行且连接稳定时触发一次语音回复，核对 `tts start`、`speaker ready`、`playRaw`、`spk_q`、DMA 最大连续空块、`ALLOC_FAIL`、`task_wdt` 和用户实际听感。只有这些证据齐全才能判断最新内存调整是否解决无声。
3. **验证“小张”端到端调用。** 确认设备录音进入网关、网关调用正确的 Grok Bot 智能体、回复回传并从喇叭播放。先前 `/debug/inject-text` 返回 `ok`，但连接随即掉线，没有形成播放证据。

## 参考资料与判断依据

- [M5Stack CoreS3 官方文档](https://docs.m5stack.com/en/core/CoreS3)：CoreS3 音频硬件与 240 MHz 能力。
- [Espressif ESP-IDF 5.5.3 外部 RAM 文档](https://docs.espressif.com/projects/esp-idf/en/v5.5.3/esp32s3/api-guides/external-ram.html)：内部 RAM 预留与 DMA 可用内存的关系。
- [Espressif ESP-IDF 5.5.3 I2S 文档](https://docs.espressif.com/projects/esp-idf/en/v5.5.3/esp32s3/api-reference/peripherals/i2s.html)：I2S 使用 DMA 缓冲。
- [Espressif ESP-IDF 5.5.3 任务看门狗文档](https://docs.espressif.com/projects/esp-idf/en/v5.5.3/esp32s3/api-reference/system/wdts.html)：空闲任务长期得不到运行会触发 `task_wdt`。

旧版 `ALLOC_FAIL size=512` 与喇叭初始化所需的内部 DMA 缓冲分配失败相符；它不能单凭大小证明为“DMA 描述符”分配失败。最新固件空闲 DMA 空间的改善尚需在真实播放时复核。

## 2026-10-15 18:45 续查结果

- 网关（8765/8766）和转发代理（18770）已重新启动；网关须保持标准输入打开（`tail -f /dev/null | python -m stackchan_mcp`），否则 stdio MCP 读到 EOF 会立即退出。
- **播放已验证。** 串口：`speaker ready: DMA free=13283 largest=6400`、`speaking (streaming)`、播放 94 个块、`tts stop`；无 `ALLOC_FAIL`，无 `task_wdt`，WebSocket 未断。听感仍需用户确认。
- **根因之一（已修）：** 代理用 `entry.id`（如 `t1s0`）给回复去重，但该 id 只是返回窗口内的轮次编号，窗口滑动后新回复会复用旧 id 被丢弃。已改用稳定的 `seq`（`gbot_client.entry_key`），并加回归测试。
- **根因之二（环境）：** 本机 `gbot` 每次调用 12–38 秒（Grok Bot 守护进程日志里有 ENOTFOUND/ECONNRESET/ETIMEDOUT，本机走 198.18.x 的代理 TUN），超过默认的 20 秒超时。已在 `gateway/.env` 加 `STACKCHAN_GBOT_SEND_TIMEOUT_S=75`、`STACKCHAN_GBOT_FIRST_TIMEOUT=90`。网络本身需另行排查。
- **端到端通过（文本注入）：** `ask_grokbot` → 代理 → 小张回复“收到”（约 25 秒）→ Gemini 向设备播报“小张已经回复了，说他收到了。”
- **仍未解决：** 设备 WebSocket 仍会周期性断开（`disconnect_count` 增长，另有 300 秒无消息的 Gemini 接收停滞重连）；真人对着麦克风说“Hi 小张”的唤醒路径尚未实测。

## 2026-10-15 19:20 语音链路打通

- **机器人已能语音回答。** 之前不响应的根因：网关默认手动 VAD（等设备发 `listen stop` 才提交一句话），而固件在 mode=auto 下从不发送它（`xiaozhi_client.cpp`），Gemini 收不到“话说完了”。本机 `gateway/.env` 设置 `STACKCHAN_MANUAL_VAD=0` 后生效；`.env.example` 已补说明。
- **WebSocket 周期性断开的主要原因：** Mac 上 Clash 的 TUN（`utun4`）接管了去设备所在网段 `192.168.19.0/24` 的回程流量，TCP 无关闭帧地断开（日志 `rcvd=None sent=None`）。执行 `sudo route -n add -net 192.168.19.0/24 192.168.8.1` 后（重启失效），连接稳定超过 4 分钟，网关事件循环与接收队列均正常。长期方案：在 Clash 里让 `192.168.0.0/16` 直连并排除出 TUN。
- **回复成韩语：** 切到自动 VAD 后，噪声片段也会触发回复，指令只写“用用户的语言”，Gemini 误判成韩语。新增 `STACKCHAN_REPLY_LANGUAGE` 固定回复语言（本机设为台湾国语）。Gemini 语音不支持闽南语。
- 网关新增：断开原因日志（`rcvd/sent`）、`seq` 去重、`.env.example` 中的超时与 VAD 说明。测试 711 通过；`test_led_failure_does_not_break_tts_stream` 在改动前就失败，与本次无关。
- 仍待观察：唤醒词偶尔漏检；“Hi 小张”后的完整语音请求经 `ask_grokbot` 到小张的一次真人实测仍以文本注入为准。
