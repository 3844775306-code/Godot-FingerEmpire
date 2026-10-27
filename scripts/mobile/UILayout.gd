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

# ==================== 顶部带布局 ====================
# 资源胶囊、顶部指令栏、顶部信息栏、小地图四类元素共用屏幕顶部一条横带。
# 统一在这里算矩形，各端只负责套用，避免每个 HUD 各写一套坐标导致互相压住。
const TOP_MARGIN: float = 10.0          # 桌面顶部带外边距（设计空间）
const TOP_CMD_W: float = 662.0          # 桌面指令底板宽（3 列 × 210 + 间距 + 内边距）
const TOP_CMD_H: float = 82.0           # 桌面指令底板高（6 键 3×2）
const TOP_CMD_RESEARCH_H: float = 120.0 # 科研模式下多一行整宽科研树按钮
# 科研模式下指令底板加高；HUD/ClientHUD 构建指令栏前按当局模式设置一次。
static var cmd_research_row: bool = false

static func top_cmd_h() -> float:
	return TOP_CMD_RESEARCH_H if cmd_research_row else TOP_CMD_H
const TOP_CAPSULE_MIN_W: float = 580.0  # 桌面资源胶囊最小宽
const TOP_CAPSULE_H: float = 52.0
const TOP_MINIMAP: float = 400.0        # 桌面小地图边长
const TOP_INFO_W: float = 680.0         # 顶部信息栏宽（两行：性能 / 对局网络，联机长句不省略）
const TOP_INFO_H: float = 92.0
const TOP_ALERT_W: float = 820.0        # 战况栏宽
const MOBILE_CAPSULE_W_DP: float = 344.0
const MOBILE_MINIMAP_DP: float = 154.0          # 手机横屏小地图
const MOBILE_MINIMAP_PORTRAIT_DP: float = 100.0 # 手机竖屏小地图
# 手机顶部信息栏只留两行：性能（FPS/画质）和对局信息（AI/地图/时间）。
# 实体数量、A* 寻路统计已经移出这里，腾出来的高度留给战场。
const MOBILE_INFO_LINE_DP: float = 18.0
const MOBILE_INFO_LINES: int = 2
const MOBILE_INFO_H_DP: float = MOBILE_INFO_LINE_DP * float(MOBILE_INFO_LINES)

# 桌面顶部指令底板：略偏右，给资源胶囊右侧的单行信息让出宽度；
# 窄屏用右侧小地图反向夹住，避免压到小地图。
const TOP_CMD_SHIFT_RIGHT: float = 220.0
static func top_cmd_rect(vp: Vector2) -> Rect2:
	var base_x := (vp.x - TOP_CMD_W) * 0.5
	var mm := top_minimap_rect(vp)
	var max_x := mm.position.x - 12.0 - TOP_CMD_W
	var x := clampf(base_x + TOP_CMD_SHIFT_RIGHT, TOP_MARGIN, maxf(TOP_MARGIN, max_x))
	return Rect2(Vector2(x, TOP_MARGIN), Vector2(TOP_CMD_W, top_cmd_h()))

# 桌面小地图：贴右上角，与顶部带同一条高度
static func top_minimap_rect(vp: Vector2) -> Rect2:
	return Rect2(Vector2(vp.x - TOP_MARGIN - TOP_MINIMAP, TOP_MARGIN), Vector2(TOP_MINIMAP, TOP_MINIMAP))

# 桌面资源胶囊：贴左上角，宽度由内容自适应（不窄于 TOP_CAPSULE_MIN_W）。
# 桌面指令底板水平居中，胶囊再长也不能压上去：右边缘最多到指令底板左侧 10 单位。
static func top_capsule_rect(vp: Vector2, width: float) -> Rect2:
	var w := maxf(width, TOP_CAPSULE_MIN_W)
	w = minf(w, maxf(TOP_CAPSULE_MIN_W, vp.x - TOP_MARGIN * 2.0))
	var cmd := top_cmd_rect(vp)
	var max_w := cmd.position.x - TOP_MARGIN - 10.0
	if max_w >= TOP_CAPSULE_MIN_W:
		w = minf(w, max_w)
	return Rect2(Vector2(TOP_MARGIN, TOP_MARGIN), Vector2(w, TOP_CAPSULE_H))

