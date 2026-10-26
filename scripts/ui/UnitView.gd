# scripts/ui/UnitView.gd
# 单位图鉴：浏览全部实体（单位 / 建筑 / 资源）的分类、属性与说明。
extends Control

# ── 画布参考尺寸（与主菜单一致，拉伸时按比例缩放） ───────────
const DESIGN_W := 2400
const DESIGN_H := 1400

# 类型中文名（type: 0=资源 1=建筑 2=单位）
const TYPE_NAMES := { 0: "资源", 1: "建筑", 2: "单位" }

# 详情属性行图标：标题 → emoji（在 _add_pair 输出时自动前置，便于扫读）
const ATTR_ICONS := {
	"耐久 / 生命": "❤️",
	"攻击 / 间隔": "⚔️",
	"秒伤 DPS": "💥",
	"范围 / 视野": "📏",
	"护甲": "🛡️",
	"移动速度": "👣",
	"溅射半径": "💣",
	"占地半径": "📐",
	"生产价格": "🪙",
	"建造价格": "🪙",
	"产出资源": "⛏️",
	"单次采集量": "🧺",
	"恢复速率": "♻️",
	"训练来源": "🏫",
	"类型": "🐾",
	"狩猎产出": "🍖",
	"可采集": "🧺",
	"载货量": "📦",
	"贸易品类": "🛒",
	"官职": "🎖️",
	"俸禄": "🪙",
	"光环": "✨",
	"定位": "🧭",
	"特殊机制": "⚙️",
	"战斗标签": "🏷️",
	"索敌倾向": "🎯",
	"特性": "⚜️",
}

# 分类 → 成员 ID（分类用线性数组 + 查表，稳定且一目了然）
const GROUP_RESOURCE := [0, 1, 2, 3, 4]
const GROUP_BUILDING := [7, 8, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 41, 42, 52, 53, 54, 64]
const GROUP_MILITARY := [11, 12, 15, 19, 30, 31, 32, 33, 34, 35, 36, 37, 38, 65, 66, 67, 68, 69]
const GROUP_SIEGE := [16, 17, 18, 58, 59]
const GROUP_NAVY := [9, 13, 14, 39, 40]
const GROUP_ECONOMY := [5, 6, 10]
const GROUP_MERCHANT := [43, 44, 45, 51]
const GROUP_OFFICIAL := [46, 47, 48, 49, 50]
const GROUP_RELIGION := [55, 56, 57]
const GROUP_ANIMAL := [60, 61, 62, 63]

# 标签页顺序（空串为分类中文名，在 _ready 填图标）
const TAB_ORDER := [
	["all", "全部"],
	["military", "军事"],
	["siege", "攻城"],
	["navy", "海军"],
	["merchant", "商人"],
	["official", "官员"],
	["religion", "宗教"],
	["animal", "动物"],
	["economy", "经济"],
	["building", "建筑"],
	["resource", "资源"],
]

const CLASS_GROUPS := {
	"resource": GROUP_RESOURCE,
	"building": GROUP_BUILDING,
	"military": GROUP_MILITARY,
	"siege": GROUP_SIEGE,
	"navy": GROUP_NAVY,
	"economy": GROUP_ECONOMY,
	"merchant": GROUP_MERCHANT,
	"official": GROUP_OFFICIAL,
	"religion": GROUP_RELIGION,
	"animal": GROUP_ANIMAL,
}

# 国家特色兵种（名称旁徽标）
const NATION_TAGS := {
	30: "维京特色", 31: "英格兰特色", 32: "法兰西特色",
	33: "中国特色", 34: "匈牙利特色", 65: "日本特色", 66: "拜占庭特色",
	67: "蒙古特色", 68: "波斯特色", 69: "西班牙特色",
}

# 图标表：UITheme.entity_emoji 有少数缺漏/错标，这里整表显式覆盖，保证图鉴完整
const EMOJI := {
	0: "💰", 1: "🌲", 2: "⛰️", 3: "🌾", 4: "🛢️",
	5: "🛒", 6: "🛒", 7: "🌉", 8: "🪜", 9: "🚢",
	10: "🧑‍🌾", 11: "⚔️", 12: "🏹", 13: "⛴️", 14: "🛠️",
	15: "🐎", 16: "🧨", 17: "🪨", 18: "🏗️", 19: "🔍",
	20: "🏰", 21: "🏰", 22: "📦", 23: "⚓", 24: "🛠️",
	25: "🏹", 26: "🧨", 27: "🧱", 28: "🏠", 29: "🏭",
	30: "💢", 31: "🏹", 32: "🐴", 33: "🎯", 34: "🐘",
	35: "🔱", 36: "🛡️", 37: "🏹", 38: "🏇", 39: "🚤",
	40: "💥", 41: "🔭", 42: "📚", 43: "🧺", 44: "🧺",
	45: "🧺", 46: "🪙", 47: "🎖️", 48: "🪶", 49: "🚩",
	50: "🐉", 51: "🧺", 52: "🏪", 53: "🏯", 54: "⛪",
	55: "🙏", 56: "🧙", 57: "🥋", 58: "🏹", 59: "💣",
	60: "🐄", 61: "🐖", 62: "🐑", 63: "🐟", 64: "🗼",
	65: "🗡️", 66: "🛡️", 67: "🏹", 68: "🛡️", 69: "🔱",
}

# 官员类型 → 一句定位语
const OFFICIAL_ROLE := {
	"clerk": "收税理政",
	"colonel": "军纪严明",
	"minister": "文治通达",
	"commander": "三军之帅",
	"chancellor": "治国安邦",
}
const OFFICIAL_NAME := {
	"clerk": "县吏", "colonel": "上校", "minister": "尚书",
	"commander": "统帅", "chancellor": "丞相",
}

