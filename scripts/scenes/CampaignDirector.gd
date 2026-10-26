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
const CampaignHUDScript = preload("res://scripts/ui/CampaignHUD.gd")
const UIThemeScript = preload("res://scripts/ui/UITheme.gd")

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

var _zone_center: Vector3 = Vector3.ZERO
var _zone_radius: float = 12.0
var _zone_hold_need: float = 120.0
var _zone_mesh: MeshInstance3D = null
var _zone_enemy_inside: bool = false

var _waves: Array = []
var _waves_fired: int = 0
var _wave_warned: Dictionary = {}
var _tick: float = 0.0
var _army_wiped_time: float = 0.0
var _hud = null
var _result_layer: CanvasLayer = null

# 开局配置解析出来的任务参数
var _survive_need: float = -1.0
var _destroy_castle_goal: bool = false
var _has_army_wiped_fail: bool = false
var _has_castle_lost_fail: bool = false
var _has_timeout_fail: bool = false
var _time_limit: float = 0.0

func _ready() -> void:
	if not GameSettings.campaign_mode or GameSettings.campaign_level_id.is_empty():
		queue_free()
		return
	# 等战斗管理器把 UI / 面板都建好再开局
	set_process(false)
	call_deferred("_setup")

# ==================== 开局生成 ====================

func _setup() -> void:
	bm = get_parent() as RTSBattleManager
	if bm == null:
		push_error("CampaignDirector: 父节点不是 RTSBattleManager")
		queue_free()
		return
	level = CampaignDataScript.get_level(GameSettings.campaign_level_id)
	if level.is_empty():
		push_warning("CampaignDirector: 找不到关卡 %s，按普通对局继续" % GameSettings.campaign_level_id)
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

	# 人口上限与起始资源由关卡指定（没有主城时按建筑算会是 0，必须走战役覆盖）
	bm.campaign_pop_caps = {
		bm.player_team: int(player_cfg.get("pop_cap", 60)),
		bm.enemy_team: int(enemy_cfg.get("pop_cap", 60)),
	}
	bm.update_population_limits()
	_apply_resources(bm.player_resources, player_cfg.get("resources", {}))
	_apply_resources(bm.enemy_resources, enemy_cfg.get("resources", {}))

	# 波次表（防守关：敌人没有城堡，只按时间点刷兵）
	_waves = enemy_cfg.get("waves", []).duplicate(true)
	_waves.sort_custom(func(a, b): return float(a.get("time", 0.0)) < float(b.get("time", 0.0)))
	enemy_spawn_point = _pick_spawn_point()

	_parse_objectives()
	_create_hud()

	# 相机对准玩家出生点（没有主城时也要对准军队）
	var cam = bm.get_viewport().get_camera_3d()
	if cam != null:
		cam.global_position = Vector3(player_anchor.x, cam.global_position.y, player_anchor.z)

	_update_objective_states()
	_update_progress_text()
	_announce_start()
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
			castle.died.connect(_on_castle_died.bind(is_player))
	# 城墙线段
	for line in cfg.get("walls", []):
		_spawn_wall_line(team, anchor, line)
	# 单点建筑（塔 / 兵营 / 民居）
	for b in cfg.get("buildings", []):
		var off: Array = b.get("offset", [0.0, 0.0])
		var pos := Vector3(anchor.x + float(off[0]), 0.0, anchor.z + float(off[1]))
		if not _is_plain(pos):
			continue
		if _too_close(pos, 1.9):
			continue
		bm.spawn_entity(EntityDatabase.get_config(int(b.get("id", 25))), team, pos, int(b.get("level", 1)))
	# 开局军队
	var units: Array = cfg.get("units", [])
	for u in units:
		var count: int = int(u.get("count", 1))
		for i in range(count):
			var pos := _unit_slot(anchor, i, count)
			if pos == Vector3.ZERO:
				continue
			bm.spawn_entity(EntityDatabase.get_config(int(u.get("id", 11))), team, pos, int(u.get("level", 1)))

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

