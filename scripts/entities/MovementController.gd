# scripts/entities/MovementController.gd
# Extracted from Army.gd — handles all movement, pathfinding, and collision separation
class_name MovementController
extends RefCounted

var _army: Army  # parent unit reference

# Movement state
var astar_path: Array = []
var astar_target: Vector3 = Vector3.ZERO
# 攻击追击目标时 A* 完全无路的标记，供 Army 做“打不到目标就换目标/拆墙”的兜底
var attack_path_failed: bool = false
# 普通移动/攻击移动的目标本身无路可走；Army 据此取消命令，避免 MOVING/ATTACK_MOVING 状态一直播放走路动画
var move_path_failed: bool = false
var astar_recalc_timer: float = 0.0
const ASTAR_RECALC_INTERVAL: float = 2.0
# 追击移动目标时目标位置每帧都在变；若每次变化都重算 A*（最多 1000 节点），
# 大部队交战时每帧会跑数百次寻路。按单位错峰限频，保留路径跟随和最终接近。
const ATTACK_PATH_COOLDOWN_MS: int = 700
# 追击目标在小范围内移动时继续沿用现有路径，避免每 0.5~0.7s 为每个单位重跑一次 A*
const ATTACK_TARGET_MOVE_TOLERANCE: float = 2.5
# 路径预览最多绘制多少个点，避免长路径为每个格子创建一个 MeshInstance3D。
const MAX_PATH_PREVIEW_POINTS: int = 64
var _last_attack_path_ms: int = -100000
# A* 分帧预算用：当前请求被延后时暂存目标，下一帧继续尝试。
var _pending_path: bool = false
var _pending_target: Vector3 = Vector3.ZERO
var _pending_stop_range: float = 0.0
var _pending_since_ms: int = 0
# A* 节点预算耗尽时不要直接返回空路径：先沿着“离目标最近的可达格”推进，
# 到达该段末端后由 Army 重新寻路。否则大部队攻击移动会停在原地。
var path_partial: bool = false
var _last_path_partial: bool = false
# 大量单位同时追击时 A* 预算可能连续多帧排不到某个单位。
# 等待超过这个时间就按“无路”处理，交给 Army 的换目标/拆墙兜底，不能让单位永远站着。
const PENDING_PATH_TIMEOUT_MS: int = 2000

var _path_sphere: SphereMesh = null
var _path_mat: StandardMaterial3D = null
var _path_mat_end: StandardMaterial3D = null  # green for last waypoint
# Path markers
var _path_markers: Array = []
var _is_selected: bool = false

# Collision
var collision_timer: float = 0.0
# 当前物理挤靠的敌方建筑：攻击目标在墙后时 A* 常从建筑格穿过去，
# 单位实际会顶在墙上原地踏步；Army 用它改打这面挡路的墙。
var blocking_building: Building = null
const COLLISION_INTERVAL: float = 0.15
var _last_recalc_frame: int = -99  # prevent recalc spam
var _path_cache: Dictionary = {}  # Vector2i(world_x, world_z) -> path_array, cleared on building placement
var _blacklist: Dictionary = {}  # Vector2i -> 过期时间戳，暂时跳过不可达目标
# 普通移动失败只临时拉黑：如果永久记住，玩家一次失败后同一位置就再也点不动，
# 只有建筑布局变化触发 recalculate() 才会恢复，表现为“单位不听移动命令”。
const MOVE_BLACKLIST_TTL_MS: int = 4000

func _init(army: Army):
	_army = army
	# 错开各单位首次碰撞分离的帧，避免几百个单位在同一物理帧集中做近邻查询
	collision_timer = randf_range(0.0, COLLISION_INTERVAL)
	# 单位死亡/离场时清理挂在 battle_manager 下的路径球。不能用
	# MovementController 的 PREDELETE 通知里再调方法，RefCounted 析构阶段方法表已不可用。
	if army != null and not army.tree_exiting.is_connected(_hide_path):
		army.tree_exiting.connect(_hide_path)

# ==================== Public API ====================

func set_selected(sel: bool):
	_is_selected = sel
	if sel:
		_show_path()
	else:
		_hide_path()

