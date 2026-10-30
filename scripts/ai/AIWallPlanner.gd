# scripts/ai/AIWallPlanner.gd
# 城墙施工调度器：只调整 AIDefense 已经规划好的墙位顺序，不改墙线本身。
# 核心目的：不要先修一条墙的中间一截，而是先咬住天然屏障的墙端，
# 再一段一段往中间合拢；已经接上墙的段落优先于孤立的墙段。
extends RefCounted

const RANK_INTERVAL: float = 0.8
const LINK_RADIUS: float = 2.35
const ANCHOR_PRIORITY: float = 2.8
const LINK_PRIORITY: float = 1.1
const ISOLATED_PENALTY: float = 3.5

var ai = null
var defense = null
var _timer: float = 0.15
var _base_priority: Dictionary = {}
var _anchor_cache: Dictionary = {}
var _built_walls: Array = []
var _built_grid: Dictionary = {}
var _castle_pos: Vector3 = Vector3.ZERO
var _ctx = null
var _enemy_dir: Vector3 = Vector3.FORWARD

func _init(ai_ref, defense_ref) -> void:
	ai = ai_ref
	defense = defense_ref

func tick(delta: float) -> void:
	if ai == null or defense == null:
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = RANK_INTERVAL
	if not bool(defense.defense_initialized):
		return
	var castle = _ctx.castle()
	if not is_instance_valid(castle):
		return
	_castle_pos = castle.global_position
	_enemy_dir = _ctx.enemy_army_direction(_castle_pos)
	_enemy_dir.y = 0.0
	if _enemy_dir.length_squared() < 0.0001:
		_enemy_dir = Vector3.FORWARD
	else:
		_enemy_dir = _enemy_dir.normalized()
	_refresh_built_walls()
	var queue: Array = defense._defense_queue
	if queue.is_empty():
		_base_priority.clear()
		return
	# 清理掉已经建完/放弃的墙位，避免缓存无限膨胀。
	if _base_priority.size() > 768:
		_base_priority.clear()
	for item in queue:
		if int(item.get("id", -1)) != 27:
			continue
		var p: Vector3 = item.get("pos", Vector3.ZERO)
		var key: String = _pos_key(p)
		if not _base_priority.has(key):
			_base_priority[key] = float(item.get("priority", 50.0))
		var base: float = float(_base_priority[key])
		var anchor: bool = _is_anchor(p)
		var linked: bool = _has_built_neighbor(p)
		var mod: float = 0.0
		if anchor:
			# 天然屏障端头先落地，墙线才有“根”。
			mod -= ANCHOR_PRIORITY
		elif linked:
			# 紧贴已建墙，继续合拢。
			mod -= LINK_PRIORITY
		elif not _built_walls.is_empty():
			# 没有任何连接、也不靠地形的孤立墙段最后建，避免墙线到处开花却处处漏风。
			mod += ISOLATED_PENALTY
		# 同优先级下，朝敌人方向的一侧略优先。
		mod -= _front_score(p) * 0.8
		item["priority"] = base + mod
	# 队列按优先级从低到高建；AIDefense._build_defense_step 按数组顺序取。
	queue.sort_custom(func(a, b):
		return float(a.get("priority", 99.0)) < float(b.get("priority", 99.0))
	)

func _refresh_built_walls() -> void:
	_built_walls.clear()
	_built_grid.clear()
	for b in _ctx.cached_buildings():
		if not is_instance_valid(b) or not (b is Building):
			continue
		if int(b.entity_id) != 27 or b.health <= 0:
			continue
		if not _ctx.belongs_to_me(b):
			continue
		_built_walls.append(b)
		_built_grid[ai.battle.world_to_grid(b.global_position)] = true

func _pos_key(p: Vector3) -> String:
	return "%.2f:%.2f" % [p.x, p.z]

# 墙端是否顶在水/山/地图边缘上。浅滩(overlay 3)是陆军可通行的，不算屏障。
func _is_anchor(p: Vector3) -> bool:
	var cell: Vector2i = ai.battle.world_to_grid(p)
	var key: String = "%d:%d" % [cell.x, cell.y]
	if _anchor_cache.has(key):
		return bool(_anchor_cache[key])
	var dirs: Array = [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)
	]
	var found: bool = false
	for d in dirs:
		var n: Vector2i = cell + d
		# 城墙允许贴最外圈建（AIDefense 用地图边界封口），所以墙格紧邻地图
		# 最外圈时就应该算“顶在边界上的锚点”，优先落地。
		if n.x <= 0 or n.y <= 0 or n.x >= RTSConfig.MAP_SIZE - 1 or n.y >= RTSConfig.MAP_SIZE - 1:
			found = true
			break
		if ai.battle.is_cliff_tile(n.x, n.y):
			found = true
			break
		if ai.battle.get_terrain_at_grid(n.x, n.y) == 2 \
				and ai.battle.get_overlay_at_grid(n.x, n.y) != 3:
			found = true
			break
	_anchor_cache[key] = found
	return found

func _has_built_neighbor(p: Vector3) -> bool:
	var cell: Vector2i = ai.battle.world_to_grid(p)
	var r: int = int(ceil(LINK_RADIUS))
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			var n: Vector2i = cell + Vector2i(dx, dz)
			if not _built_grid.has(n):
				continue
			if Vector2(float(dx), float(dz)).length() <= LINK_RADIUS:
				return true
	return false

func _front_score(p: Vector3) -> float:
	var to_p: Vector3 = p - _castle_pos
	to_p.y = 0.0
	if to_p.length_squared() < 0.0001:
		return 0.0
	return clampf(to_p.normalized().dot(_enemy_dir), -1.0, 1.0)

func set_context(c) -> void:
	_ctx = c
