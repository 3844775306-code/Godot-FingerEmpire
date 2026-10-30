# scripts/ai/defense/DefenseContext.gd
# 防御架构的只读上下文/命令适配层。
# 目标：让威胁、规划、建造、守军分配模块不再到处直接访问 AI.gd 的内部字段，
# 而是通过这个薄层读取战场事实、提交建造/单位命令。第 1 阶段只服务威胁模型。
extends RefCounted

var ai = null
var battle = null
var castle = null

func _init(ai_ref) -> void:
	ai = ai_ref
	battle = ai.battle if ai != null else null

func set_castle(castle_ref) -> void:
	castle = castle_ref

func get_castle():
	return castle

func get_game_time() -> float:
	if battle == null:
		return 0.0
	return float(battle.game_time)

func get_visible_enemies() -> Array:
	if ai == null:
		return []
	return ai._visible_enemies

func is_enemy(entity) -> bool:
	if ai == null or entity == null or not is_instance_valid(entity):
		return false
	return ai._entity_is_enemy(entity)

func belongs_to_me(entity) -> bool:
	if ai == null or entity == null or not is_instance_valid(entity):
		return false
	return ai.entity_belongs_to_me(entity)

# 与旧 AIDefense._is_combat_enemy 保持同一口径：
# 中立动物/中立单位不算敌军；没有攻击能力的单位也不触发防守。
func is_combat_enemy(entity) -> bool:
	if entity == null or not is_instance_valid(entity) or not (entity is Army):
		return false
	if entity.health <= 0:
		return false
	if int(entity.team) == RTSConfig.Team.NEUTRAL:
		return false
	if not is_enemy(entity):
		return false
	return int(entity.target_type) > 0 or float(entity.attack) > 0.0

func get_primary_enemy_team() -> int:
	if ai == null:
		return -1
	return ai._primary_enemy_team()

func get_team_castle(team: int):
	if ai == null:
		return null
	return ai.get_team_castle(team)

func get_enemy_castle_dir(castle_ref) -> Vector3:
	var enemy_team: int = get_primary_enemy_team()
	var enemy_castle = get_team_castle(enemy_team)
	if enemy_castle == null and battle != null:
		for entity in battle.entities.get_children():
			if entity is Building and int(entity.entity_id) == 20 and entity.health > 0 \
					and is_enemy(entity):
				enemy_castle = entity
				break
	if enemy_castle != null and is_instance_valid(enemy_castle):
		var direction: Vector3 = enemy_castle.global_position - castle_ref.global_position
		direction.y = 0.0
		if direction.length_squared() > 0.01:
			return direction.normalized()
	return Vector3.FORWARD

func get_own_buildings() -> Array:
	if ai == null:
		return []
	return ai._cached_buildings()

func get_own_armies() -> Array:
	if ai == null:
		return []
	return ai._cached_armies()

func get_idle_builder(pos: Vector3, max_dist: float = 60.0):
	if battle == null or not battle.has_method("find_nearest_idle_builder"):
		return null
	return battle.find_nearest_idle_builder(ai.my_team, ai.my_peer_id, pos, max_dist)

func get_resources() -> Dictionary:
	if ai == null:
		return {}
	return ai._get_resources()

func get_limits() -> Dictionary:
	if ai == null:
		return {}
	return ai._get_limits()

func is_research_mode() -> bool:
	return battle != null and battle.has_method("is_research_mode") and battle.is_research_mode()

func get_age() -> int:
	if not is_research_mode():
		return 0
	var state: Dictionary = battle.get_research_state(ai.my_peer_id, ai.my_team)
	return int(state.get("age", 0))

func can_build(building_id: int) -> bool:
	return ai != null and ai._ai_can_build(building_id)

func build(building_id: int, pos: Vector3, facing: Vector3 = Vector3.ZERO) -> bool:
	return ai != null and ai.build_building(building_id, pos, facing)

func assign_builders(building, builders: Array) -> void:
	if battle != null and battle.has_method("assign_builders"):
		battle.assign_builders(building, builders)

func enemy_army_within(pos: Vector3) -> bool:
	return ai != null and ai._enemy_army_within(pos)

func world_to_grid(pos: Vector3) -> Vector2i:
	if battle == null:
		return Vector2i.ZERO
	return battle.world_to_grid(pos)

func grid_to_world(cell: Vector2i) -> Vector3:
	if battle == null:
		return Vector3.ZERO
	return battle.grid_to_world(cell.x, cell.y)
