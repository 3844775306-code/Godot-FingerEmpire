extends Control

const MapPresets = preload("res://scripts/map/MapPresets.gd")
const MapSelectDialog = preload("res://scripts/ui/MapSelectDialog.gd")
const AppVersion = preload("res://scripts/core/AppVersion.gd")
const ChangelogData = preload("res://scripts/data/ChangelogData.gd")
const ChangelogPanel = preload("res://scripts/ui/ChangelogPanel.gd")
const GuidePanel = preload("res://scripts/ui/GuidePanel.gd")
const UpdateConfig = preload("res://scripts/core/UpdateConfig.gd")
const UpdateChecker = preload("res://scripts/core/UpdateChecker.gd")

var nation_select: OptionButton
var _map_button: Button = null
# 带 NEW 未读标记的更新日志按钮（打开日志后清掉标记）
var _changelog_btn: Button = null
# 更新检查（有新版时底部弹出下载按钮）
var _update_checker: UpdateChecker = null
var _update_banner: Button = null
# 手机端滚动列表：有新版时把下载按钮插到最上面
var _mobile_vb: VBoxContainer = null

# 主菜单场景没有战斗内的 TouchGestureRouter：触摸拖动直接驱动 ScrollContainer 滚动
# （手机点击仍由引擎模拟鼠标完成，这里只管滑动）。
func _input(event: InputEvent) -> void:
	if not InputSource.use_mobile_ui():
		return
	if event is InputEventScreenDrag:
		UILayout.scroll_at(self, event.position, event.relative.y)