# 特色一句话说明（不含数字——数值在上方属性表里由配置动态展示）
const DESC := {
	0: "野外金矿脉，派农民即可持续开采黄金。",
	1: "成片树林，是前期木料的主要来源。",
	2: "坚硬石矿，供应建筑与重装部队的用料。",
	3: "肥沃农田，提供训练大军所需的食物。",
	4: "深埋地下的油田，是后期高级兵种与巨型攻城器的稀有燃料。",
	5: "轻便手推车，造价低廉，可四处奔走运送物资。",
	6: "更坚固的贸易车，负责城镇间的物资转运。",
	7: "横架水面的通行桥，让陆军得以跨水行军。",
	8: "攀墙用的梯子，协助部队翻越敌方城墙。",
	9: "运送陆军渡海的大型船只，是跨海登陆的关键。",
	10: "最基础的经济单位，采集金木石食，也是主要的生产建设者。",
	11: "训练廉价、攻守均衡的基础近战步兵，是军队的中坚。",
	12: "廉价远程射手，适合在近战掩护下齐射输出。",
	13: "主力战舰，舰炮对敌方水面船舰构成直接威胁。",
	14: "水上采集船，专门开采海面上的油田。",
	15: "机动力强的近战骑兵，适合绕后包抄与追击溃敌。",
	16: "远程攻城火炮，弹着点带有溅射伤害。",
	17: "远程重型抛石机，抛物线投石打击敌方建筑与人群。",
	18: "巨型破城锤，专克建筑，攻城拔寨的中坚。",
	19: "身轻如燕的斥候，视野出色，用于探图与骚扰。",
	20: "帝国的心脏与象征，被摧毁即宣告战败。",
	21: "基础军事建筑，在此训练步兵并解锁进阶兵种。",
	22: "储存并提高仓储上限，是资源安全的保障。",
	23: "海军建筑，建造战船、采集船等水面舰只。",
	24: "生产各类攻城器械的工坊。",
	25: "箭矢防御塔，早期廉价的据点守卫。",
	26: "火力强劲的炮击塔，扼守要道。",
	27: "阻挡敌军推进、拱卫领土的防线。",
	28: "提供人口上限，是扩军的前提。",
	29: "精英军事工厂，训练重装部队与巨型投石机。",
	30: "狂热嗜战的近战勇士，冲锋陷阵毫不退缩。",
	31: "长弓如雨，射程与火力俱佳的王牌射手。",
	32: "重甲冲锋的铁骑，突进时势如破竹。",
	33: "诸葛连弩，机关劲射，箭如飞蝗。",
	34: "身披重甲的战象，横冲直撞如入无人之境。",
	35: "克制骑兵的长枪阵，矛头直指冲阵铁骑。",
	36: "披重甲的精锐步兵，攻防全面升级。",
	37: "重甲弓手，兼顾远程打击与生存。",
	38: "身经百战的重装骑兵，是王国最强的突击力量。",
	39: "机动的炮击舰船，可在海岸线远程压制。",
	40: "满载火药的自爆舰，以同归于尽换取战果。",
	41: "高耸的瞭望塔，提供广阔的视野与预警。",
	42: "研习文武之道的高等学府，培养朝廷官吏。",
	43: "专营石油贸易的商人。",
	44: "专营木材贸易的商人。",
	45: "专营石料贸易的商人。",
	46: "基层税吏，为国库征收财税。",
	47: "军纪严明的军官，为周围部队提供护甲加成。",
	48: "文官之首，以调度加速周围部队的行军。",
	49: "三军之帅，提振周围部队的攻击速度。",
	50: "一人之下万人之上，大幅提升周边采集效率。",
	51: "专营粮食贸易的商人。",
	52: "商旅往来的集散地，在此训练各色商人。",
	53: "独立自守的巨型要塞，攻防一体，还可在墙垣部署炮台。",
	54: "静谧的修道院，钻研信仰并培养高僧。",
	55: "虔诚的修行者，以信仰之力行走战场。",
	56: "德高望重的长老，攻击可无视目标护甲。",
	57: "武学登峰造极的宗师。",
	58: "机关连弩，射速惊人，火力倾泻如雨。",
	59: "毁天灭地的巨型投石机，一发即可重创敌阵。",
	60: "野外耕牛，猎杀可获得食物。",
	61: "野外肥猪，猎杀可获得食物。",
	62: "温顺绵羊，猎杀可获得食物。",
	63: "近海鱼群，可供捕捞果腹。",
	64: "架设在城墙上的炮台，重炮把守城防要地。",
	65: "忠于武道的日本武士，攻守兼备的近战精英。",
	66: "拜占庭重甲铁骑，全身甲胄，冲阵无往不利。",
	67: "骑射如风的草原弓骑，机动与视野俱佳。",
	68: "波斯精锐重步兵，盾甲坚固，擅长持久作战。",
	69: "西班牙长枪方阵，枪阵如林，专克骑兵冲阵。",
}

# 画布缓存（_ready 统一补齐，避免 type 提示）
var _root: Control
var _canvas: Control
var _tab_buttons: Array[Button] = []
var _tab_to_btn: Dictionary = {}
var _cur_tab := "all"
var _sel_id := -1
var _current_ids: Array = []
var _row_data: Dictionary = {}       # id -> {"btn":..., "name":...}
var _cfg: Dictionary = {}            # id -> 配置副本
var _producers: Dictionary = {}      # 被生产/解锁单位 id -> [ {name, kind, note} ]
var _mobile := false


func _ready() -> void:
	_mobile = InputSource.use_mobile_ui()
	_build_canvas()
	_prepare_data()
	_build_tabs()
	_build_list_panel()
	_build_detail_panel()
	_switch_tab("all")
	if _current_ids.size() > 0:
		_select(_current_ids[0])

# 手机端：列表与详情上下分了左右两栏，触摸拖动直接驱动 ScrollContainer。
func _input(event: InputEvent) -> void:
	if not _mobile:
		return
	if event is InputEventScreenDrag:
		UILayout.scroll_at(self, event.position, event.relative.y)