func set_move_target(pos: Vector3, stop_range: float = 0.0):
	# Use Vector2i key for fast hashing (was string "%d,%d")
	if astar_target.distance_to(pos)<0.5:
		# 终点基本相同：通常直接返回，避免每帧重复寻路；
		# 但若当前路径为空且没有待处理寻路，说明上次寻路失败，必须允许重算，
		# 否则单位会永久停在原地（农民交付时常见：目标已在主城，却一步也不走）
		if astar_path.size() > 0:
			move_path_failed = false
			attack_path_failed = false
			return
		if _pending_path:
			return
	var key = Vector2i(int(pos.x), int(pos.z))
	var is_attack_move := stop_range > 0.0
	# 黑名单只用于普通移动；攻击追击要允许重新尝试墙后/建筑中心的目标，
	# 否则目标站在曾经寻路失败过的格子上时，单位会连攻击路径都不再计算。
	if not is_attack_move and _blacklist.has(key):
		var blacklist_until: int = int(_blacklist[key])
		if Time.get_ticks_msec() < blacklist_until:
			_pending_path = false
			move_path_failed = true
			path_partial = false
			return
		_blacklist.erase(key)

	# 新一次寻路请求开始前先清掉旧的失败标记，避免上一目标失败导致移动命令被立即取消
	move_path_failed = false
	if is_attack_move:
		# 目标只挪动一点点时旧路径仍然可用，先不重算；等偏移超过容差或冷却到期再更新
		if astar_path.size() > 0 and astar_target != Vector3.ZERO and astar_target.distance_to(pos) < ATTACK_TARGET_MOVE_TOLERANCE:
			return
		var now_ms := Time.get_ticks_msec()
		# 首次追击按 unit id 分 16 个相位错峰，避免全军在同一帧集中跑 A*；
		# 后续只加少量抖动，保证追击路径不会滞后太久。
		var phase_ms := int(_army.get_instance_id() % 16) * 30
		var cooldown_ms := ATTACK_PATH_COOLDOWN_MS + int(_army.get_instance_id() % 5) * 15
		if _last_attack_path_ms < 0:
			_last_attack_path_ms = now_ms - cooldown_ms + phase_ms
		if now_ms - _last_attack_path_ms < cooldown_ms:
			# 注意：这里不能写 astar_target，否则下一次调用会被开头的
			# distance_to < 0.5 提前返回，永远不再生成路径。
			return
		_last_attack_path_ms = now_ms

	# Only cache normal movement (stop_range==0). Attacks recalc every time.
	#var use_cache = (stop_range == 0.0)
	#if use_cache and _path_cache.has(key):
		#astar_path = _path_cache[key]
		#if _is_selected: _show_path()
		#return
	# New target: calculate and cache. A* 受每帧预算限制，超预算时暂存到下一帧，
	# 避免全军同一帧各跑一次长路径导致操作卡顿。
	if not _try_compute_path(pos, stop_range):
		var was_pending: bool = _pending_path
		if not was_pending or _pending_target.distance_to(pos) > 2.0:
			_pending_since_ms = Time.get_ticks_msec()
		_pending_path = true
		_pending_target = pos
		_pending_stop_range = stop_range
		if not is_attack_move:
			# 普通移动命令先收起旧路径，避免短暂继续走向旧目标；追击保留旧路径。
			# 同步更新 astar_target，防止 Army 的“已到达”判断拿旧目标误清命令。
			astar_target = pos
			astar_path.clear()
			path_partial = false
			if _is_selected: _hide_path()
		return
	# 新目标已立即算完，清掉可能残留的旧 pending，避免下一帧把它重新算回来。
	_pending_path = false
	_pending_since_ms = 0

func _try_compute_path(pos: Vector3, stop_range: float, bm: RTSBattleManager = null) -> bool:
	if bm == null:
		bm = _get_bm()
	if bm != null and not bm.reserve_astar_request():
		return false
	var started_usec := Time.get_ticks_usec()
	var path := _calculate_astar_path(pos, stop_range)
	if bm != null:
		bm.report_astar_cost(Time.get_ticks_usec() - started_usec)
	_apply_path(pos, path, stop_range)
	return true

func _apply_path(pos: Vector3, path: Array, stop_range: float) -> void:
	var is_attack_move := stop_range > 0.0
	astar_target = pos
	astar_path = path
	path_partial = _last_path_partial
	var key = Vector2i(int(pos.x), int(pos.z))
	if astar_path.size() > 0:
		attack_path_failed = false
		move_path_failed = false
		if not is_attack_move:
			_path_cache[key] = astar_path
	elif is_attack_move:
		# 追击目标寻路失败时不写永久黑名单；重置目标，让冷却后还能重试
		attack_path_failed = true
		move_path_failed = false
		astar_target = Vector3.ZERO
	else:
		attack_path_failed = false
		move_path_failed = true
		_blacklist[key] = Time.get_ticks_msec() + MOVE_BLACKLIST_TTL_MS
	if _is_selected: _show_path()

func _try_compute_pending_path(bm: RTSBattleManager) -> bool:
	if not _pending_path:
		return true
	if not _try_compute_path(_pending_target, _pending_stop_range, bm):
		return false
	_pending_path = false
	_pending_since_ms = 0
	return true

func cancel_pending_path() -> void:
	_pending_path = false
	_pending_since_ms = 0

func _get_bm() -> RTSBattleManager:
	if _army == null or not is_instance_valid(_army) or not _army.is_inside_tree():
		return null
	return _army.get_tree().get_first_node_in_group("battle_manager") as RTSBattleManager

# 清理某个目标点的“不可达”黑名单。AI 派单位上墙时，城墙可能刚补建完成，
# 之前的寻路失败记录会让后续移动命令永远直接失败，必须按墙格清掉。
func clear_blacklist_at(pos: Vector3) -> void:
	_blacklist.erase(Vector2i(int(pos.x), int(pos.z)))

