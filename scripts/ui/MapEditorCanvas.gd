class_name MapEditorCanvas
extends Control

# 地图编辑器的二维画布：一格=一张地形格，直接读写编辑器数据。
# 用 ImageTexture 缩放显示，避免每帧画一万个矩形。

signal map_changed

const TERRAIN_COLORS := {
	0: Color(0.33, 0.47, 0.25),  # 平原
	1: Color(0.42, 0.40, 0.36),  # 山地
	2: Color(0.16, 0.31, 0.50),  # 水域
}
const OVERLAY_COLORS := {
	1: Color(0.15, 0.32, 0.16),  # 森林
	2: Color(0.30, 0.34, 0.20),  # 沼泽
	3: Color(0.28, 0.52, 0.64),  # 浅滩
	4: Color(0.48, 0.42, 0.32),  # 缓坡
	5: Color(0.58, 0.54, 0.46),  # 台地
}
const RESOURCE_COLORS := {
	0: Color(1.0, 0.84, 0.25),   # 金
	1: Color(0.48, 0.30, 0.16),  # 木
	2: Color(0.66, 0.68, 0.70),  # 石
	3: Color(0.36, 0.80, 0.30),  # 食物
	4: Color(0.20, 0.20, 0.22),  # 油
}

var map_size: int = 100
var terrain: Array = []
var height: Array = []
var overlay: Array = []
var resources: Array = []
var castles: Array = [[25, 50], [75, 50]]
var brush_kind: String = "terrain"
var brush_terrain: int = 0
var brush_overlay: int = 0
var brush_resource: int = 0
var brush_castle: int = 0

var _image: Image
var _texture: ImageTexture
var _painting := false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	custom_minimum_size = Vector2(600, 600)

func set_map_data(data: Dictionary) -> void:
	map_size = clampi(int(data.get("size", 100)), 16, 200)
	terrain = _int_grid(data.get("terrain", []), map_size, 0)
	height = _float_grid(data.get("height", []), map_size, terrain)
	overlay = _int_grid(data.get("overlay", []), map_size, 0)
	resources = []
	for r in data.get("resources", []):
		if r is Dictionary:
			resources.append({"x": int(r.get("x", 0)), "y": int(r.get("y", 0)), "type": int(r.get("type", 0))})
	castles = []
	for c in data.get("castles", []):
		if c is Array and c.size() >= 2:
			castles.append([int(c[0]), int(c[1])])
	if castles.size() < 2:
		castles = [[int(map_size * 0.25), int(map_size * 0.5)], [int(map_size * 0.75), int(map_size * 0.5)]]
	_rebuild_image()
	queue_redraw()

func get_map_data() -> Dictionary:
	return {
		"size": map_size,
		"terrain": terrain.duplicate(true),
		"height": height.duplicate(true),
		"overlay": overlay.duplicate(true),
		"resources": resources.duplicate(true),
		"castles": castles.duplicate(true),
	}

func set_brush(kind: String, value: int) -> void:
	brush_kind = kind
	match kind:
		"terrain":
			brush_terrain = value
			brush_overlay = 0
		"overlay":
			brush_overlay = value
		"resource":
			brush_resource = value
		"castle":
			brush_castle = clampi(value, 0, 1)

func _int_grid(src, size: int, fallback: int) -> Array:
	var out: Array = []
	for x in range(size):
		var row: Array = []
		row.resize(size)
		for y in range(size):
			var v := fallback
			if src is Array and x < src.size() and src[x] is Array and y < src[x].size():
				v = int(src[x][y])
			row[y] = v
		out.append(row)
	return out

func _float_grid(src, size: int, p_terrain: Array) -> Array:
	var out: Array = []
	for x in range(size):
		var row: Array = []
		row.resize(size)
		for y in range(size):
			var v := -1.0 if int(p_terrain[x][y]) == 2 else 0.0
			if src is Array and x < src.size() and src[x] is Array and y < src[x].size():
				v = float(src[x][y])
			row[y] = v
		out.append(row)
	return out

func _cell_color(x: int, y: int) -> Color:
	var t := int(terrain[x][y])
	var ov := int(overlay[x][y])
	var c: Color = TERRAIN_COLORS.get(t, TERRAIN_COLORS[0])
	if ov != 0:
		c = OVERLAY_COLORS.get(ov, c)
	# 高度只做轻微明暗，保留可读的地形类型
	var h := float(height[x][y])
	if t == 1:
		c = c.lightened(clampf(h / 24.0, 0.0, 0.22))
	elif t == 0 and h > 0.4:
		c = c.lightened(clampf(h / 12.0, 0.0, 0.12))
	return c

func _rebuild_image() -> void:
	_image = Image.create(map_size, map_size, false, Image.FORMAT_RGBA8)
	for x in range(map_size):
		for y in range(map_size):
			_image.set_pixel(x, y, _cell_color(x, y))
	_texture = ImageTexture.create_from_image(_image)

func _refresh_pixel(x: int, y: int) -> void:
	if _image == null:
		return
	_image.set_pixel(x, y, _cell_color(x, y))
	if _texture != null:
		_texture.update(_image)
	queue_redraw()

func _cell_size() -> float:
	return minf(size.x, size.y) / float(map_size)

