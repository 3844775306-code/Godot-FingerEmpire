# scripts/map/MapGenerator.gd
extends Node3D

const TEX_SIZE = 512

# 强制覆盖地图尺寸（0表示使用全局常量）
var map_size_override: int = 0

# 内部获取实际地图尺寸
func _get_map_size() -> int:
	return map_size_override if map_size_override > 0 else RTSConfig.MAP_SIZE

# 地形数据 0=平原, 1=山地, 2=水域
var terrain_grid: Array = []
var base_colors: Array = []           # 原始颜色 (MAP_SIZE x MAP_SIZE)
var terrain_image: Image
var terrain_texture: ImageTexture
var terrain_mesh_instance: MeshInstance3D
var vertex_grid: Array = []           # 存储顶点高度，用于快速查询
var height_scale: float = 2.0         # 高度缩放系数

# 城堡坐标（世界坐标）
var player_castle_pos: Vector3 = Vector3.ZERO
var enemy_castle_pos: Vector3 = Vector3.ZERO

# 资源生成列表
var resource_positions: Array = []

# 自定义地图种子（为0则随机）
var custom_seed: int = 0

# 防止重复生成
var map_generated: bool = false

func _ready():
	# 联机客户端：不自动生成，等待服务器地图数据
	if NetworkManager.mode == NetworkManager.Mode.CLIENT:
		return
	# 如果已经生成过，跳过
	if map_generated:
		return
	_generate_terrain()
	_place_castles()
	_place_resources()
	_create_visual_and_texture()
	_create_chunked_collisions()
	map_generated = true

# 服务器发来的完整地图数据直接覆盖
func apply_received_map(p_terrain: Array, p_resources: Array):
	# 清除旧的视觉和碰撞体
	for child in get_children():
		if child.name.begins_with("TerrainPlane") or child.name == "NavRegion":
			child.queue_free()

	# 同步地图尺寸
	map_size_override = p_terrain.size()
	var size = _get_map_size()

	# 覆盖地形网格和颜色
	terrain_grid = p_terrain.duplicate(true)
	base_colors.clear()
	for x in range(size):
		var color_col = []
		for y in range(size):
			var t = terrain_grid[x][y]
			var c: Color
			match t:
				0: c = Color.DARK_GREEN
				1: c = Color.SADDLE_BROWN
				2: c = Color.DEEP_SKY_BLUE
			color_col.append(c)
		base_colors.append(color_col)

	# 覆盖资源列表
	resource_positions.clear()
	for r in p_resources:
		var pos = Vector3(r["x"], r["y"], r["z"])
		resource_positions.append({"pos": pos, "type": r["type"]})

	# 重新生成视觉、碰撞、导航
	_create_visual_and_texture()
	_create_chunked_collisions()
	print("[地图] 已应用服务器地图，尺寸:", size)

# ---------- 地形生成 ----------
func _generate_terrain():
	var size = _get_map_size()
	print("实际地图尺寸:", size)

	var noise = FastNoiseLite.new()
	if custom_seed != 0:
		noise.seed = custom_seed
	else:
		noise.seed = randi()
	noise.frequency = 0.03
	noise.fractal_octaves = 4

	terrain_grid.clear()
	base_colors.clear()
	for x in range(size):
		var col = []
		var color_col = []
		for y in range(size):
			var val = noise.get_noise_2d(x, y)
			var type = 0
			var color: Color
			if val > 0.3:
				type = 1
				color = Color.SADDLE_BROWN
			elif val < -0.25:
				type = 2
				color = Color.DEEP_SKY_BLUE
			else:
				type = 0
				color = Color.DARK_GREEN
			col.append(type)
			color_col.append(color)
		terrain_grid.append(col)
		base_colors.append(color_col)

