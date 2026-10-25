#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AI 侧的任务队列工具（配合 tools/mobile_console/server.py 使用）

用法：
    python tools/mobile_console/task_tool.py list          # 列出所有任务
    python tools/mobile_console/task_tool.py pending       # 只看待处理任务
    python tools/mobile_console/task_tool.py take <id>     # 领取任务（标记 running 并打印内容）
    python tools/mobile_console/task_tool.py done <id> "结果摘要"   # 标记完成并写入结果
    python tools/mobile_console/task_tool.py fail <id> "失败原因"   # 标记失败并写入原因

说明：AI 完成任务后调用 done/fail，手机页面会自动刷新看到结果。
"""

import json
import os
import sys

# 让中文输出在 Windows 控制台也不乱码
try:
	sys.stdout.reconfigure(encoding="utf-8")
	sys.stderr.reconfigure(encoding="utf-8")
except Exception:
	pass
import time

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
QUEUE_PATH = os.path.join(BASE_DIR, "queue.json")


def load() -> dict:
	if not os.path.exists(QUEUE_PATH):
		return {"next_id": 1, "tasks": []}
	with open(QUEUE_PATH, "r", encoding="utf-8") as f:
		return json.load(f)


def save(data: dict) -> None:
	tmp = QUEUE_PATH + ".tmp"
	with open(tmp, "w", encoding="utf-8") as f:
		json.dump(data, f, ensure_ascii=False, indent=2)
	os.replace(tmp, QUEUE_PATH)


def find(data: dict, tid: int):
	for t in data["tasks"]:
		if int(t.get("id", -1)) == tid:
			return t
	return None


def cmd_list(data: dict) -> None:
	tasks = data.get("tasks", [])
	if not tasks:
		print("（队列为空）")
		return
	for t in tasks:
		print(f"#{t['id']} [{t.get('status')}] {t.get('text', '')[:80]}")
		if t.get("result"):
			print(f"    结果: {t['result'][:200]}")


def cmd_pending(data: dict) -> None:
	tasks = [t for t in data.get("tasks", []) if t.get("status") == "pending"]
	if not tasks:
		print("（没有待处理任务）")
		return
	for t in tasks:
		print(f"#{t['id']} {t.get('text', '')}")


def main() -> int:
	if len(sys.argv) < 2:
		print(__doc__)
		return 2
	action = sys.argv[1]
	data = load()

	if action == "list":
		cmd_list(data)
		return 0
	if action == "pending":
		cmd_pending(data)
		return 0
	if action in ("take", "done", "fail"):
		if len(sys.argv) < 3:
			print(f"用法: task_tool.py {action} <id> [结果]")
			return 2
		try:
			tid = int(sys.argv[2])
		except ValueError:
			print("id 必须是数字")
			return 2
		t = find(data, tid)
		if t is None:
			print(f"找不到任务 #{tid}")
			return 1
		if action == "take":
			t["status"] = "running"
			t["started"] = int(time.time())
			save(data)
			print(f"# 任务 #{tid}\n{t.get('text', '')}")
			return 0
		# done / fail
		result = " ".join(sys.argv[3:]).strip()
		t["status"] = "done" if action == "done" else "failed"
		t["result"] = result
		t["finished"] = int(time.time())
		save(data)
		print(f"任务 #{tid} 已标记为 {t['status']}")
		return 0

	print(f"未知动作: {action}")
	print(__doc__)
	return 2


if __name__ == "__main__":
	sys.exit(main())
