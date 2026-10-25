# 手机远程控制台

在手机上用浏览器给这个工作区下"改代码"需求，AI 执行完后在页面上看结果。

## 一、启动服务（电脑端）

```powershell
cd C:\Users\18749\Documents\finger-empire-
python tools/mobile_console/server.py
```

启动后终端会打印手机访问地址和 token，例如：

```
============================================================
FingerEmpire 手机远程控制台已启动
  token: Fb0268Ajqd6nGlc3
  本机访问: http://127.0.0.1:8765/?t=Fb0268Ajqd6nGlc3
  手机访问: http://183.172.51.49:8765/?t=Fb0268Ajqd6nGlc3
  Ctrl+C 停止
============================================================
```

token 也会存到 `tools/mobile_console/token.txt`，随时可以查看。

## 二、手机访问（同一 WiFi）

1. 手机连上和电脑**同一个 WiFi**；
2. 浏览器打开 `http://<电脑IP>:8765/?t=<token>`；
3. 在输入框里写下需求 → 点「发送给 AI」；
4. 任务进入队列，AI 领取执行后，页面每 2 秒自动刷新显示结果。

> 打不开的常见原因：Windows 防火墙拦截、手机连的是移动数据、电脑和手机不在同一网段。
> 防火墙放行：`New-NetFirewallRule -DisplayName "FingerEmpire Console" -Direction Inbound -LocalPort 8765 -Protocol TCP -Action Allow`

## 三、在外网用（可选穿透）

电脑通常没有公网 IP，出门在外需要穿透，几种免费方案：

| 方案 | 命令 | 说明 |
|---|---|---|
| Cloudflare Tunnel | `cloudflared tunnel --url http://127.0.0.1:8765` | 免费、免备案，会给你一个 `https://xxx.trycloudflare.com` 临时地址 |
| Tailscale | 装好后直接用 Tailscale 分配的 `100.x.x.x` 地址 | 最稳，但手机也要装 Tailscale |
| ngrok | `ngrok http 8765` | 免费版地址每次变化 |

穿透后手机访问 `https://<穿透域名>/?t=<token>` 即可。

## 四、AI 侧的任务处理

AI 通过 `task_tool.py` 领取和回填任务：

```powershell
python tools/mobile_console/task_tool.py pending        # 看还有哪些待处理
python tools/mobile_console/task_tool.py take 3         # 领取 #3（标记为执行中并打印内容）
python tools/mobile_console/task_tool.py done 3 "已把箭塔攻击力从 30 提到 36"   # 标记完成
python tools/mobile_console/task_tool.py fail 3 "改动会破坏数值平衡，已回退"     # 标记失败
```

手机页面只看状态和结果，所以 `done/fail` 的结果文字要写得让人能看懂。

## 五、文件说明

| 文件 | 作用 | 是否提交到 git |
|---|---|---|
| `server.py` | HTTP 服务 + 手机页面 | ✅ |
| `task_tool.py` | AI 侧任务队列工具 | ✅ |
| `queue.json` | 任务队列（运行时生成） | ❌ 已 gitignore |
| `token.txt` | 访问令牌（运行时生成） | ❌ 已 gitignore |

## 六、安全提醒

- 服务只做**局域网**用途时风险可控；一旦做了公网穿透，**token 就等同于操作权限**，不要外泄；
- 换 token：删掉 `token.txt` 后重启服务即可；
- 本服务只排队"需求文本"，不会直接执行任意命令——真正执行的是 AI，仍受工作区规则约束。
