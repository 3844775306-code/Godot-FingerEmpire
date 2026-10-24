class_name ClientRenderer
extends Node3D
const StatsScript = preload("res://scripts/core/BattleStats.gd")
const StatsPanelScript = preload("res://scripts/ui/BattleStatsPanel.gd")
const BuildingDeathEffect = preload("res://scripts/effects/BuildingDeathEffect.gd")
enum E { ID=0, EID, TYPE, TEAM, X, Y, Z, HEALTH, MAX_HEALTH, ATTACK, ATTACK_SPEED, MELEE_ARMOR, SHIELD_ARMOR, SPEED, VISION, BODY_R, TARGET_TYPE, OWNER, LEVEL, ORDER, HOLD, NAME, ENTITY_ID, WAYPOINTS, ROT_Y, ASTAR_PATH, GARRISONED, NATION, IN_ACTION_RANGE }
enum EB { UPGRADE=0, MAX_UPGRADE, CAN_UPGRADE, BUILD_TIMER, MAX_BUILD, PROD_CURRENT, PROD_PROGRESS, PROD_QSIZE, UPGRADE_TIMER, MAX_UPGRADE_TIME, GARRISON_COUNT }
# 与 RTSBattleManager.get_nation_name() 保持一致；客户端不跑服务端脚本，血条文字单独查表
const NATION_LABELS := ["维京", "英格兰", "法兰西", "中国", "匈牙利", "日本", "拜占庭"]
var last_applied_seq = -1
# ==================== 玩家信息 ====================
var player_team: int = -1          # 1v1 模式队伍 (BLUE=0, RED=1)
var my_peer_id: int = -1           # 2v2 模式标识（当前未用）
var my_color: Color = Color.WHITE

# ==================== 实体节点池 ====================
var entity_nodes: Dictionary = {}   # instance_id -> Node3D
# 客户端水面材质：用于把船只位置喂给着色器做涟漪/尾迹
var _water_mat: ShaderMaterial = null
var _boat_prev: Dictionary = {}   # 船只 instance_id -> 上次采样位置（算航向）
const BOAT_SHADER_SLOTS: int = 8

# ==================== 战争迷雾 ====================
var local_explored_grid: Array = []
var map_modifiers: Dictionary = {}   # 当前地图的视野规则修正（由 receive_map_data 下发）
var local_visible_grid: Array = []

# ==================== 血条池 ====================
var unit_bars: Dictionary = {}
# 血条文字开关（L 键切换）：关闭后只保留血条色条，隐藏名称/血量/生产/升级文字
var show_unit_text: bool = true

# ==================== 缓存数据 ====================
var last_resources: Dictionary = {}
var last_limits: Dictionary = {}
var last_population: Dictionary = {"current": 0, "max": 0}

# ==================== 建造预览 ====================
var placement_mode: bool = false
var placement_building_id: int = -1
var placement_preview: MeshInstance3D

# ==================== 定时器 ====================
var health_bar_timer: float = 0.0
const HEALTH_BAR_INTERVAL: float = 0.05  # 20Hz，血条与文字同频刷新
# 头顶血条尺寸：与单机版一致，50×8 基准，正交相机按 30/size 缩放
const HP_BAR_SIZE: Vector2 = Vector2(50.0, 8.0)
const HP_BAR_REF_ORTHO: float = 30.0
const HP_BAR_BASE_FONT: int = 18
var _bar_scale: float = 1.0
var _bar_size: Vector2 = HP_BAR_SIZE

# 客户端诊断
var _diag_snap_age: float = 999.0
var _diag_snap_count: int = 0
var _diag_last_snap_time: int = 0
var _snap_time_label: Label = null
var _snap_time_timer: float = 0.0
var _game_time: float = 0.0
var fog_timer: float = 0.0
var minimap_timer: float = 0.0
var _stale_cleanup_timer: float = 30.0
var _snapshot_cooldown: int = 0
var heavy_work_index: int = 0            # 轮转索引，每帧只做一个重任务
var first_fog_done: bool = false          # 首帧标志，确保初始化立即执行所有任务
var fog_cycle_active: bool = false        # 增量迷雾计算进行中
var fog_units_queue: Array = []           # 待处理的单位队列
var fog_batch_size: int = 10              # 每帧处理的单位数量（翻倍加速迷雾）

var last_snapshot_time = 0
	
@onready var entities_container: Node3D = $Entities
# 新增变量（放在类顶部）

var my_nation: int = -1  # for nation-specific unit production
var my_team: int = -1

var stale_snapshot: bool = false

var latest_snapshot: Dictionary = {}    # 必须初始化为空字典
var snapshot_processing: bool = false
var pending_delta: Array = []
var _prev_bullet_ids: Dictionary = {}  # id -> entity_id for sound detection

	# 如果有最新快照待处理，且当前不忙，则开始处理
	
var player_colors: Dictionary = {}   # peer_id -> Color
func set_all_player_colors(colors: Dictionary):
	player_colors = colors.duplicate()

# 新增方法
func set_player_info(peer_id: int, team: int, slot: int, color: Color):
	my_peer_id = peer_id
	my_team = team
	player_team = team          # 兼容1v1代码
	my_color = color
	

# ==================== 初始化 ====================
func _ready():
	add_to_group("client_renderer")
		# 快照时间显示标签
	_snap_time_label = Label.new()
	_snap_time_label.name = "SnapTimeLabel"
	_snap_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_snap_time_label.add_theme_font_size_override("font_size", 16)
	_snap_time_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7, 0.8))
	_snap_time_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_snap_time_label.add_theme_constant_override("outline_size", 1)
	_snap_time_label.text = "等待快照..."
	var ui = get_node_or_null("UI")
	if ui:
		ui.add_child(_snap_time_label)
	else:
		add_child(_snap_time_label)
	_init_fog_grids()

	# 小地图右下角
	await get_tree().process_frame
	var mm = get_node_or_null("UI/Minimap")
	if mm: mm.position = Vector2(2000, 10)

	# 建造预览体
	placement_preview = MeshInstance3D.new()
	var box = BoxMesh.new()
	box.size = Vector3(2, 1.5, 2)
	placement_preview.mesh = box
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0, 1, 0, 0.5)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.render_priority = 10          # 提高渲染优先级
	mat.no_depth_test = true          # 禁用深度测试，确保不被遮挡
	placement_preview.material_override = mat
	placement_preview.visible = false
	placement_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	placement_preview.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(placement_preview)

	# 将预览体移到所有子节点的最上层（在场景树中）
	move_child(placement_preview, get_child_count() - 1)

	# 命令卡覆盖层
	var card = CommandCard.new(); card.name = "CommandCard"
	$UI.add_child(card)

	# 选择信号 → InfoPanel + CommandCard
	if $ClientInput:
		$ClientInput.selection_changed.connect(func(ids: Array):
			var panel = $UI/InfoPanel as ClientInfoPanel
			if panel:
				if ids.size() == 1:
					panel.update_info(ids[0])
				elif ids.size() > 1:
					panel.show_multi_selection(ids)
				else:
					panel.visible = false
			var cc = $UI.get_node_or_null("CommandCard")
			if cc: _update_command_card(cc, ids)
			_refresh_waypoint_markers(ids)
			)

	# O键切换命令卡
	set_process_input(true)

	# 建造请求信号
	$ClientInput.build_requested.connect(func(wpos: Vector3):
		var menu = $UI/BuildMenu as ClientBuildMenu
		if menu:
			var cam = get_viewport().get_camera_3d()
			if cam:
				menu.popup_at(wpos, cam.unproject_position(wpos))
	)

	# 建造菜单发射“放置开始”信号
	if $UI/BuildMenu:
		$UI/BuildMenu.build_placement_started.connect(func(bid: int):
			start_build_placement(bid)
		)

func start_build_placement(bid: int):
	placement_mode = true
	placement_building_id = bid
	var cfg = EntityDatabase.get_config(bid)
	if cfg.is_empty(): return
	for c in placement_preview.get_children():
		c.queue_free()
	var model_path = RTSConfig.get_entity_model(bid)
	if model_path != "" and ResourceLoader.exists(model_path):
		var s = load(model_path)
		if s:
			var inst = s.instantiate()
			inst.name = "PreviewModel"
			# character 与步兵模型默认朝向相反，预览同样旋转 180°
			if RTSConfig.model_needs_flip(model_path): inst.rotation.y = deg_to_rad(180)
			placement_preview.mesh = null
			placement_preview.add_child(inst)
	if placement_preview.get_child_count() == 0:
		var box = BoxMesh.new()
		box.size = Vector3(cfg.body_radius*2, cfg.body_radius*1.5, cfg.body_radius*2)
		placement_preview.mesh = box
	var target_size = cfg.body_radius * 2.0 * RTSConfig.get_model_scale(bid)
	var aabb = _get_model_aabb(placement_preview)
	var current_size = max(aabb.size.x, max(aabb.size.y, aabb.size.z))
	if current_size > 0.01: placement_preview.scale = Vector3.ONE * (target_size / current_size)
	if bid in [22, 27, 28]: placement_preview.rotation.y = deg_to_rad(90)
	if bid == 18: placement_preview.rotation.y = deg_to_rad(-90)
	_tint_preview(placement_preview, Color(0, 1, 0))
	placement_preview.visible = true

			

	# Start battle music
	AudioManager.play_music("battle")

# Check if a world position is within the player's visible range
func _is_audible(pos: Vector3) -> bool:
	var gx = int(pos.x + RTSConfig.MAP_SIZE / 2)
	var gz = int(pos.z + RTSConfig.MAP_SIZE / 2)
	if gx < 0 or gx >= RTSConfig.MAP_SIZE or gz < 0 or gz >= RTSConfig.MAP_SIZE: return false
	return local_visible_grid.size() > gx and local_visible_grid[gx].size() > gz and local_visible_grid[gx][gz]

func _get_cam_pos() -> Vector3:
	var cam = get_viewport().get_camera_3d()
	return cam.global_position if cam else Vector3.ZERO

# ==================== 外部接口 ====================
func set_player_team(team: int):
	player_team = team
	print("客户端队伍设置为：", team)

func set_castle_pos(pos: Vector3):
	await get_tree().process_frame
	var cam = get_viewport().get_camera_3d()
	if cam:
		cam.global_position = Vector3(pos.x, cam.global_position.y, pos.z)

func get_population() -> Dictionary:
	return last_population

func get_player_resource(res_name: String) -> int:
	return last_resources.get(res_name, 0)

func get_player_castle_level() -> int:
	var max_lv = 1
	for n in entity_nodes.values():
		if not is_instance_valid(n) or not n.has_meta("snapshot_info"):
			continue
		var info = n.get_meta("snapshot_info")
		if info.get("type") == 1 and info.get("entity_id") == 20 and info.get("team") == player_team:
			var lv = info.get("upgrade_level", 1)
			if lv > max_lv:
				max_lv = lv
	return max_lv

# 供 CommandCard 复用：客户端没有本地资源库，用最近一次快照里的己方资源。
# 快照到达前返回空字典（按钮置灰），不要乐观放行，否则点了会被服务端拒绝
func get_host_resources() -> Dictionary:
	return last_resources

func get_host_team() -> int:
	return player_team

# 与 RTSBattleManager.is_building_unlocked 保持一致的城堡等级解锁表
func is_building_unlocked(building_id: int) -> bool:
	var cl = get_player_castle_level()
	match building_id:
		23, 25, 26, 64:
			return cl >= 2
		24, 29, 52:
			return cl >= 3
		42:
			return cl >= 3
		53, 54:
			return cl >= 4
	return true

# 归属判断：联机按 owner_peer_id，单机按队伍
func is_local_owned_info(info: Dictionary) -> bool:
	if info.is_empty(): return false
	if my_peer_id != -1:
		return int(info.get("owner_peer_id", -1)) == my_peer_id
	return int(info.get("team", -1)) == player_team

