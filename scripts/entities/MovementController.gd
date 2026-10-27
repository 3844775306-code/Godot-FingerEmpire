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
# 后期几十个单位同时追击时，0.7 秒一次仍会把 A* 预算排队堆到几十个；
# 拉长到 1 秒并配合下面的目标移动容差，先让已有路径继续走，减少无效重算。
const ATTACK_PATH_COOLDOWN_MS: int = 1000
# 追击目标在小范围内移动时继续沿用现有路径，避免每 1 秒为每个单位重跑一次 A*
const ATTACK_TARGET_MOVE_TOLERANCE: float = 3.0
# 队列压力阈值：与 RTSBattleManager.ASTAR_BACKLOG_PRESSURE 保持一致。
# 排队多时进一步降低追击重算频率、放大目标移动容差，先让现有路径继续走。
const A_STAR_PRESSURE_THRESHOLD: int = 30
# 路径预览最多采样多少个点。贴地指引带内部会再按 1.1 米加密并逐顶点贴地，
# 这里只限制单条路径的顶点总量，避免超长路径生成过大的网格。
const MAX_PATH_PREVIEW_POINTS: int = 200
# 路径指引带排头跟随单位的步长：单位每走这么远才重建一次网格，
# 既保证「走一段收一段」的实时感，又不至于每帧重新贴地。
const PATH_HEAD_STEP: float = 0.45
var _last_attack_path_ms: int = -100000
# 缓坡速度平滑：避免在坡道入口/出口瞬间跳速，也避免同一格来回抖动。
var _slope_speed_mult: float = 1.0
# A* 分帧预算用：当前请求被延后时暂存目标，下一帧继续尝试。
var _pending_path: bool = false
var _pending_target: Vector3 = Vector3.ZERO
var _pending_stop_range: float = 0.0
var _pending_since_ms: int = 0
# A* 节点预算耗尽时不要直接返回空路径：先沿着“离目标最近的可达格”推进，
# 到达该段末端后由 Army 重新寻路。否则大部队攻击移动会停在原地。
var path_partial: bool = false
var _last_path_partial: bool = false
# 大量单位同时移动/攻击移动时 A* 预算可能连续多帧排不到某个单位。
# 以前等 4~8 秒后直接判“无路”再重发，结果队尾单位反复经历
# “排队→超时失败→换目标/重发→继续排队”，永远拿不到路径。
# 现在排队超过这个时间就强制放行一次（忽略普通 A* 配额），
# 真正算不出路径才由 _apply_path 写入失败标记，交给 Army 的换目标/拆墙兜底。
const PENDING_PATH_URGENT_MS: int = 1200
# 状态层偶发漏发路径请求时的兜底：没有路径、没有排队、也没有失败标记，
# 但目标仍很远，隔一段时间主动补一次请求，避免单位永久停在“移动中但无路径”。
const NO_PATH_REISSUE_INTERVAL_MS: int = 1200
var _next_no_path_reissue_ms: int = 0
# 直走判定失败后短时间内不要每个物理帧重复采样整条长路径；
# 缓存只缓存“不能直走”，能直走时直接返回路径，不需要缓存。
const DIRECT_CHECK_CACHE_MS: int = 250
var _direct_check_result: bool = true
var _direct_check_ms: int = 0

# 路径预览：一条贴地流动的指引带（替代原来那一串青色小球），每支选中军队各一条。
var _path_guide: GroundPathGuide = null
var _path_preview_points: Array = []  # 当前指引带使用的路径点，用来判断是否需要重建
var _path_preview_tail: Array = []    # 除排头之外还剩的路径点（用来判断路径是否被消费掉）
var _path_built_head: Vector3 = Vector3(INF, 0.0, INF)  # 上次建网格时单位的脚下位置
var _is_selected: bool = false

# Collision
var collision_timer: float = 0.0
# 当前物理挤靠的敌方建筑：攻击目标在墙后时 A* 常从建筑格穿过去，
# 单位实际会顶在墙上原地踏步；Army 用它改打这面挡路的墙。
var blocking_building: Building = null
const COLLISION_INTERVAL: float = 0.15
# 山地通行：普通山体(terrain=1)对陆军封闭，只有显式标记的缓坡(overlay=4)
# 与山顶台地(overlay=5)能走。坡度只负责在这些可走坡面上调整速度与 A* 成本，
# 不再作为“能不能上山”的唯一依据。
# 缓坡/台地基础成本高于平原，避免部队为了抄近路随意翻山。
const SLOPE_BASE_COST: float = 1.35
const PLATEAU_BASE_COST: float = 1.1
var _last_recalc_frame: int = -99  # prevent recalc spam
# A* 预算按“渲染帧”计数，但一个渲染帧里可能补跑多个物理步。低帧率时如果每个
# 物理步都重试 pending 请求，几百个单位会把直路检测和预算查询重复做 4~8 次，
# 反而让帧率继续下跌。这里保证每个单位每渲染帧最多重试一次。
var _last_pending_frame: int = -1
var _path_cache: Dictionary = {}  # Vector2i(world_x, world_z) -> path_array, cleared on building placement
# 攻击移动群体路线：同目的地的大部队共用一个 A* 结果，避免几十个单位
# 同时展开上千节点把 A* 预算吃光。单位从最近航点并入缓存路线。
const GROUP_PATH_MERGE_RADIUS: float = 7.0
const GROUP_PATH_CACHE_CELL: float = 2.0
# 追击时新路径还在排队、旧路径已走完，且目标已接近攻击距离，允许最后几米
# 直接朝目标走。否则每一次目标移动触发重新寻路都会让单位停一帧甚至更久，
# 表现为“追着追着突然站住”。
const CHASE_DIRECT_APPROACH_MARGIN: float = 6.0
# 部分路径（A* 节点预算耗尽/终点暂时不可达）走完一段后立即续算下一段。
# 以前要等 Army 的 0.5 秒重试计时器，单位每走完一小段就会站住半秒，
# 大部队长途行军时表现为走走停停。
const PARTIAL_PATH_CONTINUE_MS: int = 80
var _next_partial_continue_ms: int = 0
var _blacklist: Dictionary = {}  # Vector2i -> 过期时间戳，暂时跳过不可达目标
# 普通移动失败只临时拉黑：如果永久记住，玩家一次失败后同一位置就再也点不动，
# 只有建筑布局变化触发 recalculate() 才会恢复，表现为“单位不听移动命令”。
const MOVE_BLACKLIST_TTL_MS: int = 4000

