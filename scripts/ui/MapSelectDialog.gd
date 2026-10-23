# 战场地形卡片选择弹层：主菜单与联机大厅共用。
# 直接 new() 后 add_child() 即可弹出；点卡片发出 map_selected 并自行关闭。
extends Control

signal map_selected(id: String)

const MapPresets = preload("res://scripts/map/MapPresets.gd")
const MapPreview = preload("res://scripts/map/MapPreview.gd")

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()

func _build() -> void:
	var dim = ColorRect.new()
	dim.color = Color(0, 0, 0, 0.65)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(ev):
		if ev is InputEventMouseButton and ev.pressed:
			queue_free())
	add_child(dim)

	var panel = Panel.new()
	panel.position = Vector2(340, 300)
	panel.size = Vector2(1720, 760)
	panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	add_child(panel)
	UITheme.fade_in(panel, 0.2)

	var title = Label.new()
	title.text = "⚔️ 选择战场地形 ⚔️"
	title.position = Vector2(0, 16)
	title.size = Vector2(1720, 46)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(title, 32, UITheme.GOLD)
	panel.add_child(title)

	var hint = Label.new()
	hint.text = "特殊地形暂只支持 1V1；地形会改变视野、移速与资源分布"
	hint.position = Vector2(0, 66)
	hint.size = Vector2(1720, 26)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(hint, 18, UITheme.STONE.lightened(0.35))
	panel.add_child(hint)

	var ids: Array = MapPresets.all_ids()
	var card_w := 380.0
	var gap := 24.0
	var total_w := card_w * float(ids.size()) + gap * float(ids.size() - 1)
	var start_x := (1720.0 - total_w) * 0.5
	for i in range(ids.size()):
		panel.add_child(_make_map_card(String(ids[i]), Vector2(start_x + float(i) * (card_w + gap), 104)))

	var close = Button.new()
	close.text = "✕"
	close.position = Vector2(1660, 16)
	close.size = Vector2(44, 44)
	UITheme.apply_muted_button(close, 20)
	close.pressed.connect(func(): queue_free())
	panel.add_child(close)

func _make_map_card(id: String, pos: Vector2) -> Control:
	var card_id := id
	var info := MapPresets.get_info(id)
	var selected := id == GameSettings.map_id

	var card = Panel.new()
	card.position = pos
	card.size = Vector2(380, 620)
	card.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD if selected else UITheme.STONE))

	var thumb = TextureRect.new()
	thumb.position = Vector2(55, 18)
	thumb.size = Vector2(270, 270)
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.texture = MapPreview.get_texture(id, 270)
	card.add_child(thumb)

	var name_lbl = Label.new()
	name_lbl.text = String(info["name"])
	name_lbl.position = Vector2(10, 300)
	name_lbl.size = Vector2(360, 36)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(name_lbl, 26, UITheme.GOLD if selected else UITheme.PARCHMENT)
	card.add_child(name_lbl)

	var battle_lbl = Label.new()
	battle_lbl.text = String(info["battle"])
	battle_lbl.position = Vector2(10, 338)
	battle_lbl.size = Vector2(360, 26)
	battle_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(battle_lbl, 17, UITheme.STONE.lightened(0.4))
	card.add_child(battle_lbl)

	var chips = Label.new()
	var chip_arr := PackedStringArray(info["chips"])
	chips.text = " · ".join(chip_arr)
	chips.position = Vector2(14, 374)
	chips.size = Vector2(352, 60)
	chips.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	chips.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(chips, 17, UITheme.GOLD)
	card.add_child(chips)

	var desc = Label.new()
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.text = String(info["desc"])
	UITheme.apply_label(desc, 16, UITheme.PARCHMENT.darkened(0.15))
	# 先入树再定尺寸：自动换行标签在入树前算出的宽度会按整行文本撑开
	card.add_child(desc)
	desc.position = Vector2(18, 442)
	desc.size = Vector2(344, 130)

	var pick = Button.new()
	pick.flat = true
	pick.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pick.pressed.connect(func():
		map_selected.emit(card_id)
		queue_free())
	card.add_child(pick)
	return card