# ═══════════ 数据准备 ═══════════
func _prepare_data() -> void:
	for id in EntityDatabase.configs.keys():
		_cfg[id] = EntityDatabase.configs[id]
	# 由 produces / upgrades[].unlocks_unit 推导“在哪里训练 / 解锁”
	for b_id in _cfg.keys():
		var bc: Dictionary = _cfg[b_id]
		if bc.get("type", -1) != 1:
			continue
		var bname: String = str(bc.get("name", "建筑"))
		for p in bc.get("produces", []):
			var pid: int = p.get("unit_id", -1)
			if not _producers.has(pid):
				_producers[pid] = []
			_producers[pid].append({ "name": bname, "kind": "produce", "note": p.get("cooldown", 0.0), "icon": _icon_for(b_id) })
		for up in bc.get("upgrades", []):
			var unlock_ids: Array = []
			if up.has("unlocks_units") and up["unlocks_units"] is Array:
				unlock_ids = up["unlocks_units"]
			elif up.has("unlocks_unit"):
				unlock_ids = [up["unlocks_unit"]]
			for u_id in unlock_ids:
				if int(u_id) < 0:
					continue
				# 若该建筑已直接“生产”此单位（produces 同时含 unlock 的冗余写法），跳过
				var dup := false
				for src in _producers.get(u_id, []):
					if src.get("kind") == "produce" and src.get("name") == bname:
						dup = true
						break
				if dup:
					continue
				if not _producers.has(u_id):
					_producers[u_id] = []
				_producers[u_id].append({ "name": bname, "kind": "unlock", "note": up.get("level", 0), "icon": _icon_for(b_id) })


# ═══════════ 画布 ═══════════
func _build_canvas() -> void:
	_root = self
	_canvas = Control.new()
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(_canvas)

	# 背景
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.055, 0.045, 0.035)
	_canvas.add_child(bg)

	var bg_panel := Control.new()
	bg_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg_panel.draw.connect(func():
		var r := Rect2(Vector2.ZERO, Vector2(DESIGN_W, DESIGN_H))
		bg_panel.draw_rect(r, Color(UITheme.INK, 0.55))
		bg_panel.draw_rect(r.grow(-1), Color(UITheme.GOLD, 0.35), false, 2.0)
	)
	_canvas.add_child(bg_panel)

	# 适配比例（同主菜单）；手机端不再整体缩放，直接按 dp 排版
	if not _mobile:
		_build_scale_fit()

	# 顶部标题与返回按钮（放在缩放容器里）
	_make_header()


# 等比适配：min(宽 / 2400, 高 / 1400) 缩放并居中
func _build_scale_fit() -> void:
	var vs := get_viewport().get_visible_rect().size
	var s := minf(vs.x / float(DESIGN_W), vs.y / float(DESIGN_H))
	var panel := Control.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.add_child(panel)
	panel.scale = Vector2(s, s)
	panel.position = (vs - Vector2(DESIGN_W, DESIGN_H) * s) / 2.0
	_canvas = panel


func _make_header() -> void:
	if _mobile:
		var m_title := UITheme.make_section_title("📖 单位图鉴", UITheme.GOLD, UILayout.font_dp(15.0))
		m_title.position = Vector2(UILayout.dp(6.0), UILayout.dp(4.0))
		m_title.size = Vector2(UILayout.dp(260.0), UILayout.dp(22.0))
		_canvas.add_child(m_title)

		var m_back := Button.new()
		m_back.text = "← 返回"
		m_back.position = Vector2(get_viewport().get_visible_rect().size.x - UILayout.dp(76.0), UILayout.dp(4.0))
		m_back.size = Vector2(UILayout.dp(70.0), UILayout.dp(22.0))
		UITheme.apply_muted_button(m_back, UILayout.font_dp(10.0))
		m_back.focus_mode = Control.FOCUS_NONE
		m_back.pressed.connect(func():
			get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
		)
		_canvas.add_child(m_back)
		return

	var title := UITheme.make_section_title("📖 单位图鉴 · 中世纪兵种百科", UITheme.GOLD, 40)
	title.position = Vector2(70, 46)
	title.size = Vector2(900, 60)
	_canvas.add_child(title)

	var sub := Label.new()
	UITheme.apply_label(sub, 18, UITheme.PARCHMENT)
	sub.text = "点击左侧列表查看任意单位 / 建筑 / 资源的详细属性"
	sub.position = Vector2(72, 118)
	sub.size = Vector2(700, 30)
	_canvas.add_child(sub)

	var back := Button.new()
	back.text = "← 返回主菜单"
	back.position = Vector2(DESIGN_W - 330, 52)
	back.size = Vector2(270, 66)
	UITheme.apply_muted_button(back, 20)
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(func():
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
	)
	_canvas.add_child(back)


# ═══════════ 分类标签页 ═══════════
func _build_tabs() -> void:
	if _mobile:
		var grid := GridContainer.new()
		grid.columns = 6
		grid.position = Vector2(UILayout.dp(6.0), UILayout.dp(29.0))
		grid.add_theme_constant_override("h_separation", int(UILayout.dp(2.0)))
		grid.add_theme_constant_override("v_separation", int(UILayout.dp(2.0)))
		_canvas.add_child(grid)
		for tab in TAB_ORDER:
			var key: String = tab[0]
			var label: String = tab[1]
			var emoji := _tab_icon(key)
			var btn := Button.new()
			btn.text = "%s %s" % [emoji, label]
			btn.custom_minimum_size = Vector2(UILayout.dp(52.0), UILayout.dp(24.0))
			btn.size = btn.custom_minimum_size
			btn.focus_mode = Control.FOCUS_NONE
			btn.set_meta("tab", key)
			btn.pressed.connect(_on_tab_pressed.bind(key))
			grid.add_child(btn)
			_tab_buttons.append(btn)
			_tab_to_btn[key] = btn
		return

	var w := 196.0
	var gap := 12.0
	var total := float(TAB_ORDER.size()) * w + float(TAB_ORDER.size() - 1) * gap
	var x := (DESIGN_W - total) / 2.0
	var y := 168.0
	for tab in TAB_ORDER:
		var key: String = tab[0]
		var label: String = tab[1]
		var emoji := _tab_icon(key)
		var btn := Button.new()
		btn.text = "%s %s" % [emoji, label]
		btn.position = Vector2(x, y)
		btn.size = Vector2(w, 64)
		btn.custom_minimum_size = Vector2(w, 64)
		btn.focus_mode = Control.FOCUS_NONE
		btn.set_meta("tab", key)
		btn.pressed.connect(_on_tab_pressed.bind(key))
		_canvas.add_child(btn)
		_tab_buttons.append(btn)
		_tab_to_btn[key] = btn
		x += w + gap


