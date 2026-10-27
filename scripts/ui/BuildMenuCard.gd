class_name BuildMenuCard
extends Button

# 建造菜单的图标卡片：3D 模型缩略图 + 名称 + 成本 + 快捷键角标。
# 单机（BuildMenu）和联机客户端（ClientBuildMenu）共用，保证两边长得一样。

const ICON_DIR := "res://assets/ui/build_icons/"
const RC_HEX := {
	"wood": "#6FBF73", "stone": "#B9B9B9", "gold": "#C9A84C",
	"food": "#D9A05B", "oil": "#A9714B",
}
const RC_NAME := {"wood": "木", "stone": "石", "gold": "金", "food": "粮", "oil": "油"}
const RC_ORDER := ["wood", "stone", "gold", "food", "oil"]

static var _icon_cache: Dictionary = {}

var building_id: int = 0
var _icon: TextureRect
var _fallback: Label
var _name_label: Label
var _cost_label: RichTextLabel
var _hotkey_label: Label
var _lock_cover: ColorRect
var _lock_label: Label

# 把成本转成富文本：资源够=资源色，不够=红色
static func cost_bbcode(cost: Dictionary, have: Dictionary) -> String:
	var parts: Array = []
	for res in RC_ORDER:
		var need := int(cost.get(res, 0))
		if need <= 0:
			continue
		var enough: bool = int(have.get(res, 0)) >= need
		var hex_color: String = RC_HEX.get(res, "#D4C5A9") if enough else "#E05A4A"
		parts.append("[color=%s]%s%d[/color]" % [hex_color, RC_NAME.get(res, res), need])
	return " ".join(parts)

# 成本短文本（给 tooltip 用）
static func cost_plain(cost: Dictionary) -> String:
	var parts: Array = []
	for res in RC_ORDER:
		var need := int(cost.get(res, 0))
		if need > 0:
			parts.append("%s%d" % [RC_NAME.get(res, res), need])
	return " ".join(parts)

# 模型缩略图（256×256 透明 PNG），没有就返回 null 走 emoji 兜底
static func icon_texture(building_id: int) -> Texture2D:
	if _icon_cache.has(building_id):
		return _icon_cache[building_id]
	var path := ICON_DIR + "%d.png" % building_id
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path)
	_icon_cache[building_id] = tex
	return tex

func setup(bid: int, display_name: String, cost_text: String, locked: bool, lock_text: String,
		hotkey: int, card_size: Vector2, icon_size: float, name_px: int, cost_px: int,
		cost_lines: int = 2) -> void:
	building_id = bid
	text = ""
	flat = true
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = card_size
	size = card_size
	pivot_offset = card_size * 0.5

	var radius: int = maxi(4, int(card_size.x * 0.045))
	_apply_style("normal", _card_style(Color(0.10, 0.075, 0.06, 0.93), Color(UITheme.GOLD, 0.45), 1, radius))
	_apply_style("hover", _card_style(Color(0.17, 0.13, 0.09, 0.97), UITheme.GOLD, 2, radius))
	_apply_style("pressed", _card_style(Color(0.24, 0.18, 0.11, 0.98), UITheme.GOLD, 2, radius))
	_apply_style("disabled", _card_style(Color(0.07, 0.055, 0.045, 0.9), Color(0.55, 0.48, 0.36, 0.22), 1, radius))
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	var pad_x: float = maxf(4.0, card_size.x * 0.05)
	var icon_y: float = maxf(4.0, card_size.y * 0.045)
	var center_x: float = card_size.x * 0.5

	# 图标
	var tex := icon_texture(bid)
	if tex != null:
		_icon = TextureRect.new()
		_icon.texture = tex
		_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_icon.position = Vector2(center_x - icon_size * 0.5, icon_y)
		_icon.size = Vector2(icon_size, icon_size)
		add_child(_icon)
	else:
		_fallback = Label.new()
		_fallback.text = UITheme.entity_emoji(bid, 1)
		UITheme.apply_label(_fallback, int(icon_size * 0.8), UITheme.PARCHMENT)
		_fallback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_fallback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_fallback.position = Vector2(center_x - icon_size * 0.5, icon_y)
		_fallback.size = Vector2(icon_size, icon_size)
		add_child(_fallback)

	# 名称
	var name_y: float = icon_y + icon_size + 2.0
	var name_h: float = float(name_px) + 4.0
	_name_label = Label.new()
	_name_label.text = display_name
	UITheme.apply_label(_name_label, name_px, UITheme.PARCHMENT)
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_label.position = Vector2(pad_x * 0.5, name_y)
	_name_label.size = Vector2(card_size.x - pad_x, name_h)
	add_child(_name_label)

	# 成本
	var cost_y: float = name_y + name_h
	_cost_label = RichTextLabel.new()
	_cost_label.bbcode_enabled = true
	_cost_label.fit_content = true
	_cost_label.scroll_active = false
	_cost_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if cost_lines > 1 else TextServer.AUTOWRAP_OFF
	_cost_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cost_label.add_theme_color_override("default_color", UITheme.PARCHMENT)
	_cost_label.add_theme_font_size_override("normal_font_size", cost_px)
	_cost_label.add_theme_font_size_override("bold_font_size", cost_px)
	_cost_label.text = "[center]%s[/center]" % cost_text
	_cost_label.position = Vector2(pad_x * 0.5, cost_y)
	_cost_label.size = Vector2(card_size.x - pad_x, float(cost_px * cost_lines) + 6.0)
	add_child(_cost_label)

	# 快捷键角标
	if hotkey > 0:
		_hotkey_label = Label.new()
		_hotkey_label.text = str(hotkey)
		UITheme.apply_label(_hotkey_label, maxi(9, int(card_size.x * 0.085)), UITheme.GOLD)
		_hotkey_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_hotkey_label.position = Vector2(4.0, 1.0)
		add_child(_hotkey_label)

	# 未解锁遮罩
	if locked:
		_lock_cover = ColorRect.new()
		_lock_cover.color = Color(0.02, 0.015, 0.01, 0.66)
		_lock_cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_lock_cover.position = Vector2(pad_x * 0.5, icon_y)
		_lock_cover.size = Vector2(card_size.x - pad_x, icon_size)
		add_child(_lock_cover)
		_lock_label = Label.new()
		_lock_label.text = lock_text if lock_text != "" else "未解锁"
		UITheme.apply_label(_lock_label, maxi(9, int(icon_size * 0.2)), UITheme.VERMILION)
		_lock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_lock_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_lock_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_lock_label.position = Vector2(pad_x * 0.5, icon_y)
		_lock_label.size = Vector2(card_size.x - pad_x, icon_size)
		add_child(_lock_label)

func _apply_style(state: String, style: StyleBoxFlat) -> void:
	add_theme_stylebox_override(state, style)

func _card_style(bg: Color, border: Color, width: int, radius: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.set_border_width_all(width)
	s.border_color = border
	s.content_margin_left = 0
	s.content_margin_right = 0
	s.content_margin_top = 0
	s.content_margin_bottom = 0
	return s
