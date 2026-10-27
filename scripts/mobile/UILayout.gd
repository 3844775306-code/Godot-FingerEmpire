class_name UILayout
extends RefCounted

# 移动端布局换算工具。
# 设计基准沿用 project.godot 的 2400x1400 视口（不改它，保证桌面端零回归），
# 手机端所有尺寸统一用「dp」描述，再换算成设计空间单位。

const DESIGN_W: float = 2400.0
const DESIGN_H: float = 1400.0

# 横屏时 1080p 手机屏高约 393dp，设计空间高 1400 → 1dp ≈ 3.56 单位。
# 竖屏时设计宽度只有 2400（高度被 expand 拉长），如果继续按高度算，
# 整屏 UI 会缩到原来的一半；所以竖屏改成按宽度换算，保证 1dp 的物理大小不变。
const BASE_DP_RATIO: float = 1400.0 / 393.0
const DP_RATIO: float = BASE_DP_RATIO

# 基础安全边距（dp）：无刘海时也留出视觉呼吸
const BASE_MARGIN_DP: float = 12.0

# 当前是否竖屏（设计视口高 > 宽）。旋转窗口/手机方向变化时这里会立即反映新尺寸。
static func is_portrait() -> bool:
	var s := view_size()
	return s.y > s.x

# 竖屏时 view_size 的高度会被 expand 拉长，用它和宽度的比例修正 dp。
# 横屏保持原来的 3.56；竖屏约 6.3，使 1dp 在两种方向下对应的物理像素基本一致。
static func dp_ratio() -> float:
	var s := view_size()
	if s.x <= 0.0 or s.y <= s.x:
		return BASE_DP_RATIO
	return BASE_DP_RATIO * (s.y / s.x)

# dp → 设计空间单位
static func dp(value: float) -> float:
	return value * dp_ratio()

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

# 字号：必须同样走 dp 换算。设计空间是 2400x1400，直接写 13 这种小数字
# 在手机上折合约 3.6dp，肉眼几乎看不清。
static func font_dp(size_dp: float) -> int:
	return maxi(8, int(round(dp(size_dp))))

static func font_body() -> int:
	return font_dp(14.0)

static func font_title() -> int:
	return font_dp(18.0)

static func font_small() -> int:
	return font_dp(11.0)

# 桌面字号 → 手机可读字号。用于复用桌面控件、又不想重写整套布局的界面。
static func mobile_font(base_size: int) -> int:
	if not InputSource.use_mobile_ui():
		return base_size
	if base_size <= 0:
		return base_size
	return font_dp(float(base_size))

# 把一棵「桌面控件树」整体放大到手机可读尺寸。
# 只处理字号、最小尺寸和容器间距，不碰绝对坐标；调用方仍需为面板准备滚动容器。
# 已经用 dp 换算过的控件（字号 > 28）不会被二次放大。
static func scale_widgets_for_mobile(root: Node, recursive: bool = true) -> void:
	if not InputSource.use_mobile_ui() or root == null:
		return
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if recursive:
			for child in node.get_children():
				stack.append(child)
		if not (node is Control):
			continue
		var ctrl := node as Control
		if ctrl.has_meta("mobile_dp_scaled"):
			continue
		if ctrl is Label or ctrl is Button or ctrl is CheckBox or ctrl is LineEdit or ctrl is OptionButton:
			var fs: int = ctrl.get_theme_font_size("font_size")
			if fs > 0 and fs <= 28:
				ctrl.add_theme_font_size_override("font_size", font_dp(float(fs)))
			# 按钮/输入框的图标（复选框勾、下拉箭头）也跟着放大
			if ctrl is Button or ctrl is CheckBox:
				ctrl.add_theme_constant_override("icon_max_width", int(dp(18.0)))
			var ms := ctrl.custom_minimum_size
			var r := dp_ratio()
			ctrl.custom_minimum_size = Vector2(
				ms.x * r if ms.x > 0.0 else 0.0,
				ms.y * r if ms.y > 0.0 else 0.0)
		elif ctrl is RichTextLabel:
			for key in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size", "mono_font_size"]:
				var fs: int = ctrl.get_theme_font_size(key)
				if fs > 0 and fs <= 28:
					ctrl.add_theme_font_size_override(key, font_dp(float(fs)))
		if ctrl is BoxContainer or ctrl is GridContainer or ctrl is ScrollContainer:
			var keys: Array = ["separation"] if ctrl is BoxContainer else ["h_separation", "v_separation"]
			for key in keys:
				var sep: int = ctrl.get_theme_constant(key)
				if sep > 0 and sep <= 28:
					ctrl.add_theme_constant_override(key, int(dp(float(sep))))
		ctrl.set_meta("mobile_dp_scaled", true)

# 手机端 ScrollContainer 不响应转发进来的鼠标拖动（只认触摸拖动与滚轮），
# 统一由这里按触摸位置找到最上层的滚动容器，直接驱动它的滚动值。
static func scroll_at(root_node: Node, pos: Vector2, delta_y: float) -> bool:
	var target: ScrollContainer = null
	target = _find_scroll(root_node, pos, target)
	if target == null:
		return false
	target.scroll_vertical -= int(round(delta_y))
	return true

static func _find_scroll(node: Node, pos: Vector2, best: ScrollContainer) -> ScrollContainer:
	if node is ScrollContainer:
		var sc := node as ScrollContainer
		if sc.is_visible_in_tree() and sc.get_global_rect().has_point(pos):
			best = sc
	for c in node.get_children():
		best = _find_scroll(c, pos, best)
	return best
