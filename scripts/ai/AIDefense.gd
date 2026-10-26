# scripts/ai/AIDefense.gd
# AI 防守与资源控制模块。
#
# 目标：
#   1. 用可见敌军 + 主城掉血 + 资源区受袭共同评估威胁，而不是只看军力总和；
#   2. 防线允许建在主城附近，按“内圈箭塔 → 外墙 → 炮塔”分批建造，被拆后补建；
#   3. 常驻少量守军，威胁升高时逐步回防，危急时召回全部陆战部队；
#   4. 资源区受袭时先让农民短距离躲避，再派 1-3 个机动部队去资源区；远矿点补瞭望塔；
#   5. 防守升级按“威胁方向上的塔优先”逐个升级，不再随机升级所有建筑。
#
# 本模块保持无 class_name，由 AI.gd 通过 preload 加载，避免全局类缓存不同步。
extends RefCounted

const THREAT_RADIUS: float = 15.0
const THREAT_INTERVAL: float = 2.5
const DEFENSE_FRONT: float = 7.2
const DEFENSE_WALL_RADIUS: float = 12.2
# 防线地形搜索：在城堡朝敌方向的前方扇形里找隘口/浅滩，把墙线横在通道上
const DEFENSE_ANCHOR_MIN_DIST: int = 7
const DEFENSE_ANCHOR_MAX_DIST: int = 14
const DEFENSE_ANCHOR_LATERAL: int = 7
const DEFENSE_LANE_MAX_WIDTH: int = 9
const DEFENSE_GAP_INTERVAL: float = 25.0
const DEFENSE_BUILD_MAX_PER_TICK: int = 2
const DEFENSE_UPGRADE_INTERVAL: float = 9.0
const GUARD_INTERVAL: float = 60.0
const GUARD_REFILL_INTERVAL: float = 2.0
const RESOURCE_INTERVAL: float = 1.5
const RESOURCE_ZONE_INTERVAL: float = 12.0
const OUTPOST_INTERVAL: float = 24.0
const RESOURCE_GUARD_HOLD: float = 9.0
const DEFENSE_RECALL_SAFE_RADIUS: float = 25.0
const WORKER_FLEE_TIME: float = 9.0
const WORKER_FLEE_RADIUS: float = 8.0
const WORKER_FLEE_DISTANCE: float = 6.0
const FORCE_GUARD_TIME: float = 16.0
# 常驻主城守军数量。低于防守状态时保持 5 人，避免主力出门后家里完全空虚。
const HOME_GUARD_COUNT: int = 5
# 2 秒一次的快速补员只在家门口找兵；远处的空闲野战军由 60 秒一次的完整审计处理，
# 否则刚集结好的部队会被每 2 秒拉走一个，永远出不了门。
const HOME_GUARD_REFILL_RADIUS: float = 35.0
# 友方建筑被攻击时，调动建筑周围这个半径内、没有任务的陆军反击。
# 主城（20）单独放宽到 CASTLE_DEFENSE_RADIUS，用于“回防检查”。
const BUILDING_DEFENSE_RADIUS: float = 15.0
const CASTLE_DEFENSE_RADIUS: float = 35.0
const BUILDING_DEFENSE_MAX: int = 5
const CASTLE_DEFENSE_MAX: int = 8
const BUILDING_DEFENSE_HOLD: float = 15.0
# 建筑掉血检测原来每帧遍历全部实体；后期几百单位 × 多个 AI 会形成固定开销，
# 0.5 秒一次足够发现“正在被打”，响应延迟仍在可接受范围。
const BUILDING_ALERT_INTERVAL: float = 0.5
const CASTLE_ID: int = 20
const MILITARY_BUILDING_IDS: Array = [21, 22, 23, 24, 25, 26, 27, 41, 64]

const SIEGE_IDS: Array = [16, 17, 18, 58, 59]
const ECO_IDS: Array = [10, 14, 43, 44, 45, 51]
const TOWER_IDS: Array = [25, 26]
const OUTPOST_ID: int = 41

var ai = null

# ── 威胁状态 ──
var threat_level: int = 0             # 0 平静 / 1 警戒 / 2 防守 / 3 危急
var threat_score: float = 0.0
var threat_enemy_count: int = 0
var threat_dir: Vector3 = Vector3.FORWARD
var threat_center: Vector3 = Vector3.ZERO
var _threat_timer: float = 0.0
var _threat_smoothed: float = 0.0
var _castle_damage_until: float = -999.0
var _last_castle_id: int = -1
var _last_castle_health: float = -1.0

# ── 防线状态 ──
var defense_initialized: bool = false
var _defense_dir: Vector3 = Vector3.FORWARD
var _defense_queue: Array = []        # [{"id","pos","priority","tries"}]
var _defense_slots: Array = []        # [{"id","pos"}]
var wall_positions: Array = []
var tower_positions: Array = []
var _defense_anchor: Dictionary = {}   # 选中的隘口/浅滩防线锚点
var _defense_terrain_text: String = "" # 调试面板显示的地形类型
var _defense_check_timer: float = 3.0
var _next_layout_try: float = 0.0
var _defense_retry_at: float = 0.0
var _next_reactive_tower: float = 0.0
var _upgrade_timer: float = 4.0

# ── 守军状态 ──
var _home_guard_ids: Dictionary = {}
var _guard_timer: float = 0.0
var _guard_refill_timer: float = 0.0
var _building_alert_timer: float = 0.0
var _force_guard_until: float = -999.0

# ── 建筑被攻击追踪 ──
var _building_health: Dictionary = {}

# ── 资源区状态 ──
var resource_zones: Array = []        # [{"center","type","workers","nodes","enemy_count"}]
var _resource_timer: float = 0.0
var _zone_timer: float = 0.0
var _next_outpost: float = 0.0
var _resource_guard_ids: Dictionary = {}
var _resource_guard_hold_until: float = -999.0

func _init(owner_ai) -> void:
	ai = owner_ai

# ═══════════════════════════════════════════════════════════════
# 主入口
# ═══════════════════════════════════════════════════════════════

func tick(delta: float) -> void:
	if ai == null:
		return
	var b = ai.battle
	if b == null or not is_instance_valid(b):
		return
	if b.game_over:
		return
	var castle = ai.get_peer_castle(ai.my_peer_id)
	if castle == null or not is_instance_valid(castle):
		# 没有主城时不能保留上一场战斗的高威胁分数，否则调试面板会显示“敌军 0 却高度警戒”
		threat_level = 0
		threat_score = 0.0
		_threat_smoothed = 0.0
		threat_enemy_count = 0
		return
	_threat_timer -= delta
	if _threat_timer <= 0.0:
		_threat_timer = THREAT_INTERVAL
		_evaluate_threat(castle)
	# 先检测建筑掉血并给附近空闲部队下反击命令，再调度守军；
	# 被本地防守标记的部队会在守军调度里跳过，避免刚出击就被拉回主城。
	# 检测本身要遍历全部实体，不能每帧跑；0.5 秒一次已经足够及时。
	_building_alert_timer -= delta
	if _building_alert_timer <= 0.0:
		_building_alert_timer = BUILDING_ALERT_INTERVAL
		_detect_building_attacks()
	_manage_defense(castle, delta)
	_manage_home_guard(castle, delta)
	_quick_fill_home_guard(castle, delta)
	_manage_resource_security(castle, delta)
	_manage_defense_upgrades(castle, delta)

func start_defense() -> void:
	var castle = ai.get_peer_castle(ai.my_peer_id)
	if castle == null:
		return
	_force_guard_until = float(ai.battle.game_time) + FORCE_GUARD_TIME
	_guard_timer = 0.0
	_ensure_layout(castle)
	_assign_home_guard(castle, true)

func get_status_text() -> String:
	var names: Array = ["平静", "警戒", "防守", "危急"]
	var idx: int = clampi(threat_level, 0, names.size() - 1)
	var terrain_txt: String = ""
	if not _defense_anchor.is_empty():
		terrain_txt = " 地形:%s" % str(_defense_terrain_text)
	return "威胁:%s(敌%d) 守军:%d 资源卫:%d%s" % [
		names[idx], threat_enemy_count, _home_guard_ids.size(), _resource_guard_ids.size(), terrain_txt,
	]

# ═══════════════════════════════════════════════════════════════
# 威胁评估
# ═══════════════════════════════════════════════════════════════

