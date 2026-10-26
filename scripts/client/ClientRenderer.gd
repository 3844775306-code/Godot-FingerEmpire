class_name ClientRenderer
extends Node3D
const StatsScript = preload("res://scripts/core/BattleStats.gd")
const StatsPanelScript = preload("res://scripts/ui/BattleStatsPanel.gd")
const BuildingDeathEffect = preload("res://scripts/effects/BuildingDeathEffect.gd")
const BuildingConstructionVisual = preload("res://scripts/effects/BuildingConstructionVisual.gd")
const TreeFallEffect = preload("res://scripts/effects/TreeFallEffect.gd")
const EntityDamageVisual = preload("res://scripts/effects/EntityDamageVisual.gd")
enum E { ID=0, EID, TYPE, TEAM, X, Y, Z, HEALTH, MAX_HEALTH, ATTACK, ATTACK_SPEED, MELEE_ARMOR, SHIELD_ARMOR, SPEED, VISION, BODY_R, TARGET_TYPE, OWNER, LEVEL, ORDER, HOLD, NAME, ENTITY_ID, WAYPOINTS, ROT_Y, ASTAR_PATH, GARRISONED, NATION, IN_ACTION_RANGE, ATTACK_SEQ }
enum EB { UPGRADE=0, MAX_UPGRADE, CAN_UPGRADE, BUILD_TIMER, MAX_BUILD, PROD_CURRENT, PROD_PROGRESS, PROD_QSIZE, UPGRADE_TIMER, MAX_UPGRADE_TIME, GARRISON_COUNT, REPAIR_TIMER, MAX_REPAIR, CAN_REPAIR }
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
var mobile_centered_placement: bool = false  # 手机端：预览固定屏幕中央，滑动地图调整位置

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
# 队伍 → 国家（RTSConfig.Nation 枚举）。服务器在快照里下发 team_nations，
# 客户端 HUD 的战况播报要靠它显示「哪个国家发出来的」。
var team_nations: Dictionary = {}

# 查某队伍对应的国家枚举，查不到返回 -1
func get_team_nation(team: int) -> int:
	return int(team_nations.get(team, -1))

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
	mobile_centered_placement = InputSource.use_mobile_ui()
	var cfg = EntityDatabase.get_config(bid)
	if cfg.is_empty(): return
	# 与 RTSBattleManager 的实际生成保持一致：大部分建筑的 body_radius 会再乘 2
	var effective_radius: float = float(cfg.get("body_radius", 1.0)) * RTSConfig.get_building_body_scale(bid)
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
		box.size = Vector3(effective_radius * 2.0, effective_radius * 1.5, effective_radius * 2.0)
		placement_preview.mesh = box
	var target_size = effective_radius * 2.0 * RTSConfig.get_model_scale(bid)
	var aabb = _get_model_aabb(placement_preview)
	var current_size = max(aabb.size.x, max(aabb.size.y, aabb.size.z))
	if current_size > 0.01: placement_preview.scale = Vector3.ONE * (target_size / current_size)
	if bid in [22, 27, 28]: placement_preview.rotation.y = deg_to_rad(90)
	if bid == 18: placement_preview.rotation.y = deg_to_rad(-90)
	_tint_preview(placement_preview, Color(0, 1, 0))
	placement_preview.visible = true
	if mobile_centered_placement:
		var inp = get_node_or_null("ClientInput")
		if inp and inp.has_method("update_centered_placement_preview"):
			inp.call("update_centered_placement_preview")

			

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
						BuildingConstructionVisual.cancel(node)
						# 土色贴花先摘下来独立淡出，倒塌动画结束后它还在慢慢褪色
						_fade_ground_patch_of(node)
						effect_duration = BuildingDeathEffect.play(node, int(info.get("entity_id", -1)), float(info.get("body_radius", 0.5)))
					elif int(info.get("type", -1)) == 0 and int(info.get("entity_id", -1)) == 1:
						effect_duration = TreeFallEffect.play(node, float(info.get("body_radius", 0.5)))
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

			_free_waypoint_markers(int(id))

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
			# 存档一份：HUD 的播报需要按队伍查国家名（自己是哪国、敌方是哪国）
			team_nations = data["team_nations"].duplicate()
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
				if not (alert is Dictionary): continue
				if hud and hud.has_method("show_server_alert"):
					hud.show_server_alert(alert["msg"], alert.get("color", Color(1.0, 0.2, 0.1)), int(alert.get("id", 0)), alert.get("teams", []), int(alert.get("kind", 0)), bool(alert.get("castle", false)), alert.get("nations", []))
				elif hud and hud.has_method("show_alert_message"):
					hud.show_alert_message(alert["msg"], alert.get("color", Color(1.0, 0.2, 0.1)), alert.get("teams", []), int(alert.get("kind", 0)), bool(alert.get("castle", false)), alert.get("nations", []))

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
					elif eid == 16 or eid == 39 or eid == 13:
						AudioManager.play_sfx_3d("cannon_fire", bpos, cam)
					elif eid == 17 or eid == 59:
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
					if eid2 == 16 or eid2 == 39 or eid2 == 13:
						AudioManager.play_sfx_3d("cannon_hit", n.global_position, cam)
					elif eid2 == 17 or eid2 == 59:
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
	# 客户端算修理费：和服务端 Building.repair_cost() 同一套公式（已损% × 原价，向上取整）
	var max_hp := float(d.get("max_health", 0.0))
	var cur_hp := float(d.get("health", 0.0))
	var dmg := clampf(1.0 - cur_hp / max_hp, 0.0, 1.0) if max_hp > 0.0 else 0.0
	var rcost := {}
	if dmg > 0.0:
		for res in cfg.get("cost", {}):
			var v := int(ceil(float(cfg["cost"][res]) * dmg))
			if v > 0:
				rcost[res] = v
	d["repair_cost"] = rcost
	d["repair_damage_ratio"] = dmg
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
			"attack_seq": arr[E.ATTACK_SEQ] if arr.size() > E.ATTACK_SEQ else 0,
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
				# 修理状态（老版本快照没有这几格，缺省当 0）
				info["repair_timer"] = ba[EB.REPAIR_TIMER] if ba.size() > EB.REPAIR_TIMER else 0.0
				info["max_repair_time"] = ba[EB.MAX_REPAIR] if ba.size() > EB.MAX_REPAIR else 0.0
				info["can_repair"] = ba[EB.CAN_REPAIR] if ba.size() > EB.CAN_REPAIR else 0
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
	# 联机客户端没有 Army，脚印/脚步扬尘也从快照位移里补出来。
	if int(info.get("type", -1)) == 2 and node.visible:
		_update_client_ground_trail(node, info)
	node.set_meta("snapshot_info", info)
	_refresh_client_construction_visual(node, info)
	_refresh_client_damage_visual(node, info)
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
		var attack_changed: bool = int(prev_info.get("attack_seq", 0)) != int(info.get("attack_seq", 0))
		if order_changed or range_changed or attack_changed:
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
					wall_node.set_meta("_model_instance", inst)
					BuildingConstructionVisual.rebind(wall_node)
	
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

