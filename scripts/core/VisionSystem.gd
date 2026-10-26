class_name VisionSystem
extends RefCounted

# 统一视野判定：服务端迷雾、客户端迷雾、联机快照裁剪、AI 索敌、建造预览、
# 选中单位视野环全部走这里，避免五套判定各算各的。
#
# 判定顺序：
#   1. 目标必须在观察者有效视野半径内（地图倍率/森林遮蔽/高地加成仍在这里算）；
#   2. 目标地面不能高过观察者头顶 1.5 米；
#   3. 从观察者头顶到目标地面做地形采样，中间山脊挡住后面的低地也看不见；
#   4. 视线连续穿过 2 格森林即被硬遮挡；观察者脚下 2 米内的树忽略，
#      避免林中单位连脚边都看不见。

const HEAD_CLEARANCE: float = 1.5        # 目标最多高过观察者头顶多少米
const FOREST_MIN_RUN: int = 2            # 连续几格森林算硬遮挡
const FOREST_IGNORE_DIST: float = 2.0    # 观察者脚下多少米内的森林不计遮挡
const LOS_TOLERANCE: float = 0.12        # 地形高度容差，防止浮点误差误挡
const LOS_TARGET_INSET: float = 0.8      # 目标格前多少米开始不再检查地形，避免把自己脚下当天花板
const OUTLINE_STEP: float = 0.42         # 视野环射线采样步长
const OUTLINE_MIN_RADIUS: float = 0.6
const MAX_RAY_CELLS: int = 512

# 找到真正的地形节点：战场管理器、ClientRenderer、或者地形节点自己都能传进来。
static func resolve_map(owner) -> Node:
	if owner == null or not is_instance_valid(owner) or not (owner is Node):
		return null
	var map: Node = null
	if owner.has_method("get_map_node"):
		map = owner.get_map_node()
	if map == null and owner.has_node("Map"):
		map = owner.get_node("Map")
	if map == null and owner.get("vertex_grid") != null:
		map = owner
	return map

static func map_size(map) -> int:
	if map != null and is_instance_valid(map) and map.has_method("_get_map_size"):
		return int(map._get_map_size())
	if map != null and is_instance_valid(map):
		var grid = map.get("vertex_grid")
		if grid is Array and grid.size() > 1:
			return grid.size() - 1
	return int(RTSConfig.MAP_SIZE)

static func world_to_grid(pos: Vector3, size: int = -1) -> Vector2i:
	var ms: int = size if size > 0 else int(RTSConfig.MAP_SIZE)
	var half: float = float(ms) * 0.5
	return Vector2i(
		clampi(roundi(pos.x + half), 0, ms - 1),
		clampi(roundi(pos.z + half), 0, ms - 1)
	)

static func grid_to_world(gx: int, gy: int, size: int = -1) -> Vector3:
	var ms: int = size if size > 0 else int(RTSConfig.MAP_SIZE)
	return Vector3(float(gx) - float(ms) * 0.5, 0.0, float(gy) - float(ms) * 0.5)

static func tile_height(map, gx: int, gy: int, size: int = -1) -> float:
	var ms: int = size if size > 0 else map_size(map)
	if gx < 0 or gy < 0 or gx >= ms or gy >= ms:
		return 0.0
	if map == null or not is_instance_valid(map):
		return 0.0
	if map.has_method("get_height_at_grid"):
		return float(map.get_height_at_grid(gx, gy))
	if map.has_method("get_height_at"):
		return float(map.get_height_at(grid_to_world(gx, gy, ms)))
	return 0.0

static func tile_overlay(map, gx: int, gy: int, size: int = -1) -> int:
	var ms: int = size if size > 0 else map_size(map)
	if gx < 0 or gy < 0 or gx >= ms or gy >= ms:
		return 0
	if map == null or not is_instance_valid(map) or not map.has_method("get_overlay"):
		return 0
	return int(map.get_overlay(gx, gy))