func _update_command_card(cc, ids: Array):
	# 队友单位只可查看：不显示任何生产/升级/拆除/指挥按钮
	if not ids.is_empty():
		for sid in ids:
			if not is_local_owned_info(get_entity_info(sid)):
				cc.hide_all()
				return
	if ids.size() == 1:
		var info = get_entity_info(ids[0])
		if info.get("type") == 1:
			# 用快照里已按等级截断的 production_list，而不是配置里的完整 produces，
			# 否则未解锁的单位也会画出按钮，点了会被服务端静默拒绝
			var pl = info.get("production_list", [])
			cc.show_building(pl, ids[0], info.get("entity_id",-1), self)
		elif info.get("type") == 2:
			cc.show_army()
		else:
			cc.hide_all()
	elif ids.is_empty():
		var clv = get_player_castle_level()
		cc.show_construct({"gold":get_player_resource("gold"),"wood":get_player_resource("wood"),"stone":get_player_resource("stone"),"food":get_player_resource("food"),"oil":get_player_resource("oil")}, clv, self)
	else:
		cc.hide_all()

func _input(event):
	if event is InputEventKey and event.pressed and event.keycode == KEY_O:
		var cc = $UI.get_node_or_null("CommandCard")
		if cc: cc.visible = not cc.visible
	elif event is InputEventKey and event.pressed and event.keycode == KEY_L:
		# L：切换血条文字显示（隐藏后画面上只剩血条色条）
		show_unit_text = not show_unit_text
		var hud = get_tree().get_first_node_in_group("client_hud")
		if hud and hud.has_method("show_alert_message"):
			hud.show_alert_message("单位血条文字：%s" % ("显示" if show_unit_text else "隐藏"), UITheme.ALERT_INFO)

func get_entity_info(id: int) -> Dictionary:
	var node = entity_nodes.get(id)
	if node and node.has_meta("snapshot_info"):
		return node.get_meta("snapshot_info")
	return {}

func get_entity_config(entity_id: int) -> Dictionary:
	return EntityDatabase.get_config(entity_id)

func apply_snapshot(data: Dictionary):
	# 快照总是携带本局随机国家配色；即使队伍尚未分配、快照暂不处理，也先同步配色。
	if data.has("nation_colors"):
		RTSConfig.set_nation_colors(data["nation_colors"])
	var now = Time.get_ticks_msec()
	var seq = data.get("seq", -1)
	if player_team == -1:
		return   # 尚未收到队伍分配，暂不处理快照
	if seq <= last_applied_seq:
		return   # 丢弃过时快照
	if last_applied_seq != -1 and data.get("seq") == last_applied_seq + 1:
		pass #print("连续收到")
	else:
		pass #print("跳号或重传: 期望 ", last_applied_seq+1, " 收到 ", data.get("seq"))
	last_applied_seq = seq
	_diag_snap_count += 1
	# HUD network stats
	var hud = get_tree().get_first_node_in_group("client_hud")
	if hud:
		hud._snap_recv_count += 1
		if hud._last_snap_seq >= 0 and seq > hud._last_snap_seq + 1:
			hud._snap_lost_count += (seq - hud._last_snap_seq - 1)
		hud._last_snap_seq = seq
	_diag_last_snap_time = now
	_diag_snap_age = 0.0
	last_snapshot_time = now
	if data.has("game_time"):
		_game_time = data["game_time"]
	# 丢弃未处理的旧快照，只保留最新
	if snapshot_processing:
		pending_delta.clear()
	latest_snapshot = data
	snapshot_processing = true

# 安全快照处理包装器——崩溃循环由 _process 层面的计数器处理
var _snapshot_fail_count: int = 0
func _safe_process_snapshot(data: Dictionary) -> bool:
	if data.is_empty():
		return false
	if not data.has('delta') and not data.has('entities'):
		return false
	_process_snapshot(data)
	_update_water_boats()
	return true

func _process_snapshot(data: Dictionary):
	# 缓存人口
	last_population = data.get("population", last_population)
	# Sync game time from server
	
	
	# ---- 实体更新 ----
	# 全量快照：记录本帧下发的全部实体 ID，用于下面的兜底清理
	var is_full_snap: bool = data.get("full", false)
	var full_ids: Dictionary = {}
	if data.has("delta"):
		for ent in data["delta"]:
			if is_full_snap and ent is Array and ent.size() > E.ID:
				full_ids[ent[E.ID]] = true
			_update_single_entity(ent)
	elif data.has("entities"):
		for ent in data["entities"]:
			_update_single_entity(ent)

	# 删除死亡实体（先播放死亡/倒塌表现，再释放本地节点）
	if data.has("dead_ids"):
		for id in data["dead_ids"]:
			if entity_nodes.has(id):
				var node = entity_nodes[id]
				var info = node.get_meta("snapshot_info", {})
				if _should_sink_entity(info, node):
					# 沉水动画期间从 entity_nodes 移除：选择、点选、小地图和血条都立即失效
					entity_nodes.erase(id)
					_play_sink_animation(node, info)
				else:
					# 建筑走程序化倒塌特效；节点立即移出 entity_nodes，但保留到动画结束再释放。
					var effect_duration := 0.0
					if int(info.get("type", -1)) == 1:
						effect_duration = BuildingDeathEffect.play(node, int(info.get("entity_id", -1)), float(info.get("body_radius", 0.5)))
					if effect_duration > 0.0:
						entity_nodes.erase(id)
					else:
						# 其他实体仍使用原有毁坏模型/直接删除流程
						var eid = info.get("entity_id", -1)
						var dem_path = RTSConfig.get_demolished_model(eid)
						if dem_path != "" and ResourceLoader.exists(dem_path):
							for child in node.get_children():
								if child is MeshInstance3D: child.visible = false
							var s = load(dem_path)
							if s:
								var inst = s.instantiate()
								inst.name = "DemolishedModel"
								# 毁坏模型也要按国家/队伍色染色，和正常模型保持一致
								if info.get("type", -1) != 0:
									var info_color = _get_entity_color(info)
									var lt = Color(0.5 + info_color.r * 0.5, 0.5 + info_color.g * 0.5, 0.5 + info_color.b * 0.5)
									_apply_model_tint(inst, lt)
								# 毁坏模型随本体一起放大，否则塔倒后残骸会明显偏小
								if eid == 41: inst.scale = Vector3.ONE * (0.5 * RTSConfig.get_model_scale(eid))
								node.add_child(inst)
							var t = Timer.new(); t.one_shot = true; t.wait_time = 0.3
							t.timeout.connect(node.queue_free); node.add_child(t); t.start()
						else:
							node.queue_free()
						entity_nodes.erase(id)
			_remove_all_bars(id)

			if has_meta("_wp_markers"):
				var all_wp = get_meta("_wp_markers")
				if all_wp.has(id):
					for m in all_wp[id]:
						if is_instance_valid(m): m.queue_free()
					all_wp.erase(id)

	# 兜底清理：全量快照里缺失的己方实体一律删除（防止死亡 ID 丢失导致残留尸体）
	if is_full_snap:
		_prune_missing_own_entities(full_ids)
	var my_res = {}
	var my_limits = {}
	var my_pop = last_population

	if data.has("player_resources") and my_peer_id != -1:
		my_res = data["player_resources"].get(my_peer_id, last_resources)
		my_pop = data.get("player_population", {}).get(my_peer_id, last_population)
		my_limits = data.get("player_limits", {}).get(my_peer_id, last_limits)
	elif data.has("resources"):
		my_res = data["resources"]["player"] if player_team == RTSConfig.Team.BLUE else data["resources"]["enemy"]
		my_pop = data["population"]
		my_limits = data.get("limits", {}).get("player" if player_team == RTSConfig.Team.BLUE else "enemy", {})

	# 保存最新资源（仅当快照包含资源数据时才更新缓存）
	if data.has("player_resources") or data.has("resources"):
		last_resources = my_res
		last_limits = my_limits
	last_population = my_pop
		# Debug: log first few snapshots
	if _diag_snap_count <= 5:
		print("[Snapshot#%d] team=%d peer=%d pop=%s res_keys=%s" % [_diag_snap_count, player_team, my_peer_id, str(my_pop), str(my_res.keys())])

	# ---- HUD 更新 ----
	var gather_counts = data.get("gather_counts", {})
	var income_rate = data.get("income_rate", {})
	# Unwrap peer_id-keyed data for 2v2 mode
	if my_peer_id != -1:
		gather_counts = gather_counts.get(my_peer_id, {})
		income_rate = income_rate.get(my_peer_id, {})
	if has_node("UI/HUD") and not my_res.is_empty():
		$UI/HUD.update_data(my_res, my_pop, my_limits, gather_counts, income_rate)

	# ---- InfoPanel 资源（仅当有资源数据时更新） ----
	if has_node("UI/InfoPanel") and not my_res.is_empty():
		$UI/InfoPanel.set_resources(my_res, my_limits, my_pop)

	# ---- 国家信息 ----
	if has_node("UI/HUD"):
		if data.has("nation"):
			my_nation = data["nation"] if player_team == RTSConfig.Team.BLUE else data.get("enemy_nation", -1)
			var enemy_nation = data.get("enemy_nation", -1) if player_team == RTSConfig.Team.BLUE else data["nation"]
			$UI/HUD.set_nations(my_nation, enemy_nation)
		elif data.has("team_nations") and my_team != -1:
			my_nation = data["team_nations"].get(my_team, -1)
			var my_team_nation = my_nation
			var enemy_team = RTSConfig.Team.RED if my_team == RTSConfig.Team.BLUE else RTSConfig.Team.BLUE
			var enemy_nation = data["team_nations"].get(enemy_team, -1)
			$UI/HUD.set_nations(my_team_nation, enemy_nation)

	# ---- 子弹 ----
	# ---- 服务器警报 ----
	if data.has("alerts"):
		var alerts = data["alerts"]
		if alerts is Array and alerts.size() > 0:
			var hud = get_node_or_null("UI/HUD")
			for alert in alerts:
				if hud and hud.has_method("show_alert_message"):
					hud.show_alert_message(alert["msg"], alert.get("color", Color(1.0, 0.2, 0.1)))

	if data.has("bullets"):
		var server_ids = {}
		var new_bullets = []
		for b in data["bullets"]:
			if not b.has("id") or not b.has("x"): continue
			var id = b["id"]
			server_ids[id] = b.get("entity_id", -1)
			var node = entity_nodes.get(id)
			# New bullet created → play shoot sound
			if not _prev_bullet_ids.has(id) and not node:
				var bpos = Vector3(b["x"], b["y"], b["z"])
				if _is_audible(bpos):
					var eid = b.get("entity_id", -1)
					var cam = _get_cam_pos()
					if eid == 12 or eid == 31 or eid == 37:
						AudioManager.play_sfx_3d("arrow_shoot", bpos, cam)
					elif eid == 16 or eid == 39:
						AudioManager.play_sfx_3d("cannon_fire", bpos, cam)
					elif eid == 17:
						AudioManager.play_sfx_3d("treb_fire", bpos, cam)
					else:
						AudioManager.play_sfx_3d("arrow_shoot", bpos, cam)
			if not node:
				node = _create_bullet_node(b)
				entity_nodes[id] = node
			var new_pos = Vector3(b["x"], b["y"], b["z"])
			# 用与上一快照位置的差确定飞行朝向，让箭模型指向运动方向
			if node.has_meta("prev_pos"):
				var dir = new_pos - node.get_meta("prev_pos")
				if dir.length_squared() > 0.0001:
					var up = Vector3.UP if absf(dir.y) < 0.99 * dir.length() else Vector3.FORWARD
					node.look_at(new_pos + dir, up)
			node.set_meta("prev_pos", new_pos)
			node.global_position = new_pos
			node.visible = true

		for id in entity_nodes.keys():
			var n = entity_nodes[id]
			if n.has_meta("is_bullet") and not server_ids.has(id):
				# Bullet destroyed → play hit sound
				if _is_audible(n.global_position):
					var eid2 = _prev_bullet_ids.get(id, -1)
					var cam = _get_cam_pos()
					if eid2 == 16 or eid2 == 39:
						AudioManager.play_sfx_3d("cannon_hit", n.global_position, cam)
					elif eid2 == 17:
						AudioManager.play_sfx_3d("treb_hit", n.global_position, cam)
					else:
						AudioManager.play_sfx_3d("arrow_hit", n.global_position, cam)
				n.queue_free()
				entity_nodes.erase(id)
		_prev_bullet_ids = server_ids
