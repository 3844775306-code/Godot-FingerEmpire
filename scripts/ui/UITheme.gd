# scripts/ui/UITheme.gd
# ============================================================
# 统一 UI 主题系统 — "羊皮手稿" 中世纪 RTS 风格
#
# 中世纪修道院手稿启发：温润底色、烫金点缀、宝石色油墨
# 所有 UI 文件的唯一样式来源
# ============================================================

class_name UITheme
extends RefCounted

# ── 调色板 ──────────────────────────────────────────────
# 基础色
const PARCHMENT  := Color(0.831, 0.773, 0.663)   # #D4C5A9  文字主色（暖白）
const INK        := Color(0.102, 0.086, 0.078)   # #1A1614  面板背景（暖黑）
const GOLD       := Color(0.788, 0.659, 0.298)   # #C9A84C  边框/强调/重要数字
const VERMILION  := Color(0.753, 0.224, 0.169)   # #C0392B  警报/敌方/HP低
const SAPPHIRE   := Color(0.231, 0.490, 0.847)   # #3B7DD8  友方/HP高/选中
const EMERALD    := Color(0.176, 0.545, 0.306)   # #2D8B4E  资源充足/木材
const STONE      := Color(0.439, 0.439, 0.439)   # #707070  次要文字/禁用
const PURPLE     := Color(0.482, 0.310, 0.749)   # #7B4FBF  升级进度/特殊

# 资源颜色
const RES_GOLD   := Color(1.00, 0.84, 0.10)      # 黄金
const RES_WOOD   := Color(0.25, 0.82, 0.20)      # 木材
const RES_STONE  := Color(0.62, 0.62, 0.62)      # 石头
const RES_FOOD   := Color(1.00, 0.55, 0.10)      # 食物
const RES_OIL    := Color(0.40, 0.25, 0.10)      # 石油
const RES_POP    := Color(0.30, 0.70, 1.00)      # 人口

# 语义色
const HP_HIGH    := Color(0.15, 0.75, 0.15)      # HP > 60%
const HP_MID     := Color(0.85, 0.75, 0.10)      # HP > 30%
const HP_LOW     := Color(0.85, 0.15, 0.10)      # HP <= 30%
const TEAM_RED   := Color.RED
const TEAM_BLUE  := Color.BLUE

# 警报色
const ALERT_DANGER  := Color(1.0, 0.2, 0.1)
const ALERT_WARNING := Color(1.0, 0.8, 0.1)
const ALERT_INFO    := Color(0.2, 1.0, 0.3)
const ALERT_GROUP   := Color(0.3, 0.7, 1.0)

# ── 字号层级 ────────────────────────────────────────────
const FONT_XS   := 12   # 生产队列小标签
const FONT_SM   := 14   # 统计内容、信息面板详情
const FONT_MD   := 16   # 标签正文
const FONT_LG   := 18   # 按钮、资源数值
const FONT_XL   := 20   # 国家标签、面板标题
const FONT_XXL  := 24   # 警报文字

# ── 间距与尺寸 ──────────────────────────────────────────
const RADIUS_SM   := 6    # 小圆角（行按钮）
const RADIUS_MD   := 10   # 中圆角（按钮、内层面板）
const RADIUS_LG   := 14   # 大圆角（主面板）
const BORDER_THIN := 1    # 细边框
const BORDER_MED  := 2    # 标准边框
const BORDER_THICK:= 3    # 强调边框（小地图）

# ── 透明度预设 ──────────────────────────────────────────
const ALPHA_BG      := 0.90   # 面板背景不透明度
const ALPHA_OVERLAY := 0.75   # 浮动层
const ALPHA_BORDER  := 0.50   # 边框半透明
const ALPHA_SUBTLE  := 0.30   # 微妙装饰