# 联机客户端的地面痕迹：按快照间的实际位移累计步长，避免只按时间生成导致
# 单位停住时还在留脚印。与 Army 共用 GroundTrailManager 的 MultiMesh/粒子池。
func _update_client_ground_trail(node: Node3D, info: Dictionary) -> void:
	var eid := int(info.get("entity_id", -1))
	if eid in [9, 13, 14, 39, 40] or int(info.get("health", 0)) <= 0:
		return
	var now := Time.get_ticks_msec()
	var last_pos: Vector3 = node.get_meta("_trail_last_pos", node.global_position)
	var moved := node.global_position.distance_to(last_pos)
	if moved > 8.0:
		# 快照传送/重连：只重置基线，不补一串脚印
		node.set_meta("_trail_last_pos", node.global_position)
		node.set_meta("_trail_last_ms", now)
		node.set_meta("_trail_accum", 0.0)
		return
	var dt := maxf(0.03, float(now - int(node.get_meta("_trail_last_ms", now))) / 1000.0)
	var inst_speed := moved / dt
	var old_speed := float(node.get_meta("_visual_speed", info.get("speed", 2.0)))
	node.set_meta("_visual_speed", lerpf(old_speed, inst_speed, 0.4))
	node.set_meta("_trail_last_ms", now)
	node.set_meta("_trail_last_pos", node.global_position)
	if moved < 0.005:
		node.set_meta("_trail_accum", 0.0)
		return

	var vehicle: bool = eid in [5, 6, 16, 17, 18, 59]
	var stride: float = 0.95 if vehicle else 0.52
	var accum: float = float(node.get_meta("_trail_accum", 0.0)) + moved
	if accum < stride:
		node.set_meta("_trail_accum", accum)
		return
	accum = fmod(accum, stride)
	node.set_meta("_trail_accum", accum)

	var dir := node.global_position - last_pos
	if dir.length_squared() < 0.0001:
		dir = -node.global_transform.basis.z
	var terrain := get_terrain_at(node.global_position)
	var overlay := 0
	var map := get_node_or_null("Map")
	if map and map.has_method("get_overlay"):
		var gx := int(node.global_position.x + RTSConfig.MAP_SIZE / 2.0)
		var gz := int(node.global_position.z + RTSConfig.MAP_SIZE / 2.0)
		overlay = int(map.get_overlay(gx, gz))
	var side := 0
	if not vehicle:
		side = int(node.get_meta("_trail_side", 1))
		node.set_meta("_trail_side", -side)
	var mgr := GroundTrailManager.get_instance(get_tree())
	if mgr != null:
		mgr.emit_step(node.global_position, dir, vehicle, terrain, overlay, side)
	_play_client_step_sfx(node.global_position, terrain, overlay, vehicle)