# 有效视野：地图倍率 × 高地加成 × 森林遮蔽，供迷雾与可见性判定共用。
static func effective_radius(map, pos: Vector3, raw_vision: float, modifiers: Dictionary) -> int:
	if raw_vision <= 0.0:
		return 0
	var r: float = raw_vision * float(modifiers.get("vision", 1.0))
	var ms: int = map_size(map)
	var g: Vector2i = world_to_grid(pos, ms)
	if tile_overlay(map, g.x, g.y, ms) == 1:
		r *= 0.55
	var hg: float = float(modifiers.get("high_ground_vision", 0.0))
	if hg > 0.0 and tile_height(map, g.x, g.y, ms) >= float(modifiers.get("high_ground_min", 1.0)):
		r *= 1.0 + hg
	return maxi(1, int(round(r)))

# 模型顶部相对实体原点的高度；先算实际 AABB，算不到再用体型兜底。
static func node_head_height(node: Node3D) -> float:
	if node == null or not is_instance_valid(node):
		return 0.0
	var model = node.get_meta("_model_instance", null)
	if model is Node3D and is_instance_valid(model):
		var points: Array = []
		_collect_model_points(model, model.transform, points)
		if not points.is_empty():
			var top: float = -INF
			for p in points:
				top = maxf(top, (p as Vector3).y)
			if top > 0.05:
				return top
	return 0.0

# 递归收集模型网格顶点的实体局部坐标；AABB 是值类型，直接传进去改不到外层，
# 所以这里收集点再统一取最高点。
static func _collect_model_points(node: Node, xform: Transform3D, points: Array) -> void:
	if node is MeshInstance3D:
		var local: AABB = node.get_aabb()
		for i in 8:
			points.append(xform * local.get_endpoint(i))
	for child in node.get_children():
		if child is Node3D:
			_collect_model_points(child, xform * (child as Node3D).transform, points)

# 目标点：实体取脚下地面；地形格取格心地面。
static func entity_target_point(e: Node3D) -> Vector3:
	return e.global_position

# 观察者头顶位置；模型未加载时按体型给一个保守高度。
static func node_vision_origin(node: Node3D, info: Dictionary = {}) -> Vector3:
	var h: float = node_head_height(node)
	if h <= 0.05:
		var radius: float = float(info.get("body_radius", 0.5))
		h = maxf(1.2, radius * 2.0)
	return node.global_position + Vector3.UP * h

# 用 DDA 枚举视线穿过的格子（包含起点、终点格）。
static func ray_cells(map, from: Vector3, to: Vector3, size: int = -1) -> Array:
	var cells: Array = []
	var ms: int = size if size > 0 else map_size(map)
	var half: float = float(ms) * 0.5
	var x0: float = from.x + half + 0.5
	var z0: float = from.z + half + 0.5
	var x1: float = to.x + half + 0.5
	var z1: float = to.z + half + 0.5
	var gx: int = clampi(floori(x0), 0, ms - 1)
	var gz: int = clampi(floori(z0), 0, ms - 1)
	var ex: int = clampi(floori(x1), 0, ms - 1)
	var ez: int = clampi(floori(z1), 0, ms - 1)
	var dx: float = x1 - x0
	var dz: float = z1 - z0
	var step_x: int = 1 if dx > 0.0 else -1
	var step_z: int = 1 if dz > 0.0 else -1
	var t_max_x: float = INF
	var t_max_z: float = INF
	var t_delta_x: float = INF
	var t_delta_z: float = INF
	if absf(dx) > 0.00001:
		t_max_x = (float(gx + (1 if step_x > 0 else 0)) - x0) / dx
		t_delta_x = absf(1.0 / dx)
	if absf(dz) > 0.00001:
		t_max_z = (float(gz + (1 if step_z > 0 else 0)) - z0) / dz
		t_delta_z = absf(1.0 / dz)
	cells.append(Vector2i(gx, gz))
	var guard: int = 0
	while (gx != ex or gz != ez) and guard < MAX_RAY_CELLS:
		guard += 1
		if t_max_x < t_max_z:
			gx += step_x
			t_max_x += t_delta_x
		else:
			gz += step_z
			t_max_z += t_delta_z
		gx = clampi(gx, 0, ms - 1)
		gz = clampi(gz, 0, ms - 1)
		var cell: Vector2i = Vector2i(gx, gz)
		if cells.is_empty() or cells[cells.size() - 1] != cell:
			cells.append(cell)
	return cells

