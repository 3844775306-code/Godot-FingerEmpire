extends Control

const MINIMAP_SIZE = 400
const TERRAIN_BRIGHTNESS = 0.55

var terrain_colors: Array = []
var explored_grid: Array = []
var visible_grid: Array = []
var entity_snapshots: Array = []
var camera: Camera3D = null
var player_colors: Dictionary = {}
var player_team: int = -1

# 纹理缓存 — 避免每帧 22500 次 draw_rect 调用
var _terrain_tex: ImageTexture = null
var _tex_dirty: bool = true
# 缓存 renderer 引用
var _renderer = null

func _ready():
	custom_minimum_size = Vector2(MINIMAP_SIZE, MINIMAP_SIZE)
	mouse_filter = MOUSE_FILTER_STOP
	camera = get_viewport().get_camera_3d()
	_renderer = get_tree().get_first_node_in_group("client_renderer")
	if _renderer:
		player_team = _renderer.player_team
		player_colors = _renderer.player_colors

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
	var MAP_SIZE = RTSConfig.MAP_SIZE
	var CELL_SIZE = float(MINIMAP_SIZE) / MAP_SIZE

	if terrain_colors.is_empty() or explored_grid.is_empty():
		draw_rect(Rect2(Vector2.ZERO, Vector2(MINIMAP_SIZE, MINIMAP_SIZE)), Color.GRAY)
		return

	# 重建地形纹理缓存（仅在数据变化时）
	if _tex_dirty or not _terrain_tex:
		_rebuild_terrain_texture()

	# 单次绘制整个地形纹理（替代 22500 次 draw_rect）
	if _terrain_tex:
		draw_texture(_terrain_tex, Vector2.ZERO)

	for ent in entity_snapshots:
		var gx = int(ent["x"] + MAP_SIZE / 2)
		var gy = int(ent["z"] + MAP_SIZE / 2)
		if gx < 0 or gx >= MAP_SIZE or gy < 0 or gy >= MAP_SIZE: continue

		var show = false
		var owner = ent.get("owner_peer_id", -1)
		if _renderer and owner == _renderer.my_peer_id:
			show = true
		elif ent["team"] == player_team:
			show = true
		elif ent["team"] == RTSConfig.Team.NEUTRAL:
			show = explored_grid[gx][gy]
		else:
			show = visible_grid[gx][gy]
		if not show: continue

		var dot_color = Color(0.7, 0.7, 0.7)
		if owner != -1 and player_colors.has(owner):
			dot_color = player_colors[owner].lightened(0.25)
		elif ent["team"] == RTSConfig.Team.RED:
			dot_color = Color(1.0, 0.25, 0.2)
		elif ent["team"] == RTSConfig.Team.BLUE:
			dot_color = Color(0.3, 0.5, 1.0)

		var pos = Vector2(gx * CELL_SIZE, gy * CELL_SIZE)
		draw_rect(Rect2(pos - Vector2(1, 1), Vector2(3, 3)), dot_color)

	# Border on top
	draw_rect(Rect2(Vector2.ZERO, Vector2(MINIMAP_SIZE, MINIMAP_SIZE)), Color(0.3, 0.55, 0.8, 0.9), false, 3)

func _gui_input(event):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var local = event.position
		if local.x >= 0 and local.x <= MINIMAP_SIZE and local.y >= 0 and local.y <= MINIMAP_SIZE:
			var MAP_SIZE = RTSConfig.MAP_SIZE
			var world_x = (local.x / MINIMAP_SIZE - 0.5) * MAP_SIZE
			var world_z = (local.y / MINIMAP_SIZE - 0.5) * MAP_SIZE
			if camera:
				camera.global_position = Vector3(world_x, camera.global_position.y, world_z)