# ==================== 实体创建与更新 ====================
func _rebuild_building_info(d: Dictionary):
	var cfg = EntityDatabase.get_config(d["entity_id"])
	if cfg.is_empty(): return
	var upgrades = cfg.get("upgrades", [])
	var lv = d.get("upgrade_level", 1)
	if lv <= upgrades.size():
		d["get_upgrade_cost"] = upgrades[lv - 1].get("cost", {}).duplicate()
	else:
		d["get_upgrade_cost"] = {}
	d["castle_level_required"] = cfg.get("castle_level_required", 0)
	var produces = cfg.get("produces", [])
	if not produces:
		d["production_list"] = []
		return
	var pl = []
	lv = d.get("upgrade_level", 1)
	for i in range(min(lv, produces.size())):
		var prod = produces[i].duplicate()
		var unit_cfg = EntityDatabase.get_config(prod.unit_id)
		var base_cost = unit_cfg.get("cost", {})
		var scaled = {}
		for res in base_cost:
			scaled[res] = int(base_cost[res] * (1.0 + (lv - 1) * 0.2))
		prod["current_cost"] = scaled
		pl.append(prod)
	# Add nation-specific units (matching server _unlock_nation_units)
	# 国家特色单位只由城堡(53)生产，主城(20)不再产
	if my_nation >= 0 and d.get("entity_id", 0) == 53:
		NationData._static_init()
		var nation_units = NationData.NATION_UNITS.get(my_nation, [])
		for nu in nation_units:
			if nu["unit_id"] == 10: continue
			var already = false
			for ep in pl:
				if ep.unit_id == nu["unit_id"]: already = true; break
			if not already:
				var np = {"unit_id": nu["unit_id"], "cooldown": nu.get("cooldown", 5.0), "queue_limit": nu.get("queue_limit", 5)}
				var uc2 = EntityDatabase.get_config(nu["unit_id"])
				var bc2 = uc2.get("cost", {})
				var sc2 = {}
				for rk in bc2: sc2[rk] = int(bc2[rk] * (1.0 + (lv - 1) * 0.2))
				np["current_cost"] = sc2
				pl.append(np)
	d["production_list"] = pl

func _update_single_entity(info):
	# Convert compact Array format to Dictionary
	var ap_unchanged := false
	if info is Array:
		var arr = info
		if arr.size() < E.size(): return
		ap_unchanged = arr.size() > E.ASTAR_PATH and arr[E.ASTAR_PATH] == null
		info = {
			"id": arr[E.ID], "entity_id": arr[E.EID], "type": arr[E.TYPE],
			"team": arr[E.TEAM], "x": arr[E.X], "y": arr[E.Y], "z": arr[E.Z],
			"health": arr[E.HEALTH], "max_health": arr[E.MAX_HEALTH],
				"attack": arr[E.ATTACK], "attack_speed": arr[E.ATTACK_SPEED] if arr.size() > E.ATTACK_SPEED else 1.0,
				"melee_armor": arr[E.MELEE_ARMOR], "shield_armor": arr[E.SHIELD_ARMOR],
			"vision_range": arr[E.VISION], "body_radius": arr[E.BODY_R],
			"target_type": arr[E.TARGET_TYPE], "owner_peer_id": arr[E.OWNER],
			"level": arr[E.LEVEL], "current_order": arr[E.ORDER],
			"hold_position": arr[E.HOLD], "name": arr[E.NAME],
			"rotation_y": arr[E.ROT_Y] if arr.size() > E.ROT_Y else 0.0,
			"waypoints": arr[E.WAYPOINTS] if arr.size() > E.WAYPOINTS and arr[E.WAYPOINTS] is Array else [],
			# 服务端路径增量：null = 未变化，沿用旧路径（否则每帧重发整条 A* 路径太占带宽）
			"astar_path": arr[E.ASTAR_PATH] if arr.size() > E.ASTAR_PATH and arr[E.ASTAR_PATH] is Array else [],
			"is_garrisoned": arr[E.GARRISONED] if arr.size() > E.GARRISONED else false,
			"nation": arr[E.NATION] if arr.size() > E.NATION else -1,
			"in_action_range": arr[E.IN_ACTION_RANGE] if arr.size() > E.IN_ACTION_RANGE else 0,
		}
		# Building extras
		if arr.size() > E.size() and arr[E.size()] is Array:
			var ba = arr[E.size()]
			if ba.size() >= EB.size():
				info["upgrade_level"] = ba[EB.UPGRADE]
				info["max_upgrade_level"] = ba[EB.MAX_UPGRADE]
				info["can_upgrade"] = ba[EB.CAN_UPGRADE]
				info["build_timer"] = ba[EB.BUILD_TIMER]
				info["max_build_time"] = ba[EB.MAX_BUILD]
				info["production_current_unit"] = ba[EB.PROD_CURRENT]
				info["production_progress"] = ba[EB.PROD_PROGRESS]
				info["production_queue_size"] = ba[EB.PROD_QSIZE]
				info["upgrade_timer"] = ba[EB.UPGRADE_TIMER]
				info["max_upgrade_time"] = ba[EB.MAX_UPGRADE_TIME]
				info["garrisoned_soldier_count"] = ba[EB.GARRISON_COUNT] if ba.size() > EB.GARRISON_COUNT else 0
		_rebuild_building_info(info)
	if not info.has("id") or not info.has("x") or not info.has("z"):
		return
	var id = info["id"]
	var node = entity_nodes.get(id)
	if not node:
		node = _create_entity_node(info)
		entity_nodes[id] = node
		# New building placed → play placement sound
		if info.get("type") == 1 and _is_audible(node.global_position):
			AudioManager.play_sfx_3d("build_place", node.global_position, _get_cam_pos())
	elif node.has_meta("snapshot_info") and int(node.get_meta("snapshot_info").get("team", -99)) != int(info.get("team", -99)):
		# 中立废弃建筑被占领：队伍变了，重建节点以刷新队伍色/血条颜色
		entity_nodes.erase(id)
		node.queue_free()
		node = _create_entity_node(info)
		entity_nodes[id] = node
	# 路径未变化（服务端发 null）：沿用上一次收到的路径，避免每帧重建标记
	if ap_unchanged and node.has_meta("snapshot_info"):
		var prev_ap = node.get_meta("snapshot_info").get("astar_path", [])
		info["astar_path"] = prev_ap
	# Smooth position interpolation to reduce jitter/flashing
	var target = Vector3(info["x"], info["y"], info["z"])
	if node.has_meta("_prev_pos"):
		var prev = node.get_meta("_prev_pos")
		var dist = target.distance_to(prev)
		if dist > 10.0: prev = target  # teleport if too far
		# 时间基准插值：按真实经过时间计算收敛系数，快照间隔拉长（丢包/relay 抖动）时
		# 自动加速收敛，避免固定 0.3 系数造成的滞后放大（原方案在 300ms 间隔下滞后约 1 秒）
		var now_ms = Time.get_ticks_msec()
		var prev_ms = node.get_meta("_prev_interp_ms", now_ms - 40)
		var dt = maxf(0.001, float(now_ms - prev_ms) / 1000.0)
		var t = 1.0 - exp(-dt * 12.0)   # 收敛常数 12/s（时间常数 ≈ 83ms）
		node.global_position = prev.lerp(target, t)
		node.set_meta("_prev_interp_ms", now_ms)
	else:
		node.global_position = target
		node.set_meta("_prev_interp_ms", Time.get_ticks_msec())
	node.set_meta("_prev_pos", node.global_position)
	node.rotation.y = info.get("rotation_y", 0.0)
	node.visible = _should_entity_be_visible(info)
	node.set_meta("snapshot_info", info)
	# Client-side sound effects (detect state transitions, visible entities only)
	var prev_info = node.get_meta("_prev_info") if node.has_meta("_prev_info") else {}
	if not prev_info.is_empty() and _is_audible(node.global_position):
		# Build done
		if prev_info.get("build_timer", 0) > 0 and info.get("build_timer", 0) <= 0:
			AudioManager.play_sfx_3d("build_done", node.global_position, _get_cam_pos())
		# Upgrade done
		if prev_info.get("upgrade_timer", 0) > 0 and info.get("upgrade_timer", 0) <= 0:
			AudioManager.play_sfx_3d("upgrade_done", node.global_position, _get_cam_pos())
		# Production finished (progress was >0, now 0)
		var prev_prog = prev_info.get("production_progress")
		var new_prog = info.get("production_progress")
		if prev_prog != null and new_prog != null and prev_prog > 0 and new_prog <= 0:
			AudioManager.play_sfx_3d("produce", node.global_position, _get_cam_pos())

	# 快照状态切换时立即同步动画（不等30帧轮询）
	if not prev_info.is_empty():
		var order_changed: bool = prev_info.get("current_order", "") != info.get("current_order", "")
		var range_changed: bool = int(prev_info.get("in_action_range", 0)) != int(info.get("in_action_range", 0))
		if order_changed or range_changed:
			_update_entity_animation(node, info)
	node.set_meta("_prev_info", info.duplicate())
	# Update waypoint markers if present
	_update_waypoint_markers(node, info)

# 在 ClientRenderer.gd 类顶部确保存在以下变量
  # peer_id -> Color

# ---------- 替换原有的 _create_entity_node ----------
# 递归给模型所有Mesh设置颜色

# Wall orientation — exact replica of server Building.gd logic
func _update_wall_orientation(wall_node: Node3D, info: Dictionary):
	var has_x_neg = false; var has_x_pos = false
	var has_z_neg = false; var has_z_pos = false
	var r = info.get("body_radius", 1.0)
	var half_len = r * 2.0 * 1.2
	var half_wid = r * 0.8
	var my_pos = wall_node.global_position
	for id in entity_nodes.keys():
		var other = entity_nodes.get(id)
		if other == wall_node or not is_instance_valid(other): continue
		if not other.has_meta("snapshot_info"): continue
		var oi = other.get_meta("snapshot_info")
		if oi.get("entity_id", 0) != 27: continue
		if oi.get("health", 0) <= 0: continue
		var d = other.global_position - my_pos
		if abs(d.z) <= half_len and abs(d.x) < half_wid:
			if d.z < 0: has_z_neg = true
			else: has_z_pos = true
		if abs(d.x) <= half_len and abs(d.z) < half_wid:
			if d.x < 0: has_x_neg = true
			else: has_x_pos = true
	
	var has_x = has_x_neg or has_x_pos
	var has_z = has_z_neg or has_z_pos
	var is_corner = has_x and has_z  # corner only when both axes have neighbors
	
	# Model switch
	var old_is_corner = wall_node.has_meta("_wall_is_corner") and wall_node.get_meta("_wall_is_corner")
	if is_corner != old_is_corner:
		wall_node.set_meta("_wall_is_corner", is_corner)
		var path = "res://models/castle/wall-corner.glb" if is_corner else "res://models/castle/wall.glb"
		if ResourceLoader.exists(path):
			for child in wall_node.get_children():
				if child is MeshInstance3D and child.name != "SelectionRing":
					child.queue_free()
			var s = load(path)
			if s:
				var inst = s.instantiate()
				if inst:
					var target_size = r * 2.0
					var aabb = _get_model_aabb(inst)
					var cs = max(aabb.size.x, max(aabb.size.y, aabb.size.z))
					if cs > 0.01: inst.scale = Vector3.ONE * (target_size / cs)
					wall_node.add_child(inst)
	
	# Rotation — matches server exactly
	if is_corner:
		if has_x_neg and has_z_neg: wall_node.rotation.y = deg_to_rad(90 + 180)
		elif has_x_pos and has_z_neg: wall_node.rotation.y = deg_to_rad(180 + 180)
		elif has_x_pos and has_z_pos: wall_node.rotation.y = deg_to_rad(270 + 180)
		elif has_x_neg and has_z_pos: wall_node.rotation.y = deg_to_rad(0 + 180)
	elif has_x_neg or has_x_pos: wall_node.rotation.y = deg_to_rad(90)
	else: wall_node.rotation.y = 0

