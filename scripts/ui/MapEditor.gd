extends Control

# 自定义地图编辑器：生成底图 → 画地形/资源/出生点 → 保存、分享码、进入对战。
# 地图数据格式见 CustomMapStore；运行时由 Ground.apply_custom_map 应用。

const GroundScript = preload("res://scripts/map/Ground.gd")
const MapPresets = preload("res://scripts/map/MapPresets.gd")
const CanvasScript = preload("res://scripts/ui/MapEditorCanvas.gd")
const StoreScript = preload("res://scripts/map/CustomMapStore.gd")


const MAP_SIZE := 100

var canvas: MapEditorCanvas
var name_edit: LineEdit
var preset_select: OptionButton
var seed_spin: SpinBox
var saved_select: OptionButton
var status_label: Label
var _preset_ids: Array = []
var _saved_maps: Array = []
var _generating := false
var _last_path := ""

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_new_map()

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.07, 0.06)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	root.add_child(top)

	var back := Button.new()
	back.text = "← 返回"
	UITheme.apply_muted_button(back, 18)
	back.custom_minimum_size = Vector2(100, 44)
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))
	top.add_child(back)

	var title := Label.new()
	title.text = "🗺️ 自定义地图编辑器"
	UITheme.apply_label(title, 26, UITheme.GOLD)
	title.custom_minimum_size = Vector2(300, 44)
	top.add_child(title)

	name_edit = LineEdit.new()
	name_edit.placeholder_text = "地图名称"
	name_edit.text = "我的地图"
	name_edit.custom_minimum_size = Vector2(220, 44)
	name_edit.add_theme_font_size_override("font_size", 18)
	top.add_child(name_edit)

	preset_select = OptionButton.new()
	preset_select.custom_minimum_size = Vector2(220, 44)
	preset_select.add_theme_font_size_override("font_size", 16)
	_preset_ids = MapPresets.all_ids()
	for id in _preset_ids:
		preset_select.add_item(String(MapPresets.get_info(String(id))["name"]))
	preset_select.selected = 0
	top.add_child(preset_select)

	seed_spin = SpinBox.new()
	seed_spin.min_value = 0
	seed_spin.max_value = 2147483647
	seed_spin.step = 1
	seed_spin.value = randi() % 1000000 + 1
	seed_spin.custom_minimum_size = Vector2(150, 44)
	seed_spin.add_theme_font_size_override("font_size", 16)
	seed_spin.tooltip_text = "相同预设 + 种子会生成同一张底图"
	top.add_child(seed_spin)

	var gen := Button.new()
	gen.text = "重新生成底图"
	UITheme.apply_primary_button(gen, 18)
	gen.custom_minimum_size = Vector2(160, 44)
	gen.pressed.connect(_new_map)
	top.add_child(gen)

	var content := HBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 14)
	root.add_child(content)

	var canvas_wrap := PanelContainer.new()
	canvas_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas_wrap.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.STONE))
	content.add_child(canvas_wrap)

	canvas = CanvasScript.new()
	canvas.custom_minimum_size = Vector2(640, 640)
	canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas.map_changed.connect(_on_canvas_changed)
	canvas_wrap.add_child(canvas)

	var side_scroll := ScrollContainer.new()
	side_scroll.custom_minimum_size = Vector2(330, 0)
	side_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(side_scroll)
	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(310, 0)
	side.add_theme_constant_override("separation", 7)
	side_scroll.add_child(side)

	_add_section(side, "地形笔刷")
	var terrain_grid := GridContainer.new()
	terrain_grid.columns = 2
	side.add_child(terrain_grid)
	_add_palette(terrain_grid, "平原", "terrain", 0)
	_add_palette(terrain_grid, "森林", "overlay", 1)
	_add_palette(terrain_grid, "山地", "terrain", 1)
	_add_palette(terrain_grid, "水域", "terrain", 2)
	_add_palette(terrain_grid, "浅滩", "overlay", 3)
	_add_palette(terrain_grid, "沼泽", "overlay", 2)
	_add_palette(terrain_grid, "缓坡", "overlay", 4)
	_add_palette(terrain_grid, "台地", "overlay", 5)

	_add_section(side, "资源笔刷")
	var res_grid := GridContainer.new()
	res_grid.columns = 2
	side.add_child(res_grid)
	_add_palette(res_grid, "金矿", "resource", 0)
	_add_palette(res_grid, "木材", "resource", 1)
	_add_palette(res_grid, "石料", "resource", 2)
	_add_palette(res_grid, "农田", "resource", 3)
	_add_palette(res_grid, "油井", "resource", 4)
	_add_palette(res_grid, "擦除资源", "resource_erase", 0)

	_add_section(side, "出生点")
	var castle_row := HBoxContainer.new()
	side.add_child(castle_row)
	var blue_btn := Button.new()
	blue_btn.text = "蓝方出生"
	UITheme.apply_muted_button(blue_btn, 15)
	blue_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	blue_btn.pressed.connect(func(): canvas.set_brush("castle", 0))
	castle_row.add_child(blue_btn)
	var red_btn := Button.new()
	red_btn.text = "红方出生"
	UITheme.apply_muted_button(red_btn, 15)
	red_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	red_btn.pressed.connect(func(): canvas.set_brush("castle", 1))
	castle_row.add_child(red_btn)

	_add_section(side, "地图库")
	saved_select = OptionButton.new()
	saved_select.custom_minimum_size = Vector2(0, 38)
	saved_select.add_theme_font_size_override("font_size", 15)
	side.add_child(saved_select)
	var lib_row := HBoxContainer.new()
	side.add_child(lib_row)
	var load_btn := Button.new()
	load_btn.text = "加载"
	UITheme.apply_muted_button(load_btn, 15)
	load_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	load_btn.pressed.connect(_load_selected)
	lib_row.add_child(load_btn)
	var del_btn := Button.new()
	del_btn.text = "删除"
	UITheme.apply_danger_button(del_btn, 15)
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.pressed.connect(_delete_selected)
	lib_row.add_child(del_btn)

	var save_btn := Button.new()
	save_btn.text = "💾 保存地图"
	UITheme.apply_primary_button(save_btn, 18)
	save_btn.custom_minimum_size = Vector2(0, 46)
	save_btn.pressed.connect(_save_current)
	side.add_child(save_btn)

	var share_row := HBoxContainer.new()
	side.add_child(share_row)
	var share_btn := Button.new()
	share_btn.text = "分享码"
	UITheme.apply_muted_button(share_btn, 15)
	share_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	share_btn.pressed.connect(_show_share_code)
	share_row.add_child(share_btn)
	var import_btn := Button.new()
	import_btn.text = "导入码"
	UITheme.apply_muted_button(import_btn, 15)
	import_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	import_btn.pressed.connect(_show_import_dialog)
	share_row.add_child(import_btn)

	var play_btn := Button.new()
	play_btn.text = "⚔ 单人配置使用此地图"
	UITheme.apply_primary_button(play_btn, 17)
	play_btn.custom_minimum_size = Vector2(0, 46)
	play_btn.pressed.connect(_use_in_singleplayer)
	side.add_child(play_btn)

	var online_btn := Button.new()
	online_btn.text = "🌐 联机大厅使用此地图"
	UITheme.apply_muted_button(online_btn, 16)
	online_btn.custom_minimum_size = Vector2(0, 42)
	online_btn.pressed.connect(_use_in_online)
	side.add_child(online_btn)

	status_label = Label.new()
	status_label.text = "左键绘制，右键擦除；滚轮列表可查看全部工具"
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.apply_label(status_label, 15, UITheme.STONE.lightened(0.35))
	root.add_child(status_label)