func _evaluate_threat(castle) -> void:
	var now: float = float(ai.battle.game_time)
	var raw: float = 0.0
	var count: int = 0
	var dir_sum: Vector3 = Vector3.ZERO
	var center_sum: Vector3 = Vector3.ZERO
	var weight_sum: float = 0.0

	# 威胁只来自 AI 当前视野内、确实能看到的敌军；不做全图侦测
	for e in ai._visible_enemies:
		if not is_instance_valid(e) or not (e is Army) or e.health <= 0:
			continue
		# _visible_enemies 已经过视野筛选，不再重复扫描己方全部实体
		if not _is_combat_enemy(e):
			continue
		var d: float = e.global_position.distance_to(castle.global_position)
		if d > THREAT_RADIUS:
			continue
		count += 1
		var prox: float = clampf(1.0 - d / THREAT_RADIUS, 0.0, 1.0)
		var s: float = 1.0 + prox * 3.5
		if float(e.attack) >= 30.0:
			s += 0.6
		if int(e.entity_id) in SIEGE_IDS:
			s += 0.8
		if d < 18.0:
			s += 1.0
		raw += s
		var w: float = 0.25 + prox
		dir_sum += (e.global_position - castle.global_position).normalized() * w
		center_sum += e.global_position * w
		weight_sum += w

	# 主城掉血只作为“已有可见近敌”的严重度加成，不再单独触发威胁；
	# 威胁只来自主城 15 单位内、确实可见的敌方军队。
	if _last_castle_id != castle.get_instance_id():
		_last_castle_id = castle.get_instance_id()
		_last_castle_health = castle.health
	if castle.health < _last_castle_health - 0.5:
		_castle_damage_until = now + 8.0
	_last_castle_health = castle.health
	if count > 0 and now < _castle_damage_until:
		raw += 4.0

	# 没有任何可见近敌时直接清零，避免之前战斗的高分继续残留。
	if count == 0:
		_threat_smoothed = 0.0

	threat_enemy_count = count
	if raw > _threat_smoothed:
		_threat_smoothed = lerpf(_threat_smoothed, raw, 0.7)
	else:
		_threat_smoothed = lerpf(_threat_smoothed, raw, 0.45)
	threat_score = _threat_smoothed

	# 只有成建制敌军逼近/攻城才进入防守，单个远处侦察兵不应让 AI 全员回防
	if threat_score >= 14.0:
		threat_level = 3
	elif threat_score >= 7.0:
		threat_level = 2
	elif threat_score >= 2.5:
		threat_level = 1
	else:
		threat_level = 0

	if weight_sum > 0.01 and dir_sum.length_squared() > 0.01:
		threat_dir = (dir_sum / weight_sum).normalized()
		threat_center = center_sum / weight_sum
	else:
		threat_dir = _enemy_castle_dir(castle)
		threat_center = castle.global_position + threat_dir * 18.0
	if threat_dir.length_squared() < 0.001:
		threat_dir = Vector3.FORWARD

func _enemy_castle_dir(castle) -> Vector3:
	var enemy_team: int = ai._primary_enemy_team()
	var ec = ai.get_team_castle(enemy_team)
	if ec == null:
		for e in ai.battle.entities.get_children():
			if e is Building and int(e.entity_id) == 20 and e.health > 0 and ai._entity_is_enemy(e):
				ec = e
				break
	if ec:
		var d: Vector3 = ec.global_position - castle.global_position
		d.y = 0.0
		if d.length_squared() > 0.01:
			return d.normalized()
	return Vector3.FORWARD

func _is_combat_enemy(e) -> bool:
	if e == null or not is_instance_valid(e) or not (e is Army) or e.health <= 0:
		return false
	# 中立动物/中立单位不是敌军，不能触发防守
	if int(e.team) == RTSConfig.Team.NEUTRAL:
		return false
	if not ai._entity_is_enemy(e):
		return false
	return int(e.target_type) > 0 or float(e.attack) > 0.0

# ═══════════════════════════════════════════════════════════════
# 防线规划与建造
# ═══════════════════════════════════════════════════════════════

func _manage_defense(castle, delta: float) -> void:
	if int(castle.upgrade_level) < 2:
		# 箭塔/炮塔需要主城 2 级；威胁已经到家门口时优先补这一级，否则防线永远无法开工
		if threat_level >= 1 and castle.can_upgrade():
			var up_cost: Dictionary = castle.get_upgrade_cost()
			if not up_cost.is_empty() and _can_spend(up_cost, _defense_reserve()):
				ai.upgrade_building(20)
		return
	_defense_check_timer -= delta
	if not defense_initialized:
		if threat_level >= 1 or float(ai.battle.game_time) >= 150.0:
			_ensure_layout(castle)
	else:
		if _defense_check_timer <= 0.0:
			_defense_check_timer = DEFENSE_GAP_INTERVAL
			_queue_defense_gaps()
		_build_defense_step()
		_maybe_reactive_tower(castle)

func _ensure_layout(castle) -> bool:
	if defense_initialized:
		return true
	if float(ai.battle.game_time) < _next_layout_try:
		return false
	if _plan_defense_line(castle):
		defense_initialized = true
		_next_layout_try = float(ai.battle.game_time) + 5.0
		return true
	_next_layout_try = float(ai.battle.game_time) + 8.0
	return false

# ── 地形防线：在朝敌方向前方寻找隘口/浅滩 ──
func _cell_blocks_land(gx: int, gz: int) -> bool:
	var terrain: int = ai.battle.get_terrain_at_grid(gx, gz)
	if terrain < 0:
		return true
	if terrain == 2 and ai.battle.get_overlay_at_grid(gx, gz) != 3:
		return true
	# 普通山地是天然墙；只有缓坡/台地（is_cliff_tile 返回 false）才算可通行地形。
	return ai.battle.is_cliff_tile(gx, gz)

func _is_ford_cell(gx: int, gz: int) -> bool:
	return ai.battle.get_terrain_at_grid(gx, gz) == 2 and ai.battle.get_overlay_at_grid(gx, gz) == 3

# 沿垂直方向测量可通行通道宽度；两侧山/水会很快截断
func _lane_width(pos: Vector3, perp: Vector3, max_steps: int = DEFENSE_LANE_MAX_WIDTH) -> int:
	var left: int = 0
	var right: int = 0
	while left < max_steps:
		var lc: Vector2i = ai.battle.world_to_grid(pos - perp * float(left + 1))
		if _cell_blocks_land(lc.x, lc.y):
			break
		left += 1
	while right < max_steps:
		var rc: Vector2i = ai.battle.world_to_grid(pos + perp * float(right + 1))
		if _cell_blocks_land(rc.x, rc.y):
			break
		right += 1
	return left + right + 1

func _count_nearby_barriers(pos: Vector3, radius: int = 3) -> int:
	var total: int = 0
	var center: Vector2i = ai.battle.world_to_grid(pos)
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			if dx == 0 and dz == 0:
				continue
			if _cell_blocks_land(center.x + dx, center.y + dz):
				total += 1
	return total

func _find_ford_near(pos: Vector3, radius: float = 3.5) -> Vector3:
	var center: Vector2i = ai.battle.world_to_grid(pos)
	var r: int = int(ceil(radius))
	var best: Vector3 = Vector3.ZERO
	var best_d: float = INF
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			if not _is_ford_cell(center.x + dx, center.y + dz):
				continue
			var wp: Vector3 = ai.battle.grid_to_world(center.x + dx, center.y + dz)
			var d: float = wp.distance_squared_to(pos)
			if d < best_d:
				best_d = d
				best = wp
	return best