func recalculate():
	
	_path_cache.clear()  # new building may block cached paths
	_blacklist.clear()  # new building may open paths
	attack_path_failed = false
	move_path_failed = false
	_last_attack_path_ms = -100000  # 建筑变化后允许立即重算追击路径
	# building recalc - cached paths cleared
	# 采集/交付/攻击移动也属于「有固定终点」的状态，卡住时必须能重算路径
	if astar_target != Vector3.ZERO and _army.current_order in ["move", "deliver", "gather", "attack_move"]:
		var key = Vector2i(int(astar_target.x), int(astar_target.z))
		_path_cache.erase(key)
		astar_path = _calculate_astar_path(astar_target)
		path_partial = _last_path_partial
		attack_path_failed = astar_path.is_empty()
		move_path_failed = astar_path.is_empty()
		_pending_path = false
		_pending_since_ms = 0
		if astar_path.size() > 0: _path_cache[key] = astar_path  # only cache valid paths
		if _is_selected:
			_show_path()

func get_current_target() -> Vector3:
	if is_instance_valid(_army.current_target):
		return _army.current_target.global_position
	if _army.is_attack_moving:
		return _army.attack_move_target
	if _army._order_is(_army.UnitState.MOVING):
		return astar_target
	return Vector3.ZERO

func stop():
	astar_path.clear()
	astar_target = Vector3.ZERO
	attack_path_failed = false
	move_path_failed = false
	path_partial = false
	blocking_building = null
	_pending_path = false
	_pending_since_ms = 0
	_stop_velocity()

# 单位停止/进入攻击距离后必须把残留速度清零，否则 Army 的 simple_idle 永远不成立，
# 后期几百个已经停下的单位仍会每 0.15~0.22 秒做一次碰撞近邻查询。
func _stop_velocity() -> void:
	if _army != null:
		var had_velocity: bool = _army.velocity.length_squared() > 0.04
		_army.velocity = Vector3.ZERO
		# 从移动到停下的瞬间刷新一次动画，否则 MOVING/ATTACKING 状态可能继续播放走路动作
		if had_velocity and _army.is_inside_tree():
			_army._refresh_animation_now()

# ==================== Main movement update ====================

func process_move(delta, bm: RTSBattleManager):
	# 之前因 A* 预算被延后的目标，继续在本帧尝试；普通移动仍未轮到则原地等待，
	# 不能拿旧路径继续走，否则大部队下令后会先朝旧目标移动。
	# 攻击追目标时旧路径通常仍指向同一目标，可以边沿旧路径推进边等新路径。
	if _pending_path:
		var attack_order: bool = _army.is_attack_moving or _army._order_is(_army.UnitState.ATTACKING)
		if not _army.is_attack_moving and not _army._order_is(_army.UnitState.MOVING) \
				and not _army._order_is(_army.UnitState.ATTACKING):
			# 只有真正不需要寻路的命令才丢弃待处理请求；攻击索敌必须保留，
			# 否则 A* 预算连续几帧排不到时会表现为“锁着目标却一步不走”。
			_pending_path = false
			_pending_since_ms = 0
		elif not _try_compute_pending_path(bm):
			# 只有攻击目标需要超时兜底；普通移动的寻路请求不能因为 A* 预算拥堵
			# 等了两秒就被判失败，否则玩家下令后单位会直接停住不动。
			if attack_order and Time.get_ticks_msec() - _pending_since_ms >= PENDING_PATH_TIMEOUT_MS:
				# 连续等待超时：按寻路失败处理，让 Army 换目标/拆挡路建筑，避免永久站桩。
				_pending_path = false
				_pending_since_ms = 0
				attack_path_failed = true
				move_path_failed = false
				astar_target = Vector3.ZERO
			# 攻击移动即使新路径还没算完，也可以先沿现有路径继续推进；
			# 普通攻击/普通移动没有可用新路径时先停住，等下一帧重试。
			if not (_army.is_attack_moving and astar_path.size() > 0):
				_stop_velocity()
				return
	if not _army.can_move or _army.speed <= 0:
		_stop_velocity()
		return
	if _army.hold_position and _army.target_type != 0 and not _army.has_meta("ai_wall_guard"):
		# AI 派往城墙的远程单位需要能走到墙顶并完成高度抬升，因此 process_move
		# 不因 hold_position 提前停下；抵达后由 Army 的目标逻辑保证不追出射程。
		_stop_velocity()
		return

	# Stop if at gather/attack range of target
	if _army.current_target and is_instance_valid(_army.current_target):
		var target_radius = 0.0
		if _army.current_target is GameEntity:
			target_radius = _army.current_target.body_radius
		var h_diff = Vector2(_army.global_position.x - _army.current_target.global_position.x,
			_army.global_position.z - _army.current_target.global_position.z)
		var h_dist = h_diff.length() - _army.body_radius - target_radius
		if _army.current_target is WorldResource and h_dist <= 0.5:
			_stop_velocity()
			return
		elif _army.current_target is GameEntity and h_dist <= _army.attack_range:
			_stop_velocity()
			return

	var target_pos = get_current_target()
	if target_pos == Vector3.ZERO:
		_stop_velocity()
		return

	# Follow A* path
	var move_target = target_pos
	# No A* path = no movement, unless close to target (final approach)
	if astar_path.size() == 0:
		if astar_target.distance_squared_to(_army.global_position) > 3.0:
			_stop_velocity()
			return  # too far, no path → stay put
		# Close enough: allow final approach to exact target

	if astar_path.size() > 0:
		move_target = astar_path[0]
		var h_dist = Vector2(move_target.x - _army.global_position.x, move_target.z - _army.global_position.z)
		if h_dist.length() < 0.5:
			astar_path.pop_front()
			# 不要每经过一个航点就重建全部路径球：选中大部队时这一步会瞬间
			# 创建/销毁数千个 MeshInstance3D。只在路径走完时收起预览，换目标时
			# 由 set_move_target()/recalculate() 重新生成。
			if astar_path.is_empty() and _is_selected:
				_hide_path()
			if astar_path.size() > 0:
				move_target = astar_path[0]
	# Build horizontal direction
	var horizontal_target = Vector3(move_target.x, _army.global_position.y, move_target.z)
	var move_dir = (horizontal_target - _army.global_position).normalized()
	if move_dir.length() < 0.01:
		_stop_velocity()
		return

	

	## Mountain avoidance: deflect if next step is impassable
	#var next_pos = _army.global_position + move_dir * _army.speed * 0.016
	#if bm and not _army.water_capable:
		#var terr = bm.get_terrain_at(next_pos)
		#if terr == 1:
			#var alt = move_dir.rotated(Vector3.UP, deg_to_rad(45))
			#next_pos = _army.global_position + alt * _army.speed * 0.016
			#if bm.get_terrain_at(next_pos) == 1:
				#alt = move_dir.rotated(Vector3.UP, deg_to_rad(-90))
				#next_pos = _army.global_position + alt * _army.speed * 0.016
				#if bm.get_terrain_at(next_pos) == 1: return
			#move_dir = alt
	_army.velocity = Vector3(move_dir.x, 0, move_dir.z) * _army.speed
	_army.move_and_slide()
	# 陆地单位的脚步音由 Army._play_step_sfx 按实际落脚点触发；
	# 这里只保留船只的持续航行音，避免和脚步音重复。
	if _army.speed > 0.1 and Engine.get_process_frames() % 40 == 0:
		var terr = bm.get_terrain_at(_army.global_position) if bm else 0
		if terr == 2 and _army.water_capable:
			_army._play_sfx_if_visible("sail")

	# Rotate toward movement direction
	if move_dir.length() > 0.01:
		var look_target = _army.global_position + move_dir
		_army.look_at(Vector3(look_target.x, _army.global_position.y, look_target.z), Vector3.UP)

	# Boundary clamp
	var half_map = RTSConfig.MAP_SIZE / 2.0
	_army.global_position.x = clamp(_army.global_position.x, -half_map, half_map)
	_army.global_position.z = clamp(_army.global_position.z, -half_map, half_map)

	# Terrain height smoothing
	if bm:
		var map = bm.get_node("Map")
		if map and map.has_method("get_height_at"):
			var target_height = map.get_height_at(_army.global_position)
			# Climb friendly walls + laddered enemy walls (O(1) 墙体网格查询，替代每帧全量遍历)
			var gpos2 = bm.world_to_grid(_army.global_position)
			var wall_b = bm._wall_entity_grid.get(gpos2)
			if wall_b:
				if wall_b.team == _army.team:
					target_height += RTSBattleManager.WALL_TOP_HEIGHT  # friendly wall
				elif _has_adjacent_ladder(bm, gpos2, _army.team):
					target_height += RTSBattleManager.WALL_TOP_HEIGHT  # laddered enemy wall
			_army.global_position.y = move_toward(_army.global_position.y, target_height, 5.0 * delta)