# ── 编队颜色 (1-9) ─────────────────────────────────────
const GROUP_COLORS := [
	Color(0.95, 0.20, 0.20),   # 1 红
	Color(0.20, 0.60, 1.00),   # 2 蓝
	Color(0.20, 0.95, 0.30),   # 3 绿
	Color(1.00, 0.90, 0.10),   # 4 黄
	Color(1.00, 0.50, 0.00),   # 5 橙
	Color(0.80, 0.20, 1.00),   # 6 紫
	Color(0.10, 1.00, 1.00),   # 7 青
	Color(1.00, 0.40, 0.70),   # 8 粉
	Color(0.50, 1.00, 0.50),   # 9 薄荷
]

# ── 资源名称映射 ────────────────────────────────────────
const RESOURCE_COLORS := {
	"gold":  RES_GOLD,
	"wood":  RES_WOOD,
	"stone": RES_STONE,
	"food":  RES_FOOD,
	"oil":   RES_OIL,
}

const RESOURCE_NAMES := {
	"gold":  "黄金",
	"wood":  "木材",
	"stone": "石头",
	"food":  "食物",
	"oil":   "石油",
}

# ── 工厂方法 ────────────────────────────────────────────

## 创建统一的面板 StyleBox
static func panel_style(radius: int = RADIUS_LG, border_w: int = BORDER_MED, alpha: float = ALPHA_BG) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(INK, alpha)
	s.corner_radius_top_left = radius
	s.corner_radius_top_right = radius
	s.corner_radius_bottom_left = radius
	s.corner_radius_bottom_right = radius
	s.border_width_left = border_w
	s.border_width_right = border_w
	s.border_width_top = border_w
	s.border_width_bottom = border_w
	s.border_color = Color(GOLD, ALPHA_BORDER)
	return s

## 创建统一按钮 StyleBox 组
static func button_styles(font_size: int = FONT_LG) -> Dictionary:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(INK, ALPHA_OVERLAY)
	normal.set_corner_radius_all(RADIUS_MD)
	normal.border_width_left = BORDER_MED
	normal.border_width_right = BORDER_MED
	normal.border_width_top = BORDER_MED
	normal.border_width_bottom = BORDER_MED
	normal.border_color = Color(GOLD, ALPHA_SUBTLE)
	normal.shadow_size = 4
	normal.shadow_color = Color(0, 0, 0, 0.5)
	normal.shadow_offset = Vector2(2, 2)

	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(INK, 0.85)
	hover.border_color = Color(GOLD, 0.7)

	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(INK)
	pressed.border_color = Color(GOLD)

	return {
		"normal": normal,
		"hover": hover,
		"pressed": pressed,
		"font_size": font_size,
		"font_color": PARCHMENT,
	}

## 将按钮样式应用到按钮
static func apply_button(btn: Button, font_size: int = FONT_LG) -> void:
	var styles := button_styles(font_size)
	btn.add_theme_stylebox_override("normal", styles["normal"])
	btn.add_theme_stylebox_override("hover", styles["hover"])
	btn.add_theme_stylebox_override("pressed", styles["pressed"])
	btn.add_theme_font_size_override("font_size", font_size)
	btn.add_theme_color_override("font_color", PARCHMENT)
	btn.add_theme_color_override("font_hover_color", GOLD)
	btn.add_theme_color_override("font_pressed_color", PARCHMENT)

## 创建标签样式
static func apply_label(label: Label, font_size: int = FONT_MD, color: Color = PARCHMENT) -> void:
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)

## 血条颜色
static func health_bar_color(pct: float) -> Color:
	if pct > 0.6: return HP_HIGH
	if pct > 0.3: return HP_MID
	return HP_LOW

## BBCode 十六进制颜色辅助
static func hex_str(c: Color) -> String:
	return "#%02x%02x%02x" % [
		clampi(int(c.r * 255), 0, 255),
		clampi(int(c.g * 255), 0, 255),
		clampi(int(c.b * 255), 0, 255),
	]