# ---------- 城堡选址 ----------
func get_four_castle_positions() -> Array:
	var size = _get_map_size()
	var half = size / 2.0
	var margin = 10
	var safe_size = 7

	var blue1 = _find_castle_spot_in_region(margin, half + margin, half - margin, size - margin, safe_size)
	var blue2 = _find_castle_spot_in_region(half + margin, half + margin, size - margin, size - margin, safe_size)
	var red1 = _find_castle_spot_in_region(margin, margin, half - margin, half - margin, safe_size)
	var red2 = _find_castle_spot_in_region(half + margin, margin, size - margin, half - margin, safe_size)

	if blue1 == Vector3.ZERO: blue1 = _force_flat_spot(half - 20, half + 20, safe_size)
	if blue2 == Vector3.ZERO: blue2 = _force_flat_spot(half + 20, half + 20, safe_size)
	if red1 == Vector3.ZERO: red1 = _force_flat_spot(half - 20, half - 20, safe_size)
	if red2 == Vector3.ZERO: red2 = _force_flat_spot(half + 20, half - 20, safe_size)

	return [blue1, blue2, red1, red2]

func _force_flat_spot(gx: int, gy: int, safe_size: int) -> Vector3:
	var size = _get_map_size()
	for dx in range(-safe_size, safe_size + 1):
		for dy in range(-safe_size, safe_size + 1):
			var nx = clampi(gx + dx, 0, size - 1)
			var ny = clampi(gy + dy, 0, size - 1)
			terrain_grid[nx][ny] = 0
	return grid_to_world(gx, gy)

func _place_castles():
	var size = _get_map_size()
	var half = size / 2.0
	var margin = 10
	var safe_size = 7

	player_castle_pos = _find_castle_spot_in_region(margin, half + safe_size, half - safe_size, size - margin, safe_size)
	if player_castle_pos == Vector3.ZERO:
		player_castle_pos = grid_to_world(half - 15, half + 15)

	enemy_castle_pos = _find_castle_spot_in_region(half + safe_size, margin, size - margin, half - safe_size, safe_size)
	if enemy_castle_pos == Vector3.ZERO:
		enemy_castle_pos = grid_to_world(half + 15, half - 15)

func _find_castle_spot_in_region(gx_min, gy_min, gx_max, gy_max, safe_size: int = 5) -> Vector3:
	var size = _get_map_size()
	gx_min = clampi(gx_min, 0, size - 1)
	gy_min = clampi(gy_min, 0, size - 1)
	gx_max = clampi(gx_max, 0, size - 1)
	gy_max = clampi(gy_max, 0, size - 1)

	for _attempt in range(500):
		var cx = randi_range(gx_min + safe_size, gx_max - safe_size)
		var cy = randi_range(gy_min + safe_size, gy_max - safe_size)
		var valid = true
		for dx in range(-safe_size, safe_size + 1):
			for dy in range(-safe_size, safe_size + 1):
				var nx = cx + dx
				var ny = cy + dy
				if nx < 0 or nx >= size or ny < 0 or ny >= size:
					valid = false
					break
				if terrain_grid[nx][ny] != 0:
					valid = false
					break
			if not valid: break
		if valid:
			return grid_to_world(cx, cy)
	return Vector3.ZERO

