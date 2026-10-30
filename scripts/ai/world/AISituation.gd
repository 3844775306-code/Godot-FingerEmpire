class_name AISituation
extends RefCounted

const SimTime = preload("res://scripts/core/SimTime.gd")

# P2 世界模型（影子版）：一次扫描，产出本帧只读快照。
#
# 现阶段不接管任何决策，只做三件事：
#  1. 用**单次遍历**产出 AI 需要的分类视图（本方/敌方、农民/陆军/建筑/主城）；
#  2. 记录本次快照的构建耗时（用于对比现状多次全量扫描的成本）；
#  3. 提供与现有 count_* 函数的对账接口（影子迁移的"数据一致"验收）。
#
# 后续 P2 正式切换时，Planner/Director 改为只读本快照，不再各自遍历 battle._armies。

var valid: bool = false
var stamp_time: float = 0.0
var stamp_frame: int = 0
var cost_usec: int = 0

var own_armies: Array = []
var enemy_armies: Array = []
var own_buildings: Array = []
var enemy_buildings: Array = []
var own_buildings_by_id: Dictionary = {}

var own_land_count: int = 0
var own_worker_count: int = 0
var own_military_count: int = 0
var enemy_land_count: int = 0
var enemy_worker_count: int = 0
var enemy_building_count: int = 0
var own_castle = null
var enemy_castle = null

# 与 AI.count_land_army() 完全一致的口径：活着、本方、非农民、attack > 0、非侦察、非海军。
func refresh(ai) -> void:
	var t0: int = Time.get_ticks_usec()
	own_armies.clear()
	enemy_armies.clear()
	own_buildings.clear()
	enemy_buildings.clear()
	own_buildings_by_id.clear()
	own_land_count = 0
	own_worker_count = 0
	own_military_count = 0
	enemy_land_count = 0
	enemy_worker_count = 0
	enemy_building_count = 0
	own_castle = null
	enemy_castle = null
	valid = false
	if ai == null or ai.battle == null:
		cost_usec = Time.get_ticks_usec() - t0
		return
	var battle = ai.battle
	if battle.has_method("_ensure_cache_fresh"):
		battle._ensure_cache_fresh()
	own_armies = []
	enemy_armies = []
	for e in battle._armies:
		if not is_instance_valid(e) or e.health <= 0:
			continue
		var mine: bool = ai.entity_belongs_to_me(e)
		if mine:
			own_armies.append(e)
			if int(e.entity_id) == 10:
				own_worker_count += 1
			else:
				own_military_count += 1
				if int(e.attack) > 0 and not bool(e.water_capable) and not ai._is_scout_unit(e):
					own_land_count += 1
		else:
			enemy_armies.append(e)
			if int(e.entity_id) == 10:
				enemy_worker_count += 1
			elif int(e.attack) > 0 and not bool(e.water_capable):
				enemy_land_count += 1
	for b in battle._buildings:
		if not is_instance_valid(b) or b.health <= 0:
			continue
		if ai.entity_belongs_to_me(b):
			own_buildings.append(b)
			var bid: int = int(b.entity_id)
			own_buildings_by_id[bid] = int(own_buildings_by_id.get(bid, 0)) + 1
			if bid == 20 and own_castle == null:
				own_castle = b
		else:
			enemy_buildings.append(b)
			enemy_building_count += 1
			if int(b.entity_id) == 20 and enemy_castle == null:
				enemy_castle = b
	stamp_time = float(battle.game_time)
	stamp_frame = SimTime.frame()
	valid = true
	cost_usec = Time.get_ticks_usec() - t0

func count_building(id: int) -> int:
	return int(own_buildings_by_id.get(id, 0))

# 与 AI.count_field_military() 对账用：快照里只保留 raw 明细，具体过滤在 AI 侧已有实现。
func describe() -> Dictionary:
	return {
		"valid": valid,
		"t": stamp_time,
		"cost_usec": cost_usec,
		"own_armies": own_armies.size(),
		"enemy_armies": enemy_armies.size(),
		"own_land": own_land_count,
		"own_workers": own_worker_count,
		"own_military": own_military_count,
		"enemy_land": enemy_land_count,
		"own_buildings": own_buildings.size(),
		"enemy_buildings": enemy_building_count,
	}