func _init(army: Army):
	_army = army
	# 错开各单位首次碰撞分离的帧，避免几百个单位在同一物理帧集中做近邻查询
	collision_timer = randf_range(0.0, COLLISION_INTERVAL)
	# 单位死亡/离场时清理挂在 battle_manager 下的路径指引带。不能用
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
		var bm_pressure = _get_bm()
		var pressure: bool = bm_pressure != null and bm_pressure.get_astar_pending_estimate() >= A_STAR_PRESSURE_THRESHOLD
		# 目标只挪动一点点时旧路径仍然可用，先不重算；等偏移超过容差或冷却到期再更新。
		# 排队时放大容差，避免为几米的追击漂移持续制造新的 A* 请求。
		var move_tolerance: float = ATTACK_TARGET_MOVE_TOLERANCE * (1.6 if pressure else 1.0)
		if astar_path.size() > 0 and astar_target != Vector3.ZERO and astar_target.distance_to(pos) < move_tolerance:
			return
		# 已经有一个请求在排队时不要重复占预算；process_move 会按重试配额继续处理
		if _pending_path and astar_path.is_empty():
			return
		var now_ms := Time.get_ticks_msec()
		# 首次追击按 unit id 分 16 个相位错峰，避免全军在同一帧集中跑 A*；
		# 后续只加少量抖动，保证追击路径不会滞后太久。
		var phase_ms := int(_army.get_instance_id() % 16) * 30
		var cooldown_ms := ATTACK_PATH_COOLDOWN_MS + int(_army.get_instance_id() % 5) * 15
		# 队列已经排长时，追击路径降频到约 2.2 秒一次；路径为空时下面的
		# 冷却分支会放行补发请求，不会让单位因为降频而永久站着。
		if pressure:
			cooldown_ms = int(cooldown_ms * 2.2)
		if _last_attack_path_ms < 0:
			_last_attack_path_ms = now_ms - cooldown_ms + phase_ms
		if now_ms - _last_attack_path_ms < cooldown_ms:
			# 还有旧路径可走时，冷却用于限制无效重算；
			# 但路径已经为空、也没有失败标记时，单位正站着等，继续卡冷却只会
			# 让它保持“追击中却无路径”。这种情况立即补一次请求；
			# 失败路径仍交给 Army 的换目标/拆墙超时，避免每帧重算。
			if not astar_path.is_empty() or attack_path_failed or move_path_failed:
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

func _try_compute_path(pos: Vector3, stop_range: float, bm: RTSBattleManager = null,
		is_retry: bool = false, force: bool = false) -> bool:
	if bm == null:
		bm = _get_bm()
	# 开阔地直走不消耗 A* 预算：这是后期队列增长的主要来源。
	# 必须放在 reserve 之前，否则“直走”虽然不跑 A*，仍会占掉其他单位的寻路名额。
	if bm != null:
		var now_ms := Time.get_ticks_msec()
		# 只在同一目标近期判定为“不能直走”时跳过采样，避免待处理请求
		# 每一帧都把整条长路径重新扫一遍；A* 失败/排队仍会正常处理。
		var cached_blocked: bool = not _direct_check_result \
			and now_ms - _direct_check_ms < DIRECT_CHECK_CACHE_MS
		if not cached_blocked:
			var direct_path := _try_direct_path(bm, pos, stop_range)
			_direct_check_result = not direct_path.is_empty()
			_direct_check_ms = now_ms
			if not direct_path.is_empty():
				_last_path_partial = false
				_apply_path(pos, direct_path, stop_range)
				return true
	# 攻击移动：如果同目的地已经有人算好路线，直接从最近航点并入，
	# 不必再跑一次 A*。这一步在 reserve 之前，能显著降低大部队的寻路压力。
	if bm != null and stop_range <= 0.0 and _is_group_attack_move():
		if _try_merge_group_path(pos, bm):
			return true
	# 已经排队等过的请求走 retry 配额。若新请求可以吃满全部名额，场景树里排在
	# 后面的单位会被前面不断产生的新请求长期挤掉，表现为“有移动命令但一直没路径”。
	if bm != null and not bm.reserve_astar_request(is_retry, force):
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
			# duplicate：astar_path 会在 process_move 里被 pop_front 消费，
			# 缓存必须保留完整路线给后面的单位复用。
			_path_cache[key] = astar_path.duplicate()
			if _is_group_attack_move():
				var bm = _get_bm()
				if bm != null:
					bm.set_group_attack_path(_group_path_cache_key(pos), astar_path, _army.global_position)
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

func _try_compute_pending_path(bm: RTSBattleManager, force: bool = false) -> bool:
	if not _pending_path:
		return true
	if not _try_compute_path(_pending_target, _pending_stop_range, bm, true, force):
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
		if astar_path.size() > 0:
			_path_cache[key] = astar_path.duplicate()  # only cache valid paths
			if _is_group_attack_move():
				var bm = _get_bm()
				if bm != null:
					bm.set_group_attack_path(_group_path_cache_key(astar_target), astar_path, _army.global_position)
		if _is_selected:
			_show_path()

func get_current_target() -> Vector3:
	if is_instance_valid(_army.current_target):
		return _army.current_target.global_position
	if _army.is_attack_moving:
		return _army.attack_move_target
	if _army._order_is(_army.UnitState.MOVING) or _army._order_is(_army.UnitState.BUILDING):
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
	_next_no_path_reissue_ms = 0
	_next_partial_continue_ms = 0
	_stop_velocity()
	# 命令结束/单位停下后不要把最后一段路径留在屏幕上。
	if _is_selected:
		_hide_path()

# 只处理“移动逻辑还在要路径，但既没排队也没有失败标记”的漏网状态。
# 失败的路径交给 Army 的换目标/拆墙超时，不能在这里反复重算。
func _try_reissue_missing_path(target_pos: Vector3) -> bool:
	if target_pos == Vector3.ZERO or _pending_path or not astar_path.is_empty():
		return false
	if move_path_failed or attack_path_failed or path_partial:
		return false
	var now_ms := Time.get_ticks_msec()
	if now_ms < _next_no_path_reissue_ms:
		return false
	_next_no_path_reissue_ms = now_ms + NO_PATH_REISSUE_INTERVAL_MS
	var stop_range := 0.0
	if _army.current_target != null and is_instance_valid(_army.current_target) \
			and _army.current_target is GameEntity and not (_army.current_target is WorldResource) \
			and not _army._order_is(_army.UnitState.MOVING):
		stop_range = _army.attack_range
	clear_blacklist_at(target_pos)
	set_move_target(target_pos, stop_range)
	return true

# 当前是否在追击一个“锁定了但还没进入射程”的目标。
func _is_chasing_locked_target() -> bool:
	if _army == null or _army.current_target == null \
			or not is_instance_valid(_army.current_target):
		return false
	if not _army._order_is(_army.UnitState.ATTACKING):
		return false
	return _army._combat_edge_distance(_army.current_target) > _army.attack_range

