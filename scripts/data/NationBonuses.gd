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
		"unit_mult_all": { "melee_armor": 1, "shield_armor": 3 },                  # 所有单位 +2 双护甲
		"castle_start_level": 2                             # 城堡初始 2 级
	},
	RTSConfig.Nation.CHINA: {
		"description": "中国",
		"gather_mult": { "food": 1.2, "gold": 1.1 },       # 食物+20%, 黄金+10%
		"population_bonus": 10                              # 额外 +10 人口上限
	},
	   
	RTSConfig.Nation.HUNGARY: {
		"description": "匈牙利",
		"unit_mult_all": { "melee_armor": 2, "shield_armor": 1 },          # 所有单位 +1 双护甲
		"gather_mult": { "stone": 1.15, "gold": 1.1 }, # 食物+15%, 黄金+10%
		"population_bonus": 5                       # 额外 +5 人口上限
	},
	RTSConfig.Nation.JAPAN: {
		"description": "日本",
		"unit_mult_all": { "attack_speed": 1.15, "attack": 1.1 }           # 所有单位 +15%攻速, +10%攻击
	},
	RTSConfig.Nation.BYZANTINE: {
		"description": "拜占庭",
		"unit_mult_all": { "melee_armor": 2, "shield_armor": 2 },          # 所有单位 +2 双护甲
		"gather_mult": { "gold": 1.1 }                    # 黄金采集 +10%
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
			elif attr == "melee_armor": attr_name = "铠甲"
			elif attr == "shield_armor": attr_name = "盾牌"
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

# 国家特色短描述（标题行用）
static func get_trait_short(nation: int) -> String:
	match nation:
		RTSConfig.Nation.VIKING: return "生命+25% 速度+10%"
		RTSConfig.Nation.ENGLAND: return "攻击+15% 视野+20% 采木+10%"
		RTSConfig.Nation.FRANCE: return "护甲+25 主城起始2级"
		RTSConfig.Nation.CHINA: return "食物+20% 黄金+10% 人口+10"
		RTSConfig.Nation.HUNGARY: return "护甲+15 石+15% 金+10% 人口+5"
		RTSConfig.Nation.JAPAN: return "攻速+15% 攻击+10%"
		RTSConfig.Nation.BYZANTINE: return "双护甲+2 黄金+10%"
		_: return ""

# 国家特色完整描述（面板副标题用）
static func get_trait_full(nation: int) -> String:
	match nation:
		RTSConfig.Nation.VIKING: return "全军生命 +25%、移动速度 +10%，适合正面强攻。"
		RTSConfig.Nation.ENGLAND: return "全军攻击 +15%、视野 +20%，木材采集 +10%，擅长远程压制。"
		RTSConfig.Nation.FRANCE: return "全军护甲 +25，主城开局 2 级，重装骑兵强势。"
		RTSConfig.Nation.CHINA: return "食物 +20%、黄金 +10%，人口上限 +10，经济与规模见长。"
		RTSConfig.Nation.HUNGARY: return "护甲 +15，石材 +15%、黄金 +10%，人口上限 +5。"
		RTSConfig.Nation.JAPAN: return "攻速 +15%、攻击 +10%，近战爆发更强。"
		RTSConfig.Nation.BYZANTINE: return "双护甲 +2，黄金 +10%，防御体系稳固。"
		_: return ""
