# scripts/map/MapGenerator.gd
extends Node3D

const MapPresets = preload("res://scripts/map/MapPresets.gd")

const TEX_SIZE = 512

# 强制覆盖地图尺寸（0表示使用全局常量）
var map_size_override: int = 0

# 内部获取实际地图尺寸
func _get_map_size() -> int:
	return map_size_override if map_size_override > 0 else RTSConfig.MAP_SIZE

# 地形数据 0=平原, 1=山地, 2=水域
var terrain_grid: Array = []
var height_grid: Array = []            # per-tile height values
# 覆盖层 0=无, 1=森林, 2=沼泽(预留), 3=浅滩。只影响移速/视野/观感，不改变地形类型判定
var overlay_grid: Array = []
const CLIFF_THRESHOLD: float = 3.0     # 与 MovementController 的 A* 陡坡阈值一致：高差 > 此值视为不可翻越
# 人工山墙（迷宫/台地/环形山/峡谷）的墙高：必须比相邻地面高出 CLIFF_THRESHOLD 以上，
# 否则部队会顺着缓坡直接翻墙；4.4 也为中层台地（0.9）和噪声起伏留出余量
const WALL_CLIFF_HEIGHT: float = CLIFF_THRESHOLD + 1.4
var base_colors: Array = []           # 原始颜色 (MAP_SIZE x MAP_SIZE)
var terrain_image: Image
var terrain_texture: ImageTexture
var _base_image: Image = null          # 无雾底图（按格平铺的纯色地形）
var _dark_image: Image = null          # “已探索但当前不可见”用的压暗版底图
var _fog_prev_explored: Array = []     # 上一次已应用的探索格，用于只重画变化格
var _fog_prev_visible: Array = []      # 上一次已应用的可见格
var _fog_prev_size: int = -1
var terrain_mesh_instance: MeshInstance3D
var vertex_grid: Array = []           # 存储顶点高度，用于快速查询
var height_scale: float = 2.0         # 高度缩放系数
# 水面材质（用于把船只位置推给着色器做涟漪/尾迹，以及按画质档调反射强度）
var _water_mat: ShaderMaterial = null
var _boat_update_timer: float = 0.0
var _boat_prev: Dictionary = {}        # 船只 instance_id -> 上次采样位置（算航向）
var _boat_prev_cleanup: float = 10.0
const BOAT_SHADER_SLOTS: int = 8
# 平面反射：镜像相机把水面上方的场景渲染到 SubViewport，水面按反射射线落点取样
const WATER_LAYER: int = 19
const WATER_WORLD_Y: float = -0.9
var _refl_viewport: SubViewport = null
var _refl_cam: Camera3D = null
var _refl_enabled: bool = true

# 城堡坐标（世界坐标）
var player_castle_pos: Vector3 = Vector3.ZERO
var enemy_castle_pos: Vector3 = Vector3.ZERO
var multi_castle_positions: Array = []  # 单机多AI：所有基地位置（含玩家）

# 资源生成列表
var resource_positions: Array = []
var _cached_four_castle_positions: Array = []  # cached for consistency
var _cached_six_castle_positions: Array = []  # 3v3 用，缓存保证一致性
var _cached_ffa_castle_positions: Dictionary = {}  # 乱斗 N 国环绕布局缓存（n -> Array）

# 自定义地图种子（为0则随机）
var custom_seed: int = 0

# 当前生效的地图预设（由 GameSettings.map_id 解析，见 MapPresets.gd）
var map_preset: Dictionary = {}

# 特殊地形生成管线的中间状态
var _val_grid: Array = []              # 噪声值，供山脊等算子叠加
var _mountain_threshold: float = 0.3
var _water_threshold: float = -0.25
var _pass_centers: Array = []          # 隘口中心（格坐标），用于争议资源布点
var _river_center: Array = []          # 每行河流中心 x（格坐标），供浅滩算子使用
var _river_centers: Dictionary = {}    # 命名河心记录：多河地图用 name 区分（"a"/"b"）
var _river_paths: Dictionary = {}      # 自由曲线河道采样点：name -> [{pos, tan, w}]，供渡口朝向使用
var _lake_centers: Dictionary = {}     # 湖泊记录：name -> {pos, radius}，供支流/渡口参考
var _sea_width: float = 0.0            # 海峡算子的水面宽度（格），供小岛算子参考
var _ring_radius: float = 0.0          # 环形河中心半径（归一化）
var _ring_width: float = 0.0           # 环形河宽度（归一化）
var _reach_tiles: Dictionary = {}      # 从城堡可达的格集合（仅 reachable_only 地图计算）

# 三岛登陆布局：三座攻方孤岛中心（归一化）、守方大陆中心（归一化）
var _siege_island_centers: Array = []
var _siege_mainland_anchor: Array = [0.5, 0.27]

# 防止重复生成
var map_generated: bool = false

# 是否真的连着远端（headless/单机探针里没有真实 peer，不能发 RPC）
func _has_remote_peer() -> bool:
	var peer = multiplayer.multiplayer_peer
	if peer == null or peer is OfflineMultiplayerPeer:
		return false
	return peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

func _ready():
	# 联机客户端：不自动生成，等待服务器地图数据
	if NetworkManager.mode == NetworkManager.Mode.CLIENT:
		# 先上报"战斗场景已就绪"，主机据此再发地图；同时兜底处理早到/丢失的数据
		if _has_remote_peer():
			NetworkManager.client_scene_ready.rpc_id(1)
		NetworkManager.call_deferred("_client_map_ready")
		return
	# 如果已经生成过，跳过
	if map_generated:
		return
	_resolve_preset()
	_generate_terrain()
	_place_castles()
	_place_resources()
	_create_visual_and_texture()
	_create_chunked_collisions()
	_add_water_box()
	map_generated = true

# 服务器发来的完整地图数据直接覆盖
func apply_received_map(p_terrain: Array, p_height: Array, p_resources: Array, p_overlay: PackedByteArray = PackedByteArray(), p_preset_id: String = ""):
	# 清除旧的视觉和碰撞体
	for child in get_children():
		if child.name.begins_with("TerrainPlane") or child.name == "NavRegion":
			child.queue_free()

	# 同步地图尺寸
	map_size_override = p_terrain.size()
	var size = _get_map_size()

	# 覆盖地形网格和颜色
	if p_preset_id != "":
		map_preset = MapPresets.get_preset(p_preset_id)
	terrain_grid = p_terrain.duplicate(true)
	base_colors.clear()
	height_grid = p_height.duplicate(true)
	# 覆盖层由主机下发（1 字节/格，已压缩）；旧格式缺该数据时按全 0 处理
	overlay_grid.clear()
	var use_overlay: bool = p_overlay.size() >= size * size
	var ov_i := 0
	for x in range(size):
		var orow := []
		orow.resize(size)
		for y in range(size):
			if use_overlay:
				orow[y] = p_overlay[ov_i]
				ov_i += 1
			else:
				orow[y] = 0
		overlay_grid.append(orow)
	for x in range(size):
		var color_col = []
		for y in range(size):
			# 与本地生成走同一个着色函数：类型 + 高度 + 覆盖层，客户端与主机配色一致
			color_col.append(_terrain_color_for(terrain_grid[x][y], height_grid[x][y], x, y, get_overlay(x, y)))
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

func _resolve_preset() -> void:
	map_preset = MapPresets.get_preset(GameSettings.map_id)
	if custom_seed == 0 and GameSettings.map_seed != 0:
		custom_seed = GameSettings.map_seed

# ---------- 地形生成 ----------
func _generate_terrain():
	var size = _get_map_size()
	print("实际地图尺寸:", size, " 地形预设:", map_preset.get("name", "经典大陆"))
	var stages: Array = map_preset.get("stages", [])
	if stages.is_empty():
		_generate_classic(size)
		return
	if not _special_map_supported():
		push_warning("[地图] 特殊地形只支持 1V1/2V2/3V3，乱斗模式回退经典大陆")
		_generate_classic(size)
		return
	_generate_with_stages(size, stages)

# 经典生成：与历史版本逐字节一致，作为默认图与回归基线
func _generate_classic(size: int):
	var noise = FastNoiseLite.new()
	if custom_seed != 0:
		noise.seed = custom_seed
	else:
		noise.seed = randi()
	noise.frequency = 0.03
	noise.fractal_octaves = 4

	terrain_grid.clear()
	height_grid.clear()
	overlay_grid.clear()
	for x in range(size):
		var orow := []
		orow.resize(size)
		orow.fill(0)
		overlay_grid.append(orow)
	base_colors.clear()
	# 第一趟：类型与高度。上色要查邻域（水域深浅靠岸线推断），所以先把整张网格填满
	for x in range(size):
		var col = []
		var height_col = []
		for y in range(size):
			var val = noise.get_noise_2d(x, y)
			var type = 0
			if val > 0.3:
				type = 1
			elif val < -0.25:
				type = 2
			var h = 0.0
			if type == 1: h = val * height_scale * 5.0
			elif type == 0: h = val * 0.3
			else: h = -height_scale * 0.5
			col.append(type)
			height_col.append(h)
		terrain_grid.append(col)
		height_grid.append(height_col)
	# 第二趟：上色
	for x in range(size):
		var color_col = []
		for y in range(size):
			color_col.append(_terrain_color_for(terrain_grid[x][y], height_grid[x][y], x, y))
		base_colors.append(color_col)

# 特殊地形：按预设 stages 管线生成（算子可组合，顺序即执行顺序）
func _generate_with_stages(size: int, stages: Array) -> void:
	_init_stage_grids(size)
	for stage in stages:
		if not (stage is Array) or stage.is_empty():
			continue
		var op := String(stage[0])
		var params: Dictionary = stage[1] if stage.size() > 1 and stage[1] is Dictionary else {}
		match op:
			"noise_base":
				_op_noise_base(size, params)
			"ridge":
				_op_ridge(size, params)
			"passes":
				_op_passes(size, params)
			"river":
				_op_river(size, params)
			"river_path":
				_op_river_path(size, params)
			"lake":
				_op_lake(size, params)
			"fords":
				_op_fords(size, params)
			"crossings":
				_op_crossings(size, params)
			"forest":
				_op_forest(size, params)
			"marsh":
				_op_marsh(size, params)
			"sea":
				_op_sea(size, params)
			"islets":
				_op_islets(size, params)
			"oasis":
				_op_oasis(size, params)
			"ring_river":
				_op_ring_river(size, params)
			"ring_fords":
				_op_ring_fords(size, params)
			"canyon":
				_op_canyon(size, params)
			"terrace":
				_op_terrace(size, params)
			"crater":
				_op_crater(size, params)
			"coast":
				_op_coast(size, params)
			"maze":
				_op_maze(size, params)
			"four_islands":
				_op_four_islands(size, params)
			"coastal_siege":
				_op_coastal_siege(size, params)
			_:
				push_warning("[地图] 未知生成算子: %s" % op)
	_colorize_grid(size)

func _init_stage_grids(size: int) -> void:
	_val_grid = []
	terrain_grid = []
	height_grid = []
	overlay_grid = []
	base_colors = []
	_pass_centers = []
	_reach_tiles = {}
	_river_centers = {}
	_river_paths = {}
	_lake_centers = {}
	for x in range(size):
		var vcol := []
		var tcol := []
		var hcol := []
		var ocol := []
		for y in range(size):
			vcol.append(0.0)
			tcol.append(0)
			hcol.append(0.0)
			ocol.append(0)
		_val_grid.append(vcol)
		terrain_grid.append(tcol)
		height_grid.append(hcol)
		overlay_grid.append(ocol)

# 按噪声值判定类型与高度：公式与经典生成保持一致，两张图的山地/草地观感统一
func _classify_tile(x: int, y: int, val: float) -> void:
	var t := 0
	if val > _mountain_threshold:
		t = 1
	elif val < _water_threshold:
		t = 2
	terrain_grid[x][y] = t
	if t == 1:
		height_grid[x][y] = val * height_scale * 5.0
	elif t == 0:
		height_grid[x][y] = val * 0.3
	else:
		height_grid[x][y] = -height_scale * 0.5

func _op_noise_base(size: int, params: Dictionary) -> void:
	var noise := FastNoiseLite.new()
	noise.seed = custom_seed if custom_seed != 0 else randi()
	noise.frequency = float(params.get("freq", 0.03))
	noise.fractal_octaves = int(params.get("octaves", 4))
	_mountain_threshold = float(params.get("mountain_threshold", 0.3))
	_water_threshold = float(params.get("water_threshold", -0.25))
	for x in range(size):
		for y in range(size):
			var val := noise.get_noise_2d(x, y)
			_val_grid[x][y] = val
			_classify_tile(x, y, val)

# 山脊：叠加一条高斯带，把原本的噪声值整体抬升，山脊之外保持原样
func _op_ridge(size: int, params: Dictionary) -> void:
	var axis := String(params.get("axis", "x"))
	var center := float(params.get("center", 0.5)) * float(size)
	var width := maxf(4.0, float(params.get("width", 24.0)))
	var strength := float(params.get("strength", 0.6))
	var sigma := width * 0.5
	for x in range(size):
		for y in range(size):
			var d := absf((float(y) if axis == "x" else float(x)) - center)
			var ridge := strength * exp(-(d * d) / (2.0 * sigma * sigma))
			var val := float(_val_grid[x][y]) + ridge
			_val_grid[x][y] = val
			_classify_tile(x, y, val)

# 隘口：沿山脊垂直方向打通若干条走廊；只把山地改回平原，不动湖泊
func _op_passes(size: int, params: Dictionary) -> void:
	var count := maxi(1, int(params.get("count", 3)))
	var width := maxi(1, int(params.get("width", 4)))
	var flat_h := float(params.get("height", 0.35))
	var centers: Array = params.get("centers", [])
	var half_w := int(width / 2.0)
	for i in range(count):
		var cx := int(float(i + 1) / float(count + 1) * float(size))
		if i < centers.size():
			cx = int(float(centers[i]) * float(size))
		for dx in range(-half_w, half_w + 1):
			var gx := clampi(cx + dx, 0, size - 1)
			for gy in range(size):
				if terrain_grid[gx][gy] != 1:
					continue
				terrain_grid[gx][gy] = 0
				height_grid[gx][gy] = flat_h
		_pass_centers.append(Vector2i(cx, int(size * 0.5)))

