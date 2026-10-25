# scripts/ui/Minimap.gd
class_name  Minimap
extends Control

const TERRAIN_BRIGHTNESS = 0.55
const MINIMAP_SIZE = 400
# 小地图随视角旋转时，正方形转到 45° 的对角线是边长的 √2 倍，四角会冲出控件被裁掉。
# 内容整体再乘 1/√2（≈0.707，这里取 0.70 留一点余量）之后，任意角度都刚好落在框内。
const ROTATION_FIT: float = 0.70

var terrain_colors: Array = []
var explored_grid: Array = []
var visible_grid: Array = []
var entity_snapshots: Array = []
var player_team: int = 1
var camera: Camera3D = null

# 纹理缓存
var _terrain_tex: ImageTexture = null
var _tex_dirty: bool = true

# 战事警报系统
var alert_signals: Array = []
const ALERT_DURATION: float = 3.0
const ALERT_MAX_RADIUS: float = 35.0
const ALERT_PULSE_PERIOD: float = 0.5

var latest_alert_world_pos: Vector3 = Vector3.ZERO
var has_latest_alert: bool = false

# 当前视角框：记录上次的相机位置/朝向/视野，变化时重绘
var _last_cam_pos: Vector2 = Vector2(999999.0, 999999.0)
var _last_cam_yaw: float = 99999.0
var _last_cam_size: float = -1.0
# 屏幕中心对应的地面点（由 _process 每帧算好给绘制用）
var _view_center: Vector3 = Vector3.ZERO

func _ready():
	custom_minimum_size = Vector2(MINIMAP_SIZE, MINIMAP_SIZE)
	# 视角框旋转后可能超出小地图，裁掉超出部分，避免画到面板外面
	clip_contents = true
	mouse_filter = MOUSE_FILTER_STOP
	camera = get_viewport().get_camera_3d()
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
	# 准星跟随屏幕中心的地面点：正交相机 global_position 只是「眼睛」位置，
	# 有俯角时屏幕中心对应的是相机前下方的地面点，直接用相机 x/z 会明显偏前
	if camera != null and is_instance_valid(camera):
		var c: Vector3 = camera.call("_screen_center_ground") if camera.has_method("_screen_center_ground") else camera.global_position
		_view_center = c
		var cam_pos := Vector2(c.x, c.z)
		var cam_yaw: float = float(camera.get("yaw_deg")) if camera.get("yaw_deg") != null else 0.0
		var cam_size: float = camera.size
		if cam_pos.distance_to(_last_cam_pos) > 0.05 \
				or absf(cam_yaw - _last_cam_yaw) > 0.3 \
				or absf(cam_size - _last_cam_size) > 0.3:
			_last_cam_pos = cam_pos
			_last_cam_yaw = cam_yaw
			_last_cam_size = cam_size
			queue_redraw()

