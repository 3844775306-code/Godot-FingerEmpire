# scripts/ui/ThemeHelper.gd
extends Node

## 按钮样式：深蓝渐变圆角 + 白色边框
static func apply_button_style(btn: Button):
	var normal = StyleBoxFlat.new()
	normal.bg_color = Color(0.15, 0.35, 0.7)
	normal.border_width_left = 2
	normal.border_width_right = 2
	normal.border_width_top = 2
	normal.border_width_bottom = 2
	normal.border_color = Color(1, 1, 1, 0.4)
	normal.corner_radius_top_left = 12
	normal.corner_radius_top_right = 12
	normal.corner_radius_bottom_left = 12
	normal.corner_radius_bottom_right = 12
	normal.shadow_size = 4
	normal.shadow_color = Color(0, 0, 0, 0.5)
	normal.shadow_offset = Vector2(2, 2)

	var hover = normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.25, 0.45, 0.8)
	hover.border_color = Color.WHITE

	var pressed = normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.1, 0.2, 0.5)
	pressed.border_color = Color(0.8, 0.8, 0.8)

	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", pressed)

	btn.add_theme_font_size_override("font_size", 18)
	btn.add_theme_color_override("font_color", Color.WHITE)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_color_override("font_pressed_color", Color(0.9, 0.9, 0.9))

## 面板背景：半透明深色 + 圆角
static func apply_panel_style(panel: Panel):
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.1, 0.85)
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.border_color = Color(1, 1, 1, 0.3)
	style.corner_radius_top_left = 16
	style.corner_radius_top_right = 16
	style.corner_radius_bottom_left = 16
	style.corner_radius_bottom_right = 16
	panel.add_theme_stylebox_override("panel", style)

## 标签通用设置
static func apply_label_style(label: Label, font_size: int = 16, color: Color = Color.WHITE):
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