# 追击路径暂时中断时，是否允许直接朝目标走最后几米。
# 只对已接近攻击距离、中间无悬崖、且没有被建筑实际挡住的目标放行；
# 远距离/隔墙目标仍然等 A*，不能靠直线硬挤。
func _can_direct_chase(bm: RTSBattleManager) -> bool:
	if bm == null or not _is_chasing_locked_target():
		return false
	if blocking_building != null and is_instance_valid(blocking_building):
		return false
	var edge: float = _army._combat_edge_distance(_army.current_target)
	if edge > _army.attack_range + CHASE_DIRECT_APPROACH_MARGIN:
		return false
	return not _is_cliff_between_positions(
		bm, _army.global_position, _army.current_target.global_position)

# 当前移动命令使用的寻路 stop_range：追击目标用攻击距离，其它命令用 0。
func _current_move_stop_range() -> float:
	if _army != null and _army.current_target != null \
			and is_instance_valid(_army.current_target) \
			and _army._order_is(_army.UnitState.ATTACKING):
		return _army.attack_range
	return 0.0

# 部分路径即将/已经走完时，立刻从当前位置续算下一段，避免每段之间停顿。
# allow_empty=false 只在还剩 1 个航点时预取；allow_empty=true 用于路径已空。
func _try_continue_partial_path(target_pos: Vector3, allow_empty: bool) -> bool:
	if not path_partial or target_pos == Vector3.ZERO:
		return false
	if not allow_empty and astar_path.size() > 1:
		return false
	if not allow_empty and astar_path.is_empty():
		return false
	var now_ms := Time.get_ticks_msec()
	if now_ms < _next_partial_continue_ms:
		return false
	_next_partial_continue_ms = now_ms + PARTIAL_PATH_CONTINUE_MS
	path_partial = false
	_last_path_partial = false
	clear_blacklist_at(target_pos)
	set_move_target(target_pos, _current_move_stop_range())
	return true

# 单位停止/进入攻击距离后必须把残留速度清零，否则 Army 的 simple_idle 永远不成立，
# 后期几百个已经停下的单位仍会每 0.15~0.22 秒做一次碰撞近邻查询。
func _stop_velocity() -> void:
	if _army != null:
		var had_velocity: bool = _army.velocity.length_squared() > 0.04
		_army.velocity = Vector3.ZERO
		_slope_speed_mult = 1.0
		# 从移动到停下的瞬间刷新一次动画，否则 MOVING/ATTACKING 状态可能继续播放走路动作
		if had_velocity and _army.is_inside_tree():
			_army._refresh_animation_now()

# ==================== Main movement update ====================

func process_move(delta, bm: RTSBattleManager):
	# 之前因 A* 预算被延后的目标，继续在本帧尝试；普通移动仍未轮到则原地等待，
	# 不能拿旧路径继续走，否则大部队下令后会先朝旧目标移动。
	# 攻击追目标时旧路径通常仍指向同一目标，可以边沿旧路径推进边等新路径。
	if _pending_path:
		if not _army.is_attack_moving and not _army._order_is(_army.UnitState.MOVING) \
				and not _army._order_is(_army.UnitState.ATTACKING):
			# 只有真正不需要寻路的命令才丢弃待处理请求；攻击索敌必须保留，
			# 否则 A* 预算连续几帧排不到时会表现为“锁着目标却一步不走”。
			_pending_path = false
			_pending_since_ms = 0
		else:
			var frame: int = Engine.get_process_frames()
			# 同一渲染帧内只重试一次。物理帧会在一帧里补跑多次，而 A* 预算
			# 是每渲染帧重置的；重复重试只会在预算耗尽后反复做直路扫描。
			if frame != _last_pending_frame:
				_last_pending_frame = frame
				var pending_age_ms: int = Time.get_ticks_msec() - _pending_since_ms
				if pending_age_ms >= PENDING_PATH_URGENT_MS:
					# 排队过久：强制放行一次（每帧限额），不能再等普通配额。
					# 这样即使队列一直被新请求插队，队尾单位也一定能拿到一次真正的寻路结果：
					# 有路就继续走，无路就由 _apply_path 写失败标记交给 Army 兜底。
					_try_compute_pending_path(bm, true)
				else:
					_try_compute_pending_path(bm)
			if _pending_path:
				# 攻击移动/追击即使新路径还没算完，也可以先沿现有路径继续推进；
				# 若旧路径已走完但目标就在几米内，允许直接朝目标接近。
				# 普通移动没有可用新路径时先停住，等下一帧重试。
				var keep_moving: bool = astar_path.size() > 0 \
					and (_army.is_attack_moving or _is_chasing_locked_target())
				if not keep_moving and not _can_direct_chase(bm):
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
		if _army.current_target is WorldResource and h_dist <= Army.GATHER_STANDOFF_GAP:
			_stop_velocity()
			return
		elif _army.current_target is GameEntity and h_dist <= _army.attack_range:
			_stop_velocity()
			return

	var target_pos = get_current_target()
	if target_pos == Vector3.ZERO:
		_stop_velocity()
		return
	# 部分路径只剩最后 1 个航点（或刚走空）时先续算，不等 Army 的 0.5 秒重试。
	if path_partial:
		if astar_path.is_empty():
			# 路径已经走空：不允许冷却把单位晾在路中间，立即续算。
			_next_partial_continue_ms = 0
		_try_continue_partial_path(target_pos, astar_path.is_empty())

	# Follow A* path
	var move_target = target_pos
	# No A* path = no movement, unless close to target (final approach)
	if astar_path.size() == 0:
		if _can_direct_chase(bm):
			# 追击目标已进入最后几米：旧路径在等待新路径时走完也不要站住，
			# 直接朝目标推进，交由 Army 的攻击距离判定停下。
			move_target = target_pos
		elif astar_target.distance_squared_to(_army.global_position) > 3.0:
			# 采集目标所在的格子本身是 A* 阻挡格，寻路终点常常停在离资源 1~3 米处。
			# 普通移动在 1.7 米外就原地等待重算，农民于是站在远处“假采集”（资源血量不掉）。
			# 对采集目标放行最后几米的直线接近，终点取资源边缘外 0.5 米的站位点，
			# 不直接撞进资源模型（撞进去会被碰撞滑动挤开，站位会抖）。
			var standoff := _gather_standoff_point(target_pos)
			if standoff != Vector3.ZERO:
				move_target = standoff
			else:
				_try_reissue_missing_path(target_pos)
				_stop_velocity()
				return  # too far, no path → stay put until the request is served
		# 无路径的最终接近也不能跨悬崖：目标就在脚下另一侧时，
		# 直接插值过去会让单位从台地边缘滑下陡坡。
		if bm != null and _is_cliff_between_positions(bm, _army.global_position, move_target):
			_stop_velocity()
			return
		# Close enough: allow final approach to exact target

	if astar_path.size() > 0:
		move_target = astar_path[0]
		var h_dist = Vector2(move_target.x - _army.global_position.x, move_target.z - _army.global_position.z)
		if h_dist.length() < 0.5:
			astar_path.pop_front()
			# 走过一个航点后让指引带跟着收一段（_show_path 内部按 0.45 米步长节流，
			# 不会每帧重建网格）。路径走空时不要立刻收起：单位可能还在做最后几米接近，
			# 由 _show_path 用当前位置到目的地补一条短线。
			if _is_selected:
				_show_path()
			if astar_path.size() > 0:
				move_target = astar_path[0]
	# 沿着长直路段前进时不会经过航点，这里按位移节流地刷新一次排头，
	# 让线一直贴着脚下走，而不是等到下一个航点才跳一段。
	# 路径走空但单位仍在最终接近/直追时，也要补建这条短线；停下后收起。
	if _is_selected:
		if _path_guide == null or not is_instance_valid(_path_guide):
			if astar_path.is_empty() and _preview_motion_active():
				_show_path()
		else:
			var head_now: Vector3 = _army.global_position
			if _path_built_head.distance_to(head_now) > PATH_HEAD_STEP:
				_show_path()
			elif astar_path.is_empty() and not _preview_motion_active():
				_hide_path()
	# 兜底：路径可能因建筑变化/单位被挤动而临期，实际行走前再检查一次下一段坡度。
	# 尤其禁止从高地/台地边缘直接走下悬崖；发现后立即重算，而不是停下等 Army 的
	# 0.75~1.2 秒重试计时器（那会表现为行军途中突然站住一两秒）。
	if bm != null and astar_path.size() > 0 and _is_cliff_between_positions(bm, _army.global_position, move_target):
		_stop_velocity()
		astar_path.clear()
		clear_blacklist_at(target_pos)
		var stop_range: float = _current_move_stop_range()
		set_move_target(target_pos, stop_range)
		if astar_path.is_empty() and not _pending_path:
			move_path_failed = true
		return
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
	# 统一坡度：坡度越陡，速度越慢；速度倍率就是 A* 时间成本的倒数。
	# 只改本帧速度，不永久修改 _army.speed，避免影响攻击、追击和停走逻辑；
	# 平滑过渡避免跨格时速度跳变。
	var slope_mult: float = _get_slope_speed_multiplier(bm, _army.global_position, move_target)
	_slope_speed_mult = lerpf(_slope_speed_mult, slope_mult, clampf(delta * 8.0, 0.0, 1.0))
	var effective_speed: float = _army.speed * _slope_speed_mult
	# 海军不能越过岸线：A* 会绕开陆地，但追击/采集的最后几米是直线接近，
	# 目标点可能落在岸上；这里按实际地形再拦一次，船停在岸边而不是开上岸。
	if _army.water_capable and bm != null:
		var lookahead: float = maxf(effective_speed * delta * 2.0, 0.8)
		var next_water_pos: Vector3 = _army.global_position + Vector3(move_dir.x, 0.0, move_dir.z) * lookahead
		if not _can_push_to(next_water_pos, bm):
			_stop_velocity()
			return
	var prev_pos: Vector3 = _army.global_position
	_army.velocity = Vector3(move_dir.x, 0, move_dir.z) * effective_speed
	_army.move_and_slide()
	# 碰撞/滑动也可能把船体挤出岸线；移动后按实际落点再校验一次并回退。
	if _army.water_capable and bm != null and not _can_push_to(_army.global_position, bm):
		_army.global_position = prev_pos
		_stop_velocity()
		return
	# 陆地单位的脚步音由 Army._play_step_sfx 按实际落脚点触发；
	# 这里只保留船只的持续航行音，避免和脚步音重复。
	if _army.speed > 0.1 and Engine.get_process_frames() % 40 == 0:
		var terr = bm.get_terrain_at(_army.global_position) if bm else 0
		if terr == 2 and _army.water_capable:
			_army._play_sfx_if_visible("sail")

	# 朝移动方向转身：按单位质量换算出的角速度平滑转过去，
	# 重单位掉头慢、轻单位灵活。以前直接 look_at() 是瞬间对准，看不出体量差别。
	if move_dir.length() > 0.01:
		_army.turn_toward_dir(move_dir, delta)

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
				# 城墙模型生成时会被自动缩放，顶面高度必须按模型实例计算；
				# 固定加 WALL_TOP_HEIGHT 会让单位陷进 2 米高的墙体里。
				var wall_top_h: float = bm.get_wall_top_height(wall_b)
				if wall_b.team == _army.team:
					target_height += wall_top_h  # friendly wall
				elif _has_adjacent_ladder(bm, gpos2, _army.team):
					target_height += wall_top_h  # laddered enemy wall
			_army.global_position.y = move_toward(_army.global_position.y, target_height, 5.0 * delta)