func _cell_origin() -> Vector2:
	var cs := _cell_size()
	return Vector2((size.x - cs * map_size) * 0.5, (size.y - cs * map_size) * 0.5)

func _grid_at(pos: Vector2) -> Vector2i:
	var cs := _cell_size()
	var local := (pos - _cell_origin()) / cs
	return Vector2i(floori(local.x), floori(local.y))

func _set_height_for_brush(x: int, y: int) -> void:
	var t := int(terrain[x][y])
	var ov := int(overlay[x][y])
	if t == 2:
		height[x][y] = -0.6 if ov == 3 else -1.2
	elif t == 1:
		height[x][y] = 3.0 if ov == 0 else (1.5 if ov == 4 else 3.5)
	else:
		height[x][y] = 0.0

func _paint_at(x: int, y: int) -> void:
	if x < 0 or y < 0 or x >= map_size or y >= map_size:
		return
	match brush_kind:
		"terrain":
			terrain[x][y] = brush_terrain
			overlay[x][y] = 0
			_set_height_for_brush(x, y)
		"overlay":
			overlay[x][y] = brush_overlay
			if brush_overlay == 1 or brush_overlay == 2:
				terrain[x][y] = 0
			elif brush_overlay == 3:
				terrain[x][y] = 2
			elif brush_overlay == 4 or brush_overlay == 5:
				terrain[x][y] = 1
			_set_height_for_brush(x, y)
		"resource":
			if terrain[x][y] == 2 or terrain[x][y] == 1:
				terrain[x][y] = 0
				overlay[x][y] = 0
				height[x][y] = 0.0
			_remove_resource_at(x, y)
			resources.append({"x": x, "y": y, "type": brush_resource})
		"resource_erase":
			_remove_resource_at(x, y)
			queue_redraw()
			map_changed.emit()
			return
		"castle":
			var idx := brush_castle
			while castles.size() <= idx:
				castles.append([int(map_size * 0.25), int(map_size * 0.5)])
			castles[idx] = [x, y]
			# 出生点周围压平，避免城堡落在水里
			for dx in range(-3, 4):
				for dy in range(-3, 4):
					var nx := clampi(x + dx, 0, map_size - 1)
					var ny := clampi(y + dy, 0, map_size - 1)
					terrain[nx][ny] = 0
					overlay[nx][ny] = 0
					height[nx][ny] = 0.0
			_rebuild_image()
			map_changed.emit()
			return
	_refresh_pixel(x, y)
	map_changed.emit()

func _remove_resource_at(x: int, y: int) -> void:
	for i in range(resources.size() - 1, -1, -1):
		var r: Dictionary = resources[i]
		if int(r.get("x", -1)) == x and int(r.get("y", -1)) == y:
			resources.remove_at(i)

func _erase_at(x: int, y: int) -> void:
	if x < 0 or y < 0 or x >= map_size or y >= map_size:
		return
	if brush_kind == "resource" or brush_kind == "resource_erase":
		_remove_resource_at(x, y)
		map_changed.emit()
		queue_redraw()
		return
	terrain[x][y] = 0
	overlay[x][y] = 0
	height[x][y] = 0.0
	_refresh_pixel(x, y)
	map_changed.emit()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_painting = event.pressed
			if event.pressed:
				var g := _grid_at(event.position)
				_paint_at(g.x, g.y)
				accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			var g := _grid_at(event.position)
			_erase_at(g.x, g.y)
			accept_event()
	elif event is InputEventMouseMotion and _painting:
		var g := _grid_at(event.position)
		_paint_at(g.x, g.y)
		accept_event()

func _draw() -> void:
	var cs := _cell_size()
	var origin := _cell_origin()
	if _texture != null:
		draw_texture_rect(_texture, Rect2(origin, Vector2(cs * map_size, cs * map_size)), false)
	# 资源点
	for r in resources:
		var p := origin + Vector2((float(r["x"]) + 0.5) * cs, (float(r["y"]) + 0.5) * cs)
		var col: Color = RESOURCE_COLORS.get(int(r["type"]), Color.WHITE)
		draw_circle(p, maxf(2.5, cs * 0.36), col)
	# 出生点
	for i in range(castles.size()):
		var c = castles[i]
		var p := origin + Vector2((float(c[0]) + 0.5) * cs, (float(c[1]) + 0.5) * cs)
		draw_circle(p, maxf(5.0, cs * 0.9), Color(0.25, 0.55, 1.0) if i == 0 else Color(1.0, 0.35, 0.30))
		draw_arc(p, maxf(5.0, cs * 0.9), 0, TAU, 16, Color.WHITE, 1.5)
	# 10 格辅助线
	var grid_col := Color(1, 1, 1, 0.18)
	for i in range(0, map_size + 1, 10):
		var off := origin + Vector2(i * cs, 0)
		draw_line(off, off + Vector2(0, cs * map_size), grid_col, 1.0)
		var off2 := origin + Vector2(0, i * cs)
		draw_line(off2, off2 + Vector2(cs * map_size, 0), grid_col, 1.0)
	draw_rect(Rect2(origin, Vector2(cs * map_size, cs * map_size)), Color(0.9, 0.78, 0.45), false, 2.0)