func set_data(p_explored: Array, p_visible: Array, p_entities: Array, p_terrain_dirty: bool = true):
	explored_grid = p_explored
	visible_grid = p_visible
	entity_snapshots = p_entities
	# 只有迷雾/探索范围变化时才重建小地图底图。单位点每 0.5s 更新一次，
	# 若每次都给 _tex_dirty 置真，会在后期反复重画 100×100 格 ×16 像素的底图。
	if p_terrain_dirty or _terrain_tex == null:
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
	# 在线模式下动态更新玩家队伍
	var bm = get_tree().get_first_node_in_group("battle_manager")
	if bm and bm.has_method("get_host_team"):
		player_team = bm.get_host_team()
	elif bm == null:
		# 纯客户端没有 battle_manager，队伍归属从渲染器取
		var renderer = get_tree().get_first_node_in_group("client_renderer")
		if renderer and renderer.has_method("get_host_team"):
			player_team = renderer.get_host_team()
	if terrain_colors.is_empty() or explored_grid.is_empty():
		return

	var ms = RTSConfig.MAP_SIZE
	var cell = float(MINIMAP_SIZE) / ms

	if _tex_dirty or not _terrain_tex:
		_rebuild_terrain_texture()

	# 手机端节点尺寸可能小于内部基准 400：内部照旧按 MINIMAP_SIZE 坐标画，
	# 这里统一换算成缩放因子，所有绘制代码不必改。
	var sc: float = size.x / float(MINIMAP_SIZE) if MINIMAP_SIZE > 0 else 1.0
	if sc <= 0.01:
		sc = 1.0
	# 小地图随相机朝向一起转：屏幕上"往前"的方向永远是小地图的"上"，
	# 这样点小地图移动和拖动战场的手感才一致。
	# yaw 增大表示视角向右转，2D 正值也是顺时针，所以这里用正号跟住。
	var yaw_rad: float = deg_to_rad(_last_cam_yaw) if _last_cam_yaw < 9999.0 else 0.0
	var pivot := Vector2(size.x, size.y) * 0.5
	# draw_set_transform 是「先缩放旋转、再平移」，所以平移量必须扣掉旋转后的内容中心。
	# 直接用 pivot 会让地图中心偏离框中心，转起来像绕着框的左上角打转。
	# 内容额外乘 ROTATION_FIT，保证转到任意角度四角都不出框。
	var content_center := Vector2(MINIMAP_SIZE, MINIMAP_SIZE) * 0.5
	var inner: float = sc * ROTATION_FIT
	var offset := pivot - (content_center * inner).rotated(yaw_rad)
	draw_set_transform(offset, yaw_rad, Vector2(inner, inner))

	if _terrain_tex:
		draw_texture(_terrain_tex, Vector2.ZERO)

	# 每次绘制时实时查询颜色，和战场实体同源
	var pc = {}
	bm = get_tree().get_first_node_in_group("battle_manager")
	if bm and bm.has_method("get_player_colors"):
		pc = bm.get_player_colors()
	if pc.is_empty():
		# 纯客户端从渲染器取玩家配色（2v2/3v3 按玩家着色）
		var client_renderer = get_tree().get_first_node_in_group("client_renderer")
		if client_renderer:
			pc = client_renderer.player_colors

	# —— 资源点：先画、弱化为 2x2 暗点，避免与单位方块混淆 ——
	for ent in entity_snapshots:
		if ent.get("type", -1) != 0: continue
		var gx = int(ent["x"] + ms / 2)
		var gz = int(ent["z"] + ms / 2)
		if gx < 0 or gx >= ms or gz < 0 or gz >= ms: continue
		if gx >= explored_grid.size() or gz >= explored_grid[gx].size(): continue
		if not explored_grid[gx][gz]: continue
		var eid = ent.get("entity_id", -1)
		var rkey = ["gold", "wood", "stone", "food", "oil"][eid] if eid >= 0 and eid <= 4 else "gold"
		var rc: Color = UITheme.RESOURCE_COLORS.get(rkey, Color(0.4, 0.4, 0.2)).darkened(0.35)
		var res_visible = visible_grid[gx][gz] if gx < visible_grid.size() and gz < visible_grid[gx].size() else false
		rc.a = 0.5 if res_visible else 0.28
		var rpos = Vector2(gx * cell, gz * cell)
		draw_rect(Rect2(rpos - Vector2(1, 1), Vector2(2, 2)), rc)

	# —— 单位/建筑：后画，保持 5x5 色块并加深色描边 ——
	for ent in entity_snapshots:
		if ent.get("type", -1) == 0: continue
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
		var eid = ent.get("entity_id", -1)
		var dot_color: Color
		# 动物羊皮纸白
		if eid >= 60 and eid <= 63:
			dot_color = UITheme.PARCHMENT
		elif ent.has("color"):
			# 单机/服务器快照直接带国家色；与模型、血条保持同一套颜色。
			dot_color = ent["color"].lightened(0.25)
		elif int(ent.get("nation", -1)) >= 0:
			# 联机客户端快照里带 nation，直接按国家色画点。
			dot_color = RTSConfig.get_nation_color(int(ent["nation"])).lightened(0.25)
		elif owner != -1 and pc.has(owner):
			dot_color = pc[owner].lightened(0.25)
		elif ent["team"] == player_team:
			dot_color = UITheme.VERMILION.lightened(0.15) if player_team == RTSConfig.Team.RED else UITheme.SAPPHIRE.lightened(0.25)
		elif ent["team"] == RTSConfig.Team.RED or (bm and bm.has_method("get_enemy_team") and ent["team"] == bm.get_enemy_team()):
			var enemy_team: int = RTSConfig.Team.RED
			if bm and bm.has_method("get_enemy_team"):
				enemy_team = bm.get_enemy_team()
			dot_color = UITheme.SAPPHIRE.lightened(0.25) if enemy_team == RTSConfig.Team.BLUE else UITheme.VERMILION.lightened(0.15)
		else:
			dot_color = UITheme.GOLD.lightened(0.2)
		var pos = Vector2(gx * cell, gz * cell)
		draw_rect(Rect2(pos - Vector2(3, 3), Vector2(7, 7)), Color(0, 0, 0, 0.55))
		draw_rect(Rect2(pos - Vector2(2, 2), Vector2(5, 5)), dot_color)

	# —— 友方主城：国家色圆环 + 白外弧单独特标，混在单位点里也能一眼找到 ——
	for ent in entity_snapshots:
		if int(ent.get("entity_id", -1)) != 20: continue
		if int(ent.get("team", -2)) != player_team: continue
		var cgx = int(ent["x"] + ms / 2)
		var cgz = int(ent["z"] + ms / 2)
		if cgx < 0 or cgx >= ms or cgz < 0 or cgz >= ms: continue
		var cpos = Vector2(cgx * cell, cgz * cell)
		# 主城标记取所属势力的国家色，与单位点同色系、靠更大圆环 + 白色外弧区分
		var ccolor: Color = UITheme.GOLD
		if ent.has("color"):
			ccolor = ent["color"]
		elif int(ent.get("nation", -1)) >= 0:
			ccolor = RTSConfig.get_nation_color(int(ent["nation"]))
		elif bm and bm.has_method("get_team_nation"):
			var nn: int = int(bm.get_team_nation(player_team))
			if nn >= 0:
				ccolor = RTSConfig.get_nation_color(nn)
		var cr = 8.0
		draw_circle(cpos, cr + 3.0, Color(0, 0, 0, 0.6))
		draw_circle(cpos, cr, Color(ccolor.lightened(0.1), 0.95))
		draw_arc(cpos, cr + 4.0, 0.0, TAU, 28, Color(1.0, 1.0, 1.0, 0.85), 1.5)

	# 战事警报
	for alert in alert_signals:
		var progress = alert["timer"] / alert["max_time"]
		var pulse = abs(sin(Time.get_ticks_msec() / 1000.0 / ALERT_PULSE_PERIOD * PI))
		var radius = lerp(4.0, ALERT_MAX_RADIUS, 1.0 - progress) * (0.6 + 0.4 * pulse)
		var alpha = progress * (0.7 + 0.3 * pulse)
		var ring_color = Color(UITheme.VERMILION, alpha)
		draw_circle(alert["pos"], radius, Color(UITheme.VERMILION, alpha * 0.25))
		draw_arc(alert["pos"], radius, 0, TAU, 32, ring_color, 2.0)

	# 当前视角框（画在最后，压在地形与单位点上面）
	_draw_view_frame(ms, cell)

	# 边框也在变换内绘制：和地图一起缩放、一起旋转，
	# 整块小地图像一个会转的罗盘。放在变换外面的话，转过视角后
	# 框还是正方的 400 基准尺寸，会把 77dp 的控件整个撑满并露出框外。
	draw_rect(Rect2(Vector2(2, 2), Vector2(MINIMAP_SIZE - 4, MINIMAP_SIZE - 4)), Color(UITheme.INK, 0.4), false, UITheme.BORDER_MED)
	draw_rect(Rect2(Vector2.ZERO, Vector2(MINIMAP_SIZE, MINIMAP_SIZE)), Color(UITheme.GOLD, UITheme.ALPHA_BG), false, UITheme.BORDER_THICK)

	# 复位变换，避免影响同一帧后续可能追加的绘制
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

