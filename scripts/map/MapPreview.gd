# 地图缩略图：复用正式生成管线，按固定种子跑小尺寸网格再放大。
# 只用于菜单展示，不影响实际对局地图（对局仍由 Ground 用真实尺寸生成）。
extends RefCounted

const GroundScript = preload("res://scripts/map/Ground.gd")
const MapPresets = preload("res://scripts/map/MapPresets.gd")

const GRID := 64

static var _cache: Dictionary = {}

static func get_texture(id: String, px: int = 270) -> ImageTexture:
	var key := "%s:%d" % [id, px]
	if _cache.has(key):
		return _cache[key]
	var tex := _render(id, px)
	_cache[key] = tex
	return tex

static func _render(id: String, px: int) -> ImageTexture:
	var g = GroundScript.new()
	g.map_size_override = GRID
	g.map_preset = MapPresets.get_preset(id)
	# 固定种子：同一张图每次打开菜单缩略图一致；地形预设本身也只决定大局形状
	g.custom_seed = 1000 + absi(hash(id)) % 999
	var stages: Array = g.map_preset.get("stages", [])
	if stages.is_empty():
		g._generate_classic(GRID)
	else:
		g._generate_with_stages(GRID, stages)
	var img := Image.create_empty(GRID, GRID, false, Image.FORMAT_RGBA8)
	for x in range(GRID):
		for y in range(GRID):
			var c: Color = g._terrain_color_for(g.terrain_grid[x][y], g.height_grid[x][y], x, y, g.get_overlay(x, y))
			c.a = 1.0
			img.set_pixel(x, y, c)
	img.resize(px, px, Image.INTERPOLATE_NEAREST)
	g.free()
	return ImageTexture.create_from_image(img)