func _ready():
	AudioManager.play_music("menu")
	# Scale to fit screen (design: 2400x1400)
	var vs = get_viewport().get_visible_rect().size
	var s = min(vs.x / 2400.0, vs.y / 1400.0)
	scale = Vector2(s, s)
	position = (vs - Vector2(2400, 1400) * s) / 2.0
	# 手机端：桌面绝对布局在 674×393dp 的屏幕上字只有 5~7dp，改用竖排滚动布局
	if InputSource.use_mobile_ui():
		# 手机布局直接铺满「展开后的设计视口」：竖屏时视口会变成 2400×4267，
		# 如果仍按 2400×1400 居中缩放，菜单只会占屏幕中间一条，上下全是黑的。
		scale = Vector2.ONE
		position = Vector2.ZERO
		# 锚点铺满：即使 Web 首帧稍后才把视口从 2400×1400 扩成竖屏高度，根节点也会跟着长高。
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		size = UILayout.view_size()
		# 横竖屏切换后重建菜单：所有 dp 尺寸和滚动区高度都要按新方向重算。
		add_child(OrientationReload.new())
		# 场景里那套桌面节点必须一起隐藏，否则会和下面的竖排布局重叠，变成"两层 UI"
		var old_box = get_node_or_null("VBoxContainer")
		if old_box: old_box.visible = false
		_build_mobile_layout()
		_setup_update_check()
		return
	# 隐藏旧的场景节点，全部用代码重建
	var old_box = get_node_or_null("VBoxContainer")
	if old_box: old_box.visible = false

	# 全屏暖黑背景（羊皮纸皇庭底色）
	var bg = ColorRect.new()
	bg.color = Color(0.10, 0.08, 0.06)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	move_child(bg, 0)

	# 顶部皇庭金饰横条
	var top_bar = ColorRect.new()
	top_bar.color = Color(UITheme.GOLD)
	top_bar.position = Vector2(0, 0)
	top_bar.size = Vector2(2400, 6)
	add_child(top_bar)
	var top_bar2 = ColorRect.new()
	top_bar2.color = Color(UITheme.GOLD, 0.35)
	top_bar2.position = Vector2(0, 6)
	top_bar2.size = Vector2(2400, 3)
	add_child(top_bar2)

	var center_y = 350  # 整体上移

	# 主标题（皇庭金徽章）
	var title = Label.new()
	title.text = "👑 FINGER EMPIRE 👑"
	title.position = Vector2(0, center_y - 300)
	title.size = Vector2(2400, 90)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 96)
	title.add_theme_color_override("font_color", UITheme.GOLD.lightened(0.15))
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 3)
	title.add_theme_constant_override("shadow_size", 10)
	add_child(title)

	# 标题下方金色装饰线
	var gold_line = ColorRect.new()
	gold_line.color = Color(UITheme.GOLD, 0.7)
	gold_line.position = Vector2(860, center_y - 196)
	gold_line.size = Vector2(680, 3)
	add_child(gold_line)

	# 副标题
	var subtitle = Label.new()
	subtitle.text = "即时战略 · 帝国纷争"
	subtitle.position = Vector2(0, center_y - 185)
	subtitle.size = Vector2(2400, 40)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(subtitle, 34, UITheme.PARCHMENT)
	add_child(subtitle)

	# 中央皇庭面板：主按钮 6 个 + 底部「操作指南 / 新手教程」双按钮，
	# 面板加高到 850（205..1055），底部提示面板随之下移，避免帮助入口压住提示。
	var panel = Panel.new()
	panel.position = Vector2(620, 205)
	panel.size = Vector2(1160, 850)
	panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	add_child(panel)

	# 面板内分区标题
	var section = UITheme.make_section_title("⚔️ 战役配置 ⚔️", UITheme.GOLD, 28)
	section.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	section.position = Vector2(620, 218)
	section.size = Vector2(1160, 36)
	add_child(section)

	# 国家选择区
	var nation_label = Label.new()
	nation_label.text = "选择国家"
	nation_label.position = Vector2(620, 262)
	nation_label.size = Vector2(1160, 30)
	nation_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(nation_label, 24, UITheme.PARCHMENT)
	add_child(nation_label)

	nation_select = OptionButton.new()
	nation_select.add_item("  维京    +25%生命  +10%速度")
	nation_select.add_item("  英格兰  +15%攻击  +20%视野  采木+10%")
	nation_select.add_item("  法兰西  +25护甲  城堡2级起始")
	nation_select.add_item("  中国    食物+20%  黄金+10%  人口+10")
	nation_select.add_item("  匈牙利  +15护甲  石材+15%  黄金+10%  人口+5")
	nation_select.add_item("  日本    +15%攻速  +10%攻击")
	nation_select.add_item("  拜占庭  +2双护甲  黄金+10%")
	nation_select.add_item("  蒙古    速度+20%  攻速+10%  视野+20%")
	nation_select.add_item("  波斯    生命+15%  盾甲+1  黄金+15%  人口+5")
	nation_select.add_item("  西班牙  攻击+10%  铠甲+1  黄金+15%")
	nation_select.position = Vector2(750, 296)
	nation_select.size = Vector2(900, 50)
	_style_option(nation_select, 20)
	add_child(nation_select)

	# AI难度选择
	var diff_label = Label.new()
	diff_label.text = "AI难度"
	diff_label.position = Vector2(700, 366)
	diff_label.size = Vector2(200, 30)
	diff_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	UITheme.apply_label(diff_label, 20, UITheme.PARCHMENT)
	add_child(diff_label)
	var diff_select = OptionButton.new()
	diff_select.name = "DiffSelect"
	diff_select.add_item("  简单")
	diff_select.add_item("  普通（AI资源×2）")
	diff_select.add_item("  困难（AI资源×3+额外资源）")
	diff_select.add_item("  地狱（困难+速度+20%）")
	diff_select.position = Vector2(910, 364)
	diff_select.size = Vector2(740, 46)
	_style_option(diff_select, 16)
	add_child(diff_select)

	# 游戏模式选择（1V1 / 2V2 / 3V3 对称团队战 / 乱斗3-5国）
	var mode_label = Label.new()
	mode_label.text = "游戏模式"
	mode_label.position = Vector2(700, 428)
	mode_label.size = Vector2(200, 30)
	mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	UITheme.apply_label(mode_label, 20, UITheme.PARCHMENT)
	add_child(mode_label)
	var mode_select = OptionButton.new()
	mode_select.name = "ModeSelect"
	mode_select.add_item("  1V1")
	mode_select.add_item("  2V2")
	mode_select.add_item("  3V3")
	mode_select.add_item("  乱斗·3国")
	mode_select.add_item("  乱斗·4国")
	mode_select.add_item("  乱斗·5国")
	mode_select.selected = 0   # 默认 1V1
	mode_select.position = Vector2(910, 426)
	mode_select.size = Vector2(740, 46)
	_style_option(mode_select, 16)
	add_child(mode_select)

	# 战场地形：所有模式（含乱斗）都可以选择特殊地图
	var map_label = Label.new()
	map_label.text = "战场地形"
	map_label.position = Vector2(700, 488)
	map_label.size = Vector2(200, 30)
	map_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	UITheme.apply_label(map_label, 20, UITheme.PARCHMENT)
	add_child(map_label)

	var map_btn = Button.new()
	map_btn.name = "MapButton"
	map_btn.position = Vector2(910, 486)
	map_btn.size = Vector2(420, 40)
	UITheme.apply_muted_button(map_btn, 16)
	map_btn.pressed.connect(_open_map_dialog)
	add_child(map_btn)
	_map_button = map_btn
	_refresh_map_button()
	mode_select.item_selected.connect(_update_map_availability)
	_update_map_availability(mode_select.selected)

	# 快速模式
	var fast_check = CheckBox.new()
	fast_check.name = "FastCheck"
	fast_check.text = "快速模式（采集×3）"
	fast_check.position = Vector2(1360, 492)
	fast_check.add_theme_font_size_override("font_size", 18)
	fast_check.add_theme_color_override("font_color", UITheme.PARCHMENT)
	fast_check.add_theme_color_override("font_hover_color", UITheme.GOLD)
	fast_check.add_theme_color_override("icon_normal_color", UITheme.GOLD)
	fast_check.add_theme_color_override("icon_hover_color", UITheme.GOLD.lightened(0.2))
	add_child(fast_check)

	# 发展模式：经典（原主城升级） / 科研（四时代科技树）
	var research_check = CheckBox.new()
	research_check.name = "ResearchCheck"
	research_check.text = "科研模式（四时代·科技树）"
	research_check.position = Vector2(150, 620)
	research_check.add_theme_font_size_override("font_size", 18)
	research_check.add_theme_color_override("font_color", UITheme.PARCHMENT)
	research_check.add_theme_color_override("font_hover_color", UITheme.GOLD)
	research_check.add_theme_color_override("icon_normal_color", UITheme.GOLD)
	research_check.tooltip_text = "关闭为经典模式（原升级模式）；开启后通过时代与科技树解锁建筑/单位。新手教程与战役固定使用经典模式。"
	add_child(research_check)
	research_check.toggled.connect(func(on): GameSettings.progression_mode = GameSettings.ProgressionMode.RESEARCH if on else GameSettings.ProgressionMode.CLASSIC)

	# 按钮（金主 CTA / 蓝书图鉴 / 石次 / 朱红危险）
	# 6 个主按钮行距 64、高度 58，最后一个「退出游戏」下沿 924；
	# 下方 970~1022 放「操作指南 / 新手教程」双按钮，整体仍在 205..1055 的面板内。
	var btn_data = [
		["单人游戏", Vector2(900, center_y + 196), _on_play_pressed, "primary"],
		["联机对战", Vector2(900, center_y + 260), _on_multiplayer_pressed, "primary"],
		["📖 单位图鉴", Vector2(900, center_y + 324), _on_units_pressed, "book"],
		["设  置", Vector2(900, center_y + 388), _on_settings_pressed, "muted"],
		["📜 更新日志", Vector2(900, center_y + 452), _on_changelog_pressed, "muted"],
		["退出游戏", Vector2(900, center_y + 516), _on_quit_pressed, "danger"],
	]

	for data in btn_data:
		var btn = _make_menu_button(data[0], data[1], data[3])
		btn.pressed.connect(data[2])
		add_child(btn)
		if data[3] == "primary" and data[0] == "单人游戏":
			UITheme.pulse(btn, 1.03, 0.9)   # 主 CTA 呼吸高亮
		else:
			UITheme.hover_scale(btn)
		if data[0] == "📜 更新日志":
			_changelog_btn = btn
			_attach_new_badge(btn, UITheme.FONT_SM)

	# 帮助入口：操作指南（蓝书）+ 新手教程（金色 CTA），并排放在主按钮下方。
	var guide_btn := _make_menu_button("📘 操作指南", Vector2(660, center_y + 620), "book")
	guide_btn.size = Vector2(340, 52)
	guide_btn.pressed.connect(_on_guide_pressed)
	add_child(guide_btn)
	UITheme.hover_scale(guide_btn)

	var tutorial_btn := _make_menu_button("🎓 新手教程", Vector2(1030, center_y + 620), "primary")
	tutorial_btn.size = Vector2(340, 52)
	tutorial_btn.pressed.connect(_on_tutorial_pressed)
	add_child(tutorial_btn)
	UITheme.hover_scale(tutorial_btn)

	# 闯关模式（战役）：固定地图 + 任务目标，独立的选关界面
	var campaign_btn := _make_menu_button("⚔ 战役闯关", Vector2(1400, center_y + 620), "primary")
	campaign_btn.size = Vector2(340, 52)
	campaign_btn.pressed.connect(_on_campaign_pressed)
	add_child(campaign_btn)
	UITheme.hover_scale(campaign_btn)

	# 菜单底部再写一行当前版本，玩家不进日志也能看到
	var version_hint := Label.new()
	version_hint.text = AppVersion.display()
	version_hint.position = Vector2(900, center_y + 582)
	version_hint.size = Vector2(600, 24)
	version_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	version_hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	version_hint.add_theme_color_override("font_color", Color(UITheme.STONE.lightened(0.35)))
	add_child(version_hint)

	# 中央面板淡入
	UITheme.fade_in(panel, 0.4)

	# 底部提示面板：操作说明跟着版本走（鼠标 / 键盘 / 本版贴士 / 国家加成）
	var bot_panel = Panel.new()
	bot_panel.position = Vector2(300, 1075)
	bot_panel.size = Vector2(1800, 230)
	bot_panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	add_child(bot_panel)
	UITheme.fade_in(bot_panel, 0.5)

	var tip_box = VBoxContainer.new()
	tip_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tip_box.offset_left = 30
	tip_box.offset_right = -30
	tip_box.offset_top = 14
	tip_box.offset_bottom = -14
	tip_box.add_theme_constant_override("separation", 8)
	tip_box.alignment = BoxContainer.ALIGNMENT_CENTER
	bot_panel.add_child(tip_box)

	_add_tip_line(tip_box, "🖱️ 鼠标：左键 选择·框选·移动·攻击·采集 · 右键空地 建造菜单（有选中也不清空） · 选中建筑左键空地 取消选中 · 中键拖拽平移 · Ctrl+中键拖拽旋转视角 · 滚轮缩放 · 新手先看 📘 操作指南 / 🎓 新手教程",
		16, UITheme.PARCHMENT)
	_add_tip_line(tip_box, "⌨️ 键盘：A+左键 攻击 · M+左键 纯移动 · Esc 取消 · Ctrl+1~9 编队 · F1 全选军队 · F2 自动进攻 · F3 撤退 · Alt+左键 设驻扎点 · Ctrl+Alt+左键 清除驻扎点",
		16, UITheme.PARCHMENT)
	_add_tip_line(tip_box, "✨ 本版 %s：设置里可调「相机放大倍数」· 选中单位改为贴边发光描边 · 建筑血条按阵营上色 · 手机端「↻ 按住旋转」· 点「📜 更新日志」看全部改动" % AppVersion.version(),
		15, Color(UITheme.GOLD, 0.95))
	_add_tip_line(tip_box, "国家加成：维京 +25%HP +10%速 · 英格兰 +15%攻 +20%视野 · 法兰西 +25护甲 城堡2级 · 中国 食物+20% 金+10% 人口+10 · 匈牙利 +15护甲 石+15% 金+10% · 日本 +15%攻速 +10%攻 · 拜占庭 +2护甲 金+10% · 蒙古 速度+20% 攻速+10% 视野+20% · 波斯 生命+15% 盾甲+1 金+15% 人口+5 · 西班牙 攻击+10% 铠甲+1 金+15%",
		14, Color(UITheme.STONE).lightened(0.3))

	# 底部版本号
	var version = Label.new()
	version.text = "%s - Godot 4.7" % AppVersion.display()
	version.position = Vector2(0, 1340)
	version.size = Vector2(2400, 30)
	version.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(version, 18, Color(UITheme.STONE).lightened(0.2))
	add_child(version)
	UITheme.fade_in(version, 0.6)

	# 联网检查有没有新版本（有就底部弹出下载按钮，没网静默跳过）
	_setup_update_check()