# 在小地图上标出屏幕中心对应的地面位置：一个白色十字准星
func _draw_view_frame(ms: float, cell: float) -> void:
	if camera == null or not is_instance_valid(camera):
		return
	var center := _view_center
	var px := Vector2((center.x + ms * 0.5) * cell, (center.z + ms * 0.5) * cell)
	# 先垫一层暗底，浅色地形（沙漠、雪地）上也看得清
	draw_circle(px, 8.0, Color(0.0, 0.0, 0.0, 0.40))
	draw_arc(px, 6.0, 0.0, TAU, 24, Color(1.0, 1.0, 1.0, 0.95), 1.5)
	draw_line(px + Vector2(-10.0, 0.0), px + Vector2(10.0, 0.0), Color(1.0, 1.0, 1.0, 0.85), 1.0)
	draw_line(px + Vector2(0.0, -10.0), px + Vector2(0.0, 10.0), Color(1.0, 1.0, 1.0, 0.85), 1.0)

func _gui_input(event):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var local = event.position
		# 用控件实际尺寸换算，避免窗口/布局变化后坐标偏移
		var w = maxf(size.x, 1.0)
		var h = maxf(size.y, 1.0)
		if local.x >= 0 and local.x <= w and local.y >= 0 and local.y <= h:
			# 小地图是「以框中心为轴」旋转显示的：点击位置先减去框中心、逆旋转，
			# 再按内部基准尺寸归一化，才能得到真正对应的地图坐标。
			var sc: float = w / float(MINIMAP_SIZE)
			if sc <= 0.001:
				sc = 1.0
			var yaw_rad: float = deg_to_rad(_last_cam_yaw) if _last_cam_yaw < 9999.0 else 0.0
			var pivot := Vector2(w, h) * 0.5
			var rel: Vector2 = (local - pivot).rotated(-yaw_rad) / (float(MINIMAP_SIZE) * sc * ROTATION_FIT)
			var world_x = rel.x * RTSConfig.MAP_SIZE
			var world_z = rel.y * RTSConfig.MAP_SIZE
			if camera:
				if camera.has_method("focus_on_ground"):
					camera.focus_on_ground(Vector3(world_x, 0, world_z))
				else:
					camera.global_position = Vector3(world_x, camera.global_position.y, world_z)