# ==================== Collision separation ====================

func apply_collision(delta):
	blocking_building = null
	# 墙顶空间很小，守墙单位之间不能再按地面半径互相推挤，否则会被推下墙格。
	if _army.has_meta("ai_wall_guard") and _army._is_unit_on_wall():
		return
	var bm = _army._get_bm()
	if bm == null:
		return
	# 单位碰撞只需要极近的邻居，过去固定查 5 格会把密集人群整片返回；
	# 建筑中心半径较大，单独走建筑桶查询，避免为了命中建筑而扫描周围所有单位。
	var near_range: float = maxf(_army.body_radius * 2.0 + 0.8, 1.2)
	var entities_nearby: Array = bm.get_nearby_entities(_army.global_position, near_range)
	var buildings_nearby: Array = []
	if bm.has_method("get_nearby_buildings"):
		buildings_nearby = bm.get_nearby_buildings(_army.global_position, _army.body_radius + 5.0)
	else:
		buildings_nearby = bm._buildings
	for entity in entities_nearby:
		if entity == _army or not is_instance_valid(entity): continue
		if not (entity is GameEntity) or entity.health <= 0: continue
		if entity is Building or entity is WorldResource: continue
		_separate_from(entity, delta, bm)
	for entity in buildings_nearby:
		if entity == _army or not is_instance_valid(entity): continue
		if not (entity is Building) or entity.health <= 0: continue
		if entity.entity_id == 7: continue  # 桥不阻挡通行
		if entity.entity_id == 27 and entity.team == _army.team: continue  # pass through friendly walls
		if entity.entity_id == 27 and entity.team != _army.team:
			if _has_adjacent_ladder(bm, bm.world_to_grid(entity.global_position), _army.team): continue  # pass through laddered enemy walls
		_separate_from(entity, delta, bm)

# 按体积近似推挤质量；配置里显式给了 mass 时优先使用。
func _get_push_mass(entity: GameEntity) -> float:
	if entity.mass > 0.0:
		return entity.mass
	return maxf(1.0, entity.body_radius * entity.body_radius * 10.0)

