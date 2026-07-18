# scripts/ui/BuildingActionMenu.gd
extends Control

signal upgrade_pressed
signal produce_pressed(unit_id: int)

var building: Building = null

func setup(_building: Building):
	building = _building

	# 1. 菜单本身必须停止鼠标事件，但我们手动控制子元素
	#mouse_filter = Control.MOUSE_FILTER_STOP

	

	# 3. 垂直布局（让事件继续向下传递）
	var vbox = VBoxContainer.new()
	vbox.position = Vector2(5, 5)
	#vbox.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(vbox)
	# 2. 背景（强制忽略鼠标）
	var bg = ColorRect.new()
	bg.color = Color(0.2, 0.2, 0.2, 0.9)
	#bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 7. 背景尺寸跟随内容
	var total_height = vbox.get_child_count() * 40 + 10
	bg.size = Vector2(130, total_height)
	add_child(bg)
	# 4. 升级按钮
	if building.can_upgrade():
		var cost = building.get_upgrade_cost()
		var up_btn = Button.new()
		up_btn.text = "升级\n木:%d 金:%d" % [cost.get("wood",0), cost.get("gold",0)]
		up_btn.custom_minimum_size = Vector2(120, 40)
		#up_btn.mouse_filter = Control.MOUSE_FILTER_STOP
		up_btn.pressed.connect(_on_upgrade)
		vbox.add_child(up_btn)

	# 5. 生产按钮
	if building.production_list.size() > 0:
		for prod in building.production_list:
			var btn = Button.new()
			var unit_cfg = EntityDatabase.get_config(prod.unit_id)
			var unit_name = unit_cfg.get("name", "?")
			btn.text = "生产 %s (%.1fs)" % [unit_name, prod.cooldown]
			btn.custom_minimum_size = Vector2(120, 35)
			#btn.mouse_filter = Control.MOUSE_FILTER_STOP
			btn.pressed.connect(_on_produce.bind(prod.unit_id))
			vbox.add_child(btn)

	# 6. 关闭按钮
	var close_btn = Button.new()
	close_btn.text = "关闭"
	close_btn.custom_minimum_size = Vector2(120, 35)
	#close_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	close_btn.pressed.connect(_on_close)
	vbox.add_child(close_btn)

	

	# 8. 调试：延迟打印每个按钮的实际布局位置（这时布局已完成）
	#call_deferred("_print_all_buttons")
func _on_close():
	print(1)
	queue_free()
func _print_all_buttons():
	for child in get_children():
		if child is VBoxContainer:
			for btn in child.get_children():
				if btn is Button:
					print("[MenuBtn] 最终位置: ", btn.get_global_rect())
	print("[ActionMenu] 父节点: ", get_parent())

func _on_upgrade():
	print("[ActionMenu] 升级按钮真正被点击")
	emit_signal("upgrade_pressed")
	queue_free()

func _on_produce(unit_id: int):
	print("[ActionMenu] 生产按钮被点击，unit_id=", unit_id)
	emit_signal("produce_pressed", unit_id)
	queue_free()