func _tab_icon(key: String) -> String:
	match key:
		"all": return "📚"
		"military": return "⚔️"
		"siege": return "🏰"
		"navy": return "⚓"
		"merchant": return "🏪"
		"official": return "📜"
		"religion": return "⛪"
		"animal": return "🐾"
		"economy": return "🌾"
		"building": return "🏛️"
		"resource": return "⛏️"
		_: return "❓"


func _on_tab_pressed(key: String) -> void:
	_switch_tab(key)


func _style_tab(btn: Button, selected: bool) -> void:
	var st := StyleBoxFlat.new()
	st.bg_color = Color(UITheme.INK, 0.9)
	st.set_corner_radius_all(10)
	st.set_border_width_all(2)
	if selected:
		st.border_color = UITheme.GOLD
		btn.add_theme_color_override("font_color", UITheme.GOLD)
		btn.add_theme_color_override("font_hover_color", UITheme.GOLD)
	else:
		st.border_color = Color(UITheme.STONE, 0.45)
		btn.add_theme_color_override("font_color", UITheme.PARCHMENT)
		btn.add_theme_color_override("font_hover_color", UITheme.GOLD)
	btn.add_theme_stylebox_override("normal", st)
	btn.add_theme_stylebox_override("hover", st.duplicate())
	btn.add_theme_stylebox_override("pressed", st.duplicate())
	btn.add_theme_stylebox_override("disabled", st.duplicate())
	btn.add_theme_font_size_override("font_size", UILayout.font_dp(8.5) if _mobile else 20)


func _switch_tab(key: String) -> void:
	_cur_tab = key
	for tab in TAB_ORDER:
		var k: String = tab[0]
		_style_tab(_tab_to_btn[k], k == key)
	if key == "all":
		var all_ids: Array = []
		for id in _cfg.keys():
			all_ids.append(id)
		all_ids.sort()
		_current_ids = all_ids
	else:
		_current_ids = (CLASS_GROUPS[key] as Array).duplicate()
	_refresh_list()
	if _current_ids.size() > 0:
		_select(_current_ids[0])
	else:
		_select(-1)


# ═══════════ 左侧列表 ═══════════
var _list_panel: Control
var _list_head: Label
var _list_scroll: ScrollContainer
var _list_rows: VBoxContainer

func _build_list_panel() -> void:
	_list_panel = Panel.new()
	if _mobile:
		var vp := get_viewport().get_visible_rect().size
		var y := UILayout.dp(84.0)
		var list_w := UILayout.dp(228.0)
		_list_panel.position = Vector2(UILayout.dp(4.0), y)
		_list_panel.size = Vector2(list_w, vp.y - y - UILayout.dp(4.0))
	else:
		_list_panel.position = Vector2(66, 266)
		_list_panel.size = Vector2(880, 1056)
	_list_panel.add_theme_stylebox_override("panel", UITheme.panel_style(16, 2, 0.9))
	_canvas.add_child(_list_panel)

	_list_head = Label.new()
	if _mobile:
		UITheme.apply_label(_list_head, UILayout.font_dp(10.0), UITheme.GOLD)
		_list_head.position = Vector2(UILayout.dp(5.0), UILayout.dp(4.0))
		_list_head.size = Vector2(_list_panel.size.x - UILayout.dp(10.0), UILayout.dp(18.0))
	else:
		UITheme.apply_label(_list_head, 22, UITheme.GOLD)
		_list_head.position = Vector2(28, 24)
		_list_head.size = Vector2(820, 34)
	_list_panel.add_child(_list_head)

	var scroll := ScrollContainer.new()
	if _mobile:
		scroll.position = Vector2(UILayout.dp(3.0), UILayout.dp(24.0))
		scroll.size = Vector2(_list_panel.size.x - UILayout.dp(6.0), _list_panel.size.y - UILayout.dp(28.0))
		scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	else:
		scroll.position = Vector2(18, 78)
		scroll.size = Vector2(846, 952)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list_panel.add_child(scroll)
	_list_scroll = scroll

	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", int(UILayout.dp(3.0)) if _mobile else 8)
	scroll.add_child(rows)
	_list_rows = rows


func _refresh_list() -> void:
	for c in _list_rows.get_children():
		c.queue_free()
	_row_data.clear()
	var total_all := _cfg.size()
	var cur: int = _current_ids.size()
	_list_head.text = "单位列表（本类 %d / 共 %d 种）" % [cur, total_all]
	for id in _current_ids:
		_add_row(id)