# 波次刷兵点：从玩家出生点朝敌方旧营地方向拉开一段距离，保证是可走平地
func _pick_spawn_point() -> Vector3:
	var dir := Vector3(player_anchor.x - enemy_anchor.x, 0.0, player_anchor.z - enemy_anchor.z)
	if dir.length() < 1.0:
		dir = Vector3(0.0, 0.0, 1.0)
	dir = dir.normalized()
	var base_angle: float = atan2(dir.z, dir.x)
	for dist in [48.0, 40.0, 34.0, 28.0]:
		for da in [0.0, 0.35, -0.35, 0.7, -0.7, 1.1, -1.1]:
			var pos := Vector3(
				player_anchor.x + cos(base_angle + float(da)) * dist,
				0.0,
				player_anchor.z + sin(base_angle + float(da)) * dist
			)
			if _is_plain(pos):
				return pos
	return Vector3(player_anchor.x + dir.x * 45.0, 0.0, player_anchor.z + dir.z * 45.0)

# ==================== 任务解析 ====================

func _parse_objectives() -> void:
	_time_limit = float(level.get("time_limit", 0.0))
	var fail_flags: Array = level.get("fail", [])
	_has_army_wiped_fail = fail_flags.has("army_wiped")
	_has_castle_lost_fail = fail_flags.has("castle_lost")
	_has_timeout_fail = fail_flags.has("timeout")
	objective_states.clear()
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
				var map = bm.get_node_or_null("Map")
				if map != null and map.terrain_grid.size() > 0:
					var size: int = int(map.terrain_grid.size())
					var center: Vector3 = map.grid_to_world(int(size / 2), int(size / 2))
					_zone_center = _find_plain_area(
						Vector3(center.x + float(off[0]), 0.0, center.z + float(off[1])), _zone_radius)
				_spawn_zone_ring()

# 在地图中间找一块足够大的平地放控制区（中心点被水/山占时向外搜）
func _find_plain_area(center: Vector3, radius: float) -> Vector3:
	var map = bm.get_node_or_null("Map")
	var half: float = float(RTSConfig.MAP_SIZE) * 0.5
	if map != null and map.terrain_grid.size() > 0:
		half = float(map.terrain_grid.size()) * 0.5
	for ring in range(0, 16):
		var step: float = 4.0 + float(ring) * 4.0
		for da in [0.0, 0.6, -0.6, 1.2, -1.2, 1.8, -1.8, 2.4, -2.4, 3.1]:
			var pos := Vector3(center.x + cos(float(da)) * step, 0.0, center.z + sin(float(da)) * step)
			if absf(pos.x) > half - radius - 4.0 or absf(pos.z) > half - radius - 4.0:
				continue
			if _area_is_plain(pos, radius):
				if map != null and map.has_method("get_height_at"):
					pos.y = float(map.get_height_at(pos))
				return pos
	if map != null and map.has_method("get_height_at"):
		center.y = float(map.get_height_at(center))
	return center

func _area_is_plain(center: Vector3, radius: float) -> bool:
	if not _is_plain(center):
		return false
	for i in range(12):
		var a: float = TAU * float(i) / 12.0
		var p := Vector3(center.x + cos(a) * radius, 0.0, center.z + sin(a) * radius)
		if not _is_plain(p):
			return false
	return true