func _find_defense_anchor(castle, enemy_dir: Vector3) -> Dictionary:
	var forward: Vector3 = enemy_dir
	forward.y = 0.0
	if forward.length_squared() < 0.01:
		return {}
	forward = forward.normalized()
	var perp: Vector3 = forward.cross(Vector3.UP).normalized()
	if perp.length_squared() < 0.01:
		perp = Vector3.RIGHT

	var best: Dictionary = {}
	var best_score: float = -INF
	for dist_i in range(DEFENSE_ANCHOR_MIN_DIST, DEFENSE_ANCHOR_MAX_DIST + 1):
		var dist: float = float(dist_i)
		for lateral_i in range(-DEFENSE_ANCHOR_LATERAL, DEFENSE_ANCHOR_LATERAL + 1):
			var lateral: float = float(lateral_i)
			var p: Vector3 = castle.global_position + forward * dist + perp * lateral
			if not _is_valid_defense_ground(p, 1.0, true):
				continue
			var to_p: Vector3 = p - castle.global_position
			to_p.y = 0.0
			if to_p.length_squared() < 0.01:
				continue
			var align: float = to_p.normalized().dot(forward)
			if align < 0.35:
				continue
			var width: int = _lane_width(p, perp)
			if width < 2 or width > DEFENSE_LANE_MAX_WIDTH:
				continue
			var barriers: int = _count_nearby_barriers(p, 3)
			var ford: Vector3 = _find_ford_near(p, 3.5)
			var is_ford: bool = ford != Vector3.ZERO
			if barriers < 2 and not is_ford:
				continue
			# 浅滩防线必须落在己方一侧，不能跑到河对岸去
			if is_ford:
				var ford_depth: float = (ford - castle.global_position).dot(forward)
				var p_depth: float = to_p.dot(forward)
				if p_depth > ford_depth + 1.0:
					continue
			# 通道太宽不算隘口；5 格左右最理想，过窄可能是城墙/资源夹出的假通道
			var width_score: float = 5.0 - absf(float(width) - 5.0) * 1.25
			var center_bonus: float = 1.0 - absf(lateral) / float(DEFENSE_ANCHOR_LATERAL + 1)
			var score: float = width_score * 2.0 + float(barriers) * 0.45 + center_bonus * 3.0 + align * 5.0
			score -= absf(dist - 10.0) * 0.22
			if is_ford:
				score += 14.0
			if score > best_score:
				best_score = score
				var pdir: Vector3 = to_p.normalized()
				best = {
					"pos": p,
					"dir": pdir,
					"perp": pdir.cross(Vector3.UP).normalized(),
					"dist": dist,
					"width": float(width),
					"kind": "ford" if is_ford else "choke",
				}
	return best

func _find_anchor_spot(center: Vector3, b_id: int, search: float) -> Vector3:
	var cfg: Dictionary = EntityDatabase.get_config(b_id)
	if cfg.is_empty():
		return Vector3.ZERO
	var radius: float = float(cfg.get("body_radius", 1.0))
	for r in [0.0, search * 0.5, search, search * 1.5]:
		for i in range(8):
			var a: float = TAU * float(i) / 8.0
			var p: Vector3 = center + Vector3(cos(a) * float(r), 0.0, sin(a) * float(r))
			if not _is_valid_defense_ground(p, radius, true):
				continue
			if not _defense_slot_clear(p, radius, b_id):
				continue
			return p
	return Vector3.ZERO

func _find_defense_line_spot(base: Vector3, perp: Vector3, lateral: float, b_id: int, max_off: float) -> Vector3:
	var cfg: Dictionary = EntityDatabase.get_config(b_id)
	if cfg.is_empty():
		return Vector3.ZERO
	var radius: float = float(cfg.get("body_radius", 1.0))
	for dl in [0.0, 0.6, -0.6, 1.2, -1.2]:
		for dd in [0.0, 0.8, -0.8, max_off, -max_off]:
			var p: Vector3 = base + perp * (lateral + float(dl)) + _defense_dir * float(dd)
			if not _is_valid_defense_ground(p, radius, true):
				continue
			if not _defense_slot_clear(p, radius, b_id):
				continue
			return p
	return Vector3.ZERO

# 在隘口/浅滩两侧布置箭塔，并把墙线横向排开；返回实际可用的墙段数
func _plan_anchor_defense(castle, anchor: Dictionary) -> int:
	var dir: Vector3 = anchor["dir"]
	var perp: Vector3 = anchor["perp"]
	if perp.length_squared() < 0.01:
		perp = dir.cross(Vector3.UP).normalized()
	var anchor_pos: Vector3 = anchor["pos"]
	var half_width: float = maxf(2.2, float(anchor["width"]) * 0.5)

	# 锚点较远时先在城堡前方补一座视野塔，保证后续墙/塔能落在己方视野内
	if float(anchor["dist"]) > 10.0:
		var vision_pos: Vector3 = castle.global_position + dir * 8.0
		var vision_spot: Vector3 = _find_anchor_spot(vision_pos, 25, 1.5)
		if vision_spot != Vector3.ZERO:
			_add_defense_slot(25, vision_spot, 9.0, "tower")

	var tower_base: Vector3 = anchor_pos - dir * 1.8
	for side in [-1.0, 1.0]:
		if _count_planned(25) >= 7:
			break
		var tower_pos: Vector3 = tower_base + perp * side * half_width
		var tower_spot: Vector3 = _find_anchor_spot(tower_pos, 25, 2.2)
		if tower_spot != Vector3.ZERO:
			_add_defense_slot(25, tower_spot, 12.0 + absf(float(side)) * 0.5, "tower")

	if _count_planned(26) < 3:
		var cannon_pos: Vector3 = tower_base - dir * 1.2
		var cannon_spot: Vector3 = _find_anchor_spot(cannon_pos, 26, 2.0)
		if cannon_spot != Vector3.ZERO:
			_add_defense_slot(26, cannon_spot, 15.0, "tower")

	var wall_base: Vector3 = anchor_pos - dir * 0.8
	# 城墙半径 1.0（直径 2.0）：中心距必须 < 2.0 才能首尾重叠，
	# 旧值 2.0 只是刚好相切，任何一段被微调/漏建就会露出能钻人的缝。
	var spacing: float = 1.5
	var wall_count: int = clampi(int(ceil(float(anchor["width"]) / spacing)) + 2, 6, 16)
	var walls: int = 0
	for i in range(wall_count):
		var lateral: float = (float(i) - float(wall_count - 1) * 0.5) * spacing
		var wall_spot: Vector3 = _find_defense_line_spot(wall_base, perp, lateral, 27, 1.6)
		if wall_spot != Vector3.ZERO:
			_add_defense_slot(27, wall_spot, 20.0 + absf(lateral) * 0.35, "wall")
			walls += 1
	return walls

func _plan_defense_line(castle) -> bool:
	var dir: Vector3 = threat_dir
	dir.y = 0.0
	if dir.length_squared() < 0.01:
		dir = _enemy_castle_dir(castle)
	dir = dir.normalized()
	if dir.length_squared() < 0.01:
		dir = Vector3.FORWARD

	# 先找前方隘口/浅滩；找到后把整条防线转向该地形通道，墙线横在通道口
	_defense_anchor = _find_defense_anchor(castle, dir)
	if not _defense_anchor.is_empty():
		dir = _defense_anchor["dir"]
		_defense_terrain_text = "浅滩" if str(_defense_anchor["kind"]) == "ford" else "隘口"
	else:
		_defense_terrain_text = ""
	_defense_dir = dir

	_defense_queue.clear()
	_defense_slots.clear()
	wall_positions.clear()
	tower_positions.clear()

	# 内圈箭塔：固定角度优先；树/矿/水面占位时在附近找可用点
	var arrow_specs: Array = [
		{"angle": -0.58, "dist": 7.2},
		{"angle": 0.58, "dist": 7.2},
		{"angle": -1.02, "dist": 8.3},
		{"angle": 1.02, "dist": 8.3},
	]
	for spec in arrow_specs:
		var a: float = float(spec["angle"])
		var d: float = float(spec["dist"])
		var p: Vector3 = _find_defense_spot(castle, dir, a, d, 25, 9.8)
		if p != Vector3.ZERO:
			_add_defense_slot(25, p, 10.0 + absf(a) * 2.0, "tower")
	# 固定角度只落到 1 座以内时，补搜主城前方可用塔位
	if _count_planned(25) < 4:
		for a in [-1.3, -0.9, -0.3, 0.3, 0.9, 1.3, -1.6, 1.6, 0.0]:
			if _count_planned(25) >= 4:
				break
			var p2: Vector3 = _find_defense_spot(castle, dir, a, 8.4, 25, 9.8)
			if p2 != Vector3.ZERO:
				_add_defense_slot(25, p2, 11.0 + absf(a) * 2.0, "tower")

	# 有隘口/浅滩时，墙线横在通道上；否则回退到主城前方的外墙弧线
	var anchor_wall_count: int = 0
	if not _defense_anchor.is_empty():
		anchor_wall_count = _plan_anchor_defense(castle, _defense_anchor)
	if anchor_wall_count == 0:
		# 外墙弧线：先按空位最多的半径选弧线，再逐段微调避开树/矿
		var wall_radius: float = _pick_wall_radius(castle, dir)
		# 弧线上每段墙的中心距也要压在 1.5 以内（旧版固定 9 段 ≈ 2.38 米，
		# 段与段之间留着 0.38 米的缝，小兵能从缝里溜进城墙内侧）。
		var arc_step: float = 2.0 * asin(clampf(1.5 / (2.0 * wall_radius), 0.0, 1.0))
		var arc_walls: int = maxi(9, int(ceil(1.56 / maxf(arc_step, 0.001))) + 1)
		for i in range(arc_walls):
			var t: float = float(i) / float(arc_walls - 1)
			var wa: float = lerpf(-0.78, 0.78, t)
			var wp: Vector3 = _find_defense_spot(castle, dir, wa, wall_radius, 27, 16.0)
			if wp != Vector3.ZERO:
				_add_defense_slot(27, wp, 20.0 + absf(t - 0.5) * 6.0, "wall")

	for side in [-1.0, 1.0]:
		var ca: float = 0.34 * side
		var cp: Vector3 = _find_defense_spot(castle, dir, ca, 9.8, 26, 9.8)
		if cp != Vector3.ZERO:
			_add_defense_slot(26, cp, 32.0, "tower")
	# 炮塔也被占位时补搜：正面/侧面优先，实在不行再找背面空隙
	if _count_planned(26) < 2:
		for a in [-0.7, 0.7, 0.0, -1.0, 1.0, -1.4, 1.4, -1.8, 1.8, -2.2, 2.2, -2.6, 2.6, 3.14]:
			if _count_planned(26) >= 2:
				break
			var cp2: Vector3 = _find_defense_spot(castle, dir, a, 9.8, 26, 9.8)
			if cp2 != Vector3.ZERO:
				_add_defense_slot(26, cp2, 33.0, "tower")

	_defense_queue.sort_custom(func(a, b): return float(a["priority"]) < float(b["priority"]))
	return not _defense_queue.is_empty()

