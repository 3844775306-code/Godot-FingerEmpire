# scripts/scenes/DiplomacyManager.gd
# 乱斗模式（FFA）外交核心：结盟 / 进贡 / 决裂 / 背叛 状态机。
# 以 owner_peer_id 作为国别标识（每个乱斗国家拥有独立 team 与 owner），
# 本管理器只维护"国家关系表"，资源收支与实体生灭仍由 RTSBattleManager 负责。
#
# 规则要点：
#   - 默认联盟时长 3 分钟；双方每累计进贡 1000 资源（单次 500，发送方自选类型）
#     延长 30 秒，上限为从联盟建立起 5 分钟。
#   - 每个国家同一时刻至多维持一份联盟。
#   - 决裂 = 公开退出：该对（a,b）永久禁止再次结盟，不影响 a 与其他国家。
#   - 背叛 = 秘密退出：仅当其军队对盟友造成军事伤害时才被揭发；背叛方被全局标记，
#     永久禁止与任何国家结盟，且该对被永久禁止。
#   - 淘汰：城堡被摧毁的国家移出关系表；若幸存国仅剩 2 个仍结盟，系统强制决裂
#     （该对永久禁止），直到产生唯一胜者。
class_name DiplomacyManager
extends Node

# ==================== 常量 ====================
const ALLIANCE_BASE_SECONDS := 180.0    # 默认联盟时长 3 分钟
const TRIBUTE_STEP := 1000              # 每累计进贡 1000 资源…
const TRIBUTE_EXTEND_SECONDS := 30.0    # …延长 30 秒
const ALLIANCE_MAX_SECONDS := 300.0     # 从联盟建立起最长 5 分钟
const TRIBUTE_DELIVERY := 500           # 单次进贡数量（发送方自选资源类型）

# ==================== 状态表 ====================
var battle = null
# owner -> { "team": int, "nation": int, "is_human": bool, "alive": bool, "display_name": String, "color": Color }
var nations: Dictionary = {}
# "小owner|大owner" -> { "a": int, "b": int, "start_time": float, "expires_at": float, "total_tribute": int }
var alliances: Dictionary = {}
var ruptured_pairs: Dictionary = {}     # "小owner|大owner" -> true （该对永久禁止结盟）
var betrayers: Dictionary = {}          # owner -> true （该国永久禁止与任何国家结盟）
var _pending_proposals: Dictionary = {} # 提议方 owner -> 被提议方 owner（等待对方接受）

# 便捷引用：是否已在乱斗中启用（_init_ffa_single 之后才为 true）
var active: bool = false

# ==================== 初始化 ====================
func setup(battle_ref) -> void:
	battle = battle_ref
	active = true

# 注册一个国家（在 FFA 开局 spawn 各国时调用）
func register_nation(owner: int, team: int, nation: int, is_human: bool, color: Color) -> void:
	if owner < 0:
		return
	nations[owner] = {
		"team": team,
		"nation": nation,
		"is_human": is_human,
		"alive": true,
		"display_name": nation_display_name(nation),
		"color": color,
	}

# ==================== 查询接口 ====================
func is_nation_alive(owner: int) -> bool:
	return nations.has(owner) and nations[owner]["alive"]

func get_display_name(owner: int) -> String:
	if not nations.has(owner):
		return "已灭亡"
	return nations[owner]["display_name"]

func get_nation_of(owner: int) -> int:
	if not nations.has(owner):
		return -1
	return nations[owner]["nation"]

func is_human(owner: int) -> bool:
	return nations.has(owner) and nations[owner]["is_human"]

func get_team_of(owner: int) -> int:
	if not nations.has(owner):
		return -1
	return nations[owner]["team"]

func get_alive_owners() -> Array:
	var alive: Array = []
	for owner in nations.keys():
		if nations[owner]["alive"]:
			alive.append(owner)
	return alive

func get_alive_count() -> int:
	return get_alive_owners().size()

# owner 当前联盟的另一方；无则返回 -1
func get_ally(owner: int) -> int:
	for key in alliances:
		var al = alliances[key]
		if al["a"] == owner:
			return al["b"]
		if al["b"] == owner:
			return al["a"]
	return -1

func has_active_alliance(owner: int) -> bool:
	return get_ally(owner) != -1

# a、b 当前是否互为盟友（双方都存活且联盟表命中）
func is_ally(a: int, b: int) -> bool:
	if a == b or not is_nation_alive(a) or not is_nation_alive(b):
		return false
	return _pair_key(a, b) in alliances

# a、b 是否敌对（非盟友即敌对；默认乱斗各国互相敌对）
func is_hostile(a: int, b: int) -> bool:
	if a == b or not is_nation_alive(a) or not is_nation_alive(b):
		return false
	return not is_ally(a, b)

func is_ruptured_pair(a: int, b: int) -> bool:
	return _pair_key(a, b) in ruptured_pairs

func is_betrayer(owner: int) -> bool:
	return betrayers.has(owner)

# 联盟剩余时间（秒）；无联盟返回 -1
func alliance_remaining(owner: int) -> float:
	var key := _key_of(owner)
	if key == "":
		return -1.0
	return alliances[key]["expires_at"] - battle.game_time

