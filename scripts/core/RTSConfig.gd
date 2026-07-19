extends Node

static var MAP_SIZE: int = 100
const GRID_SIZE = 1.0
enum Team { BLUE = 1, RED = 0, NEUTRAL = 2 }
enum Nation {
	VIKING,
	ENGLAND,
	FRANCE,
	CHINA,
	HUNGARY
}
const MAX_PLAYERS = 4



# 每个队伍内的玩家编号 (0~1)
enum PlayerSlot {
	SLOT_0 = 0,
	SLOT_1 = 1
}

# 玩家颜色池
const COLOR_POOL = [
	Color(1.0, 0.2, 0.1),    # 红
	Color(0.2, 0.6, 1.0),    # 蓝
	Color(1.0, 0.65, 0.0),   # 橙
	Color(0.5, 0.3, 0.9),    # 紫
]

static func get_player_color(peer_id: int) -> Color:
	return COLOR_POOL[peer_id % COLOR_POOL.size()]

# 实体模型映射
const ENTITY_MODELS = {
	# 建筑
	20: "res://models/castle.glb",
	21: "res://models/barracks.glb",
	22: "res://models/warehouse.glb",
	23: "res://models/shipyard.glb",
	24: "res://models/siege_workshop.glb",
	25: "res://models/arrow_tower.glb",
	26: "res://models/cannon_tower.glb",
	27: "res://models/wall.glb",
	28: "res://models/house.glb",
	29: "res://models/siege_workshop.glb",
	41: "res://models/watchtower.glb",
	42: "res://models/academy.glb",
	52: "res://models/market.glb",
	53: "res://models/castle.glb",
	# 军队
	10: "res://models/soldier.glb",
	11: "res://models/soldier.glb",
	12: "res://models/archer.glb",
	13: "res://models/warship.glb",
	14: "res://models/boat_small.glb",
	16: "res://models/cannon.glb",
	17: "res://models/trebuchet.glb",
	18: "res://models/ram.glb",
	40: "res://models/boat_large.glb",
	# 资源
	0: "res://models/rocks-ramp.glb",
	2: "res://models/stones.glb",
	3: "res://models/farm.glb",
}

static func get_entity_model(entity_id: int, level: int = 1) -> String:
	if entity_id == 1:
		return "res://models/tree-high.glb" if level >= 4 else "res://models/tree.glb"
	return ENTITY_MODELS.get(entity_id, "")