# 根据实际格间高差计算移速倍率。所有陆地地形统一按坡度处理：
# 移速 = 1 / 时间倍率，因此 A* 的成本与这里严格一致。
func _get_slope_speed_multiplier(bm: RTSBattleManager, from_pos: Vector3, to_pos: Vector3) -> float:
	if bm == null:
		return 1.0
	var from_tile: Vector2i = bm.world_to_grid(from_pos)
	var to_tile: Vector2i = bm.world_to_grid(to_pos)
	if from_tile == to_tile:
		return 1.0
	var step_len := sqrt(float((to_tile.x - from_tile.x) * (to_tile.x - from_tile.x)
		+ (to_tile.y - from_tile.y) * (to_tile.y - from_tile.y)))
	if step_len < 0.001:
		return 1.0
	var dh: float = _get_tile_height(to_tile, bm) - _get_tile_height(from_tile, bm)
	if absf(dh) < 0.02:
		return 1.0
	return 1.0 / RTSConfig.slope_time_multiplier(dh, step_len)

func _is_cliff_between_positions(bm: RTSBattleManager, from_pos: Vector3, to_pos: Vector3) -> bool:
	if bm == null:
		return false
	var from_tile: Vector2i = bm.world_to_grid(from_pos)
	var to_tile: Vector2i = bm.world_to_grid(to_pos)
	if from_tile == to_tile:
		return false
	return _is_cliff_between_tiles(bm, from_tile, to_tile)

func _is_cliff_between_tiles(bm: RTSBattleManager, from_tile: Vector2i, to_tile: Vector2i) -> bool:
	# 普通山壁整格封闭：哪怕高差看起来不大，也不允许直接踏上山体。
	if _is_blocked_mountain_tile(bm, from_tile) or _is_blocked_mountain_tile(bm, to_tile):
		return true
	# 山顶台地(5)只能从缓坡(4)或另一块台地进入；山脚/平地不能直接踏上台地边缘。
	if _is_plateau_transition_blocked(bm, from_tile, to_tile):
		return true
	var step_len := sqrt(float((to_tile.x - from_tile.x) * (to_tile.x - from_tile.x)
		+ (to_tile.y - from_tile.y) * (to_tile.y - from_tile.y)))
	if step_len < 0.001:
		return false
	var dh: float = _get_tile_height(to_tile, bm) - _get_tile_height(from_tile, bm)
	return RTSConfig.is_cliff_slope(dh, step_len)

