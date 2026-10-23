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

# 进度条专用色：比主题金色/紫色更亮，避免深色底上发闷
const BUILD_PROGRESS   := Color(0.960, 0.720, 0.280)   # 暖琥珀：建造
const UPGRADE_PROGRESS := Color(0.680, 0.520, 0.960)   # 亮紫罗兰：升级

# 统一进度条样式：暖黑圆角底 + 单色填充 + 顶部高光 + 同色细边
# 用于建造（琥珀）、生产（蓝）、升级（紫罗兰）三种进度
static func style_progress_bar(bar: ProgressBar, color: Color, height: float = 8.0) -> void:
	bar.custom_minimum_size = Vector2(60, height)
	bar.max_value = 1.0
	bar.show_percentage = false
	var fill := StyleBoxFlat.new()
	fill.bg_color = color.lightened(0.06)
	fill.corner_radius_top_left = 4
	fill.corner_radius_top_right = 4
	fill.corner_radius_bottom_left = 4
	fill.corner_radius_bottom_right = 4
	# 顶部 1px 亮边，模拟受光的金属/宝石质感
	fill.border_width_top = 1
	fill.border_color = color.lightened(0.45)
	fill.shadow_color = Color(color, 0.25)
	fill.shadow_size = 1
	bar.add_theme_stylebox_override("fill", fill)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(INK, 0.82)
	bg.corner_radius_top_left = 4
	bg.corner_radius_top_right = 4
	bg.corner_radius_bottom_left = 4
	bg.corner_radius_bottom_right = 4
	bg.set_border_width_all(1)
	bg.border_color = Color(color, 0.45)
	bar.add_theme_stylebox_override("background", bg)

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
	"pop":   RES_POP,
}