# ---------- 资源放置 ----------
func _place_resources():
	resource_positions.clear()
	var size = _get_map_size()
	var placed = {}

	var is_2v2 = NetworkManager.selected_mode == NetworkManager.GameMode.TWOVTWO
	var mult = 1.5 if is_2v2 else 1.0

	# Castle positions in grid coordinates
	var player_gx = int(player_castle_pos.x + size/2.0)
	var player_gy = int(player_castle_pos.z + size/2.0)
	var enemy_gx = int(enemy_castle_pos.x + size/2.0)
	var enemy_gy = int(enemy_castle_pos.z + size/2.0)
	var castles = [[player_gx, player_gy, "player"], [enemy_gx, enemy_gy, "enemy"]]
	if is_2v2:
		var four_pos = get_four_castle_positions()
		castles = []
		for fp in four_pos:
			var fgx = int(fp.x + size/2.0)
			var fgy = int(fp.z + size/2.0)
			castles.append([fgx, fgy])

	# ── Guaranteed resources near each castle ──
	# [type, group_size_min, group_size_max, max_dist, terrain, label]
	var guaranteed = [
		{"type":3, "min_sz":3, "max_sz":4, "dist":8,  "terrain":0},  # farmland
		{"type":1, "min_sz":5, "max_sz":6, "dist":12, "terrain":0, "near_mountain":true},  # forest
		{"type":2, "min_sz":2, "max_sz":3, "dist":30, "terrain":1},  # stone
	]
	for castle in castles:
		for gu in guaranteed:
			_place_group_near(gu.type, gu.min_sz, gu.max_sz, castle[0], castle[1], gu.dist, gu.terrain, placed, size, gu.get("near_mountain", false))

	# ── Remaining groups: placed anywhere ──
	var remaining = [
		{"type":0, "count": int(4*mult), "min_sz":1, "max_sz":2, "terrain":0},
		{"type":1, "count": int(8*mult), "min_sz":5, "max_sz":6, "terrain":0, "near_mountain":true},
		{"type":2, "count": int(6*mult), "min_sz":2, "max_sz":3, "terrain":1},
		{"type":3, "count": int(6*mult), "min_sz":3, "max_sz":4, "terrain":0, "away_mountain":true},
		{"type":4, "count": int(6*mult), "min_sz":1, "max_sz":2, "terrain":2},
	]
	for g in remaining:
		for _gi in range(g.count):
			_place_group_random(g.type, g.min_sz, g.max_sz, g.terrain, placed, size, castles, g.get("near_mountain", false), g.get("away_mountain", false))

	# ── Animals ──
	for _i in range(int(8 * mult)):
		var cx = randi_range(8, size - 9); var cy = randi_range(8, size - 9)
		var t = terrain_grid[cx][cy]
		var atype = -1
		if t == 0:
			var r = randf()
			if r < 0.35: atype = 60
			elif r < 0.65: atype = 61
			else: atype = 62
		elif t == 2: atype = 63
		if atype >= 0:
			var herd_size = 3 + randi_range(0, 2)
			for _j in range(herd_size):
				var ax = cx + randi_range(-4, 4); var ay = cy + randi_range(-4, 4)
				if ax >= 0 and ax < size and ay >= 0 and ay < size:
					var at = terrain_grid[ax][ay]
					if (atype == 63 and at == 2) or (atype != 63 and at == 0):
						if not placed.has("a%d,%d" % [ax, ay]):
							resource_positions.append({"pos": grid_to_world(ax, ay), "type": atype})
							placed["a%d,%d" % [ax, ay]] = true

# ── Helper: place a group near a position ──
func _place_group_near(rtype, min_sz, max_sz, cx, cy, max_dist, terrain, placed, size, near_mountain=false):
	var best_x = -1; var best_y = -1
	for _attempt in range(200):
		var tx = cx + randi_range(-max_dist, max_dist)
		var ty = cy + randi_range(-max_dist, max_dist)
		if tx < 0 or tx >= size or ty < 0 or ty >= size: continue
		if terrain_grid[tx][ty] != terrain: continue
		if placed.has("g%d,%d,%d" % [rtype, tx, ty]): continue
		if near_mountain and not _has_nearby_terrain(tx, ty, 1, 3, size): continue
		best_x = tx; best_y = ty; break
	if best_x < 0: return
	placed["g%d,%d,%d" % [rtype, best_x, best_y]] = true
	_spawn_group(rtype, min_sz, max_sz, best_x, best_y, terrain, placed, size)

# ── Helper: place a group randomly on the map ──
func _place_group_random(rtype, min_sz, max_sz, terrain, placed, size, castles, near_mountain=false, away_mountain=false):
	var cx = -1; var cy = -1
	for _attempt in range(100):
		var tx = randi_range(5, size - 6); var ty = randi_range(5, size - 6)
		if terrain_grid[tx][ty] != terrain: continue
		if placed.has("g%d,%d,%d" % [rtype, tx, ty]): continue
		# Away from castles (min 8)
		var too_close = false
		for cs in castles:
			if sqrt((tx-cs[0])**2 + (ty-cs[1])**2) < 8: too_close = true; break
		if too_close: continue
		if near_mountain and not _has_nearby_terrain(tx, ty, 1, 3, size): continue
		if away_mountain and _has_nearby_terrain(tx, ty, 1, 3, size): continue
		# Away from existing groups of same type
		var dup = false
		for k in placed.keys():
			if k.begins_with("g%d," % rtype):
				var ox = int(k.split(",")[1]); var oy = int(k.split(",")[2])
				if sqrt((tx-ox)**2 + (ty-oy)**2) < 15: dup = true; break
		if dup: continue
		cx = tx; cy = ty; break
	if cx < 0: return
	placed["g%d,%d,%d" % [rtype, cx, cy]] = true
	_spawn_group(rtype, min_sz, max_sz, cx, cy, terrain, placed, size)