func _get_model_aabb(node: Node) -> AABB:
	var result = AABB()
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh:
			var caabb = child.mesh.get_aabb()
			caabb.position += child.position
			result = result.merge(caabb)
		var cr = _get_model_aabb(child)
		if cr.has_volume():
			result = result.merge(cr)
	return result

func _update_entity_animation(node: Node3D, info: Dictionary):
	var ap: AnimationPlayer = node.get_meta("_anim_player", null)
	if not is_instance_valid(ap):
		ap = AnimationHelper.find_player(node)
		if ap != null:
			node.set_meta("_anim_player", ap)
	if not ap: return
	var anim = ""
	var ord = info.get("current_order", "")
	if info.get("health", 0) <= 0:
		anim = "die"
	elif ord in ["attack", "attack_move", "gather"]:
		# 锁定目标后还要先走到攻击/采集距离；服务端在快照里标记是否已进入距离。
		# 追击途中播放走路，进入距离后才播放攻击/采集动作。
		var in_range := int(info.get("in_action_range", 0)) == 1
		anim = "attack-melee-left" if in_range else "walk"
	elif ord in ["move", "deliver"]:
		anim = "walk"
	else:
		anim = "idle"
	if anim != "" and ap.has_animation(anim):
		var spd := 1.0
		if anim == "attack-melee-left":
			var atk_raw = info.get("attack_speed", 1.0)
			var atk_spd := float(atk_raw) if atk_raw != null else 1.0
			spd = AnimationHelper.attack_speed_scale(ap, anim, atk_spd)
		elif anim == "walk":
			var mv_raw = info.get("speed", 2.0)
			var mv_spd := float(mv_raw) if mv_raw != null else 2.0
			spd = clampf(mv_spd * 0.6, 0.2, 3.0)
		ap.speed_scale = spd
		if ap.current_animation != anim:
			ap.play(anim)

func _apply_model_tint(node: Node, tint: Color):
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh:
			for si in child.mesh.get_surface_count():
				var src = child.get_active_material(si)
				if src:
					# 复制原材质以保留 GLB 的法线/粗糙度/金属度等属性；
					# 直接 new StandardMaterial3D 会丢掉这些贴图，模型看起来会变成扁平色块
					var mat = src.duplicate()
					if "albedo_color" in mat:
						mat.albedo_color = src.albedo_color.lerp(tint, 0.5)
					if "shading_mode" in mat:
						mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
					child.set_surface_override_material(si, mat)
				else:
					var mat2 = StandardMaterial3D.new()
					mat2.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
					mat2.albedo_color = tint
					child.set_surface_override_material(si, mat2)
		_apply_model_tint(child, tint)

# 模型需要投射/接收实时阴影，否则光影层次会明显变弱
func _ensure_model_shadows(node: Node) -> void:
	if node is MeshInstance3D:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	for child in node.get_children():
		_ensure_model_shadows(child)

func _tint_preview(node: Node, color: Color):
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh:
			for si in child.mesh.get_surface_count():
				var src = child.get_active_material(si)
				if src and "albedo_color" in src:
					var m = src.duplicate()
					m.albedo_color = src.albedo_color.lerp(color, 0.5)
					child.set_surface_override_material(si, m)
		_tint_preview(child, color)

func _set_unshaded_recursive(node: Node):
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh:
			for si in child.mesh.get_surface_count():
				var src = child.get_active_material(si)
				if src and "shading_mode" in src:
					var m = src.duplicate()
					m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
					child.set_surface_override_material(si, m)
		_set_unshaded_recursive(child)

func _apply_model_color(node: Node, c: Color):
	for child in node.get_children():
		if child is MeshInstance3D:
			var m = StandardMaterial3D.new()
			m.albedo_color = c
			m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			child.material_override = m
		_apply_model_color(child, c)

# 死亡时是否播放沉水动画：船只（9/13/14/39/40）和落水身亡的陆地单位。
# 桥面、浅滩不算落水；客户端已先从 entity_nodes 移除该节点，动画期间不可选中。
func _should_sink_entity(info: Dictionary, node: Node3D) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if int(info.get("type", -1)) != 2:
		return false
	var pos: Vector3 = node.global_position
	if get_terrain_at(pos) != 2:
		return false
	var map = get_node_or_null("Map")
	if map and map.has_method("get_overlay"):
		var gx := int(pos.x + RTSConfig.MAP_SIZE / 2.0)
		var gz := int(pos.z + RTSConfig.MAP_SIZE / 2.0)
		if map.get_overlay(gx, gz) == 3:
			return false
	if _is_bridge_at_client(pos):
		return false
	var eid := int(info.get("entity_id", -1))
	if eid in [9, 13, 14, 39, 40]:
		return true
	var cfg: Dictionary = EntityDatabase.get_config(eid)
	if bool(cfg.get("water_capable", false)):
		return false
	return true

func _is_bridge_at_client(pos: Vector3) -> bool:
	var gx := int(pos.x + RTSConfig.MAP_SIZE / 2.0)
	var gz := int(pos.z + RTSConfig.MAP_SIZE / 2.0)
	for n in entity_nodes.values():
		if not is_instance_valid(n) or not n.has_meta("snapshot_info"):
			continue
		var oi: Dictionary = n.get_meta("snapshot_info")
		if int(oi.get("type", -1)) != 1 or int(oi.get("entity_id", -1)) != 7:
			continue
		if int(oi.get("health", 0)) <= 0:
			continue
		var bx := int(n.global_position.x + RTSConfig.MAP_SIZE / 2.0)
		var bz := int(n.global_position.z + RTSConfig.MAP_SIZE / 2.0)
		if bx == gx and bz == gz:
			return true
	return false

func _play_sink_animation(node: Node3D, info: Dictionary) -> void:
	if node == null or not is_instance_valid(node):
		return
	var body = node.get_node_or_null("ClickableBody")
	if body:
		body.collision_layer = 0
		body.collision_mask = 0
	for child in node.get_children():
		if child is CollisionShape3D:
			child.set_deferred("disabled", true)
	var sink_depth := maxf(2.0, float(info.get("body_radius", 0.5)) * 4.0)
	var tween := node.create_tween()
	tween.set_parallel(true)
	var down_tw = tween.tween_property(node, "global_position:y", node.global_position.y - sink_depth, 1.0)
	down_tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	var roll_tw = tween.tween_property(node, "rotation:z", node.rotation.z + deg_to_rad(18.0), 1.0)
	roll_tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.chain().tween_callback(node.queue_free)

func _create_entity_node(info: Dictionary) -> Node3D:
	if not info.has("body_radius") or not info.has("type") or not info.has("team"):
		return Node3D.new()
	var entity = Node3D.new()
	var body = StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.name = "ClickableBody"
	body.set_meta("entity_root", entity)
	entity.add_child(body)

	var col_shape = CollisionShape3D.new()
	var r = info["body_radius"]
	if info["type"] == 1:
		var box = BoxShape3D.new()
		box.size = Vector3(r*2, r*1.5, r*2)
		col_shape.shape = box
	else:
		var sphere = SphereShape3D.new()
		if info["type"] == 0: sphere.radius = r * 1.2  # 增大碰撞范围，匹配3D模型的视觉大小
		else: sphere.radius = r
		col_shape.shape = sphere
	body.add_child(col_shape)

	# 获取实体颜色：统一使用 player_colors 按 owner_peer_id 着色（血条/模型一致）
	var entity_color = _get_entity_color(info)
	var owner_id = info.get("owner_peer_id", -1)

	# 模型
	var mesh: MeshInstance3D
	var eid = info.get("entity_id", 0)
	# 尝试加载3D模型
	var model_path = RTSConfig.get_entity_model(eid)
	var loaded_model = null
	if model_path != "" and ResourceLoader.exists(model_path):
		var model_scene = load(model_path)
		if model_scene: loaded_model = model_scene.instantiate()

	if loaded_model:
		# Scale model to match entity body_radius（再乘特殊体型系数，与服务端一致）
		var target_size = info["body_radius"] * 2.0 * RTSConfig.get_model_scale(eid)
		var aabb = _get_model_aabb(loaded_model)
		var current_size = max(aabb.size.x, max(aabb.size.y, aabb.size.z))
		var scale_factor := 1.0
		if current_size > 0.01:
			scale_factor = target_size / current_size
			loaded_model.scale = Vector3.ONE * scale_factor
		# Special rotations
		if info.get("entity_id", 0) == 16: loaded_model.rotation.y = deg_to_rad(180)
		elif info.get("entity_id", 0) == 17: loaded_model.rotation.y = deg_to_rad(90)
		elif info.get("entity_id", 0) == 18: loaded_model.rotation.y = deg_to_rad(90)
		elif info.get("entity_id", 0) == 59:
			# 巨型投石机：与服务端一致，顺时针旋转 90°
			loaded_model.rotation.y = deg_to_rad(-90)
		elif info.get("entity_id", 0) == 64:
			# 炮台：顺时针旋转 90°，并按模型高度下移 30%，与服务端保持一致
			loaded_model.rotation.y = deg_to_rad(-90)
			loaded_model.position.y -= aabb.size.y * scale_factor * 0.3
		# character 与步兵模型默认朝向相反，统一绕 Y 轴旋转 180° 掉头（entity 10 原特例已并入）
		if RTSConfig.model_needs_flip(model_path):
			loaded_model.rotation.y = deg_to_rad(180)
		# 炮塔/箭塔尺寸统一走 RTSConfig.ENTITY_MODEL_SCALE，避免联机端与服务端不一致
		# 诸葛连弩保持原有放大倍率
		if info.get("entity_id", 0) == 33:
			loaded_model.scale *= 2.0
			loaded_model.scale *= 1.5
			loaded_model.scale *= 1.5
		entity.add_child(loaded_model)
		_ensure_model_shadows(loaded_model)
		# GLB 动画默认不循环；缓存 AnimationPlayer 并配置 idle/walk/attack 循环
		var cached_ap := AnimationHelper.configure_loops(loaded_model)
		if cached_ap != null:
			entity.set_meta("_anim_player", cached_ap)
		# 队伍色着色
		if info.get("type", -1) != 0:
			var lt = Color(0.5 + entity_color.r * 0.5, 0.5 + entity_color.g * 0.5, 0.5 + entity_color.b * 0.5)
			_apply_model_tint(loaded_model, lt)
		# Weapons and mounts (match server Army._add_weapon)
		var eid2 = info.get("entity_id", 0)
		var br = info.get("body_radius", 0.5)
		if eid2 in [12, 31, 37] and ResourceLoader.exists("res://models/forest/weapon-bow.glb"):
			var ws = load("res://models/forest/weapon-bow.glb")
			if ws: var w = ws.instantiate(); if w: w.position = Vector3(br*1.2, br*0.4, 0); w.scale = Vector3.ONE; w.rotation_degrees = Vector3(0, 180, 0); entity.add_child(w)
		if eid2 == 35 and ResourceLoader.exists("res://models/arena/weapon-spear.glb"):
			var ws = load("res://models/arena/weapon-spear.glb")
			if ws: var w = ws.instantiate(); if w: w.position = Vector3(br*1.2, br*0.4, 0); entity.add_child(w)
		if eid2 in [11, 15, 19, 30, 32, 34, 36, 38, 65, 66] and ResourceLoader.exists("res://models/arena/weapon-sword.glb"):
			var ws = load("res://models/arena/weapon-sword.glb")
			if ws: var w = ws.instantiate(); if w: w.position = Vector3(br*1.2, br*0.4, 0); w.scale = Vector3.ONE; entity.add_child(w)
		if eid2 in [36, 37, 38] and ResourceLoader.exists("res://models/arena/shield-round.glb"):
			var sh = load("res://models/arena/shield-round.glb")
			if sh: var s = sh.instantiate(); if s: s.position = Vector3(-0.3, br*0.6, 0); s.scale = Vector3.ONE*0.8; entity.add_child(s)
		var mpath = ""
		if eid2 in [15, 19, 38, 66]: mpath = "res://models/pets/animal-dog.glb"
		elif eid2 == 34: mpath = "res://models/pets/animal-elephant.glb"
		if mpath != "" and ResourceLoader.exists(mpath):
			var ms = load(mpath)
			if ms: var m = ms.instantiate(); if m: m.position = Vector3(0, -br*1.2, 0); m.scale = Vector3.ONE*0.7; entity.add_child(m)
	else:
		# 回退：程序化网格
		match info["type"]:
			0: # 资源
				mesh = MeshInstance3D.new()
				mesh.mesh = SphereMesh.new()
				mesh.mesh.radius = r
				var mat = StandardMaterial3D.new()
				match info["entity_id"]:
					0: mat.albedo_color = Color.YELLOW
					1: mat.albedo_color = Color(0.3,0.8,0.2)
					2: mat.albedo_color = Color.GRAY
					3: mat.albedo_color = Color.SADDLE_BROWN
					4: mat.albedo_color = Color.BLACK
				mesh.material_override = mat
			1: # 建筑
				mesh = MeshInstance3D.new()
				var box = BoxMesh.new()
				box.size = Vector3(r*2, r*1.5, r*2)
				mesh.mesh = box
				var mat = StandardMaterial3D.new()
				mat.albedo_color = entity_color
				mesh.material_override = mat
			2: # 军队
				mesh = MeshInstance3D.new()
				var cap = CapsuleMesh.new()
				cap.radius = r*0.8
				cap.height = r*2.5
				mesh.mesh = cap
				var mat = StandardMaterial3D.new()
				mat.albedo_color = entity_color
				mesh.material_override = mat
		if mesh:
			entity.add_child(mesh)

	# 存储 owner_peer_id 元数据，供后续使用
	entity.set_meta("owner_peer_id", owner_id)
	entities_container.add_child(entity)
	return entity