# 判断从 origin（观察者头顶）到 target（目标地面）是否有视线。
static func has_line_of_sight(map, origin: Vector3, target: Vector3, size: int = -1) -> bool:
	if map == null or not is_instance_valid(map):
		return true
	if target.y > origin.y + HEAD_CLEARANCE:
		return false
	var flat: Vector2 = Vector2(target.x - origin.x, target.z - origin.z)
	var dist: float = flat.length()
	if dist < 0.1:
		return true
	var ms: int = size if size > 0 else map_size(map)
	var cells: Array = ray_cells(map, origin, target, ms)
	if cells.size() <= 1:
		return true
	var forest_run: int = 0
	for i in range(1, cells.size()):
		var cell: Vector2i = cells[i]
		var center: Vector3 = grid_to_world(cell.x, cell.y, ms)
		var t: float = clampf(
			((center.x - origin.x) * flat.x + (center.z - origin.z) * flat.y) / maxf(dist * dist, 0.0001),
			0.0, 1.0
		)
		var d: float = dist * t
		var is_target_cell: bool = (i == cells.size() - 1)
		# 目标格自身的地形不参与遮挡；否则山坡上的目标会被自己脚前的坡挡住。
		if not is_target_cell and d < dist - LOS_TARGET_INSET:
			var h: float = tile_height(map, cell.x, cell.y, ms)
			var line_y: float = lerpf(origin.y, target.y, t)
			if h > line_y + LOS_TOLERANCE:
				return false
		# 森林硬遮挡：连续 2 格森林挡住视线；观察者脚下 2 米内的树忽略。
		# 目标格是森林时也计数，这样躲在密林深处的单位不会被外面看见。
		if d >= FOREST_IGNORE_DIST and tile_overlay(map, cell.x, cell.y, ms) == 1:
			forest_run += 1
			if forest_run >= FOREST_MIN_RUN:
				return false
		elif d >= FOREST_IGNORE_DIST:
			forest_run = 0
	return true