# 控制区在地面上的绿色光圈
func _spawn_zone_ring() -> void:
	if _zone_radius <= 0.0:
		return
	var mesh := TorusMesh.new()
	mesh.inner_radius = maxf(_zone_radius - 0.45, 0.5)
	mesh.outer_radius = _zone_radius + 0.45
	mesh.rings = 48
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.25, 0.95, 0.45, 0.45)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = mat
	_zone_mesh = MeshInstance3D.new()
	_zone_mesh.name = "CampaignZoneRing"
	_zone_mesh.mesh = mesh
	var y: float = float(_zone_center.y) if _zone_center.y != 0.0 else 0.15
	_zone_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bm.add_child(_zone_mesh)
	_zone_mesh.global_position = Vector3(_zone_center.x, y + 0.35, _zone_center.z)

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
	_update_objective_states()
	_update_zone(dt)
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
	var spawned: Array = []
	for u in units:
		var count: int = int(u.get("count", 1))
		for i in range(count):
			var pos := _wave_slot(i, count)
			if pos == Vector3.ZERO:
				continue
			var unit = bm.spawn_entity(EntityDatabase.get_config(int(u.get("id", 11))), bm.enemy_team, pos, int(u.get("level", 1)))
			if unit != null:
				spawned.append(unit)
	for unit in spawned:
		if is_instance_valid(unit) and unit.has_method("attack_move_to"):
			unit.attack_move_to(target)
	bm._show_hud_alert(
		"%s 敌军抵达！共 %d 个单位" % [label, spawned.size()],
		Color(1.0, 0.35, 0.2), [bm.enemy_team], bm.player_team,
		GameSettings.AlertKind.COMBAT, false, [bm.team_nations.get(bm.enemy_team, -1)],
		enemy_spawn_point, -1
	)

# 一波兵在刷兵点周围铺开
func _wave_slot(index: int, total: int) -> Vector3:
	var ring: int = index / 10
	var i_in_ring: int = index % 10
	var radius: float = 2.0 + float(ring) * 2.0
	var angle: float = TAU * float(i_in_ring) / 10.0 + float(ring) * 0.4
	for attempt in range(6):
		var pos := Vector3(
			enemy_spawn_point.x + cos(angle + float(attempt) * 0.35) * radius, 0.0,
			enemy_spawn_point.z + sin(angle + float(attempt) * 0.35) * radius)
		if _is_plain(pos):
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
		objective_states[i]["done"] = done

func _update_zone(dt: float) -> void:
	if _zone_radius <= 0.0 or _zone_hold_need <= 0.0:
		return
	var mine := 0
	var theirs := 0
	for e in bm.entities.get_children():
		if not (e is Army) or e.health <= 0:
			continue
		if e.global_position.distance_to(_zone_center) > _zone_radius:
			continue
		if int(e.team) == bm.player_team:
			mine += 1
		elif int(e.team) == bm.enemy_team:
			theirs += 1
	_zone_enemy_inside = theirs > 0
	if mine > 0 and theirs == 0:
		hold_seconds = minf(_zone_hold_need, hold_seconds + dt)
	elif theirs > 0:
		# 敌军进区：计时以两倍速倒退，防止只守不攻
		hold_seconds = maxf(0.0, hold_seconds - dt * 2.0)

func _update_warning() -> void:
	warning_text = ""
	# 波次预警：下一波 15 秒内提示
	if _waves_fired < _waves.size():
		var wave: Dictionary = _waves[_waves_fired]
		var remain: float = float(wave.get("time", 0.0)) - elapsed
		if remain > 0.0 and remain <= 15.0:
			var label := String(wave.get("label", "下一波"))
			var secs: int = int(ceil(remain))
			if not _wave_warned.has(_waves_fired):
				_wave_warned[_waves_fired] = true
				bm._show_hud_alert(
					"%s %d 秒后抵达" % [label, secs], Color(1.0, 0.8, 0.1),
					[bm.enemy_team], bm.player_team, GameSettings.AlertKind.COMBAT,
					false, [bm.team_nations.get(bm.enemy_team, -1)], enemy_spawn_point, -1)
			warning_text = "⚠ %s %d 秒后抵达" % [label, secs]
	if _zone_enemy_inside and _zone_hold_need > 0.0:
		warning_text = "⚠ 敌军正在控制区内，计时倒退！"

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
	# 战役用自己的结算卡：隐藏普通对局的统计面板
	if bm.game_over_panel != null and is_instance_valid(bm.game_over_panel):
		bm.game_over_panel.visible = false
	var stars := 0
	if won:
		stars = _compute_stars()
		CampaignProgressScript.record_win(String(level.get("id", "")), stars, elapsed)
	_show_result(won, stars)