# ---------- 替换原有的 _create_bullet_node ----------
func _create_bullet_node(info: Dictionary) -> Node3D:
	var n = Node3D.new()
	n.set_meta("is_bullet", true)
	# Try loading actual bullet model (matches server Bullet.gd)
	var eid = info.get("entity_id", -1)
	var dmg_r = float(info.get("damage_radius", 0.0))
	var loaded = false
	# Match server Bullet._ready logic exactly
	# 投石车(17)/巨型投石机(59) 用巨石；火炮(16)/炮艇(39)/炮塔(26) 用炮弹；其余用箭
	if dmg_r > 0 or eid in [16, 17, 26, 39]:
		if eid in [17, 59] and ResourceLoader.exists("res://models/defense/weapon-ammo-boulder.glb"):
			var boulder_scene = load("res://models/defense/weapon-ammo-boulder.glb")
			if boulder_scene:
				var boulder = boulder_scene.instantiate()
				if boulder:
					boulder.scale = Vector3.ONE * (3.5 if eid == 59 else 2.5)
					n.add_child(boulder)
					loaded = true
		elif ResourceLoader.exists("res://models/pirate/cannon-ball.glb"):
			var ball_scene = load("res://models/pirate/cannon-ball.glb")
			if ball_scene:
				var ball = ball_scene.instantiate()
				if ball:
					n.add_child(ball)
					loaded = true
	if not loaded and ResourceLoader.exists("res://models/forest/weapon-arrow.glb"):
		var arrow_scene = load("res://models/forest/weapon-arrow.glb")
		if arrow_scene:
			var arrow = arrow_scene.instantiate()
			# 模型自身箭头朝向与飞行方向相反，绕 Y 轴掉头 180°
			if arrow:
				arrow.scale = Vector3.ONE
				arrow.rotation.y = deg_to_rad(180)
				n.add_child(arrow)
				loaded = true
	if not loaded:
		var mesh = MeshInstance3D.new()
		var s = SphereMesh.new()
		s.radius = 0.25
		mesh.mesh = s
		var mat = StandardMaterial3D.new()
		var owner_id = info.get("owner_peer_id", -1)
		if owner_id != -1 and player_colors.has(owner_id):
			mat.albedo_color = player_colors[owner_id]
		else:
			mat.albedo_color = Color.RED if info["team"] == RTSConfig.Team.BLUE else Color.BLUE
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mesh.material_override = mat
		n.add_child(mesh)
	entities_container.add_child(n)
	return n
func on_map_size_changed():
	_init_fog_grids()

func _init_fog_grids():
	local_explored_grid.clear()
	local_visible_grid.clear()
	for x in range(RTSConfig.MAP_SIZE):
		var exp_col = []
		var vis_col = []
		for y in range(RTSConfig.MAP_SIZE):
			exp_col.append(false)
			vis_col.append(false)
		local_explored_grid.append(exp_col)
		local_visible_grid.append(vis_col)

	

	# 后续迷雾计算...
# ==================== 战争迷雾 ====================

func _start_fog_cycle():
	# 尺寸检查
	if local_explored_grid.size() != RTSConfig.MAP_SIZE or local_visible_grid.size() != RTSConfig.MAP_SIZE:
		_init_fog_grids()
	if local_explored_grid.size() > 0 and local_explored_grid[0].size() != RTSConfig.MAP_SIZE:
		_init_fog_grids()

	# 收集己方单位
	fog_units_queue.clear()
	for node in entity_nodes.values():
		if not node.has_meta("snapshot_info"): continue
		var info = node.get_meta("snapshot_info")
		if not info or info.get("health", 0) <= 0: continue
		var belongs = false
		if my_team != -1:
			belongs = (info["team"] == my_team)
		elif player_team != -1:
			belongs = (info["team"] == player_team)
		if belongs:
			fog_units_queue.append(node)

	# 清除本帧可见性（一次性操作）
	var false_row = []
	false_row.resize(RTSConfig.MAP_SIZE)
	false_row.fill(false)
	for x in range(RTSConfig.MAP_SIZE):
		local_visible_grid[x] = false_row.duplicate()

	if fog_units_queue.is_empty():
		# 没有己方单位，直接完成
		var map = get_node_or_null("Map")
		if map and map.has_method("apply_fog") and not map.base_colors.is_empty():
			map.apply_fog(local_explored_grid, local_visible_grid)
	else:
		fog_cycle_active = true

func _process_fog_batch() -> bool:
	# 返回 true 表示本轮迷雾计算全部完成
	if not fog_cycle_active:
		return false

	var processed = 0
	while fog_units_queue.size() > 0 and processed < fog_batch_size:
		var node = fog_units_queue.pop_front()
		if not is_instance_valid(node):
			continue
		var info = node.get_meta("snapshot_info")
		if not info:
			continue
		var gx = int(info["x"] + RTSConfig.MAP_SIZE / 2)
		var gz = int(info["z"] + RTSConfig.MAP_SIZE / 2)
		var vision = _effective_vision(info)
		for dx in range(-vision, vision + 1):
			for dz in range(-vision, vision + 1):
				if dx*dx + dz*dz > vision*vision: continue
				var nx = gx + dx
				var nz = gz + dz
				if nx >= 0 and nx < RTSConfig.MAP_SIZE and nz >= 0 and nz < RTSConfig.MAP_SIZE:
					local_visible_grid[nx][nz] = true
					local_explored_grid[nx][nz] = true
		processed += 1

	if fog_units_queue.size() == 0:
		# 全部完成，应用到地面纹理
		fog_cycle_active = false
		var map = get_node_or_null("Map")
		if map and map.has_method("apply_fog") and not map.base_colors.is_empty():
			map.apply_fog(local_explored_grid, local_visible_grid)
		return true
	return false

func _update_local_fog():
	# 兼容旧接口：启动增量迷雾周期
	_start_fog_cycle()
# 选中变化时立即刷新路径球/航点：不等下一次快照，避免“选中后看不到 A* 路径球”
func _refresh_waypoint_markers(ids: Array):
	if not has_meta("_wp_markers"):
		if ids.is_empty(): return
		set_meta("_wp_markers", {})
	var all_wp = get_meta("_wp_markers")
	var keep := {}
	for id in ids: keep[id] = true
	for eid in all_wp.keys().duplicate():
		if keep.has(eid): continue
		for m in all_wp[eid]:
			if is_instance_valid(m): m.queue_free()
		all_wp.erase(eid)
	for id in ids:
		var node = entity_nodes.get(id)
		if node and node.has_meta("snapshot_info"):
			_update_waypoint_markers(node, node.get_meta("snapshot_info"))

func _update_waypoint_markers(node: Node3D, info: Dictionary):
	# Only show waypoints for selected entities
	var inp = get_node_or_null("ClientInput")
	var is_selected = false
	if inp and inp.has_method("get_client_selected_ids"):
		is_selected = info["id"] in inp.get_client_selected_ids()
	if not is_selected:
		# Clear any existing markers for this entity
		if has_meta("_wp_markers"):
			var awp = get_meta("_wp_markers")
			if awp.has(info["id"]):
				for m in awp[info["id"]]:
					if is_instance_valid(m): m.queue_free()
				awp.erase(info["id"])
		return

	# Track all waypoint markers globally (keyed by entity instance id)
	if not has_meta("_wp_markers"):
		set_meta("_wp_markers", {})
	var all_wp = get_meta("_wp_markers")
	var eid = info["id"]

	# Clear previous markers for this entity
	if all_wp.has(eid):
		for m in all_wp[eid]:
			if is_instance_valid(m): m.queue_free()
		all_wp.erase(eid)

	var wps = info.get("waypoints", [])
	var apath = info.get("astar_path", [])
	if wps.is_empty() and apath.is_empty(): return

	var new_markers: Array = []
	# Render A* path spheres (green)
	for i in range(apath.size()):
		var awp = apath[i]
		var aworld_pos: Vector3
		if awp is Vector3:
			aworld_pos = awp
		elif awp is Array and awp.size() >= 3:
			aworld_pos = Vector3(awp[0], awp[1], awp[2])
		else:
			aworld_pos = Vector3(awp["x"], awp.get("y", 0), awp["z"])
		var acol = Color(0, 1, 0, 0.9) if i == apath.size() - 1 else Color(0, 1, 1, 0.8)
		var asphere = MeshInstance3D.new()
		var asph = SphereMesh.new(); asph.radius = 0.13; asph.height = 0.26
		asphere.mesh = asph
		asphere.position = aworld_pos + Vector3(0, 1.0, 0)
		var amat = StandardMaterial3D.new()
		amat.albedo_color = acol; amat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		amat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		amat.render_priority = 10; amat.no_depth_test = true
		asphere.material_override = amat
		entities_container.add_child(asphere)
		new_markers.append(asphere)
	for i in range(wps.size()):
		var wp = wps[i]
		var world_pos = Vector3(wp["x"], wp.get("y", 0), wp["z"])
		var is_loop = wp.get("is_loop", false)

		# Last = green, loop = orange, others = cyan
		var is_last = (i == wps.size() - 1)
		var ring_color = Color(0, 1, 0, 0.9) if is_last else (Color(1.0, 0.55, 0.0, 0.9) if is_loop else Color(0, 1, 1, 0.8))
		var pole_color = Color(0, 1, 0, 0.5) if is_last else (Color(1.0, 0.55, 0.0, 0.5) if is_loop else Color(0, 1, 1, 0.5))

		# Vertical pole — world space, child of entities_container
		var pole = MeshInstance3D.new()
		var cyl = CylinderMesh.new()
		cyl.top_radius = 0.08; cyl.bottom_radius = 0.08; cyl.height = 2.0
		pole.mesh = cyl
		pole.position = world_pos + Vector3(0, 1.0, 0)
		var pole_mat = StandardMaterial3D.new()
		pole_mat.albedo_color = pole_color
		pole_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		pole_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		pole_mat.render_priority = 10
		pole_mat.no_depth_test = true
		pole.material_override = pole_mat
		entities_container.add_child(pole)
		new_markers.append(pole)

		# Ring marker — world space, child of entities_container
		var marker = MeshInstance3D.new()
		var ring = TorusMesh.new()
		ring.inner_radius = 0.5; ring.outer_radius = 0.7
		marker.mesh = ring
		marker.position = world_pos + Vector3(0, 2.0, 0)
		var mat = StandardMaterial3D.new()
		mat.albedo_color = ring_color
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.render_priority = 10
		mat.no_depth_test = true
		marker.material_override = mat
		entities_container.add_child(marker)
		new_markers.append(marker)

		# Ground dot at exact click position
		var dot = MeshInstance3D.new()
		var sphere = SphereMesh.new()
		sphere.radius = 0.2; sphere.height = 0.4
		dot.mesh = sphere
		dot.position = world_pos + Vector3(0, 0.2, 0)
		var dot_mat = StandardMaterial3D.new()
		dot_mat.albedo_color = ring_color
		dot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		dot_mat.render_priority = 10
		dot_mat.no_depth_test = true
		dot.material_override = dot_mat
		entities_container.add_child(dot)
		new_markers.append(dot)

		# Number label
		var lbl = Label3D.new()
		lbl.text = str(i + 1); lbl.font_size = 32
		lbl.position = Vector3(0, 0.8, 0); lbl.modulate = Color.GREEN if is_last else (Color(1.0, 0.55, 0.0) if is_loop else Color.CYAN)
		lbl.render_priority = 11
		lbl.no_depth_test = true
		marker.add_child(lbl)

	all_wp[eid] = new_markers