# 推挤落点是否合法：陆军不能进深水/河流，海军不能上岸，桥面按各自通行规则处理。
func _can_push_to(pos: Vector3, bm: RTSBattleManager) -> bool:
	if bm == null:
		return true
	var g: Vector2i = bm.world_to_grid(pos)
	var terrain: int = bm.get_terrain_at_grid(g.x, g.y)
	if _army.water_capable:
		# 海军只能待在可航行水域；桥面虽然是水格，但船不能开上去。
		return terrain == 2 and not _bridge_set.has(g)
	if terrain != 2:
		return true
	# 陆军允许浅滩和桥面，河流/海面等深水一律拒绝。
	return bm.get_overlay_at_grid(g.x, g.y) == 3 or _bridge_set.has(g)

# 尝试推挤；整段落水/上岸时退化为单轴滑动，避免贴着岸线完全卡死。
func _try_push_position(step: Vector3, bm: RTSBattleManager) -> bool:
	var base: Vector3 = _army.global_position
	if _can_push_to(base + step, bm):
		_army.global_position = base + step
		return true
	var step_x := Vector3(step.x, 0.0, 0.0)
	if absf(step_x.x) > 0.0001 and _can_push_to(base + step_x, bm):
		_army.global_position = base + step_x
		return true
	var step_z := Vector3(0.0, 0.0, step.z)
	if absf(step_z.z) > 0.0001 and _can_push_to(base + step_z, bm):
		_army.global_position = base + step_z
		return true
	return false

# 友军挡在正前方时也加一个切向分量，让后排单位从旁边绕过去；
# 否则密集近战里后排会被径向推力顶回原地，只播放走路动画。
func _unit_slide_dir(push_dir: Vector3, velocity: Vector3) -> Vector3:
	var radial := Vector3(push_dir.x, 0.0, push_dir.z)
	if radial.length_squared() < 0.000001:
		return Vector3.ZERO
	radial = radial.normalized()
	var vel := Vector3(velocity.x, 0.0, velocity.z)
	if vel.length_squared() < 0.0001:
		return radial
	# 只有正在朝友军方向顶时才改走切向；被友军从后方/侧面推时保持径向
	if vel.normalized().dot(radial) >= -0.05:
		return radial
	var tangent := Vector3(-radial.z, 0.0, radial.x)
	var side_dot := tangent.dot(vel)
	if side_dot < -0.0001:
		tangent = -tangent
	elif absf(side_dot) <= 0.0001:
		if _army.get_instance_id() % 2 == 0:
			tangent = -tangent
	return (radial * 0.55 + tangent * 0.85).normalized()

# 建筑推挤时朝径向推开；单位仍在前进时，沿建筑边缘加一个切向分量，
# 让它顺着墙/建筑角滑过去，而不是被径向推力顶回去原地抖动。
func _building_slide_dir(push_dir: Vector3, velocity: Vector3) -> Vector3:
	var radial := Vector3(push_dir.x, 0.0, push_dir.z)
	if radial.length_squared() < 0.000001:
		return Vector3.ZERO
	radial = radial.normalized()
	var vel := Vector3(velocity.x, 0.0, velocity.z)
	if vel.length_squared() < 0.0001:
		return radial
	# 只有正在朝建筑内部顶时才改走切向；沿墙滑动或正在离开时保持径向推开
	if vel.normalized().dot(radial) >= -0.05:
		return radial
	var tangent := Vector3(-radial.z, 0.0, radial.x)
	var side_dot := tangent.dot(vel)
	if side_dot < -0.0001:
		tangent = -tangent
	elif absf(side_dot) <= 0.0001:
		# 正面顶住建筑时固定往一侧滑，避免两侧来回切换导致抖动
		if _army.get_instance_id() % 2 == 0:
			tangent = -tangent
	return (radial * 0.55 + tangent * 0.85).normalized()

func _separate_from(entity: GameEntity, delta: float, bm: RTSBattleManager) -> void:
	var dist = _army.global_position.distance_to(entity.global_position)
	var min_dist = _army.body_radius + entity.body_radius
	if dist < min_dist and dist > 0.001:
		if entity is Building and entity.team != _army.team:
			blocking_building = entity
		var overlap = min_dist - dist
		var push_dir = (_army.global_position - entity.global_position).normalized()
		var push_s = 10.0 if entity is Building and entity.entity_id == 27 and entity.team != _army.team else 15.0 if entity is Building else 8.0
		var push_amount: float = overlap * min(push_s * delta, 0.95)
		# 质量越大，自己承担的位移越小；建筑视为不可推动，全部由单位让位。
		var self_mass: float = _get_push_mass(_army)
		var other_mass: float = 1.0e9 if entity is Building else _get_push_mass(entity)
		var mass_ratio: float = other_mass / (self_mass + other_mass)
		var push_step: Vector3 = push_dir
		if entity is Building:
			var slide_dir := _building_slide_dir(push_dir, _army.velocity)
			if slide_dir != Vector3.ZERO:
				push_step = slide_dir
		else:
			var unit_slide := _unit_slide_dir(push_dir, _army.velocity)
			if unit_slide != Vector3.ZERO:
				push_step = unit_slide
		_try_push_position(push_step * push_amount * mass_ratio, bm)
	elif dist < 0.001:
		# 完全重叠时用实例 id 生成固定方向，避免随机抖动让整堆单位
		# 长时间留在同一点；不同单位方向不同，能更快散开。
		var angle: float = fmod(float(_army.get_instance_id()), 360.0) * (PI / 180.0)
		var offset := Vector3(cos(angle), 0.0, sin(angle)) * 0.15
		if not _try_push_position(offset, bm):
			_try_push_position(-offset, bm)

