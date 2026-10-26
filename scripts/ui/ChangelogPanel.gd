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
const UpdateChecker = preload("res://scripts/core/UpdateChecker.gd")

const PANEL_W: float = 780.0
const PANEL_H: float = 900.0

# 是否在最新一条上打 NEW（打开前读一次，打开后就标记已读）
var _show_new: bool = false
var _mobile: bool = false
# 底部「检查更新」一行（手动强制查一次，就地显示结果）
var _update_row: HBoxContainer = null
var _update_btn: Button = null
var _update_status: Label = null
var _update_download_btn: Button = null
var _update_url: String = ""
var _update_checker: UpdateChecker = null

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
		UILayout.font_dp(16.0) if _mobile else UITheme.FONT_XL)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	var ver := Label.new()
	ver.text = AppVersion.display()
	ver.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ver.add_theme_font_size_override("font_size",
		UILayout.font_dp(10.5) if _mobile else UITheme.FONT_SM)
	ver.add_theme_color_override("font_color", UITheme.PARCHMENT)
	header.add_child(ver)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.custom_minimum_size = Vector2(
		UILayout.dp(34.0) if _mobile else 40.0,
		UILayout.dp(26.0) if _mobile else 34.0)
	UITheme.apply_muted_button(close_btn,
		UILayout.font_dp(12.0) if _mobile else UITheme.FONT_MD)
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
	vb.add_theme_constant_override("separation", 16)
	scroll.add_child(vb)

	var list: Array = ChangelogData.entries()
	for i in list.size():
		_add_entry(vb, list[i], i == 0 and _show_new)
		if i < list.size() - 1:
			_add_separator(vb)

	# 底部：手动检查更新（有新版时这里会多出一个下载按钮）
	_add_update_row(vb)
	_add_separator(vb)

	# 末尾补一行：怎么反馈问题
	var tail := Label.new()
	tail.text = "更多细节可以在游戏内实际体验，遇到问题欢迎反馈给作者。"
	tail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tail.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	tail.add_theme_color_override("font_color", Color(UITheme.STONE.lightened(0.25)))
	vb.add_child(tail)

	if _mobile:
		UILayout.scale_widgets_for_mobile(vb)

# 一条版本记录：版本徽章 + 日期 (+NEW) → 标题 → 要点列表
func _add_entry(parent: Control, entry: Dictionary, show_new: bool) -> void:
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 6)
	parent.add_child(block)

	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 8)
	block.add_child(top_row)

	var chip := Label.new()
	chip.text = String(entry.get("version", ""))
	chip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	chip.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	chip.add_theme_color_override("font_color", UITheme.GOLD)
	var chip_style := StyleBoxFlat.new()
	chip_style.bg_color = Color(UITheme.GOLD, 0.14)
	chip_style.border_color = Color(UITheme.GOLD, 0.65)
	chip_style.set_border_width_all(1)
	chip_style.set_corner_radius_all(4)
	chip_style.set_content_margin_all(int(UILayout.dp(2.0)) if _mobile else 4)
	chip.add_theme_stylebox_override("normal", chip_style)
	top_row.add_child(chip)

	var date := Label.new()
	date.text = String(entry.get("date", ""))
	date.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	date.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	date.add_theme_color_override("font_color", Color(UITheme.STONE.lightened(0.3)))
	top_row.add_child(date)

	if show_new:
		var new_chip := Label.new()
		new_chip.text = "NEW"
		new_chip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		new_chip.add_theme_font_size_override("font_size", UITheme.FONT_XS)
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
	ttl.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	ttl.add_theme_color_override("font_color", UITheme.PARCHMENT)
	block.add_child(ttl)

	for item in entry.get("items", []):
		var line := Label.new()
		line.text = "• " + String(item)
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		line.add_theme_color_override("font_color", Color(UITheme.PARCHMENT, 0.88))
		block.add_child(line)

func _add_separator(parent: Control) -> void:
	var sep := ColorRect.new()
	sep.color = Color(UITheme.GOLD, 0.22)
	sep.custom_minimum_size = Vector2(0, 1)
	parent.add_child(sep)

# ==================== 检查更新 ====================
# 面板底部一行：手动强制联网查一次，结果就地显示在右边
func _add_update_row(parent: Control) -> void:
	_update_row = HBoxContainer.new()
	_update_row.add_theme_constant_override("separation", 10)
	parent.add_child(_update_row)

	_update_btn = Button.new()
	_update_btn.text = "🔍 检查更新"
	_update_btn.custom_minimum_size = Vector2(
		UILayout.dp(96.0) if _mobile else 130.0,
		UILayout.dp(26.0) if _mobile else 34.0)
	UITheme.apply_muted_button(_update_btn,
		UILayout.font_dp(11.0) if _mobile else UITheme.FONT_SM)
	_update_btn.pressed.connect(_on_check_update_pressed)
	_update_row.add_child(_update_btn)

	_update_status = Label.new()
	_update_status.text = "点右侧按钮查询有没有新版本"
	_update_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_update_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_update_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_update_status.add_theme_font_size_override("font_size",
		UILayout.font_dp(10.0) if _mobile else UITheme.FONT_SM)
	_update_status.add_theme_color_override("font_color", Color(UITheme.STONE.lightened(0.35)))
	_update_row.add_child(_update_status)

func _on_check_update_pressed() -> void:
	if _update_checker == null:
		_update_checker = UpdateChecker.new()
		_update_checker.name = "UpdateChecker"
		add_child(_update_checker)
		_update_checker.finished.connect(_on_update_result)
	_update_btn.disabled = true
	_update_status.text = "正在检查…"
	_update_checker.check(true)

func _on_update_result(ok: bool, has_update: bool, remote_version: String, download_url: String, notes: String) -> void:
	if _update_btn != null and is_instance_valid(_update_btn):
		_update_btn.disabled = false
	if _update_status == null or not is_instance_valid(_update_status):
		return
	if not ok:
		_update_status.text = notes
		return
	if not has_update:
		_update_status.text = "已是最新版本（%s）" % AppVersion.display()
		return
	_update_status.text = "发现新版本 %s%s" % [remote_version, ("：" + notes) if notes != "" else ""]
	if download_url != "":
		_update_url = download_url
		if _update_download_btn == null:
			_update_download_btn = Button.new()
			_update_download_btn.text = "⬇ 下载"
			_update_download_btn.custom_minimum_size = Vector2(
				UILayout.dp(76.0) if _mobile else 96.0,
				UILayout.dp(26.0) if _mobile else 34.0)
			UITheme.apply_primary_button(_update_download_btn,
				UILayout.font_dp(11.0) if _mobile else UITheme.FONT_SM)
			_update_download_btn.pressed.connect(_on_download_pressed)
			_update_row.add_child(_update_download_btn)
		_update_download_btn.text = "⬇ 下载 %s" % remote_version
		_update_download_btn.visible = true

func _on_download_pressed() -> void:
	if _update_url.strip_edges() != "":
		OS.shell_open(_update_url)

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