# 在一段弧线/半径附近寻找可建造点：先试原位置，再向内外、左右微调
func _find_defense_spot(castle, dir: Vector3, angle: float, dist: float, b_id: int, max_dist: float) -> Vector3:
	var cfg: Dictionary = EntityDatabase.get_config(b_id)
	if cfg.is_empty():
		return Vector3.ZERO
	var radius: float = float(cfg.get("body_radius", 1.0))
	for da in [0.0, 0.12, -0.12, 0.24, -0.24, 0.36, -0.36, 0.5, -0.5, 0.68, -0.68]:
		for dd in [0.0, 1.2, -1.2, 2.2, -2.2, 3.2, -3.2]:
			var try_dist: float = dist + float(dd)
			if try_dist < 5.0 or try_dist > max_dist:
				continue
			var p: Vector3 = castle.global_position + dir.rotated(Vector3.UP, angle + float(da)) * try_dist
			if not _is_valid_defense_ground(p, radius, true):
				continue
			if not _defense_slot_clear(p, radius, b_id):
				continue
			return p
	return Vector3.ZERO

func _pick_wall_radius(castle, dir: Vector3) -> float:
	var best_r: float = DEFENSE_WALL_RADIUS
	var best_n: int = -1
	for r in [DEFENSE_WALL_RADIUS, 13.6, 15.0, 11.0]:
		var n: int = 0
		for i in range(9):
			var t: float = float(i) / 8.0
			var wa: float = lerpf(-0.78, 0.78, t)
			var p: Vector3 = castle.global_position + dir.rotated(Vector3.UP, wa) * float(r)
			if _is_valid_defense_ground(p, 1.0, true) and _defense_slot_clear(p, 1.0, 27):
				n += 1
		if n > best_n:
			best_n = n
			best_r = float(r)
	return best_r

func _count_planned(b_id: int) -> int:
	var n: int = 0
	for s in _defense_slots:
		if int(s["id"]) == b_id:
			n += 1
	return n

func _defense_slot_clear(pos: Vector3, radius: float, b_id: int) -> bool:
	for s in _defense_slots:
		var cfg: Dictionary = EntityDatabase.get_config(int(s["id"]))
		var other_r: float = float(cfg.get("body_radius", 1.0))
		var min_sep: float = radius + other_r + 0.6
		# 城墙是一段接一段的，墙体之间可以贴得更近
		if b_id == 27 and int(s["id"]) == 27:
			min_sep = 0.9
		if (s["pos"] - pos).length() < min_sep:
			return false
	return true

func _add_defense_slot(b_id: int, pos: Vector3, priority: float, kind: String) -> void:
	var cfg: Dictionary = EntityDatabase.get_config(b_id)
	if cfg.is_empty():
		return
	var radius: float = float(cfg.get("body_radius", 1.0))
	# 防线塔位在规划阶段不受敌军距离影响；建好之后敌方靠近也不会把已有计划清空。
	if not _is_valid_defense_ground(pos, radius, true):
		return
	if not _defense_slot_clear(pos, radius, b_id):
		return
	_defense_slots.append({"id": b_id, "pos": pos})
	_defense_queue.append({"id": b_id, "pos": pos, "priority": priority, "tries": 0})
	if kind == "wall":
		wall_positions.append(pos)
	else:
		tower_positions.append({"id": b_id, "pos": pos})

func _build_defense_step() -> void:
	if _defense_queue.is_empty():
		return
	var now: float = float(ai.battle.game_time)
	if now < _defense_retry_at:
		return
	var built: int = 0
	var i: int = 0
	while i < _defense_queue.size() and built < DEFENSE_BUILD_MAX_PER_TICK:
		var item: Dictionary = _defense_queue[i]
		var b_id: int = int(item["id"])
		var b_pos: Vector3 = item["pos"]
		if _pos_has_building(b_id, b_pos):
			_defense_queue.remove_at(i)
			continue
		var cap: int = 12 if b_id == 27 else 10
		if ai.count_building(b_id) >= cap:
			_defense_queue.remove_at(i)
			continue
		if not ai._ai_can_build(b_id):
			break
		if not _can_spend_building(b_id, _defense_reserve()):
			break
		var facing: Vector3 = _defense_dir if b_id in TOWER_IDS else Vector3.ZERO
		if ai.build_building(b_id, b_pos, facing):
			built += 1
			_defense_queue.remove_at(i)
			continue
		item["tries"] = int(item.get("tries", 0)) + 1
		if int(item["tries"]) >= 4:
			_defense_queue.remove_at(i)
			continue
		i += 1
		_defense_retry_at = now + 3.0
	if built > 0:
		_defense_retry_at = now + 0.5

func _queue_defense_gaps() -> void:
	for slot in _defense_slots:
		var b_id: int = int(slot["id"])
		var p: Vector3 = slot["pos"]
		if _pos_has_building(b_id, p):
			continue
		if _queue_has(b_id, p):
			continue
		_defense_queue.append({"id": b_id, "pos": p, "priority": 0.0, "tries": 0})
	_defense_queue.sort_custom(func(a, b): return float(a["priority"]) < float(b["priority"]))

func _queue_has(b_id: int, pos: Vector3) -> bool:
	for q in _defense_queue:
		if int(q["id"]) == b_id and (q["pos"] - pos).length() < 1.0:
			return true
	return false

func _pos_has_building(b_id: int, pos: Vector3) -> bool:
	for e in ai.battle.entities.get_children():
		if e is Building and e.health > 0 and int(e.entity_id) == b_id and ai.entity_belongs_to_me(e):
			if e.global_position.distance_to(pos) < 1.2:
				return true
	return false

func _maybe_reactive_tower(castle) -> void:
	if threat_level < 2:
		return
	var now: float = float(ai.battle.game_time)
	if now < _next_reactive_tower:
		return
	_next_reactive_tower = now + 28.0
	var p: Vector3 = castle.global_position + threat_dir * 7.8
	if _own_tower_near(p, 9.0):
		return
	var ids: Array = [25]
	if threat_level >= 3:
		ids.append(26)
	for b_id in ids:
		if ai.count_building(int(b_id)) >= (8 if int(b_id) == 25 else 4):
			continue
		if not _can_spend_building(int(b_id), _defense_reserve()):
			continue
		if _is_valid_defense_ground(p, float(EntityDatabase.get_config(int(b_id)).get("body_radius", 1.0))):
			ai.build_building(int(b_id), p, threat_dir)
			return