func _play_client_step_sfx(pos: Vector3, terrain: int, overlay: int, vehicle: bool) -> void:
	var key := "walk"
	var pitch := 1.0
	if terrain == 2 or overlay == 3:
		key = "water_step"
		pitch = randf_range(0.90, 1.0)
	elif terrain == 1:
		pitch = 0.82
	elif overlay == 2:
		pitch = 0.85
	elif overlay == 1:
		pitch = 0.95
	else:
		pitch = randf_range(0.94, 1.06)
	if vehicle:
		pitch *= 0.82
	AudioManager.play_sfx_3d(key, pos, _get_cam_pos(), pitch)

func _update_entity_animation(node: Node3D, info: Dictionary):
	var ap: AnimationPlayer = node.get_meta("_anim_player", null)
	if not is_instance_valid(ap):
		ap = AnimationHelper.find_player(node)
		if ap != null:
			node.set_meta("_anim_player", ap)
	# 先算出目标动作名，再决定是由 AnimationPlayer 播放还是走程序化攻城动画。
	# 攻城模型（火炮/投石车/巨投/战船等）没有 AnimationPlayer，不能像以前那样
	# 直接 return，否则客户端完全看不到开火动作。
	var anim = ""
	var ord = info.get("current_order", "")
	var entity_id := int(info.get("entity_id", -1))
	if info.get("health", 0) <= 0:
		anim = "die"
	elif RTSConfig.is_animal(entity_id):
		# 动物没有指令流，快照里 order 恒为 idle；只能靠位置变化判断它在不在走，
		# 否则联机端整群动物都是滑行不迈腿。
		var prev_pos: Vector3 = node.get_meta("_anim_prev_pos", node.global_position)
		var moved: float = node.global_position.distance_to(prev_pos)
		node.set_meta("_anim_prev_pos", node.global_position)
		var move_speed: float = moved / maxf(get_process_delta_time(), 0.001)
		anim = "walk" if move_speed > 0.06 else "idle"
	elif ord in ["attack", "attack_move", "gather"]:
		# 锁定目标后还要先走到攻击/采集距离；服务端在快照里标记是否已进入距离。
		# 追击途中播放走路，进入距离后才播放攻击/采集动作。
		var in_range := int(info.get("in_action_range", 0)) == 1
		if in_range:
			# 采集是挥动，出手姿势按兵种取（法术/射击单位不能用近战左勾拳）
			anim = "attack-melee-left" if ord == "gather" else AnimationHelper.attack_anim_for(entity_id)
		else:
			anim = "walk"
	elif ord in ["move", "deliver"]:
		anim = "walk"
	else:
		anim = "idle"
	if ap != null:
		if anim != "" and ap.has_animation(anim):
			var spd := 1.0
			if anim != "walk" and anim != "idle" and anim != "die":
				var atk_raw = info.get("attack_speed", 1.0)
				var atk_spd := float(atk_raw) if atk_raw != null else 1.0
				spd = AnimationHelper.attack_speed_scale(ap, anim, atk_spd)
			elif anim == "walk":
				var mv_raw = info.get("speed", 2.0)
				var mv_spd := float(mv_raw) if mv_raw != null else 2.0
				if node.has_meta("_visual_speed"):
					var measured := float(node.get_meta("_visual_speed"))
					if measured > 0.05:
						mv_spd = measured
				spd = AnimationHelper.walk_speed_scale(mv_spd)
			ap.speed_scale = spd
			if anim == "walk":
				AnimationHelper.play_looped(ap, anim, true)
			elif ap.current_animation != anim:
				ap.play(anim)
	elif SiegeAttackAnim.is_siege(entity_id):
		_update_client_siege_attack(node, info)
	if CasterAttackAnim.is_caster(entity_id):
		_update_client_caster_attack(node, info)

# 联机客户端没有 Army/真实目标引用，只能根据 attack_seq 按朝向和射程
# 放一枚视觉法术弹；伤害/治疗仍由服务端在命中时结算，客户端只负责表现。
func _update_client_caster_attack(node: Node3D, info: Dictionary) -> void:
	var model = node.get_meta("_model_instance", null) as Node3D
	if model == null:
		return
	var entity_id := int(info.get("entity_id", -1))
	if not CasterAttackAnim.is_caster(entity_id):
		return
	var seq := int(info.get("attack_seq", 0))
	var prev_seq := int(node.get_meta("_caster_attack_seq", -1))
	if info.get("health", 0) <= 0:
		node.set_meta("_caster_attack_seq", seq)
		return
	if prev_seq == -1:
		# 刚进入视野：只记录基线，不补播进入视野前的施法
		node.set_meta("_caster_attack_seq", seq)
		return
	if seq == prev_seq:
		return
	node.set_meta("_caster_attack_seq", seq)
	var cfg := EntityDatabase.get_config(entity_id)
	var cast_range: float = float(cfg.get("attack_range", 4.5))
	var fwd: Vector3 = -node.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	var end_pos: Vector3 = node.global_position + fwd.normalized() * cast_range
	CasterAttackAnim.cast_point(entity_id, node, end_pos)