# 河流：沿南北方向的弯曲水带；amp/amp2 两层正弦叠加成自然蜿蜒，
# width_wave 让河面宽窄交替，bulge 在河心加宽，形成可放油井的水面
func _op_river(size: int, params: Dictionary) -> void:
	var center := float(params.get("center", 0.5)) * float(size)
	var width := maxf(2.0, float(params.get("width", 7.0)))
	var amp := float(params.get("amp", 0.05)) * float(size)
	var freq := float(params.get("freq", 0.06))
	var amp2 := float(params.get("amp2", 0.0)) * float(size)
	var freq2 := float(params.get("freq2", 0.11))
	var phase2 := float(params.get("phase2", 0.0))
	var width_wave := clampf(float(params.get("width_wave", 0.0)), 0.0, 0.6)
	var width_freq := float(params.get("width_freq", 2.0))
	var bulge_at := float(params.get("bulge_at", 0.5)) * float(size)
	var bulge_extra := maxf(0.0, float(params.get("bulge_extra", 0.0)))
	var bulge_len := maxf(2.0, float(params.get("bulge_len", 10.0)))
	var river_name := String(params.get("name", "default"))
	_river_center = []
	for y in range(size):
		var bulge := bulge_extra * exp(-pow(float(y) - bulge_at, 2.0) / (2.0 * bulge_len * bulge_len))
		var cx := center + sin(float(y) * freq) * amp + sin(float(y) * freq2 + phase2) * amp2
		_river_center.append(int(round(cx)))
		var wmul := 1.0 + width_wave * sin(float(y) / float(size) * TAU * width_freq + phase2)
		var half_w := (width + bulge) * 0.5 * wmul
		var x0 := maxi(0, int(round(cx - half_w)))
		var x1 := mini(size - 1, int(round(cx + half_w)))
		for x in range(x0, x1 + 1):
			terrain_grid[x][y] = 2
			height_grid[x][y] = -height_scale * 0.5
	_river_centers[river_name] = _river_center.duplicate()

# 浅滩：在指定行位横切河流，标 overlay=3（仍是水，但陆军可按 2.5 成本涉水通过）
# river 参数可指定用哪条河（多河地图），缺省用最近一次生成的河
func _op_fords(size: int, params: Dictionary) -> void:
	var river_key := String(params.get("river", ""))
	var centers: Array = _river_center
	if river_key != "" and _river_centers.has(river_key):
		centers = _river_centers[river_key]
	if centers.is_empty():
		push_warning("[地图] fords 需要先执行 river")
		return
	var positions: Array = params.get("positions", [0.3, 0.7])
	var width := maxi(1, int(params.get("width", 3)))
	var half_w := int(width / 2.0)
	for p in positions:
		var fy := clampi(int(float(p) * float(size)), 0, size - 1)
		var cx: int = centers[fy]
		var left := cx
		while left - 1 >= 0 and terrain_grid[left - 1][fy] == 2:
			left -= 1
		var right := cx
		while right + 1 < size and terrain_grid[right + 1][fy] == 2:
			right += 1
		for dy in range(-half_w, half_w + 1):
			var yy := clampi(fy + dy, 0, size - 1)
			for x in range(left, right + 1):
				overlay_grid[x][yy] = 3
				# 浅滩略高于水面：沙洲露出水线，玩家能一眼看出这里可以涉水
				height_grid[x][yy] = -height_scale * 0.25

# Catmull-Rom 插值：用于自由曲线河道，保证拐弯处平滑
func _catmull_rom(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2 := t * t
	var t3 := t2 * t
	var v := 0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)
	return v

# 自由河道：沿一组归一化控制点画任意走向的曲线河，支持宽度起伏、沿岸摆动与河岸噪声。
# 多次调用即形成支流（不同 name），河道可以穿过湖泊，也可以在任意位置汇合。
func _op_river_path(size: int, params: Dictionary) -> void:
	var river_name := String(params.get("name", "path"))
	var pts_in: Array = params.get("points", [])
	var ctrl: Array = []
	if pts_in.size() < 2:
		ctrl = [Vector2(0.5, -0.06) * float(size), Vector2(0.5, 1.06) * float(size)]
	else:
		for p in pts_in:
			ctrl.append(Vector2(float(p[0]), float(p[1])) * float(size))
	# 端点复制，让曲线严格从第一个控制点开始、到最后一个控制点结束
	var ext: Array = [ctrl[0]]
	for c in ctrl:
		ext.append(c)
	ext.append(ctrl[ctrl.size() - 1])
	var raw: Array = []
	for i in range(ext.size() - 3):
		var p0: Vector2 = ext[i]
		var p1: Vector2 = ext[i + 1]
		var p2: Vector2 = ext[i + 2]
		var p3: Vector2 = ext[i + 3]
		var seg := p1.distance_to(p2)
		var steps := maxi(2, int(ceil(seg / 0.6)))
		for j in range(steps):
			raw.append(_catmull_rom(p0, p1, p2, p3, float(j) / float(steps)))
	if raw.size() < 2:
		return
	# 累积弧长，沿河道做宽度渐变与横向摆动（端点摆动为 0，保证河一定连到地图边缘）
	var cum: Array = [0.0]
	for i in range(1, raw.size()):
		cum.append(float(cum[i - 1]) + raw[i].distance_to(raw[i - 1]))
	var total: float = maxf(0.001, float(cum[cum.size() - 1]))
	var base_w := maxf(2.0, float(params.get("width", 6.0)))
	var end_w := maxf(2.0, float(params.get("width_end", base_w)))
	var width_wave := clampf(float(params.get("width_wave", 0.0)), 0.0, 0.6)
	var width_freq := float(params.get("width_freq", 3.0))
	var width_phase := float(params.get("width_phase", 0.0))
	var wiggle := float(params.get("wiggle", 0.0)) * float(size)
	var wiggle_freq := float(params.get("wiggle_freq", 1.5))
	var wiggle_phase := float(params.get("wiggle_phase", 0.0))
	var samples: Array = []
	for i in range(raw.size()):
		var t := float(cum[i]) / total
		var tan: Vector2 = (raw[mini(i + 1, raw.size() - 1)] - raw[maxi(i - 1, 0)]).normalized()
		if tan == Vector2.ZERO:
			tan = Vector2(0, 1)
		var nrm := Vector2(-tan.y, tan.x)
		var lateral := wiggle * sin(t * TAU * wiggle_freq + wiggle_phase) * sin(t * PI)
		var w := lerpf(base_w, end_w, t) * (1.0 + width_wave * sin(t * TAU * width_freq + width_phase))
		samples.append({"pos": raw[i] + nrm * lateral, "tan": tan, "w": maxf(2.0, w)})
	# 河岸带一点噪声，避免边缘像圆规画出来的
	var seed_val := custom_seed if custom_seed != 0 else randi()
	var noise := FastNoiseLite.new()
	noise.seed = seed_val + 3329
	noise.frequency = float(params.get("bank_freq", 0.18))
	noise.fractal_octaves = 2
	var bank_amp := float(params.get("bank_noise", 0.9))
	var water_h := -height_scale * 0.5
	for s in samples:
		var half_w := float(s.w) * 0.5
		var rad := int(ceil(half_w + bank_amp)) + 1
		var bx := int(round(float(s.pos.x)))
		var by := int(round(float(s.pos.y)))
		for dx in range(-rad, rad + 1):
			for dy in range(-rad, rad + 1):
				var nx := bx + dx
				var ny := by + dy
				if nx < 0 or ny < 0 or nx >= size or ny >= size:
					continue
				var d := sqrt(float(dx * dx + dy * dy))
				var edge := half_w + noise.get_noise_2d(nx, ny) * bank_amp
				if d > edge:
					continue
				terrain_grid[nx][ny] = 2
				height_grid[nx][ny] = water_h
				overlay_grid[nx][ny] = 0
	if bool(params.get("record_path", true)):
		_river_paths[river_name] = samples

# 湖泊：噪声扰动的椭圆水面，可带湖心小洲；与 river_path 配合就是"河注入湖"
func _op_lake(size: int, params: Dictionary) -> void:
	var lake_name := String(params.get("name", "lake"))
	var center: Array = params.get("center", [0.5, 0.5])
	var cx := clampf(float(center[0]), 0.06, 0.94) * float(size)
	var cy := clampf(float(center[1]), 0.06, 0.94) * float(size)
	var radius := maxf(2.0, float(params.get("radius", 0.16)) * float(size))
	var aspect := clampf(float(params.get("aspect", 1.0)), 0.5, 1.8)
	var rough := clampf(float(params.get("rough", 0.22)), 0.0, 0.55)
	var seed_val := custom_seed if custom_seed != 0 else randi()
	var noise := FastNoiseLite.new()
	noise.seed = seed_val + 6421
	noise.frequency = float(params.get("freq", 0.09))
	noise.fractal_octaves = 2
	var water_h := -height_scale * 0.5
	var bcx := int(round(cx))
	var bcy := int(round(cy))
	var rx := int(ceil(radius * (1.0 + rough))) + 1
	var ry := int(ceil(radius * aspect * (1.0 + rough))) + 1
	for dx in range(-rx, rx + 1):
		for dy in range(-ry, ry + 1):
			var nx := bcx + dx
			var ny := bcy + dy
			if nx < 0 or ny < 0 or nx >= size or ny >= size:
				continue
			var ex := float(dx)
			var ey := float(dy) / aspect
			var d := sqrt(ex * ex + ey * ey)
			if d > radius * (1.0 + noise.get_noise_2d(nx, ny) * rough):
				continue
			terrain_grid[nx][ny] = 2
			height_grid[nx][ny] = water_h
			overlay_grid[nx][ny] = 0
	# 湖心小洲：纯地标，给大湖一点层次；湖面太小时不放
	var islet_count := maxi(0, int(params.get("islets", 0)))
	if islet_count > 0 and radius >= 6.0:
		var islet_r := maxi(1, int(round(float(params.get("islet_frac", 0.014)) * float(size))))
		for i in range(islet_count):
			var h := absi(hash(Vector2i(bcx + i * 17, bcy - i * 29)))
			var ang := TAU * float(h % 1000) / 1000.0
			var rr := radius * (0.18 + 0.34 * float((h >> 10) % 100) / 100.0)
			var icx := bcx + int(round(cos(ang) * rr))
			var icy := bcy + int(round(sin(ang) * rr * aspect))
			for dx in range(-islet_r, islet_r + 1):
				for dy in range(-islet_r, islet_r + 1):
					if dx * dx + dy * dy > islet_r * islet_r:
						continue
					var nx2 := icx + dx
					var ny2 := icy + dy
					if nx2 < 0 or ny2 < 0 or nx2 >= size or ny2 >= size:
						continue
					if terrain_grid[nx2][ny2] != 2:
						continue
					terrain_grid[nx2][ny2] = 0
					height_grid[nx2][ny2] = 0.1
					overlay_grid[nx2][ny2] = 0
	_lake_centers[lake_name] = {"pos": Vector2(cx, cy), "radius": radius}

# 渡口：在任意水域上切一条垂直于水流的浅滩带（overlay=3）。
# points 为归一化坐标；朝向优先取最近河道采样点的切线，也可用 angle 强制指定。
# reach/width 分别控制横渡长度与沿河宽度，因此既能横渡窄河，也能在湖面上铺出浅滩沙洲。
func _op_crossings(size: int, params: Dictionary) -> void:
	var points: Array = params.get("points", [])
	if points.is_empty():
		push_warning("[地图] crossings 缺少 points")
		return
	var width := maxf(2.0, float(params.get("width", 4.0)))
	var half_u := width * 0.5
	var reach := float(params.get("reach", 0.0))
	if reach <= 0.0:
		reach = maxf(8.0, float(params.get("reach_frac", 0.18)) * float(size))
	var path_name := String(params.get("path", ""))
	var angle_deg := float(params.get("angle", NAN))
	var water_shallow_h := -height_scale * 0.25
	for p in points:
		var target := Vector2(float(p[0]), float(p[1])) * float(size)
		var tx := clampi(int(round(target.x)), 0, size - 1)
		var ty := clampi(int(round(target.y)), 0, size - 1)
		var tan := Vector2(0, 1)
		var center := target
		if is_nan(angle_deg):
			# 找最近的一条河道采样点，取它的切线作为水流方向
			var best := INF
			var best_pos := target
			var arrs: Array = []
			if path_name != "" and _river_paths.has(path_name):
				arrs.append(_river_paths[path_name])
			else:
				arrs = _river_paths.values()
			for arr in arrs:
				for s in arr:
					var sp: Vector2 = s.pos
					var dd: float = (sp - target).length_squared()
					if dd < best:
						best = dd
						tan = s.tan
						best_pos = sp
			# 点本身就在水面上就以点为渡口中心，否则吸附到最近河道
			if not (terrain_grid[tx][ty] == 2):
				center = best_pos if best < INF else target
		else:
			tan = Vector2(cos(deg_to_rad(angle_deg)), sin(deg_to_rad(angle_deg)))
		var nrm := Vector2(-tan.y, tan.x)
		var bcx := int(round(center.x))
		var bcy := int(round(center.y))
		var r := int(ceil(reach))
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var nx := bcx + dx
				var ny := bcy + dy
				if nx < 0 or ny < 0 or nx >= size or ny >= size:
					continue
				var off := Vector2(dx, dy)
				if absf(off.dot(tan)) > half_u:
					continue
				if absf(off.dot(nrm)) > reach:
					continue
				if terrain_grid[nx][ny] != 2:
					continue
				overlay_grid[nx][ny] = 3
				height_grid[nx][ny] = water_shallow_h

# 森林：低频噪声圈出成片林地（按分位阈值保证覆盖率），再用另一层噪声挖出林间空地
func _op_forest(size: int, params: Dictionary) -> void:
	var coverage := clampf(float(params.get("coverage", 0.38)), 0.05, 0.85)
	var freq := float(params.get("freq", 0.045))
	var clearing := float(params.get("clearing", 0.45))
	var seed_val := custom_seed if custom_seed != 0 else randi()
	var noise := FastNoiseLite.new()
	noise.seed = seed_val
	noise.frequency = freq
	noise.fractal_octaves = 3
	var clr := FastNoiseLite.new()
	clr.seed = seed_val + 977
	clr.frequency = float(params.get("clearing_freq", 0.09))
	clr.fractal_octaves = 2

	# 只在平地上取分位阈值，保证实际覆盖率贴近参数
	var plain_vals: Array = []
	for x in range(size):
		for y in range(size):
			if terrain_grid[x][y] == 0:
				plain_vals.append(noise.get_noise_2d(x, y))
	if plain_vals.is_empty():
		return
	plain_vals.sort()
	var idx := clampi(int(float(plain_vals.size()) * (1.0 - coverage)), 0, plain_vals.size() - 1)
	var threshold: float = plain_vals[idx]
	for x in range(size):
		for y in range(size):
			if terrain_grid[x][y] != 0:
				continue
			if noise.get_noise_2d(x, y) < threshold:
				continue
			if clr.get_noise_2d(x, y) > clearing:
				continue
			overlay_grid[x][y] = 1

# 沼泽：在平原上铺成片湿地（overlay 2），按分位阈值保证覆盖率；压平区会清掉覆盖层
func _op_marsh(size: int, params: Dictionary) -> void:
	var coverage := clampf(float(params.get("coverage", 0.32)), 0.05, 0.85)
	var freq := float(params.get("freq", 0.05))
	var seed_val := custom_seed if custom_seed != 0 else randi()
	var noise := FastNoiseLite.new()
	noise.seed = seed_val + 613
	noise.frequency = freq
	noise.fractal_octaves = 3
	# 只在平地上取分位阈值，保证实际覆盖率贴近参数
	var plains: Array = []
	for x in range(size):
		for y in range(size):
			if terrain_grid[x][y] == 0:
				plains.append(noise.get_noise_2d(x, y))
	if plains.is_empty():
		return
	plains.sort()
	var idx := clampi(int(float(plains.size()) * (1.0 - coverage)), 0, plains.size() - 1)
	var threshold: float = plains[idx]
	for x in range(size):
		for y in range(size):
			if terrain_grid[x][y] != 0:
				continue
			if overlay_grid[x][y] != 0:
				continue
			if noise.get_noise_2d(x, y) < threshold:
				continue
			overlay_grid[x][y] = 2