## 主题化 OptionButton（含弹出列表）
func _style_option(o: OptionButton, font_size: int) -> void:
	o.add_theme_font_size_override("font_size", font_size)
	o.add_theme_color_override("font_color", UITheme.PARCHMENT)
	o.add_theme_color_override("font_hover_color", UITheme.GOLD)
	var pop = o.get_popup()
	pop.add_theme_font_size_override("font_size", font_size)
	pop.add_theme_color_override("font_color", UITheme.PARCHMENT)
	pop.add_theme_color_override("font_hover_color", UITheme.GOLD)

## 菜单按钮（金主 / 蓝书图鉴 / 石次 / 朱红危险）
func _make_menu_button(text: String, pos: Vector2, kind: String) -> Button:
	var btn = Button.new()
	btn.text = text
	btn.position = pos
	btn.size = Vector2(600, 58)
	match kind:
		"primary": UITheme.apply_primary_button(btn, UITheme.FONT_XXL)
		"danger": UITheme.apply_danger_button(btn, UITheme.FONT_XXL)
		"book":
			# 图鉴专用「宝石蓝」书页风格，与金色 CTA 区分
			var sb = StyleBoxFlat.new()
			sb.bg_color = Color(UITheme.SAPPHIRE, 0.16)
			sb.border_color = Color(UITheme.SAPPHIRE, 0.95)
			sb.set_corner_radius_all(10)
			sb.set_border_width_all(2)
			sb.set_content_margin_all(6)
			btn.add_theme_stylebox_override("normal", sb)
			var hover = sb.duplicate()
			hover.bg_color = Color(UITheme.SAPPHIRE, 0.30)
			btn.add_theme_stylebox_override("hover", hover)
			var pressed = hover.duplicate()
			pressed.bg_color = Color(UITheme.SAPPHIRE, 0.44)
			btn.add_theme_stylebox_override("pressed", pressed)
			var focus = StyleBoxEmpty.new()
			btn.add_theme_stylebox_override("focus", focus)
			btn.add_theme_font_size_override("font_size", UITheme.FONT_XXL)
			btn.add_theme_color_override("font_color", UITheme.PARCHMENT)
			btn.add_theme_color_override("font_hover_color", Color(UITheme.GOLD, 1.0))
			btn.add_theme_color_override("font_pressed_color", UITheme.GOLD.lightened(0.2))
		_: UITheme.apply_muted_button(btn, UITheme.FONT_XXL)
	return btn