# 桌面战况栏：指令底板正下方居中；若顶部信息栏也被挤到指令栏下方，
# 战况栏再往下让一行，保证两者不叠在一起。
# extra_bottom：单机顶部信息面板（DiagBG）的底边，面板落在指令栏下方时战况栏继续下移。
static func top_alert_rect(vp: Vector2, extra_bottom: float = 0.0) -> Rect2:
	var cmd := top_cmd_rect(vp)
	var info := top_info_rect(vp)
	var y := cmd.position.y + cmd.size.y + 10.0
	if info.position.y > cmd.position.y + 1.0:
		y = maxf(y, info.position.y + info.size.y + 8.0)
	if extra_bottom > 0.0:
		y = maxf(y, extra_bottom + 8.0)
	return Rect2(Vector2((vp.x - TOP_ALERT_W) * 0.5, y), Vector2(TOP_ALERT_W, 0.0))

# 单机桌面顶部信息面板：指令栏与小地图之间有空档就塞进空档右对齐，
# 塞不下就落到指令底板正下方居中（宽 1040，两行 44 高，不再压住指令按钮）。
static func top_diag_rect(vp: Vector2, width: float = 1040.0, line_h: float = 44.0) -> Rect2:
	var cmd := top_cmd_rect(vp)
	var mm := top_minimap_rect(vp)
	var gap_left := cmd.position.x + cmd.size.x + 12.0
	var gap_right := mm.position.x - 12.0
	var h := line_h * 2.0 + 8.0
	if gap_right - gap_left >= width:
		return Rect2(Vector2(gap_right - width, TOP_MARGIN), Vector2(width, h))
	return Rect2(Vector2((vp.x - width) * 0.5, cmd.position.y + cmd.size.y + 8.0), Vector2(width, h))

# 桌面顶部信息栏：指令栏与小地图之间有空档就塞进空档右对齐，
# 塞不下（窄屏 / 4:3）就落到指令底板正下方居中，保证不压资源胶囊与小地图。
static func top_info_rect(vp: Vector2) -> Rect2:
	var cmd := top_cmd_rect(vp)
	var mm := top_minimap_rect(vp)
	var gap_left := cmd.position.x + cmd.size.x + 12.0
	var gap_right := mm.position.x - 12.0
	if gap_right - gap_left >= TOP_INFO_W:
		return Rect2(Vector2(gap_right - TOP_INFO_W, TOP_MARGIN), Vector2(TOP_INFO_W, TOP_INFO_H))
	var below := TOP_MARGIN + top_cmd_h() + 8.0
	var max_x := maxf(TOP_MARGIN, vp.x - TOP_MARGIN - TOP_INFO_W)
	return Rect2(Vector2(clampf((vp.x - TOP_INFO_W) * 0.5, TOP_MARGIN, max_x), below), Vector2(TOP_INFO_W, TOP_INFO_H))

# 桌面单行顶部信息：资源胶囊右侧到指令底板左侧之间的空档。
# 胶囊变宽（资源数值变长）后空档会被挤窄，调用方按返回宽度再压字号。
const TOP_INFO_1LINE_H: float = 48.0
static func top_info_right_rect(vp: Vector2, capsule_right: float, h: float = TOP_INFO_1LINE_H) -> Rect2:
	var cmd := top_cmd_rect(vp)
	var left := capsule_right + 10.0
	var right := cmd.position.x - 12.0
	if right - left < 140.0:
		return Rect2()
	return Rect2(Vector2(left, TOP_MARGIN), Vector2(right - left, h))

