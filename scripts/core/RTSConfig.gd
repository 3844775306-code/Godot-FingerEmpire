extends Node

static var MAP_SIZE: int = 100
const GRID_SIZE = 1.0
enum Team { BLUE = 1, RED = 0, NEUTRAL = 2 }
enum Nation {
	VIKING,
	ENGLAND,
	FRANCE,
	CHINA,
	HUNGARY          # 新增
}
const MAX_PLAYERS = 4



# 每个队伍内的玩家编号 (0~1)
enum PlayerSlot {
	SLOT_0 = 0,
	SLOT_1 = 1
}

# 玩家颜色池 — 2v2按顺序取色确保四人颜色互不相同
const COLOR_POOL = [
	Color(1.0, 0.2, 0.1),    # 红
	Color(0.2, 0.6, 1.0),    # 蓝
	Color(1.0, 0.65, 0.0),   # 橙
	Color(0.5, 0.3, 0.9),    # 紫
]

static func get_player_color(peer_id: int) -> Color:
	return COLOR_POOL[peer_id % COLOR_POOL.size()]

# 实体模型映射 (entity_id → "res://models/xxx.glb")
const ENTITY_MODELS = {
	# 建筑
	20: "res://models/castle.glb",          # 主城
	21: "res://models/barracks.glb",        # 兵营
	22: "res://models/warehouse.glb",       # 仓库
	23: "res://models/shipyard.glb",        # 船坞
	24: "res://models/siege_workshop.glb",  # 攻城车间
	25: "res://models/arrow_tower.glb",     # 箭塔
	26: "res://models/cannon_tower.glb",    # 炮塔
	27: "res://models/wall.glb",            # 城墙
	28: "res://models/house.glb",           # 民居
	29: "res://models/siege_workshop.glb",  # 重装武器厂
	41: "res://models/watchtower.glb",      # 瞭望塔
	42: "res://models/academy.glb",         # 书院
	52: "res://models/market.glb",          # 集市
	53: "res://models/castle.glb",          # 城堡
	# 军队
	10: "res://models/soldier.glb",         # 农民
	11: "res://models/soldier.glb",         # 步兵
	12: "res://models/archer.glb",          # 弓箭手
	13: "res://models/warship.glb",         # 战船
	14: "res://models/boat_small.glb",      # 采集船
	16: "res://models/cannon.glb",          # 火炮
	17: "res://models/trebuchet.glb",       # 投石车
	18: "res://models/ram.glb",             # 攻城车
	40: "res://models/boat_large.glb",      # 快艇
	# 资源
	1: "res://models/tree.glb",             # 树林
	3: "res://models/farm.glb",             # 农田
	0: "res://models/mine.glb",             # 金矿
	2: "res://models/mine.glb",             # 石矿
}

static func get_entity_model(entity_id: int) -> String:
	return ENTITY_MODELS.get(entity_id, "")