# 海峡：加宽的 S 形水面纵切全图（复用 river 的河心记录，浅滩算子可直接叠加）
func _op_sea(size: int, params: Dictionary) -> void:
	var frac := float(params.get("width_frac", 0.16))
	_sea_width = maxf(6.0, frac * float(size))
	_op_river(size, {
		"center": params.get("center", 0.5),
		"width": _sea_width,
		"amp": params.get("amp", 0.05),
		"freq": params.get("freq", 0.035),
		"amp2": params.get("amp2", 0.0),
		"freq2": params.get("freq2", 0.11),
		"width_wave": params.get("width_wave", 0.0),
		"width_freq": params.get("width_freq", 2.0),
	})

# 岛屿：在海峡静水里撒岛，避开渡口行（那是唯一陆路通道）。
# 小岛互不相连、与两岸也保持一格水道，形成真正的"隔离岛屿"；
# big 参数额外撒几座大岛，作为海面上的地标与资源点。
func _op_islets(size: int, params: Dictionary) -> void:
	if _river_center.is_empty():
		push_warning("[地图] islets 需要先执行 sea/river")
		return
	var count := maxi(0, int(params.get("count", 14)))
	var big_count := maxi(0, int(params.get("big", 2)))
	var avoid: Array = params.get("avoid", [])
	var band := clampf(float(params.get("band", 0.5)), 0.05, 1.0)
	var r_min := maxi(1, int(params.get("radius_min", 2)))
	var r_max := maxi(r_min, int(params.get("radius_max", 4)))
	var big_r := maxi(r_max + 1, int(params.get("big_radius", 6)))
	var half_width := maxf(3.0, _sea_width * 0.5)
	var seed_val := custom_seed if custom_seed != 0 else randi()
	var isl := FastNoiseLite.new()
	isl.seed = seed_val + 1327
	isl.frequency = float(params.get("freq", 0.07))
	isl.fractal_octaves = 2
	var planted: Array = []   # [Vector2i 中心, 半径]，用于保证岛与岛之间留出水道
	var planted_count := 0
	var guard := 0
	while planted_count < count + big_count and guard < (count + big_count) * 120:
		guard += 1
		var is_big := big_count > 0 and planted_count >= count
		var rad := big_r if is_big else randi_range(r_min, r_max)
		var gy := randi_range(int(float(size) * 0.08), int(float(size) * 0.92))
		var skip := false
		for p in avoid:
			if absi(gy - int(float(p) * float(size))) <= 6:
				skip = true
				break
		if skip:
			continue
		var cx: int = int(_river_center[clampi(gy, 0, _river_center.size() - 1)])
		var gx := cx + int(round(half_width * band * randf_range(-1.0, 1.0)))
		if gx < 3 or gx >= size - 3:
			continue
		if terrain_grid[gx][gy] != 2:
			continue
		if isl.get_noise_2d(gx, gy) < 0.0:
			continue
		# 与已生成的岛保持距离，避免连成一片陆地
		var too_close := false
		for pi in planted:
			var pc: Vector2i = pi[0]
			var pr: int = int(pi[1])
			if Vector2(gx - pc.x, gy - pc.y).length() < float(rad + pr + 2):
				too_close = true
				break
		if too_close:
			continue
		# 岛必须整块落在水里（外圈再留一格水），压到陆地就当这次没撒成
		var ok := true
		for dx in range(-rad - 1, rad + 2):
			for dy in range(-rad - 1, rad + 2):
				if dx * dx + dy * dy > (rad + 1) * (rad + 1):
					continue
				var nx := gx + dx
				var ny := gy + dy
				if nx < 0 or ny < 0 or nx >= size or ny >= size:
					ok = false
					break
				if terrain_grid[nx][ny] != 2:
					ok = false
					break
			if not ok:
				break
		if not ok:
			continue
		for dx in range(-rad, rad + 1):
			for dy in range(-rad, rad + 1):
				if dx * dx + dy * dy > rad * rad:
					continue
				var nx := gx + dx
				var ny := gy + dy
				terrain_grid[nx][ny] = 0
				height_grid[nx][ny] = 0.1
		planted.append([Vector2i(gx, gy), rad])
		planted_count += 1

# 绿洲：在沙海上挖几眼小水面，既是油井落点也是地标；压平区会覆盖成平地
func _op_oasis(size: int, params: Dictionary) -> void:
	var spots: Array = params.get("spots", [[0.28, 0.32], [0.5, 0.62], [0.72, 0.38]])
	var base_r := maxi(1, int(params.get("radius", 3)))
	# 大图（150 格）绿洲按比例放大，否则水面占比太小放不下油井
	var frac_r := float(params.get("radius_frac", 0.0))
	if frac_r > 0.0:
		base_r = maxi(2, int(round(frac_r * float(size))))
	var seed_val := custom_seed if custom_seed != 0 else randi()
	for s in spots:
		var cx := int(float(s[0]) * float(size))
		var cy := int(float(s[1]) * float(size))
		var rad := base_r + int(absi(hash(Vector2i(cx, cy) + Vector2i(seed_val, 0))) % 2)
		for dx in range(-rad, rad + 1):
			for dy in range(-rad, rad + 1):
				if dx * dx + dy * dy > rad * rad:
					continue
				var nx := clampi(cx + dx, 0, size - 1)
				var ny := clampi(cy + dy, 0, size - 1)
				terrain_grid[nx][ny] = 2
				height_grid[nx][ny] = -height_scale * 0.5
				if not overlay_grid.is_empty():
					overlay_grid[nx][ny] = 0

# 环形河：以地图中心为圆心的环状水面，圈内保留河中大岛，圈外保留连续陆地
func _op_ring_river(size: int, params: Dictionary) -> void:
	var radius_frac := clampf(float(params.get("radius_frac", 0.29)), 0.12, 0.46)
	var width_frac := clampf(float(params.get("width_frac", 0.07)), 0.02, 0.16)
	_ring_radius = radius_frac
	_ring_width = width_frac
	var wave := float(params.get("wave", 0.012))
	var seed_val := custom_seed if custom_seed != 0 else randi()
	var noise := FastNoiseLite.new()
	noise.seed = seed_val + 4177
	noise.frequency = 0.05
	noise.fractal_octaves = 2
	var cx := float(size) * 0.5
	var cy := float(size) * 0.5
	var half := width_frac * 0.5
	for x in range(size):
		for y in range(size):
			var dx := float(x) - cx
			var dy := float(y) - cy
			var r := sqrt(dx * dx + dy * dy) / float(size)
			# 环半径带一点噪声起伏，避免看起来像用圆规画的
			var wobble := noise.get_noise_2d(x, y) * wave
			if r >= radius_frac - half + wobble and r <= radius_frac + half + wobble:
				terrain_grid[x][y] = 2
				height_grid[x][y] = -height_scale * 0.5
				if not overlay_grid.is_empty():
					overlay_grid[x][y] = 0

# 环河浅滩：沿若干条径向线把环状水面打通，标记 overlay=3 供陆军涉水
func _op_ring_fords(size: int, params: Dictionary) -> void:
	if _ring_radius <= 0.0:
		push_warning("[地图] ring_fords 需要先执行 ring_river")
		return
	var angles: Array = params.get("angles", [0.0, 120.0, 240.0])
	var width := maxi(1, int(params.get("width", 3)))
	var half := int(width / 2.0)
	var cx := float(size) * 0.5
	var cy := float(size) * 0.5
	var r0 := maxf(1.0, (_ring_radius - _ring_width * 0.5 - 0.02) * float(size))
	var r1 := minf(float(size) * 0.48, (_ring_radius + _ring_width * 0.5 + 0.02) * float(size))
	for adeg in angles:
		var a := deg_to_rad(float(adeg))
		var dir := Vector2(cos(a), sin(a))
		var perp := Vector2(-dir.y, dir.x)
		var r := r0
		while r <= r1:
			for w in range(-half, half + 1):
				var px := int(round(cx + dir.x * r + perp.x * float(w)))
				var py := int(round(cy + dir.y * r + perp.y * float(w)))
				if px < 0 or py < 0 or px >= size or py >= size:
					continue
				if terrain_grid[px][py] != 2:
					continue
				overlay_grid[px][py] = 3
				height_grid[px][py] = -height_scale * 0.25
			r += 1.0

# 峡谷：横向谷道贯穿全图，南北两道山壁夹住；谷道在若干处收窄成隘口，
# 山壁上留两条"翻山小径"（缺口）供部队绕到谷外穿插
func _op_canyon(size: int, params: Dictionary) -> void:
	var half := float(params.get("corridor_half", 0.09)) * float(size)
	var thick := maxf(3.0, float(params.get("wall_thick", 0.06)) * float(size))
	var pinches: Array = params.get("pinches", [0.24, 0.5, 0.76])
	var pinch_depth := float(params.get("pinch_depth", 0.05)) * float(size)
	var pinch_sigma := maxf(2.0, float(params.get("pinch_width", 0.06)) * float(size))
	var gates: Array = params.get("gates", [0.14, 0.86])
	var gate_w := maxi(2, int(params.get("gate_width", 4)))
	var seed_val := custom_seed if custom_seed != 0 else randi()
	var noise := FastNoiseLite.new()
	noise.seed = seed_val + 5519
	noise.frequency = float(params.get("edge_freq", 0.06))
	noise.fractal_octaves = 2
	var cy_all := float(size) * 0.5
	var half_gate := int(gate_w / 2.0)
	for x in range(size):
		# 谷道中心轻微蜿蜒，避免看起来是直尺画的
		var cy := cy_all + sin(float(x) / float(size) * TAU) * float(size) * 0.02
		var hw := half
		for p in pinches:
			var d := (float(x) - float(p) * float(size)) / pinch_sigma
			hw -= pinch_depth * exp(-d * d)
		hw = maxf(float(size) * 0.03, hw)
		var gate_here := false
		for g in gates:
			if absi(x - int(float(g) * float(size))) <= half_gate:
				gate_here = true
				break
		for y in range(size):
			var dy := absf(float(y) - cy)
			var inner := hw + noise.get_noise_2d(x, y) * 1.6
			var outer := inner + thick + noise.get_noise_2d(x + 71, y + 23) * 2.0
			if dy >= inner and dy <= outer:
				if gate_here:
					# 翻山小径：山壁上的缺口，谷地与谷外陆地在此连通
					terrain_grid[x][y] = 0
					height_grid[x][y] = 0.0
					overlay_grid[x][y] = 0
				else:
					terrain_grid[x][y] = 1
					height_grid[x][y] = WALL_CLIFF_HEIGHT + noise.get_noise_2d(x + 13, y + 5) * 0.5
					overlay_grid[x][y] = 0
			elif dy < inner:
				# 谷道内部：清成平地，保证主力能展开
				terrain_grid[x][y] = 0
				height_grid[x][y] = 0.0
				overlay_grid[x][y] = 0
	# 隘口中心记作"隘口"，资源布点会把金矿集中到这里（gold_at_passes）
	for p in pinches:
		_pass_centers.append(Vector2i(int(float(p) * float(size)), int(cy_all)))

# 台地：三级高度（低地 - 台地 - 低地），台缘由山脊隔断，只有若干坡道可上；
# 台地高度超过 high_ground_min 时自动获得地图的"高地视野"加成
func _op_terrace(size: int, params: Dictionary) -> void:
	var low_top := clampf(float(params.get("low_top", 0.32)), 0.1, 0.45)
	var mid_top := clampf(float(params.get("mid_top", 0.68)), 0.55, 0.9)
	var ridge_w := clampf(float(params.get("ridge_width", 0.07)), 0.03, 0.14)
	var mid_h := float(params.get("mid_height", 0.9))
	var ridge_h := maxf(float(params.get("ridge_height", WALL_CLIFF_HEIGHT)), WALL_CLIFF_HEIGHT)
	var gaps: Array = params.get("gaps", [0.22, 0.5, 0.78])
	var gap_w := maxi(2, int(params.get("gap_width", 4)))
	var seed_val := custom_seed if custom_seed != 0 else randi()
	var noise := FastNoiseLite.new()
	noise.seed = seed_val + 9137
	noise.frequency = float(params.get("edge_freq", 0.08))
	noise.fractal_octaves = 2
	var half_gap := int(gap_w / 2.0)
	for x in range(size):
		var xf := float(x) / float(size)
		var at_gap := false
		for g in gaps:
			if absf(xf - float(g)) * float(size) <= float(half_gap):
				at_gap = true
				break
		for y in range(size):
			var yf := float(y) / float(size)
			var ridge_band := ridge_w * 0.5 + noise.get_noise_2d(x, y) * 0.012
			var d_low := absf(yf - low_top)
			var d_high := absf(yf - mid_top)
			var is_ridge := (d_low <= ridge_band) or (d_high <= ridge_band)
			if is_ridge and at_gap:
				# 坡道：山脊上的缺口，连接低地与台地
				terrain_grid[x][y] = 0
				height_grid[x][y] = mid_h * 0.5
				overlay_grid[x][y] = 0
			elif is_ridge:
				terrain_grid[x][y] = 1
				height_grid[x][y] = ridge_h + noise.get_noise_2d(x + 37, y + 11) * 0.3
				overlay_grid[x][y] = 0
			elif yf > low_top and yf < mid_top:
				# 中层台地：整片抬高，站上去视野更远
				terrain_grid[x][y] = 0
				height_grid[x][y] = mid_h + noise.get_noise_2d(x, y) * 0.05
				overlay_grid[x][y] = 0
			else:
				terrain_grid[x][y] = 0
				height_grid[x][y] = 0.0
				overlay_grid[x][y] = 0
	# 台地中央的湖：既是油井落点，也是双方争夺的水源
	var lake_r := float(params.get("lake_radius", 0.05))
	if lake_r > 0.0:
		var cr := maxi(2, int(lake_r * float(size)))
		var cx := size / 2
		var cy2 := size / 2
		for dx in range(-cr, cr + 1):
			for dy in range(-cr, cr + 1):
				if dx * dx + dy * dy > cr * cr:
					continue
				var nx := clampi(cx + dx, 0, size - 1)
				var ny := clampi(cy2 + dy, 0, size - 1)
				terrain_grid[nx][ny] = 2
				height_grid[nx][ny] = -height_scale * 0.5
				overlay_grid[nx][ny] = 0
	# 坡道口与台地中心记入隘口：资源布点会在这些位置补金矿
	# 只记下侧台缘的 3 个坡道 + 台地中心，避免金矿数翻倍
	for g in gaps:
		_pass_centers.append(Vector2i(int(float(g) * float(size)), int(low_top * float(size))))
	_pass_centers.append(Vector2i(size / 2, size / 2))