## 命令模式分段切换样式
func _set_cmd_toggle(btn: Button, on: bool) -> void:
	if on:
		UITheme.apply_primary_button(btn, UITheme.FONT_SM)
	else:
		UITheme.apply_muted_button(btn, UITheme.FONT_SM)

## 地图选择对所有模式开放；乱斗同样可以选特殊地形，只是城堡布局仍按环形展开
func _update_map_availability(_mode_idx: int) -> void:
	if not _map_button:
		return
	_map_button.disabled = false
	_refresh_map_button()

func _refresh_map_button() -> void:
	if not _map_button:
		return
	var info := MapPresets.get_info(GameSettings.map_id)
	var suffix := ""
	if String(info["battle"]) != "":
		suffix = " · " + String(info["battle"])
	_map_button.text = "  %s%s ▸" % [String(info["name"]), suffix]

# ---------- 战场地形卡片选择器 ----------
func _open_map_dialog() -> void:
	if _map_button and _map_button.disabled:
		return
	var existing = get_node_or_null("MapDialog")
	if existing:
		existing.queue_free()
		return
	var dlg = MapSelectDialog.new()
	dlg.name = "MapDialog"
	dlg.map_selected.connect(_select_map)
	add_child(dlg)

func _select_map(id: String) -> void:
	GameSettings.map_id = id
	_refresh_map_button()

# 桌面版控件直接挂在根节点下，手机版嵌在滚动容器里；
# 统一递归查找，否则手机端读不到 ModeSelect/DiffSelect，模式永远落到 1V1。
func _find_ui(node_name: String) -> Node:
	var n = find_child(node_name, true, false)
	if n:
		return n
	return get_node_or_null(node_name)

func _on_play_pressed():
	GameSettings.tutorial_mode = false
	GameSettings.campaign_mode = false
	GameSettings.campaign_level_id = ""
	GameSettings.player_nation = nation_select.selected
	# 单机敌国避开玩家国家：国家色是主要识别手段，同国会撞色。
	var enemy_nation = randi() % (RTSConfig.Nation.size() - 1)
	if enemy_nation >= GameSettings.player_nation:
		enemy_nation += 1
	GameSettings.enemy_nation = enemy_nation
	var ds = _find_ui("DiffSelect")
	if ds: GameSettings.ai_difficulty = ds.selected
	var ms = _find_ui("ModeSelect")
	var mode_idx = ms.selected if ms else 0
	GameSettings.is_ffa = mode_idx >= 3   # 3/4/5 国乱斗
	if GameSettings.is_ffa:
		# 乱斗项自 index 3 起，index 值恰好等于国家数（3/4/5）
		GameSettings.ffa_nation_count = mode_idx
		GameSettings.ai_mode = 1   # 乱斗不套用 1v1/2v2 语义
	else:
		GameSettings.ffa_nation_count = 3
		GameSettings.ai_mode = mode_idx + 1
	# 战场地形对所有模式生效（包括乱斗）
	var fc = _find_ui("FastCheck")
	GameSettings.fast_mode = fc.button_pressed if fc else false
	var rc = _find_ui("ResearchCheck")
	GameSettings.progression_mode = GameSettings.ProgressionMode.RESEARCH if (rc and rc.button_pressed) else GameSettings.ProgressionMode.CLASSIC
	get_tree().change_scene_to_file("res://scenes/rts_battle.tscn")

func _on_multiplayer_pressed():
	GameSettings.tutorial_mode = false
	GameSettings.campaign_mode = false
	GameSettings.campaign_level_id = ""
	var ds = _find_ui("DiffSelect")
	if ds: GameSettings.ai_difficulty = ds.selected
	GameSettings.ai_mode = 1   # 联机模式不使用单机模式
	GameSettings.is_ffa = false
	GameSettings.map_id = "classic"   # 联机选图在联机大厅里选
	var fc = _find_ui("FastCheck")
	GameSettings.fast_mode = fc.button_pressed if fc else false
	get_tree().change_scene_to_file("res://scenes/online_menu.tscn")

func _on_units_pressed():
	# 打开单位图鉴页面
	get_tree().change_scene_to_file("res://scenes/unit_view.tscn")

# 操作指南：完整按键 / 经济 / 战斗说明，可滚动阅读
func _on_guide_pressed() -> void:
	GuidePanel.open(self, GuidePanel.Mode.GUIDE)

# 新手教程：五步上手 + 一键开始简单 1v1（进局后左上角继续显示动态目标）
func _on_tutorial_pressed() -> void:
	var panel := GuidePanel.open(self, GuidePanel.Mode.TUTORIAL)
	if panel == null:
		return
	panel.tutorial_start_requested.connect(_start_tutorial_battle)
	panel.guide_requested.connect(func():
		GuidePanel.open(self, GuidePanel.Mode.GUIDE))

func _start_tutorial_battle() -> void:
	var player_nation: int = nation_select.selected if nation_select != null else 0
	if player_nation < 0 or player_nation >= RTSConfig.Nation.size():
		player_nation = RTSConfig.Nation.VIKING
	GameSettings.tutorial_mode = true
	GameSettings.campaign_mode = false
	GameSettings.campaign_level_id = ""
	GameSettings.player_nation = player_nation
	GameSettings.enemy_nation = (player_nation + 1) % RTSConfig.Nation.size()
	GameSettings.ai_difficulty = GameSettings.AIDifficulty.EASY
	GameSettings.ai_mode = 1
	GameSettings.is_ffa = false
	GameSettings.fast_mode = true
	GameSettings.progression_mode = GameSettings.ProgressionMode.CLASSIC
	GameSettings.map_id = "classic"
	GameSettings.map_seed = 0
	get_tree().change_scene_to_file("res://scenes/rts_battle.tscn")

