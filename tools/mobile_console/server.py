#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""FingerEmpire 手机远程控制台（局域网 HTTP 服务）

用途：在手机上用浏览器给本机的工作区下"改代码"需求，AI 执行后在页面上看到结果。

启动：
    python tools/mobile_console/server.py
    python tools/mobile_console/server.py --port 8765

手机访问：
    http://<本机局域网IP>:8765/?t=<token>
    （token 见 tools/mobile_console/token.txt，首次启动自动生成）

说明：
    - 只监听局域网，不做公网穿透；需要在外网用时请另配 Cloudflare Tunnel / Tailscale。
    - 任务队列存 tools/mobile_console/queue.json，由 AI 侧用 task_tool.py 领取和回填。
"""

import argparse
import json
import os
import secrets
import sys

# 让中文输出在 Windows 控制台也不乱码
try:
	sys.stdout.reconfigure(encoding="utf-8")
	sys.stderr.reconfigure(encoding="utf-8")
except Exception:
	pass
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
QUEUE_PATH = os.path.join(BASE_DIR, "queue.json")
TOKEN_PATH = os.path.join(BASE_DIR, "token.txt")

_queue_lock = threading.Lock()


def load_token() -> str:
	if os.path.exists(TOKEN_PATH):
		with open(TOKEN_PATH, "r", encoding="utf-8") as f:
			token = f.read().strip()
		if token:
			return token
	token = secrets.token_urlsafe(12)
	with open(TOKEN_PATH, "w", encoding="utf-8") as f:
		f.write(token)
	return token


def load_queue() -> dict:
	if not os.path.exists(QUEUE_PATH):
		return {"next_id": 1, "tasks": []}
	try:
		with open(QUEUE_PATH, "r", encoding="utf-8") as f:
			data = json.load(f)
		if not isinstance(data, dict) or "tasks" not in data:
			raise ValueError("bad queue")
		return data
	except Exception:
		return {"next_id": 1, "tasks": []}


def save_queue(data: dict) -> None:
	tmp = QUEUE_PATH + ".tmp"
	with open(tmp, "w", encoding="utf-8") as f:
		json.dump(data, f, ensure_ascii=False, indent=2)
	os.replace(tmp, QUEUE_PATH)


INDEX_HTML = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<title>FingerEmpire 远程控制台</title>
<style>
	* { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
	body { margin: 0; background: #14161c; color: #e4e6ec;
	       font-family: -apple-system, "Microsoft YaHei UI", "PingFang SC", sans-serif; }
	header { padding: 14px 16px; background: #1c1f27; border-bottom: 1px solid #2a2e39;
	         display: flex; align-items: center; justify-content: space-between; }
	header h1 { margin: 0; font-size: 16px; font-weight: 600; }
	header .dot { width: 8px; height: 8px; border-radius: 4px; background: #62c98c;
	              display: inline-block; margin-right: 6px; }
	main { padding: 14px 16px 40px; }
	.card { background: #1c1f27; border: 1px solid #2a2e39; border-radius: 10px;
	        padding: 14px; margin-bottom: 14px; }
	textarea { width: 100%; min-height: 96px; resize: vertical; background: #12141a;
	           color: #e4e6ec; border: 1px solid #2f3441; border-radius: 8px;
	           padding: 10px; font-size: 15px; line-height: 1.5; font-family: inherit; }
	textarea:focus { outline: none; border-color: #4b8f68; }
	button { width: 100%; margin-top: 10px; padding: 13px; font-size: 16px; font-weight: 600;
	         color: #06110a; background: #6ad092; border: 0; border-radius: 8px; }
	button:active { background: #57b87c; }
	button:disabled { background: #3a4048; color: #8b909b; }
	.task { border-left: 3px solid #3a4048; padding: 10px 12px; margin-bottom: 10px;
	        background: #171a21; border-radius: 6px; }
	.task.pending { border-left-color: #e0b64a; }
	.task.running { border-left-color: #4ea8de; }
	.task.done { border-left-color: #62c98c; }
	.task.failed { border-left-color: #e05a5a; }
	.task .meta { font-size: 12px; color: #8b909b; margin-bottom: 6px; }
	.task .text { font-size: 14px; white-space: pre-wrap; word-break: break-word; }
	.task .result { font-size: 13px; color: #b8c0cc; margin-top: 8px; padding-top: 8px;
	                border-top: 1px dashed #2a2e39; white-space: pre-wrap; word-break: break-word; }
	.empty { color: #6d7583; font-size: 14px; text-align: center; padding: 24px 0; }
	.hint { font-size: 12px; color: #6d7583; margin-top: 10px; line-height: 1.6; }
</style>
</head>
<body>
<header>
	<h1><span class="dot"></span>FingerEmpire 远程控制台</h1>
	<span id="clock" style="font-size:12px;color:#8b909b"></span>
</header>
<main>
	<div class="card">
		<textarea id="cmd" placeholder="输入要让 AI 完成的需求，例如：&#10;把箭塔攻击力提高 20%&#10;修复船坞建造后没有采集船的问题"></textarea>
		<button id="send">发送给 AI</button>
		<div class="hint">发送后 AI 会在下一次检查时领取任务，完成后结果显示在下方。多次发送会排队执行。</div>
	</div>
	<div class="card">
		<div style="font-size:13px;color:#8b909b;margin-bottom:10px">任务记录</div>
		<div id="list"><div class="empty">还没有任务</div></div>
	</div>
</main>
<script>
(function () {
	const params = new URLSearchParams(location.search);
	let token = params.get('t') || localStorage.getItem('fe_token') || '';
	if (params.get('t')) localStorage.setItem('fe_token', params.get('t'));
	const $ = (id) => document.getElementById(id);

	function headers(extra) {
		const h = { 'Content-Type': 'application/json' };
		if (token) h['X-Token'] = token;
		return Object.assign(h, extra || {});
	}

	function fmtTime(ts) {
		if (!ts) return '';
		const d = new Date(ts * 1000);
		const p = (n) => String(n).padStart(2, '0');
		return p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
	}

	const STATUS_TEXT = { pending: '等待中', running: '执行中', done: '已完成', failed: '失败' };

	function render(tasks) {
		const list = $('list');
		if (!tasks || !tasks.length) {
			list.innerHTML = '<div class="empty">还没有任务</div>';
			return;
		}
		list.innerHTML = tasks.slice().reverse().map((t) => {
			const st = t.status || 'pending';
			let html = '<div class="task ' + st + '">';
			html += '<div class="meta">#' + t.id + ' · ' + (STATUS_TEXT[st] || st) + ' · ' + fmtTime(t.created) + '</div>';
			html += '<div class="text">' + escapeHtml(t.text || '') + '</div>';
			if (t.result) html += '<div class="result">' + escapeHtml(t.result) + '</div>';
			html += '</div>';
			return html;
		}).join('');
	}

	function escapeHtml(s) {
		return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
	}

	async function refresh() {
		if (!token) return;
		try {
			const r = await fetch('/api/state', { headers: headers() });
			if (!r.ok) return;
			const data = await r.json();
			render(data.tasks);
		} catch (e) { /* 服务没起来时静默 */ }
	}

	$('send').addEventListener('click', async () => {
		const text = $('cmd').value.trim();
		if (!text) return;
		$('send').disabled = true;
		$('send').textContent = '发送中…';
		try {
			const r = await fetch('/api/command', {
				method: 'POST',
				headers: headers(),
				body: JSON.stringify({ text: text })
			});
			if (r.ok) {
				$('cmd').value = '';
				await refresh();
			} else {
				alert('发送失败：' + r.status);
			}
		} catch (e) {
			alert('发送失败，请确认手机和电脑在同一网络');
		} finally {
			$('send').disabled = false;
			$('send').textContent = '发送给 AI';
		}
	});

	setInterval(refresh, 2000);
	refresh();
	setInterval(() => {
		const d = new Date();
		const p = (n) => String(n).padStart(2, '0');
		$('clock').textContent = p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
	}, 1000);
})();
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
	server_version = "FingerEmpireConsole/1.0"

	def _token_ok(self) -> bool:
		query = parse_qs(urlparse(self.path).query)
		token = (query.get("t") or [None])[0] or self.headers.get("X-Token") or ""
		return token == self.server.token

	def _send(self, status: int, body: bytes, content_type: str) -> None:
		self.send_response(status)
		self.send_header("Content-Type", content_type)
		self.send_header("Content-Length", str(len(body)))
		self.send_header("Cache-Control", "no-store")
		self.end_headers()
		self.wfile.write(body)

	def _json(self, status: int, obj: dict) -> None:
		self._send(status, json.dumps(obj, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")

	def do_GET(self) -> None:
		path = urlparse(self.path).path
		if path in ("/", "/index.html"):
			# 页面本身不校验 token，token 由页面脚本从 URL 取；无 token 时页面会提示
			self._send(200, INDEX_HTML.encode("utf-8"), "text/html; charset=utf-8")
			return
		if path == "/api/state":
			if not self._token_ok():
				self._json(403, {"error": "bad token"})
				return
			with _queue_lock:
				data = load_queue()
			self._json(200, {"tasks": data.get("tasks", [])})
			return
		if path == "/api/ping":
			self._json(200, {"ok": True, "time": int(time.time())})
			return
		self._json(404, {"error": "not found"})

	def do_POST(self) -> None:
		path = urlparse(self.path).path
		length = int(self.headers.get("Content-Length") or 0)
		raw = self.rfile.read(length) if length else b"{}"
		try:
			payload = json.loads(raw.decode("utf-8") or "{}")
		except Exception:
			self._json(400, {"error": "bad json"})
			return

		if path == "/api/command":
			if not self._token_ok():
				self._json(403, {"error": "bad token"})
				return
			text = str(payload.get("text", "")).strip()
			if not text:
				self._json(400, {"error": "empty text"})
				return
			with _queue_lock:
				data = load_queue()
				tid = int(data.get("next_id", 1))
				data["next_id"] = tid + 1
				data["tasks"].append({
					"id": tid,
					"text": text,
					"created": int(time.time()),
					"status": "pending",
					"result": "",
					"started": 0,
					"finished": 0,
				})
				save_queue(data)
			self._json(200, {"ok": True, "id": tid})
			return

		self._json(404, {"error": "not found"})

	def log_message(self, fmt: str, *args) -> None:
		# 只打印关键信息，避免刷屏
		sys.stderr.write("[console] " + (fmt % args) + "\n")


def main() -> None:
	parser = argparse.ArgumentParser(description="FingerEmpire 手机远程控制台")
	parser.add_argument("--port", type=int, default=8765)
	parser.add_argument("--host", default="0.0.0.0")
	args = parser.parse_args()

	token = load_token()
	httpd = ThreadingHTTPServer((args.host, args.port), Handler)
	httpd.token = token  # type: ignore[attr-defined]

	print("=" * 60)
	print("FingerEmpire 手机远程控制台已启动")
	print(f"  token: {token}")
	print(f"  本机访问: http://127.0.0.1:{args.port}/?t={token}")
	for ip in _local_ips():
		print(f"  手机访问: http://{ip}:{args.port}/?t={token}")
	print("  Ctrl+C 停止")
	print("=" * 60, flush=True)

	try:
		httpd.serve_forever()
	except KeyboardInterrupt:
		print("\n已停止")


def _local_ips() -> list:
	import socket
	ips = []
	try:
		hostname = socket.gethostname()
		for info in socket.getaddrinfo(hostname, None, socket.AF_INET):
			ip = info[4][0]
			if ip not in ips and not ip.startswith("127."):
				ips.append(ip)
	except Exception:
		pass
	if not ips:
		try:
			s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
			s.connect(("8.8.8.8", 80))
			ips.append(s.getsockname()[0])
			s.close()
		except Exception:
			pass
	return ips


if __name__ == "__main__":
	main()
