class_name GuidePanel
extends Control

# 主菜单帮助弹层：mode 为 GUIDE 时是「操作指南」，为 TUTORIAL 时是「新手教程」。
# 结构与更新日志面板一致：半透明遮罩 + 暖黑金边卡片 + 可滚动内容；
# 手机端铺满屏幕，触摸拖动由 MainMenu 的 UILayout.scroll_at 驱动。
signal tutorial_start_requested
signal guide_requested

enum Mode { GUIDE, TUTORIAL }

const PANEL_W: float = 920.0
const PANEL_H: float = 1080.0

var _mode: int = Mode.GUIDE
var _mobile: bool = false
var _scroll: ScrollContainer = null
var _content: VBoxContainer = null

# 打开帮助面板；已经开着同一个面板时再点一次按钮会关闭（开关式）。
static func open(parent: Node, mode: int) -> GuidePanel:
	var existing := parent.get_node_or_null("GuidePanel") as GuidePanel
	if existing != null:
		var same: bool = existing._mode == mode
		# 先改名再 queue_free：同一帧新建的面板如果还叫 GuidePanel 会被 Godot 自动改名，
		# 下次按钮就找不到它，无法再开关。
		existing.name = "GuidePanelClosing"
		existing.queue_free()
		if same:
			return null
	var panel := GuidePanel.new()
	panel.name = "GuidePanel"
	panel._mode = mode
	parent.add_child(panel)
	return panel

func _ready() -> void:
	_mobile = InputSource.use_mobile_ui()
	add_to_group("mobile_modal_ui")
	# 主菜单根节点在桌面分支没有设置设计尺寸，这里直接按 2400×1400 铺满。
	# 手机竖屏时改用实际展开后的设计视口，否则指南面板只有 1400 高、上下留黑。
	size = UILayout.view_size() if _mobile else Vector2(UILayout.DESIGN_W, UILayout.DESIGN_H)
	position = Vector2.ZERO
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 260
	_build()
	UITheme.fade_in(self, 0.18)

# ==================== 界面构建 ====================
func _build() -> void:
	var pad: float = UILayout.dp(9.0) if _mobile else 16.0
	var header_h: float = UILayout.dp(40.0) if _mobile else 62.0

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.72)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(_on_dim_input)
	add_child(dim)

	var panel := Panel.new()
	var w: float = PANEL_W
	var h: float = PANEL_H
	if _mobile:
		var vp_size := UILayout.view_size()
		w = vp_size.x - UILayout.dp(14.0)
		h = vp_size.y - UILayout.dp(18.0)
	panel.size = Vector2(w, h)
	var vp_now := UILayout.view_size()
	panel.position = Vector2((vp_now.x - w) * 0.5, (vp_now.y - h) * 0.5)
	panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	add_child(panel)

	var title_text: String = "📘 操作指南" if _mode == Mode.GUIDE else "🎓 新手教程"
	var title := UITheme.make_section_title(title_text, UITheme.GOLD,
		UILayout.font_dp(16.0) if _mobile else 30)
	title.position = Vector2(pad, pad * 0.45)
	title.size = Vector2(w - pad * 2.0 - (UILayout.dp(36.0) if _mobile else 52.0), header_h)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	panel.add_child(title)

	var close := Button.new()
	close.text = "✕"
	close.size = Vector2(UILayout.dp(32.0) if _mobile else 44.0,
		UILayout.dp(30.0) if _mobile else 40.0)
	close.position = Vector2(w - pad - close.size.x, pad * 0.6)
	close.focus_mode = Control.FOCUS_NONE
	UITheme.apply_muted_button(close, UILayout.font_dp(11.0) if _mobile else 20)
	close.pressed.connect(_close)
	panel.add_child(close)

	_scroll = ScrollContainer.new()
	_scroll.position = Vector2(pad, header_h + pad * 0.2)
	_scroll.size = Vector2(w - pad * 2.0, h - header_h - pad * 1.4)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.add_child(_scroll)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", int(UILayout.dp(7.0) if _mobile else 12))
	_scroll.add_child(_content)

	if _mode == Mode.GUIDE:
		_build_guide()
	else:
		_build_tutorial()