# 计算一个观察者当前能看见的格子（flat index = gx * size + gy）。
#
# 这里不能对每个格子都重跑一遍 DDA 视线：后期上百个单位时那是 10 万级采样，
# 每 0.35 秒一次会把主线程拖住。改成从观察者向四周发射细密射线，射线沿途
# 维护“已经越过的地形最高坡度”和“连续森林格数”：
#   - 目标格坡度低于之前地形坡度 → 被山脊挡住；
#   - 连续 2 格森林 → 硬遮挡；
#   - 目标高过观察者头顶 1.5 米 → 不标记（但仍把坡度记入，继续挡后面）。
# 单目标精确判定仍用 has_line_of_sight()。
static func compute_visible_cells(map, origin: Vector3, radius: float, size: int = -1) -> PackedInt32Array:
	var cells: PackedInt32Array = PackedInt32Array()
	if map == null or not is_instance_valid(map) or radius <= 0.0:
		return cells
	var ms: int = size if size > 0 else map_size(map)
	var seen: PackedByteArray = PackedByteArray()
	seen.resize(ms * ms)
	seen.fill(0)
	var origin_g: Vector2i = world_to_grid(origin, ms)
	var origin_idx: int = origin_g.x * ms + origin_g.y
	seen[origin_idx] = 1
	cells.append(origin_idx)
	# 地形数组只取一次，别在最热的循环里反复 has_method / 节点查找。
	var height_grid = map.get("height_grid")
	var overlay_grid = map.get("overlay_grid")
	var use_hgrid: bool = height_grid is Array and height_grid.size() >= ms and height_grid[0] is Array
	var use_ogrid: bool = overlay_grid is Array and overlay_grid.size() >= ms and overlay_grid[0] is Array
	var half: float = float(ms) * 0.5
	var ray_count: int = maxi(72, int(ceil(radius * 12.0)))
	var step: float = maxf(0.4, radius / 48.0)
	for i in ray_count:
		var a: float = TAU * float(i) / float(ray_count)
		var dir_x: float = cos(a)
		var dir_z: float = sin(a)
		var last_gx: int = -999
		var last_gz: int = -999
		var max_slope: float = -INF
		var forest_run: int = 0
		var d: float = step * 0.5
		while d <= radius:
			var px: float = origin.x + dir_x * d
			var pz: float = origin.z + dir_z * d
			var gx: int = clampi(roundi(px + half), 0, ms - 1)
			var gz: int = clampi(roundi(pz + half), 0, ms - 1)
			if gx != last_gx or gz != last_gz:
				last_gx = gx
				last_gz = gz
				var h: float
				var ov: int = 0
				if use_hgrid:
					var hcol = height_grid[gx]
					h = float(hcol[gz]) if hcol is Array and hcol.size() > gz else 0.0
					if use_ogrid:
						var ocol = overlay_grid[gx]
						ov = int(ocol[gz]) if ocol is Array and ocol.size() > gz else 0
				else:
					h = tile_height(map, gx, gz, ms)
					ov = tile_overlay(map, gx, gz, ms)
				var cell_slope: float = (h - origin.y) / maxf(d, 0.001)
				var visible: bool = true
				if h > origin.y + HEAD_CLEARANCE:
					visible = false
				elif cell_slope + LOS_TOLERANCE < max_slope:
					visible = false
				if d >= FOREST_IGNORE_DIST and ov == 1:
					forest_run += 1
					if forest_run >= FOREST_MIN_RUN:
						break
				elif d >= FOREST_IGNORE_DIST:
					forest_run = 0
				if visible:
					var idx: int = gx * ms + gz
					if seen[idx] == 0:
						seen[idx] = 1
						cells.append(idx)
				max_slope = maxf(max_slope, cell_slope)
			d += step
	return cells

# 生成选中单位的视野边界（世界坐标），给 GroundRangeRing 画不规则轮廓。
static func compute_visibility_outline(map, origin: Vector3, radius: float, segments: int = 96) -> Array:
	var pts: Array = []
	if map == null or not is_instance_valid(map) or radius <= 0.0:
		return pts
	var ms: int = map_size(map)
	var segs: int = maxi(32, segments)
	var step: float = maxf(OUTLINE_STEP, radius / 64.0)
	for i in segs:
		var a: float = TAU * float(i) / float(segs)
		var dir: Vector2 = Vector2(cos(a), sin(a))
		var last: float = OUTLINE_MIN_RADIUS
		var d: float = OUTLINE_MIN_RADIUS
		var blocked: bool = false
		while d <= radius:
			var wx: float = origin.x + dir.x * d
			var wz: float = origin.z + dir.y * d
			var g: Vector2i = world_to_grid(Vector3(wx, 0.0, wz), ms)
			var target: Vector3 = Vector3(wx, tile_height(map, g.x, g.y, ms), wz)
			if not has_line_of_sight(map, origin, target, ms):
				blocked = true
				break
			last = d
			d += step
		if not blocked:
			last = radius
		var fx: float = origin.x + dir.x * last
		var fz: float = origin.z + dir.y * last
		var fg: Vector2i = world_to_grid(Vector3(fx, 0.0, fz), ms)
		pts.append(Vector3(fx, tile_height(map, fg.x, fg.y, ms), fz))
	return pts
