extends Node

# 战役导演（闯关模式的核心）。
#
# 战斗场景检测到 GameSettings.campaign_mode 时创建本节点，由它接管：
#   1. 开局生成：按关卡数据放置主城（可有可无）、城墙、塔、开局军队、波次刷兵；
#   2. 任务推进：每帧推进目标进度（拆城 / 存活 / 占领区域计时）；
#   3. 胜负裁决：主城被毁、全军覆没、超时、目标达成；
#   4. 结算与存档：1~3 星评级、解锁下一关、重试 / 下一关 / 返回战役。
#
# 普通对局完全不受影响：只有 campaign_mode 为真时才会走到这里。

const CampaignDataScript = preload("res://scripts/data/CampaignData.gd")
const CampaignProgressScript = preload("res://scripts/core/CampaignProgress.gd")
const TrainingDataScript = preload("res://scripts/data/TrainingData.gd")
const TrainingProgressScript = preload("res://scripts/core/TrainingProgress.gd")
const CampaignHUDScript = preload("res://scripts/ui/CampaignHUD.gd")
const UIThemeScript = preload("res://scripts/ui/UITheme.gd")

# ── 控制区/护送类目标的 AI 布防参数 ──
# 战役 AI 原来只会闷头打玩家主城，占领区和护送路线没人争；
# 这里给敌人配开局守军 + 持续增援 + 护送途中的伏兵。
const AI_GUARD_UNIT_IDS: Array = [11, 12, 11, 12, 15, 16, 18]  # 步兵/弓手/骑兵/攻城车轮换
const AI_ZONE_FIRST_DELAY: float = 14.0     # 第一次增援控制区的延迟（秒）
const AI_ZONE_INTERVAL: float = 30.0        # 之后每隔多久再派一队去争控制区
const AI_ZONE_MAX_WAVES: int = 5            # 单局最多增援次数，避免无限刷兵
const AI_ESCORT_TRIGGERS: Array = [0.25, 0.55, 0.8]     # 信使走到路线这些比例时触发伏兵

enum State { RUNNING, WON, LOST }

var bm: RTSBattleManager = null
var level: Dictionary = {}
var state: int = State.RUNNING
var elapsed: float = 0.0
var hold_seconds: float = 0.0
var objective_states: Array = []
var progress_text: String = ""
var warning_text: String = ""

var player_castle = null
var enemy_castle = null
var player_anchor: Vector3 = Vector3.ZERO
var enemy_anchor: Vector3 = Vector3.ZERO
var enemy_spawn_point: Vector3 = Vector3.ZERO
# 防守关的多路进攻入口：按波次轮换主攻方向，同一波再拆主攻/侧翼两股。
var _defense_wave_lanes: Array = []

var _zone_center: Vector3 = Vector3.ZERO
var _zone_radius: float = 12.0
var _zone_hold_need: float = 120.0
var _zone_mesh: MeshInstance3D = null
var _zone_disc: MeshInstance3D = null
var _zone_pillar: MeshInstance3D = null
var _zone_pillar_mat: StandardMaterial3D = null
var _zone_label: Label3D = null
var _zone_state_text: String = ""
var _zone_ping_timer: float = 0.0
var _zone_nearest_dist: float = -1.0
var _zone_enemy_inside: bool = false
# 屏幕空间标记（俯视时 3D 文字会被压扁，所以再用一层 2D 标签钉在目标上方）
var _screen_layer: CanvasLayer = null
var _zone_screen_label: Label = null
var _escort_screen_label: Label = null

var _waves: Array = []
var _waves_fired: int = 0
var _wave_warned: Dictionary = {}
var _tick: float = 0.0
var _army_wiped_time: float = 0.0
var _hud = null
var _result_layer: CanvasLayer = null

# ── 扩展目标（护送 / 拆塔 / 采集 / 击杀）──
var _escort_unit = null
var _escort_unit_id: int = 0
var _escort_zone_center: Vector3 = Vector3.ZERO
var _escort_zone_radius: float = 8.0
var _escort_mesh: MeshInstance3D = null
var _target_ids: Array = []
var _target_need: int = 0
var _target_initial: int = 0
var _gather_need: float = 0.0
var _gather_total: float = 0.0
var _gather_last_total: float = -1.0
var _kill_need: int = 0
var _kill_ids: Array = []
var _kill_intercept_dist: float = 0.0   # >0 时：只有死在离主城这么远之外的才算"击沉"
var _kill_max_slip: int = 0             # >0 时：靠岸漏过的数量超过它就判负
var _kill_slipped: int = 0
var _enemy_kills: int = 0
var _enemy_kills_by_id: Dictionary = {}
var _enemy_water_spawn: Vector3 = Vector3.ZERO
var _has_water_waves: bool = false

# 无尽挑战（endless）：波次越滚越强，记录波数与得分
var _endless_on: bool = false
var _endless_first: float = 20.0
var _endless_interval: float = 30.0
var _endless_waves: int = 0
var _endless_timer: float = 0.0
var _endless_score: int = 0

# 多控制区（hold_zones）与"守住自家建筑"（defend_targets）目标
var _multi_zones: Array = []
var _defend_ids: Array = []
var _defend_buildings: Array = []   # 开局就存在的指定目标建筑；玩家后建的同 ID 建筑不算
var _defend_min_alive: int = 1
var _defend_initial: int = 0
var _defend_alive: int = 0
var _defend_duration: float = 0.0

# 控制区/护送点的 AI 布防状态
var _ai_zone_timer: float = 0.0
var _ai_zone_waves: int = 0
var _ai_escort_points: Array = []     # 护送路线上预埋的伏击点
var _ai_escort_flags: Array = []      # 每档伏击是否已触发

# 开局配置解析出来的任务参数
var _survive_need: float = -1.0
var _destroy_castle_goal: bool = false
var _has_army_wiped_fail: bool = false
var _has_castle_lost_fail: bool = false
var _has_timeout_fail: bool = false
var _time_limit: float = 0.0
var _three_star_time: float = 0.0
var _three_star_warned: bool = false

func _ready() -> void:
	if not (GameSettings.campaign_mode or GameSettings.training_mode):
		queue_free()
		return
	if GameSettings.campaign_level_id.is_empty() and GameSettings.training_level_id.is_empty():
		queue_free()
		return
	# 等战斗管理器把 UI / 面板都建好再开局
	set_process(false)
	call_deferred("_setup")

func _is_training() -> bool:
	return GameSettings.training_mode

func _data_source():
	return TrainingDataScript if _is_training() else CampaignDataScript

func _progress_source():
	return TrainingProgressScript if _is_training() else CampaignProgressScript

# ==================== 开局生成 ====================

func _setup() -> void:
	bm = get_parent() as RTSBattleManager
	if bm == null:
		push_error("CampaignDirector: 父节点不是 RTSBattleManager")
		queue_free()
		return
	var level_id := GameSettings.training_level_id if _is_training() else GameSettings.campaign_level_id
	if _is_training():
		level = _data_source().get_level(level_id, GameSettings.training_nation)
	else:
		level = _data_source().get_level(level_id)
	if level.is_empty():
		push_warning("CampaignDirector: 找不到关卡 %s，按普通对局继续" % level_id)
		queue_free()
		return

	var player_cfg: Dictionary = level.get("player", {})
	var enemy_cfg: Dictionary = level.get("enemy", {})
	var p_nation: int = int(player_cfg.get("nation", GameSettings.player_nation))
	var e_nation: int = int(enemy_cfg.get("nation", GameSettings.enemy_nation))
	bm.player_team = RTSConfig.Team.BLUE
	bm.enemy_team = RTSConfig.Team.RED
	bm.team_nations = {
		RTSConfig.Team.BLUE: p_nation,
		RTSConfig.Team.RED: e_nation,
	}
	# 战役固定阵营：玩家永远蓝方、敌国永远红方（不参与单机随机对调）
	var map = bm.get_node_or_null("Map")
	if map == null:
		push_error("CampaignDirector: 缺少 Map 节点")
		queue_free()
		return
	player_anchor = map.player_castle_pos
	enemy_anchor = map.enemy_castle_pos
	bm.player_castle_pos = player_anchor
	bm.enemy_castle_pos = enemy_anchor

	# 中立资源点：和普通对局一样按地图布点生成。
	# 但战役的主城/城墙是地图生成之后才摆的，资源点可能正好压在基地里，
	# 这里跳过双方出生点 14 米内的资源，保证开局建筑有地方落。
	for res in map.resource_positions:
		var rpos: Vector3 = res.pos
		if rpos.distance_to(player_anchor) < 14.0 or rpos.distance_to(enemy_anchor) < 14.0:
			continue
		bm.spawn_entity(EntityDatabase.get_config(int(res.type)), RTSConfig.Team.NEUTRAL, rpos)

	_setup_ai(enemy_cfg)
	_spawn_side(player_cfg, bm.player_team, player_anchor, true)
	_spawn_side(enemy_cfg, bm.enemy_team, enemy_anchor, false)
	_prebuild_attack_ai_defense(enemy_cfg)

	# 人口上限与起始资源由关卡指定（没有主城时按建筑算会是 0，必须走战役覆盖）
	bm.campaign_pop_caps = {
		bm.player_team: int(player_cfg.get("pop_cap", 60)),
		bm.enemy_team: int(enemy_cfg.get("pop_cap", 60)),
	}
	bm.update_population_limits()
	_apply_resources(bm.player_resources, player_cfg.get("resources", {}))
	_apply_resources(bm.enemy_resources, enemy_cfg.get("resources", {}))
	_apply_campaign_research_setup()

	# 波次表（防守关：敌人没有城堡，只按时间点刷兵）
	_waves = enemy_cfg.get("waves", []).duplicate(true)
	_waves.sort_custom(func(a, b): return float(a.get("time", 0.0)) < float(b.get("time", 0.0)))
	_has_water_waves = false
	for w in _waves:
		if bool(w.get("water", false)):
			_has_water_waves = true
			break
	enemy_spawn_point = _pick_spawn_point()

	_parse_objectives()
	# 防守关不再让所有波次共用同一个边缘刷兵点：从地图隘口/敌方来路展开几条进攻路线，
	# 每波轮换入口；没有隘口的地图至少从敌方方向拉出左右两翼。
	_defense_wave_lanes = _build_defense_wave_lanes()
	if not _defense_wave_lanes.is_empty():
		enemy_spawn_point = _defense_wave_lanes[0]
	_spawn_escort()
	_deploy_objective_guards()
	if _has_water_waves:
		_enemy_water_spawn = _find_water_point(player_anchor, 22.0, 60.0)
	# 国家试炼：主城默认不生产特色兵，训练营在这里补上本关所选国家。
	if _is_training() and bm.has_method("_unlock_training_nation_units"):
		bm._unlock_training_nation_units()
	_create_hud()

	# 相机对准玩家出生点（没有主城时也要对准军队）
	var cam = bm.get_viewport().get_camera_3d()
	if cam != null:
		cam.global_position = Vector3(player_anchor.x, cam.global_position.y, player_anchor.z)

	_update_objective_states()
	_update_progress_text()
	_announce_start()
	_announce_objective_guards()
	set_process(true)

# 保留/移除静态 AI：波次关没有城堡，AI 没法发展，直接不启用
func _setup_ai(enemy_cfg: Dictionary) -> void:
	var ai = bm.get_node_or_null("AIController")
	if ai == null:
		return
	var want_ai: bool = bool(enemy_cfg.get("ai", false)) and bool(enemy_cfg.get("castle", false))
	if not want_ai:
		ai.queue_free()
		return
	ai.my_team = bm.enemy_team
	var nation: int = int(enemy_cfg.get("nation", -1))
	if nation >= 0:
		ai.nation = nation

# 进攻类关卡（摧毁主城/指定建筑）的 AI 基地开局就应是一座完整要塞：
# 用 AIDefense 的地形塔圈规划预置一圈外围城墙，并配箭塔、炮塔、墙顶炮台。
# 只对“玩家进攻、敌方有 AI 主城”的关卡生效，防守关/纯波次关不受影响。
func _prebuild_attack_ai_defense(enemy_cfg: Dictionary) -> void:
	if not bool(enemy_cfg.get("ai", false)) or enemy_castle == null:
		return
	if not is_instance_valid(enemy_castle) or not _is_attack_objective_level():
		return
	var ai = bm.get_node_or_null("AIController")
	if ai == null or not ai.has_method("prebuild_campaign_defense"):
		return
	ai.prebuild_campaign_defense(enemy_castle, player_anchor - enemy_anchor)

func _is_attack_objective_level() -> bool:
	for o in level.get("objectives", []):
		var t: String = String(o.get("type", ""))
		if t == "destroy_castle" or t == "destroy_targets" or t == "destroy_buildings":
			return true
	return false