# 环形山：地图中心一圈环形山壁，四个方向各开一处山口；山心是聚金洼地，
# 全图金矿只落在四处山口与山心，逼双方为"进坑"还是"守口"做选择
func _op_crater(size: int, params: Dictionary) -> void:
	var radius_frac := clampf(float(params.get("radius_frac", 0.30)), 0.16, 0.40)
	var width_frac := clampf(float(params.get("width_frac", 0.07)), 0.03, 0.14)
	var gates: Array = params.get("gates", [0, 90, 180, 270])
	var gate_w := maxi(3, int(params.get("gate_width", 6)))
	var seed_val := custom_seed if custom_seed != 0 else randi()
	var noise := FastNoiseLite.new()
	noise.seed = seed_val + 7331
	noise.frequency = 0.07
	noise.fractal_octaves = 2
	var cx := float(size) * 0.5
	var cy := float(size) * 0.5
	var ring_r := radius_frac * float(size)
	var half_w := maxf(2.0, width_frac * float(size) * 0.5)
	var gate_half := float(gate_w) * 0.5
	var gate_tol := rad_to_deg(gate_half / maxf(ring_r, 1.0))
	for x in range(size):
		for y in range(size):
			var dx := float(x) - cx
			var dy := float(y) - cy
			var r := sqrt(dx * dx + dy * dy)
			if r > ring_r + half_w + 3.0:
				continue   # 环外保留噪声地形（平原为主）
			var ang := rad_to_deg(atan2(dy, dx))
			var gate_here := false
			for g in gates:
				var diff := absf(fposmod(ang - float(g) + 180.0, 360.0) - 180.0)
				if diff <= gate_tol:
					gate_here = true
					break
			var wob := noise.get_noise_2d(x, y) * 2.0
			if absf(r + wob - ring_r) <= half_w:
				if gate_here:
					terrain_grid[x][y] = 0
					height_grid[x][y] = 0.0
				else:
					terrain_grid[x][y] = 1
					height_grid[x][y] = WALL_CLIFF_HEIGHT + noise.get_noise_2d(x + 29, y + 17) * 0.45
				overlay_grid[x][y] = 0
			elif r < ring_r - half_w:
				# 山心洼地：整片平地，中央洼下去一点，金矿就撒在这里
				terrain_grid[x][y] = 0
				height_grid[x][y] = 0.0
				overlay_grid[x][y] = 0
	# 东西两处山口 + 山心记入隘口：金矿集中到这三处，南北两口留作纯通道
	var gold_gates: Array = params.get("gold_gates", [0, 180])
	for g in gold_gates:
		var a := deg_to_rad(float(g))
		_pass_centers.append(Vector2i(int(round(cx + cos(a) * ring_r)), int(round(cy + sin(a) * ring_r))))
	_pass_centers.append(Vector2i(size / 2, size / 2))

# 海岸登陆：外围一圈陆地（玩家出生带），中央一座大岛，二者之间是环状海面
func _op_coast(size: int, params: Dictionary) -> void:
	var width_frac := clampf(float(params.get("width_frac", 0.16)), 0.08, 0.26)
	var island_frac := clampf(float(params.get("island_frac", 0.20)), 0.10, 0.30)
	var seed_val := custom_seed if custom_seed != 0 else randi()
	var coast_noise := FastNoiseLite.new()
	coast_noise.seed = seed_val + 9973
	coast_noise.frequency = float(params.get("coast_freq", 0.055))
	coast_noise.fractal_octaves = 2
	var island_noise := FastNoiseLite.new()
	island_noise.seed = seed_val + 2719
	island_noise.frequency = float(params.get("island_freq", 0.045))
	island_noise.fractal_octaves = 2
	var base := width_frac * float(size)
	var water_h := -height_scale * 0.5
	var cx := float(size) * 0.5
	var cy := float(size) * 0.5
	var island_r := island_frac * float(size)
	for x in range(size):
		for y in range(size):
			var edge := float(mini(mini(x, y), mini(size - 1 - x, size - 1 - y)))
			var coast := base + coast_noise.get_noise_2d(x + 91, y + 43) * 3.0
			var nx := (float(x) - cx) / island_r
			var ny := (float(y) - cy) / island_r
			var d := sqrt(nx * nx + ny * ny)
			var island_edge := d + island_noise.get_noise_2d(float(x) + 317.0, float(y) + 127.0) * 0.18
			if edge < coast or island_edge <= 1.0:
				# 外环陆地与中央大岛：平地，保证基地和登陆场能展开
				terrain_grid[x][y] = 0
				height_grid[x][y] = 0.0
				overlay_grid[x][y] = 0
			else:
				# 外环与中央岛之间全部是海水，没有任何陆桥
				terrain_grid[x][y] = 2
				height_grid[x][y] = water_h
				overlay_grid[x][y] = 0

# 迷宫山：三层方环状山壁围成螺旋迷宫，缺口方向内外交替；
# 整片迷宫区先清成平地再叠山墙，保证每条走廊都能走通；中心是唯一金矿区
func _op_maze(size: int, params: Dictionary) -> void:
	var radii: Array = params.get("radii", [0.15, 0.23, 0.31])
	var gaps: Array = params.get("gaps", ["h", "v", "h"])
	var thick := maxf(2.0, float(params.get("thick_frac", 0.03)) * float(size))
	var gap := maxi(3, int(params.get("gap_width", 6)))
	var half_t := thick * 0.5
	var gap_half := float(gap) * 0.5
	var cx := float(size) * 0.5
	var cy := float(size) * 0.5
	var outer_r := float(radii[radii.size() - 1]) * float(size)
	for x in range(size):
		for y in range(size):
			var dx := absf(float(x) - cx)
			var dy := absf(float(y) - cy)
			var sq := maxf(dx, dy)
			if sq > outer_r + half_t:
				continue   # 环外保留噪声地形
			var t := 0
			var h := 0.0
			for i in range(radii.size()):
				var rr := float(radii[i]) * float(size)
				if absf(sq - rr) > half_t:
					continue
				var g := String(gaps[i]) if i < gaps.size() else "h"
				var in_gap := false
				if g == "h":
					in_gap = dx <= gap_half     # 南北向缺口（上下两侧同时开口，镜像公平）
				else:
					in_gap = dy <= gap_half     # 东西向缺口
				if not in_gap:
					t = 1
					h = WALL_CLIFF_HEIGHT
				break
			terrain_grid[x][y] = t
			height_grid[x][y] = h
			overlay_grid[x][y] = 0
	_pass_centers.append(Vector2i(size / 2, size / 2))
	# 中环东西两处缺口各埋一处金矿，避免全图金矿只挤在中心一小块
	if radii.size() >= 2:
		var mid_r := int(float(radii[1]) * float(size))
		_pass_centers.append(Vector2i(size / 2 - mid_r, size / 2))
		_pass_centers.append(Vector2i(size / 2 + mid_r, size / 2))
func _op_four_islands(size: int, params: Dictionary) -> void:
	var water_h := -height_scale * 0.5
	for x in range(size):
		for y in range(size):
			terrain_grid[x][y] = 2
			height_grid[x][y] = water_h
			overlay_grid[x][y] = 0
	var radius := clampi(int(float(size) * float(params.get("radius_frac", 0.14))), 10, 22)
	var corner := clampf(float(params.get("corner", 0.18)), 0.12, 0.26)
	var spots: Array = [
		Vector2(corner, corner), Vector2(1.0 - corner, corner),
		Vector2(corner, 1.0 - corner), Vector2(1.0 - corner, 1.0 - corner),
	]
	if _team_size_for_layout() >= 3:
		spots.append(Vector2(0.5, corner))
		spots.append(Vector2(0.5, 1.0 - corner))
	var rr := float(radius)
	for s in spots:
		var cx := int(float(s.x) * float(size))
		var cy := int(float(s.y) * float(size))
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				if float(dx * dx + dy * dy) > rr * rr:
					continue
				var nx := clampi(cx + dx, 0, size - 1)
				var ny := clampi(cy + dy, 0, size - 1)
				terrain_grid[nx][ny] = 0
				height_grid[nx][ny] = 0.0
				overlay_grid[nx][ny] = 0

# 三岛登陆：上半图一块随机海岸线的大陆（守方），下半图三座随机形状孤岛（攻方）；
# 大陆中部一条小河横贯全图并汇入外海，两处浅滩是越过河线直取主城的必经之路
func _op_coastal_siege(size: int, params: Dictionary) -> void:
	var water_h := -height_scale * 0.5
	for x in range(size):
		for y in range(size):
			terrain_grid[x][y] = 2
			height_grid[x][y] = water_h
			overlay_grid[x][y] = 0

	var seed_val := custom_seed if custom_seed != 0 else randi()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val + 6151
	var coast := FastNoiseLite.new()
	coast.seed = seed_val + 4207
	coast.frequency = float(params.get("coast_freq", 0.075))
	coast.fractal_octaves = 3
	var coast_detail := FastNoiseLite.new()
	coast_detail.seed = seed_val + 5507
	coast_detail.frequency = float(params.get("coast_detail_freq", 0.19))
	coast_detail.fractal_octaves = 2
	var hills := FastNoiseLite.new()
	hills.seed = seed_val + 8811
	hills.frequency = float(params.get("hill_freq", 0.085))
	hills.fractal_octaves = 2

	# ── 大陆：扰动椭圆，只占上半图，四周留出外海 ──
	var cx := (0.5 + rng.randf_range(-0.02, 0.02)) * float(size)
	var cy := float(params.get("mainland_cy", 0.27)) * float(size)
	var rx := float(params.get("mainland_rx", 0.44)) * float(size)
	var ry := float(params.get("mainland_ry", 0.205)) * float(size)
	var bottom := mini(size - 1, int(float(params.get("mainland_bottom", 0.53)) * float(size)))
	var coast_amp := float(params.get("coast_amp", 0.30))
	var margin := maxi(2, int(float(size) * 0.025))
	var mountain_th := float(params.get("mountain_threshold", 0.66))
	for x in range(size):
		for y in range(margin, bottom + 1):
			if x < margin or x >= size - margin:
				continue
			var nx := (float(x) - cx) / rx
			var ny := (float(y) - cy) / ry
			var d := sqrt(nx * nx + ny * ny)
			var edge := d + coast.get_noise_2d(float(x), float(y)) * coast_amp \
				+ coast_detail.get_noise_2d(float(x), float(y)) * coast_amp * 0.35
			if edge > 1.0:
				continue
			var hv := hills.get_noise_2d(float(x), float(y))
			terrain_grid[x][y] = 0
			height_grid[x][y] = clampf(hv, 0.0, 1.0) * 0.16
			# 内陆少量山地，作为守方纵深与远程掩护；海岸带保持可登陆
			if hv > mountain_th and edge < 0.84:
				terrain_grid[x][y] = 1
				height_grid[x][y] = clampf((hv - mountain_th) / maxf(0.001, 1.0 - mountain_th), 0.0, 1.0) * height_scale * 1.8
			overlay_grid[x][y] = 0

	# ── 小河：横向蜿蜒穿过大陆，两端汇入外海；只切陆地，不动海面 ──
	var river_y := float(params.get("river_y", 0.375)) * float(size)
	var river_amp := float(params.get("river_amp", 0.028)) * float(size)
	var river_freq := float(params.get("river_freq", 0.055))
	var river_half := maxi(0, int(params.get("river_width", 2)) / 2)
	var meander := FastNoiseLite.new()
	meander.seed = seed_val + 3313
	meander.frequency = 0.09
	meander.fractal_octaves = 2
	var river_tiles := {}
	for x in range(size):
		var line_y := river_y + sin(float(x) * river_freq) * river_amp + meander.get_noise_1d(float(x)) * float(size) * 0.012
		for dy in range(-river_half, river_half + 1):
			var yy := clampi(int(round(line_y)) + dy, 0, size - 1)
			if terrain_grid[x][yy] == 2:
				continue
			terrain_grid[x][yy] = 2
			height_grid[x][yy] = water_h
			overlay_grid[x][yy] = 0
			river_tiles[Vector2i(x, yy)] = true

	# 两处浅滩：守方可南北调兵，攻方渡河多两个选择（只标在河身上，绝不改海面）
	var fords: Array = params.get("fords", [0.34, 0.66])
	for f in fords:
		var fx := clampi(int(float(f) * float(size)), 1, size - 2)
		for xx in range(fx - 1, fx + 2):
			for y in range(int(float(size) * 0.2), bottom + 1):
				if not river_tiles.has(Vector2i(xx, y)):
					continue
				overlay_grid[xx][y] = 3
				height_grid[xx][y] = -height_scale * 0.25

	# ── 三座孤岛：位置/大小/形状随机，与大陆及彼此之间强制隔水 ──
	var island_centers: Array = []
	var planted: Array = []   # [中心x, 中心y, 横半径, 纵半径]
	var base_x: Array = params.get("island_x", [0.17, 0.5, 0.83])
	var base_y := float(params.get("island_y", 0.78))
	var irx := float(params.get("island_rx", 0.115))
	var iry := float(params.get("island_ry", 0.095))
	var island_amp := float(params.get("island_amp", 0.30))
	var island_top_limit := int(float(size) * 0.60)
	for i in range(base_x.size()):
		var icx := (float(base_x[i]) + rng.randf_range(-0.016, 0.016)) * float(size)
		var icy := (base_y + rng.randf_range(-0.022, 0.022)) * float(size)
		var sx := irx * float(size) * rng.randf_range(0.88, 1.10)
		var sy := iry * float(size) * rng.randf_range(0.88, 1.10)
		var x0 := maxi(1, int(icx - sx * 1.5))
		var x1 := mini(size - 2, int(icx + sx * 1.5))
		var y0 := maxi(island_top_limit, int(icy - sy * 1.5))
		var y1 := mini(size - 2, int(icy + sy * 1.5))
		for x in range(x0, x1 + 1):
			for y in range(y0, y1 + 1):
				var nx := (float(x) - icx) / sx
				var ny := (float(y) - icy) / sy
				var d := sqrt(nx * nx + ny * ny)
				var edge := d + coast.get_noise_2d(float(x) + 711.0, float(y) + 353.0) * island_amp \
					+ coast_detail.get_noise_2d(float(x) + 711.0, float(y) + 353.0) * island_amp * 0.4
				if edge > 1.0:
					continue
				# 与已生成岛屿之间至少留 2 格水道，避免三岛连成一块
				var blocked := false
				for p in planted:
					var pdx := (float(x) - float(p[0])) / (float(p[2]) * (1.0 + island_amp) + 2.0)
					var pdy := (float(y) - float(p[1])) / (float(p[3]) * (1.0 + island_amp) + 2.0)
					if pdx * pdx + pdy * pdy < 1.0:
						blocked = true
						break
				if blocked:
					continue
				terrain_grid[x][y] = 0
				height_grid[x][y] = 0.05
				overlay_grid[x][y] = 0
		planted.append([icx, icy, sx, sy])
		island_centers.append([icx / float(size), icy / float(size)])
	_siege_island_centers = island_centers
	_siege_mainland_anchor = [cx / float(size), cy / float(size)]