func _add_row(id: int) -> void:
	var cfg: Dictionary = _cfg.get(id, {})
	if cfg.is_empty():
		return
	var btn := Button.new()
	if _mobile:
		btn.custom_minimum_size = Vector2(0, UILayout.dp(34.0))
	else:
		btn.custom_minimum_size = Vector2(0, 68)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.focus_mode = Control.FOCUS_NONE
	btn.text = ""
	_list_rows.add_child(btn)

	var icon := Label.new()
	icon.text = _icon_for(id)
	if _mobile:
		UITheme.apply_label(icon, UILayout.font_dp(14.0), UITheme.PARCHMENT)
		icon.position = Vector2(UILayout.dp(2.0), 0)
		icon.size = Vector2(UILayout.dp(24.0), UILayout.dp(34.0))
	else:
		UITheme.apply_label(icon, 26, UITheme.PARCHMENT)
		icon.position = Vector2(14, 0)
		icon.size = Vector2(60, 68)
	icon.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(icon)

	var name_l := Label.new()
	name_l.text = str(cfg.get("name", "?"))
	if _mobile:
		UITheme.apply_label(name_l, UILayout.font_dp(10.0), UITheme.PARCHMENT)
		name_l.position = Vector2(UILayout.dp(28.0), 0)
		name_l.size = Vector2(_list_panel.size.x - UILayout.dp(32.0), UILayout.dp(34.0))
	else:
		UITheme.apply_label(name_l, 23, UITheme.PARCHMENT)
		name_l.position = Vector2(92, 0)
		name_l.size = Vector2(470, 68)
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(name_l)

	if not _mobile:
		var info := Label.new()
		info.text = _row_summary(cfg)
		UITheme.apply_label(info, 15, Color(UITheme.STONE).lightened(0.25))
		info.position = Vector2(548, 0)
		info.size = Vector2(300, 68)
		info.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		info.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		info.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(info)
		_row_data[id] = { "btn": btn, "name": name_l, "info": info }
	else:
		_row_data[id] = { "btn": btn, "name": name_l, "info": null }

	btn.pressed.connect(_select.bind(id))
	_refresh_row_style(id, false)


func _row_summary(cfg: Dictionary) -> String:
	var parts: Array[String] = []
	if cfg.has("max_health"):
		parts.append("❤️ %s" % _num(cfg.max_health))
	if cfg.get("attack", 0) > 0:
		parts.append("⚔️ %s" % _num(cfg.attack))
	if parts.is_empty():
		parts.append("无战斗属性")
	return "   ".join(parts)


func _refresh_row_style(id: int, sel: bool) -> void:
	var row: Dictionary = _row_data.get(id, {})
	if row.is_empty():
		return
	var btn: Button = row["btn"]
	var name_l: Label = row["name"]
	var st := StyleBoxFlat.new()
	st.bg_color = Color(UITheme.INK, 0.7)
	st.set_corner_radius_all(8)
	st.set_border_width_all(1)
	if sel:
		st.bg_color = Color(UITheme.SAPPHIRE, 0.16)
		st.border_color = UITheme.GOLD
		name_l.add_theme_color_override("font_color", UITheme.GOLD)
	else:
		st.border_color = Color(UITheme.STONE, 0.28)
		name_l.add_theme_color_override("font_color", UITheme.PARCHMENT)
	btn.add_theme_stylebox_override("normal", st)
	btn.add_theme_stylebox_override("hover", st)
	btn.add_theme_stylebox_override("pressed", st)
	btn.add_theme_stylebox_override("disabled", st)


# ═══════════ 右侧详情 ═══════════
var _detail_panel: Control
var _detail_body: VBoxContainer

func _build_detail_panel() -> void:
	_detail_panel = Panel.new()
	if _mobile:
		var vp := get_viewport().get_visible_rect().size
		var y := UILayout.dp(84.0)
		var x := UILayout.dp(228.0) + UILayout.dp(8.0)
		_detail_panel.position = Vector2(x, y)
		_detail_panel.size = Vector2(vp.x - x - UILayout.dp(4.0), vp.y - y - UILayout.dp(4.0))
	else:
		_detail_panel.position = Vector2(974, 266)
		_detail_panel.size = Vector2(1360, 1056)
	_detail_panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	_canvas.add_child(_detail_panel)

	var body := VBoxContainer.new()
	if _mobile:
		var scroll := ScrollContainer.new()
		scroll.position = Vector2(UILayout.dp(3.0), UILayout.dp(3.0))
		scroll.size = Vector2(_detail_panel.size.x - UILayout.dp(6.0), _detail_panel.size.y - UILayout.dp(6.0))
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_detail_panel.add_child(scroll)
		body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		body.add_theme_constant_override("separation", int(UILayout.dp(2.0)))
		scroll.add_child(body)
	else:
		body.position = Vector2(40, 36)
		body.size = Vector2(1280, 984)
		body.add_theme_constant_override("separation", 8)
		_detail_panel.add_child(body)
	_detail_body = body


func _select(id: int) -> void:
	if _sel_id == id:
		return
	if _sel_id >= 0:
		_refresh_row_style(_sel_id, false)
	_sel_id = id
	if id >= 0:
		_refresh_row_style(id, true)
		_render_detail(id)
	else:
		_render_detail(-1)


# 详情整体渲染（动态内容全部放 _detail_body 的 VBox）
func _render_detail(id: int) -> void:
	for c in _detail_body.get_children():
		c.queue_free()
	if id < 0:
		_add_line("← 请选择左侧实体", UITheme.STONE, 20, 40)
		return
	var cfg: Dictionary = _cfg.get(id, {})
	if cfg.is_empty():
		_add_line("数据缺失", UITheme.VERMILION, 20, 40)
		return

	# ── 标题行：图标 + 名称 + 徽标 ──
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", int(UILayout.dp(4.0)) if _mobile else 16)
	_detail_body.add_child(head)

	var emoji := Label.new()
	emoji.text = _icon_for(id)
	if _mobile:
		UITheme.apply_label(emoji, UILayout.font_dp(16.0), UITheme.PARCHMENT)
		emoji.custom_minimum_size = Vector2(UILayout.dp(22.0), UILayout.dp(24.0))
	else:
		UITheme.apply_label(emoji, 44, UITheme.PARCHMENT)
		emoji.custom_minimum_size = Vector2(72, 72)
	head.add_child(emoji)

	var name_l := Label.new()
	name_l.text = str(cfg.get("name", "?"))
	if _mobile:
		UITheme.apply_label(name_l, UILayout.font_dp(13.0), UITheme.GOLD)
		name_l.custom_minimum_size = Vector2(0, UILayout.dp(24.0))
	else:
		UITheme.apply_label(name_l, 42, UITheme.GOLD)
		name_l.custom_minimum_size = Vector2(620, 72)
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(name_l)

	var nation := _nation_tag(id)
	if nation != "":
		var tag := Label.new()
		tag.text = nation
		if _mobile:
			UITheme.apply_label(tag, UILayout.font_dp(9.0), UITheme.PARCHMENT)
			tag.custom_minimum_size = Vector2(0, UILayout.dp(24.0))
		else:
			UITheme.apply_label(tag, 17, UITheme.PARCHMENT)
			tag.custom_minimum_size = Vector2(0, 72)
		tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		head.add_child(tag)

	# ── 身份 / 分类标签行 ──
	var ident := _identity_line(cfg, id)
	var ident_l := Label.new()
	ident_l.text = ident
	if _mobile:
		UITheme.apply_label(ident_l, UILayout.font_dp(9.0), Color(UITheme.PARCHMENT).darkened(0.12))
		ident_l.custom_minimum_size = Vector2(0, UILayout.dp(15.0))
		ident_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	else:
		UITheme.apply_label(ident_l, 17, Color(UITheme.PARCHMENT).darkened(0.12))
		ident_l.custom_minimum_size = Vector2(0, 30)
	_detail_body.add_child(ident_l)

	# ── 生产 / 建造价格 ──
	var cost_txt := _cost_string(cfg)
	if cost_txt != "":
		var cost_tag := "建造价格" if int(cfg.get("type", 2)) == 1 else "生产价格"
		_add_pair(cost_tag, cost_txt)

	# ── 分隔线 ──
	_add_rule()

	# ── 属性网格（资源无战斗属性，跳过统计块避免双分割线） ──
	if int(cfg.get("type", 2)) != 0:
		_add_stats(cfg)
		_add_rule()

	# ── 生产来源 / 用途详情 ──
	_add_detail_lines(cfg, id)


