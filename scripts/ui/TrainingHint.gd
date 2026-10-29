class_name TrainingHint
extends CanvasLayer

# 训练营左上角知识卡：显示本关两个新概念和目标。
# 与 TutorialHint 一样只在单机训练关创建；按 H 或点“收起/展开”切换。

const TrainingDataScript = preload("res://scripts/data/TrainingData.gd")

var _card: Panel = null
var _toggle: Button = null
var _title: Label = null
var _body: Label = null
var _collapsed := false
var _full_height := 300.0
var _compact_height := 44.0

func _ready() -> void:
	layer = 30
	_build()
	set_process_input(true)
	set_process(true)

func _build() -> void:
	var mobile := InputSource.use_mobile_ui()
	var w: float = UILayout.dp(274.0) if mobile else 620.0
	var h: float = UILayout.dp(232.0) if mobile else 340.0
	_full_height = h
	_compact_height = UILayout.dp(34.0) if mobile else 44.0
	var x: float = UILayout.dp(8.0) if mobile else 28.0
	var y: float = UILayout.dp(46.0) if mobile else 240.0

	_card = Panel.new()
	_card.name = "TrainingCard"
	_card.position = Vector2(x, y)
	_card.size = Vector2(w, h)
	_card.mouse_filter = Control.MOUSE_FILTER_STOP
	_card.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	add_child(_card)
	UITheme.fade_in(_card, 0.25)

	_title = Label.new()
	_title.text = "🎓 新兵训练营"
	_title.position = Vector2(UILayout.dp(7.0) if mobile else 16, UILayout.dp(4.0) if mobile else 10)
	_title.size = Vector2(w - (UILayout.dp(72.0) if mobile else 150.0), UILayout.dp(18.0) if mobile else 28)
	UITheme.apply_label(_title, UILayout.font_dp(10.0) if mobile else 20, UITheme.GOLD)
	_card.add_child(_title)

	_toggle = Button.new()
	_toggle.text = "收起"
	_toggle.focus_mode = Control.FOCUS_NONE
	_toggle.position = Vector2(w - (UILayout.dp(54.0) if mobile else 106.0),
		UILayout.dp(3.0) if mobile else 7.0)
	_toggle.size = Vector2(UILayout.dp(48.0) if mobile else 92.0,
		UILayout.dp(20.0) if mobile else 32.0)
	UITheme.apply_muted_button(_toggle, UILayout.font_dp(7.0) if mobile else 14)
	_toggle.pressed.connect(_toggle_card)
	_card.add_child(_toggle)

	var level_id := GameSettings.training_level_id
	var level := TrainingDataScript.get_level(level_id, GameSettings.training_nation)
	var concepts: Array = level.get("concepts", [])
	var lines: Array = []
	lines.append("【本关目标】" + _objective_text(level))
	if String(level.get("brief", "")) != "":
		lines.append("教官：%s" % String(level.get("brief", "")))
	if concepts.size() > 0:
		lines.append("")
		lines.append("【本关两个新概念】")
		for c in concepts:
			lines.append("%s %s：%s" % [String(c.get("icon", "•")), String(c.get("name", "")),
				String(c.get("desc", ""))])
	else:
		lines.append("")
		lines.append("【挑战关】不教新单位，只使用前面已经学过的内容。")

	_body = Label.new()
	_body.position = Vector2(UILayout.dp(7.0) if mobile else 16,
		UILayout.dp(26.0) if mobile else 48)
	_body.size = Vector2(w - (UILayout.dp(14.0) if mobile else 32.0),
		h - (UILayout.dp(32.0) if mobile else 58))
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_body.text = "\n".join(lines)
	UITheme.apply_label(_body, UILayout.font_dp(7.0) if mobile else 15, UITheme.PARCHMENT)
	_card.add_child(_body)

func _objective_text(level: Dictionary) -> String:
	var objs: Array = level.get("objectives", [])
	if objs.is_empty():
		return "完成训练任务"
	var parts: Array = []
	for o in objs:
		parts.append(String(o.get("label", o.get("type", ""))))
	return "；".join(parts)

func _toggle_card() -> void:
	_collapsed = not _collapsed
	_body.visible = not _collapsed
	_card.size.y = _compact_height if _collapsed else _full_height
	_toggle.text = "展开" if _collapsed else "收起"

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_H:
		_toggle_card()
		get_viewport().set_input_as_handled()

func _process(_delta: float) -> void:
	# 保持最上层，避免被全屏战报/面板遮住
	if layer != 30:
		layer = 30