# ==================== 结盟流程 ====================
# 返回不可结盟原因；"" 表示可以结盟
func alliance_block_reason(a: int, b: int) -> String:
	if a == b:
		return "不能与自己结盟"
	if not is_nation_alive(a):
		return "%s 已灭亡" % get_display_name(a)
	if not is_nation_alive(b):
		return "%s 已灭亡" % get_display_name(b)
	if has_active_alliance(a):
		return "%s 已有一份联盟" % get_display_name(a)
	if has_active_alliance(b):
		return "%s 已有一份联盟" % get_display_name(b)
	if is_betrayer(a):
		return "%s 是背叛者，无法再结盟" % get_display_name(a)
	if is_betrayer(b):
		return "%s 是背叛者，无法再结盟" % get_display_name(b)
	if is_ruptured_pair(a, b):
		return "%s 与 %s 决裂过，无法再结盟" % [get_display_name(a), get_display_name(b)]
	return ""

# 一方向另一方提议结盟；需对方 accept_alliance 才会正式成立
func propose_alliance(from_owner: int, to_owner: int) -> bool:
	if alliance_block_reason(from_owner, to_owner) != "":
		return false
	_pending_proposals[from_owner] = to_owner
	return true

# 返回曾向 owner 发起提议、尚待 owner 接受的国家
func get_incoming_proposals(owner: int) -> Array:
	var result: Array = []
	for proposer in _pending_proposals.keys():
		if _pending_proposals[proposer] == owner:
			result.append(proposer)
	return result

# 被提议方接受提议：acceptor 接受 proposer 的结盟请求
func accept_alliance(acceptor: int, proposer: int) -> bool:
	if _pending_proposals.get(proposer, -1) != acceptor:
		return false
	if alliance_block_reason(proposer, acceptor) != "":
		_pending_proposals.erase(proposer)
		return false
	_pending_proposals.erase(proposer)
	_create_alliance(proposer, acceptor, battle.game_time)
	return true

# 拒绝提议
func decline_alliance(owner: int, proposer: int) -> void:
	if _pending_proposals.get(proposer, -1) == owner:
		_pending_proposals.erase(proposer)

# 主动解除提议（提议方反悔）
func cancel_proposal(proposer: int) -> void:
	_pending_proposals.erase(proposer)

# 内部：正式建立一份联盟
func _create_alliance(a: int, b: int, now: float) -> void:
	var lo = a if a < b else b
	var hi = b if a < b else a
	var key := "%d|%d" % [lo, hi]
	alliances[key] = {
		"a": lo,
		"b": hi,
		"start_time": now,
		"expires_at": now + ALLIANCE_BASE_SECONDS,
		"total_tribute": 0,
	}
	_alert("%s 与 %s 结为盟友" % [get_display_name(a), get_display_name(b)], Color(0.3, 0.9, 1.0))

# ==================== 进贡 ====================
# 发送方扣除 TRIBUTE_DELIVERY，接收方入账；累计 1000 延长联盟 30 秒（上限 5 分钟）
# 返回是否成功
func deliver_tribute(from_owner: int, to_owner: int, res_type: String) -> bool:
	if not is_ally(from_owner, to_owner):
		return false
	if not battle:
		return false
	var cost := {res_type: TRIBUTE_DELIVERY}
	if not battle.deduct_resources_for(from_owner, cost):
		return false
	# 接收方仓库不足时退回，避免资源白白蒸发
	var limits = battle.get_limits_for(to_owner)
	if not limits.is_empty():
		var cap = limits.get(res_type, 99999)
		var cur = battle.get_resources_for(to_owner).get(res_type, 0)
		if cap - cur < TRIBUTE_DELIVERY:
			battle.add_resource_for(from_owner, res_type, TRIBUTE_DELIVERY)
			return false
	battle.add_resource_for(to_owner, res_type, TRIBUTE_DELIVERY)
	_report_tribute(from_owner, to_owner, TRIBUTE_DELIVERY)
	return true

# 内部：登记一次进贡（双方方向都累计到同一份联盟）
func _report_tribute(a: int, b: int, amount: int) -> void:
	var key := _key_of(a)
	if key == "":
		return
	var al = alliances[key]
	al["total_tribute"] += amount
	var step_count = int(al["total_tribute"] / TRIBUTE_STEP)
	var desired = min(
		al["start_time"] + ALLIANCE_MAX_SECONDS,
		al["start_time"] + ALLIANCE_BASE_SECONDS + step_count * TRIBUTE_EXTEND_SECONDS
	)
	if desired > al["expires_at"]:
		al["expires_at"] = desired
		_alert("%s → %s 进贡使联盟延长至 %.0f 秒" % [
			get_display_name(a), get_display_name(b), al["expires_at"] - al["start_time"]
		], Color(0.3, 0.9, 0.6))