# 生成一方的开局：主城 / 城墙 / 建筑 / 军队
func _spawn_side(cfg: Dictionary, team: int, anchor: Vector3, is_player: bool) -> void:
	var castle = null
	if bool(cfg.get("castle", true)):
		castle = _spawn_castle(anchor, team)
		if is_player:
			player_castle = castle
		else:
			enemy_castle = castle
		if castle != null:
			# 训练营用 castle_level 让不同关卡从合适的经典科技阶段开始。
			# 国家加成可能给更高初始等级，这里取二者较大值。
			var want_lv: int = int(cfg.get("castle_level", 0))
			if want_lv > int(castle.upgrade_level):
				castle.upgrade_level = clampi(want_lv, 1, 5)
				castle.level = castle.upgrade_level
				if castle.has_method("_sync_production_unlocks"):
					castle._sync_production_unlocks()
			castle.died.connect(_on_castle_died.bind(is_player))
	# 城墙线段
	for line in cfg.get("walls", []):
		_spawn_wall_line(team, anchor, line)
	# 单点建筑（塔 / 兵营 / 民居）
	for b in cfg.get("buildings", []):
		var off: Array = b.get("offset", [0.0, 0.0])
		var want := Vector3(anchor.x + float(off[0]), 0.0, anchor.z + float(off[1]))
		# 关卡里给的坐标是理想位置：被山/水/资源占了就就近挪几米，不能直接不生成，
		# 否则"拆 4 座塔"这类目标会因为塔没生成而永远完不成
		var pos := _find_spot_near(want, 8.0, 1.9)
		if pos == Vector3.ZERO:
			continue
		bm.spawn_entity(EntityDatabase.get_config(int(b.get("id", 25))), team, pos, int(b.get("level", 1)))
	# 开局军队
	var units: Array = cfg.get("units", [])
	for u in units:
		var count: int = int(u.get("count", 1))
		var unit_id: int = int(u.get("id", 11))
		for i in range(count):
			var pos := _unit_slot(anchor, i, count)
			if pos == Vector3.ZERO:
				continue
			var unit = bm.spawn_entity(EntityDatabase.get_config(unit_id), team, pos, int(u.get("level", 1)))
			if team == bm.enemy_team:
				_hook_enemy_kill(unit, unit_id)
	# 开局海军：船只能在水面，单独走水域布点（海战关）
	for n in cfg.get("navy", []):
		var ncount: int = int(n.get("count", 1))
		var nid: int = int(n.get("id", 13))
		for i in range(ncount):
			var npos := _find_water_point(anchor, 10.0, 46.0)
			if npos == Vector3.ZERO:
				continue
			if i > 0:
				var a: float = TAU * float(i) / float(maxi(ncount, 1))
				npos = _find_water_point(Vector3(npos.x + cos(a) * 6.0, 0.0, npos.z + sin(a) * 6.0), 1.0, 12.0)
			var ship = bm.spawn_entity(EntityDatabase.get_config(nid), team, npos, int(n.get("level", 1)))
			if team == bm.enemy_team:
				_hook_enemy_kill(ship, nid)

func _spawn_castle(anchor: Vector3, team: int) -> Building:
	var cfg = EntityDatabase.get_config(20)
	var castle = bm.spawn_entity(cfg, team, anchor, 1)
	if castle == null:
		return null
	# 国家加成的主城初始等级（中国等国家开局 2 级）
	var nation: int = int(bm.team_nations.get(team, -1))
	if nation >= 0:
		var start_lv: int = NationBonuses.get_castle_start_level(nation)
		castle.upgrade_level = start_lv
		castle.level = start_lv
	return castle

# 城墙线段：按墙体间距（body_radius*2）铺满，被山/水/建筑占的格跳过
func _spawn_wall_line(team: int, anchor: Vector3, line: Dictionary) -> void:
	var f: Array = line.get("from", [0.0, 0.0])
	var t: Array = line.get("to", [0.0, 0.0])
	var a := Vector3(anchor.x + float(f[0]), 0.0, anchor.z + float(f[1]))
	var b := Vector3(anchor.x + float(t[0]), 0.0, anchor.z + float(t[1]))
	var delta := Vector3(b.x - a.x, 0.0, b.z - a.z)
	var length: float = delta.length()
	if length < 0.5:
		return
	var wall_cfg = EntityDatabase.get_config(27)
	var step: float = maxf(2.0, float(wall_cfg.get("body_radius", 1.0)) * 2.0)
	var count: int = int(ceil(length / step))
	for i in range(count + 1):
		var k: float = float(i) / float(count)
		var pos := Vector3(a.x + delta.x * k, 0.0, a.z + delta.z * k)
		if not _is_plain(pos):
			continue
		if _too_close(pos, 1.2):
			continue
		bm.spawn_entity(EntityDatabase.get_config(27), team, pos, 1)

# 军队排成几圈，放在出生点周围的空地上
func _unit_slot(anchor: Vector3, index: int, total: int) -> Vector3:
	var ring: int = index / 12
	var per_ring: int = mini(total - ring * 12, 12)
	var i_in_ring: int = index % 12
	var radius: float = 3.2 + float(ring) * 2.4
	var angle: float = TAU * (float(i_in_ring) / float(maxi(per_ring, 1))) + float(ring) * 0.31
	# 最多试 8 个角度，找一个平地且不压单位的点
	for attempt in range(8):
		var a: float = angle + float(attempt) * 0.26
		var pos := Vector3(anchor.x + cos(a) * radius, 0.0, anchor.z + sin(a) * radius)
		if _is_plain(pos) and not _too_close(pos, 0.9):
			return pos
	# 实在没空位：放宽到只要求平地，宁可挤一点也不能让开局军队缺席
	for attempt in range(12):
		var a2: float = angle + float(attempt) * 0.52
		var pos2 := Vector3(anchor.x + cos(a2) * radius, 0.0, anchor.z + sin(a2) * radius)
		if _is_plain(pos2):
			return pos2
	return Vector3.ZERO

# 波次刷兵点：从玩家出生点朝敌方营地方向拉开一段距离，保证在地图内、可走平地。
# 旧实现用的是“玩家 - 敌方”方向，实际会把兵刷到玩家背后的地图边缘；
# 这里改为朝敌方一侧，并避开地图外和已有实体。
func _pick_spawn_point() -> Vector3:
	var dir := Vector3(enemy_anchor.x - player_anchor.x, 0.0, enemy_anchor.z - player_anchor.z)
	if dir.length() < 1.0:
		dir = Vector3(0.0, 0.0, 1.0)
	dir = dir.normalized()
	var base_angle: float = atan2(dir.z, dir.x)
	for dist in [44.0, 38.0, 32.0, 26.0, 50.0]:
		for da in [0.0, 0.35, -0.35, 0.7, -0.7, 1.1, -1.1]:
			var pos := Vector3(
				player_anchor.x + cos(base_angle + float(da)) * float(dist),
				0.0,
				player_anchor.z + sin(base_angle + float(da)) * float(dist)
			)
			if _is_inside_spawn_map(pos) and _is_plain(pos) and not _too_close(pos, 2.0):
				return pos
	# 兜底：沿敌方方向缩到 24 米，并夹到地图内，宁可靠近也不能刷到图外
	for dist in [24.0, 20.0, 28.0, 16.0]:
		for da in [0.0, 0.5, -0.5, 1.0, -1.0]:
			var pos := Vector3(
				player_anchor.x + cos(base_angle + float(da)) * float(dist), 0.0,
				player_anchor.z + sin(base_angle + float(da)) * float(dist))
			if _is_inside_spawn_map(pos) and _is_plain(pos):
				return pos
	var fallback := Vector3(player_anchor.x + dir.x * 16.0, 0.0,
		player_anchor.z + dir.z * 16.0)
	var half := _map_half_extent()
	fallback.x = clampf(fallback.x, -half + 6.0, half - 6.0)
	fallback.z = clampf(fallback.z, -half + 6.0, half - 6.0)
	return fallback

func _map_half_extent() -> float:
	var map = bm.get_node_or_null("Map")
	if map != null and map.terrain_grid.size() > 0:
		return float(map.terrain_grid.size()) * 0.5
	return float(RTSConfig.MAP_SIZE) * 0.5

func _is_inside_spawn_map(pos: Vector3, margin: float = 6.0) -> bool:
	var half := _map_half_extent()
	return absf(pos.x) <= half - margin and absf(pos.z) <= half - margin

# 防守关：只有“无敌方主城 + 纯防守目标”的波次关才启用地形多路入场。
func _is_defense_wave_level() -> bool:
	var enemy_cfg: Dictionary = level.get("enemy", {})
	if bool(enemy_cfg.get("castle", true)):
		return false
	for obj in level.get("objectives", []):
		var t := String(obj.get("type", ""))
		if t == "survive" or t == "defend_targets" or t == "endless":
			return true
	return false

# 候选入口：在玩家外围、地图内、平地，且没有压住现有实体。
func _is_valid_wave_lane(pos: Vector3, center: Vector3) -> bool:
	if not _is_inside_spawn_map(pos):
		return false
	if not _is_plain(pos):
		return false
	var dist: float = Vector2(pos.x - center.x, pos.z - center.z).length()
	if dist < 24.0 or dist > 72.0:
		return false
	return not _too_close(pos, 2.5)

func _append_wave_lane(lanes: Array, pos: Vector3) -> void:
	if pos == Vector3.ZERO:
		return
	var flat := Vector3(pos.x, 0.0, pos.z)
	for p in lanes:
		if flat.distance_to(Vector3(p.x, 0.0, p.z)) < 10.0:
			return
	lanes.append(flat)

# 波次入口按波次轮换：同一关的敌军可以走不同隘口/侧翼，而不是永远压在同一条边线。
func _wave_entry_point(number: int) -> Vector3:
	if _defense_wave_lanes.is_empty():
		return enemy_spawn_point
	var idx: int = int(posmod(number - 1, _defense_wave_lanes.size()))
	return _defense_wave_lanes[idx]

# 一路主攻 + 一路侧翼：同一波拆成两股，比整波只走一条线更像真实围攻；
# 波次轮换主攻方向，避免每波都从同一个入口压过来。
func _wave_centers(number: int) -> Array:
	if _defense_wave_lanes.is_empty():
		return [enemy_spawn_point]
	if _defense_wave_lanes.size() == 1:
		return [_defense_wave_lanes[0]]
	var size: int = _defense_wave_lanes.size()
	var primary: int = int(posmod(number - 1, size))
	var offset: int = int(ceil(float(size) / 2.0))
	var secondary: int = (primary + offset) % size
	return [_defense_wave_lanes[primary], _defense_wave_lanes[secondary]]

# 战役波次等级：固定波次表默认按波次递增（第 1 波 1 级、第 5 波 5 级封顶），
# 防守类关卡放慢到每两波升 1 级（第 1~2 波 1 级、第 3~4 波 2 级，依此类推）；
# 关卡可在单波里用 level 字段覆盖；无尽模式沿用 _endless_wave_data 自带的成长曲线。
func _wave_army_level(wave: Dictionary, unit: Dictionary, number: int) -> int:
	var base: int = clampi(int(unit.get("level", 1)), 1, 5)
	var forced: int = int(wave.get("level", 0))
	if forced > 0:
		return clampi(maxi(base, forced), 1, 5)
	if _endless_on:
		return base
	if _is_defense_wave_level():
		return clampi(maxi(base, 1 + (number - 1) / 2), 1, 5)
	return clampi(maxi(base, number), 1, 5)

# 隘口通常只有几格宽：沿“玩家→隘口”的径向偏移很容易直接顶到山壁，
# 因此在隘口周围再找一圈仍在通道里的平地，优先取靠敌方一侧的点。
func _find_pass_wave_lane(pass_pos: Vector3, center: Vector3) -> Vector3:
	var delta := Vector3(pass_pos.x - center.x, 0.0, pass_pos.z - center.z)
	if delta.length() < 8.0:
		return Vector3.ZERO
	var outward := delta.normalized()
	for extra in [8.0, 14.0, 4.0, 0.0]:
		var pos := pass_pos + outward * float(extra)
		if _is_valid_wave_lane(pos, center):
			return pos
	var pass_dist: float = delta.length()
	for radius in [3.0, 5.0, 7.0, 9.0]:
		for i in range(8):
			var a := TAU * float(i) / 8.0
			var pos := pass_pos + Vector3(cos(a), 0.0, sin(a)) * float(radius)
			if not _is_valid_wave_lane(pos, center):
				continue
			# 优先刷在隘口外侧（离玩家更远），这样部队会穿过隘口再进攻。
			if Vector2(pos.x - center.x, pos.z - center.z).length() >= pass_dist:
				return pos
	# 通道太窄时退而求其次，允许选靠近玩家一侧的通道口，至少保证这一路存在。
	for radius in [3.0, 5.0]:
		for i in range(8):
			var a := TAU * float(i) / 8.0
			var pos := pass_pos + Vector3(cos(a), 0.0, sin(a)) * float(radius)
			if _is_valid_wave_lane(pos, center):
				return pos
	return Vector3.ZERO