# 联机客户端没有 Army/attack_timer，改为比较快照里的 attack_seq：
# 每真正攻击一次 seq 才 +1，客户端只在变化时播放一次，不再按冷却循环猜测。
func _update_client_siege_attack(node: Node3D, info: Dictionary) -> void:
	var model = node.get_meta("_model_instance", null) as Node3D
	if model == null:
		return
	var entity_id := int(info.get("entity_id", -1))
	if not SiegeAttackAnim.is_siege(entity_id):
		return
	var seq := int(info.get("attack_seq", 0))
	var prev_seq := int(node.get_meta("_siege_attack_seq", -1))
	if info.get("health", 0) <= 0:
		SiegeAttackAnim.reset(model)
		node.set_meta("_siege_attack_seq", seq)
		return
	if prev_seq == -1:
		# 刚进入视野：只记录基线，不补播进入视野前的攻击
		node.set_meta("_siege_attack_seq", seq)
		return
	if seq == prev_seq:
		return
	node.set_meta("_siege_attack_seq", seq)
	var opts := {
		"target": null,
		"body_radius": float(info.get("body_radius", 0.8)),
		"forward": -node.global_transform.basis.z,
		"right": node.global_transform.basis.x,
	}
	SiegeAttackAnim.play(entity_id, model, opts)

func _refresh_client_construction_visual(node: Node3D, info: Dictionary) -> void:
	if int(info.get("type", -1)) != 1:
		return
	var build_timer := float(info.get("build_timer", 0.0))
	if build_timer > 0.0:
		var max_build := maxf(float(info.get("max_build_time", 0.0)), 0.001)
		var progress := clampf(1.0 - build_timer / max_build, 0.0, 1.0)
		BuildingConstructionVisual.update(node, progress)
		return
	# 修理中：同样用脚手架 + 扬尘那套施工外观，但模型保持完整（repair 模式）
	var repair_timer := float(info.get("repair_timer", 0.0))
	if repair_timer > 0.0:
		var max_repair := maxf(float(info.get("max_repair_time", 0.0)), 0.001)
		var rprogress := clampf(1.0 - repair_timer / max_repair, 0.0, 1.0)
		if not BuildingConstructionVisual.is_repairing(node):
			BuildingConstructionVisual.begin(node, null, true)
		BuildingConstructionVisual.update(node, rprogress)
		return
	BuildingConstructionVisual.finish(node)

func _refresh_client_damage_visual(node: Node3D, info: Dictionary) -> void:
	var max_hp := float(info.get("max_health", 0.0))
	var hp := float(info.get("health", 0.0))
	if max_hp <= 0.0 or hp <= 0.0:
		return
	var ratio := clampf(hp / max_hp, 0.0, 1.0)
	var entity_type := int(info.get("type", -1))
	if entity_type == 1:
		# 建造中由施工动画控制模型变换，完成后再显示受损外观。
		# 修理用的是同一套施工外观，但修理时模型保持完整，受损/修补外观要照常跟着血量走，
		# 否则联机端修完会突然从残破「跳」成完好。
		if float(info.get("build_timer", 0.0)) > 0.0:
			return
		if node.has_meta("_construction_visual") and not BuildingConstructionVisual.is_repairing(node):
			return
		EntityDamageVisual.update_building(node, ratio)
	elif entity_type == 0:
		EntityDamageVisual.update_resource(node, ratio)

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

# 需要划桨/帆位动画的船：采集船是划艇，其余三条有帆
const SHIP_ANIM_IDS := [13, 14, 39, 40]
# 石油资源（EntityDatabase id 4），模型是 water-rocks，靠冒黑烟才认得出来
const OIL_RESOURCE_ID := 4
# 修理进度条颜色：和建造条（琥珀）同样的形状与位置，用绿一点的颜色区分「修补」和「新建」
const REPAIR_BAR_COLOR: Color = Color(0.36, 0.86, 0.52)

# 在船模型下面挂一个 ShipSailAnimator（与服务端同一套实现，纯视觉）
func _attach_ship_sail_animator(model_instance: Node3D) -> void:
	if model_instance == null or not is_instance_valid(model_instance):
		return
	if model_instance.get_node_or_null("ShipSailAnimator") != null:
		return
	var animator := ShipSailAnimator.new()
	animator.name = "ShipSailAnimator"
	model_instance.add_child(animator)
	animator.setup(model_instance)

