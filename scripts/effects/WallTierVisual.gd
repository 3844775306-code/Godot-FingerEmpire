class_name WallTierVisual
extends RefCounted

# 城墙等级外观（纯程序化材质，不新增 GLB）：
# Lv.1 木墙、Lv.2 粗糙低阶石墙、Lv.3 平整好石墙。
# 服务端与客户端共用同一套纹理/材质缓存，避免两边看起来不一致。

const WALL_ID: int = 27
const TEX_SIZE: int = 128
const TEXTURE_SCALE: float = 0.35

static var _texture_cache: Dictionary = {}
static var _material_cache: Dictionary = {}

static func apply(building: Node3D, level: int, team_color: Color = Color.WHITE) -> void:
	if building == null or not is_instance_valid(building):
		return
	var eid = building.get("entity_id")
	if eid == null:
		eid = building.get_meta("_entity_id", -1)
	if int(eid) != WALL_ID:
		return
	level = clampi(level, 1, 3)
	var key: String = "%d_%s" % [level, team_color.to_html()]
	var model = building.get_meta("_model_instance", null)
	if not is_instance_valid(model) or not (model is Node3D):
		return
	if building.has_meta("_wall_tier_key") and str(building.get_meta("_wall_tier_key")) == key \
			and building.has_meta("_wall_tier_model") and building.get_meta("_wall_tier_model") == model:
		return
	_apply_recursive(model, _material_for(level, team_color))
	building.set_meta("_wall_tier_key", key)
	building.set_meta("_wall_tier_model", model)

static func _apply_recursive(node: Node, mat: Material) -> void:
	if node is MeshInstance3D and node.mesh != null:
		(node as MeshInstance3D).material_override = mat
	for child in node.get_children():
		_apply_recursive(child, mat)

static func _material_for(level: int, team_color: Color) -> StandardMaterial3D:
	var key: String = "%d_%s" % [level, team_color.to_html()]
	if _material_cache.has(key):
		return _material_cache[key] as StandardMaterial3D
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _texture_for(level)
	# 只混一点点队伍色，保留木材/石头的本色，又能在远处区分敌我城墙。
	mat.albedo_color = Color.WHITE.lerp(team_color, 0.16)
	mat.roughness = 0.95 if level <= 2 else 0.82
	mat.metallic = 0.0
	# 城墙模型各处 UV 不统一，改用世界坐标三平面投影，木纹/石缝才会连续。
	mat.uv1_triplanar = true
	mat.uv1_world_triplanar = true
	mat.uv1_scale = Vector3(TEXTURE_SCALE, TEXTURE_SCALE, TEXTURE_SCALE)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_material_cache[key] = mat
	return mat

static func _texture_for(level: int) -> ImageTexture:
	if _texture_cache.has(level):
		return _texture_cache[level] as ImageTexture
	var img := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGB8)
	for y in range(TEX_SIZE):
		for x in range(TEX_SIZE):
			var c: Color
			if level <= 1:
				c = _wood_pixel(x, y)
			elif level == 2:
				c = _low_stone_pixel(x, y)
			else:
				c = _good_stone_pixel(x, y)
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_texture_cache[level] = tex
	return tex

# 竖直木板：每 16 像素一块板，板缝深色，木纹沿高度轻微起伏。
static func _wood_pixel(x: int, y: int) -> Color:
	var plank: int = x / 16
	var seam: int = x % 16
	var grain: float = 0.5 + 0.5 * sin(float(y) * 0.33 + float(x) * 0.16 + sin(float(x) * 0.5) * 1.8)
	var tone: float = 0.24 + grain * 0.10 + float(plank % 3) * 0.012
	if seam <= 1 or seam >= 14:
		tone *= 0.48
	# 少量木节：固定位置的小暗斑，避免整面墙像塑料。
	var knot_x: int = (plank * 37 + 11) % 128
	if absi(x - knot_x) <= 1 and absi(y - (plank * 53 + 19) % 128) <= 3:
		tone *= 0.62
	return Color(tone * 1.05, tone * 0.66, tone * 0.36)

# 低阶石墙：块大、灰褐、缝隙宽，夹杂草根/泥土色斑。
static func _low_stone_pixel(x: int, y: int) -> Color:
	var row: int = y / 16
	var row_off: int = (row % 2) * 11
	var bx: int = (x + row_off) % 24
	var by: int = y % 16
	var mortar: bool = by <= 2 or bx <= 2
	var n: float = _hash01(x / 3, y / 3)
	var tone: float = 0.34 + n * 0.11 + 0.025 * sin(float(x) * 0.2 + float(y) * 0.17)
	if mortar:
		tone = 0.20 + n * 0.04
	# 稀疏苔藓/土渍，低阶石头显得更旧。
	if _hash01(x / 9, y / 9) > 0.86 and not mortar:
		return Color(tone * 0.78, tone * 0.86, tone * 0.55)
	return Color(tone * 1.02, tone * 0.96, tone * 0.84)

# 高阶石墙：块面平整、灰白、缝隙细直，少量高光让石头看起来更坚固。
static func _good_stone_pixel(x: int, y: int) -> Color:
	var row: int = y / 20
	var row_off: int = (row % 2) * 16
	var bx: int = (x + row_off) % 32
	var by: int = y % 20
	var mortar: bool = by <= 1 or bx <= 1
	var n: float = _hash01(x / 4, y / 4)
	var tone: float = 0.53 + n * 0.07 + 0.02 * sin(float(x) * 0.11 + float(y) * 0.13)
	if mortar:
		tone = 0.39 + n * 0.035
	# 每块石头的上沿提亮，形成被切割过的平整倒角。
	elif by <= 3:
		tone += 0.045
	return Color(tone, tone * 0.985, tone * 0.94)

static func _hash01(x: int, y: int) -> float:
	var n: int = x * 374761393 + y * 668265263
	n = (n ^ (n >> 13)) * 1274126177
	return float((n ^ (n >> 16)) & 0xFFFF) / 65535.0