func _identity_line(cfg: Dictionary, id: int) -> String:
	var type: int = cfg.get("type", 2)
	var t_name: String = TYPE_NAMES.get(type, "单位")
	var role := _role_hint(cfg)
	var nation := _nation_tag(id)
	var out := "ID %d · %s" % [id, t_name]
	var cl := _class_label_of(id)
	if cl != t_name:
		out += " · " + cl
	if role != "":
		out += " · " + role
	if nation != "":
		out += " · " + nation
	return out


func _class_label_of(id: int) -> String:
	for key in CLASS_GROUPS.keys():
		if id in (CLASS_GROUPS[key] as Array):
			return _class_cn(key)
	return _class_cn("resource")


func _class_cn(key: String) -> String:
	match key:
		"military": return "军事单位"
		"siege": return "攻城单位"
		"navy": return "海军单位"
		"economy": return "经济单位"
		"merchant": return "贸易商人"
		"official": return "朝廷官员"
		"religion": return "宗教单位"
		"animal": return "野生动物"
		"building": return "建筑"
		"resource": return "野外资源"
		_: return "单位"


func _nation_tag(id: int) -> String:
	return NATION_TAGS.get(id, "")


func _role_hint(cfg: Dictionary) -> String:
	var parts: Array[String] = []
	if cfg.get("type", 2) == 2:
		if cfg.get("water_capable", false):
			parts.append("可在水面行动")
		if cfg.get("can_move", false):
			parts.append("移动单位")
		elif cfg.has("can_move"):
			parts.append("驻守单位")
	if cfg.get("merchant_type", "") != "":
		var m: String = cfg.merchant_type
		if UITheme.RESOURCE_NAMES.has(m):
			parts.append("主营%s贸易" % str(UITheme.RESOURCE_NAMES[m]))
	if cfg.get("official_type", "") != "":
		var o: String = cfg.official_type
		parts.append(OFFICIAL_ROLE.get(o, ""))
	if cfg.get("special_type", "") == "monk":
		parts.append("修士")
	if cfg.get("animal_type", "") != "":
		parts.append("可猎杀")
	return "，".join(parts)


func _icon_for(id: int) -> String:
	if EMOJI.has(id):
		return EMOJI[id]
	return UITheme.entity_emoji(id, _cfg.get(id, {}).get("type", -1))


# 生成 "资源图标 数量" 串；无 cost（野外资源/野生动物等）返回空串
func _cost_string(cfg: Dictionary) -> String:
	var cost = cfg.get("cost")
	if not (cost is Dictionary) or cost.is_empty():
		return ""
	var parts: Array[String] = []
	var order := ["gold", "wood", "stone", "food", "oil"]
	for r in order:
		if cost.has(r):
			parts.append("%s %s" % [
				str(UITheme.RESOURCE_ICONS.get(r, "·")),
				_num(cost[r]),
			])
	# 兜底：未在常规顺序里的资源键（如人口/特殊资源）补在末尾，避免漏显示
	for key in cost.keys():
		if not order.has(key):
			parts.append("%s %s" % [
				str(UITheme.RESOURCE_ICONS.get(key, "·")),
				_num(cost[key]),
			])
	return "　".join(parts)


# ── 详情辅助 ──
func _add_rule() -> void:
	var r := ColorRect.new()
	r.custom_minimum_size = Vector2(0, UILayout.dp(1.0) if _mobile else 2)
	r.color = Color(UITheme.GOLD, 0.35)
	_detail_body.add_child(r)


func _add_line(text: String, color: Color, fs: int = 20, min_h: int = 40) -> void:
	var l := Label.new()
	l.text = text
	if _mobile:
		var mfs := UILayout.font_dp(9.5) if fs >= 20 else UILayout.font_dp(9.0)
		UITheme.apply_label(l, mfs, color)
		l.custom_minimum_size = Vector2(0, UILayout.dp(14.0))
	else:
		UITheme.apply_label(l, fs, color)
		l.custom_minimum_size = Vector2(0, min_h)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_body.add_child(l)


func _add_pair(title: String, value: String) -> void:
	var l := Label.new()
	UITheme.apply_label(l, UILayout.font_dp(9.5) if _mobile else 18, UITheme.PARCHMENT)
	var icon = ATTR_ICONS.get(title, "")
	if icon != "":
		l.text = "%s %s：%s" % [icon, title, value]
	else:
		l.text = "%s：%s" % [title, value]
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.custom_minimum_size = Vector2(0, UILayout.dp(12.0) if _mobile else 32)
	_detail_body.add_child(l)


