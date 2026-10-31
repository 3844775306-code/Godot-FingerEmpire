class_name AIClock
extends RefCounted

# P1 基础设施：统一节拍器。
# 替代散落各处的 `_xxx_timer -= delta; if _xxx_timer <= 0: ...` 模式。
#
# 用法：
#	var clock := AIClock.new()
#	clock.add("retask", 3.0)
#	clock.add("defense", 1.0, 0.35)	# phase 0~1，用于在周期内错开首次触发
#	func _tick(d: float) -> void:
#		clock.advance(d)
#		if clock.due("retask"):
#			...
#
# 设计要点：
#  - phase 用于把不同 AI / 不同模块错开，避免所有定时器在同一帧集中触发（削峰）；
#  - 触发后 `timer += interval` 而不是 `timer = interval`，长时间运行不累积漂移；
#  - 严重掉帧时最多补触发一次，不连续追帧（避免一帧内爆发多次决策）；
#  - 纯逻辑，不读墙钟；确定性模式下由调用方传入 SimTime 的 delta。

const EPSILON: float = 0.000001

var _entries: Dictionary = {}
var _paused: bool = false

func add(key: String, interval: float, phase: float = 0.0) -> void:
	var iv: float = maxf(interval, 0.0001)
	var offset: float = clampf(phase, 0.0, 1.0) * iv
	_entries[key] = {"interval": iv, "timer": offset, "phase": offset, "fires": 0}

func remove(key: String) -> void:
	_entries.erase(key)

func has(key: String) -> bool:
	return _entries.has(key)

func remaining(key: String) -> float:
	var e = _entries.get(key)
	return float(e["timer"]) if e != null else 0.0

func interval_of(key: String) -> float:
	var e = _entries.get(key)
	return float(e["interval"]) if e != null else 0.0

func reset(key: String, phase: float = 0.0) -> void:
	var e = _entries.get(key)
	if e == null:
		return
	var iv: float = float(e["interval"])
	e["phase"] = clampf(phase, 0.0, 1.0) * iv
	e["timer"] = e["phase"]

func pause(value: bool) -> void:
	_paused = value

func is_paused() -> bool:
	return _paused

func advance(delta: float) -> void:
	if _paused or delta <= 0.0:
		return
	for key in _entries:
		var e: Dictionary = _entries[key]
		e["timer"] = float(e["timer"]) - delta

# 到点返回 true 并推进周期；同一 key 每个周期只返回一次 true。
func due(key: String) -> bool:
	if _paused:
		return false
	var e = _entries.get(key)
	if e == null:
		return false
	if float(e["timer"]) > EPSILON:
		return false
	var iv: float = float(e["interval"])
	e["timer"] = float(e["timer"]) + iv
	if float(e["timer"]) <= 0.0:
		# 掉帧超过一个周期：直接对齐到下一个周期，不连续补触发。
		e["timer"] = iv
	e["fires"] = int(e["fires"]) + 1
	# Dictionary 是引用类型，写回只为语义清晰（某些 GDScript 版本对嵌套写入更稳妥）。
	_entries[key] = e
	return true

func next_in(key: String) -> float:
	var e = _entries.get(key)
	return float(e["timer"]) if e != null else -1.0

func snapshot() -> Dictionary:
	var out: Dictionary = {}
	for key in _entries:
		var e: Dictionary = _entries[key]
		out[key] = {"interval": float(e["interval"]), "timer": float(e["timer"]), "fires": int(e["fires"])}
	return out
