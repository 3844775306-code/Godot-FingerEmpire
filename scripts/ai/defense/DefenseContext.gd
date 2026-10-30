# scripts/ai/defense/DefenseContext.gd
# 防御架构的只读上下文/命令适配层。
# 目标：让威胁、规划、建造、守军分配模块不再直接访问 AI.gd 的内部字段，
# 而是通过这个薄层读取战场事实、提交建造/单位命令。
#
# A8：适配层本身也改为只依赖 AIContext（读）+ BuildPort（写），
# 不再持有 AI 控制器引用。
extends RefCounted

var _ctx = null
var _build_port = null
var castle = null

func _init(context = null, build_port = null) -> void:
	_ctx = context
	_build_port = build_port

func set_ports(build_port) -> void:
	_build_port = build_port

func set_castle(castle_ref) -> void:
	castle = castle_ref

func get_castle():
	return castle

func get_game_time() -> float:
	return _ctx.game_time() if _ctx != null else 0.0

func get_meta_flag(meta_name: String, default_value: bool = false) -> bool:
	return bool(_ctx.meta(meta_name, default_value)) if _ctx != null else default_value

func get_visible_enemies() -> Array:
	return _ctx.visible_enemies() if _ctx != null else []

func is_enemy(entity) -> bool:
	if _ctx == null or entity == null or not is_instance_valid(entity):
		return false
	return _ctx.is_enemy(entity)

func belongs_to_me(entity) -> bool:
	if _ctx == null or entity == null or not is_instance_valid(entity):
		return false
	return _ctx.belongs_to_me(entity)

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
	return _ctx.primary_enemy_team() if _ctx != null else -1

func get_team_castle(team: int):
	return _ctx.team_castle_of(team) if _ctx != null else null

func get_enemy_castle_dir(castle_ref) -> Vector3:
	var enemy_team: int = get_primary_enemy_team()
	var enemy_castle = get_team_castle(enemy_team)
	if enemy_castle == null and _ctx != null:
		for entity in _ctx.entities_children():
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
	return _ctx.cached_buildings() if _ctx != null else []

func get_own_armies() -> Array:
	return _ctx.cached_armies() if _ctx != null else []

func get_idle_builder(pos: Vector3, max_dist: float = 60.0):
	if _ctx == null:
		return null
	return _ctx.nearest_idle_builder(_ctx.my_team(), _ctx.my_peer_id(), pos, max_dist)

func get_resources() -> Dictionary:
	return _ctx.resources() if _ctx != null else {}

func get_limits() -> Dictionary:
	return _ctx.limits() if _ctx != null else {}

func is_research_mode() -> bool:
	return _ctx.is_research_mode() if _ctx != null else false

func get_age() -> int:
	if _ctx == null or not is_research_mode():
		return 0
	var state: Dictionary = _ctx.research_state(_ctx.my_peer_id(), _ctx.my_team())
	return int(state.get("age", 0))

func can_build(building_id: int) -> bool:
	return bool(_build_port.can_build(building_id)) if _build_port != null else false

func build(building_id: int, pos: Vector3, facing: Vector3 = Vector3.ZERO) -> bool:
	return bool(_build_port.build(building_id, pos, facing)) if _build_port != null else false

func assign_builders(building, builders: Array) -> void:
	if _ctx != null:
		_ctx.assign_builders(building, builders)

func enemy_army_within(pos: Vector3) -> bool:
	return _ctx.enemy_army_within(pos) if _ctx != null else false

func world_to_grid(pos: Vector3) -> Vector2i:
	return _ctx.world_to_grid(pos) if _ctx != null else Vector2i.ZERO

func grid_to_world(cell: Vector2i) -> Vector3:
	return _ctx.grid_to_world(cell) if _ctx != null else Vector3.ZERO
