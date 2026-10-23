class_name UILayout
extends RefCounted

# 移动端布局换算工具。
# 设计基准沿用 project.godot 的 2400x1400 视口（不改它，保证桌面端零回归），
# 手机端所有尺寸统一用「dp」描述，再换算成设计空间单位。

const DESIGN_W: float = 2400.0
const DESIGN_H: float = 1400.0

# 1080p 手机屏高约 393dp，设计空间高 1400 → 1dp ≈ 3.56 单位。
# 中端机 720p/20:9 时屏高同为约 360-400dp，该比例基本通用。
const DP_RATIO: float = 1400.0 / 393.0

# 基础安全边距（dp）：无刘海时也留出视觉呼吸
const BASE_MARGIN_DP: float = 12.0

# dp → 设计空间单位
static func dp(value: float) -> float:
	return value * DP_RATIO

# 视口尺寸（设计空间；stretch canvas_items 下即 2400x1400 或按 expand 扩展后的尺寸）
static func view_size() -> Vector2:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return Vector2(DESIGN_W, DESIGN_H)
	return tree.root.get_visible_rect().size

static func scale_factor() -> float:
	var s := view_size()
	return minf(s.x / DESIGN_W, s.y / DESIGN_H)

# 四边安全区（设计空间单位）。返回 Vector4(left, top, right, bottom)。
# 安卓/微信小游戏等带刘海或圆角的设备，用系统安全区换算；桌面直接返回基础边距。
static func safe_insets() -> Vector4:
	var base := dp(BASE_MARGIN_DP)
	var result := Vector4(base, base, base, base)
	if not InputSource.is_touch():
		return result

	var win_pos := DisplayServer.window_get_position()
	var win_size := DisplayServer.window_get_size()
	if win_size.x <= 0 or win_size.y <= 0:
		return result

	var safe := DisplayServer.get_display_safe_area()
	if safe.size.x <= 0 or safe.size.y <= 0:
		return result

	var px_left := maxf(0.0, float(safe.position.x - win_pos.x))
	var px_top := maxf(0.0, float(safe.position.y - win_pos.y))
	var px_right := maxf(0.0, float(win_pos.x + win_size.x - (safe.position.x + safe.size.x)))
	var px_bottom := maxf(0.0, float(win_pos.y + win_size.y - (safe.position.y + safe.size.y)))

	# 物理像素 → 设计空间
	var s := view_size()
	var kx := s.x / float(win_size.x)
	var ky := s.y / float(win_size.y)

	result.x = maxf(base, px_left * kx)
	result.y = maxf(base, px_top * ky)
	result.z = maxf(base, px_right * kx)
	result.w = maxf(base, px_bottom * ky)
	return result

# 按锚点设置 Control 的四边偏移（相对锚定边）。
# anchor_x: 0=左 1=右；anchor_y: 0=上 1=下
static func place(ctrl: Control, anchor_x: float, anchor_y: float,
		left: float, top: float, right: float, bottom: float) -> void:
	ctrl.anchor_left = anchor_x
	ctrl.anchor_right = anchor_x
	ctrl.anchor_top = anchor_y
	ctrl.anchor_bottom = anchor_y
	ctrl.offset_left = left
	ctrl.offset_top = top
	ctrl.offset_right = right
	ctrl.offset_bottom = bottom
	ctrl.grow_horizontal = Control.GROW_DIRECTION_BEGIN if anchor_x >= 1.0 else Control.GROW_DIRECTION_END
	ctrl.grow_vertical = Control.GROW_DIRECTION_BEGIN if anchor_y >= 1.0 else Control.GROW_DIRECTION_END

# 把一个 Control 贴到视口某一角/边的矩形（用 dp 描述宽高与边距）
# corner: "tl" 左上, "tr" 右上, "bl" 左下, "br" 右下, "bottom" 底部居中
static func place_dp(ctrl: Control, corner: String, width_dp: float, height_dp: float,
		margin_dp: float = BASE_MARGIN_DP) -> void:
	var insets := safe_insets()
	var w := dp(width_dp)
	var h := dp(height_dp)
	var mx := dp(margin_dp)
	var left_m := insets.x + mx
	var top_m := insets.y + mx
	var right_m := insets.z + mx
	var bottom_m := insets.w + mx
	match corner:
		"tl":
			place(ctrl, 0.0, 0.0, left_m, top_m, left_m + w, top_m + h)
		"tr":
			place(ctrl, 1.0, 0.0, -right_m - w, top_m, -right_m, top_m + h)
		"bl":
			place(ctrl, 0.0, 1.0, left_m, -bottom_m - h, left_m + w, -bottom_m)
		"br":
			place(ctrl, 1.0, 1.0, -right_m - w, -bottom_m - h, -right_m, -bottom_m)
		"bottom":
			ctrl.anchor_left = 0.5
			ctrl.anchor_right = 0.5
			ctrl.anchor_top = 1.0
			ctrl.anchor_bottom = 1.0
			ctrl.offset_left = -w * 0.5
			ctrl.offset_right = w * 0.5
			ctrl.offset_top = -bottom_m - h
			ctrl.offset_bottom = -bottom_m
			ctrl.grow_horizontal = Control.GROW_DIRECTION_BOTH
			ctrl.grow_vertical = Control.GROW_DIRECTION_BEGIN

# 按钮最小触控热区（dp）：低于 44 不可靠，统一 48
static func touch_min() -> Vector2:
	return Vector2(dp(48), dp(48))

static func font_body() -> int:
	return 16

static func font_title() -> int:
	return 20

static func font_small() -> int:
	return 14