# 石油资源：常年冒黑烟 + 脚下油渍（纯视觉，客户端自己跑，不依赖服务端快照）
func _attach_oil_smoke(model_instance: Node3D, body_radius: float) -> void:
	if model_instance == null or not is_instance_valid(model_instance):
		return
	if model_instance.get_node_or_null("OilSmoke") != null:
		return
	model_instance.add_child(OilSmoke.create(body_radius))

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

# 建筑模型的实际水平半径（客户端）。
# 快照里的 body_radius 是按模型「最大边」算的，高瘦建筑水平方向明显更窄，
# 土色贴花和选择环都该用这里的值，否则会大出一圈。
# 返回 0 表示拿不到模型尺寸，调用方退回 body_radius。
func _model_horizontal_radius(node: Node3D, fallback: float) -> float:
	if node == null or not is_instance_valid(node):
		return 0.0
	var model = node.get_meta("_model_instance", null) if node.has_meta("_model_instance") else null
	if model == null or not is_instance_valid(model) or not (model is Node3D):
		return 0.0
	var inst: Node3D = model
	if absf(inst.scale.x) < 0.001:
		return 0.0
	var aabb: AABB = _get_model_aabb(inst)
	var horiz: float = maxf(aabb.size.x, aabb.size.z) * absf(inst.scale.x) * 0.5
	return horiz if horiz > 0.05 else 0.0

# 建筑脚下的土色贴花：与服务端 Building 保持一致的尺寸与配色，纹理直接复用同一个静态资源
func _attach_ground_patch(node: Node3D, info: Dictionary) -> void:
	if node == null or not is_instance_valid(node):
		return
	if int(info.get("type", -1)) != 1:
		return
	# 与服务端一致：城墙/炮台/桥/梯子这些构件不铺土色
	if int(info.get("entity_id", -1)) in Building.GROUND_PATCH_EXCLUDE_IDS:
		return
	if node.get_node_or_null("GroundPatch") != null:
		return
	var eid: int = int(info.get("entity_id", -1))
	# 尺寸优先按模型实际水平尺寸算（与服务端同一套判据）：body_radius 是按
	# 模型「最大边」缩放的，高瘦的塔类建筑水平方向比它窄，直接用会偏大。
	var visual_radius: float = float(info.get("body_radius", 1.0)) * RTSConfig.get_model_scale(eid)
	var horiz: float = _model_horizontal_radius(node, visual_radius)
	if horiz > 0.0:
		visual_radius = horiz
	var half: float = visual_radius + Building.GROUND_PATCH_MARGIN

	var decal := Decal.new()
	decal.name = "GroundPatch"
	decal.texture_albedo = Building._ground_patch_texture()
	decal.size = Vector3(half * 2.0, 12.0, half * 2.0)
	decal.modulate = Building.GROUND_PATCH_COLOR
	decal.albedo_mix = 1.0
	decal.upper_fade = 1.2
	decal.lower_fade = 1.2
	node.add_child(decal)

# 资源脚下的软边地皮：与服务端 WorldResource 使用同一套纹理/配色/尺寸算法，
# 让树、石头、农田、油井和地面之间有一圈自然的过渡，而不是模型直接切在地表上。
func _attach_resource_ground_patch(node: Node3D, info: Dictionary) -> void:
	if node == null or not is_instance_valid(node):
		return
	if int(info.get("type", -1)) != 0:
		return
	if node.get_node_or_null("GroundPatch") != null:
		return
	var eid: int = int(info.get("entity_id", -1))
	var model: Node3D = null
	if node.has_meta("_model_instance"):
		var mi = node.get_meta("_model_instance")
		if mi is Node3D and is_instance_valid(mi):
			model = mi
	var half: float = WorldResource.ground_patch_half_size(float(info.get("body_radius", 0.6)), model)
	var decal := Decal.new()
	decal.name = "GroundPatch"
	decal.texture_albedo = WorldResource.ground_patch_texture()
	decal.modulate = WorldResource.ground_patch_color(WorldResource.resource_type_for_id(eid))
	decal.albedo_mix = 0.9
	decal.cull_mask = WorldResource.GROUND_PATCH_CULL_MASK
	decal.size = Vector3(half * 2.0, 6.0, half * 2.0)
	decal.position = Vector3.ZERO
	decal.upper_fade = 1.0
	decal.lower_fade = 1.0
	node.add_child(decal)