func _colorize_grid(size: int) -> void:
	base_colors.clear()
	for x in range(size):
		var color_col := []
		for y in range(size):
			color_col.append(_terrain_color_for(terrain_grid[x][y], height_grid[x][y], x, y, get_overlay(x, y)))
		base_colors.append(color_col)

# ---------- 地形着色 ----------
# 两端共用的着色函数：只由 (类型, 高度) 推导颜色，不依赖原始噪声值。
# 主机用噪声算出的高度，客户端用服务器同步来的高度网格，因此同一块地两端配色完全一致。
# 纯观感，不参与任何寻路/建造判定（那些只认 terrain_grid 的类型）。

func _terrain_color_for(terrain_type: int, h: float, gx: int, gy: int, overlay: int = 0) -> Color:
	var color: Color
	var pal: Dictionary = map_preset.get("palette", {})
	match terrain_type:
		1:  # 山地：山脚土棕 -> 高处灰岩（预设可用 palette.mountain_low/high 换山色）
			color = _pal_color(pal, "mountain_low", Color(0.40, 0.30, 0.18)).lerp(
				_pal_color(pal, "mountain_high", Color(0.64, 0.62, 0.58)),
				clamp(h / (height_scale * 5.0), 0.0, 1.0))
		2:  # 水域：深度没有进高度网格，改用邻域陆地量当靠岸程度 —— 近岸浅亮、远海深暗
			color = _pal_color(pal, "water_deep", Color(0.10, 0.28, 0.50)).lerp(
				_pal_color(pal, "water_shallow", Color(0.24, 0.58, 0.72)), _shore_amount(gx, gy))
		_:  # 草原：低地深绿 -> 高地黄绿（沙漠图改成沙色）
			color = _pal_color(pal, "plain_low", Color(0.12, 0.33, 0.14)).lerp(
				_pal_color(pal, "plain_high", Color(0.42, 0.51, 0.22)),
				clamp((h + 0.075) / 0.165, 0.0, 1.0))
	# 覆盖层着色：森林压暗偏绿、沼泽铺泥、浅滩撒沙
	if overlay == 1:
		color = color.lerp(Color(0.10, 0.26, 0.12), 0.55)
	elif overlay == 2:
		# 沼泽：泥地为主，按格哈希撒出水洼与草甸，远看是斑驳湿地
		var mh := float(absi(hash(Vector2i(gx, gy))) % 1000) / 1000.0
		var mud := Color(0.20, 0.24, 0.14).lerp(Color(0.30, 0.34, 0.20), mh)
		if mh < 0.16:
			mud = Color(0.15, 0.21, 0.20)
		elif mh > 0.95:
			mud = Color(0.34, 0.38, 0.16)
		color = color.lerp(mud, 0.75)
	elif overlay == 3:
		# 浅滩：沙底为主，按格哈希撒出深浅不一的沙粒与偶发水色
		var hv := float(absi(hash(Vector2i(gx, gy))) % 1000) / 1000.0
		var sand := Color(0.66, 0.60, 0.42).lerp(Color(0.82, 0.75, 0.55), hv)
		if hv < 0.18:
			sand = Color(0.50, 0.45, 0.32)     # 深色湿沙
		elif hv > 0.94:
			sand = Color(0.38, 0.52, 0.50)     # 偶发水色
		color = color.lerp(sand, 0.82)
	# 高频细节噪声：明暗微扰打散整片纯色，远看是自然纹理而不是塑料色块
	var d := _get_detail_noise().get_noise_2d(float(gx), float(gy))
	if d > 0.0:
		color = color.lightened(d * 0.09)
	else:
		color = color.darkened(-d * 0.09)
	return color

# 预设调色板取值：支持 [r,g,b] 数组（可用于 const 字典）与 Color 两种写法
func _pal_color(pal: Dictionary, key: String, fallback: Color) -> Color:
	if not pal.has(key):
		return fallback
	var v = pal[key]
	if v is Color:
		return v
	if v is Array and v.size() >= 3:
		return Color(float(v[0]), float(v[1]), float(v[2]))
	return fallback

# 靠岸程度：3x3 邻域里陆地格占比（0=远海，1=贴岸）。水深不会同步给客户端，
# 用邻域陆地量代替，两端都能算，靠岸浅亮、远海深暗的观感就出来了。
func _shore_amount(gx: int, gy: int) -> float:
	var size = _get_map_size()
	if terrain_grid.size() < size or terrain_grid[0].size() < size:
		return 0.0
	var land := 0
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var nx = gx + dx
			var ny = gy + dy
			if nx < 0 or ny < 0 or nx >= size or ny >= size:
				continue
			if terrain_grid[nx][ny] != 2:
				land += 1
	return float(land) / 9.0

var _detail_noise: FastNoiseLite = null
# 细节噪声用固定种子，两端各自独立计算也得到同样的结果，无需同步
func _get_detail_noise() -> FastNoiseLite:
	if _detail_noise == null:
		_detail_noise = FastNoiseLite.new()
		_detail_noise.seed = 20240917
		_detail_noise.frequency = 0.33
		_detail_noise.fractal_octaves = 2
	return _detail_noise

# 画两张地形底图：base 是正常亮度，dark 是迷雾里“已探索但当前不可见”用的压暗版。
# 两张都在这里逐格画一次，之后 apply_fog 只做整块拷贝，不再重算
func _build_terrain_images() -> void:
	var size = _get_map_size()
	# 底图重建后之前的迷雾差异缓存失效，下一次 apply_fog 必须全量重画
	_fog_prev_explored.clear()
	_fog_prev_visible.clear()
	_fog_prev_size = -1
	_base_image = Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	_dark_image = Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	for x in range(size):
		var x_start = int(floor(float(x) / size * TEX_SIZE))
		var x_end = int(floor(float(x + 1) / size * TEX_SIZE))
		for y in range(size):
			var y_start = int(floor(float(y) / size * TEX_SIZE))
			var y_end = int(floor(float(y + 1) / size * TEX_SIZE))
			# 一格一个颜色，整格平铺 —— 着色只由 (类型, 高度, 覆盖层) 决定，两端一致
			var c := _terrain_color_for(terrain_grid[x][y], height_grid[x][y], x, y, get_overlay(x, y))
			var d := c.darkened(0.7)
			d.a = 1.0
			for px in range(x_start, x_end):
				for py in range(y_start, y_end):
					if px >= TEX_SIZE or py >= TEX_SIZE:
						continue
					_base_image.set_pixel(px, py, c)
					_dark_image.set_pixel(px, py, d)

# ---------- 城堡选址 ----------
# 特殊地图团队锚点：沿镜像轴把每方 2/3 个基地均匀排开
# 返回 [blue1..blueK, red1..redK]；镜像轴由 castle_layout.type 决定
func _preset_team_anchors(k: int) -> Array:
	var layout: Dictionary = map_preset.get("castle_layout", {})
	# 环形河布局：内圈（蓝方）在河心岛上，外圈（红方）沿环外陆地均分，角度错开浅滩
	if String(layout.get("type", "mirror_x")) == "ring":
		return _ring_anchors(k, layout)
	if String(layout.get("type", "mirror_x")) == "corners":
		return _corner_anchors(k, layout)
	if String(layout.get("type", "mirror_x")) == "coast":
		return _coast_anchors(k, layout)
	if String(layout.get("type", "mirror_x")) == "siege":
		return _siege_anchors(k, layout)
	var anchors: Array = layout.get("anchors", [])
	if anchors.size() < 2 or k <= 1:
		return anchors.duplicate()
	var free_vals: Array = [0.33, 0.67] if k == 2 else [0.25, 0.5, 0.75]
	# 可选 spread：把同侧基地收拢到中轴附近（如山海关这种只有一处关隘的地图），
	# 避免 2V2/3V3 的基地被摊到地图两端后，部队要横穿半张图才能找到唯一通道
	var spread := clampf(float(layout.get("spread", 0.0)), 0.0, 0.2)
	if spread > 0.0:
		if k == 2:
			free_vals = [0.5 - spread, 0.5 + spread]
		else:
			free_vals = [0.5 - spread, 0.5, 0.5 + spread]
	var out: Array = []
	if String(layout.get("type", "mirror_x")) == "mirror_z":
		for f in free_vals:
			out.append([float(f), float(anchors[0][1])])
		for f in free_vals:
			out.append([float(f), float(anchors[1][1])])
	else:
		for f in free_vals:
			out.append([float(anchors[0][0]), float(f)])
		for f in free_vals:
			out.append([float(anchors[1][0]), float(f)])
	return out

# 环形河基地锚点：蓝方在岛内按角度均分（1 人时居中），红方在环外陆地按角度均分，
# 外圈角度取 30° + 360/k 的倍数，与 0/120/240 的三处浅滩错开，避免基地压在渡口上
func _ring_anchors(k: int, layout: Dictionary) -> Array:
	var inner_r := float(layout.get("inner_radius", 0.13))
	var outer_r := float(layout.get("outer_radius", 0.42))
	var out: Array = []
	if k <= 1:
		out.append([0.5, 0.5])
	else:
		for i in range(k):
			var a := deg_to_rad(90.0 + 360.0 * float(i) / float(k))
			out.append([clampf(0.5 + inner_r * cos(a), 0.06, 0.94), clampf(0.5 + inner_r * sin(a), 0.06, 0.94)])
	var n := maxi(1, k)
	for i in range(n):
		var a2 := deg_to_rad(30.0 + 360.0 * float(i) / float(n))
		out.append([clampf(0.5 + outer_r * cos(a2), 0.06, 0.94), clampf(0.5 + outer_r * sin(a2), 0.06, 0.94)])
	return out

# 四大岛基地锚点：1V1 对角两座岛，2V2 北岸两座对南岸两座，3V3 南北各三座（含中央两岛）
func _corner_anchors(k: int, layout: Dictionary) -> Array:
	var c := clampf(float(layout.get("corner", 0.18)), 0.12, 0.26)
	var out: Array = []
	if k <= 1:
		out.append([c, c])
		out.append([1.0 - c, 1.0 - c])
	elif k == 2:
		out.append([c, c])
		out.append([1.0 - c, c])
		out.append([c, 1.0 - c])
		out.append([1.0 - c, 1.0 - c])
	else:
		out.append([c, c])
		out.append([0.5, c])
		out.append([1.0 - c, c])
		out.append([c, 1.0 - c])
		out.append([0.5, 1.0 - c])
		out.append([1.0 - c, 1.0 - c])
	return out

# 海岸登陆基地锚点：蓝方（玩家/攻方）在外周陆地上，红方（守方）据守中央大岛；
# 2V2/3V3 时同阵营基地在各自区域里横向均分，避免跨海混编
func _coast_anchors(k: int, layout: Dictionary) -> Array:
	var outer_y := clampf(float(layout.get("outer_y", 0.12)), 0.07, 0.20)
	var island_off := clampf(float(layout.get("island_offset", 0.10)), 0.06, 0.14)
	var out: Array = []
	var outer_xs: Array
	if k <= 1:
		outer_xs = [0.5]
	elif k == 2:
		outer_xs = [0.33, 0.67]
	else:
		outer_xs = [0.25, 0.5, 0.75]
	for fx in outer_xs:
		out.append([float(fx), outer_y])
	if k <= 1:
		out.append([0.5, 0.5])
	elif k == 2:
		out.append([0.5 - island_off, 0.5])
		out.append([0.5 + island_off, 0.5])
	else:
		out.append([0.5 - island_off, 0.5])
		out.append([0.5, 0.5])
		out.append([0.5 + island_off, 0.5])
	return out

# 三岛登陆基地锚点：蓝方（攻方）取三座孤岛，1 人用中岛、2 人用左右岛、3 人各占一岛；
# 红方（守方）沿大陆中轴线均分，落在小河以北，背靠主城、面向南岸登陆场
func _siege_anchors(k: int, layout: Dictionary) -> Array:
	var centers: Array = _siege_island_centers
	if centers.size() < 3:
		centers = [[0.17, 0.78], [0.5, 0.78], [0.83, 0.78]]
	var picks: Array = []
	if k <= 1:
		picks = [centers[1]]
	elif k == 2:
		picks = [centers[0], centers[2]]
	else:
		picks = [centers[0], centers[1], centers[2]]
	var out: Array = []
	for c in picks:
		out.append([float(c[0]), float(c[1])])
	var dy := float(layout.get("defender_y", 0.26))
	var xs: Array
	if k <= 1:
		xs = [0.5]
	elif k == 2:
		xs = [0.33, 0.67]
	else:
		xs = [0.25, 0.5, 0.75]
	for fx in xs:
		out.append([float(fx), dy])
	return out

# 团队锚点压平后转世界坐标
func _preset_team_points(k: int) -> Array:
	var size := _get_map_size()
	var radius: int = clampi(int(map_preset.get("castle_layout", {}).get("flat_radius", 5)), 2, 8)
	var pts: Array = []
	for a in _preset_team_anchors(k):
		var gx := int(clampf(float(a[0]) * float(size), float(radius + 1), float(size - radius - 2)))
		var gy := int(clampf(float(a[1]) * float(size), float(radius + 1), float(size - radius - 2)))
		_flatten_area(gx, gy, radius)
		pts.append(grid_to_world(gx, gy))
	return pts

func get_four_castle_positions() -> Array:
	if not _cached_four_castle_positions.is_empty():
		return _cached_four_castle_positions
	if _use_preset_layout():
		_cached_four_castle_positions = _preset_team_points(2)
		return _cached_four_castle_positions
	var size = _get_map_size()
	var half = size / 2.0
	var margin = 10
	var ps = 5
	var blue1 = _find_flat_plain(margin, half + ps, half - ps, size - margin, ps)
	if blue1 == Vector3.ZERO: blue1 = grid_to_world(half - 20, half + 20)
	var blue2 = _find_flat_plain(half + ps, half + ps, size - margin, size - margin, ps)
	if blue2 == Vector3.ZERO: blue2 = grid_to_world(half + 20, half + 20)
	var red1 = _find_flat_plain(margin, margin, half - ps, half - ps, ps)
	if red1 == Vector3.ZERO: red1 = grid_to_world(half - 20, half - 20)
	var red2 = _find_flat_plain(half + ps, margin, size - margin, half - ps, ps)
	if red2 == Vector3.ZERO: red2 = grid_to_world(half + 20, half - 20)
	_cached_four_castle_positions = [blue1, blue2, red1, red2]
	return _cached_four_castle_positions