# terrain=1 且没有缓坡(4)/台地(5)标记的格子就是不可通行的山壁。
func _is_blocked_mountain_tile(bm: RTSBattleManager, tile: Vector2i) -> bool:
	if bm == null:
		return false
	if bm.get_terrain_at_grid(tile.x, tile.y) != 1:
		return false
	var ov: int = bm.get_overlay_at_grid(tile.x, tile.y)
	return ov != 4 and ov != 5

# 台地边缘只允许接缓坡或另一块台地；平地/水面直接贴着台地会被当成悬崖。
func _is_plateau_transition_blocked(bm: RTSBattleManager, from_tile: Vector2i, to_tile: Vector2i) -> bool:
	if bm == null:
		return false
	var from_ov: int = bm.get_overlay_at_grid(from_tile.x, from_tile.y)
	var to_ov: int = bm.get_overlay_at_grid(to_tile.x, to_tile.y)
	if from_ov != 5 and to_ov != 5:
		return false
	var from_high := from_ov == 4 or from_ov == 5
	var to_high := to_ov == 4 or to_ov == 5
	return not from_high or not to_high

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
	var near_range: float = maxf(_get_collision_radius(_army) * 2.0 + 0.8, 1.2)
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

# 船只视觉模型放大后使用 push_radius 做推挤；普通单位仍沿用 body_radius。
func _get_collision_radius(entity: GameEntity) -> float:
	if entity is Army and entity.push_radius > 0.0:
		return entity.push_radius
	return entity.body_radius

# 按体积近似推挤质量；配置里显式给了 mass 时优先使用。
func _get_push_mass(entity: GameEntity) -> float:
	if entity.mass > 0.0:
		return entity.mass
	var r: float = _get_collision_radius(entity)
	return maxf(1.0, r * r * 10.0)

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
		# 普通山壁不能靠推挤挤上山；缓坡/台地仍按坡度检查。
		if terrain == 1:
			var ov: int = bm.get_overlay_at_grid(g.x, g.y)
			if ov != 4 and ov != 5:
				return false
		# 推挤也不能把陆军挤下悬崖/陡坎；否则密集阵型会在台地边缘互相推落。
		if _is_cliff_between_positions(bm, _army.global_position, pos):
			return false
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
	var min_dist = _get_collision_radius(_army) + _get_collision_radius(entity)
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

# ==================== Path markers ====================

# 路径预览：用一条贴地流动的指引带代替原来那一串青色小球。
# 指引带内部逐顶点贴地，并自带「起点淡出 + 末端呼吸落点环」，所以不再需要绿球标终点。
# 每支被选中的军队各画自己的路径；路径点没变就沿用现有节点，不重复生成网格。
func _show_path():
	var bm = _get_bm()
	if bm == null:
		_hide_path()
		return
	# 单条长路径也不逐格取点，按固定上限抽样；尾点始终保留。
	# 排头用单位当前位置，这样线始终从脚下开始，走一段收一段（实时缩短）。
	var head: Vector3 = _army.global_position
	head.y = 0.0
	var tail: Array = _preview_tail_points()
	if tail.is_empty():
		_hide_path()
		return
	# 单位在原地小幅晃动、或者只走了一点点时不必重建网格：
	# 路径点没变、排头位移不到 PATH_HEAD_STEP 就沿用现有的指引带。
	var head_moved: bool = _path_built_head.distance_to(head) > PATH_HEAD_STEP
	if not head_moved and _path_preview_tail == tail and _path_guide != null and is_instance_valid(_path_guide):
		return
	var points: Array = [head]
	points.append_array(tail)
	_path_preview_tail = tail
	_path_built_head = head
	_path_preview_points = points
	# 节点还在、只是路径变了：直接重设中心线，比销毁重建便宜
	if _path_guide != null and is_instance_valid(_path_guide):
		_path_guide.set_points(points)
		return
	# 指引带要挂在世界空间（不旋转）的节点下，沿用原来的 battle_manager；
	# 高度采样交给 GroundStripMesh.height_fn_for()，拿不到地形时退回路径点的原始 y。
	_path_guide = GroundPathGuide.create(points, GroundStripMesh.height_fn_for(bm))
	bm.add_child(_path_guide)

# 路径预览的剩余路径点。
# A* 路径可能只剩 1 个航点，甚至在最后几米被清空；此时单位仍在走（最终接近/直追），
# 如果只按 astar_path.size() >= 2 判断，就会表现为“正在行走却没有路径”。
func _preview_tail_points() -> Array:
	var tail: Array = []
	if astar_path.is_empty():
		if not _preview_motion_active():
			return tail
		var dest: Vector3 = get_current_target()
		if dest != Vector3.ZERO:
			tail.append(dest)
		return tail
	if astar_path.size() <= MAX_PATH_PREVIEW_POINTS:
		# 必须复制：astar_path 会被 process_move 逐个 pop_front，共享引用会让缓存对比失真
		tail = astar_path.duplicate()
	else:
		var step: float = float(astar_path.size() - 1) / float(MAX_PATH_PREVIEW_POINTS - 1)
		for i in range(MAX_PATH_PREVIEW_POINTS):
			tail.append(astar_path[int(round(float(i) * step))])
	# A* 终点常停在资源/建筑边缘外，最后一段由 process_move 直线接近；
	# 把真正的目的地接到尾点，路径才不会提前断掉。
	var dest2: Vector3 = get_current_target()
	if dest2 != Vector3.ZERO and not tail.is_empty():
		var last: Vector3 = tail[tail.size() - 1]
		if Vector2(last.x - dest2.x, last.z - dest2.z).length() > 0.8:
			tail.append(dest2)
	return tail

# 没有 A* 路径时，只有确实还在移动才补画最终接近/追击线；站桩攻击或采集不画假路径。
func _preview_motion_active() -> bool:
	if _army == null:
		return false
	return _army.velocity.length_squared() > 0.04 or _army.is_attack_moving

func _hide_path():
	_path_preview_points.clear()
	_path_preview_tail.clear()
	_path_built_head = Vector3(INF, 0.0, INF)
	if _path_guide != null:
		if is_instance_valid(_path_guide):
			_path_guide.queue_free()
		_path_guide = null

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
# 当前生效的缓存（由 _ensure_static_caches 按当前单位队伍切换）。
static var _wall_set: Dictionary = {}    # Vector2i -> true
# 仅建筑按半径扩展出来的格子。目标格落在这里时需要改走到建筑外沿，
# 否则目标被自己/建筑外圈围住，A* 永远进不了中心格。
static var _footprint_set: Dictionary = {}  # Vector2i -> true
static var _wall_ver: int = -1
static var _wall_bm_id: int = -1
static var _wall_team: int = -1  # friendly-wall passability is team-dependent
static var _bridge_set: Dictionary = {}          # 桥所在格子
static var _ladder_set: Dictionary = {}          # 梯子使该敌方城墙格可通行
# 每个队伍一份静态障碍缓存。以前只有一份、按 _wall_team 判断，
# 双方单位交替寻路时会在同一帧反复全图重建墙缓存，A* 时间被大量浪费。
static var _team_static: Dictionary = {}  # team -> {wall, footprint, bridge, ladder}
static var _transport_water: Dictionary = {}     # 运载船周围3格水域(陆军可通行)
static var _transport_frame: int = -1
static var _transport_team: int = -1
# 每个队伍、每一帧的运载船水域缓存；避免双方交替时反复扫描运载船。
static var _team_transport: Dictionary = {}  # team -> {frame, water}