func _own_tower_near(pos: Vector3, radius: float) -> bool:
	for e in ai.battle.entities.get_children():
		if e is Building and e.health > 0 and int(e.entity_id) in TOWER_IDS and ai.entity_belongs_to_me(e):
			if e.global_position.distance_to(pos) < radius:
				return true
	return false

# ── 防守升级：只升级塔/墙，优先威胁方向 ──
func _manage_defense_upgrades(castle, delta: float) -> void:
	_upgrade_timer -= delta
	if _upgrade_timer > 0.0:
		return
	_upgrade_timer = DEFENSE_UPGRADE_INTERVAL
	var now: float = float(ai.battle.game_time)
	if threat_level == 0 and now < 240.0:
		return
	var towers: Array = []
	for e in ai.battle.entities.get_children():
		if not (e is Building) or e.health <= 0:
			continue
		if not ai.entity_belongs_to_me(e):
			continue
		if int(e.entity_id) not in TOWER_IDS:
			continue
		if not e.can_upgrade():
			continue
		if int(e.upgrade_level) >= int(castle.upgrade_level):
			continue
		if e.health < e.max_health * 0.45:
			continue
		towers.append(e)
	if towers.is_empty():
		return
	towers.sort_custom(func(a, b):
		return a.global_position.distance_squared_to(threat_center) < b.global_position.distance_squared_to(threat_center)
	)
	var reserve: float = 0.2 if threat_level >= 2 else 0.42
	for t in towers:
		var cost: Dictionary = t.get_upgrade_cost()
		if cost.is_empty():
			continue
		if not _can_spend(cost, reserve):
			continue
		if t.perform_upgrade(ai.battle):
			return

# ═══════════════════════════════════════════════════════════════
# 建筑被攻击 → 周围空闲部队反击
# ═══════════════════════════════════════════════════════════════

func _detect_building_attacks() -> void:
	var now: float = float(ai.battle.game_time)
	var seen: Dictionary = {}
	var alerts: Array = []
	for e in ai.battle.entities.get_children():
		if not (e is Building) or e.health <= 0:
			continue
		if int(e.team) == RTSConfig.Team.NEUTRAL:
			continue
		# 友方建筑包括自己的和同队玩家的建筑；敌方建筑不处理
		if ai._entity_is_enemy(e):
			continue
		var uid: int = e.get_instance_id()
		seen[uid] = true
		var prev: float = float(_building_health.get(uid, -1.0))
		_building_health[uid] = e.health
		if prev < 0.0 or e.health >= prev - 0.5:
			continue
		var attacker = e.get("_last_damager")
		# 远程弹丸/防御塔的 source 可能不是 Army，兜底找建筑周围最近的可战斗敌军
		if not _is_combat_enemy(attacker):
			var alert_radius: float = CASTLE_DEFENSE_RADIUS if int(e.entity_id) == CASTLE_ID else BUILDING_DEFENSE_RADIUS
			attacker = _nearest_enemy_combat(e.global_position, alert_radius)
		if attacker == null:
			continue
		alerts.append({"building": e, "attacker": attacker})
	# 同一帧多个建筑受袭时，先保主城，再保军事建筑，最后才保经济建筑，
	# 避免附近有限的空闲部队被边缘建筑先抽空。
	alerts.sort_custom(func(a, b):
		return _building_defense_priority(a["building"]) < _building_defense_priority(b["building"])
	)
	for alert in alerts:
		_send_building_defenders(alert["building"], alert["attacker"], now)
	# 清理已消失建筑的旧血量，防止 instance_id 复用造成误判
	for uid in _building_health.keys():
		if not seen.has(uid):
			_building_health.erase(uid)

func _building_defense_priority(building) -> int:
	if building == null or not is_instance_valid(building):
		return 9
	if int(building.entity_id) == CASTLE_ID:
		return 0
	if int(building.entity_id) in MILITARY_BUILDING_IDS:
		return 1
	return 2

func _send_building_defenders(building, attacker, now: float) -> void:
	if building == null or not is_instance_valid(building):
		return
	if attacker == null or not is_instance_valid(attacker) or attacker.health <= 0:
		return
	var is_castle: bool = int(building.entity_id) == CASTLE_ID
	var radius: float = CASTLE_DEFENSE_RADIUS if is_castle else BUILDING_DEFENSE_RADIUS
	var max_responders: int = CASTLE_DEFENSE_MAX if is_castle else BUILDING_DEFENSE_MAX
	var candidates: Array = []
	for u in _land_combat_units():
		if not is_instance_valid(u) or u.health <= 0:
			continue
		if u.global_position.distance_to(building.global_position) > radius:
			continue
		# 只调动真正空闲的部队；已有目标、移动/攻击移动、排队命令的部队不打断
		if u.current_target != null and is_instance_valid(u.current_target):
			continue
		if u.is_attack_moving or u.current_order != "" or not u.command_queue.is_empty():
			continue
		if _is_local_building_defender(u, now):
			continue
		# 攻击者可能在船上/墙上，近战或不会对空的兵种去了也打不到，
		# 不要把名额和回防标记浪费在无法攻击的目标上。
		if u.has_method("_can_attack_target") and not u._can_attack_target(attacker):
			continue
		if u.has_method("_is_target_attackable_now") and not u._is_target_attackable_now(attacker):
			continue
		candidates.append(u)
	# 距离最近的先响应，并限制单座建筑抽兵数量；主城威胁可多派一些。
	candidates.sort_custom(func(a, b):
		return a.global_position.distance_squared_to(building.global_position) < b.global_position.distance_squared_to(building.global_position)
	)
	var sent: int = 0
	for u in candidates:
		if sent >= max_responders:
			break
		# 非驻扎单位的原锚点=接到命令时的位置；目标死亡/超时后回这里，
		# 避免建筑防守部队被一路带到地图另一头。上一次回防的 meta 已过期时
		# 要刷新锚点，否则会把它送回上一座建筑附近。
		var prev_defense_until: float = -1.0
		if u.has_meta("ai_building_defense_until"):
			prev_defense_until = float(u.get_meta("ai_building_defense_until"))
		if u._defense_return_position == Vector3.ZERO or prev_defense_until <= now:
			u._defense_return_position = u.global_position
		# 驻扎中的部队也可以回防“自己附近的建筑”，这是防守例外；
		# 但给它一个短标记，防止同一帧后续守军调度把它重新拉回主城。
		u.set_meta("ai_building_defense_until", now + BUILDING_DEFENSE_HOLD)
		if u.has_method("attack_target"):
			u.attack_target(attacker)
		else:
			u.current_target = attacker
			u.current_order = "attack"
		sent += 1

func _is_local_building_defender(u, now: float) -> bool:
	if u == null or not is_instance_valid(u):
		return false
	return u.has_meta("ai_building_defense_until") and now < float(u.get_meta("ai_building_defense_until"))

# ═══════════════════════════════════════════════════════════════
# 守军调度
# ═══════════════════════════════════════════════════════════════

func _defense_mode_active() -> bool:
	if threat_level >= 2:
		return true
	if ai != null and float(ai.battle.game_time) < _force_guard_until:
		return true
	if ai != null and ai.has_method("_is_defending"):
		return bool(ai._is_defending())
	return false

# 判断“防守回撤”时是否应跳过该单位：
# 已经在主城 25 单位内、并且正有攻击目标，说明它正在家门口交战，不能被召回换目标。
func _skip_near_castle_active(unit, castle) -> bool:
	if unit == null or not is_instance_valid(unit) or castle == null or not is_instance_valid(castle):
		return false
	if unit.global_position.distance_squared_to(castle.global_position) > DEFENSE_RECALL_SAFE_RADIUS * DEFENSE_RECALL_SAFE_RADIUS:
		return false
	var target = unit.current_target
	return target != null and is_instance_valid(target)

# 城墙优先保留远程兵：守墙逻辑每 30 秒才巡检一次，守军快速补员
# 不能在这之前把刚生产出来的远程兵全部收进主城，否则城墙会长期空着。
func _has_valid_walls() -> bool:
	for b in ai.battle.entities.get_children():
		if b is Building and int(b.entity_id) == 27 and b.health > 0 and b.build_timer <= 0.0 \
				and ai.entity_belongs_to_me(b):
			return true
	return false

