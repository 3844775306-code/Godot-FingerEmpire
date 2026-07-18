# scripts/data/EntityDatabase.gd
extends Node



var configs: Dictionary = {}

func _ready():
	_init_data()
	NationData._static_init()

func _init_data():
	var raw_configs = [
		# ==================== 资源 (ID 0-4) ====================
		{
			"id": 0, "type": 0, "name": "金矿", "team": 2,
			"max_health": 3000, "regeneration_rate": 0.2, "gather_amount": 10,
			"body_radius": 0.8, "resource_type": "gold"
		},
		{
			"id": 1, "type": 0, "name": "树林", "team": 2,
			"max_health": 1500, "regeneration_rate": 1, "gather_amount": 10,
			"body_radius": 0.7, "resource_type": "wood"
		},
		{
			"id": 2, "type": 0, "name": "石矿", "team": 2,
			"max_health": 2000, "regeneration_rate": 0.4, "gather_amount": 10,
			"body_radius": 0.8, "resource_type": "stone"
		},
		{
			"id": 3, "type": 0, "name": "农田", "team": 2,
			"max_health": 1200, "regeneration_rate": 1, "gather_amount": 10,
			"body_radius": 0.6, "resource_type": "food"
		},
		{
			"id": 4, "type": 0, "name": "石油", "team": 2,
			"max_health": 1000, "regeneration_rate": 0.3, "gather_amount": 8,
			"body_radius": 0.6, "resource_type": "oil"
		},

		# ==================== 军队 (ID 10-18) ====================
		{
			"id": 10, "type": 2, "name": "农民", "team": 0,
			"cost": {"food": 50},
			"max_health": 50, "attack": 3, "attack_speed": 1.5, "speed": 1.5,
			"vision_range": 12, "attack_range": 0.5, "target_type": 0, "body_radius": 0.4,
			"armor": 0, "can_move": true,
			"gatherable_resources": ["wood", "food", "gold", "stone"]
		},
		{
			"id": 11, "type": 2, "name": "步兵", "team": 0,
			"cost": {"food": 30, "gold": 10},
			"max_health": 200, "attack": 15, "attack_speed": 1.0, "speed": 2.0,
			"vision_range": 15, "attack_range": 0.5, "target_type": 2, "body_radius": 0.5,
			"armor": 10, "can_move": true
		},
		{
			"id": 12, "type": 2, "name": "弓箭手", "team": 0,
			"cost": {"food": 25, "wood": 15},
			"max_health": 80, "attack": 10, "attack_speed": 0.9, "speed": 1.5,
			"vision_range": 18, "attack_range": 4.0, "damage_radius": 0, "target_type": 3,
			"body_radius": 0.35, "armor": 0, "can_move": true
		},
		{
			"id": 13, "type": 2, "name": "战船", "team": 0,
			"cost": {"wood": 40, "gold": 30},
			"max_health": 300, "attack": 25, "attack_speed": 2.0, "speed": 1.5,
			"vision_range": 20, "attack_range": 4.0, "target_type": 3, "body_radius": 0.8,
			"armor": 15, "water_capable": true, "can_move": true
		},
		{
			"id": 14, "type": 2, "name": "采集船", "team": 0,
			"cost": {"wood": 30, "gold": 15},
			"max_health": 100, "attack": 8, "attack_speed": 1.8, "speed": 1.2,
			"vision_range": 15, "attack_range": 0.5, "target_type": 0, "body_radius": 0.5,
			"armor": 0, "water_capable": true, "can_move": true,
			"gatherable_resources": ["oil"], "max_cargo": 40
		},
		{
			"id": 15, "type": 2, "name": "骑兵", "team": 0,
			"cost": {"food": 40, "gold": 20, "wood": 10},
			"max_health": 250, "attack": 20, "attack_speed": 1.4, "speed": 3.0,
			"vision_range": 18, "attack_range": 0.5, "target_type": 2, "body_radius": 0.6,
			"armor": 12, "can_move": true
		},
		{
			"id": 16, "type": 2, "name": "火炮", "team": 0,
			"cost": {"wood": 60, "gold": 40, "stone": 20},
			"max_health": 120, "attack": 35, "attack_speed": 3.0, "speed": 1.0,
			"vision_range": 16, "attack_range": 6.0, "damage_radius": 1.5, "target_type": 3,
			"body_radius": 0.7, "armor": 5, "can_move": true
		},
		{
			"id": 17, "type": 2, "name": "投石车", "team": 0,
			"cost": {"wood": 80, "gold": 50, "stone": 30},
			"max_health": 100, "attack": 50, "attack_speed": 4.0, "speed": 0.8,
			"vision_range": 18, "attack_range": 8.0, "damage_radius": 2.0, "target_type": 3,
			"body_radius": 0.8, "armor": 3, "can_move": true
		},
		{
			"id": 18, "type": 2, "name": "攻城车", "team": 0,
			"cost": {"wood": 100, "gold": 20, "stone": 10},
			"max_health": 200, "attack": 60, "attack_speed": 2.5, "speed": 1.2,
			"vision_range": 12, "attack_range": 0.8, "damage_radius": 0, "target_type": 1,
			"body_radius": 0.9, "armor": 20, "can_move": true,"ignore_building_armor": true,
		},

			{
				"id": 19, "type": 2, "name": "侦察兵", "team": 0,
				"cost": {"food": 30},
				"max_health": 40, "attack": 5, "attack_speed": 1.5, "speed": 3.5,
				"vision_range": 15, "attack_range": 0.5, "target_type": 2, "body_radius": 0.3,
				"armor": 0, "can_move": true
			},
		# ==================== 建筑 (ID 20-28) ====================
		{
			"id": 20, "type": 1, "name": "主城", "team": 0,
			"cost": {"wood": 0, "gold": 0},
			"max_health": 3000, "armor": 20, "body_radius": 1.2,
			"produces": [ {"unit_id": 10, "cooldown": 3.0, "queue_limit": 5}, {"unit_id": 19, "cooldown": 4.0, "queue_limit": 5} ],
			"upgrades": [
				{ "level": 2, "cost": {"wood": 50, "stone": 50}, "health_bonus": 200, "armor_bonus": 5 , "unlocks_unit": 19},
				{ "level": 3, "cost": {"stone": 200, "gold": 150}, "health_bonus": 300, "armor_bonus": 10 },
				{ "level": 4, "cost": {"gold": 300, "oil": 200}, "health_bonus": 400, "armor_bonus": 15 },
				{ "level": 5, "cost": {"gold": 500, "oil": 400}, "health_bonus": 500, "armor_bonus": 20 }
			]
		},
		{
			"id": 21, "type": 1, "name": "兵营", "team": 0,
			"cost": {"wood": 100, "stone": 50},
			"max_health": 500, "body_radius": 1.0,
			"produces": [ {"unit_id": 11, "cooldown": 4.0, "queue_limit": 4} ,
						{"unit_id": 12, "cooldown": 5.0, "queue_limit": 5} ,
			{"unit_id": 15, "cooldown": 6.0, "queue_limit": 4} ,
			{"unit_id": 35, "cooldown": 7.0, "queue_limit": 4} ,
			],
			"upgrades": [
				{ "level": 2, "cost": {"wood": 100, "stone": 80}, "health_bonus": 100, "unlocks_unit": 12 },
				{ "level": 3, "cost": {"stone": 150, "gold": 80}, "health_bonus": 150, "unlocks_unit": 15 },
				{ "level": 4, "cost": {"gold": 200, "oil": 120}, "health_bonus": 200 ,"unlocks_unit": 35 },
				{ "level": 5, "cost": {"gold": 350, "oil": 200}, "health_bonus": 250 }
			]
		},
		{
			"id": 22, "type": 1, "name": "仓库", "team": 0,
			"cost": {"wood": 75, "stone": 75},
			"max_health": 400, "body_radius": 0.8, "storage_bonus": 500,
			"upgrades": [
				{ "level": 2, "cost": {"wood": 80, "stone": 50}, "storage_bonus": 200 },
				{ "level": 3, "cost": {"stone": 120, "gold": 60}, "storage_bonus": 200 },
				{ "level": 4, "cost": {"gold": 150, "oil": 100}, "storage_bonus": 300 },
				{ "level": 5, "cost": {"gold": 250, "oil": 200}, "storage_bonus": 300 }
			]
		},
		{
			"id": 23, "type": 1, "name": "船坞", "team": 0,
			"cost": {"wood": 150, "gold": 80},
			"max_health": 500, "body_radius": 1.0,
			"produces": [
				{ "unit_id": 14, "cooldown": 6.0, "queue_limit": 2 }, 
				{ "unit_id": 13, "cooldown": 7.0, "queue_limit": 5 },   # 采集船
				{ "unit_id": 39, "cooldown": 10.0, "queue_limit": 5 },   # 炮艇
				{ "unit_id": 40, "cooldown": 5.0, "queue_limit": 8 }     # 快艇
			],
			"upgrades": [
				{ "level": 2, "cost": {"wood": 120, "stone": 80}, "health_bonus": 100, "unlocks_unit": 13 },
				{ "level": 3, "cost": {"stone": 180, "gold": 100}, "health_bonus": 150,"unlocks_unit": 40 },
				{ "level": 4, "cost": {"gold": 240, "oil": 150}, "health_bonus": 200 ,"unlocks_unit": 39},
				{ "level": 5, "cost": {"gold": 400, "oil": 300}, "health_bonus": 250 }
			]
		},
		{
			"id": 24, "type": 1, "name": "攻城车间", "team": 0,
			"cost": {"wood": 120, "stone": 60, "gold": 60},
			"max_health": 350, "body_radius": 1.0,
			"produces": [
				{ "unit_id": 18, "cooldown": 6.0, "queue_limit": 3 },
				{ "unit_id": 16, "cooldown": 8.0, "queue_limit": 2 },
				{ "unit_id": 17, "cooldown": 10.0, "queue_limit": 2 }
			],
			"upgrades": [
				{ "level": 2, "cost": {"wood": 80, "stone": 40}, "health_bonus": 100, "unlocks_unit": 16 },
				{ "level": 3, "cost": {"stone": 100, "gold": 60}, "health_bonus": 150, "unlocks_unit": 17 },
				{ "level": 4, "cost": {"gold": 150, "oil": 80}, "health_bonus": 200 },
				{ "level": 5, "cost": {"gold": 250, "oil": 150}, "health_bonus": 250 }
			]
		},
		{
			"id": 25, "type": 1, "name": "箭塔", "team": 0,
			"cost": {"wood": 80, "stone": 50},
			"max_health": 800, "attack": 15, "attack_speed": 1.2, "attack_range": 6.0,
			"target_type": 3, "body_radius": 0.6, "armor": 50,
			"upgrades": [
				{ "level": 2, "cost": {"wood": 100, "stone": 60}, "health_bonus": 120, "attack_bonus": 10 },
				{ "level": 3, "cost": {"stone": 120, "gold": 50}, "health_bonus": 180, "attack_bonus": 15 },
				{ "level": 4, "cost": {"gold": 150, "oil": 80}, "health_bonus": 240, "attack_bonus": 20 },
				{ "level": 5, "cost": {"gold": 200, "oil": 120}, "health_bonus": 300, "attack_bonus": 25 }
			]
		},
		{
			"id": 26, "type": 1, "name": "炮塔", "team": 0,
			"cost": {"stone": 100, "gold": 80},
			"max_health": 700, "attack": 30, "attack_speed": 2.0, "attack_range": 7.0,
			"damage_radius": 1.4, "target_type": 3, "body_radius": 0.8, "armor": 40,
			"upgrades": [
				{ "level": 2, "cost": {"stone": 80, "gold": 60}, "health_bonus": 150, "attack_bonus": 20 },
				{ "level": 3, "cost": {"gold": 120, "oil": 60}, "health_bonus": 200, "attack_bonus": 25 },
				{ "level": 4, "cost": {"gold": 200, "oil": 100}, "health_bonus": 250, "attack_bonus": 30 },
				{ "level": 5, "cost": {"gold": 300, "oil": 200}, "health_bonus": 300, "attack_bonus": 35 }
			]
		},
		{
			"id": 27, "type": 1, "name": "城墙", "team": 0,
			"cost": {"stone": 30},
			"max_health": 700, "armor": 30, "body_radius": 0.5,
			"upgrades": [
				{ "level": 2, "cost": {"stone": 50}, "health_bonus": 200, "armor_bonus": 10 },
				{ "level": 3, "cost": {"stone": 80, "gold": 30}, "health_bonus": 300, "armor_bonus": 15 },
				{ "level": 4, "cost": {"gold": 100, "oil": 50}, "health_bonus": 400, "armor_bonus": 20 },
				{ "level": 5, "cost": {"gold": 150, "oil": 100}, "health_bonus": 500, "armor_bonus": 25 }
			]
		},
		{
			"id": 28, "type": 1, "name": "民居", "team": 0,
			"cost": {"wood": 30},
			"max_health": 150, "body_radius": 0.6,
			"population_bonus": 5
		},

		# ==================== 特色兵种 ====================
		{
			"id": 30, "type": 2, "name": "狂战士", "team": 0,
			"cost": {"food": 60, "gold": 20},
			"max_health": 180, "attack": 22, "attack_speed": 0.7, "speed": 2.2,
			"vision_range": 14, "attack_range": 0.5, "target_type": 2, "body_radius": 0.5,
			"armor": 5, "can_move": true
		},
		{
			"id": 31, "type": 2, "name": "长弓兵", "team": 0,
			"cost": {"food": 40, "wood": 20},
			"max_health": 70, "attack": 14, "attack_speed": 1.0, "speed": 1.6,
			"vision_range": 20, "attack_range": 5.5, "target_type": 3, "body_radius": 0.35,
			"armor": 0, "can_move": true
		},
		{
			"id": 32, "type": 2, "name": "法式骑兵", "team": 0,
			"cost": {"food": 50, "gold": 30},
			"max_health": 300, "attack": 28, "attack_speed": 1.5, "speed": 2.5,
			"vision_range": 16, "attack_range": 0.5, "target_type": 2, "body_radius": 0.7,
			"armor": 18, "can_move": true
		},
		{
			"id": 33, "type": 2, "name": "诸葛连弩", "team": 0,
			"cost": {"wood": 40, "gold": 20},
			"max_health": 90, "attack": 3, "attack_speed": 0.6, "speed": 1.4,
			"vision_range": 18, "attack_range": 5.0, "damage_radius": 0, "target_type": 3, "body_radius": 0.4,
			"armor": 0, "can_move": true,"multiple_process": [8, 3, 30, 6, 2]
		},        # ==================== 像骑兵 (id 34) ====================
		{
			"id": 34, "type": 2, "name": "象骑兵", "team": 0,
			"cost": {"food": 80, "gold": 40},
			"max_health": 500, "attack": 30, "attack_speed": 2.0, "speed": 1.5,
			"vision_range": 14, "attack_range": 0.8, "damage_radius": 1.0,
			"target_type": 2, "body_radius": 1.0, "armor": 25,
			"can_move": true
		},
				# 长枪兵 (id 35)
		{
			"id": 35, "type": 2, "name": "长枪兵", "team": 0,
			"cost": {"food": 40, "wood": 20},
			"max_health": 150, "attack": 20, "attack_speed": 1.5, "speed": 1.8,
			"vision_range": 12, "attack_range": 0.8, "damage_radius": 1.5, "target_type": 2,
			"body_radius": 0.45, "armor": 5, "can_move": true,
			"ignore_armor": true, "piercing": true
		},        # ==================== 重装武器厂 (ID 29) ====================
		{
			"id": 29, "type": 1, "name": "重装武器厂", "team": 0,
			"cost": {"wood": 150, "stone": 200, "oil": 100},
			"max_health": 600, "body_radius": 1.0,
			"produces": [
				{ "unit_id": 36, "cooldown": 12.0, "queue_limit": 5 },
				{ "unit_id": 37, "cooldown": 14.0, "queue_limit": 5 },
				{ "unit_id": 38, "cooldown": 16.0, "queue_limit": 5 }
			],
			"upgrades": [
				{ "level": 2, "cost": {"stone": 150, "oil": 100}, "health_bonus": 150, "unlocks_unit": 36 },
				{ "level": 3, "cost": {"stone": 250, "oil": 180}, "health_bonus": 200, "unlocks_unit": 37 },
				{ "level": 4, "cost": {"stone": 400, "oil": 300}, "health_bonus": 250, "unlocks_unit": 38 },
				{ "level": 5, "cost": {"stone": 600, "oil": 500}, "health_bonus": 300 }
			]
		},

		# ==================== 重装步兵 (ID 36) ====================
		{
			"id": 36, "type": 2, "name": "重装步兵", "team": 0,
			"cost": {"food": 50, "stone": 40, "oil": 20},
			"max_health": 250, "attack": 30, "attack_speed": 2.5, "speed": 1.2,
			"vision_range": 14, "attack_range": 0.8, "damage_radius": 0, "target_type": 2,
			"body_radius": 0.6, "armor": 60, "can_move": true
		},
		# ==================== 重装弓箭手 (ID 37) ====================
		{
			"id": 37, "type": 2, "name": "重装弓箭手", "team": 0,
			"cost": {"food": 40, "stone": 50, "oil": 30},
			"max_health": 180, "attack": 35, "attack_speed": 3.0, "speed": 1.0,
			"vision_range": 16, "attack_range": 6.0, "damage_radius": 0, "target_type": 3,
			"body_radius": 0.5, "armor": 35, "can_move": true
		},
		# ==================== 重装骑兵 (ID 38) ====================
		{
			"id": 38, "type": 2, "name": "重装骑兵", "team": 0,
			"cost": {"food": 60, "stone": 60, "oil": 40},
			"max_health": 350, "attack": 40, "attack_speed": 2.8, "speed": 2.0,
			"vision_range": 18, "attack_range": 0.5, "damage_radius": 0, "target_type": 2,
			"body_radius": 0.7, "armor": 65,  "can_move": true
		},
				# ==================== 炮艇 (ID 39) ====================
		{
			"id": 39, "type": 2, "name": "炮艇", "team": 0,
			"cost": {"wood": 100, "gold": 60, "oil": 20},
			"max_health": 400, "attack": 45, "attack_speed": 3.5, "speed": 1.0,
			"vision_range": 22, "attack_range": 8.0, "damage_radius": 2.5, "target_type": 3,
			"body_radius": 1.0, "armor": 20, "water_capable": true, "can_move": true
		},
		# ==================== 快艇 (ID 40) ====================
		{
			"id": 40, "type": 2, "name": "快艇", "team": 0,
			"cost": {"wood": 40, "gold": 20},
			"max_health": 120, "attack": 15, "attack_speed": 1.0, "speed": 3.5,
			"vision_range": 18, "attack_range": 0.8, "target_type": 2,
			"body_radius": 0.5, "armor": 5, "water_capable": true, "can_move": true
		},
				# ==================== 瞭望塔 (ID 41) ====================
		{
			"id": 41, "type": 1, "name": "瞭望塔", "team": 0,
			"cost": {"wood": 40, "stone": 20},
			"max_health": 200, "attack": 0, "attack_range": 0,
			"vision_range": 25, "body_radius": 0.6, "armor": 5,
			"can_move": false,
			"upgrades": [
				{ "level": 2, "cost": {"wood": 80, "stone": 50}, "health_bonus": 50, "vision_bonus": 10 },
				{ "level": 3, "cost": {"stone": 120, "gold": 60}, "health_bonus": 80, "vision_bonus": 10 },
				{ "level": 4, "cost": {"gold": 150, "oil": 80}, "health_bonus": 120, "vision_bonus": 15 },
				{ "level": 5, "cost": {"gold": 250, "oil": 150}, "health_bonus": 150, "vision_bonus": 15 }
			]
		},
			# ==================== 书院 (ID 42) ====================
			{
				"id": 42, "type": 1, "name": "书院", "team": 0,
				"cost": {"wood": 200, "stone": 150, "gold": 100},
				"max_health": 800, "body_radius": 1.0,
				"produces": [
					{"unit_id": 46, "cooldown": 15.0, "queue_limit": 5},
					{"unit_id": 47, "cooldown": 20.0, "queue_limit": 3},
					{"unit_id": 48, "cooldown": 30.0, "queue_limit": 3},
					{"unit_id": 49, "cooldown": 40.0, "queue_limit": 2},
					{"unit_id": 50, "cooldown": 50.0, "queue_limit": 2}
				],
				"upgrades": [
					{ "level": 2, "cost": {"wood": 150, "gold": 100}, "health_bonus": 100, "unlocks_unit": 47 },
					{ "level": 3, "cost": {"gold": 200, "stone": 150}, "health_bonus": 150, "unlocks_unit": 48 },
					{ "level": 4, "cost": {"gold": 300, "oil": 200}, "health_bonus": 200, "unlocks_unit": 49 },
					{ "level": 5, "cost": {"gold": 500, "oil": 400}, "health_bonus": 250, "unlocks_unit": 50 }
				]
			},
			# ==================== 商人 (ID 43-45) ====================
			{
				"id": 43, "type": 2, "name": "油商", "team": 0,
				"cost": {"oil": 100},
				"max_health": 80, "attack": 0, "speed": 2.0,
				"vision_range": 10, "body_radius": 0.5, "armor": 0, "can_move": true,
				"merchant_type": "oil"
			},
			{
				"id": 44, "type": 2, "name": "木商", "team": 0,
				"cost": {"food": 150},
				"max_health": 80, "attack": 0, "speed": 2.0,
				"vision_range": 10, "body_radius": 0.5, "armor": 0, "can_move": true,
				"merchant_type": "wood"
			},
			{
				"id": 45, "type": 2, "name": "石商", "team": 0,
				"cost": {"food": 150},
				"max_health": 80, "attack": 0, "speed": 2.0,
				"vision_range": 10, "body_radius": 0.5, "armor": 0, "can_move": true,
				"merchant_type": "stone"
			},
				# ==================== 食商 (ID 51) ====================
				{
					"id": 51, "type": 2, "name": "食商", "team": 0,
					"cost": {"food": 150},
					"max_health": 80, "attack": 0, "speed": 2.0,
					"vision_range": 10, "body_radius": 0.5, "armor": 0, "can_move": true,
					"merchant_type": "food"
				},

			# ==================== 官员 (ID 46-50) ====================
			{
				"id": 46, "type": 2, "name": "县吏", "team": 0,
				"cost": {"food": 200, "gold": 100},
				"max_health": 50, "attack": 0, "speed": 1.5, "vision_range": 8,
				"body_radius": 0.4, "armor": 0, "can_move": true,"target_type": 0,
				"official_type": "clerk", "salary": 5
			},
			{
				"id": 47, "type": 2, "name": "上校", "team": 0,
				"cost": {"food": 200, "gold": 200},
				"max_health": 60, "attack": 10, "speed": 1.5, "vision_range": 10,
				"body_radius": 0.45, "armor": 10, "can_move": true,"target_type": 0,
				"official_type": "colonel", "armor_bonus": 80, "salary": 10
			},
			{
				"id": 48, "type": 2, "name": "尚书", "team": 0,
				"cost": {"food": 250, "gold": 300},"target_type": 0,
				"max_health": 50, "attack": 0, "speed": 1.5, "vision_range": 8,
				"body_radius": 0.4, "armor": 0, "can_move": true,
				"official_type": "minister", "speed_bonus": 0.5, "salary": 15
			},
			{
				"id": 49, "type": 2, "name": "统帅", "team": 0,
				"cost": {"food": 400, "gold": 500},
				"max_health": 500, "attack": 40, "attack_speed": 1.5, "speed": 2.0,
				"vision_range": 15, "attack_range": 0.8, "body_radius": 0.8, "armor": 50, "can_move": true,
				"official_type": "commander", "aura_attack_speed": 0.2, "aura_radius": 12, "salary": 25
			},
			{
				"id": 50, "type": 2, "name": "丞相", "team": 0,
				"cost": {"food": 400, "gold": 400},"target_type": 0,
				"max_health": 60, "attack": 0, "speed": 1.5, "vision_range": 8,
				"body_radius": 0.4, "armor": 0, "can_move": true,
				"official_type": "chancellor", "efficiency_multiplier": 2.0, "salary": 30
			},

			# ==================== 集市 (ID 52) ====================
				{
					"id": 52, "type": 1, "name": "集市", "team": 0,
					"cost": {"wood": 150, "stone": 100, "gold": 50},
					"max_health": 600, "body_radius": 1.0, "armor": 5,
					"produces": [
						{"unit_id": 51, "cooldown": 10.0, "queue_limit": 3},
						{"unit_id": 44, "cooldown": 10.0, "queue_limit": 3},
						{"unit_id": 45, "cooldown": 10.0, "queue_limit": 3},
						{"unit_id": 43, "cooldown": 10.0, "queue_limit": 3}
					],
					"upgrades": [
						{ "level": 2, "cost": {"wood": 100, "stone": 80}, "health_bonus": 100 },
						{ "level": 3, "cost": {"stone": 150, "gold": 100}, "health_bonus": 150 },
						{ "level": 4, "cost": {"gold": 200, "oil": 150}, "health_bonus": 200 },
						{ "level": 5, "cost": {"gold": 350, "oil": 250}, "health_bonus": 250 }
					]
				},

			# ==================== 动物 (ID 60-63) ====================
			{
				"id": 60, "type": 2, "name": "牛", "team": 2,
				"max_health": 100, "attack": 20, "attack_speed": 1.5, "speed": 0.5,
				"vision_range": 8, "attack_range": 0.5, "target_type": 2, "body_radius": 0.6,
				"armor": 5, "can_move": true, "animal_type": "cow", "food_reward": 80
			},
			{
				"id": 61, "type": 2, "name": "猪", "team": 2,
				"max_health": 200, "attack": 10, "attack_speed": 1.5, "speed": 0.5,
				"vision_range": 6, "attack_range": 0.5, "target_type": 2, "body_radius": 0.5,
				"armor": 5, "can_move": true, "animal_type": "pig", "food_reward": 100
			},
			{
				"id": 62, "type": 2, "name": "羊", "team": 2,
				"max_health": 50, "attack": 5, "attack_speed": 1.5, "speed":0.8,
				"vision_range": 10, "attack_range": 0.5, "target_type": 2, "body_radius": 0.4,
				"armor": 2, "can_move": true, "animal_type": "sheep", "food_reward": 60
			},
			{
				"id": 63, "type": 2, "name": "鱼", "team": 2,
				"max_health": 40, "attack": 5, "attack_speed": 1.5, "speed": 0.8,
				"vision_range": 6, "attack_range": 0.5, "target_type": 2, "body_radius": 0.3,
				"armor": 0, "water_capable": true, "can_move": true, "animal_type": "fish", "food_reward": 50
			}
	]

	# 将数组转换为字典，以 ID 为键实现 O(1) 查找
	for cfg in raw_configs:
		configs[cfg["id"]] = cfg

func get_config(entity_id: int) -> Dictionary:
	var cfg = configs.get(entity_id, null)
	if cfg:
		return cfg.duplicate()
	return {}