# ==================== 操作指南 ====================
func _build_guide() -> void:
	_add_intro("第一次进入帝国？先用 2 分钟看完下面几段，就能独立打完一局。")
	_add_heading("🎯 胜利目标")
	_add_body("保护自己的城堡，摧毁敌方城堡即可获胜。城堡被摧毁会立即失败；"
		+ "联机/乱斗模式中，最后一个还有城堡的国家获胜。")

	_add_heading("🖱️ 基础操作")
	_add_key_row("左键", "点选单位/建筑；拖动框选；选中军队后，点地面移动、点敌人攻击、点资源采集。"
		+ "点己方城墙会让军队上墙，点桥会过桥，点己方运载船会让陆军登船。")
	_add_key_row("右键", "只在空地打开建造菜单；选中单位时右键空地也会保留当前选中。"
		+ "右键点单位/建筑用于查看信息或下达智能指令，不再清空选择。")
	_add_key_row("建筑选中", "只选中建筑时，左键点空地即可取消选中。")
	_add_key_row("中键拖拽", "平移视角；按住 Ctrl + 中键拖动可以旋转视角。")
	_add_key_row("滚轮 / 双指", "缩放视角；方向键也可以平移。")
	_add_key_row("Shift", "连续建造/连续生产；选中多个建筑时一起下达生产命令；"
		+ "给军队下令时按住 Shift 可排队。")
	_add_key_row("A / M", "A 进入攻击下令模式，下一次左键攻击目标；M 进入纯移动模式，"
		+ "下一次左键只移动不主动索敌；右键或 Esc 取消。")

	_add_heading("🌾 经济与采集")
	_add_body("选中农民，右键树木、金矿、石矿、农田、羊或油井，农民会自动往返主城交付。"
		+ "木材、黄金、石头、食物是最基础的四种资源；石油用于后期攻城与特殊单位。")
	_add_key_row("人口", "人口达到上限会停产。建造房屋提高上限，房屋被拆会卡人口。")
	_add_key_row("主城", "主城可以训练农民、升级时代；升级后解锁更强建筑和兵种。")
	_add_key_row("快速模式", "结算前勾选「快速模式」可让采集速度 ×3，适合新手和快速对局。")

	_add_heading("🏰 建造与生产")
	_add_body("右键点空地打开建造菜单，左键选择建筑后再左键放置（有选中单位时也不会清空选择）。"
		+ "左键放下地基后，附近农民会自动赶去施工；也可以选中农民，右键自家工地手动派人。"
		+ "最多 3 个农民同时施工，人越多越快；没有农民到场时进度会暂停，农民被杀/调走也会停工。")
	_add_body("修理同理：选中受损建筑点「修理」会扣费并派农民，农民到场后才开始回复；"
		+ "即使附近有敌军也可以强行修理，只有没有可用农民或资源不足时才会等待或不可用。"
		+ "地基刚放下、农民还没动工前，信息面板会出现「取消建造」，可全额退款；一旦动工就不能取消。")
	_add_body("选中建筑后，通过右侧/底部命令卡生产、升级。"
		+ "建筑有等级，升级后血量、攻击、产能都会提升；被攻击时优先把农民拉走。")
	_add_key_row("兵营", "训练近战/远程士兵；城堡被围攻时，兵营是翻盘的关键。")
	_add_key_row("城墙 + 塔", "城墙阻挡陆军，塔提供视野和火力；记得给己方城墙留门/梯子。"
		+ "箭塔/炮塔和城堡还能进驻士兵，驻军是防守时最划算的火力升级。")

	_add_heading("🛡️ 驻军与齐射（重要）")
	_add_body("箭塔、炮塔和防御城堡（主城不能进驻）可以进驻士兵或农民：选中单位后右键己方目标建筑即可；"
		+ "也可以框选多支部队，点信息面板底部的「🛡️ 进驻建筑」，再左键点目标建筑。"
		+ "右键或 Esc 取消进驻模式。")
	_add_body("每名驻军会让防御建筑在攻击时多发射一颗子弹，每颗子弹单独索敌，可以同时打不同敌人；"
		+ "箭塔/炮塔最多 5 人，城堡最多 10 人。驻军面板会列出兵种和人数，点「🚪 取消进驻」可全部释放。")
	_add_body("防守时优先把远程兵放进箭塔，把近战兵放进城堡；驻军越多，齐射越密。"
		+ "新兵训练营第 6 关「筑墙守土」会专门练习这个操作。")

	_add_heading("🧺 智能军需官")
	_add_body("按 F4（或点顶部「🧺 军需官」按钮）开启后，军需官会自动把农民补充到 15 人，并按各资源储量与仓容缺口分配采集；"
		+ "任意资源接近仓容上限时，会自动在资源点附近补一座仓库。"
		+ "开启时会接管当前正在采集的农民；之后你手动改派目标不会被抢回。关闭 F4 后已派出的农民会继续手头工作。")

	_add_heading("⚔️ 战斗操作")
	_add_key_row("框选 + 左键", "最常用的进攻方式：框选军队，左键点敌人集火；点空地移动。"
		+ "按 A 后再左键目标 = 强制攻击，按 M 后再左键 = 纯移动。"
		+ "命令卡上的生产/升级/修理/拆除/进驻请直接点击按钮，不再提供字母快捷键。")
	_add_key_row("城墙 / 桥 / 船", "选中军队后左键己方城墙：最多 1 个大型或 3 个小型单位上墙，多出的在墙脚待命；"
		+ "左键桥 = 过桥；左键己方运载船 = 最近的陆军自动走到岸边登船，船满后其余单位原地不动。")
	_add_key_row("F1 / F2 / F3 / F4", "F1 全选军队；F2 自动进攻；F3 撤退；F4 开关智能军需官。")
	_add_key_row("P", "快速暂停/继续。暂停时仍可建造、升级、生产和下令，但单位不移动、不攻击，进度条也不读条。")
	_add_key_row("H / , / .", "H 跳到己方主城；逗号选空闲农民；句号循环空闲军事单位。")
	_add_key_row("Ctrl + 1~9", "把当前选中单位编为 1~9 队；按 1~9 快速选队，双击数字跳转编队。")
	_add_key_row("Alt + 左键", "设置驻扎点/集结点，让新兵自动前往；Ctrl + Alt + 左键清除驻扎点。")
	_add_key_row("Esc", "取消 A/M 下令模式；没有下令模式时关闭建造菜单或取消当前选择。")
	_add_key_row("L / Tab", "L 切换血条显示；Tab 跟随选中单位。")
	_add_body("高地视野更远，森林会遮挡视线；攻城单位优先拆建筑，普通士兵优先打敌军。"
		+ "打不过时按 F3 撤退，不要把整支部队送进敌方塔阵。")

	_add_heading("📱 手机操作")
	_add_body("单指点击选择，拖动平移；双指缩放；长按空地打开建造菜单。"
		+ "放下地基后会自动派农民施工，也可以先选农民再右键工地手动派人。"
		+ "右上角小地图可以快速跳转，编队/进攻按钮在屏幕右侧命令卡。")

	_add_heading("🌐 联机提示")
	_add_body("联机双方需要同一版本；进入大厅后选国家、地图和队伍。"
		+ "网络不好时优先打 1v1，人口多的大混战对帧率和网络要求更高。")

	_add_heading("💡 新手容易忽略的细节")
	_add_body("• 开局先保证食物和木材不断，再考虑升时代。\n"
		+ "• 人口快满时提前补房屋，别等停产。\n"
		+ "• 农民被追杀时先拉回主城，不要原地修建筑。\n"
		+ "• 攻城单位拆城墙/塔很快，但需要步兵保护。\n"
		+ "• 防守时别让箭塔空着：进驻 3~5 名士兵，齐射火力会明显提升。\n"
		+ "• 多利用高地、森林和城墙，以少打多。")

	_add_footer("随时可以在主菜单重新打开本指南。")