# 3v3 六城堡选址：每边 3 个，沿南北两侧三分分布，返回 [blue1, blue2, blue3, red1, red2, red3]
func get_six_castle_positions() -> Array:
	if not _cached_six_castle_positions.is_empty():
		return _cached_six_castle_positions
	if _use_preset_layout():
		_cached_six_castle_positions = _preset_team_points(3)
		return _cached_six_castle_positions
	var size = _get_map_size()
	var half = size / 2.0
	var third = size / 3.0
	var margin = 10
	var ps = 5
	var blue1 = _find_flat_plain(margin, half + ps, third - ps, size - margin, ps)
	if blue1 == Vector3.ZERO: blue1 = grid_to_world(third / 2.0, half + 20)
	var blue2 = _find_flat_plain(third + ps, half + ps, third * 2 - ps, size - margin, ps)
	if blue2 == Vector3.ZERO: blue2 = grid_to_world(third * 1.5, half + 20)
	var blue3 = _find_flat_plain(third * 2 + ps, half + ps, size - margin, size - margin, ps)
	if blue3 == Vector3.ZERO: blue3 = grid_to_world(third * 2.5, half + 20)
	var red1 = _find_flat_plain(margin, margin, third - ps, half - ps, ps)
	if red1 == Vector3.ZERO: red1 = grid_to_world(third / 2.0, half - 20)
	var red2 = _find_flat_plain(third + ps, margin, third * 2 - ps, half - ps, ps)
	if red2 == Vector3.ZERO: red2 = grid_to_world(third * 1.5, half - 20)
	var red3 = _find_flat_plain(third * 2 + ps, margin, size - margin, half - ps, ps)
	if red3 == Vector3.ZERO: red3 = grid_to_world(third * 2.5, half - 20)
	_cached_six_castle_positions = [blue1, blue2, blue3, red1, red2, red3]
	return _cached_six_castle_positions

# 乱斗模式（FFA）N 国环绕布局：N 个城堡绕地图中心均匀排布，玩家=layout[0]（地图正下方），
# 其余 AI 国沿圆周逆时针依次分布；每点在目标附近找平坦处，找不到则强制压平兜底。
func get_ffa_castle_positions(n: int) -> Array:
	var count = clampi(n, 3, 5)
	if _cached_ffa_castle_positions.has(count):
		return _cached_ffa_castle_positions[count]
	var size = _get_map_size()
	var center = size / 2.0
	var radius = size * 0.30
	var layout: Array = []
	for i in range(count):
		# i=0 从正下方（gy 增大方向）出发，逆时针均匀环绕一圈
		var theta = PI / 2.0 - TAU * float(i) / float(count)
		var cx = int(center + radius * cos(theta))
		var cy = int(center + radius * sin(theta))
		var spot = _find_flat_near_point(cx, cy, 8)
		if spot == Vector3.ZERO:
			spot = _force_flat_spot(clampi(cx, 5, size - 6), clampi(cy, 5, size - 6), 5)
		layout.append(spot)
	_cached_ffa_castle_positions[count] = layout
	return layout

# 以 (cx, cy) 为中心、search_radius 为半径随机采样：5×5 全平原且高度差 < 0.8
func _find_flat_near_point(cx: int, cy: int, search_radius: int) -> Vector3:
	var size = _get_map_size()
	for _try in range(200):
		var tx = cx + randi_range(-search_radius, search_radius)
		var ty = cy + randi_range(-search_radius, search_radius)
		if tx < 5 or ty < 5 or tx > size - 6 or ty > size - 6:
			continue
		var ok = true
		for dx in range(-2, 3):
			for dy in range(-2, 3):
				var nx = tx + dx
				var ny = ty + dy
				if terrain_grid[nx][ny] != 0:
					ok = false
					break
				var h0 = height_grid[nx][ny]
				for nd in [Vector2i(1, 0), Vector2i(0, 1)]:
					var ax = nx + nd.x
					var ay = ny + nd.y
					if ax >= 0 and ax < size and ay >= 0 and ay < size:
						if abs(height_grid[ax][ay] - h0) >= 0.8:
							ok = false
							break
			if not ok:
				break
		if ok:
			return grid_to_world(tx, ty)
	return Vector3.ZERO

func _force_flat_spot(gx: int, gy: int, safe_size: int) -> Vector3:
	var size = _get_map_size()
	for dx in range(-safe_size, safe_size + 1):
		for dy in range(-safe_size, safe_size + 1):
			var nx = clampi(gx + dx, 0, size - 1)
			var ny = clampi(gy + dy, 0, size - 1)
			terrain_grid[nx][ny] = 0
			# 只改类型不改高度会让被压平的格子仍沉在水面下，城堡会悬空/陷水
			if height_grid.size() > nx and height_grid[nx].size() > ny:
				height_grid[nx][ny] = 0.0
	return grid_to_world(gx, gy)

# 特殊地图适用范围：单机/联机的 1V1 与 2V2/3V3；乱斗是环绕布局，锚点体系不适用
func _special_map_supported() -> bool:
	return not GameSettings.is_ffa

# 当前对局每队人数：1=1V1，2=2V2，3=3V3（联机看 selected_mode，单机看 ai_mode）
func _team_size_for_layout() -> int:
	if NetworkManager.mode != NetworkManager.Mode.NONE:
		match NetworkManager.selected_mode:
			NetworkManager.GameMode.TWOVTWO:
				return 2
			NetworkManager.GameMode.THREEvTHREE:
				return 3
			_:
				return 1
	return clampi(GameSettings.ai_mode, 1, 3)

func _use_preset_layout() -> bool:
	return _special_map_supported() and not map_preset.get("castle_layout", {}).is_empty()

# 按归一化锚点放置城堡：先压平地形与高度，再转世界坐标
func _place_castles_from_anchors(layout: Dictionary) -> void:
	var size := _get_map_size()
	var type := String(layout.get("type", "mirror_x"))
	var anchors: Array = layout.get("anchors", [])
	# 三岛登陆/环形/四角/海岸登陆等布局没有固定 anchors，1V1 的两人锚点需要按布局规则现算
	if type == "siege" or type == "ring" or type == "corners" or type == "coast":
		anchors = _preset_team_anchors(1)
	if anchors.size() < 2:
		return
	var radius: int = clampi(int(layout.get("flat_radius", 5)), 2, 8)
	var pts: Array = []
	for a in anchors:
		var gx := int(clampf(float(a[0]) * float(size), float(radius + 1), float(size - radius - 2)))
		var gy := int(clampf(float(a[1]) * float(size), float(radius + 1), float(size - radius - 2)))
		_flatten_area(gx, gy, radius)
		pts.append(grid_to_world(gx, gy))
	player_castle_pos = pts[0]
	enemy_castle_pos = pts[1]

func _flatten_area(gx: int, gy: int, radius: int) -> void:
	var size := _get_map_size()
	for dx in range(-radius, radius + 1):
		for dy in range(-radius, radius + 1):
			var nx := clampi(gx + dx, 0, size - 1)
			var ny := clampi(gy + dy, 0, size - 1)
			terrain_grid[nx][ny] = 0
			height_grid[nx][ny] = 0.0
			if not overlay_grid.is_empty():
				overlay_grid[nx][ny] = 0

func _find_flat_plain(gx_min,gy_min,gx_max,gy_max,ps:int) -> Vector3:
	var size=_get_map_size()
	gx_min=clampi(gx_min,0,size-1);gx_max=clampi(gx_max,0,size-1)
	gy_min=clampi(gy_min,0,size-1);gy_max=clampi(gy_max,0,size-1)
	var hp=ps/2
	for _try in range(500):
		var cx=randi_range(gx_min+hp,gx_max-hp)
		var cy=randi_range(gy_min+hp,gy_max-hp)
		var ok=true
		for dx in range(-hp,hp+1):
			for dy in range(-hp,hp+1):
				var nx=cx+dx;var ny=cy+dy
				if nx<0 or nx>=size or ny<0 or ny>=size:ok=false;break
				if terrain_grid[nx][ny]!=0:ok=false;break
				var h0=height_grid[nx][ny]
				for nd in [Vector2i(1,0),Vector2i(0,1)]:
					var ax=nx+nd.x;var ay=ny+nd.y
					if ax>=0 and ax<size and ay>=0 and ay<size:
						if abs(height_grid[ax][ay]-h0)>=0.8:ok=false;break
			if not ok:break
		if ok:return grid_to_world(cx,cy)
	return Vector3.ZERO

func _place_castles():
	var size = _get_map_size()
	var half = size / 2.0
	var margin = 10
	var ps = 5
	# 特殊地图：1V1 用锚点对；2V2/3V3 按镜像轴展开成每方 2/3 个基地
	if _use_preset_layout():
		var team_size := _team_size_for_layout()
		if team_size >= 2:
			var layout := get_four_castle_positions() if team_size == 2 else get_six_castle_positions()
			multi_castle_positions = layout
			player_castle_pos = layout[0]
			enemy_castle_pos = layout[team_size]
			return
		_place_castles_from_anchors(map_preset.get("castle_layout", {}))
		return
	# 乱斗模式（FFA）：N 国环绕布局，玩家=layout[0]，其余 AI 国依次分布
	if NetworkManager.mode == NetworkManager.Mode.NONE and GameSettings.is_ffa:
		var ffa_layout = get_ffa_castle_positions(clampi(GameSettings.ffa_nation_count, 3, 5))
		multi_castle_positions = ffa_layout
		player_castle_pos = ffa_layout[0]
		enemy_castle_pos = ffa_layout[1]  # 阶段2 临时敌人指针（阶段3 起按国 spawn，不再依赖该字段）
		return
	# 单机对称团队战（2V2/3V3）：2V2 用四城堡布局，3V3 用六城堡布局；玩家=layout[0]，首个红方=layout[mode]
	if NetworkManager.mode == NetworkManager.Mode.NONE and GameSettings.ai_mode >= 2:
		var mode = clampi(GameSettings.ai_mode, 2, 3)
		var layout = get_four_castle_positions() if mode == 2 else get_six_castle_positions()
		multi_castle_positions = layout
		player_castle_pos = layout[0]
		enemy_castle_pos = layout[mode]
		return
	player_castle_pos = _find_flat_plain(half/2+margin, half+ps, half-ps, size-margin, ps)
	if player_castle_pos == Vector3.ZERO:
		player_castle_pos = grid_to_world(half-15, half+15)
	enemy_castle_pos = _find_flat_plain(half+ps, margin, size-margin, half-ps, ps)
	if enemy_castle_pos == Vector3.ZERO:
		enemy_castle_pos = grid_to_world(half+15, half-15)
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
func _res_count(base: float, prof: Dictionary, key: String) -> int:
	return maxi(0, int(round(base * float(prof.get(key, 1.0)))))

