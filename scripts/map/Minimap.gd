# scripts/ui/Minimap.gd
class_name  Minimap
extends Control

const TERRAIN_BRIGHTNESS = 0.55
const MINIMAP_SIZE = 400

var terrain_colors: Array = []
var explored_grid: Array = []
var visible_grid: Array = []
var entity_snapshots: Array = []
var player_team: int = 1
var camera: Camera3D = null

var _player_colors: Dictionary = {}



# 纹理缓存 — 避免每帧 22500 次 draw_rect 调用
var _terrain_tex: ImageTexture = null
var _tex_dirty: bool = true

# 战事警报系统
var alert_signals: Array = []
const ALERT_DURATION: float = 3.0
const ALERT_MAX_RADIUS: float = 35.0
const ALERT_PULSE_PERIOD: float = 0.5

var latest_alert_world_pos: Vector3 = Vector3.ZERO
var has_latest_alert: bool = false

func _ready():
	custom_minimum_size = Vector2(MINIMAP_SIZE, MINIMAP_SIZE)
	mouse_filter = MOUSE_FILTER_STOP
	camera = get_viewport().get_camera_3d()
	# 获取玩家颜色映射（联机模式）
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm and bm.has_method("get_player_colors"):
		_player_colors = bm.get_player_colors()

	set_process(true)

func add_alert(world_pos: Vector3):
	var ms = RTSConfig.MAP_SIZE
	latest_alert_world_pos = world_pos
	has_latest_alert = true
	var gx = world_pos.x + ms / 2.0
	var gz = world_pos.z + ms / 2.0
	if gx < 0 or gx >= ms or gz < 0 or gz >= ms:
		return
	var cell = float(MINIMAP_SIZE) / ms
	for alert in alert_signals:
		if alert["pos"].distance_to(Vector2(gx * cell, gz * cell)) < 3.0 and alert["timer"] > alert["max_time"] - 1.0:
			alert["timer"] = alert["max_time"]
			return
	alert_signals.append({
		"pos": Vector2(gx * cell, gz * cell),
		"timer": ALERT_DURATION,
		"max_time": ALERT_DURATION
	})
	queue_redraw()

func _process(delta):
	var changed = false
	for i in range(alert_signals.size() - 1, -1, -1):
		alert_signals[i]["timer"] -= delta
		if alert_signals[i]["timer"] <= 0:
			alert_signals.remove_at(i)
			changed = true
	if changed:
		queue_redraw()

func set_data(p_explored: Array, p_visible: Array, p_entities: Array):
	explored_grid = p_explored
	visible_grid = p_visible
	entity_snapshots = p_entities
	_tex_dirty = true
	queue_redraw()

func _rebuild_terrain_texture():
	var ms = RTSConfig.MAP_SIZE
	if ms <= 0 or terrain_colors.is_empty() or explored_grid.is_empty():
		return

	var img = Image.create(MINIMAP_SIZE, MINIMAP_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color.BLACK)
	var cell_px = float(MINIMAP_SIZE) / ms

	for gx in range(min(ms, explored_grid.size())):
		var row = explored_grid[gx]
		var trow = terrain_colors[gx]
		var vrow = visible_grid[gx]
		var px_start = int(gx * cell_px)
		var px_end = int((gx + 1) * cell_px)
		for gy in range(min(ms, row.size())):
			if not row[gy]:
				continue
			var col = trow[gy]
			if not vrow[gy]:
				col = col.darkened(0.7) * Color(TERRAIN_BRIGHTNESS, TERRAIN_BRIGHTNESS, TERRAIN_BRIGHTNESS)
			else:
				col = col * Color(TERRAIN_BRIGHTNESS, TERRAIN_BRIGHTNESS, TERRAIN_BRIGHTNESS)
			var py_start = int(gy * cell_px)
			var py_end = int((gy + 1) * cell_px)
			for px in range(px_start, px_end):
				for py in range(py_start, py_end):
					img.set_pixel(px, py, col)

	_terrain_tex = ImageTexture.create_from_image(img)
	_tex_dirty = false

func _draw():
	if terrain_colors.is_empty() or explored_grid.is_empty():
		return

	var ms = RTSConfig.MAP_SIZE
	var cell = float(MINIMAP_SIZE) / ms

	# 重建地形纹理缓存（仅在数据变化时）
	if _tex_dirty or not _terrain_tex:
		_rebuild_terrain_texture()

	# 单次绘制整个地形纹理（替代 22500 次 draw_rect）
	if _terrain_tex:
		draw_texture(_terrain_tex, Vector2.ZERO)

	# 描边
	draw_rect(Rect2(Vector2.ZERO, Vector2(MINIMAP_SIZE, MINIMAP_SIZE)), Color(0.3, 0.55, 0.8, 0.9), false, 3)

	# 实体点
	for ent in entity_snapshots:
		var gx = int(ent["x"] + ms / 2)
		var gz = int(ent["z"] + ms / 2)
		if gx < 0 or gx >= ms or gz < 0 or gz >= ms: continue

		var show = false
		if ent["team"] == player_team:
			show = true
		elif ent["team"] == RTSConfig.Team.NEUTRAL:
			show = explored_grid[gx][gz] if gx < explored_grid.size() and gz < explored_grid[gx].size() else false
		else:
			show = visible_grid[gx][gz] if gx < visible_grid.size() and gz < visible_grid[gx].size() else false
		if not show: continue

		var owner = ent.get("owner_peer_id", -1)
		var dot_color: Color
		if owner != -1 and _player_colors.has(owner):
			dot_color = _player_colors[owner]
		elif ent["team"] == player_team:
			dot_color = Color(0.3, 1.0, 1.0, 1.0)
		elif ent["team"] == RTSConfig.Team.RED:
			dot_color = Color(1.0, 0.5, 0.3, 1.0)
		else:
			dot_color = Color(1.0, 1.0, 0.4, 1.0)
		var pos = Vector2(gx * cell, gz * cell)
		draw_rect(Rect2(pos - Vector2(1, 1), Vector2(3, 3)), dot_color)

	# 战事警报
	for alert in alert_signals:
		var progress = alert["timer"] / alert["max_time"]
		var pulse = abs(sin(Time.get_ticks_msec() / 1000.0 / ALERT_PULSE_PERIOD * PI))
		var radius = lerp(4.0, ALERT_MAX_RADIUS, 1.0 - progress) * (0.6 + 0.4 * pulse)
		var alpha = progress * (0.7 + 0.3 * pulse)
		var ring_color = Color(1.0, 0.15, 0.1, alpha)
		draw_circle(alert["pos"], radius, Color(1.0, 0.2, 0.1, alpha * 0.25))
		draw_arc(alert["pos"], radius, 0, TAU, 32, ring_color, 2.0)

func _gui_input(event):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var local = event.position
		if local.x >= 0 and local.x <= MINIMAP_SIZE and local.y >= 0 and local.y <= MINIMAP_SIZE:
			var world_x = (local.x / MINIMAP_SIZE - 0.5) * RTSConfig.MAP_SIZE
			var world_z = (local.y / MINIMAP_SIZE - 0.5) * RTSConfig.MAP_SIZE
			if camera:
				camera.global_position = Vector3(world_x, camera.global_position.y, world_z)