# 防守关生成多路进攻入口：优先用地图隘口，其次从敌方方向展开正面+左右两翼。
func _build_defense_wave_lanes() -> Array:
	var lanes: Array = []
	if not _is_defense_wave_level():
		return lanes
	var center: Vector3 = _player_target_position()
	var map = bm.get_node_or_null("Map")
	var raw_passes: Array = []
	if map != null:
		var raw = map.get("_pass_centers")
		if raw is Array:
			raw_passes = raw
	# 先用地形隘口：刷在隘口靠敌方一侧，让部队必须穿过隘口才能到玩家面前。
	for pc in raw_passes:
		if not (pc is Vector2i):
			continue
		var pass_pos: Vector3 = map.grid_to_world(pc.x, pc.y)
		var lane := _find_pass_wave_lane(pass_pos, center)
		if lane != Vector3.ZERO:
			_append_wave_lane(lanes, lane)
	# 隘口太少（或这张图没有隘口）时，从敌方方向展开扇形：
	# 普通防守关至少三路（正面主攻 + 侧翼），第10关这类双隘口地图也有侧翼突袭；
	# 无尽挑战要求“四面八方”，补到四路。
	var min_lanes: int = 4 if _endless_on else 3
	if lanes.size() < min_lanes:
		var base := Vector3(enemy_anchor.x - center.x, 0.0, enemy_anchor.z - center.z)
		if base.length() < 1.0:
			base = Vector3(0.0, 0.0, 1.0)
		var base_angle: float = atan2(base.z, base.x)
		for da in [0.0, 0.55, -0.55, 1.05, -1.05, 1.5, -1.5]:
			for dist in [42.0, 36.0, 30.0, 48.0, 26.0]:
				var pos := Vector3(
					center.x + cos(base_angle + float(da)) * float(dist), 0.0,
					center.z + sin(base_angle + float(da)) * float(dist))
				if _is_valid_wave_lane(pos, center):
					_append_wave_lane(lanes, pos)
					break
	if lanes.is_empty():
		if enemy_spawn_point != Vector3.ZERO:
			_append_wave_lane(lanes, enemy_spawn_point)
		if lanes.is_empty():
			lanes.append(_pick_spawn_point())
	# 最多保留 4 条主攻路线，太多会让“敌军来了”失去方向感。
	if lanes.size() > 4:
		lanes = lanes.slice(0, 4)
	return lanes

# ==================== 任务解析 ====================

func _parse_objectives() -> void:
	_time_limit = float(level.get("time_limit", 0.0))
	_three_star_time = float(level.get("stars", {}).get("three", 0.0))
	_three_star_warned = false
	var fail_flags: Array = level.get("fail", [])
	_has_army_wiped_fail = fail_flags.has("army_wiped")
	_has_castle_lost_fail = fail_flags.has("castle_lost")
	_has_timeout_fail = fail_flags.has("timeout")
	objective_states.clear()
	# 先把所有目标参数清零：没有 hold_zone 的关卡不能带着上一关/默认值继续算计时，
	# 否则会在地图原点凭空出现"控制区"（还会刷出控制区警告）。
	_zone_radius = 0.0
	_zone_hold_need = 0.0
	_zone_center = Vector3.ZERO
	_zone_state_text = ""
	_escort_unit_id = 0
	_kill_need = 0
	_kill_ids.clear()
	_kill_intercept_dist = 0.0
	_kill_max_slip = 0
	_kill_slipped = 0
	_target_ids.clear()
	_target_need = 0
	_target_initial = 0
	_gather_need = 0.0
	_multi_zones.clear()
	_defend_ids.clear()
	_defend_buildings.clear()
	_defend_min_alive = 1
	_defend_initial = 0
	_defend_alive = 0
	_defend_duration = 0.0
	_ai_zone_timer = 0.0
	_ai_zone_waves = 0
	_ai_escort_points.clear()
	_ai_escort_flags.clear()
	_endless_on = false
	_endless_first = 20.0
	_endless_interval = 30.0
	_endless_waves = 0
	_endless_timer = 0.0
	_endless_score = 0
	for o in level.get("objectives", []):
		var obj: Dictionary = o
		var t := String(obj.get("type", ""))
		objective_states.append({"label": String(obj.get("label", "")), "done": false})
		match t:
			"survive":
				_survive_need = float(obj.get("duration", 300.0))
			"destroy_castle":
				_destroy_castle_goal = true
			"hold_zone":
				var zone: Dictionary = obj.get("zone", {})
				_zone_hold_need = float(obj.get("hold", 120.0))
				_zone_radius = float(zone.get("radius", 12.0))
				var off: Array = zone.get("offset", [0.0, 0.0])
				_zone_center = _map_center_offset(off, _zone_radius)
				_mark_hold_zone(_zone_center, _zone_radius)
			"escort":
				_escort_unit_id = int(obj.get("unit_id", 19))
				var ezone: Dictionary = obj.get("zone", {})
				_escort_zone_radius = float(ezone.get("radius", 8.0))
				var eoff: Array = ezone.get("offset", [0.0, 0.0])
				_escort_zone_center = _map_center_offset(eoff, _escort_zone_radius)
				var blue := Color(0.35, 0.7, 1.0)
				_add_ground_mesh(_make_ground_disc(_escort_zone_center, _escort_zone_radius, 0.45),
					_escort_zone_center, Color(blue, 0.14), "CampaignEscortDisc")
				_escort_mesh = _add_ground_mesh(
					_make_ground_band(_escort_zone_center, maxf(_escort_zone_radius - 0.8, 0.6),
						_escort_zone_radius + 0.8, 0.6),
					_escort_zone_center, Color(blue, 0.95), "CampaignEscortRing")
				_ensure_screen_layer()
				_escort_screen_label = _make_screen_label()
				var escort_label := Label3D.new()
				escort_label.name = "CampaignEscortLabel"
				escort_label.text = "护送点"
				escort_label.font_size = 64
				escort_label.pixel_size = 0.03
				escort_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
				escort_label.no_depth_test = true
				escort_label.modulate = Color(0.55, 0.8, 1.0)
				escort_label.outline_modulate = Color(0.0, 0.0, 0.0, 0.95)
				escort_label.outline_size = 14
				bm.add_child(escort_label)
				escort_label.global_position = Vector3(_escort_zone_center.x,
					float(_escort_zone_center.y) + 9.0, _escort_zone_center.z)
				_ping_minimap(_escort_zone_center)
			"hold_zones":
				var zbase := _zone_group_base()
				var zlist: Array = obj.get("zones", [])
				for zi in range(zlist.size()):
					var zc: Dictionary = zlist[zi]
					var zr: float = float(zc.get("radius", 6.5))
					var zoff: Array = zc.get("offset", [0.0, 0.0])
					var zwant := Vector3(zbase.x + float(zoff[0]), 0.0, zbase.z + float(zoff[1]))
					var zpos := _find_plain_area(zwant, zr)
					var zcolor := Color(0.35, 0.95, 0.55) if zi == 0 else Color(1.0, 0.86, 0.35)
					_multi_zones.append(_build_multi_zone(zpos, zr,
						float(zc.get("hold", 60.0)), String(zc.get("name", "区 %d" % (zi + 1))), zcolor))
			"defend_targets":
				for bid in obj.get("building_ids", [22]):
					_defend_ids.append(int(bid))
				_defend_min_alive = int(obj.get("min_alive", 1))
				_defend_duration = float(obj.get("duration", 300.0))
				# 只把开局由关卡摆放的目标建筑记成“真正的粮仓”。
				# 玩家后续自己补建的同 ID 建筑不能顶上，否则粮仓全毁后还能靠新建续命。
				_defend_buildings = _collect_defend_buildings(_defend_ids)
				_defend_initial = _defend_buildings.size()
			"destroy_targets":
				_target_ids = obj.get("building_ids", [25, 26]).duplicate()
				_target_need = int(obj.get("count", 3))
				_target_initial = _count_enemy_buildings(_target_ids)
			"gather":
				_gather_need = float(obj.get("amount", 1500.0))
			"endless":
				_endless_on = true
				_endless_first = float(obj.get("first_wave", 20.0))
				_endless_interval = float(obj.get("interval", 30.0))
				_endless_timer = _endless_first
			"kill_units":
				_kill_need = int(obj.get("count", 10))
				_kill_ids = obj.get("unit_ids", []).duplicate()
				_kill_intercept_dist = float(obj.get("intercept_dist", 0.0))
				_kill_max_slip = int(obj.get("max_slip", 0))

# 在地图中间找一块足够大的平地放控制区（中心点被水/山占时向外搜）
func _find_plain_area(center: Vector3, radius: float) -> Vector3:
	var map = bm.get_node_or_null("Map")
	var half: float = float(RTSConfig.MAP_SIZE) * 0.5
	if map != null and map.terrain_grid.size() > 0:
		half = float(map.terrain_grid.size()) * 0.5
	# 从目标点开始一圈圈往外找，优先用最近的点；占领区只需要"大部分是平地"，
	# 不能要求整圈都是平地，否则桥头/绿洲这种地形会把它挤到几十米外的岸上
	for ring in range(0, 21):
		var step: float = float(ring) * 2.0
		for i in range(16):
			var da: float = TAU * float(i) / 16.0
			var pos := Vector3(center.x + cos(float(da)) * step, 0.0, center.z + sin(float(da)) * step)
			if absf(pos.x) > half - radius - 4.0 or absf(pos.z) > half - radius - 4.0:
				continue
			if _area_is_plain_loose(pos, radius):
				if map != null and map.has_method("get_height_at"):
					pos.y = float(map.get_height_at(pos))
				return pos
	if map != null and map.has_method("get_height_at"):
		center.y = float(map.get_height_at(center))
	return center

# 占领区判定：中心必须是平地，圈内 60%/100% 半径上至少 75% 的点是平地
func _area_is_plain_loose(center: Vector3, radius: float) -> bool:
	if not _is_plain(center):
		return false
	var plain := 0
	var total := 0
	for scale in [0.6, 1.0]:
		for i in range(16):
			var a: float = TAU * float(i) / 16.0
			var p := Vector3(center.x + cos(a) * radius * float(scale), 0.0,
				center.z + sin(a) * radius * float(scale))
			total += 1
			if _is_plain(p):
				plain += 1
	return float(plain) / float(total) >= 0.75

func _area_is_plain(center: Vector3, radius: float) -> bool:
	if not _is_plain(center):
		return false
	for i in range(12):
		var a: float = TAU * float(i) / 12.0
		var p := Vector3(center.x + cos(a) * radius, 0.0, center.z + sin(a) * radius)
		if not _is_plain(p):
			return false
	return true

# 地图中心 + 偏移（世界米）→ 找一块足够大的平地当目标区
func _map_center_offset(off: Array, radius: float) -> Vector3:
	var map = bm.get_node_or_null("Map")
	var center := Vector3.ZERO
	if map != null and map.terrain_grid.size() > 0:
		var size: int = int(map.terrain_grid.size())
		center = map.grid_to_world(int(size / 2), int(size / 2))
	# 偏移为 0 表示"抢中间"：用双方主城连线的中点当地图中心，
	# 不能直接用地形中心——地形中心有时正好压在某一方基地里，那一方开局白赚计时。
	if absf(float(off[0])) < 0.01 and absf(float(off[1])) < 0.01:
		if player_anchor != Vector3.ZERO and enemy_anchor != Vector3.ZERO \
				and player_anchor.distance_to(enemy_anchor) > 8.0:
			return _find_balanced_area(radius)
	return _find_plain_area(Vector3(center.x + float(off[0]), 0.0, center.z + float(off[1])), radius)

# 在双方基地连线中点附近找一块平地当争夺区，优先取"两边跑过来差不多远"的点，
# 避免因为地形把圈挤到某一方门口（那样另一方开局就吃亏）。
func _find_balanced_area(radius: float) -> Vector3:
	var mid: Vector3 = player_anchor.lerp(enemy_anchor, 0.5)
	var best := Vector3.ZERO
	var found := false
	var best_score := -INF
	for ring in range(0, 11):
		var step: float = float(ring) * 4.0
		for i in range(16):
			var a: float = TAU * float(i) / 16.0
			var pos := Vector3(mid.x + cos(a) * step, 0.0, mid.z + sin(a) * step)
			if not _area_is_plain_loose(pos, radius):
				continue
			# 两边距离差越小越好，同时不能为了"一样远"把圈甩到地图角落：
			# 离中点每远 1 米扣 0.6 分，距离差每 1 米扣 1 分
			var score: float = -absf(player_anchor.distance_to(pos) - enemy_anchor.distance_to(pos))
			score -= step * 0.6
			if not found or score > best_score:
				found = true
				best_score = score
				best = pos
	if found:
		var map = bm.get_node_or_null("Map")
		if map != null and map.has_method("get_height_at"):
			best.y = float(map.get_height_at(best))
		return best
	return _find_plain_area(mid, radius)