# 静态障碍缓存：建筑/资源/墙/桥/梯子只在布局变化时重建；
# 运载船周围可通行水域因为船会移动，按帧缓存。
# 直走判定和 A* 共用这份缓存，避免为了判断“能不能直走”再扫一遍全图实体。
func _ensure_static_caches(bm: RTSBattleManager) -> void:
	var frame = Engine.get_process_frames()
	var bm_id = bm.get_instance_id()
	# 建筑布局变化或切换战场时，整份缓存作废；否则只切换当前队伍的那一份。
	if _wall_bm_id != bm_id or _wall_ver != bm._wall_cache_version:
		_team_static.clear()
		_team_transport.clear()
		_wall_bm_id = bm_id
		_wall_ver = bm._wall_cache_version
	var team: int = _army.team
	var pack = _team_static.get(team)
	if pack == null:
		_wall_set = {}
		_footprint_set = {}
		_bridge_set = {}
		_ladder_set = {}
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
				for dx in range(-1, 2):
					for dy in range(-1, 2):
						if dx == 0 and dy == 0: continue
						var wall_b = bm._wall_entity_grid.get(Vector2i(eg.x + dx, eg.y + dy))
						if wall_b and wall_b.team != team:
							_ladder_set[Vector2i(eg.x + dx, eg.y + dy)] = true
				continue
			if e is Building and e.entity_id == 27:
				if e.team == team: continue
				_wall_set[eg] = true
			elif e is Building:
				_add_blocked_footprint(eg, e.body_radius)
			else:
				_wall_set[eg] = true
		pack = {
			"wall": _wall_set,
			"footprint": _footprint_set,
			"bridge": _bridge_set,
			"ladder": _ladder_set,
		}
		_team_static[team] = pack
	else:
		_wall_set = pack["wall"]
		_footprint_set = pack["footprint"]
		_bridge_set = pack["bridge"]
		_ladder_set = pack["ladder"]
	_wall_team = team
	var transport_pack = _team_transport.get(team)
	if transport_pack == null or int(transport_pack.get("frame", -1)) != frame:
		var water := {}
		for e in bm.entities.get_children():
			if e is Army and e.entity_id == 9 and e.health > 0 and e.team == team:
				var tg = bm.world_to_grid(e.global_position)
				for rdx in range(-3, 4):
					for rdy in range(-3, 4):
						var tx = tg.x + rdx; var ty = tg.y + rdy
						if tx >= 0 and tx < RTSConfig.MAP_SIZE and ty >= 0 and ty < RTSConfig.MAP_SIZE:
							if bm.get_terrain_at_grid(tx, ty) == 2:
								water[Vector2i(tx, ty)] = true
		transport_pack = {"frame": frame, "water": water}
		_team_transport[team] = transport_pack
	_transport_water = transport_pack["water"]
	_transport_frame = frame
	_transport_team = team

# 直线可达时直接返回目标点，不跑 A*。
# 后期大规模交战时绝大多数单位都在开阔地追击，真正需要绕墙/绕水的只是少数；
# 如果每个单位都跑 A*，固定预算很快被填满，后面的请求只能无限排队。
func _try_direct_path(bm: RTSBattleManager, target_pos: Vector3, stop_range: float) -> Array:
	_ensure_static_caches(bm)
	var start_pos := _army.global_position
	var start_tile: Vector2i = bm.world_to_grid(start_pos)
	var goal_tile: Vector2i = bm.world_to_grid(target_pos)
	var path_goal_pos := target_pos
	# 建筑中心格在 footprint 内：直接走到中心会卡进建筑。
	# 改成走向建筑外沿最近的可走格，最后一段交给 process_move 的最终接近/攻击距离判定。
	if _footprint_set.has(goal_tile):
		var approach_tile := _find_approach_tile(goal_tile, bm, _wall_set)
		if approach_tile == goal_tile:
			return []
		goal_tile = approach_tile
		var half_map: float = RTSConfig.MAP_SIZE / 2.0
		path_goal_pos = Vector3(goal_tile.x - half_map, 0.0, goal_tile.y - half_map)
	var dist := start_pos.distance_to(path_goal_pos)
	if dist < 0.05:
		return [path_goal_pos]
	if start_tile == goal_tile:
		return [path_goal_pos]
	# 0.4 米采样，足以命中一格宽的墙/建筑外沿；比 A* 展开几千节点便宜得多。
	var samples: int = maxi(2, int(ceil(dist / 0.4)))
	var prev_tile := start_tile
	for i in range(1, samples + 1):
		var t := float(i) / float(samples)
		var sample_pos := start_pos.lerp(path_goal_pos, t)
		var tile: Vector2i = bm.world_to_grid(sample_pos)
		if tile == prev_tile:
			continue
		if _is_cliff_between_tiles(bm, prev_tile, tile):
			return []
		# 终点格允许是墙/资源中心（近战会在攻击距离停下）；中间格必须可通行。
		if tile != goal_tile:
			if _wall_set.has(tile) and not _ladder_set.has(tile):
				return []
		if _get_terrain_cost(tile, bm, _wall_set) >= 999.0:
			return []
		prev_tile = tile
	return [path_goal_pos]

# 攻击移动群体路线缓存键：按队伍和 2 米网格分组，让同一波部队
# 即使队形落点相差一两米也能共用同一条主路线。
func _group_path_cache_key(target_pos: Vector3) -> Vector3i:
	# 水军和陆军可走的格子不同，必须分车道；否则一方会复用另一方穿水/上岸的路线。
	var lane: int = int(_army.team) * 2 + (1 if _army.water_capable else 0)
	return Vector3i(
		lane,
		int(round(target_pos.x / GROUP_PATH_CACHE_CELL)),
		int(round(target_pos.z / GROUP_PATH_CACHE_CELL))
	)

func _is_group_attack_move() -> bool:
	return _army != null and (_army.is_attack_moving or _army._order_is(_army.UnitState.ATTACK_MOVING))