func _reserve_ranged_for_wall(unit, walls_exist: bool) -> bool:
	if not walls_exist or unit == null or not is_instance_valid(unit):
		return false
	if not ai.has_method("_is_ranged_wall_candidate") or not ai._is_ranged_wall_candidate(unit):
		return false
	return true

func _manage_home_guard(castle, delta: float) -> void:
	_guard_timer -= delta
	if _guard_timer > 0.0:
		return
	_guard_timer = GUARD_INTERVAL
	_prune_guard_ids()

	var own: Array = _land_combat_units()
	if own.is_empty():
		return
	var now: float = float(ai.battle.game_time)
	var is_defending: bool = _defense_mode_active()
	var walls_exist: bool = _has_valid_walls()
	var desired: int = 0
	if now < _force_guard_until:
		desired = own.size()
	else:
		match threat_level:
			0:
				desired = mini(own.size(), HOME_GUARD_COUNT)
			1:
				desired = mini(own.size(), HOME_GUARD_COUNT)
			2:
				desired = mini(own.size(), maxi(6, threat_enemy_count * 2 + 2))
			_:
				desired = own.size()
	desired = mini(desired, own.size())

	# 家门口已有目标、正在交战的部队算作有效防守力量，不重复从远处抽兵填补名额
	if is_defending:
		var active_near: int = 0
		for u in own:
			if _skip_near_castle_active(u, castle):
				active_near += 1
				var active_uid: int = u.get_instance_id()
				if _home_guard_ids.has(active_uid):
					_release_guard(active_uid)
		desired = maxi(0, desired - active_near)

	own.sort_custom(func(a, b):
		return a.global_position.distance_squared_to(castle.global_position) < b.global_position.distance_squared_to(castle.global_position)
	)
	var rally: Vector3 = _guard_rally(castle)
	var assigned: int = 0
	for u in own:
		if assigned >= desired:
			break
		if not is_instance_valid(u) or u.health <= 0:
			continue
		if _is_local_building_defender(u, now):
			continue
		# 非防守状态不再调动已有驻扎点的部队；自己的常驻守军已在 _home_guard_ids 中，
		# 允许继续刷新集结点，不会因此被重复招募或丢失。
		var uid: int = u.get_instance_id()
		if not is_defending and u.garrison_point != Vector3.ZERO and not _home_guard_ids.has(uid):
			continue
		if is_defending and _skip_near_castle_active(u, castle):
			# 家门口正在交战的部队保留当前目标；驻扎点已在前面统一解除
			continue
		# 守卫主城只给没有任务的部队下达指令：正在交战、攻击移动、采集/交付、
		# 排队执行命令或已经驻扎的部队继续做自己的事，不能被守军调度打断。
		if _unit_has_existing_task(u):
			continue
		# 城墙优先保留远程兵；已经在守军名单里的单位不受影响。
		# 紧急回防（_force_guard_until）期间不再保留，所有能回的单位都要回主城。
		if not _home_guard_ids.has(uid) and threat_level < 2 and now >= _force_guard_until \
				and _reserve_ranged_for_wall(u, walls_exist):
			continue
		var special: bool = u.has_meta("ai_resource_guard") or u.has_meta("ai_harass")
		if special and threat_level < 3 and now >= _force_guard_until:
			continue
		if special:
			_clear_special_role(u)
		_assign_guard(u, rally)
		assigned += 1

	# 威胁解除/守军超编时释放距离主城最远的守军
	var extra: Array = []
	for uid in _home_guard_ids.keys():
		if _home_guard_ids.size() - extra.size() <= desired:
			break
		var u = instance_from_id(int(uid))
		if u == null or not is_instance_valid(u) or not (u is Army) or u.health <= 0:
			_home_guard_ids.erase(uid)
			continue
		extra.append({"id": int(uid), "d": u.global_position.distance_squared_to(castle.global_position)})
	extra.sort_custom(func(a, b): return float(a["d"]) > float(b["d"]))
	for item in extra:
		_release_guard(int(item["id"]))

# 主城守军每 2 秒做一次轻量补员：守卫阵亡/被调走时不必等满一分钟审计。
# 数量/威胁等级变化仍由每 60 秒的 _manage_home_guard 完整审计处理。
func _quick_fill_home_guard(castle, delta: float) -> void:
	_guard_refill_timer -= delta
	if _guard_refill_timer > 0.0:
		return
	_guard_refill_timer = GUARD_REFILL_INTERVAL
	if _guard_timer <= 0.0:
		return
	if threat_level >= 2:
		# 进入防守/危急时立刻走完整守军调度，不等一分钟。
		_guard_timer = 0.0
		_manage_home_guard(castle, 0.0)
		return
	_prune_guard_ids()
	if _home_guard_ids.size() >= HOME_GUARD_COUNT:
		return
	var own: Array = _land_combat_units()
	if own.is_empty():
		return
	var walls_exist: bool = _has_valid_walls()
	own.sort_custom(func(a, b):
		return a.global_position.distance_squared_to(castle.global_position) < b.global_position.distance_squared_to(castle.global_position)
	)
	var rally: Vector3 = _guard_rally(castle)
	for u in own:
		if _home_guard_ids.size() >= HOME_GUARD_COUNT:
			break
		if not is_instance_valid(u) or u.health <= 0:
			continue
		if u.global_position.distance_to(castle.global_position) > HOME_GUARD_REFILL_RADIUS:
			# own 已按距离排序，后面的只会更远。
			break
		if u.has_meta("ai_home_guard") or u.has_meta("ai_wall_guard"):
			continue
		# 补员同样只挑没有任务的部队，避免把正在交战/行军/采集/排队的部队拉回主城。
		if _unit_has_existing_task(u):
			continue
		if _is_local_building_defender(u, float(ai.battle.game_time)):
			continue
		if _reserve_ranged_for_wall(u, walls_exist) \
				and float(ai.battle.game_time) >= _force_guard_until:
			continue
		_assign_guard(u, rally)

# 主攻前调用：解除主城守军的驻扎，避免 attack_move 被 garrison_point 拉回主城
func release_guards_for_attack() -> void:
	_force_guard_until = -999.0
	_guard_timer = 0.0
	for uid in _home_guard_ids.keys():
		_release_guard(int(uid))
	_home_guard_ids.clear()

func _assign_home_guard(castle, force: bool) -> void:
	var own: Array = _land_combat_units()
	if own.is_empty():
		return
	var is_defending: bool = _defense_mode_active()
	var rally: Vector3 = _guard_rally(castle)
	var desired: int = own.size() if force else mini(own.size(), maxi(HOME_GUARD_COUNT, threat_enemy_count * 2 + 2))
	if is_defending:
		var active_near: int = 0
		for u in own:
			if _skip_near_castle_active(u, castle):
				active_near += 1
				var active_uid: int = u.get_instance_id()
				if _home_guard_ids.has(active_uid):
					_release_guard(active_uid)
		desired = maxi(0, desired - active_near)
	var assigned: int = 0
	own.sort_custom(func(a, b):
		return a.global_position.distance_squared_to(castle.global_position) < b.global_position.distance_squared_to(castle.global_position)
	)
	for u in own:
		if assigned >= desired:
			break
		if not is_instance_valid(u) or u.health <= 0:
			continue
		if _is_local_building_defender(u, float(ai.battle.game_time)):
			continue
		# 强制回防也只动没有任务的部队；正在执行任务的主力继续自己的行动。
		if _unit_has_existing_task(u):
			continue
		if is_defending and _skip_near_castle_active(u, castle):
			continue
		if force or threat_level >= 3:
			_clear_special_role(u)
		elif u.has_meta("ai_resource_guard") or u.has_meta("ai_harass"):
			continue
		_assign_guard(u, rally)
		assigned += 1

func _guard_rally(castle) -> Vector3:
	var dir: Vector3 = threat_dir
	if threat_level == 0:
		dir = _enemy_castle_dir(castle)
	dir.y = 0.0
	if dir.length_squared() < 0.01:
		dir = Vector3.FORWARD
	var p: Vector3 = castle.global_position + dir.normalized() * 5.5
	var gx: int = int(p.x + RTSConfig.MAP_SIZE / 2.0)
	var gz: int = int(p.z + RTSConfig.MAP_SIZE / 2.0)
	if gx < 0 or gx >= RTSConfig.MAP_SIZE or gz < 0 or gz >= RTSConfig.MAP_SIZE:
		return castle.global_position
	if ai.battle.get_terrain_at_grid(gx, gz) != 0:
		return castle.global_position + Vector3(3.0, 0.0, 3.0)
	return p