# 手机横屏单行顶部信息：资源胶囊右侧到小地图左侧；竖屏不用这个函数（竖屏保持胶囊下方多行）。
static func mobile_info_right_rect(capsule_rect: Rect2, h_dp: float = 22.0) -> Rect2:
	var mm := mobile_minimap_rect(capsule_rect)
	var left := capsule_rect.position.x + capsule_rect.size.x + dp(8.0)
	var right := mm.position.x - dp(8.0)
	if right - left < dp(90.0):
		return Rect2()
	var h := dp(h_dp)
	var top := capsule_rect.position.y + (capsule_rect.size.y - h) * 0.5
	return Rect2(Vector2(left, top), Vector2(right - left, h))

# 手机资源胶囊实际宽度（dp）：标准 9:16 竖屏用满 344dp；
# 20:9 等高瘦屏竖屏逻辑宽度只有约 300dp，胶囊必须收窄，否则会被屏幕右边缘裁掉。
static func mobile_capsule_width_dp() -> float:
	var insets := safe_insets()
	var avail := view_size().x - insets.x - insets.z - dp(4.0)
	return clampf(avail / maxf(dp_ratio(), 0.001), 240.0, MOBILE_CAPSULE_W_DP)

# 手机小地图：横屏贴右上（与胶囊同高）；竖屏放到资源胶囊正下方右侧，
# 与顶部信息栏同一行（信息栏在左，小地图在右），因为竖屏胶囊几乎占满整行宽度。
static func mobile_minimap_rect(capsule_rect: Rect2) -> Rect2:
	var vp := view_size()
	var insets := safe_insets()
	if is_portrait():
		var side := dp(MOBILE_MINIMAP_PORTRAIT_DP)
		var right := insets.z + dp(6.0)
		var top := capsule_rect.position.y + capsule_rect.size.y + dp(4.0)
		return Rect2(Vector2(vp.x - right - side, top), Vector2(side, side))
	var side_l := dp(MOBILE_MINIMAP_DP)
	var right_l := insets.z + dp(6.0)
	return Rect2(Vector2(vp.x - right_l - side_l, insets.y + dp(2.0)), Vector2(side_l, side_l))

# 手机顶部信息栏：横屏时夹在资源胶囊与小地图之间；竖屏放到资源胶囊正下方，
# 左边一直延伸到小地图左侧。单机默认 2 行；联机信息多，可以传 lines=3。
static func mobile_top_info_rect(capsule_rect: Rect2, lines: int = MOBILE_INFO_LINES) -> Rect2:
	var insets := safe_insets()
	var mm := mobile_minimap_rect(capsule_rect)
	var h := dp(MOBILE_INFO_LINE_DP * float(maxi(lines, 1)))
	if is_portrait():
		var left := insets.x + dp(2.0)
		var right := mm.position.x - dp(6.0)
		var w := maxf(right - left, dp(140.0))
		var top := capsule_rect.position.y + capsule_rect.size.y + dp(4.0)
		return Rect2(Vector2(left, top), Vector2(w, h))
	var left_l := capsule_rect.position.x + capsule_rect.size.x + dp(8.0)
	var right_l := mm.position.x - dp(8.0)
	if right_l - left_l < dp(120.0):
		return Rect2()
	return Rect2(Vector2(left_l, insets.y + dp(4.0)), Vector2(right_l - left_l, h))

# 手机战况栏：竖屏让开胶囊下方的信息栏和小地图，横屏放在信息栏下方居中。
# info_lines：调用方信息栏实际行数（联机 3 行时传 3，避免战况栏压住信息文字）。
static func mobile_alert_rect(capsule_rect: Rect2 = Rect2(), info_lines: int = MOBILE_INFO_LINES) -> Rect2:
	var vp := view_size()
	var w := dp(300.0 if is_portrait() else 310.0)
	# 竖屏小地图 100dp 高，战况栏必须在小地图底边之下（166dp）；
	# 横屏战况栏与右上小地图左右错开，可以直接贴信息栏下方（58dp）。
	var base_y := dp(166.0) if is_portrait() else dp(58.0)
	var top_y := base_y
	if capsule_rect.size.x > 0.0:
		var info := mobile_top_info_rect(capsule_rect, info_lines)
		top_y = maxf(top_y, info.position.y + info.size.y + dp(6.0))
	return Rect2(Vector2((vp.x - w) * 0.5, top_y), Vector2(w, 0.0))

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