func _add_section(parent: VBoxContainer, text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	UITheme.apply_label(lbl, 17, UITheme.GOLD)
	parent.add_child(lbl)

func _add_palette(parent: GridContainer, text: String, kind: String, value: int) -> void:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(140, 36)
	UITheme.apply_muted_button(b, 15)
	if kind == "resource_erase":
		b.pressed.connect(func(): canvas.set_brush("resource_erase", 0))
	else:
		b.pressed.connect(func(): canvas.set_brush(kind, value))
	parent.add_child(b)

func _selected_preset_id() -> String:
	var idx := clampi(preset_select.selected, 0, _preset_ids.size() - 1)
	return String(_preset_ids[idx])

func _new_map() -> void:
	if _generating:
		return
	_generating = true
	status_label.text = "正在生成底图…"
	await get_tree().process_frame
	var g = GroundScript.new()
	g.data_only = true
	g.map_size_override = MAP_SIZE
	g.custom_seed = int(seed_spin.value)
	g.map_preset = MapPresets.get_preset(_selected_preset_id())
	add_child(g)
	g._resolve_preset()
	g._generate_terrain()
	g._place_castles()
	g._place_resources()
	var data := _ground_to_map(g)
	g.queue_free()
	canvas.set_map_data(data)
	_generating = false
	refresh_saved_list()
	status_label.text = "底图已生成。左键绘制，右键擦除；记得保存或分享。"

func _ground_to_map(g) -> Dictionary:
	var size := int(g._get_map_size())
	var player := [int(g.player_castle_pos.x + size / 2.0), int(g.player_castle_pos.z + size / 2.0)]
	var enemy := [int(g.enemy_castle_pos.x + size / 2.0), int(g.enemy_castle_pos.z + size / 2.0)]
	var res: Array = []
	for r in g.resource_positions:
		var p: Vector3 = r["pos"]
		res.append({"x": int(p.x + size / 2.0), "y": int(p.z + size / 2.0), "type": int(r["type"])})
	return {
		"size": size,
		"preset": _selected_preset_id(),
		"seed": int(seed_spin.value),
		"terrain": g.terrain_grid.duplicate(true),
		"height": g.height_grid.duplicate(true),
		"overlay": g.overlay_grid.duplicate(true),
		"resources": res,
		"castles": [player, enemy],
	}

func _snapshot_data() -> Dictionary:
	var data := canvas.get_map_data()
	data["preset"] = _selected_preset_id()
	data["seed"] = int(seed_spin.value)
	data["name"] = name_edit.text.strip_edges()
	if data["name"] == "":
		data["name"] = "我的地图"
	# 保存前把城堡与资源所在格压平，防止玩家把出生点/资源画进水里
	for c in data["castles"]:
		var cx := int(c[0])
		var cy := int(c[1])
		for dx in range(-3, 4):
			for dy in range(-3, 4):
				var nx := clampi(cx + dx, 0, int(data["size"]) - 1)
				var ny := clampi(cy + dy, 0, int(data["size"]) - 1)
				data["terrain"][nx][ny] = 0
				data["overlay"][nx][ny] = 0
				data["height"][nx][ny] = 0.0
	for r in data["resources"]:
		var rx := int(r["x"])
		var ry := int(r["y"])
		if rx < 0 or ry < 0 or rx >= int(data["size"]) or ry >= int(data["size"]):
			continue
		data["terrain"][rx][ry] = 0
		data["overlay"][rx][ry] = 0
		data["height"][rx][ry] = 0.0
	return data

func _save_current() -> bool:
	var data := _snapshot_data()
	var err := StoreScript.validate(data)
	if err != "":
		status_label.text = "保存失败：" + err
		return false
	var path := StoreScript.save_map(String(data["name"]), data)
	if path == "":
		status_label.text = "保存失败：无法写入 user://custom_maps"
		return false
	_last_path = path
	refresh_saved_list()
	status_label.text = "已保存：" + String(data["name"])
	return true

func refresh_saved_list() -> void:
	if saved_select == null:
		return
	_saved_maps = StoreScript.list_maps()
	saved_select.clear()
	for m in _saved_maps:
		saved_select.add_item(String(m["name"]))
		saved_select.set_item_metadata(saved_select.item_count - 1, String(m["path"]))
	if _saved_maps.is_empty():
		saved_select.add_item("（暂无已保存地图）")
		saved_select.set_item_metadata(0, "")

func _load_selected() -> void:
	var idx := saved_select.selected
	if idx < 0 or idx >= _saved_maps.size():
		return
	var path := String(_saved_maps[idx]["path"])
	var data := StoreScript.load_map(path)
	if data.is_empty() or StoreScript.validate(data) != "":
		status_label.text = "地图文件损坏，无法加载"
		return
	name_edit.text = String(data.get("name", "我的地图"))
	seed_spin.value = int(data.get("seed", seed_spin.value))
	var pid := String(data.get("preset", "classic"))
	var pidx := _preset_ids.find(pid)
	if pidx >= 0:
		preset_select.selected = pidx
	canvas.set_map_data(data)
	_last_path = path
	status_label.text = "已加载：" + String(data.get("name", ""))

func _delete_selected() -> void:
	var idx := saved_select.selected
	if idx < 0 or idx >= _saved_maps.size():
		return
	var path := String(_saved_maps[idx]["path"])
	StoreScript.delete_map(path)
	status_label.text = "已删除本地地图"
	refresh_saved_list()

func _show_share_code() -> void:
	if not _save_current():
		return
	var data := _snapshot_data()
	data["name"] = name_edit.text.strip_edges()
	var code := StoreScript.encode_share(data)
	_show_text_dialog("分享码（复制给其他玩家导入）", code, true)

func _show_import_dialog() -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "粘贴分享码"
	dlg.size = Vector2i(760, 520)
	var te := TextEdit.new()
	te.custom_minimum_size = Vector2(720, 400)
	te.placeholder_text = "粘贴 FEMAP1: 开头的分享码"
	dlg.add_child(te)
	dlg.ok_button_text = "导入"
	dlg.confirmed.connect(func():
		var data := StoreScript.decode_share(te.text)
		if data.is_empty():
			status_label.text = "导入失败：分享码无效或版本不兼容"
			return
		name_edit.text = String(data.get("name", "导入地图"))
		var pid := String(data.get("preset", "classic"))
		var pidx := _preset_ids.find(pid)
		if pidx >= 0:
			preset_select.selected = pidx
		seed_spin.value = int(data.get("seed", 0))
		canvas.set_map_data(data)
		status_label.text = "已导入：" + String(data.get("name", ""))
	)
	add_child(dlg)
	dlg.popup_centered()

func _show_text_dialog(title_text: String, text: String, read_only: bool) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = title_text
	dlg.size = Vector2i(820, 560)
	var te := TextEdit.new()
	te.text = text
	te.editable = not read_only
	te.custom_minimum_size = Vector2(780, 430)
	te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	dlg.add_child(te)
	dlg.add_button("复制", true, "copy")
	dlg.custom_action.connect(func(action):
		if action == "copy":
			DisplayServer.clipboard_set(te.text)
			status_label.text = "分享码已复制到剪贴板"
	)
	add_child(dlg)
	dlg.popup_centered()

func _apply_to_game() -> void:
	var data := _snapshot_data()
	GameSettings.set_custom_map(data, String(data["name"]))
	GameSettings.tutorial_mode = false
	GameSettings.campaign_mode = false
	GameSettings.training_mode = false

func _use_in_singleplayer() -> void:
	if not _save_current():
		return
	_apply_to_game()
	get_tree().change_scene_to_file("res://scenes/single_player_menu.tscn")

func _use_in_online() -> void:
	if not _save_current():
		return
	_apply_to_game()
	GameSettings.ai_mode = 1
	GameSettings.is_ffa = false
	get_tree().change_scene_to_file("res://scenes/online_menu.tscn")

func _on_canvas_changed() -> void:
	if status_label != null:
		status_label.text = "已修改，未保存"