func _assign_guard(unit, rally: Vector3) -> void:
	var uid: int = unit.get_instance_id()
	var is_new: bool = not unit.has_meta("ai_home_guard")
	_home_guard_ids[uid] = true
	unit.set_meta("ai_home_guard", true)
	# 驻军点只为“新守军/换了集结点”更新，避免每 0.8 秒重建一次旗帜标记
	if is_new or unit.garrison_point.distance_to(rally) > 1.0:
		unit.set_garrison(rally)
	if unit.global_position.distance_to(rally) > 4.0 and unit.current_order != "move":
		unit.move_to(rally)

func _release_guard(uid: int) -> void:
	_home_guard_ids.erase(uid)
	var u = instance_from_id(uid)
	if u == null or not is_instance_valid(u):
		return
	if u.has_meta("ai_home_guard"):
		u.remove_meta("ai_home_guard")
	u.garrison_point = Vector3.ZERO
	if u.has_method("_hide_garrison_marker"):
		u.call("_hide_garrison_marker")

func _prune_guard_ids() -> void:
	for uid in _home_guard_ids.keys():
		var u = instance_from_id(int(uid))
		if u == null or not is_instance_valid(u) or not (u is Army) or u.health <= 0 \
				or not u.has_meta("ai_home_guard"):
			_home_guard_ids.erase(uid)

func _clear_special_role(unit) -> void:
	if unit.has_meta("ai_harass"):
		unit.remove_meta("ai_harass")
	if unit.has_meta("ai_resource_guard"):
		unit.remove_meta("ai_resource_guard")
	_resource_guard_ids.erase(unit.get_instance_id())

func _land_combat_units() -> Array:
	var out: Array = []
	for e in ai.battle.entities.get_children():
		if not (e is Army) or e.health <= 0:
			continue
		if not ai.entity_belongs_to_me(e):
			continue
		if int(e.target_type) <= 0:
			continue
		if int(e.entity_id) in [10, 14, 43, 44, 45, 46, 47, 48, 49, 50, 51]:
			continue
		if e.water_capable:
			continue
		# 正在登船/坐船渡水的单位由 AIWaterCrossing 管理，不能被守军调度拉回
		if e.has_meta("ai_transporting"):
			continue
		# 固定在城墙上的远程单位由 AI 的守墙逻辑管理，不能再被守军调度拉走
		if e.has_meta("ai_wall_guard"):
			continue
		var boarded = e.get("_boarded_on")
		if boarded != null and int(boarded) != -1:
			continue
		var sgb = e.get("_soldier_garrison_building")
		if sgb != null and sgb.get_ref() != null:
			continue
		out.append(e)
	return out

# 是否已有目标/正在执行任务：这类部队不应被资源守军调度拉走
# 包括追击/攻击目标、移动/攻击移动/采集/交付中、有排队指令、已驻扎在其他据点的部队
func _unit_has_existing_task(u) -> bool:
	if u.current_target != null and is_instance_valid(u.current_target):
		return true
	if u.is_attack_moving or u.current_order != "":
		return true
	if not u.command_queue.is_empty():
		return true
	if u.garrison_point != Vector3.ZERO:
		return true
	return false

# ═══════════════════════════════════════════════════════════════
# 资源区控制
# ═══════════════════════════════════════════════════════════════

func _manage_resource_security(castle, delta: float) -> void:
	_resource_timer -= delta
	if _resource_timer > 0.0:
		return
	_resource_timer = RESOURCE_INTERVAL
	_zone_timer -= RESOURCE_INTERVAL
	if _zone_timer <= 0.0:
		_zone_timer = RESOURCE_ZONE_INTERVAL
		_refresh_resource_zones(castle)
	_defend_resources(castle)
	_maybe_build_outpost(castle)

func _refresh_resource_zones(castle) -> void:
	var clusters: Array = []
	for w in ai.battle.entities.get_children():
		if not (w is Army) or w.health <= 0 or not ai.entity_belongs_to_me(w):
			continue
		if int(w.entity_id) != 10:
			continue
		var tgt = w.current_target
		if tgt == null or not is_instance_valid(tgt) or not (tgt is WorldResource):
			continue
		if tgt.health <= 0:
			continue
		var p: Vector3 = tgt.global_position
		var found = null
		for c in clusters:
			if c["center"].distance_to(p) < 10.0:
				found = c
				break
		if found == null:
			found = {"center": p, "sum": Vector3.ZERO, "workers": 0, "nodes": {}, "type": String(tgt.resource_type)}
			clusters.append(found)
		found["sum"] += p
		found["workers"] = int(found["workers"]) + 1
		found["center"] = found["sum"] / float(found["workers"])
		found["nodes"][tgt.get_instance_id()] = true

	var zones: Array = []
	for c in clusters:
		var center: Vector3 = c["center"]
		var dist: float = center.distance_to(castle.global_position)
		if dist > 62.0:
			continue
		var score: float = float(c["workers"]) * 2.0 + minf(dist / 18.0, 3.0)
		if String(c["type"]) in ["gold", "stone"]:
			score += 0.6
		if dist > 24.0:
			score += 1.0
		zones.append({
			"center": center,
			"type": String(c["type"]),
			"workers": int(c["workers"]),
			"nodes": c["nodes"],
			"dist": dist,
			"score": score,
			"enemy_count": 0,
		})
	zones.sort_custom(func(a, b): return float(a["score"]) > float(b["score"]))
	resource_zones = zones.slice(0, 3)

func _defend_resources(castle) -> void:
	var now: float = float(ai.battle.game_time)
	var workers: Array = []
	for w in ai.battle.entities.get_children():
		if w is Army and w.health > 0 and int(w.entity_id) == 10 and ai.entity_belongs_to_me(w):
			workers.append(w)

	# 1) 农民避险：只有敌人贴到 8m 才短暂躲避，往远离敌人的方向挪 6m，
	#    不再把所有农民都召回主城；防守状态下资源采集也尽量保持。
	for w in workers:
		var danger = _nearest_enemy_combat(w.global_position, WORKER_FLEE_RADIUS)
		if danger:
			# 已经在躲避中就不要每 1.5 秒重复改目标，否则农民会被一路推着跑
			if w.has_meta("ai_flee_until") and now < float(w.get_meta("ai_flee_until")):
				continue
			w.set_meta("ai_flee_until", now + WORKER_FLEE_TIME)
			var has_cargo: bool = false
			for rk in ["gold", "wood", "stone", "food", "oil"]:
				if int(w.cargo.get(rk, 0)) > 0:
					has_cargo = true
					break
			if has_cargo:
				# 有货物时按正常经济逻辑去交付，不强行把它押回主城
				if w.current_order != "deliver" and w.current_order != "move":
					if w.has_method("_return_to_deliver"):
						w.call("_return_to_deliver")
			elif w.current_order != "move":
				var away: Vector3 = w.global_position - danger.global_position
				away.y = 0.0
				if away.length_squared() < 0.01:
					away = Vector3.RIGHT
				var flee_pos: Vector3 = w.global_position + away.normalized() * WORKER_FLEE_DISTANCE
				var half_limit: float = RTSConfig.MAP_SIZE / 2.0 - 3.0
				flee_pos.x = clampf(flee_pos.x, -half_limit, half_limit)
				flee_pos.z = clampf(flee_pos.z, -half_limit, half_limit)
				w.move_to(flee_pos)
		elif w.has_meta("ai_flee_until") and now >= float(w.get_meta("ai_flee_until")):
			w.remove_meta("ai_flee_until")

	# 2) 选出最危险的资源区
	var hot_zone = null
	var hot_enemies: int = 0
	for z in resource_zones:
		var ec: int = _count_enemy_combat_near(z["center"], 17.0)
		z["enemy_count"] = ec
		if ec > hot_enemies:
			hot_enemies = ec
			hot_zone = z
	if hot_zone == null:
		# 资源区刷新有 12 秒间隔；若有农民已经挨打，用农民位置临时兜底
		for w in workers:
			var danger = _nearest_enemy_combat(w.global_position, 13.0)
			if danger:
				hot_zone = {"center": w.global_position, "workers": 1, "type": "emergency", "enemy_count": 1}
				hot_enemies = 1
				break

	if hot_zone != null:
		_resource_guard_hold_until = now + RESOURCE_GUARD_HOLD
		var needed: int = mini(3, maxi(1, hot_enemies))
		_prune_resource_guards()
		var guards: Array = []
		for uid in _resource_guard_ids.keys():
			var u = instance_from_id(int(uid))
			if u != null and is_instance_valid(u) and u is Army and u.health > 0:
				guards.append(u)
		if guards.size() < needed:
			var candidates: Array = []
			for u in _land_combat_units():
				if u.has_meta("ai_home_guard") or u.has_meta("ai_harass"):
					continue
				# 已有目标/正在执行任务的部队保持原命令，不拉来守资源
				if _unit_has_existing_task(u):
					continue
				if _resource_guard_ids.has(u.get_instance_id()):
					continue
				var d: float = u.global_position.distance_to(hot_zone["center"])
				if d > 45.0 and u.global_position.distance_to(castle.global_position) > 25.0:
					continue
				candidates.append({"u": u, "d": d})
			candidates.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))
			for item in candidates:
				if guards.size() >= needed:
					break
				var u = item["u"]
				_resource_guard_ids[u.get_instance_id()] = true
				u.set_meta("ai_resource_guard", true)
				u.set_garrison(hot_zone["center"])
				if u.global_position.distance_to(hot_zone["center"]) > 5.0:
					u.move_to(hot_zone["center"])
				guards.append(u)
		else:
			# 资源区转移时，让已有卫队跟随新位置
			for u in guards:
				if u.global_position.distance_to(hot_zone["center"]) > 12.0:
					u.set_garrison(hot_zone["center"])
					u.move_to(hot_zone["center"])
	elif now >= _resource_guard_hold_until:
		_prune_resource_guards()
		for uid in _resource_guard_ids.keys():
			var u = instance_from_id(int(uid))
			_resource_guard_ids.erase(uid)
			if u != null and is_instance_valid(u) and u is Army:
				if u.has_meta("ai_resource_guard"):
					u.remove_meta("ai_resource_guard")
				u.garrison_point = Vector3.ZERO
				if u.has_method("_hide_garrison_marker"):
					u.call("_hide_garrison_marker")