# 尝试并入已经算好的攻击移动路线。只从最近航点做一次直线可达检查；
# 不可达就退回正常 A*，不会为了复用路线把单位硬塞进墙里。
func _try_merge_group_path(target_pos: Vector3, bm: RTSBattleManager) -> bool:
	if bm == null or not _is_group_attack_move():
		return false
	var route: Array = bm.get_group_attack_path(_group_path_cache_key(target_pos))
	if route.size() < 2:
		return false
	var origin := _army.global_position
	var best_index: int = -1
	var best_dist: float = GROUP_PATH_MERGE_RADIUS
	for i in range(route.size()):
		var wp: Vector3 = route[i]
		var d := Vector2(wp.x - origin.x, wp.z - origin.z).length()
		if d < best_dist:
			best_dist = d
			best_index = i
	if best_index < 0:
		return false
	# 到最近航点必须能直线走通；否则从当前位置硬切过去可能穿墙。
	var prefix: Array = _try_direct_path(bm, route[best_index], 0.0)
	if prefix.is_empty():
		return false
	var merged: Array = prefix.duplicate()
	for i in range(best_index, route.size()):
		var wp2: Vector3 = route[i]
		if merged.size() > 0 and (merged[merged.size() - 1] as Vector3).distance_to(wp2) < 0.2:
			continue
		merged.append(wp2)
	if merged.is_empty():
		return false
	astar_target = target_pos
	astar_path = merged
	path_partial = false
	_last_path_partial = false
	move_path_failed = false
	attack_path_failed = false
	_pending_path = false
	_pending_since_ms = 0
	if _is_selected:
		_show_path()
	return true

func _calculate_astar_path(target_pos: Vector3, stop_range: float = 0.0) -> Array:
	_last_path_partial = false
	var bm = _army._get_bm() as RTSBattleManager
	if not bm: return []
	bm.note_astar_path_call()
	var start = _army.global_position
	var start_tile = bm.world_to_grid(start)
	var end_tile = bm.world_to_grid(target_pos)

	if start_tile == end_tile and stop_range <= 0:
		# 同格移动不能返回空路径：_apply_path 会把空路径当成“不可达”写进永久黑名单，
		# 之后该格再也无法寻路。返回一个起点航点，让 process_move 走最终接近并正常到达。
		var half_map: float = RTSConfig.MAP_SIZE / 2.0
		return [Vector3(start_tile.x - half_map, 0.0, start_tile.y - half_map)]

	_ensure_static_caches(bm)
	var wall_cache = _wall_set

	# 目标点落在放大建筑内部时，A* 不能直接走进中心格：建筑外围一圈都是障碍，
	# 中心格会被彻底围死。把寻路终点改成最近的可走外沿，单位仍会朝向真实目标
	# 做最终接近/攻击，不会因此丢失目标。
	var goal_tile: Vector2i = end_tile
	var goal_adjusted := false
	if _footprint_set.has(goal_tile):
		var approach_tile := _find_approach_tile(goal_tile, bm, wall_cache)
		if approach_tile != goal_tile:
			goal_tile = approach_tile
			goal_adjusted = true

	# 单位已经站在建筑外沿时，目标格可能就落在脚下。返回一个起点航点，
	# 避免空路径被当成“不可达”写进黑名单，后续攻击/最终接近仍可正常工作。
	if goal_adjusted and goal_tile == start_tile:
		var half_map_start: float = RTSConfig.MAP_SIZE / 2.0
		return [Vector3(start_tile.x - half_map_start, 0.0, start_tile.y - half_map_start)]

	# A* data structures — Vector2i keys (fast int hash, no string allocs)
	var open_list = MinHeap.new()
	var closed_set := {}  # Vector2i -> true
	var g_score := {}     # Vector2i -> float
	var came_from := {}   # Vector2i -> Vector2i

	# 排队很长时用更激进的加权 A*：稍微牺牲路径最优性，换取更少的节点展开，
	# 让单个长路径更快算完，队尾才有机会被消化。无压力时保持原权重。
	var heuristic_weight: float = 1.2
	if bm.get_astar_pending_estimate() >= A_STAR_PRESSURE_THRESHOLD:
		heuristic_weight = 1.6
	g_score[start_tile] = 0.0
	open_list.push(start_tile, _heuristic(start_tile, goal_tile) * heuristic_weight)

	var max_nodes: int = 1000
	# 固定 1000 节点在 100×100 地图上不够跨河：桥头堡等地图的浅滩偏离起点/终点连线时，
	# A* 会沿着河岸展开 1500~1800 个节点才找到渡口，旧上限会提前返回空路径。
	# 表现就是 AI 部队堵在集结点、永远不发起进攻。按起终点距离放宽预算，同时保留硬上限。
	# 150×150 的 2v2/3v3 河图上，双河/海湾类地图的绕行更远（实测最坏约 12k 节点），
	# 因此预算与上限相应上调；普通短距离寻路命中节点数不变，不影响常规性能。
	var tile_span: int = absi(start_tile.x - goal_tile.x) + absi(start_tile.y - goal_tile.y)
	max_nodes = clampi(2000 + tile_span * 80, 2000, 12000)
	var nodes_explored := 0
	var from_height := _get_tile_height(start_tile, bm)
	var best_partial_tile: Vector2i = start_tile
	var best_partial_h: float = _heuristic(start_tile, goal_tile)

	while not open_list.is_empty() and nodes_explored < max_nodes:
		var current_entry = open_list.pop()
		if current_entry.is_empty(): break
		var cur_tile: Vector2i = current_entry.tile
		nodes_explored += 1
		var cur_h: float = _heuristic(cur_tile, goal_tile)
		if cur_h < best_partial_h:
			best_partial_h = cur_h
			best_partial_tile = cur_tile

		# Goal checks
		if stop_range > 0 and not goal_adjusted:
			# 用曼哈顿距离判断“已进入攻击距离”：切比雪夫距离会把 (5,5) 这种对角格
			# 当成距离5，实际中心距离 7.07，远程单位会停在射程外，表现为锁敌后不攻击。
			# 曼哈顿距离 <= stop_range 时，欧氏距离必然 <= stop_range，终点一定在射程内。
			if _heuristic(cur_tile, goal_tile) <= stop_range:
				var path2 = _reconstruct_path(came_from, cur_tile)
				if path2.size() > 1: path2.pop_front()
				return path2
		if cur_tile == goal_tile:
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
				# 台地边缘必须接缓坡/台地；平地不能直接斜着踏上台地。
				if _is_plateau_transition_blocked(bm, cur_tile, neighbor): continue

				# 统一坡度：悬崖/陡坎上下都不允许通过；普通坡提高时间成本。
				# 普通山壁已在 _get_terrain_cost 里按 999 阻断，只有缓坡/台地能进入这里。
				var neighbor_h = _get_tile_height(neighbor, bm)
				var step_len := sqrt(float(dx * dx + dy * dy))
				var dh: float = neighbor_h - from_height
				if RTSConfig.is_cliff_slope(dh, step_len): continue

				# Wall collision (skip for goal tile — allow reaching target)
				if neighbor != goal_tile and wall_cache.has(neighbor) and not _ladder_set.has(neighbor): continue

				# 成本 = 水平距离 × 时间倍率；与 MovementController 实际移速严格互为倒数。
				var step_cost = terrain_cost * step_len * RTSConfig.slope_time_multiplier(dh, step_len)
				var tentative_g = cur_g + step_cost

				if tentative_g < g_score.get(neighbor, 9999.0):
					came_from[neighbor] = cur_tile
					g_score[neighbor] = tentative_g
					open_list.push(neighbor, tentative_g + _heuristic(neighbor, goal_tile) * heuristic_weight)

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
	var ov := bm.get_overlay_at_grid(tile.x, tile.y)
	var cost: float
	if _army.water_capable:
		# 水军无法通过桥
		cost = 999.0 if _bridge_set.has(tile) else (0.8 if terrain == 2 else 999.0)
	else:
		# 山地：普通山壁不可通行；只有缓坡(4)与山顶台地(5)能走。
		# 森林/沼泽/浅滩的权重取实际基础速度的倒数，保证 A* 时间成本、实际移速一致。
		if ov == 4:
			cost = SLOPE_BASE_COST
		elif ov == 5:
			cost = PLATEAU_BASE_COST
		elif ov == 3:
			cost = 1.0 / maxf(float(bm.map_modifiers.get("ford_speed", 0.55)), 0.1)
		elif ov == 2:
			cost = 1.0 / maxf(float(bm.map_modifiers.get("marsh_speed", 0.6)), 0.1)
		elif ov == 1:
			cost = 1.0 / 0.9
		else:
			match terrain:
				0: cost = 1.0
				1: cost = 999.0
				2: cost = 1.5 if _bridge_set.has(tile) or _transport_water.has(tile) else 999.0
				_: cost = 999.0
	return cost

