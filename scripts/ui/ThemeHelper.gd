# scripts/ui/ThemeHelper.gd
# ⚠️ 已废弃 — 请直接使用 UITheme 常量
# 保留此文件仅为向后兼容，所有方法委托到 UITheme

extends Node

static func apply_button_style(btn: Button):
	UITheme.apply_button(btn)

static func apply_panel_style(panel: Panel):
	panel.add_theme_stylebox_override("panel", UITheme.panel_style())

static func apply_label_style(label: Label, font_size: int = 16, color: Color = UITheme.PARCHMENT):
	UITheme.apply_label(label, font_size, color)