func _path_height(wp: Vector3, bm) -> float:
	if bm.has_node("Map") and bm.get_node("Map").has_method("get_height_at"):
		return bm.get_node("Map").get_height_at(wp)
	if bm.has_method("get_height_at_grid"):
		var g = bm.world_to_grid(wp)
		return bm.get_height_at_grid(g.x, g.y)
	return 0.0

# ==================== Path markers ====================

func _show_path():
	if not _path_sphere:
		_path_sphere = SphereMesh.new()
		_path_sphere.radius = 0.2; _path_sphere.height = 0.4
	if not _path_mat:
		_path_mat = StandardMaterial3D.new()
		_path_mat.albedo_color = Color(0, 1, 1, 0.8)
		if not _path_mat_end:
			_path_mat_end = StandardMaterial3D.new()
			_path_mat_end.albedo_color = Color(0, 1, 0, 0.8)  # green
			_path_mat_end.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_path_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hide_path()
	if astar_path.size() < 2: return
	var bm = _army.get_tree().get_first_node_in_group("battle_manager")

	if not bm: return
	# 框选大部队时只为第一个选中单位绘制路径，避免几十/上百条路径同时生成。
	if bm.selection != null and bm.selection.selected_entities.size() > 1:
		if bm.selection.selected_entities[0] != _army:
			return
	# 单条长路径也不逐格创建，按固定上限抽样；尾点始终保留。
	var points: Array = []
	if astar_path.size() <= MAX_PATH_PREVIEW_POINTS:
		points = astar_path
	else:
		var step: float = float(astar_path.size() - 1) / float(MAX_PATH_PREVIEW_POINTS - 1)
		for i in range(MAX_PATH_PREVIEW_POINTS):
			points.append(astar_path[int(round(float(i) * step))])
	var last_wp: Vector3 = astar_path[astar_path.size() - 1]
	for wp in points:
		var m = MeshInstance3D.new()
		m.mesh = _path_sphere
		m.position = Vector3(wp.x, _path_height(wp, bm) + 0.3, wp.z)
		# 路径点只是操作提示，不参与阴影投射，避免额外 shadow pass。
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Last waypoint is green
		if wp == last_wp:
			m.material_override = _path_mat_end
		else:
			m.material_override = _path_mat
		bm.add_child(m)
		_path_markers.append(m)

func _hide_path():
	for m in _path_markers:
		if is_instance_valid(m): m.queue_free()
	_path_markers.clear()

# ==================== A* Pathfinding (optimized) ====================

# Min-heap priority queue — O(log n) push/pop vs O(n) linear scan
class MinHeap extends RefCounted:
	var _data: Array = []  # [{tile: Vector2i, f: float}, ...]

	func size() -> int: return _data.size()
	func is_empty() -> bool: return _data.is_empty()

	func push(tile: Vector2i, f: float):
		_data.append({"tile": tile, "f": f})
		_sift_up(_data.size() - 1)

	func pop() -> Dictionary:
		if _data.is_empty(): return {}
		var result = _data[0]
		var last = _data.pop_back()
		if not _data.is_empty():
			_data[0] = last
			_sift_down(0)
		return result

	func _sift_up(idx: int):
		while idx > 0:
			var parent = (idx - 1) / 2
			if _data[idx].f >= _data[parent].f: break
			var tmp = _data[idx]; _data[idx] = _data[parent]; _data[parent] = tmp
			idx = parent

	func _sift_down(idx: int):
		var sz = _data.size()
		while true:
			var smallest = idx
			var left = 2 * idx + 1; var right = 2 * idx + 2
			if left < sz and _data[left].f < _data[smallest].f: smallest = left
			if right < sz and _data[right].f < _data[smallest].f: smallest = right
			if smallest == idx: break
			var tmp = _data[idx]; _data[idx] = _data[smallest]; _data[smallest] = tmp
			idx = smallest

# Shared wall cache — keyed by (bm_id, wall_cache_version, team).
# Stationary entities (buildings + resources) only move on build/destroy, so the
# wall set is rebuilt only when the battle manager's entity cache version bumps
# (NOT per frame, NOT per target — `end_tile` no longer invalidates it; the A*
# loop already skips wall checks for the goal tile).
static var _wall_set: Dictionary = {}    # Vector2i -> true
static var _wall_ver: int = -1
static var _wall_bm_id: int = -1
static var _wall_team: int = -1  # friendly-wall passability is team-dependent
static var _bridge_set: Dictionary = {}          # 桥所在格子
static var _ladder_set: Dictionary = {}          # 梯子使该敌方城墙格可通行
static var _transport_water: Dictionary = {}     # 运载船周围3格水域(陆军可通行)
static var _transport_frame: int = -1            # 运载船是移动的，水域标记单独做帧级缓存
static var _transport_team: int = -1