# 闯关模式：打开选关界面（关卡数据在 scripts/data/CampaignData.gd）
func _on_campaign_pressed() -> void:
	GameSettings.tutorial_mode = false
	GameSettings.campaign_mode = true
	GameSettings.campaign_level_id = ""
	get_tree().change_scene_to_file("res://scenes/campaign_menu.tscn")

# 打开更新日志面板（已打开则关掉，形成"按钮开关"）
func _on_changelog_pressed() -> void:
	var existing := get_node_or_null("ChangelogPanel")
	if existing != null:
		existing.queue_free()
		return
	ChangelogPanel.open(self)
	# 看过了就把 NEW 标记清掉
	if _changelog_btn != null and is_instance_valid(_changelog_btn):
		var badge := _changelog_btn.get_node_or_null("NewBadge")
		if badge != null:
			badge.queue_free()

# 入口按钮上的「NEW」小徽章：有新版本日志没看过时才加
func _attach_new_badge(btn: Button, font_size: int) -> void:
	if not ChangelogData.is_unseen():
		return
	var badge := Label.new()
	badge.name = "NewBadge"
	badge.text = "NEW"
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_theme_font_size_override("font_size", font_size)
	badge.add_theme_color_override("font_color", UITheme.GOLD_TEXT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = UITheme.GOLD
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(2)
	badge.add_theme_stylebox_override("normal", sb)
	var badge_size := Vector2(58, 24)
	badge.size = badge_size
	badge.position = Vector2(btn.size.x - badge_size.x - 12, (btn.size.y - badge_size.y) * 0.5)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(badge)

# 手机版入口按钮整行宽：NEW 徽章用右上角锚点，窗口/字号变化都不会错位
func _attach_new_badge_mobile(btn: Button) -> void:
	if not ChangelogData.is_unseen():
		return
	var badge := Label.new()
	badge.name = "NewBadge"
	badge.text = "NEW"
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_theme_font_size_override("font_size", UILayout.font_dp(8.5))
	badge.add_theme_color_override("font_color", UITheme.GOLD_TEXT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = UITheme.GOLD
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(2)
	badge.add_theme_stylebox_override("normal", sb)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	badge.offset_left = -UILayout.dp(46.0)
	badge.offset_right = -UILayout.dp(6.0)
	badge.offset_top = UILayout.dp(3.0)
	badge.offset_bottom = UILayout.dp(19.0)
	btn.add_child(badge)

# 底部说明行：居中、自动换行，字体/颜色跟随主题
func _add_tip_line(box: VBoxContainer, text: String, font_size: int, color: Color) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(lbl, font_size, color)
	box.add_child(lbl)

# ==================== 更新检查 ====================
# 主菜单启动后拉一次版本清单：有新版就在底部（手机在列表最上面）弹出下载按钮。
func _setup_update_check() -> void:
	if not UpdateConfig.ENABLED:
		return
	_update_checker = UpdateChecker.new()
	_update_checker.name = "UpdateChecker"
	add_child(_update_checker)
	_update_checker.finished.connect(_on_update_checked)
	_update_checker.check(false)

func _on_update_checked(ok: bool, has_update: bool, remote_version: String, download_url: String, notes: String) -> void:
	if not ok or not has_update or download_url == "":
		return
	_show_update_banner(remote_version, download_url, notes)

# 有新版本：底部一个金色下载按钮（桌面绝对定位 / 手机插到滚动列表最上面）
func _show_update_banner(remote_version: String, download_url: String, notes: String) -> void:
	if _update_banner != null and is_instance_valid(_update_banner):
		return
	var btn := Button.new()
	btn.name = "UpdateBanner"
	var action := "点此刷新" if OS.has_feature("web") else "点此下载"
	btn.text = "🆕 发现新版本 %s · %s" % [remote_version, action]
	btn.tooltip_text = notes
	btn.pressed.connect(_open_download.bind(download_url))
	if InputSource.use_mobile_ui():
		btn.custom_minimum_size = Vector2(0, UILayout.dp(42.0))
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_mobile_style_button(btn, "primary", UILayout.font_dp(12.0))
		if _mobile_vb != null and is_instance_valid(_mobile_vb):
			_mobile_vb.add_child(btn)
			_mobile_vb.move_child(btn, 0)
		else:
			add_child(btn)
	else:
		btn.position = Vector2(900, 1288)
		btn.size = Vector2(600, 46)
		UITheme.apply_primary_button(btn, UITheme.FONT_MD + 2)
		add_child(btn)
		UITheme.pulse(btn, 1.02, 1.1)
	_update_banner = btn

# 用系统浏览器/商店打开下载页；Web 版直接跳到新地址，避免停留在旧页面。
func _open_download(url: String) -> void:
	if OS.has_feature("web"):
		var js = Engine.get_singleton("JavaScriptBridge")
		if js != null:
			var target := url.strip_edges()
			if target == "":
				js.eval("window.location.reload();")
			else:
				js.eval("window.location.href = %s;" % JSON.stringify(target))
			return
	if url.strip_edges() == "":
		return
	OS.shell_open(url)

func _on_settings_pressed():
	# Toggle settings panel
	var existing = get_node_or_null("SettingsPanel")
	if existing:
		existing.visible = !existing.visible
		return
	if InputSource.use_mobile_ui():
		_create_settings_panel_mobile()
	else:
		_create_settings_panel()

func _create_settings_panel():
	var panel = Panel.new()
	panel.name = "SettingsPanel"
	panel.position = Vector2(750, 400)
	panel.size = Vector2(900, 420)
	panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	add_child(panel)
	UITheme.fade_in(panel, 0.3)

	# Title
	var ttl = UITheme.make_section_title("⚙️ 音量设置", UITheme.GOLD, 30)
	ttl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ttl.position = Vector2(0, 15)
	ttl.size = Vector2(900, 40)
	panel.add_child(ttl)

	# Close button
	var close = Button.new()
	close.text = "✕"
	close.position = Vector2(840, 10)
	close.size = Vector2(50, 50)
	UITheme.apply_muted_button(close, UITheme.FONT_SM)
	close.pressed.connect(func(): panel.visible = false)
	panel.add_child(close)

	# Music volume
	var ml = Label.new()
	ml.text = "音乐音量"
	ml.position = Vector2(50, 90)
	ml.size = Vector2(200, 30)
	UITheme.apply_label(ml, 22, UITheme.PARCHMENT)
	panel.add_child(ml)

	var mv = HSlider.new()
	mv.name = "MusicSlider"
	mv.position = Vector2(280, 92)
	mv.size = Vector2(500, 30)
	mv.min_value = 0; mv.max_value = 100
	mv.value = AudioManager._music_volume * 100
	mv.value_changed.connect(func(v: float): AudioManager.set_music_volume(v / 100.0))
	panel.add_child(mv)

	var mvl = Label.new()
	mvl.name = "MusicValue"
	mvl.text = "%d%%" % int(mv.value)
	mvl.position = Vector2(790, 90)
	mvl.size = Vector2(80, 30)
	UITheme.apply_label(mvl, 20, UITheme.RES_GOLD)
	panel.add_child(mvl)
	mv.value_changed.connect(func(v: float): mvl.text = "%d%%" % int(v))

	# SFX volume
	var sl = Label.new()
	sl.text = "音效音量"
	sl.position = Vector2(50, 160)
	sl.size = Vector2(200, 30)
	UITheme.apply_label(sl, 22, UITheme.PARCHMENT)
	panel.add_child(sl)

	var sv = HSlider.new()
	sv.name = "SFXSlider"
	sv.position = Vector2(280, 162)
	sv.size = Vector2(500, 30)
	sv.min_value = 0; sv.max_value = 100
	sv.value = AudioManager._sfx_volume * 100
	sv.value_changed.connect(func(v: float): AudioManager.set_sfx_volume(v / 100.0))
	panel.add_child(sv)

	var svl = Label.new()
	svl.name = "SFXValue"
	svl.text = "%d%%" % int(sv.value)
	svl.position = Vector2(790, 160)
	svl.size = Vector2(80, 30)
	UITheme.apply_label(svl, 20, UITheme.RES_GOLD)
	panel.add_child(svl)
	sv.value_changed.connect(func(v: float): svl.text = "%d%%" % int(v))

	# Test SFX button
	var test = Button.new()
	test.text = "测试音效"
	test.position = Vector2(280, 230)
	test.size = Vector2(180, 45)
	UITheme.apply_muted_button(test, UITheme.FONT_SM)
	test.pressed.connect(func(): AudioManager.play_sfx("ui_click"))
	panel.add_child(test)

	# --- 命令模式 ---
	var cmd_label = Label.new()
	cmd_label.text = "命令模式"
	cmd_label.position = Vector2(50, 292)
	cmd_label.size = Vector2(200, 30)
	UITheme.apply_label(cmd_label, 22, UITheme.PARCHMENT)
	panel.add_child(cmd_label)

	var cmd_single = Button.new()
	cmd_single.text = "单次命令"
	cmd_single.position = Vector2(280, 292)
	cmd_single.size = Vector2(140, 40)

	var cmd_cont = Button.new()
	cmd_cont.text = "连续命令"
	cmd_cont.position = Vector2(430, 292)
	cmd_cont.size = Vector2(140, 40)

	_set_cmd_toggle(cmd_single, GameSettings.command_mode == 0)
	_set_cmd_toggle(cmd_cont, GameSettings.command_mode == 1)
	cmd_single.pressed.connect(func():
		GameSettings.command_mode = 0
		_set_cmd_toggle(cmd_single, true)
		_set_cmd_toggle(cmd_cont, false)
	)
	cmd_cont.pressed.connect(func():
		GameSettings.command_mode = 1
		_set_cmd_toggle(cmd_single, false)
		_set_cmd_toggle(cmd_cont, true)
	)
	panel.add_child(cmd_single)
	panel.add_child(cmd_cont)

	# Hint
	var hint = Label.new()
	hint.text = "音效距离衰减：50米内可听到 | 单次命令：下令后取消选择"
	hint.position = Vector2(50, 356)
	hint.size = Vector2(800, 25)
	UITheme.apply_label(hint, 16, Color(UITheme.STONE).lightened(0.25))
	panel.add_child(hint)

func _on_quit_pressed():
	get_tree().quit()

# ==================== 手机端布局 ====================
# 桌面版是 2400×1400 绝对定位；手机屏只有 674×393dp，字号与按钮必须按 dp 重排。
# 结构：标题 + 可滚动竖排配置区（国家/AI 难度/模式/地图/快速模式/按钮）。

func _build_mobile_layout() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.08, 0.06)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var top_bar := ColorRect.new()
	top_bar.color = Color(UITheme.GOLD)
	top_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top_bar.offset_bottom = UILayout.dp(2.0)
	add_child(top_bar)

	var title := Label.new()
	title.text = "👑 FINGER EMPIRE 👑"
	title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = UILayout.dp(6.0)
	title.offset_bottom = UILayout.dp(28.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", UILayout.font_dp(15.0))
	title.add_theme_color_override("font_color", UITheme.GOLD.lightened(0.15))
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 3)
	add_child(title)

	var subtitle := Label.new()
	subtitle.text = "即时战略 · 帝国纷争"
	subtitle.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	subtitle.offset_top = UILayout.dp(28.0)
	subtitle.offset_bottom = UILayout.dp(41.0)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(subtitle, UILayout.font_dp(9.0), UITheme.PARCHMENT)
	add_child(subtitle)

	# 滚动区：配置区内容超过一屏时上下滑动
	var scroll := ScrollContainer.new()
	scroll.name = "MobileScroll"
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_top = UILayout.dp(44.0)
	scroll.offset_left = UILayout.dp(10.0)
	scroll.offset_right = -UILayout.dp(10.0)
	scroll.offset_bottom = -UILayout.dp(6.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	# 触摸拖动由 MainMenu._input 驱动；容器自身忽略鼠标事件，避免它把 scroll 值又算回 0
	scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scroll)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", int(UILayout.dp(6.0)))
	scroll.add_child(vb)

	# 国家选择（选项文本较长，字号用 10dp 防止截断过多）
	var nation_title := _mobile_section("⚔️ 战役配置 ⚔️", UITheme.GOLD)
	vb.add_child(nation_title)

	nation_select = OptionButton.new()
	nation_select.add_item("  维京    +25%生命  +10%速度")
	nation_select.add_item("  英格兰  +15%攻击  +20%视野  采木+10%")
	nation_select.add_item("  法兰西  +25护甲  城堡2级起始")
	nation_select.add_item("  中国    食物+20%  黄金+10%  人口+10")
	nation_select.add_item("  匈牙利  +15护甲  石材+15%  黄金+10%  人口+5")
	nation_select.add_item("  日本    +15%攻速  +10%攻击")
	nation_select.add_item("  拜占庭  +2双护甲  黄金+10%")
	nation_select.add_item("  蒙古    速度+20%  攻速+10%  视野+20%")
	nation_select.add_item("  波斯    生命+15%  盾甲+1  黄金+15%  人口+5")
	nation_select.add_item("  西班牙  攻击+10%  铠甲+1  黄金+15%")
	nation_select.custom_minimum_size = Vector2(0, UILayout.dp(38.0))
	nation_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_option(nation_select, UILayout.font_dp(10.0))
	vb.add_child(nation_select)

	var diff_select := OptionButton.new()
	diff_select.name = "DiffSelect"
	diff_select.add_item("  AI 难度：简单")
	diff_select.add_item("  AI 难度：普通（资源×2）")
	diff_select.add_item("  AI 难度：困难（资源×3+额外）")
	diff_select.add_item("  AI 难度：地狱（困难+速度+20%）")
	diff_select.custom_minimum_size = Vector2(0, UILayout.dp(36.0))
	diff_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_option(diff_select, UILayout.font_dp(10.0))
	vb.add_child(diff_select)

	var mode_select := OptionButton.new()
	mode_select.name = "ModeSelect"
	mode_select.add_item("  模式：1V1")
	mode_select.add_item("  模式：2V2")
	mode_select.add_item("  模式：3V3")
	mode_select.add_item("  乱斗·3国")
	mode_select.add_item("  乱斗·4国")
	mode_select.add_item("  乱斗·5国")
	mode_select.selected = 0
	mode_select.custom_minimum_size = Vector2(0, UILayout.dp(36.0))
	mode_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_option(mode_select, UILayout.font_dp(10.0))
	vb.add_child(mode_select)

	var map_btn := Button.new()
	map_btn.name = "MapButton"
	map_btn.custom_minimum_size = Vector2(0, UILayout.dp(36.0))
	map_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_muted_button(map_btn, UILayout.font_dp(10.0))
	map_btn.pressed.connect(_open_map_dialog)
	vb.add_child(map_btn)
	_map_button = map_btn
	_refresh_map_button()
	mode_select.item_selected.connect(_update_map_availability)
	_update_map_availability(mode_select.selected)

	var fast_check := CheckBox.new()
	fast_check.name = "FastCheck"
	fast_check.text = "快速模式（采集×3）"
	fast_check.custom_minimum_size = Vector2(0, UILayout.dp(34.0))
	fast_check.add_theme_font_size_override("font_size", UILayout.font_dp(10.0))
	fast_check.add_theme_color_override("font_color", UITheme.PARCHMENT)
	fast_check.add_theme_color_override("font_hover_color", UITheme.GOLD)
	fast_check.add_theme_color_override("icon_normal_color", UITheme.GOLD)
	vb.add_child(fast_check)

	var research_check := CheckBox.new()
	research_check.name = "ResearchCheck"
	research_check.text = "科研模式（四时代·科技树）"
	research_check.custom_minimum_size = Vector2(0, UILayout.dp(34.0))
	research_check.add_theme_font_size_override("font_size", UILayout.font_dp(10.0))
	research_check.add_theme_color_override("font_color", UITheme.PARCHMENT)
	research_check.add_theme_color_override("font_hover_color", UITheme.GOLD)
	research_check.add_theme_color_override("icon_normal_color", UITheme.GOLD)
	research_check.tooltip_text = "关闭为经典模式；开启后通过时代与科技树解锁建筑/单位。教程与战役固定经典模式。"
	vb.add_child(research_check)
	research_check.toggled.connect(func(on): GameSettings.progression_mode = GameSettings.ProgressionMode.RESEARCH if on else GameSettings.ProgressionMode.CLASSIC)

	var sep := HSeparator.new()
	vb.add_child(sep)

	var btn_data := [
		["⚔️ 单人游戏", _on_play_pressed, "primary"],
		["🌐 联机对战", _on_multiplayer_pressed, "primary"],
		["📖 单位图鉴", _on_units_pressed, "book"],
		["📘 操作指南", _on_guide_pressed, "book"],
		["🎓 新手教程", _on_tutorial_pressed, "primary"],
		["⚔️ 战役闯关", _on_campaign_pressed, "primary"],
		["⚙️ 设  置", _on_settings_pressed, "muted"],
		["📜 更新日志（%s）" % AppVersion.version(), _on_changelog_pressed, "muted"],
		["🚪 退出游戏", _on_quit_pressed, "danger"],
	]
	for data in btn_data:
		var btn := Button.new()
		btn.text = data[0]
		btn.custom_minimum_size = Vector2(0, UILayout.dp(42.0))
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_mobile_style_button(btn, data[2], UILayout.font_dp(13.0))
		# 更新日志：长按/点击都走同一个回调，NEW 徽章贴在按钮右侧
		btn.pressed.connect(data[1])
		vb.add_child(btn)
		if String(data[0]).begins_with("📜 更新日志"):
			_changelog_btn = btn
			# 手机按钮是整行宽，NEW 徽章用锚点贴右上角
			_attach_new_badge_mobile(btn)

	var tip := Label.new()
	tip.text = "手机操作：点按选择·指挥 / 拖动平移 / 双指缩放 / ↻ 按住旋转视角 / 长按空地建造 / 右上角小地图切换统计"
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.add_theme_font_size_override("font_size", UILayout.font_dp(8.0))
	tip.add_theme_color_override("font_color", Color(UITheme.STONE).lightened(0.25))
	vb.add_child(tip)

	# 本版贴士（和桌面版一致，提示这版新增可调项与更新日志入口）
	var tip_ver := Label.new()
	tip_ver.text = "本版 %s：设置里可调相机倍数 · 主菜单「📜 更新日志」看全部改动" % AppVersion.version()
	tip_ver.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip_ver.add_theme_font_size_override("font_size", UILayout.font_dp(8.0))
	tip_ver.add_theme_color_override("font_color", Color(UITheme.GOLD, 0.8))
	vb.add_child(tip_ver)

	vb.add_child(_mobile_section("%s - Godot 4.7" % AppVersion.display(), Color(UITheme.STONE).lightened(0.2)))
	_mobile_vb = vb

func _mobile_section(text: String, color: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", UILayout.font_dp(11.0))
	lbl.add_theme_color_override("font_color", color)
	return lbl

# 菜单按钮样式（primary / danger / book / muted），字号由调用方按 dp 传入
func _mobile_style_button(btn: Button, kind: String, font_size: int) -> void:
	match kind:
		"primary":
			UITheme.apply_primary_button(btn, font_size)
		"danger":
			UITheme.apply_danger_button(btn, font_size)
		"book":
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(UITheme.SAPPHIRE, 0.16)
			sb.border_color = Color(UITheme.SAPPHIRE, 0.95)
			sb.set_corner_radius_all(10)
			sb.set_border_width_all(2)
			sb.set_content_margin_all(6)
			btn.add_theme_stylebox_override("normal", sb)
			var hover := sb.duplicate()
			hover.bg_color = Color(UITheme.SAPPHIRE, 0.30)
			btn.add_theme_stylebox_override("hover", hover)
			var pressed := hover.duplicate()
			pressed.bg_color = Color(UITheme.SAPPHIRE, 0.44)
			btn.add_theme_stylebox_override("pressed", pressed)
			btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
			btn.add_theme_font_size_override("font_size", font_size)
			btn.add_theme_color_override("font_color", UITheme.PARCHMENT)
			btn.add_theme_color_override("font_hover_color", Color(UITheme.GOLD, 1.0))
			btn.add_theme_color_override("font_pressed_color", UITheme.GOLD.lightened(0.2))
		_:
			UITheme.apply_muted_button(btn, font_size)

# 手机端设置面板：全屏滚动卡片，控件按 dp 放大
func _create_settings_panel_mobile() -> void:
	var panel := Panel.new()
	panel.name = "SettingsPanel"
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = UILayout.dp(6.0)
	panel.offset_right = -UILayout.dp(6.0)
	panel.offset_top = UILayout.dp(8.0)
	panel.offset_bottom = -UILayout.dp(8.0)
	panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	panel.z_index = 50
	add_child(panel)
	UITheme.fade_in(panel, 0.3)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left = UILayout.dp(8.0)
	scroll.offset_right = -UILayout.dp(8.0)
	scroll.offset_top = UILayout.dp(8.0)
	scroll.offset_bottom = -UILayout.dp(8.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(scroll)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", int(UILayout.dp(6.0)))
	scroll.add_child(vb)

	var ttl := UITheme.make_section_title("⚙️ 音量设置", UITheme.GOLD, UILayout.font_dp(12.0))
	ttl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(ttl)

	vb.add_child(_mobile_volume_row("音乐音量", AudioManager._music_volume,
		func(v: float): AudioManager.set_music_volume(v), "MusicSlider"))
	vb.add_child(_mobile_volume_row("音效音量", AudioManager._sfx_volume,
		func(v: float): AudioManager.set_sfx_volume(v), "SFXSlider"))

	var test := Button.new()
	test.text = "🔊 测试音效"
	test.custom_minimum_size = Vector2(0, UILayout.dp(36.0))
	UITheme.apply_muted_button(test, UILayout.font_dp(11.0))
	test.pressed.connect(func(): AudioManager.play_sfx("ui_click"))
	vb.add_child(test)

	vb.add_child(_mobile_section("命令模式", UITheme.PARCHMENT))

	var cmd_row := HBoxContainer.new()
	cmd_row.add_theme_constant_override("separation", int(UILayout.dp(6.0)))
	vb.add_child(cmd_row)
	var cmd_single := Button.new()
	cmd_single.text = "单次命令"
	cmd_single.custom_minimum_size = Vector2(0, UILayout.dp(36.0))
	cmd_single.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var cmd_cont := Button.new()
	cmd_cont.text = "连续命令"
	cmd_cont.custom_minimum_size = Vector2(0, UILayout.dp(36.0))
	cmd_cont.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_set_cmd_toggle(cmd_single, GameSettings.command_mode == 0)
	_set_cmd_toggle(cmd_cont, GameSettings.command_mode == 1)
	cmd_single.add_theme_font_size_override("font_size", UILayout.font_dp(11.0))
	cmd_cont.add_theme_font_size_override("font_size", UILayout.font_dp(11.0))
	cmd_single.pressed.connect(func():
		GameSettings.command_mode = 0
		_set_cmd_toggle(cmd_single, true)
		_set_cmd_toggle(cmd_cont, false)
	)
	cmd_cont.pressed.connect(func():
		GameSettings.command_mode = 1
		_set_cmd_toggle(cmd_single, false)
		_set_cmd_toggle(cmd_cont, true)
	)
	cmd_row.add_child(cmd_single)
	cmd_row.add_child(cmd_cont)

	var hint := Label.new()
	hint.text = "音效距离衰减：50米内可听到 | 单次命令：下令后取消选择"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", UILayout.font_dp(8.0))
	hint.add_theme_color_override("font_color", Color(UITheme.STONE).lightened(0.25))
	vb.add_child(hint)

	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(0, UILayout.dp(40.0))
	UITheme.apply_danger_button(close, UILayout.font_dp(12.0))
	close.pressed.connect(func(): panel.visible = false)
	vb.add_child(close)

# 手机端音量行：标签 + 滑块 + 百分比
func _mobile_volume_row(label_text: String, value: float, setter: Callable, slider_name: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(UILayout.dp(4.0)))
	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(UILayout.dp(62.0), 0)
	lbl.add_theme_font_size_override("font_size", UILayout.font_dp(10.0))
	lbl.add_theme_color_override("font_color", UITheme.PARCHMENT)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lbl)

	var slider := HSlider.new()
	slider.name = slider_name
	slider.custom_minimum_size = Vector2(0, UILayout.dp(28.0))
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.min_value = 0
	slider.max_value = 100
	slider.value = value * 100.0
	row.add_child(slider)

	var val := Label.new()
	val.text = "%d%%" % int(slider.value)
	val.custom_minimum_size = Vector2(UILayout.dp(34.0), 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.add_theme_font_size_override("font_size", UILayout.font_dp(10.0))
	val.add_theme_color_override("font_color", UITheme.RES_GOLD)
	val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(val)

	slider.value_changed.connect(func(v: float):
		val.text = "%d%%" % int(v)
		setter.call(v / 100.0)
	)
	return row