func _prune_resource_guards() -> void:
	for uid in _resource_guard_ids.keys():
		var u = instance_from_id(int(uid))
		if u == null or not is_instance_valid(u) or not (u is Army) or u.health <= 0:
			_resource_guard_ids.erase(uid)

func _own_outpost_near(pos: Vector3, radius: float) -> bool:
	for e in ai.battle.entities.get_children():
		if e is Building and e.health > 0 and int(e.entity_id) == OUTPOST_ID and ai.entity_belongs_to_me(e):
			if e.global_position.distance_to(pos) < radius:
				return true
	return false

func _maybe_build_outpost(castle) -> void:
	var now: float = float(ai.battle.game_time)
	if now < _next_outpost:
		return
	_next_outpost = now + OUTPOST_INTERVAL
	if ai.count_building(OUTPOST_ID) >= 2:
		return
	var best = null
	var best_score: float = 0.0
	for z in resource_zones:
		if int(z["workers"]) < 2:
			continue
		if float(z["dist"]) < 22.0 or float(z["dist"]) > 58.0:
			continue
		if int(z.get("enemy_count", 0)) > 0:
			continue
		if _own_outpost_near(z["center"], 12.0):
			continue
		var score: float = float(z["workers"]) * 2.0 + float(z["dist"]) / 20.0
		if score > best_score:
			best_score = score
			best = z
	if best == null:
		return
	if not _can_spend_building(OUTPOST_ID, 0.4):
		return
	for dist in [4.5, 6.0, 8.0]:
		for i in range(8):
			var a: float = TAU * float(i) / 8.0
			var p: Vector3 = best["center"] + Vector3(cos(a) * dist, 0.0, sin(a) * dist)
			if _is_valid_defense_ground(p, float(EntityDatabase.get_config(OUTPOST_ID).get("body_radius", 0.6))):
				if ai.build_building(OUTPOST_ID, p):
					return

# ═══════════════════════════════════════════════════════════════
# 通用判定
# ═══════════════════════════════════════════════════════════════

func _is_valid_defense_ground(pos: Vector3, radius: float = 1.0, allow_under_fire: bool = false) -> bool:
	var half: float = RTSConfig.MAP_SIZE / 2.0
	if absf(pos.x) >= half - 2.0 or absf(pos.z) >= half - 2.0:
		return false
	var gx: int = int(pos.x + half)
	var gz: int = int(pos.z + half)
	if gx < 0 or gx >= RTSConfig.MAP_SIZE or gz < 0 or gz >= RTSConfig.MAP_SIZE:
		return false
	if ai.battle.get_terrain_at_grid(gx, gz) != 0:
		return false
	for e in ai.battle.entities.get_children():
		if not (e is GameEntity) or e.health <= 0:
			continue
		var d: float = e.global_position.distance_to(pos)
		if e is WorldResource:
			if d < radius + 1.8:
				return false
		elif e is Building:
			if d < radius + float(e.body_radius) + 0.8:
				return false
		elif e is Army:
			# 规划防线时不要被己方部队挡住塔位：部队会移动，建造失败还有补建队列。
			# 但敌方单位仍然不能重叠，否则会把塔位规划到敌人身上。
			if allow_under_fire and ai.entity_belongs_to_me(e):
				continue
			if d < radius + float(e.body_radius) + 0.5:
				return false
	if not allow_under_fire:
		for e in ai._visible_enemies:
			if not is_instance_valid(e) or not (e is Army or e is Building) or e.health <= 0:
				continue
			if not ai._entity_is_enemy(e):
				continue
			if e.global_position.distance_to(pos) < 5.0:
				return false
	return _has_friendly_vision(pos)

func _has_friendly_vision(pos: Vector3) -> bool:
	# 主城默认视野 10m，而外墙在 12m 外；先按“防线包络”允许规划，
	# 实际建造时前面几座箭塔会提供视野，build_building 仍会做最终校验。
	var castle = ai.get_peer_castle(ai.my_peer_id)
	if castle != null and castle.global_position.distance_to(pos) <= 18.0:
		return true
	for e in ai.battle.entities.get_children():
		if e is GameEntity and e.health > 0 and ai.entity_belongs_to_me(e):
			if e.global_position.distance_to(pos) <= float(e.vision_range):
				return true
	return false

func _can_spend_building(b_id: int, reserve_ratio: float) -> bool:
	var cfg: Dictionary = EntityDatabase.get_config(b_id)
	if cfg.is_empty():
		return false
	var cost: Dictionary = cfg.get("cost", {})
	return _can_spend(cost, reserve_ratio)

func _can_spend(cost: Dictionary, reserve_ratio: float) -> bool:
	var res: Dictionary = ai._get_resources()
	var limits: Dictionary = ai._get_limits()
	for k in cost:
		var need: float = float(cost[k])
		if float(res.get(k, 0)) < need:
			return false
		var limit: float = maxf(float(limits.get(k, 500)), 1.0)
		if float(res.get(k, 0)) - need < limit * reserve_ratio:
			return false
	return true

func _defense_reserve() -> float:
	# 防守建设/升级必须先留出一部分资源给补兵，否则 AIDefense 在 AI 生产之前把资源花光，
	# 就会出现“进入防守后不再生产军队”的情况。
	if threat_level >= 2:
		return 0.22
	if threat_level == 1:
		return 0.2
	return 0.35

func _nearest_enemy_combat(pos: Vector3, radius: float):
	var best = null
	var best_d: float = radius
	for e in ai._visible_enemies:
		if not _is_combat_enemy(e):
			continue
		var d: float = e.global_position.distance_to(pos)
		if d < best_d:
			best_d = d
			best = e
	return best

func _count_enemy_combat_near(pos: Vector3, radius: float) -> int:
	var n: int = 0
	for e in ai._visible_enemies:
		if not _is_combat_enemy(e):
			continue
		if e.global_position.distance_to(pos) <= radius:
			n += 1
	return n
