# scripts/ai/defense/DefenseDirector.gd
# 防御架构第 2 阶段：态势/预算导演（影子模式）。
#
# 第 2 阶段只做只读汇总：把威胁快照翻译成 DEFCON 姿态、防守预算和圈数目标，
# 不改变任何建造/守军命令。等日志确认口径正确后，再逐项接管 AIDefense 的散落判断。
extends RefCounted

enum Posture { CALM, ALERT, DEFEND, CRITICAL }

const POSTURE_NAMES: Array = ["平静", "警戒", "防守", "危急"]
const RESERVE_DEFEND: float = 0.22
const RESERVE_ALERT: float = 0.20
const RESERVE_CALM: float = 0.35

var context = null

var threat_level: int = 0
var threat_score: float = 0.0
var enemy_count: int = 0
var track_count: int = 0
var posture: int = Posture.CALM
var budget_reserve: float = RESERVE_CALM
var recommended_ring_target: int = 0
var primary_sector: int = -1
var sector_pressure: Array = []
var updated_at: float = 0.0

func _init(context_ref) -> void:
	context = context_ref

# snapshot 来自 DefenseThreatModel；ring_target 沿用当前 AIDefense 的圈数判断。
# 返回值是给 DefensePlan / 调试面板读的只读摘要。
func evaluate(snapshot: Dictionary, ring_target: int, now: float) -> Dictionary:
	threat_level = clampi(int(snapshot.get("level", 0)), 0, 3)
	threat_score = float(snapshot.get("score", 0.0))
	enemy_count = int(snapshot.get("enemy_count", 0))
	posture = threat_level
	budget_reserve = _reserve_for(posture)
	recommended_ring_target = maxi(ring_target, 0)
	var tracks: Array = snapshot.get("tracks", [])
	track_count = tracks.size()
	var sectors: Array = snapshot.get("sectors", [])
	sector_pressure = []
	primary_sector = -1
	var best_pressure: float = 0.0
	for i in range(sectors.size()):
		var sector: Dictionary = sectors[i]
		var pressure: float = float(sector.get("pressure", 0.0))
		sector_pressure.append(pressure)
		if pressure > best_pressure:
			best_pressure = pressure
			primary_sector = i
	updated_at = now
	return to_dictionary()

func _reserve_for(level: int) -> float:
	# 与 AIDefense._defense_reserve() 保持同一口径，方便后续直接替换。
	if level >= 2:
		return RESERVE_DEFEND
	if level == 1:
		return RESERVE_ALERT
	return RESERVE_CALM

func posture_name() -> String:
	return String(POSTURE_NAMES[clampi(posture, 0, POSTURE_NAMES.size() - 1)])

func is_defending() -> bool:
	return posture >= Posture.DEFEND

func is_critical() -> bool:
	return posture == Posture.CRITICAL

func to_dictionary() -> Dictionary:
	return {
		"posture": posture,
		"posture_name": posture_name(),
		"threat_level": threat_level,
		"threat_score": threat_score,
		"enemy_count": enemy_count,
		"track_count": track_count,
		"budget_reserve": budget_reserve,
		"recommended_ring_target": recommended_ring_target,
		"primary_sector": primary_sector,
		"sector_pressure": sector_pressure.duplicate(),
		"updated_at": updated_at,
	}

# 供调试面板显示一行摘要，不参与任何决策。
func describe() -> String:
	var sector_txt := "-"
	if primary_sector >= 0:
		sector_txt = str(primary_sector + 1)
	return "姿态:%s 预算:%.2f 圈:%d 主扇区:%s 轨迹:%d" % [
		posture_name(), budget_reserve, recommended_ring_target, sector_txt, track_count,
	]