# 地面上画一个目标光圈（占领区绿色 / 护送点蓝色）
func _spawn_ring(center: Vector3, radius: float, color: Color, ring_name: String) -> MeshInstance3D:
	if radius <= 0.0:
		return null
	var mesh := TorusMesh.new()
	mesh.inner_radius = maxf(radius - 0.45, 0.5)
	mesh.outer_radius = radius + 0.45
	mesh.rings = 48
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = mat
	var ring := MeshInstance3D.new()
	ring.name = ring_name
	ring.mesh = mesh
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bm.add_child(ring)
	var y: float = float(center.y) if center.y != 0.0 else 0.15
	ring.global_position = Vector3(center.x, y + 0.35, center.z)
	return ring

# ==================== 地面标记（贴着地形画）====================

func _ground_y_at(x: float, z: float) -> float:
	var map = bm.get_node_or_null("Map")
	if map != null and map.has_method("get_height_at"):
		return float(map.get_height_at(Vector3(x, 0.0, z)))
	return 0.0

# 平铺在起伏地形上的扇形色块（逐顶点采地形高度，不会被山包/沙丘埋掉）
func _make_ground_disc(center: Vector3, radius: float, y_off: float, segments: int = 48) -> ArrayMesh:
	var base_y: float = _ground_y_at(center.x, center.z)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var c := Vector3(0.0, y_off, 0.0)
	for i in range(segments):
		var a0: float = TAU * float(i) / float(segments)
		var a1: float = TAU * float(i + 1) / float(segments)
		var x0: float = center.x + cos(a0) * radius
		var z0: float = center.z + sin(a0) * radius
		var x1: float = center.x + cos(a1) * radius
		var z1: float = center.z + sin(a1) * radius
		var p0 := Vector3(cos(a0) * radius, _ground_y_at(x0, z0) - base_y + y_off, sin(a0) * radius)
		var p1 := Vector3(cos(a1) * radius, _ground_y_at(x1, z1) - base_y + y_off, sin(a1) * radius)
		for v in [c, p0, p1]:
			st.set_normal(Vector3.UP)
			st.add_vertex(v)
	return st.commit()

# 贴着地形的一圈色带（相当于"粗光圈"）
func _make_ground_band(center: Vector3, inner_r: float, outer_r: float, y_off: float,
		segments: int = 64) -> ArrayMesh:
	var base_y: float = _ground_y_at(center.x, center.z)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(segments):
		var a0: float = TAU * float(i) / float(segments)
		var a1: float = TAU * float(i + 1) / float(segments)
		var i0 := _band_vertex(center, base_y, a0, inner_r, y_off)
		var o0 := _band_vertex(center, base_y, a0, outer_r, y_off)
		var i1 := _band_vertex(center, base_y, a1, inner_r, y_off)
		var o1 := _band_vertex(center, base_y, a1, outer_r, y_off)
		for v in [i0, o0, i1, o0, o1, i1]:
			st.set_normal(Vector3.UP)
			st.add_vertex(v)
	return st.commit()

func _band_vertex(center: Vector3, base_y: float, angle: float, r: float, y_off: float) -> Vector3:
	var x: float = center.x + cos(angle) * r
	var z: float = center.z + sin(angle) * r
	return Vector3(cos(angle) * r, _ground_y_at(x, z) - base_y + y_off, sin(angle) * r)

func _ground_mat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_receive_shadows = true
	return mat