# ── 属性数值 ──
func _add_stats(cfg: Dictionary) -> void:
	var t = cfg.get("type", 2)
	if t == 0:
		return
	var atk = cfg.get("attack", 0)
	var ass = cfg.get("attack_speed", 0.0)
	var dps := 0.0
	if atk > 0 and ass > 0:
		dps = float(atk) / float(ass)
	var arm_parts: Array[String] = []
	if cfg.get("melee_armor", 0) > 0:
		arm_parts.append("近战护甲 %s" % _num(cfg.melee_armor))
	if cfg.get("shield_armor", 0) > 0:
		arm_parts.append("远程护甲 %s" % _num(cfg.shield_armor))
	var def := "，".join(arm_parts)
	var rng := ""
	if cfg.get("attack_range", 0) > 0:
		rng = "攻击距离 %s" % _num(cfg.attack_range)
	if cfg.has("vision_range"):
		if rng == "":
			rng = "视野 %s" % _num(cfg.vision_range)
		else:
			rng += " · 视野 %s" % _num(cfg.vision_range)
	if rng == "":
		rng = "—"
	if cfg.get("max_health", 0) > 0:
		_add_pair("耐久 / 生命", "%s" % _num(cfg.max_health))
	else:
		_add_pair("耐久 / 生命", "—")
	_add_pair("攻击 / 间隔", "%s  /  %.1f 秒" % [(_num(atk) if atk > 0 else "—"), ass])
	_add_pair("秒伤 DPS", ("%.1f" % dps if dps > 0 else "—"))
	_add_pair("范围 / 视野", rng)
	if def != "":
		_add_pair("护甲", def)
	if cfg.has("speed") and t == 2:
		_add_pair("移动速度", _num(cfg.speed))
	if cfg.has("damage_radius") and cfg.damage_radius > 0:
		_add_pair("溅射半径", _num(cfg.damage_radius))
	if t == 1 and cfg.has("body_radius"):
		_add_pair("占地半径", _num(cfg.body_radius))


func _num(v) -> String:
	var f := float(v)
	var s := "%.2f" % f
	while s.ends_with("0"):
		s = s.substr(0, s.length() - 1)
	if s.ends_with("."):
		s = s.substr(0, s.length() - 1)
	return s


# ── 详细文字块 ──
func _add_detail_lines(cfg: Dictionary, id: int) -> void:
	var t: int = cfg.get("type", 2)
	# 描述
	_add_line(str(DESC.get(id, "没有更多说明。")), UITheme.PARCHMENT, 20, 48)

	if t == 0:
		var rt: String = str(cfg.get("resource_type", ""))
		var rt_cn := str(UITheme.RESOURCE_NAMES.get(rt, rt))
		_add_pair("产出资源", rt_cn)
		if cfg.has("gather_amount"):
			_add_pair("单次采集量", "%s / 次" % _num(cfg.gather_amount))
		if cfg.has("regeneration_rate"):
			_add_pair("恢复速率", "每秒 +%s" % _num(cfg.regeneration_rate))
		return

	if t == 1:
		_add_building_lines(cfg, id)
	else:
		_add_unit_lines(cfg, id)


func _unit_produce_note(cfg: Dictionary, id: int) -> String:
	# “哪里训练”：优先 produce 来源，其次解锁来源
	var srcs: Array = _producers.get(id, [])
	var parts: Array[String] = []
	for s in srcs:
		var n: String = s.name
		var icon: String = str(s.get("icon", ""))
		var note: String = ""
		if s.kind == "produce":
			note = "%s 秒" % _fmt_cd(s.note)
			parts.append("%s %s（训练 %s）" % [icon, n, note])
		else:
			parts.append("%s %s（升级解锁）" % [icon, n])
	if parts.is_empty():
		return ""
	return "，".join(parts)


func _fmt_cd(v) -> String:
	var f := float(v)
	if absf(f - round(f)) < 0.01:
		return str(int(round(f)))
	return _num(f)


func _add_building_lines(cfg: Dictionary, id: int) -> void:
	# 训练产出
	var prods: Array = cfg.get("produces", [])
	var prod_ids: Array = []
	if prods.size() > 0:
		var l := _add_info_header("📋 可训练 / 可产出")
		_detail_body.add_child(l)
		for p in prods:
			var pid: int = p.get("unit_id", -1)
			prod_ids.append(pid)
			var pc: Dictionary = _cfg.get(pid, {})
			var nm := str(pc.get("name", "单位 %d" % pid))
			_add_pair("  · " + _icon_for(pid) + " " + nm, "冷却 %s 秒，队列上限 %s" % [_fmt_cd(p.get("cooldown", 0)), p.get("queue_limit", 1)])

	# 升级解锁：produces 里已能训练的单位不重复列出
	var ups: Array = cfg.get("upgrades", [])
	var unlocks: Array = []
	for u in ups:
		var unlock_ids: Array = []
		if u.has("unlocks_units") and u["unlocks_units"] is Array:
			unlock_ids = u["unlocks_units"]
		elif u.has("unlocks_unit"):
			unlock_ids = [u["unlocks_unit"]]
		for uid in unlock_ids:
			if int(uid) < 0 or int(uid) in prod_ids:
				continue
			unlocks.append({"level": u.get("level", 1), "unit_id": int(uid)})
	if unlocks.size() > 0:
		var l2 := _add_info_header("📈 升级解锁")
		_detail_body.add_child(l2)
		for item in unlocks:
			var uid2: int = int(item["unit_id"])
			var uc: Dictionary = _cfg.get(uid2, {})
			var unm := str(uc.get("name", "单位 %d" % uid2))
			_add_pair("  · Lv.%s %s" % [item["level"], _icon_for(uid2)], unm)
	elif prods.size() == 0 and ups.size() > 0:
		# 无新增兵种的建筑：仅提示可升级强化
		var l3 := _add_info_header("📈 可升级 %d 级（强化）" % ups.size())
		_detail_body.add_child(l3)
		_add_line("逐级强化耐久、护甲与攻击。", Color(UITheme.STONE).lightened(0.2), 16, 32)

	# 其它被动
	var passive := _building_passives(cfg)
	if passive != "":
		_add_pair("特性", passive)