# 建筑倒塌时把土色贴花摘下来独立淡出，让地面痕迹比建筑多留一会儿
func _fade_ground_patch_of(node: Node3D) -> void:
	if node == null or not is_instance_valid(node):
		return
	var decal = node.get_node_or_null("GroundPatch")
	if decal == null or not is_instance_valid(decal):
		return
	var host := get_parent()
	if host != null:
		decal.reparent(host, true)
	var tw := decal.create_tween()
	tw.tween_property(decal, "modulate:a", 0.0, Building.GROUND_PATCH_FADE_TIME)
	tw.tween_callback(Callable(decal, "queue_free"))

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
	entity.set_meta("_body_radius", float(r))
	entity.set_meta("_entity_id", int(info.get("entity_id", -1)))
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
		entity.set_meta("_model_instance", loaded_model)
		# 快照里的 body_radius 已经是服务端放大后的有效半径，模型按它缩放到目标尺寸即可。
		# 这里不能再乘一次建筑放大 2 倍，否则客户端建筑会是服务端的 2 倍（配置的 4 倍）。
		# 服务端对普通建筑放大后按包围盒重新贴地，客户端这里做同样的底部对齐。
		if int(info.get("type", -1)) == 1 and RTSConfig.get_building_body_scale(int(info.get("entity_id", 0))) != 1.0:
			if absf(aabb.position.y * scale_factor) > 0.005:
				loaded_model.position.y -= aabb.position.y * scale_factor
		_ensure_model_shadows(loaded_model)
		# 船只：划艇摆桨、有帆的船按风向转帆（纯视觉，客户端自己跑）
		if int(info.get("entity_id", 0)) in SHIP_ANIM_IDS:
			_attach_ship_sail_animator(loaded_model)
		# 石油：冒黑烟 + 脚下油渍
		if int(info.get("entity_id", 0)) == OIL_RESOURCE_ID:
			_attach_oil_smoke(loaded_model, float(info.get("body_radius", 0.6)))
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

	# 官员与农民共用随机人物模型，联机端也必须补上同样的金色标识，
	# 否则只有服务端/单机看得到，联机玩家仍然分不清。
	if OfficialMarker.is_official(eid):
		entity.add_child(OfficialMarker.create(float(info.get("body_radius", 0.4))))
	# 僧侣/长老/宗师同理：双层法阵 + 头顶职业符号，客户端与服务端共用 CasterMarker
	if CasterMarker.is_caster(eid):
		entity.add_child(CasterMarker.create(eid, float(info.get("body_radius", 0.4))))
	# 动物：脚下接触阴影，把模型压在地面上（鱼不需要）
	if RTSConfig.is_animal(eid) and eid != 63:
		var animal_model: Node3D = null
		if entity.has_meta("_model_instance"):
			var mi = entity.get_meta("_model_instance")
			if mi is Node3D and is_instance_valid(mi):
				animal_model = mi
		entity.add_child(GroundContact.create(GroundContact.half_size_for(float(info.get("body_radius", 0.4)), animal_model)))

	# 存储 owner_peer_id 元数据，供后续使用
	entity.set_meta("owner_peer_id", owner_id)
	# 攻城单位：以首次快照为动画基线，避免第一次攻击时把旧序号当成新事件
	if SiegeAttackAnim.is_siege(int(info.get("entity_id", -1))):
		entity.set_meta("_siege_attack_seq", int(info.get("attack_seq", 0)))
	entities_container.add_child(entity)
	# 建筑脚下铺一层土色贴花，让建筑看起来压在地上而不是浮着
	_attach_ground_patch(entity, info)
	# 资源脚下同样铺一层软边地皮，消除模型与地表的生硬切边
	_attach_resource_ground_patch(entity, info)
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
# 选中变化时立即刷新路径指引带：不等下一次快照，避免「选中后看不到路径」
func _refresh_waypoint_markers(ids: Array):
	if not has_meta("_wp_markers"):
		if ids.is_empty(): return
		set_meta("_wp_markers", {})
	var all_wp = get_meta("_wp_markers")
	var keep := {}
	for id in ids: keep[id] = true
	for eid in all_wp.keys().duplicate():
		if keep.has(eid): continue
		_free_waypoint_markers(int(eid))
	for id in ids:
		var node = entity_nodes.get(id)
		if node and node.has_meta("snapshot_info"):
			_update_waypoint_markers(node, node.get_meta("snapshot_info"))