const RESOURCE_NAMES := {
	"gold":  "黄金",
	"wood":  "木材",
	"stone": "石头",
	"food":  "食物",
	"oil":   "石油",
	"pop":   "人口",
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

	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(INK, 0.4)
	disabled.border_color = Color(STONE, 0.25)
	disabled.shadow_size = 0

	return {
		"normal": normal,
		"hover": hover,
		"pressed": pressed,
		"disabled": disabled,
		"font_size": font_size,
		"font_color": PARCHMENT,
	}

## 将按钮样式应用到按钮
static func apply_button(btn: Button, font_size: int = FONT_LG) -> void:
	var styles := button_styles(font_size)
	btn.add_theme_stylebox_override("normal", styles["normal"])
	btn.add_theme_stylebox_override("hover", styles["hover"])
	btn.add_theme_stylebox_override("pressed", styles["pressed"])
	btn.add_theme_stylebox_override("disabled", styles["disabled"])
	btn.add_theme_font_size_override("font_size", font_size)
	btn.add_theme_color_override("font_color", PARCHMENT)
	btn.add_theme_color_override("font_disabled_color", Color(STONE).lightened(0.35))
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

# ════════════════════════════════════════════════════════
# 组件工厂 — 三级按钮体系
# ════════════════════════════════════════════════════════
# 主按钮（金）    → 高优先级动作（升级 / 开始 / 确认）
# 危险按钮（朱红）→ 破坏性动作（拆除 / 退出 / 清除）
# 次要按钮（灰）  → 辅助操作
const GOLD_TEXT := Color(0.35, 0.25, 0.08)   # 金色按钮上的深色文字

## 金色主按钮四态样式
static func primary_button_styles(font_size: int = FONT_LG) -> Dictionary:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(GOLD)
	normal.set_corner_radius_all(RADIUS_MD)
	normal.set_border_width_all(BORDER_MED)
	normal.border_color = GOLD.lightened(0.35)
	normal.shadow_size = 4
	normal.shadow_color = Color(0, 0, 0, 0.5)
	normal.shadow_offset = Vector2(2, 2)

	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = GOLD.lightened(0.15)
	hover.border_color = Color.WHITE

	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = GOLD.darkened(0.18)
	pressed.border_color = GOLD.darkened(0.1)

	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(STONE, 0.30)
	disabled.border_color = Color(STONE, 0.20)
	disabled.shadow_size = 0

	return {
		"normal": normal, "hover": hover, "pressed": pressed, "disabled": disabled,
		"font_size": font_size, "font_color": GOLD_TEXT,
	}

## 朱红危险按钮四态样式
static func danger_button_styles(font_size: int = FONT_LG) -> Dictionary:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(VERMILION)
	normal.set_corner_radius_all(RADIUS_MD)
	normal.set_border_width_all(BORDER_MED)
	normal.border_color = VERMILION.lightened(0.4)
	normal.shadow_size = 4
	normal.shadow_color = Color(0, 0, 0, 0.5)
	normal.shadow_offset = Vector2(2, 2)

	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = VERMILION.lightened(0.15)
	hover.border_color = Color.WHITE

	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = VERMILION.darkened(0.2)
	pressed.border_color = VERMILION.darkened(0.1)

	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(STONE, 0.30)
	disabled.border_color = Color(STONE, 0.20)
	disabled.shadow_size = 0

	return {
		"normal": normal, "hover": hover, "pressed": pressed, "disabled": disabled,
		"font_size": font_size, "font_color": PARCHMENT,
	}

## 石板灰次要按钮四态样式
static func muted_button_styles(font_size: int = FONT_MD) -> Dictionary:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(INK, ALPHA_OVERLAY)
	normal.set_corner_radius_all(RADIUS_MD)
	normal.set_border_width_all(BORDER_THIN)
	normal.border_color = Color(STONE, ALPHA_BORDER)

	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(INK, 0.9)
	hover.border_color = Color(PARCHMENT, 0.6)

	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(INK)
	pressed.border_color = Color(PARCHMENT, 0.9)

	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(INK, 0.3)
	disabled.border_color = Color(STONE, 0.15)

	return {
		"normal": normal, "hover": hover, "pressed": pressed, "disabled": disabled,
		"font_size": font_size, "font_color": PARCHMENT,
	}

## 将按钮四态字典应用到任意按钮
static func apply_button_styles(btn: Button, styles: Dictionary) -> void:
	btn.add_theme_stylebox_override("normal", styles["normal"])
	btn.add_theme_stylebox_override("hover", styles["hover"])
	btn.add_theme_stylebox_override("pressed", styles["pressed"])
	btn.add_theme_stylebox_override("disabled", styles["disabled"])
	btn.add_theme_font_size_override("font_size", styles["font_size"])
	btn.add_theme_color_override("font_color", styles["font_color"])
	btn.add_theme_color_override("font_hover_color", styles["font_color"])
	btn.add_theme_color_override("font_pressed_color", styles["font_color"])
	btn.add_theme_color_override("font_disabled_color", Color(STONE).lightened(0.35))

## 金色主按钮（升级 / 开始 / 确认）
static func apply_primary_button(btn: Button, font_size: int = FONT_LG) -> void:
	apply_button_styles(btn, primary_button_styles(font_size))

## 朱红危险按钮（拆除 / 退出）
static func apply_danger_button(btn: Button, font_size: int = FONT_LG) -> void:
	apply_button_styles(btn, danger_button_styles(font_size))

## 石板灰次要按钮（辅助操作）
static func apply_muted_button(btn: Button, font_size: int = FONT_MD) -> void:
	apply_button_styles(btn, muted_button_styles(font_size))

## 列表行按钮四态样式（左侧强调色描边 — 多选统计分组行）
static func row_button_styles(accent: Color, font_size: int = FONT_SM) -> Dictionary:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(INK, 0.85)
	normal.set_corner_radius_all(RADIUS_SM)
	normal.set_border_width_all(BORDER_THIN)
	normal.border_width_left = BORDER_THICK
	normal.border_color = accent

	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(INK)
	hover.border_color = accent.lightened(0.3)

	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(accent.r, accent.g, accent.b, 0.30)
	pressed.border_color = accent.lightened(0.5)

	return {
		"normal": normal, "hover": hover, "pressed": pressed, "disabled": normal,
		"font_size": font_size, "font_color": accent,
	}

## 应用列表行按钮样式（多选统计行）
static func apply_row_button(btn: Button, accent: Color) -> void:
	var s := row_button_styles(accent)
	btn.add_theme_stylebox_override("normal", s["normal"])
	btn.add_theme_stylebox_override("hover", s["hover"])
	btn.add_theme_stylebox_override("pressed", s["pressed"])
	btn.add_theme_stylebox_override("disabled", s["disabled"])
	btn.add_theme_font_size_override("font_size", s["font_size"])
	btn.add_theme_color_override("font_color", s["font_color"])
	btn.add_theme_color_override("font_hover_color", accent.lightened(0.3))
	btn.add_theme_color_override("font_pressed_color", accent.lightened(0.5))
	btn.add_theme_color_override("font_disabled_color", accent)

## 命令卡按钮四态样式（CommandCard 网格 — 石板底 + 金边，禁用态明显变暗）
static func command_button_styles(font_size: int = FONT_XS) -> Dictionary:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(INK, 0.9)
	normal.set_corner_radius_all(RADIUS_SM)
	normal.set_border_width_all(BORDER_THIN)
	normal.border_color = Color(GOLD, 0.35)

	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(INK)
	hover.border_color = Color(GOLD, 0.7)

	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(GOLD, 0.25)
	pressed.border_color = Color(GOLD)

	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(0, 0, 0, 0.35)
	disabled.border_color = Color(STONE, 0.2)

	return {
		"normal": normal, "hover": hover, "pressed": pressed, "disabled": disabled,
		"font_size": font_size, "font_color": PARCHMENT,
	}

## 应用命令卡按钮样式（CommandCard 网格按钮）
static func apply_command_button(btn: Button, font_size: int = FONT_XS) -> void:
	apply_button_styles(btn, command_button_styles(font_size))

## 分区标题（在线菜单 / 主菜单区块标题）
static func make_section_title(text: String, color: Color = GOLD, font_size: int = FONT_XL) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	return l

## 资源筹码样式（黑底 + 资源色描边）
static func chip_style(accent: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0, 0, 0, 0.45)
	s.set_corner_radius_all(14)
	s.set_border_width_all(BORDER_THIN)
	s.border_color = Color(accent, 0.55)
	return s

## 卡片样式（顶部强调色粗描边 — 信息卡）
static func card_style(accent: Color = GOLD) -> StyleBoxFlat:
	# StyleBoxFlat 仅支持统一 border_color（无 per-side 颜色），
	# 用「整体 accent 边框 + 顶部 4px 加粗」实现顶部强调描边效果
	var s := panel_style(RADIUS_MD, BORDER_THIN, 0.85)
	s.border_width_top = BORDER_THICK + 1
	s.border_color = Color(accent, 0.55)
	return s

# ── 图标映射 ─────────────────────────────────────────────
const RESOURCE_ICONS := {
	"gold":  "💰",
	"wood":  "🌲",
	"stone": "⛰️",
	"food":  "🌾",
	"oil":   "🛢️",
	"pop":   "👥",
}

## 实体图标 — 按 id 映射到中世纪羊皮纸风格 emoji
static func entity_emoji(entity_id: int, entity_type: int = -1) -> String:
	match entity_id:
		0: return "💰"   # 金矿
		1: return "🌲"   # 树林
		2: return "⛰️"  # 石矿
		3: return "🌾"   # 农田
		4: return "🛢️"  # 油田
	if entity_type == 1:  # 建筑
		match entity_id:
			20: return "🏰"   # 主城
			21: return "⚔️"  # 兵营
			22: return "📦"   # 仓库
			23: return "⚓"   # 船坞
			24: return "🛠️"  # 攻城车间
			25, 41: return "🏹"  # 箭塔 / 瞭望塔
			26: return "🧨"   # 炮塔
			27: return "🧱"   # 城墙
			28: return "🏠"   # 民居
			29: return "🏭"   # 重装武器厂
			42: return "📜"   # 书院
			52: return "🏛️"  # 议会
			64: return "🛡️"  # 堡垒
			7: return "🌉"    # 桥
			8: return "🪜"    # 梯子
			_: return "🏰"
	match entity_id:
		5, 6: return "🛒"   # 商人
		9: return "⛵"       # 渔船
		10: return "🌾"     # 农民
		11: return "⚔️"    # 步兵
		12: return "🏹"    # 弓箭手
		13: return "🚢"    # 战船
		14: return "🎣"    # 渔民
		15: return "🐎"    # 骑兵
		16: return "🧨"    # 爆破兵
		17: return "🪨"    # 投石车
		18: return "🏗️"   # 工程兵
		19: return "🔎"    # 侦察兵
		30: return "💪"    # 狂战士
		31: return "🏹"    # 长弓兵
		32: return "🐴"    # 法式骑兵
		33: return "🎯"    # 诸葛连弩
		34: return "🐘"    # 象骑兵
		35: return "🔱"    # 长枪兵
		36: return "🛡️"    # 重装步兵
		37: return "🏹"    # 重装弓箭手
		38: return "🏇"    # 重装骑兵
		39: return "🚢"    # 运输船
		40: return "💥"    # 火船
		43, 44, 45, 51: return "🏪"  # 商人
		46: return "📜"    # 县吏
		47: return "🎖️"    # 上校
		48: return "🪶"    # 尚书
		49: return "🚩"    # 统帅
		50: return "🐉"    # 丞相
		_: return "⚔️"

# ── 轻量动效库 ───────────────────────────────────────────
## 淡入（0.3s 二次缓出）— 进场语义
static func fade_in(node: CanvasItem, dur: float = 0.3) -> void:
	node.modulate.a = 0.0
	node.create_tween() \
		.tween_property(node, "modulate:a", 1.0, dur) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

## 悬停微放大（1.04，0.12s）— 可点按反馈
static func hover_scale(btn: Button, amount: float = 1.04, dur: float = 0.12) -> void:
	var base := btn.scale
	btn.mouse_entered.connect(func():
		btn.create_tween() \
			.tween_property(btn, "scale", base * amount, dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	)
	btn.mouse_exited.connect(func():
		btn.create_tween() \
			.tween_property(btn, "scale", base, dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	)

## 呼吸脉冲（循环 1.0 ↔ 1.05）— 主菜单高亮按钮
static func pulse(node: CanvasItem, amount: float = 1.05, dur: float = 0.7) -> void:
	var tw := node.create_tween().set_loops()
	tw.tween_property(node, "scale", Vector2.ONE * amount, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(node, "scale", Vector2.ONE, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