# Control-group label colors (same as HUD)
# Helper: get control-group prefix string for label
func _get_entity_group_prefix(eid: int) -> String:
	var inp = get_node_or_null("ClientInput")
	if not inp or not inp.has_method("get_entity_groups"): return ""
	var groups = inp.get_entity_groups(eid)
	if groups.is_empty(): return ""
	var s = ""
	for g in groups:
		s += "T%d " % g
	return s

# 血条文字里的国家前缀，与单机 HUD 的 _nat_tag() 格式一致
func _get_entity_nation_prefix(info: Dictionary) -> String:
	var nation := int(info.get("nation", -1))
	if nation >= 0 and nation < NATION_LABELS.size():
		return "「%s」" % NATION_LABELS[nation]
	return ""

const GROUP_LABEL_COLORS = {
	1: Color(1.0, 0.3, 0.2),   # Red
	2: Color(0.2, 0.6, 1.0),   # Blue
	3: Color(0.2, 1.0, 0.3),   # Green
	4: Color(1.0, 1.0, 0.2),   # Yellow
	5: Color(1.0, 0.5, 0.0),   # Orange
	6: Color(0.7, 0.3, 1.0),   # Purple
	7: Color(0.0, 1.0, 1.0),   # Cyan
	8: Color(1.0, 0.4, 0.7),   # Pink
	9: Color(0.5, 1.0, 0.5),   # Mint
}

# 实体专属颜色：国家色优先（与服务器 HUD/模型/小地图统一），
# 快照没有 nation 时按 owner_peer_id / 队伍兜底。
func _get_entity_color(info: Dictionary) -> Color:
	var nation: int = int(info.get("nation", -1))
	if nation >= 0 and RTSConfig.has_nation_color(nation):
		return RTSConfig.get_nation_color(nation)
	var owner_id = info.get("owner_peer_id", -1)
	if owner_id != -1 and player_colors.has(owner_id):
		return player_colors[owner_id]
	match info.get("team", -1):
		RTSConfig.Team.BLUE:
			return Color(0.3, 0.5, 1.0)   # 蓝队基础色
		RTSConfig.Team.RED:
			return Color(1.0, 0.25, 0.2)  # 红队基础色
		_:
			return Color(0.7, 0.7, 0.7)   # 中立灰色

# 是否玩家自己的单位：2v2/3v3 按 owner_peer_id，1v1 没有 owner 时按队伍兜底
func _is_own_entity(info: Dictionary) -> bool:
	var oid = int(info.get("owner_peer_id", -1))
	if my_peer_id != -1:
		if oid != -1:
			return oid == my_peer_id
		return int(info.get("team", -1)) == player_team
	if player_team != -1:
		return int(info.get("team", -1)) == player_team
	return false

# 血条标签镶边：玩家自己的单位用绿色，友军/敌军仍用所属国家/阵营色
func _apply_label_nation_outline(lab: Label, info: Dictionary) -> void:
	var outline := Color(0.25, 1.0, 0.35) if _is_own_entity(info) else _get_entity_color(info)
	lab.add_theme_color_override("font_outline_color", outline)
	lab.add_theme_constant_override("outline_size", 3)

# Helper: get color for entity label (by control group first, then owner/team)
func _get_entity_label_color(info: Dictionary) -> Color:
	var eid = info["id"]
	var inp = get_node_or_null("ClientInput")
	if inp and inp.has_method("get_entity_groups"):
		var groups = inp.get_entity_groups(eid)
		if groups.size() > 0 and GROUP_LABEL_COLORS.has(groups[0]):
			return GROUP_LABEL_COLORS[groups[0]]
	
	
	return Color.WHITE

func _should_entity_be_visible(ent: Dictionary) -> bool:
	# 进驻中的单位始终隐藏
	if ent.get("is_garrisoned", false):
		return false
	if ent["team"] == player_team:
		return true
	if ent["team"] == RTSConfig.Team.NEUTRAL:
		var gx = int(ent["x"] + RTSConfig.MAP_SIZE/2)
		var gz = int(ent["z"] + RTSConfig.MAP_SIZE/2)
		if gx<0 or gx>=RTSConfig.MAP_SIZE or gz<0 or gz>=RTSConfig.MAP_SIZE: return false
		return local_explored_grid[gx][gz]
	# 敌方单位
	var gx = int(ent["x"] + RTSConfig.MAP_SIZE/2)
	var gz = int(ent["z"] + RTSConfig.MAP_SIZE/2)
	if gx<0 or gx>=RTSConfig.MAP_SIZE or gz<0 or gz>=RTSConfig.MAP_SIZE: return false
	return local_visible_grid[gx][gz]

func _get_valid_entities() -> Array:
	var arr = []
	for n in entity_nodes.values():
		if n.has_meta("snapshot_info"):
			arr.append(n)
	return arr

# ==================== 血条系统（与单机版风格一致） ====================
# Periodic cleanup of entity nodes that no longer have valid server data
func _cleanup_stale_entities():
	var to_remove = []
	for id in entity_nodes.keys():
		var node = entity_nodes.get(id)
		if not is_instance_valid(node):
			to_remove.append(id)
			continue
		# 子弹没有 snapshot_info，由快照的 bullets 分支单独管理生命周期，
		# 不能在这里清理，否则飞行中的箭会被从字典移除却留在场景里（残留弓箭）
		if node.has_meta("is_bullet"):
			continue
		if not node.has_meta("snapshot_info"):
			to_remove.append(id)
	if to_remove.size() > 0:
		for id in to_remove:
			var node = entity_nodes.get(id)
			if is_instance_valid(node):
				node.queue_free()
			entity_nodes.erase(id)
			_remove_all_bars(id)

# 全量快照兜底清理：己方阵营的实体在任何全量快照里都是完整的（服务端不做视野剔除），
# 因此全量快照中缺失的己方节点就是漏删的"尸体"（快照走 unreliable，
# 死亡 ID 在长时间卡顿/丢包时可能全部丢失）。误删的节点下一帧会重新创建，代价很低。
func _prune_missing_own_entities(seen_ids: Dictionary):
	if player_team == -1: return
	var to_remove = []
	for id in entity_nodes.keys():
		if seen_ids.has(id): continue
		var node = entity_nodes.get(id)
		if not is_instance_valid(node):
			to_remove.append(id)
			continue
		if node.has_meta("is_bullet"): continue  # 子弹不在实体快照里，由 bullets 分支单独清理
		var info = node.get_meta("snapshot_info", null)
		if info and int(info.get("team", -1)) == player_team:
			to_remove.append(id)
	if to_remove.is_empty(): return
	for id in to_remove:
		var node = entity_nodes.get(id)
		if is_instance_valid(node): node.queue_free()
		entity_nodes.erase(id)
		_remove_all_bars(id)

