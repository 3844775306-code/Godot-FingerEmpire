class_name TrainingMultiDirector
extends Node

# 训练营 2v2 / 1v2 的轻量目标层：
# - 显示团队目标和盟友状态
# - 在标准 2v2 胜负判定后记录训练进度，并用自己的结算卡替换普通统计面板
# - 2v2 走“摧毁两座敌城”；1v2 同样要求拆掉两座敌城

const TrainingDataScript = preload("res://scripts/data/TrainingData.gd")
const TrainingProgressScript = preload("res://scripts/core/TrainingProgress.gd")

var bm = null
var _card: Panel
var _status: Label
var _result_layer: CanvasLayer
var _recorded := false
var _elapsed := 0.0

func _ready() -> void:
	bm = get_parent()
	_build_objective()
	set_process(true)

func _build_objective() -> void:
	var mobile := InputSource.use_mobile_ui()
	var w: float = UILayout.dp(270.0) if mobile else 560.0
	var h: float = UILayout.dp(92.0) if mobile else 128.0
	var x: float = UILayout.dp(8.0) if mobile else 28.0
	var y: float = UILayout.dp(46.0) if mobile else 240.0
	var layer := CanvasLayer.new()
	layer.layer = 30
	add_child(layer)
	_card = Panel.new()
	_card.position = Vector2(x, y)
	_card.size = Vector2(w, h)
	_card.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	layer.add_child(_card)
	var title := Label.new()
	title.text = "🎓 新兵训练营 · %s" % ("2v2 联军协同" if GameSettings.training_level_id == "t25" else "1v2 孤军奋战")
	title.position = Vector2(UILayout.dp(8.0) if mobile else 16, UILayout.dp(5.0) if mobile else 10)
	title.size = Vector2(w - 20.0, UILayout.dp(20.0) if mobile else 28.0)
	UITheme.apply_label(title, UILayout.font_dp(10.0) if mobile else 20, UITheme.GOLD)
	_card.add_child(title)
	_status = Label.new()
	_status.position = Vector2(UILayout.dp(8.0) if mobile else 16, UILayout.dp(26.0) if mobile else 46)
	_status.size = Vector2(w - (UILayout.dp(16.0) if mobile else 32.0),
		h - (UILayout.dp(30.0) if mobile else 54))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(_status, UILayout.font_dp(7.0) if mobile else 15, UITheme.PARCHMENT)
	_card.add_child(_status)

func _process(delta: float) -> void:
	if bm == null or not is_instance_valid(bm):
		return
	if not bm.game_over:
		_elapsed += delta
		_update_status()
		return
	if _recorded:
		return
	_recorded = true
	var won: bool = int(bm._team_castle_count.get(bm.enemy_team, 0)) <= 0 \
		and int(bm._team_castle_count.get(bm.player_team, 0)) > 0
	if won:
		var stars := 3 if _elapsed <= 600.0 else (2 if _elapsed <= 720.0 else 1)
		TrainingProgressScript.record_win(GameSettings.training_level_id, stars, _elapsed)
	if bm.game_over_panel != null and is_instance_valid(bm.game_over_panel):
		bm.game_over_panel.visible = false
	_show_result(won)
	set_process(false)

func _update_status() -> void:
	if _status == null:
		return
	var lines: Array = []
	lines.append("目标：摧毁两座敌方主城")
	var enemy_left := int(bm._team_castle_count.get(bm.enemy_team, 0))
	var ally_alive := false
	if bm.ai_players.has(1000):
		var c = bm.ai_players[1000].get("castle")
		ally_alive = c != null and is_instance_valid(c) and c.health > 0
	if GameSettings.training_level_id == "t25":
		lines.append("盟友英格兰：%s" % ("存活，正在作战" if ally_alive else "已失守"))
	lines.append("剩余敌方主城：%d / 2" % enemy_left)
	lines.append("提示：和盟友夹击同一座城；盟友基地遇袭时回防。")
	_status.text = "\n".join(lines)

func _show_result(won: bool) -> void:
	_result_layer = CanvasLayer.new()
	_result_layer.layer = 40
	bm.add_child(_result_layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	_result_layer.add_child(root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.72)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)
	var mobile := InputSource.use_mobile_ui()
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UITheme.card_style(
		UITheme.GOLD if won else UITheme.VERMILION))
	card.custom_minimum_size = Vector2(UILayout.dp(460.0) if mobile else 560.0, 0.0)
	card.anchor_left = 0.5
	card.anchor_right = 0.5
	card.anchor_top = 0.5
	card.anchor_bottom = 0.5
	card.offset_left = -(UILayout.dp(230.0) if mobile else 280.0)
	card.offset_right = (UILayout.dp(230.0) if mobile else 280.0)
	card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	card.grow_vertical = Control.GROW_DIRECTION_BOTH
	root.add_child(card)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	vb.add_theme_constant_override("margin_left", 22)
	vb.add_theme_constant_override("margin_right", 22)
	vb.add_theme_constant_override("margin_top", 18)
	vb.add_theme_constant_override("margin_bottom", 18)
	card.add_child(vb)
	var title := Label.new()
	title.text = "🎓 训练完成" if won else "💀 训练失败"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(title, UILayout.font_dp(20.0) if mobile else 26,
		UITheme.EMERALD if won else UITheme.VERMILION)
	vb.add_child(title)
	var level := TrainingDataScript.get_level(GameSettings.training_level_id)
	var name_label := Label.new()
	name_label.text = TrainingDataScript.display_name(level)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(name_label, UILayout.font_dp(11.0) if mobile else 17, UITheme.PARCHMENT)
	vb.add_child(name_label)
	var body := Label.new()
	body.text = ("你和盟友拆掉了两座敌城。" if won else "两座敌城还没有全部摧毁，或我方主城失守。") \
		+ "\n用时：%s" % _fmt_time(_elapsed)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(body, UILayout.font_dp(9.0) if mobile else 15, UITheme.PARCHMENT)
	vb.add_child(body)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 10)
	vb.add_child(buttons)
	if won and GameSettings.training_level_id == "t25":
		var next_btn := _button("高难 1v2 ▸", true, mobile)
		next_btn.pressed.connect(_on_next)
		buttons.add_child(next_btn)
	var retry := _button("重试", false, mobile)
	retry.pressed.connect(_on_retry)
	buttons.add_child(retry)
	var back := _button("返回训练营", false, mobile)
	back.pressed.connect(_on_back)
	buttons.add_child(back)
	UITheme.fade_in(root, 0.25)

func _button(text: String, primary: bool, mobile: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(UILayout.dp(104.0) if mobile else 120.0,
		UILayout.dp(38.0) if mobile else 44.0)
	if primary:
		UITheme.apply_primary_button(b, UILayout.font_dp(10.0) if mobile else 15)
	else:
		UITheme.apply_button(b, UILayout.font_dp(10.0) if mobile else 15)
	return b

func _fmt_time(seconds: float) -> String:
	var s := maxi(0, int(seconds))
	return "%02d:%02d" % [s / 60, s % 60]

func _on_next() -> void:
	GameSettings.training_mode = true
	GameSettings.training_level_id = "t26"
	GameSettings.campaign_mode = true
	LoadingScreen.goto_scene("res://scenes/rts_battle.tscn")

func _on_retry() -> void:
	LoadingScreen.goto_scene("res://scenes/rts_battle.tscn")

func _on_back() -> void:
	GameSettings.training_mode = false
	GameSettings.training_level_id = ""
	get_tree().change_scene_to_file("res://scenes/training_menu.tscn")
