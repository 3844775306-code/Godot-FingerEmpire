class_name MobileUnitBar
extends Control

# 底部中间·单位条：列出当前选中的单位，点按聚焦、长按从选择中移除。
# 只做展示与聚焦，不改选择逻辑本身。

signal focus_requested(entity)

const HEIGHT_DP: float = 44.0
const ITEM_W_DP: float = 58.0
const MAX_ITEMS: int = 8

var selection_provider: Callable = Callable()

var _panel: Panel = null
var _hbox: HBoxContainer = null
var _scroll: ScrollContainer = null
var _items: Array = []

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()

func _build() -> void:
	UILayout.place_dp(self, "bottom", 0.0, HEIGHT_DP)
	# 底部居中条：宽度跟随内容，锚点固定在底部中间
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 1.0
	anchor_bottom = 1.0
	var insets := UILayout.safe_insets()
	var w := UILayout.dp(340.0)
	offset_left = -w * 0.5
	offset_right = w * 0.5
	offset_top = -insets.w - UILayout.dp(4.0) - UILayout.dp(HEIGHT_DP)
	offset_bottom = -insets.w - UILayout.dp(4.0)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BEGIN

	_panel = Panel.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(UITheme.INK, 0.7)
	style.border_color = Color(UITheme.GOLD, 0.25)
	style.set_border_width_all(1)
	style.set_corner_radius_all(int(UILayout.dp(8.0)))
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	_scroll = ScrollContainer.new()
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll.offset_left = UILayout.dp(4.0)
	_scroll.offset_right = -UILayout.dp(4.0)
	_scroll.offset_top = UILayout.dp(3.0)
	_scroll.offset_bottom = -UILayout.dp(3.0)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_scroll)

	_hbox = HBoxContainer.new()
	_hbox.add_theme_constant_override("separation", int(UILayout.dp(4.0)))
	_scroll.add_child(_hbox)
	visible = false

# 由 MobileHUD 定时调用
func refresh(selected: Array) -> void:
	# 无选中 → 整条隐藏，把战场让出来
	if selected.is_empty():
		if visible:
			visible = false
			_clear_items()
		return
	visible = true

	if _signature(selected) == _current_signature:
		return
	_current_signature = _signature(selected)
	_rebuild(selected)

var _current_signature: String = ""

func _signature(selected: Array) -> String:
	var parts: Array = []
	for e in selected:
		if e == null or not is_instance_valid(e):
			continue
		var nm := str(e.get("display_name"))
		var hp := int(e.get("health"))
		parts.append("%s:%d" % [nm, hp])
	return "|".join(parts)

func _clear_items() -> void:
	for item in _items:
		if is_instance_valid(item):
			item.queue_free()
	_items.clear()

func _rebuild(selected: Array) -> void:
	_clear_items()
	var shown := 0
	for e in selected:
		if shown >= MAX_ITEMS:
			break
		if e == null or not is_instance_valid(e):
			continue
		_items.append(_make_item(e))
		shown += 1

func _make_item(entity: Node) -> Control:
	var item := Button.new()
	item.custom_minimum_size = Vector2(UILayout.dp(ITEM_W_DP), UILayout.dp(HEIGHT_DP - 8.0))
	item.flat = true
	item.mouse_filter = Control.MOUSE_FILTER_STOP

	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item.add_child(vb)

	var name_lbl := Label.new()
	name_lbl.text = str(entity.get("display_name")) if entity.get("display_name") != null else "单位"
	name_lbl.add_theme_font_size_override("font_size", 11)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(name_lbl)

	var hp := ProgressBar.new()
	hp.max_value = 100.0
	hp.show_percentage = false
	hp.custom_minimum_size = Vector2(0.0, UILayout.dp(4.0))
	var max_hp := float(entity.get("max_health")) if entity.get("max_health") != null else 100.0
	var cur_hp := float(entity.get("health")) if entity.get("health") != null else max_hp
	hp.value = clampf(cur_hp / maxf(max_hp, 1.0) * 100.0, 0.0, 100.0)
	hp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(hp)

	item.pressed.connect(func(): focus_requested.emit(entity))
	_hbox.add_child(item)
	return item