# ==================== 新手教程 ====================
func _build_tutorial() -> void:
	_add_intro("这是一局为你准备的简单 1v1 新手对局：采集 ×3、AI 简单，"
		+ "进入对局后左上角会持续显示当前目标。")
	_add_heading("🎓 六步上手")
	_add_step("1", "先派农民采资源", "选中农民，右键树木采木材、右键金矿采黄金。"
		+ "食物和木材不要断，主城才能持续生产。")
	_add_step("2", "补房屋，别卡人口", "右键点空地打开建造菜单，选民居，左键放 2 座民居。"
		+ "放下后附近农民会自动赶来施工；没有农民到场时不会涨进度。人口接近上限时就要补。")
	_add_step("3", "建造兵营，训练士兵", "右键点空地打开建造菜单，选兵营，左键放在主城附近。"
		+ "同样要等农民到场才会完工。选中兵营训练 6~8 名士兵；前期不要只造农民，否则 AI 第一波进攻会直接拆掉主城。")
	_add_step("4", "编队并学会集火", "框选士兵按 Ctrl+1 编队，按 F2 自动进攻；"
		+ "遇到敌人时左键集火，或按 A 再左键强制攻击，优先点掉对方远程和攻城单位。")
	_add_step("5", "建塔并练习进驻", "在城堡附近补 2 座箭塔；选中 3~4 名士兵右键箭塔，或框选后点「进驻建筑」再点箭塔。"
		+ "驻军会多打子弹、分别索敌；点建筑可看驻军明细和「取消进驻」。")
	_add_step("6", "保护城堡，反推敌城", "用城墙、箭塔和驻军守住第一波；兵力成型后，"
		+ "带着剩余士兵反推敌方城堡。城堡倒下就获胜。")

	_add_heading("🛡️ 对局中的小目标")
	_add_body("• 保持 8~12 个农民采集。\n"
		+ "• 人口上限保持在当前人口 +10 以上。\n"
		+ "• 第一波防守时把农民拉进主城或塔后。\n"
		+ "• 兵力成型后再进攻，不要一个一个送。")

	_add_footer("建议先看完「操作指南」再开始；对局中左上角会持续显示当前目标。")

	var start_btn := Button.new()
	start_btn.text = "🚀 开始新手对局"
	start_btn.custom_minimum_size = Vector2(0, UILayout.dp(34.0) if _mobile else 58.0)
	start_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_primary_button(start_btn, UILayout.font_dp(12.0) if _mobile else 22)
	start_btn.pressed.connect(func():
		tutorial_start_requested.emit()
		_close())
	_content.add_child(start_btn)

	var guide_btn := Button.new()
	guide_btn.text = "📘 先看操作指南"
	guide_btn.custom_minimum_size = Vector2(0, UILayout.dp(28.0) if _mobile else 44.0)
	guide_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.apply_muted_button(guide_btn, UILayout.font_dp(10.0) if _mobile else 18)
	guide_btn.pressed.connect(func():
		guide_requested.emit()
		_close())
	_content.add_child(guide_btn)

