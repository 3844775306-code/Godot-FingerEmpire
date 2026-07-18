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

# 预定义玩家颜色
const PLAYER_COLORS = {
	0: Color.RED,         # 红队槽0
	1: Color.ORANGE,      # 红队槽1
	2: Color.BLUE,        # 蓝队槽0
	3: Color.PURPLE         # 蓝队槽1
}

# 给每个 peer_id 分配全局颜色
static func get_player_color(peer_id: int) -> Color:
	return PLAYER_COLORS.get(peer_id % 4, Color.WHITE) # AI / 敌方
