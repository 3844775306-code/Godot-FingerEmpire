class_name EntityCard
extends RefCounted

# 大图标卡片：图标 + 名称 + 说明（价格/数量）。
# 生产按钮和框选分组共用，保证两处观感一致；窄屏（手机）切成上下堆叠，
# 宽屏（桌面）保持图标在左、文字在右，这样图标能放得比原来大得多。
#
# 参数：
#   title_bbcode / sub_bbcode  支持 BBCode（用 [center] 居中）
#   icon_px                    图标边长
#   card_min                   卡片最小尺寸（宽写 0 表示由父容器拉伸）
#   accent                     多选行的高亮色（仅 toggle 时使用）
#   stack                      true = 图标在上文字在下（手机竖排）

static func make(entity_id: int, entity_type: int, title_bbcode: String, sub_bbcode: String,
		icon_px: float, card_min: Vector2, accent: Color, toggle_mode: bool,
		title_font: int, sub_font: int, stack: bool = false) -> Button:
	var btn := Button.new()
	btn.text = ""
	btn.toggle_mode = toggle_mode
	btn.custom_minimum_size = card_min
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.clip_contents = false
	if toggle_mode:
		UITheme.apply_row_button(btn, accent)
	else:
		UITheme.apply_button(btn, title_font)

	var box: BoxContainer
	if stack:
		var vb := VBoxContainer.new()
		vb.alignment = BoxContainer.ALIGNMENT_CENTER
		box = vb
	else:
		var hb := HBoxContainer.new()
		hb.alignment = BoxContainer.ALIGNMENT_CENTER
		box = hb
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 6.0
	box.offset_top = 5.0
	box.offset_right = -6.0
	box.offset_bottom = -5.0
	box.add_theme_constant_override("separation", 6)

	var icon := EntityIcon.make_rect(entity_id, entity_type, icon_px)
	if icon != null:
		if stack:
			icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		box.add_child(icon)

	var texts := VBoxContainer.new()
	texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.add_theme_constant_override("separation", 1)
	texts.add_child(_rtl("[center]%s[/center]" % title_bbcode, title_font, UITheme.PARCHMENT))
	if sub_bbcode != "":
		texts.add_child(_rtl("[center]%s[/center]" % sub_bbcode, sub_font, UITheme.PARCHMENT))
	box.add_child(texts)
	btn.add_child(box)
	return btn

# 图标卡片的"禁用"表现：Button 的 disabled 样式只改底板，塞进去的图标/文字要自己压暗
static func set_dimmed(btn: Button, dimmed: bool) -> void:
	if btn == null:
		return
	btn.modulate = Color(0.62, 0.62, 0.62, 1.0) if dimmed else Color.WHITE

static func _rtl(text: String, font_size: int, color: Color) -> RichTextLabel:
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	rtl.fit_content = true
	rtl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rtl.add_theme_color_override("default_color", color)
	rtl.add_theme_font_size_override("normal_font_size", font_size)
	rtl.add_theme_font_size_override("bold_font_size", font_size)
	rtl.add_theme_font_size_override("italics_font_size", font_size)
	rtl.add_theme_font_size_override("mono_font_size", font_size)
	rtl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rtl.text = text
	return rtl
