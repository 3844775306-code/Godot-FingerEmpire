class_name EntityIcon
extends RefCounted

# 实体图标统一入口：建筑读建造菜单那套渲染图（assets/ui/build_icons），
# 单位/资源读 tools/render_entity_icons.gd 生成的图（assets/ui/entity_icons）。
# 生产按钮、信息面板头像、框选分组列表都会反复用到同一张图，这里做一次缓存。
# 找不到图时返回 null，调用方回退到 emoji，保证任何时候都不会出现空格子。

const BUILD_DIR := "res://assets/ui/build_icons/"
const ENTITY_DIR := "res://assets/ui/entity_icons/"

static var _cache: Dictionary = {}

static func texture(entity_id: int, entity_type: int = -1) -> Texture2D:
	var key := "%d|%d" % [entity_id, entity_type]
	if _cache.has(key):
		return _cache[key] as Texture2D
	var tex: Texture2D = null
	if entity_type == 1:
		tex = _load_from(BUILD_DIR, entity_id)
		if tex == null:
			tex = _load_from(ENTITY_DIR, entity_id)
	else:
		tex = _load_from(ENTITY_DIR, entity_id)
		if tex == null:
			tex = _load_from(BUILD_DIR, entity_id)
	_cache[key] = tex
	return tex

static func has(entity_id: int, entity_type: int = -1) -> bool:
	return texture(entity_id, entity_type) != null

# 按需创建一张固定边长的图标（等比缩放、居中、不吃鼠标事件）
static func make_rect(entity_id: int, entity_type: int, px: float) -> TextureRect:
	var tex := texture(entity_id, entity_type)
	if tex == null:
		return null
	var tr := TextureRect.new()
	tr.texture = tex
	tr.custom_minimum_size = Vector2(px, px)
	tr.size = Vector2(px, px)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr

static func _load_from(dir: String, entity_id: int) -> Texture2D:
	var path := "%s%d.png" % [dir, entity_id]
	if not ResourceLoader.exists(path):
		return null
	var res = load(path)
	if res is Texture2D:
		return res as Texture2D
	return null
