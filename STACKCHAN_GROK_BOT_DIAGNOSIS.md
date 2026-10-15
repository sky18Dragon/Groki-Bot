# StackChan 接入 Grok Bot：调试记录与运行手册

更新日期：2026-10-15（Australia/Sydney）  
设备：M5Stack StackChan，CoreS3 + M5/Takao 底座；ESP-IDF 5.5.3

## 当前状态

语音链路已经打通：对机器人说“Hi 小张”，听到唤醒提示音，说出请求，Gemini 把任务交给 Grok Bot 智能体“小张”，小张的回复由机器人用台湾国语念出来。

```
机器人 ──ws://<电脑 IP>:8765──▶ 网关 ──▶ Gemini Live
                                  │
                                  └─ ask_grokbot ─▶ 转发服务 127.0.0.1:18770 ─▶ gbot ─▶ 小张
```

仍待处理：

- 唤醒词“Hi 小张”偶尔漏检（一次连说 3 遍只命中 1 遍），还没有调优。
- Grok Bot 应用到后端的连接不稳定，`gbot` 单次调用要 10 到 40 秒，所以智能体回复偏慢。
- 给设备所在网段加的路由重启后失效，见下文。

## 逐个问题的根因与修复

| 现象 | 根因 | 处理 |
| --- | --- | --- |
| 喇叭无声，串口 `ALLOC_FAIL size=512` | 内部 RAM 里能做 DMA 的连续空间只有几百字节，喇叭初始化分配失败 | 固件：预留 96 KiB 内部 RAM、播放缓存各由 8 KiB 减到 4 KiB、XiaoZhi 模式喇叭 DMA 缓冲从 16 降到 8、CPU 240 MHz、发送音频时让出 CPU。提交 `74bc7ad`。播放时串口可见 `speaker ready`、`speaking (streaming)`，无 `ALLOC_FAIL` |
| 小张回复了，但转发服务报超时 | 回复条目的 `id`（如 `t1s0`）只是返回窗口内的轮次编号，窗口滑动后新回复会复用旧 id，被当作已读而丢弃 | 用稳定的 `seq` 去重（`gbot_client.entry_key`），并加回归测试。提交 `4e47d43` |
| `gbot` 调用超时 | 本机 `gbot` 每次 10 到 40 秒（Grok Bot 守护进程日志里有 ENOTFOUND/ECONNRESET/ETIMEDOUT） | `gateway/.env` 里加 `STACKCHAN_GBOT_SEND_TIMEOUT_S=75`、`STACKCHAN_GBOT_FIRST_TIMEOUT=90`。网络本身需另行排查 |
| 设备 WebSocket 每隔十几秒断开 | 电脑上 Clash 的 TUN（`utun4`）接走了去设备网段 `192.168.19.0/24` 的回程包，TCP 无关闭帧地断开（网关日志 `rcvd=None sent=None`，固件 `transport_poll_write`） | `sudo route -n add -net 192.168.19.0/24 192.168.8.1`，之后连接稳定超过 4 分钟。该路由重启失效；长期做法是在 Clash 里让 `192.168.0.0/16` 直连。网关事件循环和接收队列经检查正常 |
| 唤醒后机器人不回答 | 网关默认手动 VAD，等设备发 `listen stop` 才提交一句话；固件在 mode=auto 下从不发送它 | `gateway/.env` 设 `STACKCHAN_MANUAL_VAD=0`，由 Gemini 自己判断说完 |
| 机器人用韩语回答 | 自动断句后，噪声片段也会触发回复，指令只写“用用户的语言”，Gemini 误判语言 | 新增 `STACKCHAN_REPLY_LANGUAGE`，本机设为台湾国语。Gemini 语音不支持闽南语 |
| 网关一启动就退出 | stdio MCP 服务读到标准输入 EOF 就结束 | 启动时保持标准输入打开，例如 `tail -f /dev/null \| uv run python -m stackchan_mcp`，或用 `gateway/scripts/run_stackchan_gateway_launchd.sh` |
| 机器人“没有声音” | 一次是喇叭被误关（静音） | 先查设备音量 `curl http://<机器人 IP>/api/speaker-volume` 和屏幕上的静音状态 |

## 运行手册

启动（在 `gateway/` 下，不要让网关占用机器人的串口）：

```sh
export NO_PROXY="*" STACKCHAN_USB_DISABLE=1
uv run stackchan-gbot-proxy &                       # Grok Bot 转发服务，监听 127.0.0.1:18770
tail -f /dev/null | uv run python -u -m stackchan_mcp   # 网关，监听 8765 / 8766
```

检查：

```sh
route -n get <机器人 IP> | grep interface            # 应是局域网网卡，不是 utun*
curl -s http://127.0.0.1:8766/debug/status           # device.connected、wake_gate、gemini
curl -s http://127.0.0.1:18770/health                # 转发服务
```

不用开口也能测完整链路（需要 `STACKCHAN_TOKEN`）：

```sh
curl -s -X POST http://127.0.0.1:8766/debug/inject-text \
  -H "Authorization: Bearer $STACKCHAN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"text":"请把这个任务交给小张：让小张回复收到两个字。"}'
```

串口里确认播放：`tts start` 之后应出现 `speaker ready`、`speaking`，不应有 `ALLOC_FAIL` 或 `task_wdt`。

`gateway/.env` 含 Gemini 密钥和设备令牌，已被 gitignore，不要提交，也不要贴到日志或文档里。

## 本地工作区注意事项

- `components/M5Unified` 子模块里有本地改动（喇叭重采样状态、RTC 初始化、`Speaker_Class.cpp` 中 `playRaw()` 对初始化或任务创建失败返回 `false`）。这些改动没有提交到仓库，其他环境需要先运行 `tools/apply-m5-patches.sh` 或自行带上。不要直接重置这个子模块。
- 网关设置项和排查表已写入 `gateway/README.md`、`gateway/README.zh-CN.md` 和 `gateway/.env.example`。

## 参考资料

- [M5Stack CoreS3 官方文档](https://docs.m5stack.com/en/core/CoreS3)
- [ESP-IDF 5.5.3 外部 RAM 文档](https://docs.espressif.com/projects/esp-idf/en/v5.5.3/esp32s3/api-guides/external-ram.html)：内部 RAM 预留与 DMA 可用内存的关系
- [ESP-IDF 5.5.3 I2S 文档](https://docs.espressif.com/projects/esp-idf/en/v5.5.3/esp32s3/api-reference/peripherals/i2s.html)
- [ESP-IDF 5.5.3 任务看门狗文档](https://docs.espressif.com/projects/esp-idf/en/v5.5.3/esp32s3/api-reference/system/wdts.html)