func _place_resources():
	resource_positions.clear()
	var size = _get_map_size()
	var placed = {}

	var is_3v3 = NetworkManager.selected_mode == NetworkManager.GameMode.THREEvTHREE
	var is_single_team = NetworkManager.mode == NetworkManager.Mode.NONE and GameSettings.ai_mode >= 2
	if is_single_team:
		is_3v3 = GameSettings.ai_mode >= 3
	var is_ffa_single = NetworkManager.mode == NetworkManager.Mode.NONE and GameSettings.is_ffa
	var is_team_mode = NetworkManager.selected_mode != NetworkManager.GameMode.ONEvONE or is_single_team
	var ffa_n = clampi(GameSettings.ffa_nation_count, 3, 5) if is_ffa_single else 3
	var mult = 2.0 if is_3v3 else (2.0 if (is_ffa_single and ffa_n >= 4) else (1.5 if (is_team_mode or is_ffa_single) else 1.0))

	# 资源画像：按预设倍率调整每类资源的组数
	var prof: Dictionary = map_preset.get("resources", {})
	# 森林/山脊图基地附近没有山，"靠山才有林"的条件会落空，先放开
	var wood_near_any := String(prof.get("wood_near", "mountain")) == "any"
	# 森林图山地稀少，"靠山才有石"会大面积落空，同样放开
	var stone_near_any := String(prof.get("stone_near", "mountain")) == "any"
	# 黑森林：木材只在林缘（多）与林内（少）生成，不再随机撒
	var wood_forest := String(prof.get("wood_near", "mountain")) == "forest"
	# 山脊图：所有金矿集中在隘口
	var gold_at_passes := bool(prof.get("gold_at_passes", false))
	# 沙漠图 food=0：除每座城堡 1 组保底农田外不再撒农田，高难度 AI 加成也不补，食物主要靠狩猎
	var no_extra_food := float(prof.get("food", 1.0)) <= 0.0
	# 动物密度：沙漠这类以狩猎为主的图调高兽群数量
	var animal_mult := maxf(0.0, float(prof.get("animals", 1.0)))

	# Castle positions in grid coordinates
	var player_gx = int(player_castle_pos.x + size/2.0)
	var player_gy = int(player_castle_pos.z + size/2.0)
	var enemy_gx = int(enemy_castle_pos.x + size/2.0)
	var enemy_gy = int(enemy_castle_pos.z + size/2.0)
	var castles = [[player_gx, player_gy, "player"], [enemy_gx, enemy_gy, "enemy"]]
	if is_ffa_single:
		castles = []
		for fp in multi_castle_positions:
			castles.append([int(fp.x + size/2.0), int(fp.z + size/2.0)])
	elif is_team_mode:
		var team_pos = get_six_castle_positions() if is_3v3 else get_four_castle_positions()
		castles = []
		for fp in team_pos:
			var fgx = int(fp.x + size/2.0)
			var fgy = int(fp.z + size/2.0)
			castles.append([fgx, fgy])

	# ── Guaranteed resources near each castle ──
	# [type, group_size_min, group_size_max, max_dist, terrain, label]
	var guaranteed = [
		{"type":3, "min_sz":3, "max_sz":4, "dist":8,  "terrain":0},  # farmland
		{"type":1, "min_sz":5, "max_sz":6, "dist":12, "terrain":0, "near_mountain":true},  # forest
		{"type":2, "min_sz":2, "max_sz":3, "dist":30, "terrain":0, "adjacent_mountains":2},  # stone (山边平地)
		{"type":0, "min_sz":2, "max_sz":3, "dist":10, "terrain":0},  # gold
	]
	if wood_near_any:
		for gu in guaranteed:
			if int(gu["type"]) == 1:
				gu["near_mountain"] = false
	if stone_near_any:
		for gu in guaranteed:
			if int(gu["type"]) == 2:
				gu["adjacent_mountains"] = 0
	# 特殊规则：金矿只在隘口 / 木材只在林区，先摘掉常规条目
	if gold_at_passes:
		guaranteed = guaranteed.filter(func(e): return int(e["type"]) != 0)
	if wood_forest:
		guaranteed = guaranteed.filter(func(e): return int(e["type"]) != 1)
	for castle in castles:
		for gu in guaranteed:
			_place_group_near(gu.type, gu.min_sz, gu.max_sz, castle[0], castle[1], gu.dist, gu.terrain, placed, size, gu.get("near_mountain", false), gu.get("adjacent_mountains", 0))
	# 三岛登陆：三座孤岛都要能独立开局/中转，空岛也保底补木石金田
	if bool(map_preset.get("island_staging", false)):
		var staging = [
			{"type":3, "min_sz":2, "max_sz":3, "dist":9},
			{"type":1, "min_sz":4, "max_sz":5, "dist":11},
			{"type":2, "min_sz":2, "max_sz":3, "dist":18},
			{"type":0, "min_sz":2, "max_sz":3, "dist":9},
		]
		for ic in _siege_island_centers:
			var igx := clampi(int(float(ic[0]) * float(size)), 0, size - 1)
			var igy := clampi(int(float(ic[1]) * float(size)), 0, size - 1)
			for gu in staging:
				_place_group_near(gu.type, gu.min_sz, gu.max_sz, igx, igy, gu.dist, 0, placed, size)
	# Extra resources for Hard/Hell AI near enemy/red castles
	var hard_extra = [
		{"type":3, "min_sz":3, "max_sz":4, "dist":10, "terrain":0},  # farmland
		{"type":1, "min_sz":5, "max_sz":6, "dist":14, "terrain":0, "near_mountain":true},  # forest
		{"type":2, "min_sz":2, "max_sz":3, "dist":30, "terrain":0, "adjacent_mountains":2},  # stone (山边平地)
		{"type":0, "min_sz":2, "max_sz":3, "dist":12, "terrain":0},  # gold
	]
	if wood_near_any:
		for gu in hard_extra:
			if int(gu["type"]) == 1:
				gu["near_mountain"] = false
	if stone_near_any:
		for gu in hard_extra:
			if int(gu["type"]) == 2:
				gu["adjacent_mountains"] = 0
	if gold_at_passes:
		hard_extra = hard_extra.filter(func(e): return int(e["type"]) != 0)
	if wood_forest:
		hard_extra = hard_extra.filter(func(e): return int(e["type"]) != 1)
	# 沙漠图：高难度 AI 也不额外补农田，食物靠兽群
	if no_extra_food:
		hard_extra = hard_extra.filter(func(e): return int(e["type"]) != 3)
	if GameSettings.ai_difficulty >= GameSettings.AIDifficulty.HARD or GameSettings.red_ai_difficulty >= GameSettings.AIDifficulty.HARD or GameSettings.blue_ai_difficulty >= GameSettings.AIDifficulty.HARD:
		# Only for enemy/AI castles（1v1 敌方 = 后半；2v2/3v3 红队城堡 = 后半；乱斗 = 玩家之外全部 AI）
		var ai_castles = castles.slice(1) if is_ffa_single else castles.slice(castles.size() / 2)
		for cs in ai_castles:
			for gu in hard_extra:
				_place_group_near(gu.type, gu.min_sz, gu.max_sz, cs[0], cs[1], gu.dist, gu.terrain, placed, size, gu.get("near_mountain", false))

	# ── Remaining groups: placed anywhere ──
	var remaining = [
		{"type":0, "count": _res_count(4.0 * mult, prof, "gold"), "min_sz":1, "max_sz":2, "terrain":0},
		{"type":1, "count": _res_count(8.0 * mult, prof, "wood"), "min_sz":5, "max_sz":6, "terrain":0, "near_mountain":true},
		{"type":2, "count": _res_count(6.0 * mult, prof, "stone"), "min_sz":2, "max_sz":3, "terrain":0, "adjacent_mountains":2},
		{"type":3, "count": _res_count(6.0 * mult, prof, "food"), "min_sz":3, "max_sz":4, "terrain":0, "away_mountain":true},
		{"type":4, "count": _res_count(6.0 * mult, prof, "oil"), "min_sz":1, "max_sz":2, "terrain":2},
	]
	if wood_near_any:
		for g in remaining:
			if int(g["type"]) == 1:
				g["near_mountain"] = false
	if stone_near_any:
		for g in remaining:
			if int(g["type"]) == 2:
				g["adjacent_mountains"] = 0
	if gold_at_passes:
		remaining = remaining.filter(func(g): return int(g["type"]) != 0)
	if wood_forest:
		remaining = remaining.filter(func(g): return int(g["type"]) != 1)
	for g in remaining:
		for _gi in range(g.count):
			_place_group_random(g.type, g.min_sz, g.max_sz, g.terrain, placed, size, castles, g.get("near_mountain", false), g.get("away_mountain", false), g.get("adjacent_mountains", 0))

	# 黑森林：林缘木材多、林内木材少
	if wood_forest:
		_place_forest_wood(size, castles, placed, mult)

	# 特殊地图：隘口上的争议金矿，逼双方争夺通道
	# 山脊图全图金矿只在隘口：1V1 每处 2 组，2V2/3V3 按人数加组
	var players := 2
	if is_team_mode:
		players = 4 if not is_3v3 else 6
	for pc in _pass_centers:
		var per_pass := 1
		if gold_at_passes:
			per_pass = 2 + maxi(0, int((players - 2) / 2))
		var gold_dist := 6 if gold_at_passes else 10
		for _i in range(per_pass):
			_place_group_near(0, 2, 3, pc.x, pc.y, gold_dist, 0, placed, size)

	# 海峡图：岛上的资源工人够不着（没桥/浅滩），生成完直接剔除不可达资源与动物
	if bool(map_preset.get("reachable_only", false)):
		var drop_origins: Array = castles.duplicate()
		# 三岛登陆：空岛是攻方渡海后的中转站，岛上资源要保留（登陆占地后才采得到），
		# 这里只把它们当作可达性起点，不改变 AI 的就近采集决策
		if bool(map_preset.get("island_staging", false)):
			for ic in _siege_island_centers:
				drop_origins.append([int(float(ic[0]) * float(size)), int(float(ic[1]) * float(size))])
		_drop_unreachable_resources(size, drop_origins)

	# ── Animals ──
	# 沙漠等以狩猎为主的图：food=0 后动物是主要食物来源，兽群数量按 animals 倍率放大
	var herd_count := int(round(8.0 * mult * animal_mult))
	for _i in range(herd_count):
		var cx = randi_range(8, size - 9); var cy = randi_range(8, size - 9)
		# 孤岛上的兽群猎不到，直接换位置（海峡图）
		if not _reach_tiles.is_empty() and not _reach_tiles.has(Vector2i(cx, cy)):
			continue
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
					if not _reach_tiles.is_empty() and not _reach_tiles.has(Vector2i(ax, ay)):
						continue
					var at = terrain_grid[ax][ay]
					if (atype == 63 and at == 2) or (atype != 63 and at == 0):
						if not placed.has("a%d,%d" % [ax, ay]):
							resource_positions.append({"pos": grid_to_world(ax, ay), "type": atype})
							placed["a%d,%d" % [ax, ay]] = true

	# 常规地图：木材所在地改为森林覆盖层（树林在地图上可见，进入后按森林算视野/移速）
	if String(map_preset.get("id", "classic")) == "classic":
		_mark_wood_as_forest(size)
		_colorize_grid(size)

# 油井只能落在水域内部：8 邻格不能有任何陆地，且不能是浅滩。
# 这样石油不会出现在岸边，而会优先落在开阔水面中央。
func _is_oil_center_cell(tx: int, ty: int, size: int) -> bool:
	if tx < 0 or ty < 0 or tx >= size or ty >= size:
		return false
	if terrain_grid[tx][ty] != 2:
		return false
	if get_overlay(tx, ty) == 3:
		return false
	return _count_adjacent_terrain(tx, ty, 0, size) == 0

# 以候选格为中心统计半径2内的水面格数；周围水越多，权重越高。
# 油井抽选时使用平方权重，让地图中央的开阔水域明显更容易出油。
func _oil_water_weight(tx: int, ty: int, size: int) -> int:
	var count := 0
	for dx in range(-2, 3):
		for dy in range(-2, 3):
			var nx: int = tx + dx
			var ny: int = ty + dy
			if nx < 0 or ny < 0 or nx >= size or ny >= size:
				continue
			if terrain_grid[nx][ny] == 2 and get_overlay(nx, ny) != 3:
				count += 1
	return maxi(1, count)

# 从每座城堡出发做一次洪水填充（地形 0/1 可走，水面仅浅滩可走），
# 把落在孤岛上的资源点/兽群剔除，避免工人永远走不到、AI 反复尝试
func _drop_unreachable_resources(size: int, castles: Array) -> void:
	var reach := {}
	var q: Array = []
	for cs in castles:
		var c := Vector2i(clampi(int(cs[0]), 0, size - 1), clampi(int(cs[1]), 0, size - 1))
		if not reach.has(c):
			reach[c] = true
			q.append(c)
	while not q.is_empty():
		var cur: Vector2i = q.pop_back()
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = cur + d
			if n.x < 0 or n.y < 0 or n.x >= size or n.y >= size:
				continue
			if reach.has(n):
				continue
			var t: int = terrain_grid[n.x][n.y]
			if t == 2 and get_overlay(n.x, n.y) != 3:
				continue
			# 与 A* 相同的陡坡规则：高差超过阈值即不可通行，避免资源被留在
			# 陡峭山脊围出的孤岛口袋里（类型 BFS 会把山地当可走，检查不出来）
			if absf(height_grid[n.x][n.y] - height_grid[cur.x][cur.y]) > CLIFF_THRESHOLD:
				continue
			reach[n] = true
			q.append(n)
	_reach_tiles = reach
	# 石油改到水域中央后不再贴岸，不能再按“相邻陆地可达”判断。
	# 从与可达陆地相邻的水格出发做水面包围扩展，能连通到这些岸边的水域才算可采。
	var water_reach: Dictionary = {}
	var has_water_resource := false
	for r in resource_positions:
		var r_gx := int(r["pos"].x + size / 2.0)
		var r_gy := int(r["pos"].z + size / 2.0)
		if r_gx >= 0 and r_gx < size and r_gy >= 0 and r_gy < size and int(terrain_grid[r_gx][r_gy]) == 2:
			has_water_resource = true
			break
	if has_water_resource:
		var wq: Array = []
		for x in range(size):
			for y in range(size):
				if int(terrain_grid[x][y]) != 2:
					continue
				var c := Vector2i(x, y)
				if water_reach.has(c):
					continue
				var touches_land := false
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					if reach.has(c + d):
						touches_land = true
						break
				if touches_land:
					water_reach[c] = true
					wq.append(c)
		while not wq.is_empty():
			var cur: Vector2i = wq.pop_back()
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = cur + d
				if n.x < 0 or n.y < 0 or n.x >= size or n.y >= size:
					continue
				if water_reach.has(n):
					continue
				if int(terrain_grid[n.x][n.y]) != 2:
					continue
				water_reach[n] = true
				wq.append(n)
	var kept: Array = []
	for r in resource_positions:
		var gx := int(r["pos"].x + size / 2.0)
		var gy := int(r["pos"].z + size / 2.0)
		var ok: bool = reach.has(Vector2i(gx, gy))
		# 水面资源（油井）由采集船从船坞出海采集，只要所在水域与可达岸边连通即可
		if not ok and int(terrain_grid[gx][gy]) == 2:
			ok = water_reach.has(Vector2i(gx, gy))
		if ok:
			kept.append(r)
	resource_positions = kept

# 黑森林木材：沿森林边缘一株一株密集排开（只认成片森林的边界，不围着零星小树洞种）
func _place_forest_wood(size: int, castles: Array, placed: Dictionary, mult: float) -> void:
	# 候选 = 紧贴森林（8 邻域有森林）且周围成片的平原格
	var cands: Array = []
	for x in range(3, size - 4):
		for y in range(3, size - 4):
			if terrain_grid[x][y] != 0:
				continue
			if get_overlay(x, y) != 0:
				continue
			if not _forest_edge(x, y, size):
				continue
			# 3 格内至少 10 格森林：小树洞/单棵孤树旁边不放木材，视线会散
			if _forest_count_near(x, y, 3) < 10:
				continue
			if placed.has("r1,%d,%d" % [x, y]):
				continue
			cands.append(Vector2i(x, y))
	cands.shuffle()
	# 密度：林线要连成一片树墙，1V1 约 400 株，团队按规模放大（上限 900 防止实体爆炸）
	var target := mini(900, int(round(400.0 * mult)))
	var nodes: Array = []
	# 每座基地附近先各取 30 株，保证开局能采到木
	for cs in castles:
		var center := Vector2i(int(cs[0]), int(cs[1]))
		var want := 30
		for c in cands:
			if want <= 0:
				break
			if Vector2(c.x - center.x, c.y - center.y).length() > 30.0:
				continue
			if _too_close_to_wood(c, nodes, 1.0):
				continue
			nodes.append(c)
			want -= 1
	for c in cands:
		if nodes.size() >= target:
			break
		if _too_close_to_wood(c, nodes, 1.0):
			continue
		nodes.append(c)
	for c in nodes:
		placed["r1,%d,%d" % [c.x, c.y]] = true
		resource_positions.append({"pos": grid_to_world(c.x, c.y), "type": 1})

# 统计 (x,y) 周围 radius 内的森林覆盖层格数
func _forest_count_near(x: int, y: int, radius: int) -> int:
	var size := _get_map_size()
	var count := 0
	for dx in range(-radius, radius + 1):
		for dy in range(-radius, radius + 1):
			var nx := x + dx
			var ny := y + dy
			if nx < 0 or ny < 0 or nx >= size or ny >= size:
				continue
			if overlay_grid[nx][ny] == 1:
				count += 1
	return count

# 木材之间保持最小间距（1.0 = 允许紧贴成行，只要不落在同一格）
func _too_close_to_wood(tile: Vector2i, nodes: Array, min_dist: float) -> bool:
	for n in nodes:
		if Vector2(tile.x - n.x, tile.y - n.y).length() < min_dist:
			return true
	return false

func _forest_edge(x: int, y: int, size: int) -> bool:
	if get_overlay(x, y) != 0:
		return false
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var nx: int = x + dx
			var ny: int = y + dy
			if nx < 0 or ny < 0 or nx >= size or ny >= size:
				continue
			if overlay_grid[nx][ny] == 1:
				return true
	return false

# 常规地图：木材节点所在格及周围一格改为森林覆盖层
func _mark_wood_as_forest(size: int) -> void:
	if overlay_grid.is_empty():
		return
	for r in resource_positions:
		if int(r["type"]) != 1:
			continue
		var gx := int(r["pos"].x + size / 2.0)
		var gy := int(r["pos"].z + size / 2.0)
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var nx := gx + dx
				var ny := gy + dy
				if nx < 0 or ny < 0 or nx >= size or ny >= size:
					continue
				if terrain_grid[nx][ny] != 0:
					continue
				overlay_grid[nx][ny] = 1

# ── Helper: place a group near a position ──
func _place_group_near(rtype, min_sz, max_sz, cx, cy, max_dist, terrain, placed, size, near_mountain=false, adjacent_mountains=0):
	var best_x = -1; var best_y = -1
	for _attempt in range(200):
		var tx = cx + randi_range(-max_dist, max_dist)
		var ty = cy + randi_range(-max_dist, max_dist)
		if tx < 0 or tx >= size or ty < 0 or ty >= size: continue
		if terrain_grid[tx][ty] != terrain: continue
		if placed.has("g%d,%d,%d" % [rtype, tx, ty]): continue
		if near_mountain and not _has_nearby_terrain(tx, ty, 1, 3, size): continue
		if adjacent_mountains > 0 and _count_adjacent_terrain(tx, ty, 1, size) < adjacent_mountains: continue
		best_x = tx; best_y = ty; break
	if best_x < 0:
		return
	placed["g%d,%d,%d" % [rtype, best_x, best_y]] = true
	_spawn_group(rtype, min_sz, max_sz, best_x, best_y, terrain, placed, size, adjacent_mountains)