# ── Spawn individual resources in a group ──
func _spawn_group(rtype, min_sz, max_sz, cx, cy, terrain, placed, size):
	var count = min_sz + randi_range(0, max_sz - min_sz)
	resource_positions.append({"pos": grid_to_world(cx, cy), "type": rtype})
	var placed_count = 1
	for _mt in range(count * 5):
		if placed_count >= count: break
		var mx = cx + randi_range(-4, 4); var my = cy + randi_range(-4, 4)
		if mx < 0 or mx >= size or my < 0 or my >= size: continue
		if terrain_grid[mx][my] != terrain: continue
		if placed.has("r%d,%d" % [mx, my]): continue
		placed["r%d,%d" % [mx, my]] = true
		resource_positions.append({"pos": grid_to_world(mx, my), "type": rtype})
		placed_count += 1

# ── Check if terrain type exists within range ──
func _has_nearby_terrain(x, y, terr_type, radius, size) -> bool:
	for dx in range(-radius, radius+1):
		for dy in range(-radius, radius+1):
			var nx = x + dx; var ny = y + dy
			if nx >= 0 and nx < size and ny >= 0 and ny < size:
				if terrain_grid[nx][ny] == terr_type: return true
	return false

func _create_visual_and_texture():
	var size = _get_map_size()
	var subdivisions = 100
	var mesh = ArrayMesh.new()
	var surface_tool = SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)

	vertex_grid.clear()
	vertex_grid.resize(subdivisions + 1)
	for i in range(subdivisions + 1):
		vertex_grid[i] = []
		vertex_grid[i].resize(subdivisions + 1)

	for x in range(subdivisions + 1):
		for z in range(subdivisions + 1):
			var world_x = (float(x) / subdivisions - 0.5) * size
			var world_z = (float(z) / subdivisions - 0.5) * size
			var height = _get_terrain_height(world_x, world_z)
			vertex_grid[x][z] = height
			surface_tool.set_uv(Vector2(float(x) / subdivisions, float(z) / subdivisions))
			surface_tool.add_vertex(Vector3(world_x, height, world_z))

	for x in range(subdivisions):
		for z in range(subdivisions):
			var i00 = x * (subdivisions + 1) + z
			var i10 = (x + 1) * (subdivisions + 1) + z
			var i01 = x * (subdivisions + 1) + (z + 1)
			var i11 = (x + 1) * (subdivisions + 1) + (z + 1)
			surface_tool.add_index(i00); surface_tool.add_index(i10); surface_tool.add_index(i01)
			surface_tool.add_index(i10); surface_tool.add_index(i11); surface_tool.add_index(i01)

	surface_tool.generate_normals()
	surface_tool.commit(mesh)

	

	terrain_image = Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	var image_w = TEX_SIZE
	var image_h = TEX_SIZE
	for x in range(size):
		for y in range(size):
			var src_color = base_colors[x][y]
			# 计算当前格子对应的纹理像素范围
			var x_start = int(floor(float(x) / size * image_w))
			var y_start = int(floor(float(y) / size * image_h))
			var x_end = int(floor(float(x + 1) / size * image_w))
			var y_end = int(floor(float(y + 1) / size * image_h))
			for px in range(x_start, x_end):
				for py in range(y_start, y_end):
					if px < image_w and py < image_h:
						terrain_image.set_pixel(px, py, src_color)

	terrain_texture = ImageTexture.create_from_image(terrain_image)
	var mat = StandardMaterial3D.new()
	mat.albedo_texture = terrain_texture
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL

	terrain_mesh_instance = MeshInstance3D.new()
	terrain_mesh_instance.name = "TerrainPlane"
	terrain_mesh_instance.mesh = mesh
	terrain_mesh_instance.material_override = mat
	add_child(terrain_mesh_instance)