# ==================== 决裂 / 背叛 ====================
# 公开退出联盟：from_owner 主动决裂，该对永久禁止再结盟
func rupture_alliance(from_owner: int) -> bool:
	var key := _key_of(from_owner)
	if key == "":
		return false
	var al = alliances[key]
	var other = al["a"] if al["a"] != from_owner else al["b"]
	_break_alliance(key, true)
	_alert("%s 与 %s 决裂！" % [get_display_name(from_owner), get_display_name(other)], Color(1.0, 0.7, 0.2))
	return true

# 背叛：秘密解除联盟，仅当背叛方军队对盟友造成军事伤害时才揭发。
# betray_owner 被标记为全局背叛者，永久禁止与任何国家结盟；该对被永久禁止。
func betray_alliance(betray_owner: int) -> bool:
	var key := _key_of(betray_owner)
	if key == "":
		return false
	var al = alliances[key]
	var other = al["a"] if al["a"] != betray_owner else al["b"]
	betrayers[betray_owner] = true
	_break_alliance(key, true)
	_alert("%s 背叛了 %s！两国彻底决裂，%s 永远无法再结盟！" % [
		get_display_name(betray_owner), get_display_name(other), get_display_name(betray_owner)
	], Color(1.0, 0.3, 0.2))
	return true

# 军队对另一国造成军事伤害时的上报入口：若双方正结盟，则视为背叛揭发
func notify_military_attack(attacker_owner: int, victim_owner: int) -> void:
	if not is_ally(attacker_owner, victim_owner):
		return
	betray_alliance(attacker_owner)

# 联盟到期自然解除（不加黑名单；到期后可再次正常结盟）
func _expire_alliance(key: String) -> void:
	var al = alliances[key]
	_alert("%s 与 %s 的联盟到期结束" % [get_display_name(al["a"]), get_display_name(al["b"])], Color(0.7, 0.7, 0.7))
	alliances.erase(key)

# 内部：拆解联盟。加黑名单则永久禁止该对再结盟
func _break_alliance(key: String, ban_pair: bool) -> void:
	if not alliances.has(key):
		return
	if ban_pair:
		ruptured_pairs[key] = true
	alliances.erase(key)

# ==================== 每帧推进 ====================
func tick(game_time: float) -> void:
	if not active or alliances.is_empty():
		return
	# 1) 到期自动解除（不加黑名单）
	for key in alliances.keys():
		if game_time >= alliances[key]["expires_at"]:
			_expire_alliance(key)
	# 2) 幸存国仅剩 2 个且仍结盟 → 系统强制决裂（该对永久禁止，避免无限拖延）
	var alive := get_alive_owners()
	if alive.size() == 2 and alliances.size() > 0:
		var key := _pair_key(alive[0], alive[1])
		if alliances.has(key):
			_break_alliance(key, true)
			_alert("%s 与 %s 是最后两个国家，联盟被强制解除！" % [
				get_display_name(alive[0]), get_display_name(alive[1])
			], Color(1.0, 0.7, 0.2))

# ==================== 淘汰与胜者 ====================
# 城堡被摧毁 → 该国淘汰。返回剩余存活国家（可能为空）。
func notify_castle_died(owner: int) -> Array:
	if not nations.has(owner):
		return get_alive_owners()
	nations[owner]["alive"] = false
	# 清理待处理提议
	var proposers_to_remove: Array = []
	for proposer in _pending_proposals.keys():
		if proposer == owner or _pending_proposals[proposer] == owner:
			proposers_to_remove.append(proposer)
	for proposer in proposers_to_remove:
		_pending_proposals.erase(proposer)
	# 若正处联盟：解除（该国已亡，解除不属于决裂/背叛，不加黑名单）
	var key := _key_of(owner)
	if key != "":
		var al = alliances[key]
		var other = al["a"] if al["a"] != owner else al["b"]
		_break_alliance(key, false)
		_alert("%s 被消灭（%s 退出战场）" % [get_display_name(owner), get_display_name(owner)], Color(0.9, 0.4, 0.3))
	return get_alive_owners()

# ==================== 工具 ====================
func _key_of(owner: int) -> String:
	for key in alliances:
		var al = alliances[key]
		if al["a"] == owner or al["b"] == owner:
			return key
	return ""

func _pair_key(a: int, b: int) -> String:
	var lo = a if a < b else b
	var hi = b if a < b else a
	return "%d|%d" % [lo, hi]

# 玩家视角的轻量提示（AI 间事件也尽量转发，便于后期调试/日志）
func _alert(msg: String, color: Color) -> void:
	if not battle:
		return
	var player_ally := -1
	if battle.has_method("_show_hud_alert"):
		battle._show_hud_alert(msg, color)

func nation_display_name(nation: int) -> String:
	match nation:
		RTSConfig.Nation.VIKING: return "维京"
		RTSConfig.Nation.ENGLAND: return "英格兰"
		RTSConfig.Nation.FRANCE: return "法兰西"
		RTSConfig.Nation.CHINA: return "中国"
		RTSConfig.Nation.HUNGARY: return "匈牙利"
		RTSConfig.Nation.JAPAN: return "日本"
		RTSConfig.Nation.BYZANTINE: return "拜占庭"
		_: return "未知"