# ── Helper: place a group randomly on the map ──
func _place_group_random(rtype, min_sz, max_sz, terrain, placed, size, castles, near_mountain=false, away_mountain=false, adjacent_mountains=0):
	var cx = -1; var cy = -1
	# 油井统一生成在水域内部，按周围水面开阔程度加权抽选：
	# 离岸越远、周围水越多，被选中的概率越高；贴岸格和浅滩直接排除。
	if rtype == 4 and terrain == 2:
		var cands: Array = []
		for tx in range(5, size - 5):
			for ty in range(5, size - 5):
				if not _is_oil_center_cell(tx, ty, size): continue
				if placed.has("g%d,%d,%d" % [rtype, tx, ty]): continue
				var skip_c := false
				for cs in castles:
					if sqrt((tx-cs[0])**2 + (ty-cs[1])**2) < 8: skip_c = true; break
				if skip_c: continue
				var near_dup := false
				for k in placed.keys():
					if k.begins_with("g%d," % rtype):
						var ox = int(k.split(",")[1]); var oy = int(k.split(",")[2])
						if sqrt((tx-ox)**2 + (ty-oy)**2) < 15: near_dup = true; break
				if near_dup: continue
				var w: int = _oil_water_weight(tx, ty, size)
				cands.append({"cell": Vector2i(tx, ty), "weight": float(w * w)})
		if cands.is_empty():
			return
		var total_w := 0.0
		for c in cands:
			total_w += float(c["weight"])
		if total_w <= 0.0:
			return
		var pick := randf() * total_w
		var chosen: Vector2i = cands[cands.size() - 1]["cell"]
		for c in cands:
			pick -= float(c["weight"])
			if pick <= 0.0:
				chosen = c["cell"]
				break
		cx = chosen.x; cy = chosen.y
		placed["g%d,%d,%d" % [rtype, cx, cy]] = true
		_spawn_group(rtype, min_sz, max_sz, cx, cy, terrain, placed, size, adjacent_mountains)
		return
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
		if adjacent_mountains > 0 and _count_adjacent_terrain(tx, ty, 1, size) < adjacent_mountains: continue
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
	_spawn_group(rtype, min_sz, max_sz, cx, cy, terrain, placed, size, adjacent_mountains)

# ── Spawn individual resources in a group ──
func _spawn_group(rtype, min_sz, max_sz, cx, cy, terrain, placed, size, adjacent_mountains=0):
	var count = min_sz + randi_range(0, max_sz - min_sz)
	resource_positions.append({"pos": grid_to_world(cx, cy), "type": rtype})
	var placed_count = 1
	for _mt in range(count * 5):
		if placed_count >= count: break
		var mx = cx + randi_range(-4, 4); var my = cy + randi_range(-4, 4)
		if mx < 0 or mx >= size or my < 0 or my >= size: continue
		if terrain_grid[mx][my] != terrain: continue
		# 油井群内的其余油点也必须在水域内部，不能补到岸边
		if rtype == 4 and terrain == 2 and not _is_oil_center_cell(mx, my, size): continue
		if adjacent_mountains > 0 and _count_adjacent_terrain(mx, my, 1, size) < adjacent_mountains: continue
		if placed.has("r%d,%d" % [mx, my]): continue
		placed["r%d,%d" % [mx, my]] = true
		resource_positions.append({"pos": grid_to_world(mx, my), "type": rtype})
		placed_count += 1

# ── Check if terrain type exists within range ──
# Count adjacent tiles (8 directions) of a specific terrain type
func _count_adjacent_terrain(x, y, terr_type, size) -> int:
	var count = 0
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			if dx == 0 and dy == 0: continue
			var nx = x + dx; var ny = y + dy
			if nx >= 0 and nx < size and ny >= 0 and ny < size:
				if terrain_grid[nx][ny] == terr_type: count += 1
	return count

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
	var subdivisions = _get_map_size()
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

	

	# 底图逐像素画一次（草地点彩就在这里生成），之后迷雾阶段只做整块拷贝
	_build_terrain_images()
	terrain_image = Image.create_from_data(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8, _base_image.get_data())
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
func apply_fog(explored: Array, visible: Array) -> bool:
	var size = _get_map_size()
	if base_colors.is_empty() or terrain_grid.is_empty(): return false
	if explored.size() != size or visible.size() != size: return false
	if explored[0].size() != size or visible[0].size() != size: return false
	if _base_image == null or _dark_image == null or terrain_image == null or terrain_texture == null: return false

	# 只重画探索/可见状态真正变化的格子。后期单位很多、视野每 0.5s
	# 才变化一次，绝大多数格子状态不变；旧实现每次都把 100×100 格全部
	# fill_rect/blit_rect 一遍，是后期主线程的固定开销。
	var full := _fog_prev_size != size or _fog_prev_explored.is_empty() or _fog_prev_visible.is_empty()
	if full:
		_fog_prev_explored.clear()
		_fog_prev_visible.clear()
		for x in range(size):
			_fog_prev_explored.append(explored[x].duplicate())
			_fog_prev_visible.append(visible[x].duplicate())
		_fog_prev_size = size

	var changed := false
	for x in range(size):
		var x_start = int(floor(float(x) / size * TEX_SIZE))
		var x_end = int(floor(float(x + 1) / size * TEX_SIZE))
		var prev_explored_row: Array = _fog_prev_explored[x]
		var prev_visible_row: Array = _fog_prev_visible[x]
		for y in range(size):
			var ex = explored[x][y]
			var vis = visible[x][y]
			if not full and prev_explored_row[y] == ex and prev_visible_row[y] == vis:
				continue
			var y_start = int(floor(float(y) / size * TEX_SIZE))
			var y_end = int(floor(float(y + 1) / size * TEX_SIZE))
			var rect := Rect2i(x_start, y_start, x_end - x_start, y_end - y_start)
			if not ex:
				terrain_image.fill_rect(rect, Color(0.1, 0.1, 0.1, 1.0))
			elif not vis:
				# 整块拷贝预生成的压暗底图：比逐像素重算颜色快得多，同时保住草丛图案
				terrain_image.blit_rect(_dark_image, rect, Vector2i(x_start, y_start))
			else:
				terrain_image.blit_rect(_base_image, rect, Vector2i(x_start, y_start))
			prev_explored_row[y] = ex
			prev_visible_row[y] = vis
			changed = true

	if not changed:
		return false
	terrain_texture.update(terrain_image)
	return true

# ---------- 工具函数 ----------

func _add_water_box():
		var size = _get_map_size()
		var w = MeshInstance3D.new()
		w.name = "WaterBox"
		var plane = PlaneMesh.new()
		plane.size = Vector2(size, size)
		# 细分后才能看到顶点波浪与船只附近的涟漪（默认 4 个顶点几乎没有任何位移）
		plane.subdivide_width = 128
		plane.subdivide_depth = 128
		w.mesh = plane
		w.position = Vector3(0, WATER_WORLD_Y, 0)
		# 水面单独占一层，镜像相机剔除这一层，避免镜子反射自身
		w.layers = 1 << WATER_LAYER
		var shader = load("res://resources/water_noise.gdshader")
		if shader:
			var mat = ShaderMaterial.new()
			mat.shader = shader
			mat.set_shader_parameter("fog_tex", terrain_texture)
			# 船只位置数组必须先把长度对齐到着色器里的固定数组大小
			var empty_boats := PackedVector3Array()
			empty_boats.resize(BOAT_SHADER_SLOTS)
			mat.set_shader_parameter("boats", empty_boats)
			mat.set_shader_parameter("boat_dirs", empty_boats)
			mat.set_shader_parameter("boat_count", 0)
			_water_mat = mat
			w.material_override = mat
		else:
			var mat = StandardMaterial3D.new()
			mat.albedo_color = Color(0.0, 0.75, 1.0, 0.5)
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.metallic = 0.3; mat.roughness = 0.2
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			w.material_override = mat
		print("[Water-Server] box added, shader_loaded=%s, fog_tex=%s" % [str(shader != null), str(terrain_texture)])
		add_child(w)
		_setup_planar_reflection()

# ---------- 平面反射 ----------
# 在水面下方镜像位置放一台相机渲染场景，得到"从水里看到的水上世界"；
# 它的投影参数与主相机一致，所以反射射线落点坐标可直接作为取样坐标。

func _setup_planar_reflection() -> void:
	if _water_mat == null:
		return
	if _refl_viewport != null and is_instance_valid(_refl_viewport):
		return
	_refl_viewport = SubViewport.new()
	_refl_viewport.name = "WaterReflection"
	_refl_viewport.size = Vector2i(480, 270)
	_refl_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_refl_viewport.transparent_bg = false
	_refl_viewport.msaa_3d = Viewport.MSAA_DISABLED
	add_child(_refl_viewport)
	_refl_cam = Camera3D.new()
	_refl_cam.name = "ReflectionCamera"
	_refl_cam.cull_mask = 0xFFFFF & ~(1 << WATER_LAYER)
	_refl_cam.current = true
	_refl_viewport.add_child(_refl_cam)
	_water_mat.set_shader_parameter("reflection_tex", _refl_viewport.get_texture())
	_water_mat.set_shader_parameter("reflection_enabled", 1.0 if _refl_enabled else 0.0)

func _update_planar_reflection() -> void:
	if _refl_cam == null or _refl_viewport == null or not _refl_enabled:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	# 反射纹理取主画面一半分辨率，控制每帧多渲染一遍场景的开销
	var vs: Vector2i = get_viewport().size
	var target := Vector2i(maxi(160, vs.x / 2), maxi(90, vs.y / 2))
	if _refl_viewport.size != target:
		_refl_viewport.size = target
	if _refl_cam.fov != cam.fov:
		_refl_cam.fov = cam.fov
	_refl_cam.near = maxf(cam.near, 0.05)
	_refl_cam.far = cam.far
	_refl_cam.projection = cam.projection
	# 宽高比与画面偏移必须一并复制，否则倒影会与主画面错位
	_refl_cam.keep_aspect = cam.keep_aspect
	_refl_cam.h_offset = cam.h_offset
	_refl_cam.v_offset = cam.v_offset
	_refl_cam.size = cam.size
	# 以水面为镜面镜像相机变换：位置 y -> 2h - y，朝向上下翻转
	var xf: Transform3D = cam.global_transform
	var flip := Basis(Vector3(1, 0, 0), Vector3(0, -1, 0), Vector3(0, 0, 1))
	_refl_cam.global_transform = Transform3D(flip * xf.basis, flip * xf.origin + Vector3(0, 2.0 * WATER_WORLD_Y, 0))

func set_planar_reflection(enabled: bool) -> void:
	_refl_enabled = enabled
	if _refl_viewport != null and is_instance_valid(_refl_viewport):
		_refl_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if enabled else SubViewport.UPDATE_DISABLED
	if _water_mat != null:
		_water_mat.set_shader_parameter("reflection_enabled", 1.0 if enabled else 0.0)

func _process(delta: float) -> void:
	_update_planar_reflection()
	_update_water_boats(delta)

# 把水面单位位置喂给水面着色器：船体周围生成涟漪与泡沫尾迹
func _update_water_boats(delta: float) -> void:
	if _water_mat == null:
		return
	_boat_update_timer -= delta
	if _boat_update_timer > 0.0:
		return
	_boat_update_timer = 0.15
	var arr := PackedVector3Array()
	arr.resize(BOAT_SHADER_SLOTS)
	var dirs := PackedVector3Array()
	dirs.resize(BOAT_SHADER_SLOTS)
	var count: int = 0
	var bm = get_tree().get_first_node_in_group("battle_manager")
	var armies: Array = []
	if bm != null and bm.get("_armies") != null:
		bm._ensure_cache_fresh()
		armies = bm.get("_armies")
	else:
		# 联机客户端没有服务端实体缓存，退化为直接遍历实体组
		armies = get_tree().get_nodes_in_group("entities")
	var seen: Dictionary = {}
	for e in armies:
		if count >= BOAT_SHADER_SLOTS:
			break
		if not is_instance_valid(e) or e.health <= 0:
			continue
		if not bool(e.get("water_capable")):
			continue
		var id: int = e.get_instance_id()
		var pos: Vector3 = e.global_position
		# 与上一次采样位置相减得到航向，供着色器沿航行反方向拉出尾流带
		var dir := Vector3.ZERO
		var prev = _boat_prev.get(id)
		if prev is Vector3:
			var d: Vector3 = pos - prev
			d.y = 0.0
			if d.length() > 0.03:
				dir = d.normalized()
		_boat_prev[id] = pos
		seen[id] = true
		arr[count] = pos
		dirs[count] = dir
		count += 1
	# 定期清掉已经消失的船的缓存，避免字典无限增长
	_boat_prev_cleanup -= delta
	if _boat_prev_cleanup <= 0.0:
		_boat_prev_cleanup = 10.0
		for k in _boat_prev.keys():
			if not seen.has(k):
				_boat_prev.erase(k)
	_water_mat.set_shader_parameter("boats", arr)
	_water_mat.set_shader_parameter("boat_dirs", dirs)
	_water_mat.set_shader_parameter("boat_count", count)

# 画质档位联动：低画质关掉屏幕空间反射，减少全屏水面的采样开销
func set_water_quality(level: int) -> void:
	if _water_mat == null:
		return
	var refl: float = 0.85 if level <= 0 else (0.55 if level == 1 else 0.0)
	var wake: float = 1.0 if level <= 2 else 0.7
	_water_mat.set_shader_parameter("reflect_strength", refl)
	_water_mat.set_shader_parameter("wake_strength", wake)
	# 最低两档关掉平面反射（每帧多渲染一遍场景），水面退回屏幕空间近似
	set_planar_reflection(level < 2)

func get_height_at(world_pos: Vector3) -> float:
	var size = _get_map_size()
	var subdivisions = _get_map_size()
	var fx = (world_pos.x / size + 0.5) * subdivisions
	var fz = (world_pos.z / size + 0.5) * subdivisions
	var x = clampi(int(fx), 0, subdivisions)
	var z = clampi(int(fz), 0, subdivisions)
	return vertex_grid[x][z] if vertex_grid.size() > x and vertex_grid[x].size() > z else 0.0

func get_terrain(gx: int, gy: int) -> int:
	if gx >= 0 and gx < terrain_grid.size() and gy >= 0 and gy < terrain_grid[0].size():
		return terrain_grid[gx][gy]
	return -1

func get_overlay(gx: int, gy: int) -> int:
	if overlay_grid.is_empty():
		return 0
	if gx >= 0 and gx < overlay_grid.size() and gy >= 0 and gy < overlay_grid[0].size():
		return overlay_grid[gx][gy]
	return 0

func get_height_at_grid(gx:int,gy:int)->float:
	if gx>=0 and gx<height_grid.size() and gy>=0 and gy<height_grid[0].size():
		return height_grid[gx][gy]
	return 0.0

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
	if height_grid.size() > gx and height_grid[gx].size() > gz:
		return height_grid[gx][gz]
	return 0.0
		

func get_terrain_texture() -> ImageTexture:
	return terrain_texture

func get_terrain_grid() -> Array:
	return terrain_grid
