class_name TutorialHint
extends CanvasLayer

# 新手教程对局左上角的动态目标卡：只由主菜单「新手教程」启动对局时创建。
# 目标按当前局势推进：采集 → 民居 → 兵营 → 士兵 → 反推敌城。
# 玩家可以随时点「跳过教程」关闭，本局后续不再提示。
const COMBAT_IDS: Array = [
	11, 12, 13, 15, 16, 17, 18, 19,
	30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
	58, 59, 65, 66, 67, 68, 69
]
const HOUSE_ID: int = 28
const BARRACKS_ID: int = 21
const CASTLE_IDS: Array = [20, 53]
const REFRESH_INTERVAL: float = 0.4

var _card: Panel = null
var _title: Label = null
var _objective: Label = null
var _resources: Label = null
var _close_btn: Button = null
var _timer: float = 0.0
var _elapsed: float = 0.0
var _last_objective: String = ""
var _finished: bool = false

func _ready() -> void:
	layer = 30
	_build()
	set_process(true)

func _build() -> void:
	var mobile := InputSource.use_mobile_ui()
	var w: float = UILayout.dp(252.0) if mobile else 560.0
	var h: float = UILayout.dp(108.0) if mobile else 236.0
	var x: float = UILayout.dp(8.0) if mobile else 28.0
	var y: float = UILayout.dp(46.0) if mobile else 240.0

	_card = Panel.new()
	_card.name = "TutorialCard"
	_card.position = Vector2(x, y)
	_card.size = Vector2(w, h)
	_card.mouse_filter = Control.MOUSE_FILTER_STOP
	_card.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	add_child(_card)
	UITheme.fade_in(_card, 0.25)

	var title_size: int = UILayout.font_dp(10.0) if mobile else 20
	_title = Label.new()
	_title.text = "🎓 新手教程 · 当前目标"
	_title.position = Vector2(UILayout.dp(7.0) if mobile else 16, UILayout.dp(4.0) if mobile else 10)
	_title.size = Vector2(w - (UILayout.dp(56.0) if mobile else 112.0), UILayout.dp(18.0) if mobile else 30)
	UITheme.apply_label(_title, title_size, UITheme.GOLD)
	_card.add_child(_title)

	_close_btn = Button.new()
	_close_btn.text = "跳过"
	_close_btn.focus_mode = Control.FOCUS_NONE
	_close_btn.position = Vector2(w - (UILayout.dp(48.0) if mobile else 96.0),
		UILayout.dp(3.0) if mobile else 8.0)
	_close_btn.size = Vector2(UILayout.dp(40.0) if mobile else 80.0,
		UILayout.dp(19.0) if mobile else 34.0)
	UITheme.apply_muted_button(_close_btn, UILayout.font_dp(7.0) if mobile else 15)
	_close_btn.pressed.connect(_skip)
	_card.add_child(_close_btn)

	var body_size: int = UILayout.font_dp(8.0) if mobile else 17
	_objective = Label.new()
	_objective.position = Vector2(UILayout.dp(7.0) if mobile else 16,
		UILayout.dp(25.0) if mobile else 52)
	_objective.size = Vector2(w - (UILayout.dp(14.0) if mobile else 32.0),
		h - (UILayout.dp(48.0) if mobile else 98.0))
	_objective.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_objective.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	UITheme.apply_label(_objective, body_size, UITheme.PARCHMENT)
	_card.add_child(_objective)

	_resources = Label.new()
	_resources.position = Vector2(UILayout.dp(7.0) if mobile else 16,
		h - (UILayout.dp(20.0) if mobile else 40.0))
	_resources.size = Vector2(w - (UILayout.dp(14.0) if mobile else 32.0),
		UILayout.dp(16.0) if mobile else 28.0)
	UITheme.apply_label(_resources, UILayout.font_dp(7.0) if mobile else 14, UITheme.GOLD.lightened(0.1))
	_card.add_child(_resources)

func _process(delta: float) -> void:
	_elapsed += delta
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = REFRESH_INTERVAL
	_refresh()

func _refresh() -> void:
	if not GameSettings.tutorial_mode:
		queue_free()
		return
	var bm = get_tree().current_scene
	if bm == null or not bm.has_method("get_host_team"):
		return
	if not _finished and bool(bm.get("game_over")):
		_finished = true
		_set_objective("🏁 对局结束。点「跳过」关闭提示，回主菜单可以再开一局或重看教程。")
		return
	if _finished:
		return
	bm.call("_ensure_cache_fresh")
	var all: Array = bm.get("_all_entities")
	if all == null:
		return
	var host: int = int(bm.get_host_team())
	var houses: int = 0
	var barracks: int = 0
	var soldiers: int = 0
	var enemy_castles: int = 0
	for e in all:
		if not is_instance_valid(e):
			continue
		var eid: int = int(e.get("entity_id"))
		var team: int = int(e.get("team"))
		if team == host:
			if e is Building and float(e.get("build_timer")) <= 0.0:
				if eid == HOUSE_ID:
					houses += 1
				elif eid == BARRACKS_ID:
					barracks += 1
			elif e is Army and eid in COMBAT_IDS and float(e.get("health")) > 0.0:
				soldiers += 1
		elif e is Building and eid in CASTLE_IDS and float(e.get("health")) > 0.0:
			enemy_castles += 1

	var text: String = ""
	if _elapsed < 9.0 and houses < 2:
		text = "① 先派农民采集\n选中农民，右键树木采木材、右键金矿采黄金。木材和食物不要断。"
	elif houses < 2:
		text = "② 补民居，别卡人口\n先点空地取消选择，按 Q 进入民居建造，左键放 2 座民居。放下后附近农民会自动赶来施工，没农民到场进度会暂停。人口满了会直接停产。"
	elif barracks < 1:
		text = "③ 建造兵营\n先点空地取消选择，按 A 进入兵营建造，左键放在主城附近，方便回防。记得留农民给它施工。"
	elif soldiers < 6:
		text = "④ 训练 6 名士兵\n选中兵营训练士兵。前期只造农民会被 AI 第一波直接拆家。"
	elif enemy_castles > 0:
		text = "⑤ 反推敌方城堡\n框选士兵，按 F1 全选、F2 自动进攻；右键集火，摧毁敌方城堡即可获胜。"
	else:
		text = "🎉 敌方城堡已被摧毁，本局胜利！"
	_set_objective(text)
	_refresh_resources(bm)

func _set_objective(text: String) -> void:
	if text == _last_objective:
		return
	_last_objective = text
	_objective.text = text

func _refresh_resources(bm: Node) -> void:
	var res: Dictionary = bm.get("player_resources")
	if res == null:
		return
	_resources.text = "木 %d  金 %d  石 %d  粮 %d  人口 %d/%d" % [
		int(res.get("wood", 0)), int(res.get("gold", 0)), int(res.get("stone", 0)),
		int(res.get("food", 0)), int(bm.get("player_pop")), int(bm.get("player_max_pop"))
	]

func _skip() -> void:
	GameSettings.tutorial_mode = false
	queue_free()