func _add_ground_mesh(mesh: Mesh, center: Vector3, color: Color, node_name: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.material_override = _ground_mat(color)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bm.add_child(mi)
	mi.global_position = Vector3(center.x, _ground_y_at(center.x, center.z), center.z)
	return mi

# ==================== 屏幕空间标记 ====================

func _ensure_screen_layer() -> void:
	if _screen_layer != null and is_instance_valid(_screen_layer):
		return
	_screen_layer = CanvasLayer.new()
	_screen_layer.name = "CampaignMarkers"
	_screen_layer.layer = 9
	bm.add_child(_screen_layer)

func _make_screen_label() -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", UILayout.font_dp(13.0))
	l.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
	l.add_theme_constant_override("outline_size", UILayout.font_dp(4.0))
	l.visible = false
	_screen_layer.add_child(l)
	return l

# 把 3D 坐标投影到屏幕，把标签钉在目标上方一点（俯视/斜视都看得见）
func _update_screen_marker(label: Label, world_pos: Vector3, text: String, color: Color,
		raise_px: float) -> void:
	if label == null or not is_instance_valid(label):
		return
	var cam := bm.get_viewport().get_camera_3d()
	if cam == null or cam.is_position_behind(world_pos):
		label.visible = false
		return
	var screen: Vector2 = cam.unproject_position(world_pos)
	var vp: Vector2 = bm.get_viewport().get_visible_rect().size
	label.text = text
	label.add_theme_color_override("font_color", color)
	label.visible = true
	label.reset_size()
	var sz: Vector2 = label.get_combined_minimum_size()
	# 目标不在画面里时把标签贴到屏幕边缘（不是只把中心点拉回来，否则会露半行字；
	# 也不能直接隐藏，否则玩家找不到控制区）
	var margin := UILayout.dp(20.0)
	var min_x: float = margin + sz.x * 0.5
	var max_x: float = maxf(vp.x - margin - sz.x * 0.5, min_x)
	var min_y: float = margin + sz.y + raise_px
	var max_y: float = maxf(vp.y - margin, min_y)
	var anchor_pos := Vector2(clampf(screen.x, min_x, max_x), clampf(screen.y, min_y, max_y))
	label.position = anchor_pos - Vector2(sz.x * 0.5, sz.y + raise_px)

# 占领区标记：贴地色块 + 贴地粗光圈 + 光柱 + 3D 悬浮字 + 屏幕空间倒计时。
# 只有一圈细线在野外地图上几乎看不见，所以这里做成"老远就能看到"的标记。
func _mark_hold_zone(center: Vector3, radius: float) -> void:
	var green := Color(0.3, 1.0, 0.45)
	var y: float = float(center.y)
	# 地面色块（贴地形，逐顶点采高度）
	_zone_disc = _add_ground_mesh(_make_ground_disc(center, radius, 0.45), center,
		Color(green, 0.16), "CampaignZoneDisc")
	# 贴地粗光圈
	_zone_mesh = _add_ground_mesh(_make_ground_band(center, maxf(radius - 0.8, 0.6),
		radius + 0.8, 0.6), center, Color(green, 0.95), "CampaignZoneRing")
	# 光柱：远处也能一眼看到位置
	_zone_pillar_mat = StandardMaterial3D.new()
	_zone_pillar_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_zone_pillar_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_zone_pillar_mat.albedo_color = Color(green, 0.12)
	_zone_pillar_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var pillar_mesh := CylinderMesh.new()
	pillar_mesh.top_radius = 1.0
	pillar_mesh.bottom_radius = 1.0
	pillar_mesh.height = 26.0
	pillar_mesh.radial_segments = 12
	pillar_mesh.material = _zone_pillar_mat
	_zone_pillar = MeshInstance3D.new()
	_zone_pillar.name = "CampaignZonePillar"
	_zone_pillar.mesh = pillar_mesh
	_zone_pillar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bm.add_child(_zone_pillar)
	_zone_pillar.global_position = Vector3(center.x, y + 13.0, center.z)
	# 头顶悬浮文字（倒计时）
	_zone_label = Label3D.new()
	_zone_label.name = "CampaignZoneLabel"
	_zone_label.font_size = 64
	_zone_label.pixel_size = 0.03
	_zone_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_zone_label.no_depth_test = true
	_zone_label.modulate = Color(0.55, 1.0, 0.65)
	_zone_label.outline_modulate = Color(0.0, 0.0, 0.0, 0.95)
	_zone_label.outline_size = 14
	_zone_label.text = "占领区 %d 秒" % int(_zone_hold_need)
	bm.add_child(_zone_label)
	_zone_label.global_position = Vector3(center.x, y + 13.0, center.z)
	# 屏幕空间倒计时：俯视时 3D 文字会被压扁到看不见，这层永远是正的
	_ensure_screen_layer()
	_zone_screen_label = _make_screen_label()
	_ping_minimap(center)

# 在小地图上闪一下标记点（复用 HUD 小地图的警报闪烁）
func _ping_minimap(pos: Vector3) -> void:
	var mm = bm.find_child("Minimap", true, false)
	if mm != null and mm.has_method("add_alert"):
		mm.add_alert(pos)

# ==================== 护送目标 ====================

# 生成被护送的信使：单独一个侦察兵，头顶挂一个显眼的蓝色标记
func _spawn_escort() -> void:
	if _escort_unit_id <= 0:
		return
	var pos := _unit_slot(player_anchor, 0, 1)
	if pos == Vector3.ZERO:
		pos = player_anchor
	var unit = bm.spawn_entity(EntityDatabase.get_config(_escort_unit_id), bm.player_team, pos, 1)
	if unit == null:
		return
	_escort_unit = unit
	unit.died.connect(_on_escort_died)
	var marker := Label3D.new()
	marker.text = "信使"
	marker.font_size = 48
	marker.pixel_size = 0.012
	marker.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	marker.no_depth_test = true
	marker.modulate = Color(0.45, 0.85, 1.0)
	marker.position = Vector3(0.0, 3.2, 0.0)
	unit.add_child(marker)
	bm._show_hud_alert("信使已出发：把他带到蓝色光圈", Color(0.45, 0.85, 1.0),
		[bm.player_team], bm.player_team, GameSettings.AlertKind.MISC, false,
		[bm.team_nations.get(bm.player_team, -1)], _escort_zone_center, -1)

func _on_escort_died() -> void:
	if state != State.RUNNING:
		return
	if _escort_unit_id > 0:
		_finish(false)
		return

# ==================== AI 争夺控制区 / 拦截护送 ====================
#
# 战役里的 AI 本来只按自己的三阶段逻辑打玩家主城，占领类关卡不会派人进圈，
# 护送类关卡也不会在半路拦截。这里按目标类型单独给敌人布置战场压力：
#   · hold_zone / hold_zones：开局在圈里放守军 + 圈边箭塔，之后定时派兵增援正在被抢的圈；
#   · escort：沿护送路线预埋两处伏兵 + 中点箭塔，信使推进到 20%/45%/70%/90% 时再两翼包抄。

func _deploy_objective_guards() -> void:
	_ai_zone_timer = AI_ZONE_FIRST_DELAY
	_ai_zone_waves = 0
	_ai_escort_points.clear()
	_ai_escort_flags.clear()
	# 单控制区：8 个守军 + 1 座箭塔
	if _zone_radius > 0.0 and _zone_hold_need > 0.0 and _zone_center != Vector3.ZERO:
		_guard_zone(_zone_center, _zone_radius, 6)
	# 多控制区：每个点都要有人守，玩家没法靠"占一个点"白嫖
	for z in _multi_zones:
		_guard_zone(z["center"], float(z["radius"]), 4)
	# 护送路线：预埋伏兵 + 卡路口箭塔
	if _escort_unit_id > 0:
		_setup_escort_ambush()
	for i in range(AI_ESCORT_TRIGGERS.size()):
		_ai_escort_flags.append(false)

# 某个控制区里敌我各有几个单位（增援判断用）
func _zone_unit_counts(center: Vector3, radius: float) -> Dictionary:
	var mine := 0
	var theirs := 0
	for e in bm.entities.get_children():
		if not (e is Army) or e.health <= 0:
			continue
		if e.global_position.distance_to(center) > radius:
			continue
		if int(e.team) == bm.player_team:
			mine += 1
		elif int(e.team) == bm.enemy_team:
			theirs += 1
	return {"mine": mine, "theirs": theirs}

# 在控制区里放一队守军：直接设驻扎点，挨打会迎战、追远了会自己回圈里，不会一路追到玩家主城
func _guard_zone(center: Vector3, radius: float, squad: int) -> void:
	# 箭塔放在圈外 5 米，既守圈又不挡圈内走位
	var tower_pos := _find_spot_near(Vector3(center.x, 0.0, center.z + radius + 5.0), 12.0, 4.0)
	if tower_pos == Vector3.ZERO:
		tower_pos = _find_spot_near(Vector3(center.x, 0.0, center.z - radius - 5.0), 12.0, 4.0)
	if tower_pos != Vector3.ZERO:
		bm.spawn_entity(EntityDatabase.get_config(25), bm.enemy_team, tower_pos, 1)
	for i in range(squad):
		var slot := _zone_slot(center, i, squad, radius)
		if slot == Vector3.ZERO:
			continue
		var uid: int = int(AI_GUARD_UNIT_IDS[i % AI_GUARD_UNIT_IDS.size()])
		var unit = bm.spawn_entity(EntityDatabase.get_config(uid), bm.enemy_team, slot, 1)
		if unit == null:
			continue
		_hook_enemy_kill(unit, uid)
		unit.garrison_point = center

# 圈内铺兵：中心附近两圈，避开占地实体
func _zone_slot(center: Vector3, index: int, total: int, radius: float) -> Vector3:
	var ring_radius: float = maxf(radius * 0.45, 2.0) + float(index / 6) * 2.2
	var angle: float = TAU * float(index % 6) / 6.0 + float(index / 6) * 0.5
	for attempt in range(8):
		var a: float = angle + float(attempt) * 0.4
		var p := Vector3(center.x + cos(a) * ring_radius, 0.0, center.z + sin(a) * ring_radius)
		if _is_plain(p) and not _too_close(p, 1.1):
			return p
	return Vector3.ZERO

# 护送路线伏击：1/3 与 2/3 处各埋一队，中点立箭塔卡住必经之路
func _setup_escort_ambush() -> void:
	var start := player_anchor
	var dir := Vector3(_escort_zone_center.x - start.x, 0.0, _escort_zone_center.z - start.z)
	if dir.length() < 5.0:
		return
	var side := Vector3(-dir.z, 0.0, dir.x).normalized()
	for frac in [0.34, 0.66]:
		var mid := start.lerp(_escort_zone_center, float(frac))
		var ambush := _find_spot_near(mid + side * 7.0, 12.0, 2.0)
		if ambush == Vector3.ZERO:
			ambush = _find_spot_near(mid, 12.0, 2.0)
		if ambush == Vector3.ZERO:
			continue
		_ai_escort_points.append(ambush)
		_spawn_ambushers(ambush, 4, true)
	var tower := _find_spot_near(start.lerp(_escort_zone_center, 0.5) - side * 9.0, 14.0, 4.0)
	if tower != Vector3.ZERO:
		bm.spawn_entity(EntityDatabase.get_config(25), bm.enemy_team, tower, 1)

# 一队伏兵：garrison=true 时原地埋伏，false 时由调用方下达攻击移动
func _spawn_ambushers(pos: Vector3, count: int, garrison: bool) -> Array:
	var spawned: Array = []
	for i in range(count):
		var slot := _zone_slot(pos, i, count, 4.0)
		if slot == Vector3.ZERO:
			continue
		var uid: int = int(AI_GUARD_UNIT_IDS[i % AI_GUARD_UNIT_IDS.size()])
		var unit = bm.spawn_entity(EntityDatabase.get_config(uid), bm.enemy_team, slot, 1)
		if unit == null:
			continue
		_hook_enemy_kill(unit, uid)
		spawned.append(unit)
		if garrison:
			unit.garrison_point = pos
	return spawned

# 每帧（0.15 秒节拍）推进：控制区增援 + 护送伏兵触发
func _update_objective_ai(dt: float) -> void:
	if _zone_radius > 0.0 and _zone_hold_need > 0.0:
		_tick_zone_reinforcement(dt)
	if _escort_unit_id > 0:
		_tick_escort_ambush()

func _tick_zone_reinforcement(dt: float) -> void:
	if _ai_zone_waves >= AI_ZONE_MAX_WAVES:
		return
	_ai_zone_timer -= dt
	if _ai_zone_timer > 0.0:
		return
	var center := _contested_zone_center()
	if center == Vector3.ZERO:
		return
	_ai_zone_timer = AI_ZONE_INTERVAL
	_ai_zone_waves += 1
	var from := enemy_spawn_point
	if enemy_castle != null and is_instance_valid(enemy_castle):
		from = enemy_castle.global_position
	var spawn_pos := _find_spot_near(Vector3(from.x, 0.0, from.z), 20.0, 2.0)
	if spawn_pos == Vector3.ZERO:
		spawn_pos = from
	var squad := _spawn_ambushers(spawn_pos, 5, false)
	for unit in squad:
		if is_instance_valid(unit) and unit.has_method("attack_move_to"):
			unit.attack_move_to(center)
			unit.garrison_point = center
	if not squad.is_empty():
		bm._show_hud_alert(
			"敌军增援正赶往控制区（第 %d 波）" % _ai_zone_waves,
			Color(1.0, 0.45, 0.25), [bm.enemy_team], bm.player_team,
			GameSettings.AlertKind.COMBAT, false,
			[bm.team_nations.get(bm.enemy_team, -1)], center, -1)

# 找出"需要增援"的圈：玩家在圈里、敌人还没到，或玩家人数压过守军
func _contested_zone_center() -> Vector3:
	if _zone_radius > 0.0 and _zone_hold_need > 0.0:
		if hold_seconds >= _zone_hold_need:
			return Vector3.ZERO
		var c := _zone_unit_counts(_zone_center, _zone_radius)
		if int(c["mine"]) > 0 and int(c["mine"]) > int(c["theirs"]):
			return _zone_center
		return Vector3.ZERO
	for z in _multi_zones:
		if bool(z.get("done", false)):
			continue
		var center: Vector3 = z["center"]
		var counts := _zone_unit_counts(center, float(z["radius"]))
		if int(counts["mine"]) > int(counts["theirs"]):
			return center
	return Vector3.ZERO

# 信使推进到路线相应比例时触发两翼伏兵
func _tick_escort_ambush() -> void:
	if _ai_escort_flags.is_empty():
		return
	if _escort_unit == null or not is_instance_valid(_escort_unit) or _escort_unit.health <= 0:
		return
	if state != State.RUNNING:
		return
	var total: float = player_anchor.distance_to(_escort_zone_center)
	if total < 5.0:
		return
	var progress: float = clampf(
		1.0 - _escort_unit.global_position.distance_to(_escort_zone_center) / total, 0.0, 1.0)
	for i in range(AI_ESCORT_TRIGGERS.size()):
		if bool(_ai_escort_flags[i]):
			continue
		if progress < float(AI_ESCORT_TRIGGERS[i]):
			continue
		_ai_escort_flags[i] = true
		_trigger_escort_intercept(i)

func _trigger_escort_intercept(index: int) -> void:
	if _escort_unit == null or not is_instance_valid(_escort_unit):
		return
	var escort_pos: Vector3 = _escort_unit.global_position
	var dir := Vector3(_escort_zone_center.x - escort_pos.x, 0.0, _escort_zone_center.z - escort_pos.z)
	if dir.length() < 1.0:
		dir = Vector3(0.0, 0.0, 1.0)
	dir = dir.normalized()
	var side := Vector3(-dir.z, 0.0, dir.x)
	var base: Vector3 = escort_pos + dir * 18.0
	var spawned_total := 0
	for side_i in range(2):
		var group := _find_spot_near(base + side * (7.0 if side_i == 0 else -7.0), 10.0, 2.0)
		if group == Vector3.ZERO:
			continue
		var squad := _spawn_ambushers(group, 2, false)
		for unit in squad:
			if is_instance_valid(unit) and unit.has_method("attack_move_to"):
				unit.attack_move_to(escort_pos)
		spawned_total += squad.size()
	if spawned_total > 0:
		bm._show_hud_alert(
			"伏兵从两翼杀出，保护信使！（第 %d 档）" % (index + 1),
			Color(1.0, 0.35, 0.2), [bm.enemy_team], bm.player_team,
			GameSettings.AlertKind.COMBAT, false,
			[bm.team_nations.get(bm.enemy_team, -1)], escort_pos, -1)

# 开局播报：告诉玩家敌人已经在目标点布防，别以为跑过去就能白拿
func _announce_objective_guards() -> void:
	var text := ""
	if _zone_radius > 0.0 and _zone_hold_need > 0.0:
		text = "敌军已抢先占据控制区并架起箭塔，带兵把他们赶出去"
	elif not _multi_zones.is_empty():
		text = "每处控制区都有敌军守军和箭塔，逐个拔掉"
	elif _escort_unit_id > 0:
		text = "护送路线两侧有敌军伏兵，路上还会不断有拦截部队"
	if text.is_empty():
		return
	bm._show_hud_alert(text, Color(1.0, 0.55, 0.3), [bm.player_team], bm.player_team,
		GameSettings.AlertKind.MISC, false, [bm.team_nations.get(bm.player_team, -1)],
		player_anchor, -1)

# 统计敌方指定建筑还活着几座（拆塔类目标的基线）
func _count_enemy_buildings(ids: Array) -> int:
	var n := 0
	for e in bm.entities.get_children():
		if e is Building and e.health > 0 and int(e.team) == bm.enemy_team and int(e.entity_id) in ids:
			n += 1
	return n

# ==================== 击杀统计 ====================

# 给敌方单位挂死亡回调，用于"击沉/歼灭 N 个"类目标
func _hook_enemy_kill(unit, unit_id: int) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	if not unit.died.is_connected(_on_enemy_unit_died):
		unit.died.connect(_on_enemy_unit_died.bind(unit, unit_id))

func _on_enemy_unit_died(unit, unit_id: int) -> void:
	# 海战关的"拦截"判定：火船靠岸自爆不算击沉（算漏过），
	# 否则玩家什么都不做、等它们撞岸也能凑够击杀数。
	if _kill_intercept_dist > 0.0 and is_instance_valid(unit) and player_castle != null 			and is_instance_valid(player_castle):
		var dist: float = unit.global_position.distance_to(player_castle.global_position)
		if dist < _kill_intercept_dist:
			_kill_slipped += 1
			return
	_enemy_kills += 1
	_enemy_kills_by_id[unit_id] = int(_enemy_kills_by_id.get(unit_id, 0)) + 1

# ==================== 采集统计 ====================

# 累计玩家"新增"的资源量：每帧对比资源总额，只累加正增量（花掉的不倒扣）
func _update_economy() -> void:
	var total := 0.0
	for k in bm.player_resources:
		total += float(bm.player_resources[k])
	if _gather_last_total < 0.0:
		_gather_last_total = total
		return
	var delta: float = total - _gather_last_total
	if delta > 0.0:
		_gather_total += delta
	_gather_last_total = total

# ==================== 水域刷兵（海战关）====================

func _is_water(pos: Vector3) -> bool:
	return bm.get_terrain_at(pos) == 2

# 在出生点周围找一片水面（由近到远、多角度试）
func _find_water_point(center: Vector3, min_dist: float, max_dist: float) -> Vector3:
	var dist: float = min_dist
	while dist <= max_dist:
		for i in range(16):
			var a: float = TAU * float(i) / 16.0
			var pos := Vector3(center.x + cos(a) * dist, 0.0, center.z + sin(a) * dist)
			if _is_water(pos):
				return pos
		dist += 4.0
	return Vector3(center.x, 0.0, center.z + max_dist)

# ==================== 无尽波次（endless）====================

# 到点刷下一波：数量/等级随波数上涨，每 10 波来一个首领
func _update_endless(dt: float) -> void:
	if not _endless_on:
		return
	_endless_score = _endless_waves * 100 + int(elapsed)
	_endless_timer -= dt
	if _endless_timer > 0.0:
		return
	_endless_waves += 1
	_endless_timer = _endless_interval
	_fire_wave(_endless_wave_data(_endless_waves), _endless_waves)

func _endless_wave_data(w: int) -> Dictionary:
	var lv: int = clampi(1 + w / 4, 1, 5)
	var units: Array = [
		{"id": 11, "count": mini(4 + w * 2, 26), "level": lv},
		{"id": 12, "count": mini(2 + w, 14), "level": lv},
	]
	if w >= 3:
		units.append({"id": 15, "count": mini(1 + w / 3, 10), "level": lv})
	if w >= 5:
		units.append({"id": 18, "count": mini(1 + w / 6, 6), "level": lv})
	if w >= 7:
		units.append({"id": 16, "count": mini(1 + w / 8, 5), "level": lv})
	if w % 10 == 0:
		units.append({"id": 49, "count": 1, "level": 5})
	return {"units": units, "label": "第 %d 波" % w}

# 无尽挑战没有"胜利"，按坚持的波数给星
func _endless_stars() -> int:
	if _endless_waves >= 15:
		return 3
	if _endless_waves >= 10:
		return 2
	if _endless_waves >= 5:
		return 1
	return 0

# ==================== 每帧推进 ====================

func _process(delta: float) -> void:
	if state != State.RUNNING:
		return
	elapsed += delta
	_update_waves()
	_tick += delta
	if _tick < 0.15:
		return
	var dt: float = _tick
	_tick = 0.0
	_update_economy()
	_update_defend(dt)
	_update_objective_states()
	_update_zone(dt)
	_update_multi_zones(dt)
	_update_objective_ai(dt)
	_update_endless(dt)
	_update_escort_marker()
	_update_warning()
	_update_progress_text()
	_check_finish(dt)

func _update_waves() -> void:
	while _waves_fired < _waves.size():
		var wave: Dictionary = _waves[_waves_fired]
		if elapsed < float(wave.get("time", 0.0)):
			return
		_fire_wave(wave, _waves_fired + 1)
		_waves_fired += 1

func _fire_wave(wave: Dictionary, number: int) -> void:
	var target := _player_target_position()
	var label := String(wave.get("label", "第 %d 波" % number))
	var units: Array = wave.get("units", [])
	var water: bool = bool(wave.get("water", false))
	var lane_centers: Array = []
	if not water:
		# 玩家可能在预定路线上补了建筑：刷兵前把每个入口挪到附近空地，避免兵卡在墙里。
		for c in _wave_centers(number):
			var spot: Vector3 = c
			var legal := _find_spot_near(spot, 8.0, 2.0)
			if legal != Vector3.ZERO and _is_inside_spawn_map(legal):
				spot = legal
			lane_centers.append(spot)
		if lane_centers.is_empty():
			lane_centers.append(enemy_spawn_point)
	var total_units: int = 0
	for u in units:
		total_units += int(u.get("count", 1))
	var split_at: int = int(ceil(float(total_units) / 2.0))
	var spawn_index: int = 0
	var alert_pos: Vector3 = lane_centers[0] if not lane_centers.is_empty() else enemy_spawn_point
	if water:
		alert_pos = _enemy_water_spawn if _enemy_water_spawn != Vector3.ZERO else enemy_spawn_point
	var spawned: Array = []
	for u in units:
		var count: int = int(u.get("count", 1))
		var unit_id: int = int(u.get("id", 11))
		for i in range(count):
			var pos: Vector3
			if water:
				pos = _water_spawn_slot(i, count)
			else:
				var lane: Vector3 = lane_centers[0]
				if lane_centers.size() > 1 and spawn_index >= split_at:
					lane = lane_centers[1]
				pos = _wave_slot(spawn_index, total_units, lane)
			spawn_index += 1
			if pos == Vector3.ZERO:
				continue
			var unit = bm.spawn_entity(EntityDatabase.get_config(unit_id), bm.enemy_team, pos,
				_wave_army_level(wave, u, number))
			if unit != null:
				spawned.append(unit)
				_hook_enemy_kill(unit, unit_id)
	for unit in spawned:
		if is_instance_valid(unit) and unit.has_method("attack_move_to"):
			unit.attack_move_to(target)
	bm._show_hud_alert(
		"%s 敌军抵达！共 %d 个单位" % [label, spawned.size()],
		Color(1.0, 0.35, 0.2), [bm.enemy_team], bm.player_team,
		GameSettings.AlertKind.COMBAT, false, [bm.team_nations.get(bm.enemy_team, -1)],
		alert_pos, -1
	)

# 一波兵在刷兵点周围铺开
# 海战波次：在敌我之间的海面上铺开
func _water_spawn_slot(index: int, total: int) -> Vector3:
	var center: Vector3 = _enemy_water_spawn if _enemy_water_spawn != Vector3.ZERO else enemy_spawn_point
	var ring: int = index / 8
	var i_in_ring: int = index % 8
	var radius: float = 2.0 + float(ring) * 2.5
	var angle: float = TAU * float(i_in_ring) / 8.0 + float(ring) * 0.4
	for attempt in range(8):
		var pos := Vector3(
			center.x + cos(angle + float(attempt) * 0.45) * radius, 0.0,
			center.z + sin(angle + float(attempt) * 0.45) * radius)
		if _is_water(pos):
			return pos
	return center if _is_water(center) else Vector3.ZERO

func _wave_slot(index: int, total: int, center: Vector3) -> Vector3:
	var ring: int = index / 10
	var i_in_ring: int = index % 10
	var radius: float = 2.0 + float(ring) * 2.0
	var angle: float = TAU * float(i_in_ring) / 10.0 + float(ring) * 0.4
	for attempt in range(6):
		var pos := Vector3(
			center.x + cos(angle + float(attempt) * 0.35) * radius, 0.0,
			center.z + sin(angle + float(attempt) * 0.35) * radius)
		if _is_inside_spawn_map(pos) and _is_plain(pos):
			return pos
	return Vector3.ZERO

# ==================== 目标推进 ====================

func _update_objective_states() -> void:
	var objs: Array = level.get("objectives", [])
	for i in range(mini(objs.size(), objective_states.size())):
		var obj: Dictionary = objs[i]
		var t := String(obj.get("type", ""))
		var done := false
		match t:
			"destroy_castle":
				done = _enemy_castle_destroyed()
			"survive":
				done = _survive_need > 0.0 and elapsed >= _survive_need
			"hold_zone":
				done = hold_seconds >= _zone_hold_need
			"hold_zones":
				done = _multi_zones_done()
			"endless":
				done = false
			"defend_targets":
				done = _defend_duration > 0.0 and elapsed >= _defend_duration and _defend_alive >= _defend_min_alive
			"escort":
				done = _escort_reached()
			"destroy_targets":
				done = _targets_destroyed() >= _target_need
			"gather":
				done = _gather_total >= _gather_need
			"kill_units":
				if _kill_max_slip > 0 and _kill_slipped > _kill_max_slip:
					_finish(false)
					return
				done = _kill_progress() >= _kill_need
		objective_states[i]["done"] = done

# 信使是否已经走进护送点
func _escort_reached() -> bool:
	if _escort_unit == null or not is_instance_valid(_escort_unit) or _escort_unit.health <= 0:
		return false
	return _escort_unit.global_position.distance_to(_escort_zone_center) <= _escort_zone_radius

# 敌方指定建筑已经倒下几座（AI 期间新建的塔不算进度，最多按基线算）
func _targets_destroyed() -> int:
	var alive := _count_enemy_buildings(_target_ids)
	return clampi(_target_initial - alive, 0, _target_initial)

# 击杀进度：有 unit_ids 只数这些兵种，没有就数全部
func _kill_progress() -> int:
	if _kill_ids.is_empty():
		return _enemy_kills
	var n := 0
	for id in _kill_ids:
		n += int(_enemy_kills_by_id.get(int(id), 0))
	return n

func _update_zone(dt: float) -> void:
	if _zone_radius <= 0.0 or _zone_hold_need <= 0.0:
		return
	var mine := 0
	var theirs := 0
	var nearest := -1.0
	for e in bm.entities.get_children():
		if not (e is Army) or e.health <= 0:
			continue
		var dist: float = e.global_position.distance_to(_zone_center)
		if int(e.team) == bm.player_team:
			if nearest < 0.0 or dist < nearest:
				nearest = dist
			if dist <= _zone_radius:
				mine += 1
		elif int(e.team) == bm.enemy_team and dist <= _zone_radius:
			theirs += 1
	_zone_nearest_dist = nearest
	_zone_enemy_inside = theirs > 0
	# 占领规则（按人数比，不是"敌人一进来就全盘倒退"）：
	#   我方人多  → 计时走，纯占领全速、混战半速；
	#   双方一样  → 都推不动，计时暂停；
	#   敌方人多  → 计时倒退（含我方一个都没有的情况）。
	if mine > theirs:
		hold_seconds = minf(_zone_hold_need,
			hold_seconds + dt * (1.0 if theirs == 0 else 0.5))
	elif theirs > mine:
		hold_seconds = maxf(0.0, hold_seconds - dt * 2.0)
	if hold_seconds >= _zone_hold_need:
		_zone_state_text = "占领完成"
	elif mine > 0 and theirs == 0:
		_zone_state_text = "占领中"
	elif mine > 0 and mine > theirs:
		_zone_state_text = "争夺中（我方人多，半速计时）"
	elif theirs > mine:
		_zone_state_text = "敌军控制，计时倒退"
	elif mine > 0 and mine == theirs:
		_zone_state_text = "争夺中（势均力敌，计时暂停）"
	else:
		_zone_state_text = "无人驻守"
	_update_zone_visual(dt)

# 占领区动态表现：光圈呼吸、光柱闪烁、头顶倒计时、小地图定时闪点
func _update_zone_visual(dt: float) -> void:
	var t: float = float(Time.get_ticks_msec()) * 0.001
	var done: bool = hold_seconds >= _zone_hold_need
	if _zone_mesh != null and is_instance_valid(_zone_mesh):
		var pulse: float = 1.0 + 0.02 * sin(t * 2.6)
		_zone_mesh.scale = Vector3(pulse, 1.0, pulse)
		_zone_mesh.visible = not done
	if _zone_disc != null and is_instance_valid(_zone_disc):
		_zone_disc.visible = not done
	if _zone_pillar != null and is_instance_valid(_zone_pillar) and _zone_pillar_mat != null:
		_zone_pillar_mat.albedo_color.a = 0.08 + 0.05 * (0.5 + 0.5 * sin(t * 1.6))
		_zone_pillar.visible = not done
	if _zone_label != null and is_instance_valid(_zone_label):
		if done:
			_zone_label.text = "占领完成"
		else:
			_zone_label.text = "占领区 %d / %d 秒\n%s" % [
				int(hold_seconds), int(_zone_hold_need), _zone_state_text]
		if _zone_enemy_inside and not done:
			_zone_label.modulate = Color(1.0, 0.45, 0.35)
		else:
			_zone_label.modulate = Color(0.55, 1.0, 0.65)
	# 屏幕空间倒计时（俯视也能看见）
	if _zone_screen_label != null and is_instance_valid(_zone_screen_label):
		if done:
			_update_screen_marker(_zone_screen_label,
				_zone_center + Vector3(0.0, 3.0, 0.0), "✔ 占领完成",
				Color(0.55, 1.0, 0.65), 48.0)
		else:
			var mark_text := "占领区 %d/%d 秒 · %s" % [
				int(hold_seconds), int(_zone_hold_need), _zone_state_text]
			var mark_color := Color(1.0, 0.5, 0.4) if _zone_enemy_inside else Color(0.55, 1.0, 0.65)
			_update_screen_marker(_zone_screen_label,
				_zone_center + Vector3(0.0, 3.0, 0.0), mark_text, mark_color, 48.0)
	# 小地图每 8 秒闪一次，别让玩家忘了圈在哪
	_zone_ping_timer -= dt
	if _zone_ping_timer <= 0.0 and not done:
		_zone_ping_timer = 8.0
		_ping_minimap(_zone_center)

# 护送点标记：屏幕空间文字，显示信使还有多远
func _update_escort_marker() -> void:
	if _escort_screen_label == null or not is_instance_valid(_escort_screen_label):
		return
	if _escort_unit != null and is_instance_valid(_escort_unit) and _escort_unit.health > 0:
		var dist: float = _escort_unit.global_position.distance_to(_escort_zone_center)
		_update_screen_marker(_escort_screen_label, _escort_zone_center + Vector3(0.0, 3.0, 0.0),
			"护送点 · 信使 %.0f 米" % dist, Color(0.55, 0.8, 1.0), 44.0)
	else:
		_update_screen_marker(_escort_screen_label, _escort_zone_center + Vector3(0.0, 3.0, 0.0),
			"护送点", Color(0.55, 0.8, 1.0), 44.0)

# ==================== 多控制区（hold_zones）====================

# 多控制区的基准点：双方基地连线中点（没有基地时用地图中心）
func _zone_group_base() -> Vector3:
	if player_anchor.length() > 0.5 and enemy_anchor.length() > 0.5:
		return Vector3((player_anchor.x + enemy_anchor.x) * 0.5, 0.0,
			(player_anchor.z + enemy_anchor.z) * 0.5)
	return Vector3.ZERO

# 建一个多控制区：贴地色块 + 光圈 + 光柱 + 3D 字 + 屏幕标签，全部记在字典里
func _build_multi_zone(center: Vector3, radius: float, need: float, zone_name: String,
		color: Color) -> Dictionary:
	var suffix := str(_multi_zones.size() + 1)
	var z: Dictionary = {
		"name": zone_name,
		"center": center,
		"radius": radius,
		"need": need,
		"held": 0.0,
		"enemy": false,
		"nearest": -1.0,
		"state": "无人驻守",
		"done": false,
		"ping": 3.0 + float(_multi_zones.size()) * 2.0,
		"disc": null,
		"ring": null,
		"pillar": null,
		"mat": null,
		"label3d": null,
		"screen": null,
	}
	z["disc"] = _add_ground_mesh(_make_ground_disc(center, radius, 0.45), center,
		Color(color, 0.16), "CampaignZoneDisc" + suffix)
	z["ring"] = _add_ground_mesh(
		_make_ground_band(center, maxf(radius - 0.8, 0.6), radius + 0.8, 0.6), center,
		Color(color, 0.95), "CampaignZoneRing" + suffix)
	var base_y: float = _ground_y_at(center.x, center.z)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(color, 0.12)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var pillar_mesh := CylinderMesh.new()
	pillar_mesh.top_radius = 1.0
	pillar_mesh.bottom_radius = 1.0
	pillar_mesh.height = 26.0
	pillar_mesh.radial_segments = 16
	pillar_mesh.material = mat
	var pillar := MeshInstance3D.new()
	pillar.name = "CampaignZonePillar" + suffix
	pillar.mesh = pillar_mesh
	pillar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bm.add_child(pillar)
	pillar.global_position = Vector3(center.x, base_y + 13.0, center.z)
	z["pillar"] = pillar
	z["mat"] = mat
	var l3 := Label3D.new()
	l3.name = "CampaignZoneLabel" + suffix
	l3.font_size = 64
	l3.pixel_size = 0.03
	l3.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l3.no_depth_test = true
	l3.modulate = color
	l3.outline_modulate = Color(0.0, 0.0, 0.0, 0.95)
	l3.outline_size = 14
	l3.text = zone_name
	bm.add_child(l3)
	l3.global_position = Vector3(center.x, base_y + 13.0, center.z)
	z["label3d"] = l3
	_ensure_screen_layer()
	z["screen"] = _make_screen_label()
	_ping_minimap(center)
	return z

func _multi_zones_done() -> bool:
	if _multi_zones.is_empty():
		return false
	for z in _multi_zones:
		if not bool(z.get("done", false)):
			return false
	return true

# 人数比 → 状态文案（单区/多区共用同一套规则，避免两处逻辑跑偏）
func _zone_state_of(mine: int, theirs: int) -> String:
	if mine > 0 and theirs == 0:
		return "占领中"
	if mine > theirs:
		return "争夺中（我方人多，半速计时）"
	if theirs > mine:
		return "敌军控制，计时倒退"
	if mine > 0 and mine == theirs:
		return "争夺中（势均力敌，计时暂停）"
	return "无人驻守"

func _update_multi_zones(dt: float) -> void:
	if _multi_zones.is_empty():
		return
	var t: float = float(Time.get_ticks_msec()) * 0.001
	for z in _multi_zones:
		var center: Vector3 = z["center"]
		var radius: float = float(z["radius"])
		var mine := 0
		var theirs := 0
		var nearest := -1.0
		for e in bm.entities.get_children():
			if not (e is Army) or e.health <= 0:
				continue
			var dist: float = e.global_position.distance_to(center)
			if int(e.team) == bm.player_team:
				if nearest < 0.0 or dist < nearest:
					nearest = dist
				if dist <= radius:
					mine += 1
			elif int(e.team) == bm.enemy_team and dist <= radius:
				theirs += 1
		z["nearest"] = nearest
		z["enemy"] = theirs > 0
		if not bool(z["done"]):
			var held: float = float(z["held"])
			var need: float = float(z["need"])
			if mine > theirs:
				held = minf(need, held + dt * (1.0 if theirs == 0 else 0.5))
			elif theirs > mine:
				held = maxf(0.0, held - dt * 2.0)
			z["held"] = held
			if held >= need:
				z["done"] = true
				z["state"] = "占领完成"
			else:
				z["state"] = _zone_state_of(mine, theirs)
		_update_multi_zone_visual(z, t, dt)

func _update_multi_zone_visual(z: Dictionary, t: float, dt: float) -> void:
	var done: bool = bool(z.get("done", false))
	var ring = z.get("ring")
	if ring != null and is_instance_valid(ring):
		var pulse: float = 1.0 + 0.02 * sin(t * 2.6)
		ring.scale = Vector3(pulse, 1.0, pulse)
		ring.visible = not done
	var disc = z.get("disc")
	if disc != null and is_instance_valid(disc):
		disc.visible = not done
	var mat = z.get("mat")
	var pillar = z.get("pillar")
	if pillar != null and is_instance_valid(pillar) and mat != null:
		mat.albedo_color.a = 0.08 + 0.05 * (0.5 + 0.5 * sin(t * 1.6))
		pillar.visible = not done
	var l3 = z.get("label3d")
	if l3 != null and is_instance_valid(l3):
		if done:
			l3.text = "%s\n占领完成" % String(z["name"])
		else:
			l3.text = "%s\n占领区 %d / %d 秒\n%s" % [
				String(z["name"]), int(z["held"]), int(z["need"]), String(z["state"])]
		l3.modulate = Color(1.0, 0.45, 0.35) if bool(z["enemy"]) and not done else Color(0.55, 1.0, 0.65)
	var screen = z.get("screen")
	if screen != null and is_instance_valid(screen):
		var center: Vector3 = z["center"]
		if done:
			_update_screen_marker(screen, center + Vector3(0.0, 3.0, 0.0),
				"✔ %s 占领完成" % String(z["name"]), Color(0.55, 1.0, 0.65), 48.0)
		else:
			var col := Color(1.0, 0.5, 0.4) if bool(z["enemy"]) else Color(0.55, 1.0, 0.65)
			_update_screen_marker(screen, center + Vector3(0.0, 3.0, 0.0),
				"%s %d/%d 秒 · %s" % [String(z["name"]), int(z["held"]), int(z["need"]),
					String(z["state"])], col, 48.0)
	z["ping"] = float(z["ping"]) - dt
	if float(z["ping"]) <= 0.0 and not done:
		z["ping"] = 8.0
		_ping_minimap(z["center"])

# ==================== 守住自家建筑（defend_targets）====================

# 开局目标建筑：只认这一刻已经存在的实体，后续新建的同 ID 建筑不会进来。
func _collect_defend_buildings(ids: Array) -> Array:
	var found: Array = []
	for e in bm.entities.get_children():
		if not (e is Building):
			continue
		if e.health <= 0 or e.is_queued_for_deletion():
			continue
		if int(e.team) != bm.player_team:
			continue
		if int(e.entity_id) not in ids:
			continue
		found.append(e)
	return found

func _count_alive_defend_targets() -> int:
	var n := 0
	for b in _defend_buildings:
		if not is_instance_valid(b) or b.is_queued_for_deletion():
			continue
		if b.health > 0 and int(b.team) == bm.player_team:
			n += 1
	return n

func _update_defend(dt: float) -> void:
	if _defend_ids.is_empty():
		return
	_defend_alive = _count_alive_defend_targets()
	# 目标建筑全毁：立刻判负，别等超时；新建的同 ID 建筑不能替代开局粮仓
	if _defend_alive <= 0:
		_finish(false)

func _update_warning() -> void:
	warning_text = ""
	# 3 星时限（7 分钟）过去后提示一次，让玩家知道这关已经拿不到 3 星
	if not _endless_on and _three_star_time > 0.0 and not _three_star_warned and elapsed > _three_star_time:
		_three_star_warned = true
		bm._show_hud_alert(
			"已超过 3★ 时限（%s），本关最多 2 星" % _fmt_time(_three_star_time),
			Color(1.0, 0.7, 0.25), [bm.player_team], bm.player_team,
			GameSettings.AlertKind.MISC, false, [bm.team_nations.get(bm.player_team, -1)],
			player_anchor, -1)
	# 波次预警：下一波 15 秒内提示
	if _waves_fired < _waves.size():
		var wave: Dictionary = _waves[_waves_fired]
		var remain: float = float(wave.get("time", 0.0)) - elapsed
		if remain > 0.0 and remain <= 15.0:
			var label := String(wave.get("label", "下一波"))
			var secs: int = int(ceil(remain))
			if not _wave_warned.has(_waves_fired):
				_wave_warned[_waves_fired] = true
				var warn_pos := _wave_entry_point(_waves_fired + 1)
				if warn_pos == Vector3.ZERO:
					warn_pos = enemy_spawn_point
				bm._show_hud_alert(
					"%s %d 秒后抵达" % [label, secs], Color(1.0, 0.8, 0.1),
					[bm.enemy_team], bm.player_team, GameSettings.AlertKind.COMBAT,
					false, [bm.team_nations.get(bm.enemy_team, -1)], warn_pos, -1)
			warning_text = "⚠ %s %d 秒后抵达" % [label, secs]
	if _zone_hold_need > 0.0 and hold_seconds < _zone_hold_need and _zone_enemy_inside:
		warning_text = "⚠ 控制区被敌军压住，计时倒退！快把兵调回去"
	for z in _multi_zones:
		if not bool(z.get("done", false)) and bool(z.get("enemy", false)):
			warning_text = "⚠ %s 被敌军压住，计时倒退！" % String(z.get("name", "控制区"))
	if _endless_on and _endless_timer <= 10.0:
		warning_text = "⚠ 第 %d 波还有 %d 秒抵达" % [_endless_waves + 1, int(ceil(_endless_timer))]

# ==================== 胜负判定 ====================

func _check_finish(dt: float) -> void:
	# 目标全部达成 → 胜利
	var all_done: bool = true
	for item in objective_states:
		if not bool(item.get("done", false)):
			all_done = false
			break
	if not objective_states.is_empty() and all_done:
		_finish(true)
		return
	if _has_castle_lost_fail:
		if player_castle != null and (not is_instance_valid(player_castle) or player_castle.health <= 0):
			_finish(false)
			return
		if level.get("player", {}).get("castle", true) and player_castle == null:
			_finish(false)
			return
	if _has_timeout_fail and _time_limit > 0.0 and elapsed >= _time_limit:
		_finish(false)
		return
	if _has_army_wiped_fail:
		if _count_player_mobile() <= 0:
			_army_wiped_time += dt
			if _army_wiped_time >= 2.0:
				_finish(false)
				return
		else:
			_army_wiped_time = 0.0

func _count_player_mobile() -> int:
	var n := 0
	for e in bm.entities.get_children():
		if e is Army and e.health > 0 and int(e.team) == bm.player_team:
			n += 1
	return n

func _enemy_castle_destroyed() -> bool:
	if enemy_castle == null:
		return false
	return not is_instance_valid(enemy_castle) or enemy_castle.health <= 0

func _on_castle_died(is_player: bool) -> void:
	if state != State.RUNNING:
		return
	if is_player:
		if _has_castle_lost_fail:
			_finish(false)
		return
	# 敌方主城被拆：只有“拆城”类关卡直接判胜，其它关卡（占领关）继续打
	if _destroy_castle_goal:
		_finish(true)

# ==================== 面板与结算 ====================

func _create_hud() -> void:
	var ui = bm.get_node_or_null("UI")
	if ui == null:
		return
	_hud = CampaignHUDScript.new()
	_hud.setup(self)
	ui.add_child(_hud)

func _announce_start() -> void:
	var subtitle := String(level.get("subtitle", ""))
	bm._show_hud_alert(
		"任务开始：%s%s" % [String(level.get("name", "")), ("（%s）" % subtitle) if subtitle else ""],
		Color(0.35, 0.95, 0.55), [bm.player_team], bm.player_team,
		GameSettings.AlertKind.MISC, false, [bm.team_nations.get(bm.player_team, -1)],
		player_anchor, -1)

func _finish(won: bool) -> void:
	if state != State.RUNNING:
		return
	state = State.WON if won else State.LOST
	set_process(false)
	bm.game_over = true
	AudioManager.play_music("victory" if won else "defeat")
	if _hud != null and is_instance_valid(_hud):
		_hud.visible = false
	if _screen_layer != null and is_instance_valid(_screen_layer):
		_screen_layer.visible = false
	# 战役用自己的结算卡：隐藏普通对局的统计面板
	if bm.game_over_panel != null and is_instance_valid(bm.game_over_panel):
		bm.game_over_panel.visible = false
	var stars := 0
	if won:
		stars = _compute_stars()
		_progress_source().record_win(String(level.get("id", "")), stars, elapsed)
		if _is_training() and String(level.get("id", "")) == "t24":
			TrainingProgressScript.mark_nation_seen(GameSettings.training_nation)
	elif _endless_on:
		stars = _endless_stars()
		_progress_source().record_win(String(level.get("id", "")), stars, elapsed)
		_progress_source().record_endless(String(level.get("id", "")), _endless_waves, _endless_score)
	_show_result(won, stars)

func _compute_stars() -> int:
	if _endless_on:
		return _endless_stars()
	var stars := 1
	var star_cfg: Dictionary = level.get("stars", {})
	var two: float = float(star_cfg.get("two", 0.0))
	var three: float = float(star_cfg.get("three", 0.0))
	# 3 星只认速度：7 分钟内通关，主城血量不能把慢通关补成 3 星
	if three > 0.0 and elapsed <= three:
		stars = 3
	elif two > 0.0 and elapsed <= two:
		stars = 2
	# 有主城的关卡：主城血量只作为 1★→2★ 的补救（最高 2 星，不越过时间门槛）
	if stars < 3 and player_castle != null and is_instance_valid(player_castle):
		var hp_pct: float = float(player_castle.health) / maxf(float(player_castle.max_health), 1.0)
		if hp_pct >= 0.85 and stars < 2:
			stars = 2
	return clampi(stars, 1, 3)

func _show_result(won: bool, stars: int) -> void:
	_result_layer = CanvasLayer.new()
	_result_layer.name = "CampaignResult"
	_result_layer.layer = 20
	bm.add_child(_result_layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	_result_layer.add_child(root)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.68)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)

	var mobile := InputSource.use_mobile_ui()
	var card_w: float = UILayout.dp(520.0) if mobile else 620.0
	var pad: float = UILayout.dp(18.0) if mobile else 26.0
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UIThemeScript.card_style(
		UIThemeScript.GOLD if won else UIThemeScript.VERMILION))
	card.custom_minimum_size = Vector2(card_w, 0.0)
	card.anchor_left = 0.5
	card.anchor_right = 0.5
	card.anchor_top = 0.5
	card.anchor_bottom = 0.5
	card.offset_left = -card_w * 0.5
	card.offset_right = card_w * 0.5
	card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	card.grow_vertical = Control.GROW_DIRECTION_BOTH
	root.add_child(card)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	vb.add_theme_constant_override("margin_left", int(pad))
	card.add_child(vb)

	var title := Label.new()
	if _endless_on:
		title.text = "🏁 挑战结束"
	elif won:
		title.text = "🎓 训练完成" if _is_training() else "🎉 任务完成"
	else:
		title.text = "💀 训练失败" if _is_training() else "💀 任务失败"
	UIThemeScript.apply_label(title, UILayout.font_dp(22.0) if mobile else UIThemeScript.FONT_XXL,
		UIThemeScript.EMERALD if won else (UIThemeScript.GOLD if _endless_on else UIThemeScript.VERMILION))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	var name_label := Label.new()
	name_label.text = _data_source().display_name(level)
	UIThemeScript.apply_label(name_label, UILayout.font_dp(13.0) if mobile else UIThemeScript.FONT_LG,
		UIThemeScript.PARCHMENT)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(name_label)

	if won or _endless_on:
		var star_label := Label.new()
		star_label.text = "★".repeat(stars) + "☆".repeat(3 - stars)
		UIThemeScript.apply_label(star_label, UILayout.font_dp(24.0) if mobile else 32, UIThemeScript.GOLD)
		star_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vb.add_child(star_label)

	var stats := Label.new()
	var lines: Array = []
	lines.append("用时：%s" % _fmt_time(elapsed))
	if not _endless_on and _three_star_time > 0.0:
		lines.append("3★ 门槛：%s 内通关（本关限时 %s）" % [
			_fmt_time(_three_star_time), _fmt_time(_time_limit)])
	if player_castle != null and is_instance_valid(player_castle):
		var hp_pct: float = float(player_castle.health) / maxf(float(player_castle.max_health), 1.0)
		lines.append("主城剩余血量：%d%%" % int(round(hp_pct * 100.0)))
	if _endless_on:
		lines.append("坚持到第 %d 波 · 得分 %d" % [_endless_waves, _endless_score])
		lines.append("历史最高：第 %d 波 / %d 分" % [
			_progress_source().best_wave(String(level.get("id", ""))),
			_progress_source().best_score(String(level.get("id", "")))])
	lines.append("本关最好成绩：%s / %d 星" % [
		_fmt_time(_progress_source().best_time(String(level.get("id", "")))),
		_progress_source().best_stars(String(level.get("id", "")))])
	stats.text = "\n".join(lines)
	UIThemeScript.apply_label(stats, UILayout.font_dp(11.0) if mobile else UIThemeScript.FONT_MD,
		UIThemeScript.PARCHMENT)
	stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(stats)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(buttons)
	var next_id := String(_data_source().next_level_id(String(level.get("id", ""))))
	if won and not next_id.is_empty():
		var next_btn := _make_button("下一关 ▸", true, mobile)
		next_btn.pressed.connect(_on_next_pressed.bind(next_id))
		buttons.add_child(next_btn)
	var retry_btn := _make_button("重试", not (won and not next_id.is_empty()), mobile)
	retry_btn.pressed.connect(_on_retry_pressed)
	buttons.add_child(retry_btn)
	var back_btn := _make_button("返回训练营" if _is_training() else "返回战役", false, mobile)
	back_btn.pressed.connect(_on_back_pressed)
	buttons.add_child(back_btn)
	var menu_btn := _make_button("主菜单", false, mobile)
	menu_btn.pressed.connect(_on_menu_pressed)
	buttons.add_child(menu_btn)

	UIThemeScript.fade_in(root, 0.25)