# ==================== 联机路径指引带 ====================
# 原来给每个 A* 路径点建一颗青球、给每个 waypoint 建「竖直杆 + 悬空环 + 地面球」，
# 全都 no_depth_test，看着是一串飘在空中的标记。现在整条路径换成一条贴地的
# GroundPathGuide：中心线逐顶点贴地、虚线往前流动、末端自带落点环。
# 只给选中单位画；waypoint 编号保留为贴地抬高 0.6 米的 Label3D。
func _update_waypoint_markers(node: Node3D, info: Dictionary):
	# Only show waypoints for selected entities
	var inp = get_node_or_null("ClientInput")
	var is_selected = false
	if inp and inp.has_method("get_client_selected_ids"):
		is_selected = info["id"] in inp.get_client_selected_ids()
	if not is_selected:
		_free_waypoint_markers(int(info.get("id", -1)))
		return

	# Track all waypoint markers globally (keyed by entity id)
	if not has_meta("_wp_markers"):
		set_meta("_wp_markers", {})
	var all_wp = get_meta("_wp_markers")
	var eid: int = int(info.get("id", -1))

	var wps = info.get("waypoints", [])
	var apath = info.get("astar_path", [])
	# 中心线取点：优先 A*（单位真正在走的路线），A* 缺失时退回 waypoint 链
	var pts: Array = []
	if apath is Array:
		for a in apath:
			var ap: Vector3 = _path_point_to_vector3(a)
			if is_finite(ap.x):
				pts.append(ap)
	if pts.size() < 2 and wps is Array:
		pts.clear()
		for w in wps:
			var wp: Vector3 = _path_point_to_vector3(w)
			if is_finite(wp.x):
				pts.append(wp)
	# loop（巡逻/循环）指令：整条带子用橙色，和普通移动的青白区分开
	var loop: bool = false
	if wps is Array:
		for w in wps:
			if w is Dictionary and bool(w.get("is_loop", false)):
				loop = true
				break
	if pts.size() < 2:
		_free_waypoint_markers(eid)
		return

	# 快照 10Hz 每次都会走这个函数：路径点没变就复用现有指引带，绝不重建网格
	var sig: int = hash([pts, loop])
	var guide: GroundPathGuide = null
	if all_wp.has(eid):
		var arr = all_wp[eid]
		if arr is Array and arr.size() > 0 and is_instance_valid(arr[0]) and arr[0] is GroundPathGuide:
			guide = arr[0]
			# loop 语义变了要换带子颜色，只能重建节点
			if bool(guide.get_meta("_path_loop", false)) != loop:
				guide.queue_free()
				guide = null
		else:
			# 旧版本留下的球/杆/环：整组清掉，统一换成贴地指引带
			for m in arr:
				if is_instance_valid(m):
					m.queue_free()
			all_wp.erase(eid)
	if guide != null and int(guide.get_meta("_path_sig", 0)) == sig:
		return
	if guide != null:
		# 路径变了但颜色不用变：只重建中心线，节点和编号标签都复用
		guide.set_points(pts)
		guide.set_meta("_path_sig", sig)
		_refresh_path_guide_labels(guide, wps)
		return
	# 首次创建：节点放在世界原点，网格按世界坐标建（地形高度逐顶点采样）
	guide = _make_path_guide(pts, loop)
	entities_container.add_child(guide)
	guide.set_meta("_path_sig", sig)
	guide.set_meta("_path_loop", loop)
	all_wp[eid] = [guide]
	_refresh_path_guide_labels(guide, wps)

func _make_path_guide(pts: Array, loop: bool) -> GroundPathGuide:
	# tint 的 alpha=0 表示「用默认青白」，loop 指令用橙色
	var tint: Color = Color(1.0, 0.56, 0.12, 0.46) if loop else Color(0, 0, 0, 0)
	var guide: GroundPathGuide = GroundPathGuide.create(pts, get_ground_height_fn(), tint)
	guide.name = "ClientPathGuide"
	return guide

# waypoint 编号标签：位置只跟 waypoint 走，A* 路径变化时不用重建
func _refresh_path_guide_labels(guide: GroundPathGuide, wps) -> void:
	var wp_sig: int = hash(wps) if wps is Array else 0
	if int(guide.get_meta("_wp_sig", -1)) == wp_sig:
		return
	guide.set_meta("_wp_sig", wp_sig)
	for c in guide.get_children():
		if c is Label3D:
			c.queue_free()
	if not (wps is Array) or wps.is_empty():
		return
	var height_fn: Callable = get_ground_height_fn()
	for i in wps.size():
		var wp = wps[i]
		var p: Vector3 = _path_point_to_vector3(wp)
		if not is_finite(p.x):
			continue
		var is_loop: bool = wp is Dictionary and bool(wp.get("is_loop", false))
		var is_last: bool = (i == wps.size() - 1)
		var lbl := Label3D.new()
		lbl.text = str(i + 1)
		lbl.font_size = 32
		# 原来编号挂在 2 米高的悬空环上，俯视角看是飘的；改成贴地抬高 0.6 米
		lbl.position = Vector3(p.x, float(height_fn.call(p)) + 0.6, p.z)
		lbl.modulate = Color.GREEN if is_last else (Color(1.0, 0.55, 0.0) if is_loop else Color.CYAN)
		lbl.render_priority = 11
		lbl.no_depth_test = true
		guide.add_child(lbl)

# 路径点可能是 Vector3，也可能是快照里的 [x,y,z] 数组或 {x,y,z} 字典
func _path_point_to_vector3(v) -> Vector3:
	if v is Vector3:
		return v
	if v is Array and v.size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	if v is Dictionary and v.has("x") and v.has("z"):
		return Vector3(float(v["x"]), float(v.get("y", 0.0)), float(v["z"]))
	return Vector3(INF, INF, INF)