# ==================== 内容组件 ====================
func _add_intro(text: String) -> void:
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", UITheme.card_style(Color(UITheme.GOLD, 0.35)))
	var margin := MarginContainer.new()
	var pad: int = int(UILayout.dp(5.0) if _mobile else 12.0)
	margin.add_theme_constant_override("margin_left", pad)
	margin.add_theme_constant_override("margin_right", pad)
	margin.add_theme_constant_override("margin_top", pad)
	margin.add_theme_constant_override("margin_bottom", pad)
	box.add_child(margin)
	var msg := _make_label(text, UILayout.font_dp(9.5) if _mobile else 18, UITheme.PARCHMENT)
	msg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(msg)
	_content.add_child(box)

func _add_heading(text: String) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, UILayout.dp(2.0) if _mobile else 6.0)
	_content.add_child(spacer)
	var label := _make_label(text, UILayout.font_dp(12.0) if _mobile else 22, UITheme.GOLD)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(label)

func _add_body(text: String) -> void:
	var label := _make_label(text, UILayout.font_dp(9.0) if _mobile else 17, UITheme.PARCHMENT.darkened(0.08))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(label)

func _add_key_row(key: String, desc: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(UILayout.dp(4.0) if _mobile else 10))
	var key_label := _make_label(key, UILayout.font_dp(9.0) if _mobile else 17, UITheme.GOLD)
	key_label.custom_minimum_size = Vector2(UILayout.dp(58.0) if _mobile else 150.0, 0)
	key_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	row.add_child(key_label)
	var desc_label := _make_label(desc, UILayout.font_dp(9.0) if _mobile else 17,
		UITheme.PARCHMENT.darkened(0.08))
	desc_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(desc_label)
	_content.add_child(row)

func _add_step(num: String, title: String, text: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(UILayout.dp(5.0) if _mobile else 12))

	var num_label := _make_label(num, UILayout.font_dp(15.0) if _mobile else 30, UITheme.GOLD)
	num_label.custom_minimum_size = Vector2(UILayout.dp(22.0) if _mobile else 44.0, 0)
	num_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	num_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	row.add_child(num_label)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", int(UILayout.dp(1.0) if _mobile else 3))
	var title_label := _make_label(title, UILayout.font_dp(10.0) if _mobile else 19, UITheme.GOLD.lightened(0.1))
	col.add_child(title_label)
	var body_label := _make_label(text, UILayout.font_dp(9.0) if _mobile else 16,
		UITheme.PARCHMENT.darkened(0.1))
	body_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(body_label)
	row.add_child(col)
	_content.add_child(row)

func _add_footer(text: String) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, UILayout.dp(3.0) if _mobile else 8.0)
	_content.add_child(spacer)
	var label := _make_label(text, UILayout.font_dp(8.5) if _mobile else 15, UITheme.STONE.lightened(0.35))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(label)

func _make_label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
	return label

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