func _calculate_astar_path(target_pos: Vector3, stop_range: float = 0.0) -> Array:
	_last_path_partial = false
	var bm = _army._get_bm() as RTSBattleManager
	if not bm: return []
	var start = _army.global_position
	var start_tile = bm.world_to_grid(start)
	var end_tile = bm.world_to_grid(target_pos)

	if start_tile == end_tile and stop_range <= 0:
		# 同格移动不能返回空路径：_apply_path 会把空路径当成“不可达”写进永久黑名单，
		# 之后该格再也无法寻路。返回一个起点航点，让 process_move 走最终接近并正常到达。
		var half_map: float = RTSConfig.MAP_SIZE / 2.0
		return [Vector3(start_tile.x - half_map, 0.0, start_tile.y - half_map)]

	# 静态墙集合按实体缓存版本号重建（建造/摧毁时才变化），运载船水域单独做帧级缓存
	var frame = Engine.get_process_frames()
	var bm_id = bm.get_instance_id()
	if _wall_bm_id != bm_id or _wall_ver != bm._wall_cache_version or _wall_team != _army.team:
		_wall_set.clear()
		_bridge_set.clear()
		_ladder_set.clear()
		for e in bm.entities.get_children():
			if not (e is GameEntity) or e.health <= 0: continue
			if not (e is Building or e is WorldResource): continue
			var eg = bm.world_to_grid(e.global_position)
			# 桥不阻挡通行，单独记录
			if e is Building and e.entity_id == 7:
				_bridge_set[eg] = true
				continue
			# 梯子不阻挡通行，且使其相邻敌方城墙可通行
			if e is Building and e.entity_id == 8:
				# 标记梯子相邻的敌方城墙格为可通行（O(8) 查墙体网格，替代 O(8×n) 全量扫描）
				for dx in range(-1, 2):
					for dy in range(-1, 2):
						if dx == 0 and dy == 0: continue
						var wall_b = bm._wall_entity_grid.get(Vector2i(eg.x + dx, eg.y + dy))
						if wall_b and wall_b.team != _army.team:
							_ladder_set[Vector2i(eg.x + dx, eg.y + dy)] = true
				continue
			if e is Building and e.entity_id == 27 and e.team == _army.team: continue
			_wall_set[eg] = true
		_wall_bm_id = bm_id; _wall_ver = bm._wall_cache_version; _wall_team = _army.team
	# 运载船会移动：水域标记做帧级缓存（同一帧多个单位寻路只算一次）
	if _transport_frame != frame or _transport_team != _army.team:
		_transport_water.clear()
		for e in bm.entities.get_children():
			if e is Army and e.entity_id == 9 and e.health > 0 and e.team == _army.team:
				var tg = bm.world_to_grid(e.global_position)
				for rdx in range(-3, 4):
					for rdy in range(-3, 4):
						var tx = tg.x + rdx; var ty = tg.y + rdy
						if tx >= 0 and tx < RTSConfig.MAP_SIZE and ty >= 0 and ty < RTSConfig.MAP_SIZE:
							if bm.get_terrain_at_grid(tx, ty) == 2:
								_transport_water[Vector2i(tx, ty)] = true
		_transport_frame = frame; _transport_team = _army.team
	var wall_cache = _wall_set

	# A* data structures — Vector2i keys (fast int hash, no string allocs)
	var open_list = MinHeap.new()
	var closed_set := {}  # Vector2i -> true
	var g_score := {}     # Vector2i -> float
	var came_from := {}   # Vector2i -> Vector2i

	g_score[start_tile] = 0.0
	open_list.push(start_tile, _heuristic(start_tile, end_tile) * 1.2)

	var max_nodes: int = 1000
	# 固定 1000 节点在 100×100 地图上不够跨河：桥头堡等地图的浅滩偏离起点/终点连线时，
	# A* 会沿着河岸展开 1500~1800 个节点才找到渡口，旧上限会提前返回空路径。
	# 表现就是 AI 部队堵在集结点、永远不发起进攻。按起终点距离放宽预算，同时保留硬上限。
	# 150×150 的 2v2/3v3 河图上，双河/海湾类地图的绕行更远（实测最坏约 12k 节点），
	# 因此预算与上限相应上调；普通短距离寻路命中节点数不变，不影响常规性能。
	var tile_span: int = absi(start_tile.x - end_tile.x) + absi(start_tile.y - end_tile.y)
	max_nodes = clampi(2000 + tile_span * 80, 2000, 12000)
	var nodes_explored := 0
	var from_height := _get_tile_height(start_tile, bm)
	var best_partial_tile: Vector2i = start_tile
	var best_partial_h: float = _heuristic(start_tile, end_tile)

	while not open_list.is_empty() and nodes_explored < max_nodes:
		var current_entry = open_list.pop()
		if current_entry.is_empty(): break
		var cur_tile: Vector2i = current_entry.tile
		nodes_explored += 1
		var cur_h: float = _heuristic(cur_tile, end_tile)
		if cur_h < best_partial_h:
			best_partial_h = cur_h
			best_partial_tile = cur_tile

		# Goal checks
		if stop_range > 0:
			# 用曼哈顿距离判断“已进入攻击距离”：切比雪夫距离会把 (5,5) 这种对角格
			# 当成距离5，实际中心距离 7.07，远程单位会停在射程外，表现为锁敌后不攻击。
			# 曼哈顿距离 <= stop_range 时，欧氏距离必然 <= stop_range，终点一定在射程内。
			if _heuristic(cur_tile, end_tile) <= stop_range:
				var path2 = _reconstruct_path(came_from, cur_tile)
				if path2.size() > 1: path2.pop_front()
				return path2
		if cur_tile == end_tile:
			var path = _reconstruct_path(came_from, cur_tile)
			if path.size() > 1: path.pop_front()
			return path

		closed_set[cur_tile] = true
		var cur_g = g_score.get(cur_tile, 9999.0)
		from_height = _get_tile_height(cur_tile, bm)

		# 8-neighbor expansion — merged terrain+wall+slope check
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				if dx == 0 and dy == 0: continue
				var neighbor = Vector2i(cur_tile.x + dx, cur_tile.y + dy)
				if neighbor.x < 0 or neighbor.x >= RTSConfig.MAP_SIZE or neighbor.y < 0 or neighbor.y >= RTSConfig.MAP_SIZE: continue
				if closed_set.has(neighbor): continue

				# Single terrain cost lookup (merged passability + cost, was 2-3 calls)
				var terrain_cost = _get_terrain_cost(neighbor, bm, wall_cache)
				if terrain_cost >= 999.0: continue

				# Slope check (was in separate _can_traverse call)
				var neighbor_h = _get_tile_height(neighbor, bm)
				if abs(neighbor_h - from_height) > 3.0: continue

				# Wall collision (skip for goal tile — allow reaching target)
				if neighbor != end_tile and wall_cache.has(neighbor) and not _ladder_set.has(neighbor): continue

				var step_cost = terrain_cost * (1.414 if (dx != 0 and dy != 0) else 1.0)
				var tentative_g = cur_g + step_cost

				if tentative_g < g_score.get(neighbor, 9999.0):
					came_from[neighbor] = cur_tile
					g_score[neighbor] = tentative_g
					open_list.push(neighbor, tentative_g + _heuristic(neighbor, end_tile) * 1.2)

	# 节点预算耗尽（而不是终点真的不可达）时，返回走到离目标最近的可达格的路径，
	# 让单位先推进一段；Army 会在该段走完后从新位置继续寻路。
	if best_partial_tile != start_tile:
		var partial := _reconstruct_path(came_from, best_partial_tile)
		if partial.size() > 1:
			partial.pop_front()
		if partial.size() > 0:
			_last_path_partial = true
			return partial
	return []