func _make_button(text: String, primary: bool, mobile: bool) -> Button:
	var btn := Button.new()
	btn.text = text
	if mobile:
		btn.custom_minimum_size = Vector2(UILayout.dp(110.0), UILayout.dp(40.0))
	else:
		btn.custom_minimum_size = Vector2(120.0, 44.0)
	if primary:
		UIThemeScript.apply_primary_button(btn, UILayout.font_dp(11.0) if mobile else UIThemeScript.FONT_MD)
	else:
		UIThemeScript.apply_button(btn, UILayout.font_dp(11.0) if mobile else UIThemeScript.FONT_MD)
	return btn

func _on_retry_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/rts_battle.tscn")

func _on_next_pressed(next_id: String) -> void:
	if _is_training():
		GameSettings.training_level_id = next_id
		GameSettings.campaign_mode = false
	else:
		GameSettings.campaign_mode = true
		GameSettings.campaign_level_id = next_id
	get_tree().change_scene_to_file("res://scenes/rts_battle.tscn")

func _on_back_pressed() -> void:
	if _is_training():
		GameSettings.training_mode = false
		GameSettings.training_level_id = ""
		get_tree().change_scene_to_file("res://scenes/training_menu.tscn")
		return
	GameSettings.campaign_mode = false
	get_tree().change_scene_to_file("res://scenes/campaign_menu.tscn")