func _update_health_bars():
	var cam = get_viewport().get_camera_3d()
	if not cam: return
	# 血条随相机缩放，与单机版 HUD._update_health_bars 保持一致
	_bar_scale = 1.0
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		_bar_scale = HP_BAR_REF_ORTHO / maxf(cam.size, 0.001)
	_bar_size = HP_BAR_SIZE * _bar_scale
	var viewport_rect = get_viewport().get_visible_rect().grow(50)

	for id in entity_nodes.keys():
		var node = entity_nodes.get(id)
		if not is_instance_valid(node): continue
		if not node.has_meta("snapshot_info"): continue
		var info = node.get_meta("snapshot_info")
		if not info: continue
		if not info.has("health") or not info.has("type"): continue
		if info["health"] <= 0: continue  # 已死亡实体不显示血条
		# 第一人称跟随视角：被跟随单位自身的血条锚点位于相机处，会悬浮在画面中央——隐藏
		if cam.has_method("get_follow_target") and cam.get_follow_target() == node:
			_hide_unit_bars(id)
			continue
		# 透视投影下相机后方的实体会 unproject 出翻转坐标——隐藏其血条
		var bar_world_pos = node.global_position + Vector3.UP * (info["body_radius"]*2 + 0.5)
		if cam.projection != Camera3D.PROJECTION_ORTHOGONAL and cam.is_position_behind(bar_world_pos):
			_hide_unit_bars(id)
			continue
		if not _should_entity_be_visible(info):
			_hide_unit_bars(id)
			continue
		var hp = info["health"]
		var max_hp = info.get("max_health", hp)
		if max_hp <= 0: max_hp = hp  # 防止除零
		var type = info["type"]
		var team = info.get("team", -1)

		# 每帧先隐藏建造条，建造分支命中时会重新显示
		if unit_bars.has(id) and unit_bars[id].get("build_bar"):
			unit_bars[id].build_bar.visible = false

		# 建造中
		if type == 1 and info.get("build_timer", 0) > 0:
			if Engine.get_process_frames() % 40 == 0:
				AudioManager.play_sfx_3d("build_loop", node.global_position, _get_cam_pos())
			var bar = _get_or_create_build_bar(id)
			var lab = _get_or_create_label(id)
			var bt := maxf(float(info.get("max_build_time", 0.0)), 0.001)
			var bp := clampf(1.0 - float(info["build_timer"]) / bt, 0.0, 1.0)
			bar.visible = true; lab.visible = show_unit_text
			bar.value = bp
			var nm2 = info["name"]
			var _gpfx3 = _get_entity_group_prefix(info["id"])
			lab.text = _gpfx3 + _get_entity_nation_prefix(info) + "%s (建造中 %d%%)" % [nm2, int(bp * 100.0)]
			var _lbc3 = _get_entity_label_color(info)
			lab.add_theme_color_override("font_color", _lbc3)
			_apply_label_nation_outline(lab, info)
			var world_pos = node.global_position + Vector3.UP * (info["body_radius"]*2 + 0.5)
			var screen_pos = cam.unproject_position(world_pos)
			if viewport_rect.has_point(screen_pos):
				bar.position = screen_pos - Vector2(30, 4)
				lab.position = bar.position + Vector2(0, -22)
				lab.visible = show_unit_text
			else:
				bar.visible = false; lab.visible = false
			continue

		# 生产中
		# Upgrade progress (purple bar matching health bar style, above HP)
		if info.get("upgrade_timer", 0) > 0:
			var upbar = _get_or_create_upgrade_bar(id)
			var uplab = _get_or_create_upgrade_label(id)
			var ut := maxf(float(info.get("max_upgrade_time", 0.0)), 0.001)
			var up := clampf(1.0 - float(info["upgrade_timer"]) / ut, 0.0, 1.0)
			upbar.visible = true; uplab.visible = show_unit_text
			upbar.value = up
			uplab.text = "升级中 %d%%" % int(up * 100.0)
			uplab.add_theme_color_override("font_color", UITheme.PURPLE.lightened(0.25))
			var uwp = node.global_position + Vector3.UP * (info["body_radius"]*2 + 0.5)
			var usp = cam.unproject_position(uwp)
			if viewport_rect.has_point(usp):
				upbar.position = usp - Vector2(30, 5) + Vector2(0, -20)
				uplab.position = upbar.position + Vector2(0, -14)
				uplab.visible = show_unit_text
			else:
				upbar.visible = false; uplab.visible = false
		else:
			_hide_upgrade_bars(id)

		if type == 1 and info.get("production_current_unit", -1) != -1 and info.get("production_current_unit") != null:
			var pbar = _get_or_create_prod_bar(id)
			var plab = _get_or_create_prod_label(id)
			pbar.visible = true; plab.visible = show_unit_text
			var prog = info.get("production_progress")
			var prog_f := clampf(float(prog) if prog != null else 0.0, 0.0, 1.0)
			pbar.value = prog_f
			var pcu = info.get("production_current_unit")
			if pcu == null or pcu == -1: continue
			var unit_cfg = EntityDatabase.get_config(pcu)
			plab.text = "%s x%d %d%%" % [unit_cfg.get("name","?"), info["production_queue_size"], int(prog_f * 100.0)]
			var world_pos = node.global_position + Vector3.UP * (info["body_radius"]*2 + 0.5)
			var screen_pos = cam.unproject_position(world_pos)
			if viewport_rect.has_point(screen_pos):
				pbar.position = screen_pos - Vector2(30, 0) + Vector2(0, 6)
				plab.position = pbar.position + Vector2(0, -12)
				plab.visible = show_unit_text
			else:
				pbar.visible = false; plab.visible = false

			if hp < max_hp:
				var bar = _get_or_create_health_bar(id)
				bar.visible = true
				# 血条颜色与模型一致：按 owner_peer_id 取该玩家专属阵营色
				bar.update_bar(hp, max_hp, team, _get_entity_color(info))
				if viewport_rect.has_point(screen_pos):
					bar.position = screen_pos - Vector2(_bar_size.x * 0.5, _bar_size.y * 0.5) + Vector2(0, -22.0 * _bar_scale)
				else: bar.visible = false
			else:
				if unit_bars.has(id) and unit_bars[id].bar: unit_bars[id].bar.visible = false
			continue

		# 普通实体
		_hide_prod_bars(id)
		var lab = _get_or_create_label(id)
		var world_pos = node.global_position + Vector3.UP * (info["body_radius"]*2 + 0.5)
		var screen_pos = cam.unproject_position(world_pos)

		if hp < max_hp:
			var bar = _get_or_create_health_bar(id)
			bar.visible = true
			# 血条颜色与模型一致：按 owner_peer_id 取该玩家专属阵营色
			bar.update_bar(hp, max_hp, team, _get_entity_color(info))
			if viewport_rect.has_point(screen_pos):
				bar.position = screen_pos - Vector2(_bar_size.x * 0.5, _bar_size.y * 0.5)
				lab.position = bar.position + Vector2(0, -22.0 * _bar_scale)
				lab.visible = show_unit_text
				var _gpfx2 = _get_entity_group_prefix(info["id"])
				var _res_info = ""
				if info.get("entity_id") in [10, 14]:
					var _ord = info.get("order", "")
					if _ord == "deliver": _res_info = "\n返回"
					elif _ord == "gather": _res_info = "\n采集中"
				lab.text = _gpfx2 + _get_entity_nation_prefix(info) + "%s Lv.%d%s\n%d/%d" % [info["name"], info.get("level", 1), _res_info, hp, max_hp]

				var _lbc4 = _get_entity_label_color(info)
				lab.add_theme_color_override("font_color", _lbc4)
				_apply_label_nation_outline(lab, info)
			else:
				bar.visible = false; lab.visible = false
		else:
			if unit_bars.has(id) and unit_bars[id].bar: unit_bars[id].bar.visible = false
			# 满血单位不显示名字：后期几百个 Label 的布局与绘制是客户端 UI 侧最大开销
			lab.visible = false

# 隐藏某实体的所有血条/标签控件
func _hide_unit_bars(id):
	if unit_bars.has(id):
		var bd = unit_bars[id]
		if bd.get("bar"): bd.bar.visible = false
		if bd.get("label"): bd.label.visible = false
		if bd.get("prod_bar"): bd.prod_bar.visible = false
		if bd.get("prod_label"): bd.prod_label.visible = false
		if bd.get("build_bar"): bd.build_bar.visible = false
		if bd.get("upgrade_bar"): bd.upgrade_bar.visible = false
		if bd.get("upgrade_label"): bd.upgrade_label.visible = false

# ==================== 血条控件创建 ====================
func _get_or_create_health_bar(id) -> HealthBarControl:
	if not unit_bars.has(id):
		unit_bars[id] = { "bar":null, "label":null, "prod_bar":null, "prod_label":null, "order_label":null }
	if not unit_bars[id].bar:
		var b = HealthBarControl.new()
		b.size = _bar_size
		add_child(b)
		# add_child 会触发 HealthBarControl._ready 写入默认最小尺寸，需在其后覆盖
		b.custom_minimum_size = _bar_size
		b.size = _bar_size
		unit_bars[id].bar = b
	# 相机缩放变化时同步已有血条尺寸
	var bar0 = unit_bars[id].bar
	if bar0.custom_minimum_size != _bar_size:
		bar0.custom_minimum_size = _bar_size
	bar0.size = _bar_size
	return unit_bars[id].bar

func _get_or_create_label(id) -> Label:
	if not unit_bars.has(id):
		unit_bars[id] = { "bar":null, "label":null, "prod_bar":null, "prod_label":null, "order_label":null }
	if not unit_bars[id].label:
		var l = Label.new()
		l.add_theme_font_size_override("font_size", HP_BAR_BASE_FONT)
		l.add_theme_color_override("font_color", Color.WHITE)
		l.add_theme_color_override("font_outline_color", Color.BLACK)
		l.add_theme_constant_override("outline_size", 1)
		add_child(l)
		unit_bars[id].label = l
	# 字号随血条一起缩放，与单机版一致
	unit_bars[id].label.add_theme_font_size_override("font_size", maxi(12, int(float(HP_BAR_BASE_FONT) * _bar_scale)))
	return unit_bars[id].label

func _get_or_create_prod_bar(id) -> ProgressBar:
	if not unit_bars.has(id):
		unit_bars[id] = { "bar":null, "label":null, "prod_bar":null, "prod_label":null, "order_label":null }
	if not unit_bars[id].prod_bar:
		var p = ProgressBar.new()
		UITheme.style_progress_bar(p, UITheme.SAPPHIRE, 8.0)
		add_child(p)
		unit_bars[id].prod_bar = p
	return unit_bars[id].prod_bar

func _get_or_create_prod_label(id) -> Label:
	if not unit_bars.has(id):
		unit_bars[id] = { "bar":null, "label":null, "prod_bar":null, "prod_label":null, "order_label":null, "upgrade_bar":null, "upgrade_label":null }
	if not unit_bars[id].has("prod_label") or not unit_bars[id].prod_label:
		var l = Label.new()
		l.add_theme_font_size_override("font_size", 20)
		l.add_theme_color_override("font_color", Color.WHITE)
		add_child(l)
		unit_bars[id].prod_label = l
	return unit_bars[id].prod_label

func _get_or_create_build_bar(id) -> ProgressBar:
	if not unit_bars.has(id):
		unit_bars[id] = { "bar":null, "label":null, "prod_bar":null, "prod_label":null, "order_label":null }
	if not unit_bars[id].has("build_bar") or not unit_bars[id].build_bar:
		var p = ProgressBar.new()
		UITheme.style_progress_bar(p, UITheme.BUILD_PROGRESS, 8.0)
		add_child(p)
		unit_bars[id].build_bar = p
	return unit_bars[id].build_bar

func _get_or_create_upgrade_bar(id) -> ProgressBar:
	if not unit_bars.has(id):
		unit_bars[id] = { "bar":null, "label":null, "prod_bar":null, "prod_label":null, "order_label":null, "upgrade_bar":null, "upgrade_label":null }
	if not unit_bars[id].has("upgrade_bar") or not unit_bars[id].upgrade_bar:
		var hb = ProgressBar.new()
		UITheme.style_progress_bar(hb, UITheme.UPGRADE_PROGRESS, 8.0)
		add_child(hb)
		unit_bars[id].upgrade_bar = hb
	return unit_bars[id].upgrade_bar

func _get_or_create_upgrade_label(id) -> Label:
	if not unit_bars.has(id):
		unit_bars[id] = { "bar":null, "label":null, "prod_bar":null, "prod_label":null, "order_label":null, "upgrade_bar":null, "upgrade_label":null }
	if not unit_bars[id].has("upgrade_label") or not unit_bars[id].upgrade_label:
		var l = Label.new()
		l.add_theme_font_size_override("font_size", 12)
		l.add_theme_color_override("font_color", Color(0.8, 0.4, 1.0))
		add_child(l)
		unit_bars[id].upgrade_label = l
	return unit_bars[id].upgrade_label

	if not unit_bars.has(id):
		unit_bars[id] = { "bar":null, "label":null, "prod_bar":null, "prod_label":null, "order_label":null }
	if not unit_bars[id].prod_label:
		var l = Label.new()
		l.add_theme_font_size_override("font_size", 20)
		l.add_theme_color_override("font_color", Color.WHITE)
		add_child(l)
		unit_bars[id].prod_label = l
	return unit_bars[id].prod_label

func _hide_upgrade_bars(id):
	if unit_bars.has(id):
		if unit_bars[id].has("upgrade_bar") and unit_bars[id].upgrade_bar:
			unit_bars[id].upgrade_bar.visible = false
		if unit_bars[id].has("upgrade_label") and unit_bars[id].upgrade_label:
			unit_bars[id].upgrade_label.visible = false

func _hide_prod_bars(id):
	if unit_bars.has(id):
		if unit_bars[id].prod_bar: unit_bars[id].prod_bar.visible = false
		if unit_bars[id].prod_label: unit_bars[id].prod_label.visible = false

func _remove_all_bars(id):
	if unit_bars.has(id):
		var data = unit_bars[id]
		if data.bar: data.bar.queue_free()
		if data.label: data.label.queue_free()
		if data.prod_bar: data.prod_bar.queue_free()
		if data.prod_label: data.prod_label.queue_free()
		if data.get("build_bar"): data.build_bar.queue_free()
		if data.get("upgrade_bar"): data.upgrade_bar.queue_free()
		if data.get("upgrade_label"): data.upgrade_label.queue_free()
		if data.order_label: data.order_label.queue_free()
		unit_bars.erase(id)

# ==================== 小地图数据收集 ====================
func _collect_entity_snapshots() -> Array:
	var list = []
	for node in entity_nodes.values():
		if not node.has_meta("snapshot_info"): continue
		var info = node.get_meta("snapshot_info")
		if info.health > 0:
			list.append(info)
	return list