func _get_tile_height(tile: Vector2i, bm: RTSBattleManager) -> float:
	if bm and bm.has_method("get_height_at_grid"):
		return bm.get_height_at_grid(tile.x, tile.y)
	return 0.0

# 把建筑按实际碰撞半径占用的格子加入静态障碍集合。
# 网格一格 = 1 米，建筑放大后 body_radius 也同步变大，因此不能再只标中心格。
func _add_blocked_footprint(center: Vector2i, radius: float) -> void:
	var r := int(ceil(maxf(radius, 0.0)))
	if r <= 0:
		_wall_set[center] = true
		_footprint_set[center] = true
		return
	var rr := radius * radius
	var map_size := RTSConfig.MAP_SIZE
	for dx in range(-r, r + 1):
		for dy in range(-r, r + 1):
			if float(dx * dx + dy * dy) > rr:
				continue
			var tx := center.x + dx
			var ty := center.y + dy
			if tx < 0 or ty < 0 or tx >= map_size or ty >= map_size:
				continue
			var tile := Vector2i(tx, ty)
			_wall_set[tile] = true
			_footprint_set[tile] = true

# 目标格在建筑 footprint 内时，从中心向外找最近的可走格（按切比雪夫环扫描）。
# 只要求地形可行、不是静态障碍；具体能否从起点到达仍由 A* 判断。
func _find_approach_tile(center: Vector2i, bm: RTSBattleManager, wall_cache: Dictionary) -> Vector2i:
	var max_radius := 16
	for r in range(1, max_radius + 1):
		var best_tile: Vector2i = center
		var best_dist: float = 1e20
		var found := false
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var tx := center.x + dx
				var ty := center.y + dy
				if tx < 0 or ty < 0 or tx >= RTSConfig.MAP_SIZE or ty >= RTSConfig.MAP_SIZE:
					continue
				var tile := Vector2i(tx, ty)
				if wall_cache.has(tile):
					continue
				if _get_terrain_cost(tile, bm, wall_cache) >= 999.0:
					continue
				var d := float(dx * dx + dy * dy)
				if d < best_dist:
					best_dist = d
					best_tile = tile
					found = true
		if found:
			return best_tile
	return center

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

# ── 采集最终接近 ──
# 资源点占用的 A* 格子是阻挡格，寻路终点往往停在离资源 1~3 米的地方。
# 普通移动在「目标 1.7 米外且无路径」时会原地等待重算，农民就会站在远处假采集。
# 这里对采集目标单独放行最后几米的直线接近：终点取资源边缘外 GATHER_STANDOFF_GAP 米的站位点，
# 让「采集停靠间距」真的等于 Army.GATHER_STANDOFF_GAP（0.5 米）。
const GATHER_FINAL_APPROACH_RANGE: float = 4.0
const GATHER_FINAL_APPROACH_STEP: float = 0.5


# 返回采集站位点；不是采集目标 / 太远 / 中间隔山隔水时返回 Vector3.ZERO（表示不放行）
func _gather_standoff_point(target_pos: Vector3) -> Vector3:
	if _army == null or not is_instance_valid(_army.current_target):
		return Vector3.ZERO
	if not (_army.current_target is WorldResource):
		return Vector3.ZERO
	if String(_army.current_order) != "gather":
		return Vector3.ZERO
	var target_radius: float = 0.0
	if _army.current_target is GameEntity:
		target_radius = float(_army.current_target.body_radius)
	var flat: float = Vector2(target_pos.x - _army.global_position.x, target_pos.z - _army.global_position.z).length()
	var stand_dist: float = float(_army.body_radius) + target_radius + Army.GATHER_STANDOFF_GAP
	# 已经站在站位点内侧（贴上了）就不用再插值，交给 Army 的采集判定
	if flat <= stand_dist + 0.01:
		return Vector3.ZERO
	# 只放行最后几米：更远的距离说明寻路真的没走到，继续等 A* 重算
	if flat - stand_dist > GATHER_FINAL_APPROACH_RANGE:
		return Vector3.ZERO
	var bm = _get_bm()
	if bm != null:
		# 中间不能隔山/隔水：逐段采样地形，陆地单位只走平原
		var steps: int = int(flat / GATHER_FINAL_APPROACH_STEP) + 1
		for i in range(1, steps + 1):
			var t: float = float(i) / float(steps)
			var p: Vector3 = _army.global_position.lerp(target_pos, t)
			var terr: int = int(bm.get_terrain_at(p))
			if terr == 1:
				return Vector3.ZERO
			if terr == 2 and not _army.water_capable:
				return Vector3.ZERO
	var dir := Vector3(_army.global_position.x - target_pos.x, 0.0, _army.global_position.z - target_pos.z)
	if dir.length() < 0.001:
		return Vector3.ZERO
	# 站位点比阈值再往里 0.05 米，避免浮点误差导致“差一点点不算到”而反复微调
	var aim: float = maxf(stand_dist - 0.05, 0.0)
	return Vector3(target_pos.x, _army.global_position.y, target_pos.z) + dir.normalized() * aim