func _on_menu_pressed() -> void:
	var was_training := _is_training()
	GameSettings.campaign_mode = false
	GameSettings.training_mode = false
	GameSettings.training_level_id = ""
	if was_training:
		GameSettings.progression_mode = GameSettings.training_prev_progression
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

# ==================== 小工具 ====================

# 战役科研模式的开局校准：
# 1. 按章节把时代推进到本章应有的阶段（第一章黑暗、第二章封建……），
#    否则固定 10 分钟关卡从黑暗时代点起，科研几乎来不及展开；
# 2. 给一小笔“战前科研补给”，保证纯军队关（无主城/无农民/零资源）也能真正点科技。
# 只影响科研模式，经典模式的战役数值完全不变。
func _apply_campaign_research_setup() -> void:
	if not GameSettings.is_research_mode():
		return
	var chapter: int = clampi(int(level.get("chapter", 1)), 1, 4)
	var target_age: int = chapter - 1
	var st: Dictionary = bm.get_host_research_state()
	if not st.is_empty():
		st["age"] = maxi(int(st.get("age", 0)), target_age)
		bm._refresh_research_derived(st)
	# 有城堡的关卡若给了资源，保留关卡原值；只在科研模式下追加固定补给。
	var stipend := {"food": 200, "wood": 200, "gold": 150, "stone": 150}
	for key in stipend:
		bm.player_resources[key] = int(bm.player_resources.get(key, 0)) + int(stipend[key])
	# 敌方 AI 也进入同一时代，避免玩家用封建科技碾压黑暗 AI。
	var enemy_st: Dictionary = bm.get_research_state(-1, bm.enemy_team)
	if not enemy_st.is_empty():
		enemy_st["age"] = maxi(int(enemy_st.get("age", 0)), target_age)
		bm._refresh_research_derived(enemy_st)

