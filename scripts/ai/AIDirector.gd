extends RefCounted

# P3.2 AIDirector（影子阶段）
#
# 职责：每轮拿"一份快照（AISituation）+ 一本账（RoleLedger）"，算出这一轮 AI 想做什么
#（意图 Intent），并把意图与真实决策并排打印出来做对照。
#
# 现阶段**只观测、不接管**：不派单、不设置角色、不写任何元数据，因此对局行为不变。
# 后续步骤会把各模块的选择逻辑逐个搬进这里，最终由 Director 统一出意图、Executor 统一执行。
#
# 意图格式（Dictionary）：
#   kind: String   —— defend / push / reinforce / gather / idle_warn
#   priority: int  —— 0 最高，数字越大越不急
#   count: int     —— 建议投入的单位数（0 表示"提示类"意图，不涉及数量）
#   note: String   —— 人读的说明，便于对照日志

# 角色号必须与 AI.gd 的 UnitRole 枚举一致（这里只读账本，不能反向 preload AI.gd，否则循环依赖）。
const ROLE_GARRISON: int = 2
const ROLE_WALL: int = 3
const ROLE_HOME_GUARD: int = 4
const ROLE_BUILDING_DEFENSE: int = 6
const ROLE_RAID: int = 8
const ROLE_FIELD: int = 9
const ROLE_SIEGE: int = 10

const KIND_DEFEND: String = "defend"
const KIND_PUSH: String = "push"
const KIND_REINFORCE: String = "reinforce"
const KIND_GATHER: String = "gather"
const KIND_IDLE_WARN: String = "idle_warn"

# 与 AIConfig 的攻击阈值保持一致的兜底值；实际优先读 AI 的配置。
const FALLBACK_ASSAULT_LAND: int = 12
const FALLBACK_WORKER_TARGET: int = 8
# 闲置比例超过这个值就提示"兵没被派出去"。
const IDLE_WARN_RATIO: float = 0.25

var ai = null
var _tick_count: int = 0
var _log_timer: float = 0.0
var _intents: Array = []
var _kind_counts: Dictionary = {}
var _last_summary: String = ""

func setup(controller) -> void:
	ai = controller

# 每轮调用一次（低频，跟随 AISituation 的对账节奏）。
func tick(situation, ledger, now: float) -> void:
	if situation == null:
		return
	_tick_count += 1
	_intents = _build_intents(situation, ledger)
	_kind_counts.clear()
	for it in _intents:
		var k: String = String(it.get("kind", "?"))
		_kind_counts[k] = int(_kind_counts.get(k, 0)) + 1
	_last_summary = _format_intents()
	# 日志节流：前 3 轮 + 每 20 轮一次，避免刷屏。
	if _tick_count <= 3 or _tick_count % 20 == 0:
		print("[DIRECTOR-V2] t=%.0f %s" % [now, _last_summary])

func _build_intents(situation, ledger) -> Array:
	var out: Array = []
	var land: int = int(situation.own_land_count)
	var workers: int = int(situation.own_worker_count)
	var visible: int = int(situation.visible_enemies.size())

	# 1) 防守：视野里有敌人，且账本里守军/守墙/回防的占用不足。
	var assign: int = 0
	if ledger != null:
		assign = int(ledger.count_of("director", ROLE_WALL)) \
			+ int(ledger.count_of("director", ROLE_HOME_GUARD)) \
			+ int(ledger.count_of("director", ROLE_BUILDING_DEFENSE)) \
			+ int(ledger.count_of("director", ROLE_GARRISON))
	if visible > 0 and assign < visible:
		out.append({
			"kind": KIND_DEFEND, "priority": 0,
			"count": maxi(1, visible - assign),
			"note": "可见敌人 %d > 已分配守军 %d" % [visible, assign],
		})

	# 2) 推进：陆军规模达到进攻阈值，且账本里主攻/突袭的兵不够多。
	var field: int = 0
	if ledger != null:
		field = int(ledger.count_of("director", ROLE_FIELD)) \
			+ int(ledger.count_of("director", ROLE_RAID)) \
			+ int(ledger.count_of("director", ROLE_SIEGE))
	var assault_land: int = FALLBACK_ASSAULT_LAND
	if ai != null and ai.has_method("_effective_assault_threshold"):
		assault_land = int(ai._effective_assault_threshold())
	if land >= assault_land and field < land - assign:
		out.append({
			"kind": KIND_PUSH, "priority": 1,
			"count": land - assign - field,
			"note": "陆军 %d ≥ 阈值 %d，主攻占比 %d/%d" % [land, assault_land, field, land],
		})
	elif land < assault_land:
		out.append({
			"kind": KIND_REINFORCE, "priority": 2,
			"count": assault_land - land,
			"note": "距进攻阈值还差 %d 兵" % (assault_land - land),
		})

	# 3) 农民：数量不足时提示补农（具体训练仍由 WorkerDirector 决策）。
	var worker_target: int = FALLBACK_WORKER_TARGET
	if ai != null:
		worker_target = int(ai.desired_worker_count)
	if workers < worker_target:
		out.append({
			"kind": KIND_GATHER, "priority": 2,
			"count": worker_target - workers,
			"note": "农民 %d < 目标 %d" % [workers, worker_target],
		})

	# 4) 闲置告警：陆军不少但账本几乎没有占用，说明派单链路漏了。
	if land > 0 and (assign + field) == 0 and float(land) >= 4.0:
		out.append({
			"kind": KIND_IDLE_WARN, "priority": 3,
			"count": land,
			"note": "陆军 %d 但账本零占用" % land,
		})
	elif land >= 4 and float(assign + field) / float(land) < IDLE_WARN_RATIO:
		out.append({
			"kind": KIND_IDLE_WARN, "priority": 3,
			"count": land - assign - field,
			"note": "占用率 %d%% < %d%%" % [int(100.0 * float(assign + field) / float(land)), int(IDLE_WARN_RATIO * 100.0)],
		})
	return out

func _format_intents() -> String:
	if _intents.is_empty():
		return "intents=0"
	var parts: Array = []
	for it in _intents:
		parts.append("%s(%d)" % [String(it.get("kind", "?")), int(it.get("count", 0))])
	return "intents=%d %s" % [_intents.size(), " ".join(parts)]

func intents() -> Array:
	return _intents

func intents_by_kind() -> Dictionary:
	return _kind_counts.duplicate()

func summary() -> String:
	return _last_summary

func debug_snapshot() -> Dictionary:
	return {
		"ticks": _tick_count,
		"intents": _intents.size(),
		"kinds": _kind_counts.duplicate(),
		"summary": _last_summary,
	}