const MAX_DELTA_PER_FRAME = 15
# ==================== 地形与视野工具 ====================
func is_in_player_vision(world_pos: Vector3) -> bool:
	for node in entity_nodes.values():
		var info = node.get_meta("snapshot_info", null)
		if info and info["team"] == player_team and info["health"] > 0:
			if node.global_position.distance_to(world_pos) <= _effective_vision(info):
				return true
	return false

# 客户端有效视野：与主机 get_effective_vision 同口径（地图倍率 × 树林遮蔽 × 高地加成）
func _effective_vision(info: Dictionary) -> int:
	var v := float(info.get("vision_range", 12))
	if v <= 0.0:
		return 0
	v *= float(map_modifiers.get("vision", 1.0))
	var map = get_node_or_null("Map")
	if map and map.has_method("get_overlay"):
		var gx := int(float(info.get("x", 0.0)) + RTSConfig.MAP_SIZE / 2.0)
		var gz := int(float(info.get("z", 0.0)) + RTSConfig.MAP_SIZE / 2.0)
		if map.get_overlay(gx, gz) == 1:
			v *= 0.55
		var hg := float(map_modifiers.get("high_ground_vision", 0.0))
		if hg > 0.0 and map.has_method("get_height_at_grid") and map.get_height_at_grid(gx, gz) >= float(map_modifiers.get("high_ground_min", 1.0)):
			v *= 1.0 + hg
	return maxi(1, int(round(v)))

func get_terrain_at(pos: Vector3) -> int:
	var map = get_node_or_null("Map")
	if map and map.has_method("get_terrain"):
		return map.get_terrain(int(pos.x + RTSConfig.MAP_SIZE/2), int(pos.z + RTSConfig.MAP_SIZE/2))
	return -1

func get_terrain_at_grid(gx: int, gy: int) -> int:
	var map = get_node_or_null("Map")
	if map and map.has_method("get_terrain"):
		return map.get_terrain(gx, gy)
	return -1

func get_terrain_height(world_pos: Vector3) -> float:
	var map = get_node_or_null("Map")
	if map and map.has_method("get_height_at"):
		return map.get_height_at(world_pos)
	return 0.0

# ==================== 游戏结束面板 ====================
# 结算层出现前，先隐藏客户端统计面板，避免压在全屏结算层之上
func _hide_client_stat_panels(ui: Node) -> void:
	if ui == null:
		return
	var hud = ui.get_node_or_null("HUD")
	if hud and hud.has_method("hide_stat_panels"):
		hud.hide_stat_panels()

func show_game_over(winner_team: int, stats_payload: Dictionary = {}):
	AudioManager.play_music("victory" if winner_team == player_team else "defeat")
	var existing = get_node_or_null("UI/GameOverPanel")
	if existing: existing.queue_free()

	var ui = get_node_or_null("UI")
	if not ui: ui = get_tree().root
	_hide_client_stat_panels(ui)

	# 优先使用房主发来的完整统计采样；没有数据时保留简易结算兜底
	if not stats_payload.is_empty():
		var stats = StatsScript.new(null)
		stats.load_payload(stats_payload)
		var stats_panel = StatsPanelScript.new()
		stats_panel.name = "GameOverPanel"
		stats_panel.restart_scene_path = "res://scenes/online_menu.tscn"
		if winner_team == player_team:
			stats_panel.result_label.text = "胜利！"
			stats_panel.result_label.add_theme_color_override("font_color", Color.GREEN)
		else:
			stats_panel.result_label.text = "失败！"
			stats_panel.result_label.add_theme_color_override("font_color", Color.RED)
		ui.add_child(stats_panel)
		stats_panel.show_stats(stats)
		stats_panel.visible = true
		return

	var panel = Control.new()
	panel.name = "GameOverPanel"
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var bg = ColorRect.new()
	bg.color = Color(0, 0, 0, 0.7)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_child(bg)

	var vbox = VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vbox.custom_minimum_size = Vector2(300, 200)
	vbox.add_theme_constant_override("separation", 20)
	panel.add_child(vbox)

	var res_lab = Label.new()
	res_lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	res_lab.add_theme_font_size_override("font_size", 48)
	if winner_team == player_team:
		res_lab.text = "胜利！"
		res_lab.add_theme_color_override("font_color", Color.GREEN)
	else:
		res_lab.text = "失败！"
		res_lab.add_theme_color_override("font_color", Color.RED)
	vbox.add_child(res_lab)

	var btn_restart = Button.new()
	btn_restart.text = "返回联机菜单"
	btn_restart.custom_minimum_size = Vector2(200, 50)
	btn_restart.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/online_menu.tscn"))
	vbox.add_child(btn_restart)

	var btn_quit = Button.new()
	btn_quit.text = "返回主菜单"
	btn_quit.custom_minimum_size = Vector2(200, 50)
	btn_quit.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))
	vbox.add_child(btn_quit)

	ui.add_child(panel)
func _process(delta):
	# 1. 快照处理 —— 始终优先（带崩溃循环保护）
	if snapshot_processing and not latest_snapshot.is_empty():
		if _snapshot_fail_count > 10:
			# 连续失败太多次，丢弃当前快照并重置
			latest_snapshot.clear()
			snapshot_processing = false
			_snapshot_fail_count = 0
			_snapshot_cooldown = 30
			print('[ClientRenderer] Too many snapshot failures, skipping. Cooldown 30 frames.')
		elif _snapshot_cooldown > 0:
			# 冷却期内丢弃快照，让系统恢复
			latest_snapshot.clear()
			snapshot_processing = false
			_snapshot_cooldown -= 1
		else:
			var snap = latest_snapshot.duplicate()
			latest_snapshot.clear()
			snapshot_processing = false
			_snapshot_fail_count += 1
			_safe_process_snapshot(snap)
			_snapshot_fail_count = 0

	# 2. pending_delta 积压处理
	if pending_delta.size() > 0:
		var count = min(pending_delta.size(), MAX_DELTA_PER_FRAME)
		for i in range(count):
			_update_single_entity(pending_delta.pop_front())

	# 3. 增量迷雾：每帧处理一批单位（不受交错调度限制）
	if fog_cycle_active:
		_process_fog_batch()

	# 4. 计时器更新
	# 快照超时诊断
	_diag_snap_age += delta
	if _diag_snap_age > 2.0 and _diag_last_snap_time > 0:
		var now_str = Time.get_datetime_string_from_system()
		print("[Client] 快照超时! %s | %.1fs未收到快照, seq=%d, 已收=%d" % [now_str, _diag_snap_age, last_applied_seq, _diag_snap_count])
		_diag_snap_age = 0.0

		# 更新快照时间标签
		_snap_time_timer -= delta
		if _snap_time_timer <= 0:
			_snap_time_timer = 1.0
			if _snap_time_label and _diag_last_snap_time > 0:
				var dt = Time.get_datetime_dict_from_unix_time(_diag_last_snap_time / 1000.0)
				var mins = int(_game_time / 60)
				var secs = int(_game_time) % 60
				_snap_time_label.text = "快照: %02d:%02d" % [mins, secs]
				var elapsed = (Time.get_ticks_msec() - _diag_last_snap_time) / 1000.0
				if elapsed > 2.0:
					_snap_time_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.2, 0.9))
				else:
					_snap_time_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3, 0.8))
			elif _snap_time_label:
				_snap_time_label.text = "等待快照..."
			# 定位到屏幕顶部中央
			if _snap_time_label:
				var vp = get_viewport().get_visible_rect()
				_snap_time_label.position = Vector2(vp.size.x / 2 - 120, 10)
				_snap_time_label.size = Vector2(240, 24)
	health_bar_timer -= delta
	fog_timer -= delta
	minimap_timer -= delta

	# 5. 启动新迷雾周期
	if fog_timer <= 0 and not fog_cycle_active:
		fog_timer = 2.0
		_start_fog_cycle()

	# 6. Periodic stale entity cleanup (every 30s)
	_stale_cleanup_timer -= delta
	if _stale_cleanup_timer <= 0:
		_stale_cleanup_timer = 30.0
		_cleanup_stale_entities()

	# 动画+音效+城墙 统一更新（每30帧同步）
	if Engine.get_process_frames() % 30 == 0:
		for id in entity_nodes.keys():
			var n = entity_nodes.get(id)
			if not is_instance_valid(n) or not n.has_meta("snapshot_info"):
				continue
			var inf = n.get_meta("snapshot_info")
			# 动画更新（状态切换已在 _update_single_entity 中即时触发）
			_update_entity_animation(n, inf)
			# 持续性移动音效（与动画同频）
			var ord = inf.get("current_order", "")
			if ord in ["move", "deliver"] and inf.get("health", 0) > 0 and _is_audible(n.global_position):
				var terr = get_terrain_at(n.global_position)
				AudioManager.play_sfx_3d("sail" if terr == 2 else "walk", n.global_position, _get_cam_pos())
			# 城墙朝向
			if inf.get("entity_id", 0) == 27:
				_update_wall_orientation(n, inf)
	if health_bar_timer <= 0:
		health_bar_timer = HEALTH_BAR_INTERVAL
		_update_health_bars()

	# 小地图更新
	if minimap_timer <= 0:
		minimap_timer = 1.0
		var minimap = get_node_or_null("UI/Minimap")
		if minimap:
			if minimap.terrain_colors.is_empty():
				var minimap_map = get_node_or_null("Map")
				if minimap_map and minimap_map.has_method("get_base_colors"):
					minimap.terrain_colors = minimap_map.get_base_colors()
			minimap.set_data(local_explored_grid, local_visible_grid, _collect_entity_snapshots())

# 7. 建造预览
	if placement_mode:
		var inp = $ClientInput
		if inp and inp.has_method("get_last_world_pos"):
			var pos = inp.get_last_world_pos()
			placement_preview.global_position = pos
func _add_water_box(map_size: int = 100, fog_texture = null):
	# Remove existing water
	var old = get_node_or_null("WaterBox")
	if old: old.queue_free()
	var w = MeshInstance3D.new()
	w.name = "WaterBox"
	var plane = PlaneMesh.new()
	plane.size = Vector2(map_size, map_size)
	# 细分后才能看到顶点波浪与船只附近的涟漪
	plane.subdivide_width = 128
	plane.subdivide_depth = 128
	w.mesh = plane
	w.position = Vector3(0, -0.9, 0)
	var shader = load("res://resources/water_noise.gdshader")
	if shader:
		var mat = ShaderMaterial.new()
		mat.shader = shader
		if fog_texture: mat.set_shader_parameter("fog_tex", fog_texture)
		var empty_boats := PackedVector3Array()
		empty_boats.resize(BOAT_SHADER_SLOTS)
		mat.set_shader_parameter("boats", empty_boats)
		mat.set_shader_parameter("boat_count", 0)
		_water_mat = mat
		w.material_override = mat
	add_child(w)

# 把客户端可见的水面单位位置喂给水面着色器（船体涟漪与泡沫尾迹）
func _update_water_boats() -> void:
	if _water_mat == null:
		return
	var arr := PackedVector3Array()
	arr.resize(BOAT_SHADER_SLOTS)
	var dirs := PackedVector3Array()
	dirs.resize(BOAT_SHADER_SLOTS)
	var count: int = 0
	for n in entity_nodes.values():
		if count >= BOAT_SHADER_SLOTS:
			break
		if not is_instance_valid(n) or not (n is Node3D):
			continue
		if not bool(n.get("water_capable")):
			continue
		var hp = n.get("health")
		if hp != null and int(hp) <= 0:
			continue
		var id: int = n.get_instance_id()
		var pos: Vector3 = n.global_position
		var dir := Vector3.ZERO
		var prev = _boat_prev.get(id)
		if prev is Vector3:
			var d: Vector3 = pos - prev
			d.y = 0.0
			if d.length() > 0.03:
				dir = d.normalized()
		_boat_prev[id] = pos
		arr[count] = pos
		dirs[count] = dir
		count += 1
	_water_mat.set_shader_parameter("boats", arr)
	_water_mat.set_shader_parameter("boat_dirs", dirs)
	_water_mat.set_shader_parameter("boat_count", count)
