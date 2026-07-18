class_name NationBonuses
extends RefCounted

# 增益定义：每个国家拥有一个全局增益表
static var BONUSES: Dictionary = {
	RTSConfig.Nation.VIKING: {
		"description": "维京",
		"unit_mult_all": { "health": 1.25, "speed": 1.1 }   # 所有单位 +10%生命和移速
	},
	RTSConfig.Nation.ENGLAND: {
		"description": "英格兰",
		"unit_mult_all": { "attack": 1.15 ,"vision_range":1.2},               # 所有单位 +15%攻击
		"gather_mult": { "wood": 1.1 }                     # 木材采集 +20%
	},
	RTSConfig.Nation.FRANCE: {
		"description": "法兰西",
		"unit_mult_all": { "armor": 25 },                  # 所有单位 +15 护甲
		"castle_start_level": 2                             # 城堡初始 2 级
	},
	RTSConfig.Nation.CHINA: {
		"description": "中国",
		"gather_mult": { "food": 1.2, "gold": 1.1 },       # 食物+20%, 黄金+10%
		"population_bonus": 10                              # 额外 +10 人口上限
	},
	   
	RTSConfig.Nation.HUNGARY: {
		"description": "匈牙利",
		"unit_mult_all": { "armor": 15 },          # 所有单位 +20 护甲
		"gather_mult": { "stone": 1.15, "gold": 1.1 }, # 食物+15%, 黄金+10%
		"population_bonus": 5                       # 额外 +5 人口上限
	}
}

# 获取指定国家所有兵种共通的属性增益
static func get_all_unit_multipliers(nation: int) -> Dictionary:
	var bonus = BONUSES.get(nation, {})
	return bonus.get("unit_mult_all", {})

# 获取指定资源类型的采集倍率
static func get_gather_mult(nation: int, resource_type: String) -> float:
	var bonus = BONUSES.get(nation, {})
	var gather = bonus.get("gather_mult", {})
	return gather.get(resource_type, 1.0)

# 获取城堡初始等级
static func get_castle_start_level(nation: int) -> int:
	var bonus = BONUSES.get(nation, {})
	return bonus.get("castle_start_level", 1)

# 获取额外的人口上限
static func get_population_bonus(nation: int) -> int:
	var bonus = BONUSES.get(nation, {})
	return bonus.get("population_bonus", 0)
static func get_description(nation: int) -> String:
	var bonus = BONUSES.get(nation, {})
	var text = ""

	# 通用单位增益
	var unit_mults = bonus.get("unit_mult_all", {})
	if not unit_mults.is_empty():
		var parts = []
		for attr in unit_mults:
			var val = unit_mults[attr]
			var attr_name = attr.capitalize()
			if attr == "health": attr_name = "生命"
			elif attr == "attack": attr_name = "攻击"
			elif attr == "armor": attr_name = "护甲"
			elif attr == "speed": attr_name = "速度"
			elif attr == "attack_speed": attr_name = "攻速"
			elif attr == "attack_range": attr_name = "射程"
			elif attr == "vision_range": attr_name = "视野"
			if val is float:
				parts.append("%s%+.0f%%" % [attr_name, (val - 1) * 100])
			else:
				parts.append("%s+%d" % [attr_name, val])
		text += "单位: " + " ".join(parts) + "\n"

	# 采集增益
	var gather = bonus.get("gather_mult", {})
	if not gather.is_empty():
		var parts = []
		for res in gather:
			var res_name = res.capitalize()
			parts.append("%s%+.0f%%" % [res_name, (gather[res] - 1) * 100])
		text += "采集: " + " ".join(parts) + "\n"

	# 特殊加成
	if bonus.has("castle_start_level"):
		text += "初始城堡等级: %d\n" % bonus["castle_start_level"]
	if bonus.has("population_bonus"):
		text += "人口上限+%d\n" % bonus["population_bonus"]

	return text.trim_suffix("\n")