func _add_info_header(text: String) -> Label:
	var l := Label.new()
	l.text = text
	if _mobile:
		UITheme.apply_label(l, UILayout.font_dp(10.0), UITheme.GOLD)
		l.custom_minimum_size = Vector2(0, UILayout.dp(15.0))
	else:
		UITheme.apply_label(l, 19, UITheme.GOLD)
		l.custom_minimum_size = Vector2(0, 30)
	return l


func _building_passives(cfg: Dictionary) -> String:
	var parts: Array[String] = []
	if cfg.has("population_bonus") and cfg.population_bonus > 0:
		parts.append("人口上限 +%s" % _num(cfg.population_bonus))
	if cfg.has("storage_bonus") and cfg.storage_bonus > 0:
		parts.append("仓储上限 +%s" % _num(cfg.storage_bonus))
	if cfg.get("wall_only", false):
		parts.append("仅可建造于城墙旁")
	if cfg.has("regeneration_rate"):
		parts.append("每秒自愈 +%s" % _num(cfg.regeneration_rate))
	if parts.is_empty():
		return ""
	return "，".join(parts)


func _add_unit_lines(cfg: Dictionary, id: int) -> void:
	# 训练来源
	var src := _unit_produce_note(cfg, id)
	if src != "":
		_add_pair("训练来源", src)

	# 经济角色
	if cfg.get("animal_type", "") != "":
		_add_pair("类型", _animal_cn(str(cfg.animal_type)))
		_add_pair("狩猎产出", "食物 +%s" % _num(cfg.get("food_reward", 0)))
	if cfg.get("gatherable_resources", []).size() > 0:
		var gres: Array = cfg.gatherable_resources
		var gn: Array[String] = []
		for r in gres:
			gn.append("%s %s" % [UITheme.RESOURCE_ICONS.get(r, "·"), UITheme.RESOURCE_NAMES.get(r, r)])
		_add_pair("可采集", "，".join(gn))
	if cfg.has("max_cargo"):
		_add_pair("载货量", _num(cfg.max_cargo))

	# 商人 / 官员 / 特殊
	if cfg.get("merchant_type", "") != "":
		var m := str(cfg.merchant_type)
		_add_pair("贸易品类", "%s %s" % [UITheme.RESOURCE_ICONS.get(m, ""), UITheme.RESOURCE_NAMES.get(m, m)])
	if cfg.get("official_type", "") != "":
		var o := str(cfg.official_type)
		_add_pair("官职", "%s（%s）" % [OFFICIAL_NAME.get(o, o), OFFICIAL_ROLE.get(o, "")])
		if cfg.has("salary"):
			_add_pair("俸禄", "每周期 %s 黄金" % _num(cfg.salary))
		var aura := _official_aura(cfg)
		if aura != "":
			_add_pair("光环", aura)
	if cfg.get("special_type", "") == "monk":
		_add_pair("定位", "由修道院培养的修士，特殊施法单位")
	if cfg.get("special_type", "") == "grandmaster":
		_add_pair("定位", "武学宗师，近战压制")
	if cfg.get("special_type", "") == "elder":
		_add_pair("定位", "无视目标护甲的高阶修士")
	if cfg.get("multiple_process", []).size() > 0:
		_add_pair("特殊机制", "多重攻击（单次出手复数弩箭）")
	if cfg.get("piercing", false):
		_add_pair("特殊机制", "对兵海有额外穿透效果")

	# 战斗标签
	var combat: Array[String] = []
	if cfg.get("ignore_armor", false):
		combat.append("无视护甲")
	if cfg.get("ignore_building_armor", false):
		combat.append("无视建筑护甲")
	if cfg.get("damage_radius", 0) > 0:
		combat.append("溅射伤害")
	if cfg.get("attack_range", 0) >= 3.0:
		combat.append("远程")
	if cfg.get("attack", 0) > 0 and cfg.get("attack_range", 0) < 3.0:
		combat.append("近战")
	if combat.size() > 0:
		_add_pair("战斗标签", "，".join(combat))

	# 目标类型说明
	var tt = cfg.get("target_type", -1)
	var tt_text := ""
	match tt:
		0: tt_text = "仅能攻击建筑 / 资源"
		1: tt_text = "优先攻击建筑"
		2: tt_text = "优先攻击士兵"
		3: tt_text = "优先攻击远程 / 攻城器"
		_: tt_text = ""
	if tt_text != "":
		_add_pair("索敌倾向", tt_text)


func _official_aura(cfg: Dictionary) -> String:
	var parts: Array[String] = []
	if cfg.has("aura_radius") and cfg.aura_radius > 0:
		parts.append("影响范围 %s" % _num(cfg.aura_radius))
	if cfg.has("aura_attack_speed") and cfg.aura_attack_speed > 0:
		parts.append("友军攻速 +%d%%" % int(cfg.aura_attack_speed * 100.0))
	if cfg.has("speed_bonus") and cfg.speed_bonus > 0:
		parts.append("友军移速 +%d%%" % int(cfg.speed_bonus * 100.0))
	if cfg.has("melee_armor_bonus") and cfg.melee_armor_bonus > 0:
		parts.append("友军近战护甲 +%s" % _num(cfg.melee_armor_bonus))
	if cfg.has("shield_armor_bonus") and cfg.shield_armor_bonus > 0:
		parts.append("友军远程护甲 +%s" % _num(cfg.shield_armor_bonus))
	if cfg.has("efficiency_multiplier") and cfg.efficiency_multiplier > 1.0:
		parts.append("周边采集效率 ×%s" % _num(cfg.efficiency_multiplier))
	return "，".join(parts)


func _animal_cn(k: String) -> String:
	match k:
		"cow": return "牛"
		"pig": return "猪"
		"sheep": return "羊"
		"fish": return "鱼"
		_: return k
