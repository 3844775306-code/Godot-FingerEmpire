class_name ChangelogPanel
extends Control

# 更新日志面板：主菜单点「📜 更新日志」打开。
# 结构参考对局内设置面板（暖黑卡片 + 金边 + 可滚动内容）：
#   标题「📜 更新日志」+ 当前版本（v1.0.0 (2026-10-26)）+ 版本条目列表。
# 打开即把最新版本记为已读，主菜单入口的 NEW 标记随之消失。
# 手机端：面板铺满可用高度、内容可滚动，触摸拖动由 MainMenu 的滚动驱动处理
# （主菜单没有战斗里的 TouchGestureRouter，所以走 UILayout.scroll_at）。

const AppVersion = preload("res://scripts/core/AppVersion.gd")
const ChangelogData = preload("res://scripts/data/ChangelogData.gd")

const PANEL_W: float = 780.0
const PANEL_H: float = 900.0

# 是否在最新一条上打 NEW（打开前读一次，打开后就标记已读）
var _show_new: bool = false
var _mobile: bool = false

# 打开更新日志：已经开着就直接返回（避免叠两层）
static func open(parent: Node) -> ChangelogPanel:
	var existing := parent.get_node_or_null("ChangelogPanel") as ChangelogPanel
	if existing != null:
		return existing
	var panel := ChangelogPanel.new()
	panel.name = "ChangelogPanel"
	panel._show_new = ChangelogData.is_unseen()
	parent.add_child(panel)
	# 打开就算看过了：关掉面板后主菜单的 NEW 标记不会再来
	ChangelogData.mark_seen()
	return panel

func _ready() -> void:
	_mobile = InputSource.use_mobile_ui()
	add_to_group("mobile_modal_ui")
	# 主菜单（桌面分支）根节点没有设设计尺寸，anchors 会整体塌成 40×40，
	# 所以这里直接按设计尺寸铺满，不依赖父节点大小。
	size = Vector2(UILayout.DESIGN_W, UILayout.DESIGN_H)
	position = Vector2.ZERO
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 250
	_build()
	UITheme.fade_in(self, 0.18)

# ==================== 界面构建 ====================
func _build() -> void:
	# 半透明遮罩：点空白处关闭
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.68)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(_on_dim_input)
	add_child(dim)

	var pad: float = UILayout.dp(9.0) if _mobile else 14.0

	var panel := Panel.new()
	var w: float = PANEL_W
	var h: float = PANEL_H
	if _mobile:
		w = minf(UILayout.dp(360.0), UILayout.DESIGN_W - UILayout.dp(12.0))
		h = UILayout.DESIGN_H - UILayout.dp(16.0)
	panel.custom_minimum_size = Vector2(w, h)
	panel.size = Vector2(w, h)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.offset_left = -w * 0.5
	panel.offset_right = w * 0.5
	panel.offset_top = -h * 0.5
	panel.offset_bottom = h * 0.5
	var st := StyleBoxFlat.new()
	st.bg_color = Color(UITheme.INK, 0.97)
	st.set_corner_radius_all(10)
	st.set_border_width_all(2)
	st.border_color = Color(UITheme.GOLD, 0.55)
	panel.add_theme_stylebox_override("panel", st)
	add_child(panel)

	# 头部：标题 + 当前版本 + 关闭
	var header := HBoxContainer.new()
	header.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	header.offset_left = pad
	header.offset_right = -pad
	header.offset_top = pad * 0.6
	header.offset_bottom = pad * 0.6 + (UILayout.dp(28.0) if _mobile else 40.0)
	header.add_theme_constant_override("separation", 10)
	panel.add_child(header)

	var title := UITheme.make_section_title("📜 更新日志", UITheme.GOLD,
		UILayout.font_dp(13.0) if _mobile else UITheme.FONT_XL)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	var ver := Label.new()
	ver.text = AppVersion.display()
	ver.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ver.add_theme_font_size_override("font_size",
		UILayout.font_dp(9.5) if _mobile else UITheme.FONT_SM)
	ver.add_theme_color_override("font_color", UITheme.PARCHMENT)
	header.add_child(ver)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.custom_minimum_size = Vector2(
		UILayout.dp(30.0) if _mobile else 40.0,
		UILayout.dp(22.0) if _mobile else 34.0)
	UITheme.apply_muted_button(close_btn,
		UILayout.font_dp(10.0) if _mobile else UITheme.FONT_MD)
	close_btn.pressed.connect(_close)
	header.add_child(close_btn)

	# 内容区：所有版本条目竖向滚动
	var scroll := ScrollContainer.new()
	scroll.name = "ChangelogScroll"
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left = pad
	scroll.offset_right = -pad
	scroll.offset_top = pad * 0.6 + (UILayout.dp(32.0) if _mobile else 46.0)
	scroll.offset_bottom = -pad
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	panel.add_child(scroll)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", int(UILayout.dp(9.0)) if _mobile else 16)
	scroll.add_child(vb)

	var list: Array = ChangelogData.entries()
	for i in list.size():
		_add_entry(vb, list[i], i == 0 and _show_new)
		if i < list.size() - 1:
			_add_separator(vb)

	# 末尾补一行：怎么反馈问题
	var tail := Label.new()
	tail.text = "更多细节可以在游戏内实际体验，遇到问题欢迎反馈给作者。"
	tail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tail.add_theme_font_size_override("font_size",
		UILayout.font_dp(8.5) if _mobile else UITheme.FONT_XS)
	tail.add_theme_color_override("font_color", Color(UITheme.STONE.lightened(0.25)))
	vb.add_child(tail)

	if _mobile:
		UILayout.scale_widgets_for_mobile(vb)

