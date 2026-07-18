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