# ---------- 碰撞与导航 ----------
func _create_chunked_collisions():
	# 移除旧的 NavRegion（场景自带的或之前生成的），防止旧碰撞体干扰射线检测
	for child in get_children():
		if child.name == "NavRegion":
			child.queue_free()

	var size = _get_map_size()          # 使用实际地图尺寸
	var nav_region = NavigationRegion3D.new()
	nav_region.name = "NavRegion"
	nav_region.add_to_group("nav_region")
	var nav_mesh = NavigationMesh.new()
	nav_mesh.agent_radius = 0.5
	nav_mesh.agent_height = 1.2
	nav_mesh.navigation_layers = 1
	nav_region.navigation_mesh = nav_mesh

	var half_map = size / 2.0
	const REGION_SIZE = 10
	for cx in range(0, size, REGION_SIZE):
		for cz in range(0, size, REGION_SIZE):
			var block_size = REGION_SIZE
			var center_x = (cx + REGION_SIZE / 2.0 - half_map)
			var center_z = (cz + REGION_SIZE / 2.0 - half_map)

			var body = StaticBody3D.new()
			# 下沉到最低高度以下，避免遮挡任何实体
			body.position = Vector3(center_x, _get_terrain_height(center_x, center_z), center_z)
			body.collision_layer = 2   # 地面在层2，不干扰单位选择
			body.collision_mask = 0    # 不碰撞任何对象
			var col = CollisionShape3D.new()
			col.shape = BoxShape3D.new()
			col.shape.size = Vector3(block_size, 0.2, block_size)
			body.add_child(col)
			nav_region.add_child(body)

	add_child(nav_region)
	nav_region.bake_navigation_mesh()

# ---------- 迷雾更新 ----------
func apply_fog(explored: Array, visible: Array):
	var size = _get_map_size()
	if base_colors.is_empty() or terrain_grid.is_empty(): return
	if explored.size() != size or visible.size() != size: return
	if explored[0].size() != size or visible[0].size() != size: return

	var image_w = TEX_SIZE
	var image_h = TEX_SIZE
	for x in range(size):
		for y in range(size):
			var explored_val = explored[x][y]
			var visible_val = visible[x][y]
			var base = base_colors[x][y]
			var block_color: Color
			if not explored_val:
				block_color = Color(0.1, 0.1, 0.1, 1.0)
			elif not visible_val:
				block_color = base.darkened(0.7)
				block_color.a = 1.0
			else:
				block_color = base
				block_color.a = 1.0

			# 用 fill_rect 替代逐像素 set_pixel
			var x_start = int(floor(float(x) / size * image_w))
			var y_start = int(floor(float(y) / size * image_h))
			var x_end = int(floor(float(x + 1) / size * image_w))
			var y_end = int(floor(float(y + 1) / size * image_h))
			terrain_image.fill_rect(Rect2i(x_start, y_start, x_end - x_start, y_end - y_start), block_color)

	terrain_texture.update(terrain_image)

# ---------- 工具函数 ----------
func get_height_at(world_pos: Vector3) -> float:
	var size = _get_map_size()
	var subdivisions = 100
	var fx = (world_pos.x / size + 0.5) * subdivisions
	var fz = (world_pos.z / size + 0.5) * subdivisions
	var x = clampi(int(fx), 0, subdivisions)
	var z = clampi(int(fz), 0, subdivisions)
	return vertex_grid[x][z] if vertex_grid.size() > x and vertex_grid[x].size() > z else 0.0

func get_terrain(gx: int, gy: int) -> int:
	if gx >= 0 and gx < terrain_grid.size() and gy >= 0 and gy < terrain_grid[0].size():
		return terrain_grid[gx][gy]
	return -1

func grid_to_world(gx: int, gy: int) -> Vector3:
	var size = _get_map_size()
	return Vector3(gx - size / 2.0, 0, gy - size / 2.0)

func get_base_colors() -> Array:
	return base_colors

func _get_terrain_height(world_x: float, world_z: float) -> float:
	var size = _get_map_size()
	var gx = int(world_x + size / 2.0)
	var gz = int(world_z + size / 2.0)
	gx = clampi(gx, 0, size - 1)
	gz = clampi(gz, 0, size - 1)
	var terrain_type = terrain_grid[gx][gz]
	match terrain_type:
		0: return 0.0
		1: return height_scale * 0.8
		2: return -height_scale * 0.5
	return 0.0

func get_terrain_grid() -> Array:
	return terrain_grid