# 一条版本记录：版本徽章 + 日期 (+NEW) → 标题 → 要点列表
func _add_entry(parent: Control, entry: Dictionary, show_new: bool) -> void:
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", int(UILayout.dp(3.0)) if _mobile else 6)
	parent.add_child(block)

	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", int(UILayout.dp(5.0)) if _mobile else 8)
	block.add_child(top_row)

	var chip := Label.new()
	chip.text = String(entry.get("version", ""))
	chip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	chip.add_theme_font_size_override("font_size",
		UILayout.font_dp(9.5) if _mobile else UITheme.FONT_SM)
	chip.add_theme_color_override("font_color", UITheme.GOLD)
	var chip_style := StyleBoxFlat.new()
	chip_style.bg_color = Color(UITheme.GOLD, 0.14)
	chip_style.border_color = Color(UITheme.GOLD, 0.65)
	chip_style.set_border_width_all(1)
	chip_style.set_corner_radius_all(4)
	chip_style.set_content_margin_all(4)
	chip.add_theme_stylebox_override("normal", chip_style)
	top_row.add_child(chip)

	var date := Label.new()
	date.text = String(entry.get("date", ""))
	date.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	date.add_theme_font_size_override("font_size",
		UILayout.font_dp(9.0) if _mobile else UITheme.FONT_XS)
	date.add_theme_color_override("font_color", Color(UITheme.STONE.lightened(0.3)))
	top_row.add_child(date)

	if show_new:
		var new_chip := Label.new()
		new_chip.text = "NEW"
		new_chip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		new_chip.add_theme_font_size_override("font_size",
			UILayout.font_dp(8.5) if _mobile else UITheme.FONT_XS)
		new_chip.add_theme_color_override("font_color", UITheme.GOLD_TEXT)
		var new_style := StyleBoxFlat.new()
		new_style.bg_color = UITheme.GOLD
		new_style.set_corner_radius_all(4)
		new_style.set_content_margin_all(4)
		new_chip.add_theme_stylebox_override("normal", new_style)
		top_row.add_child(new_chip)

	var ttl := Label.new()
	ttl.text = String(entry.get("title", ""))
	ttl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ttl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ttl.add_theme_font_size_override("font_size",
		UILayout.font_dp(10.5) if _mobile else UITheme.FONT_MD)
	ttl.add_theme_color_override("font_color", UITheme.PARCHMENT)
	block.add_child(ttl)

	for item in entry.get("items", []):
		var line := Label.new()
		line.text = "• " + String(item)
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_theme_font_size_override("font_size",
			UILayout.font_dp(9.5) if _mobile else UITheme.FONT_SM)
		line.add_theme_color_override("font_color", Color(UITheme.PARCHMENT, 0.88))
		block.add_child(line)

func _add_separator(parent: Control) -> void:
	var sep := ColorRect.new()
	sep.color = Color(UITheme.GOLD, 0.22)
	sep.custom_minimum_size = Vector2(0, 1)
	parent.add_child(sep)

# ==================== 关闭 ====================
func _on_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_close()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
		and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_close()

func _close() -> void:
	queue_free()