func _heuristic(a: Vector2i, b: Vector2i) -> float:
	return abs(a.x - b.x) + abs(a.y - b.y)

func _get_terrain_cost(tile: Vector2i, bm: RTSBattleManager, wall_cache: Dictionary) -> float:
	# 梯子使敌方城墙可通行
	if _ladder_set.has(tile): return 3.0
	# 普通建筑/资源阻挡
	if wall_cache.has(tile): return 5.0
	var terrain = bm.get_terrain_at_grid(tile.x, tile.y)
	var cost: float
	if _army.water_capable:
		# 水军无法通过桥
		cost = 999.0 if _bridge_set.has(tile) else (0.8 if terrain == 2 else 999.0)
	else:
		# 浅滩：仍是水格，但陆军可以涉水通过；沼泽：陆地但泥泞难行（成本高于平原、低于山地）
		var ov := bm.get_overlay_at_grid(tile.x, tile.y)
		if ov == 3:
			cost = 2.5
		elif ov == 2:
			cost = 1.8
		else:
			match terrain:
				0: cost = 1.0
				1: cost = 2.5
				2: cost = 1.5 if _bridge_set.has(tile) or _transport_water.has(tile) else 999.0
				_: cost = 999.0
	return cost

func _get_tile_height(tile: Vector2i, bm: RTSBattleManager) -> float:
	if bm and bm.has_method("get_height_at_grid"):
		return bm.get_height_at_grid(tile.x, tile.y)
	return 0.0

func _reconstruct_path(came_from: Dictionary, end_tile: Vector2i) -> Array:
	# Use append + reverse instead of push_front (O(1) per step vs O(n))
	var path := []
	var current = end_tile
	var half = RTSConfig.MAP_SIZE / 2.0
	path.append(Vector3(current.x - half, 0, current.y - half))
	# 远距离/绕河路径可能超过 200 格，必须按实际 came_from 链回溯，不能截断
	for _i in range(RTSConfig.MAP_SIZE * 4):
		if not came_from.has(current): break
		current = came_from[current]
		path.append(Vector3(current.x - half, 0, current.y - half))
	path.reverse()
	return path

# 检查指定城墙格是否有己方梯子相邻（O(8) 查梯子网格，替代 O(8×n) 全量扫描）
func _has_adjacent_ladder(bm: RTSBattleManager, wall_tile: Vector2i, my_team: int) -> bool:
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if dx == 0 and dy == 0: continue
			var ladder_b = bm._ladder_entity_grid.get(Vector2i(wall_tile.x + dx, wall_tile.y + dy))
			if ladder_b and ladder_b.health > 0 and ladder_b.team == my_team:
				return true
	return false
