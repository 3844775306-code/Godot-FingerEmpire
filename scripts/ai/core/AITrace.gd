extends RefCounted

# A0 竖切：AI 决策链路追踪（默认关闭；关闭时只多一次 bool 判断，不做任何分配）。
#
# 目的：任何一条会改变对局状态的指令，都能回答五跳——
#   1 意图 intent → 2 规则 rule → 3 指令 command → 4 落地（由调用方记录）→ 5 结果 result
#
# 用法（调用方）：
#   AITraceScript.begin_round(tag, round, game_time)
#   AITraceScript.push_rule("military.reinforce_gap", {"gap": 3})
#   var seq := AITraceScript.command("recruit", "produce_unit", {"unit": 14, "rule": current_rule()})
#   AITraceScript.result(seq, ok, "" if ok else "no_gold")
#   AITraceScript.pop_rule()
#   AITraceScript.end_round()
#
# 输出：每行一个 JSON 对象（JSONL），可直接 grep / jq。

static var enabled: bool = false
static var _file: FileAccess = null
static var _path: String = ""
static var _round_ctx: Dictionary = {}
static var _rules: Array = []
static var _seq: int = 0
static var _pending: Dictionary = {}
static var _unattributed: int = 0
static var _counts: Dictionary = {}
static var _dropped: int = 0
const MAX_LINES_PER_ROUND: int = 400

static func configure(on: bool, path: String = "res://docs/ai-analysis/trace/trace.jsonl") -> void:
	enabled = on
	if not on:
		if _file != null:
			_file.close()
			_file = null
		return
	if _file != null:
		_file.close()
	_path = path
	var abs_dir: String = ProjectSettings.globalize_path(path.get_base_dir())
	DirAccess.make_dir_recursive_absolute(abs_dir)
	_file = FileAccess.open(path, FileAccess.WRITE)
	if _file == null:
		enabled = false
		push_warning("[AI-TRACE] 无法打开追踪文件: " + path)

static func is_enabled() -> bool:
	return enabled

static func begin_round(ai_tag: String, round_no: int, game_time: float) -> void:
	if not enabled:
		return
	_round_ctx = {
		"ai": ai_tag, "round": round_no,
		"t": snappedf(game_time, 0.01),
	}
	_rules.clear()
	_pending.clear()

static func end_round() -> void:
	if not enabled:
		return
	# 有指令没有结果 = 调用方漏记或中途 return，也要让它可见。
	for k in _pending.keys():
		var e: Dictionary = _pending[k]
		e["ok"] = null
		e["reject"] = "no_result_reported"
		_emit(e)
	_pending.clear()
	_rules.clear()

static func push_rule(id: String, data: Dictionary = {}) -> void:
	if not enabled:
		return
	_rules.append({"id": id, "data": data})

static func pop_rule() -> void:
	if not enabled:
		return
	if not _rules.is_empty():
		_rules.pop_back()

static func current_rule() -> String:
	if not enabled or _rules.is_empty():
		return ""
	return String(_rules.back()["id"])

static func current_rule_data() -> Dictionary:
	if not enabled or _rules.is_empty():
		return {}
	return _rules.back()["data"]

static func intent(kind: String, count: int, extra: Dictionary = {}) -> void:
	if not enabled:
		return
	var e: Dictionary = _entry("intent")
	e["intent"] = kind
	e["count"] = count
	e.merge(extra, true)
	_emit(e)

static func command(port: String, method: String, args: Dictionary) -> int:
	if not enabled:
		return -1
	_seq += 1
	var e: Dictionary = _entry("command")
	e["seq"] = _seq
	e["port"] = port
	e["method"] = method
	e["args"] = args
	var rule: String = String(args.get("rule", ""))
	if rule == "":
		rule = current_rule()
	if rule == "":
		rule = "unattributed"
		_unattributed += 1
	e["rule"] = rule
	_pending[_seq] = e
	return _seq

static func result(seq: int, ok: bool, reason: String = "", extra: Dictionary = {}) -> void:
	if not enabled or seq < 0:
		return
	var e = _pending.get(seq)
	if e == null:
		return
	e["ok"] = ok
	e["reject"] = reason
	e.merge(extra, true)
	_pending.erase(seq)
	_emit(e)

static func _entry(kind: String) -> Dictionary:
	var e: Dictionary = _round_ctx.duplicate()
	e["kind"] = kind
	e["rule"] = current_rule()
	return e

static func _emit(e: Dictionary) -> void:
	var kind: String = String(e.get("kind", "?"))
	var n: int = int(_counts.get(kind, 0)) + 1
	_counts[kind] = n
	if n > MAX_LINES_PER_ROUND:
		_dropped += 1
		return
	if _file != null:
		_file.store_line(JSON.stringify(e))
		_file.flush()

static func stats() -> Dictionary:
	return {
		"path": _path,
		"unattributed": _unattributed,
		"dropped": _dropped,
		"counts": _counts.duplicate(),
	}
