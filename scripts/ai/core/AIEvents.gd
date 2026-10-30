class_name AIEvents
extends RefCounted

# P1 基础设施：AI 事件队列。
#
# 目的：把"每 tick 重新全量扫描实体"变成"只处理发生变化的部分"。
# battle 侧在关键状态变化时 emit（实体死亡 / 建筑受损 / 生产完成 / 资源耗尽 / 发现敌人），
# Planner / Director 每 tick 用 take() 一次性取走并处理。
#
# 现阶段只提供容器与常量，尚未接入 battle 信号（属于 P2 世界模型的工作）；
# 提前落地是为了让后续模块有统一的写入口，避免又出现一堆 `if entity is Army` 全扫。

const UNIT_DIED: String = "unit_died"
const BUILDING_DAMAGED: String = "building_damaged"
const BUILDING_DESTROYED: String = "building_destroyed"
const TRAIN_FINISHED: String = "train_finished"
const RESOURCE_DEPLETED: String = "resource_depleted"
const ENEMY_SPOTTED: String = "enemy_spotted"

var _queue: Array = []
var _max: int = 512
var _dropped: int = 0
var _counts: Dictionary = {}

func emit(kind: String, payload: Dictionary = {}) -> void:
	if _queue.size() >= _max:
		_queue.pop_front()
		_dropped += 1
	payload["kind"] = kind
	_queue.append(payload)
	_counts[kind] = int(_counts.get(kind, 0)) + 1

func take() -> Array:
	var out: Array = _queue
	_queue = []
	return out

func size() -> int:
	return _queue.size()

func dropped() -> int:
	return _dropped

func counts() -> Dictionary:
	return _counts.duplicate()

func clear() -> void:
	_queue.clear()
	_dropped = 0
	_counts.clear()