func _apply_resources(bucket: Dictionary, values: Dictionary) -> void:
	for k in values:
		bucket[k] = values[k]

func _is_plain(pos: Vector3) -> bool:
	return bm.get_terrain_at(pos) == 0

# 在目标点附近找一个可用的空地（平地 + 不与实体重叠），最多挪 max_shift 米
func _find_spot_near(pos: Vector3, max_shift: float, gap: float) -> Vector3:
	if _is_plain(pos) and not _too_close(pos, gap):
		return pos
	var steps: int = maxi(int(max_shift / 2.0), 1)
	for ring in range(1, steps + 1):
		var r: float = float(ring) * 2.0
		for i in range(10):
			var a: float = TAU * float(i) / 10.0 + float(ring) * 0.3
			var p := Vector3(pos.x + cos(a) * r, 0.0, pos.z + sin(a) * r)
			if _is_plain(p) and not _too_close(p, gap):
				return p
	return Vector3.ZERO

# 判断落点是否已经有实体（按中心距，不用碰撞半径：
# 城墙相邻两段中心距正好等于 2 米，用半径判断会把每隔一段的墙都判成“太挤”）
func _too_close(pos: Vector3, center_range: float) -> bool:
	for e in bm.get_nearby_entities(pos, center_range):
		if e is GameEntity and e.health > 0:
			return true
	return false

func _player_target_position() -> Vector3:
	if player_castle != null and is_instance_valid(player_castle):
		return player_castle.global_position
	return player_anchor

func _fmt_time(sec: float) -> String:
	var total: int = maxi(int(round(sec)), 0)
	return "%02d:%02d" % [total / 60, total % 60]

# HUD 每帧读这个字符串：主目标进度 + 关卡剩余时间
func _update_progress_text() -> void:
	var parts: Array = []
	var objs: Array = level.get("objectives", [])
	for i in range(mini(objs.size(), objective_states.size())):
		var obj: Dictionary = objs[i]
		var t := String(obj.get("type", ""))
		match t:
			"survive":
				parts.append("守城倒计时 %s / %s" % [
					_fmt_time(maxf(_survive_need - elapsed, 0.0)), _fmt_time(_survive_need)])
			"hold_zone":
				var zone_line := "占领区 %d / %d 秒 · %s" % [
					int(hold_seconds), int(_zone_hold_need), _zone_state_text]
				if _zone_nearest_dist > _zone_radius:
					zone_line += "（最近部队 %.0f 米外）" % _zone_nearest_dist
				parts.append(zone_line)
			"escort":
				if _escort_unit != null and is_instance_valid(_escort_unit) and _escort_unit.health > 0:
					var dist: float = _escort_unit.global_position.distance_to(_escort_zone_center)
					parts.append("信使距哨站 %.0f 米（进蓝圈即送达）" % dist)
				else:
					parts.append("信使已阵亡")
			"hold_zones":
				var zone_parts: Array = []
				for z in _multi_zones:
					zone_parts.append("%s %d/%d 秒·%s" % [
						String(z["name"]), int(z["held"]), int(z["need"]), String(z["state"])])
				parts.append("；".join(zone_parts))
			"endless":
				parts.append("已坚持 %d 波 · 得分 %d（历史最高 %d 波）" % [
					_endless_waves, _endless_score,
					_progress_source().best_wave(String(level.get("id", "")))])
			"defend_targets":
				parts.append("目标建筑 %d/%d 座 · 撑过 %s / %s" % [
					_defend_alive, maxi(_defend_initial, _defend_min_alive),
					_fmt_time(maxf(_defend_duration - elapsed, 0.0)), _fmt_time(_defend_duration)])
			"destroy_targets":
				parts.append("已摧毁 %d / %d 座目标建筑" % [_targets_destroyed(), _target_need])
			"gather":
				parts.append("累计采集 %d / %d 资源" % [int(_gather_total), int(_gather_need)])
			"kill_units":
				var verb := "已击沉敌船" if not _kill_ids.is_empty() else "已歼灭敌军"
				var kill_line := "%s %d / %d" % [verb, _kill_progress(), _kill_need]
				if _kill_max_slip > 0:
					kill_line += "（漏过 %d / %d 艘）" % [_kill_slipped, _kill_max_slip]
				parts.append(kill_line)
			"destroy_castle":
				if enemy_castle != null and is_instance_valid(enemy_castle):
					var hp: float = float(enemy_castle.health)
					var max_hp: float = maxf(float(enemy_castle.max_health), 1.0)
					parts.append("敌方主城剩余 %d%%（已拆 %d%%）" % [
						int(round(hp / max_hp * 100.0)), int(round((1.0 - hp / max_hp) * 100.0))])
				else:
					parts.append("敌方主城已不存在")
	if _time_limit > 0.0:
		parts.append("关卡剩余 %s" % _fmt_time(maxf(_time_limit - elapsed, 0.0)))
	else:
		parts.append("已用时 %s" % _fmt_time(elapsed))
	progress_text = "\n".join(parts)