func _compute_stars() -> int:
	var stars := 1
	var star_cfg: Dictionary = level.get("stars", {})
	var two: float = float(star_cfg.get("two", 0.0))
	var three: float = float(star_cfg.get("three", 0.0))
	if three > 0.0 and elapsed <= three:
		stars = 3
	elif two > 0.0 and elapsed <= two:
		stars = 2
	# 有主城的关卡：主城血量也是评价标准（守得越好星级越高）
	if player_castle != null and is_instance_valid(player_castle):
		var hp_pct: float = float(player_castle.health) / maxf(float(player_castle.max_health), 1.0)
		if hp_pct >= 0.85 and stars < 3:
			stars = 3
		elif hp_pct >= 0.5 and stars < 2:
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
	title.text = "🎉 任务完成" if won else "💀 任务失败"
	UIThemeScript.apply_label(title, UILayout.font_dp(22.0) if mobile else UIThemeScript.FONT_XXL,
		UIThemeScript.EMERALD if won else UIThemeScript.VERMILION)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	var name_label := Label.new()
	name_label.text = CampaignDataScript.display_name(level)
	UIThemeScript.apply_label(name_label, UILayout.font_dp(13.0) if mobile else UIThemeScript.FONT_LG,
		UIThemeScript.PARCHMENT)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(name_label)

	if won:
		var star_label := Label.new()
		star_label.text = "★".repeat(stars) + "☆".repeat(3 - stars)
		UIThemeScript.apply_label(star_label, UILayout.font_dp(24.0) if mobile else 32, UIThemeScript.GOLD)
		star_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vb.add_child(star_label)

	var stats := Label.new()
	var lines: Array = []
	lines.append("用时：%s" % _fmt_time(elapsed))
	if player_castle != null and is_instance_valid(player_castle):
		var hp_pct: float = float(player_castle.health) / maxf(float(player_castle.max_health), 1.0)
		lines.append("主城剩余血量：%d%%" % int(round(hp_pct * 100.0)))
	lines.append("本关最好成绩：%s / %d 星" % [
		_fmt_time(CampaignProgressScript.best_time(String(level.get("id", "")))),
		CampaignProgressScript.best_stars(String(level.get("id", "")))])
	stats.text = "\n".join(lines)
	UIThemeScript.apply_label(stats, UILayout.font_dp(11.0) if mobile else UIThemeScript.FONT_MD,
		UIThemeScript.PARCHMENT)
	stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(stats)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(buttons)
	var next_id := CampaignDataScript.next_level_id(String(level.get("id", "")))
	if won and not next_id.is_empty():
		var next_btn := _make_button("下一关 ▸", true, mobile)
		next_btn.pressed.connect(_on_next_pressed.bind(next_id))
		buttons.add_child(next_btn)
	var retry_btn := _make_button("重试", not (won and not next_id.is_empty()), mobile)
	retry_btn.pressed.connect(_on_retry_pressed)
	buttons.add_child(retry_btn)
	var back_btn := _make_button("返回战役", false, mobile)
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
	GameSettings.campaign_mode = true
	GameSettings.campaign_level_id = next_id
	get_tree().change_scene_to_file("res://scenes/rts_battle.tscn")

func _on_back_pressed() -> void:
	GameSettings.campaign_mode = false
	get_tree().change_scene_to_file("res://scenes/campaign_menu.tscn")

func _on_menu_pressed() -> void:
	GameSettings.campaign_mode = false
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

# ==================== 小工具 ====================

func _apply_resources(bucket: Dictionary, values: Dictionary) -> void:
	for k in values:
		bucket[k] = values[k]

func _is_plain(pos: Vector3) -> bool:
	return bm.get_terrain_at(pos) == 0

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
				parts.append("控制区累计 %d / %d 秒" % [int(hold_seconds), int(_zone_hold_need)])
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