# 释放某实体的指引带（连同它下面的编号标签）：_wp_markers 里始终只存一个节点
func _free_waypoint_markers(eid: int) -> void:
	if eid < 0 or not has_meta("_wp_markers"):
		return
	var all_wp = get_meta("_wp_markers")
	if not all_wp.has(eid):
		return
	for m in all_wp[eid]:
		if is_instance_valid(m):
			m.queue_free()
	all_wp.erase(eid)

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

		# 修理中（联机）：位置压在升级条下方，样式与建造条一致
		if type == 1 and float(info.get("repair_timer", 0.0)) > 0.0:
			if Engine.get_process_frames() % 40 == 0:
				AudioManager.play_sfx_3d("build_loop", node.global_position, _get_cam_pos())
			var rbar = _get_or_create_repair_bar(id)
			var rlab = _get_or_create_repair_label(id)
			var rt := maxf(float(info.get("max_repair_time", 0.0)), 0.001)
			var rp := clampf(1.0 - float(info["repair_timer"]) / rt, 0.0, 1.0)
			rbar.visible = true; rlab.visible = show_unit_text
			rbar.value = rp
			var nm3 = info["name"]
			var _gpfx4 = _get_entity_group_prefix(info["id"])
			rlab.text = _gpfx4 + "%s (修理中 %d%%)" % [nm3, int(rp * 100.0)]
			var _lbc4 = _get_entity_label_color(info)
			rlab.add_theme_color_override("font_color", _lbc4)
			_apply_label_nation_outline(rlab, info)
			var rwp = node.global_position + Vector3.UP * (info["body_radius"]*2 + 0.5)
			var rsp = cam.unproject_position(rwp)
			if viewport_rect.has_point(rsp):
				rbar.position = rsp - Vector2(30, 4) + Vector2(0, 18)
				rlab.position = rbar.position + Vector2(0, -22)
				rlab.visible = show_unit_text
			else:
				rbar.visible = false; rlab.visible = false
		else:
			_hide_repair_bars(id)

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
		if bd.get("repair_bar"): bd.repair_bar.visible = false
		if bd.get("repair_label"): bd.repair_label.visible = false

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

# ==================== 修理进度条（联机） ====================
# 单机的修理条画在 scripts/ui/HUD.gd；联机没有真实 Building 对象，只能靠快照的
# repair_timer / max_repair_time 在这里画，位置与建造条一致。
func _get_or_create_repair_bar(id) -> ProgressBar:
	if not unit_bars.has(id):
		unit_bars[id] = { "bar":null, "label":null, "prod_bar":null, "prod_label":null, "order_label":null }
	if not unit_bars[id].has("repair_bar") or not unit_bars[id].repair_bar:
		var p = ProgressBar.new()
		UITheme.style_progress_bar(p, REPAIR_BAR_COLOR, 8.0)
		add_child(p)
		unit_bars[id].repair_bar = p
	return unit_bars[id].repair_bar

func _get_or_create_repair_label(id) -> Label:
	if not unit_bars.has(id):
		unit_bars[id] = { "bar":null, "label":null, "prod_bar":null, "prod_label":null, "order_label":null }
	if not unit_bars[id].has("repair_label") or not unit_bars[id].repair_label:
		var l = Label.new()
		l.add_theme_font_size_override("font_size", 12)
		l.add_theme_color_override("font_color", REPAIR_BAR_COLOR)
		add_child(l)
		unit_bars[id].repair_label = l
	return unit_bars[id].repair_label

func _hide_repair_bars(id) -> void:
	if unit_bars.has(id):
		if unit_bars[id].has("repair_bar") and unit_bars[id].repair_bar:
			unit_bars[id].repair_bar.visible = false
		if unit_bars[id].has("repair_label") and unit_bars[id].repair_label:
			unit_bars[id].repair_label.visible = false

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
		if data.get("repair_bar"): data.repair_bar.queue_free()
		if data.get("repair_label"): data.repair_label.queue_free()
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

# 贴地视觉（范围圈 / 路径指引带）用的地形高度函数：
# GroundStripMesh.height_fn_for 需要一个「有 Map 子节点、且 Map 有 get_height_at」的对象，
# 传 self 即可；拿不到地形时会退回点的原始 y，不会把贴地带压到 0 高度。
func get_ground_height_fn() -> Callable:
	return GroundStripMesh.height_fn_for(self)

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
			# 船只持续航行音；陆地脚步已由 _update_client_ground_trail 按落脚触发
			var ord = inf.get("current_order", "")
			if ord in ["move", "deliver"] and inf.get("health", 0) > 0 and _is_audible(n.global_position):
				var eid_walk := int(inf.get("entity_id", 0))
				if eid_walk in [9, 13, 14, 39, 40] and get_terrain_at(n.global_position) == 2:
					AudioManager.play_sfx_3d("sail", n.global_position, _get_cam_pos())
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
