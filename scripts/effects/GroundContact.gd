class_name GroundContact
extends Decal

# 单位脚下的一小块柔和暗色贴花，用来把模型「按」在地面上。
#
# 动物用的是小体量模型，站在程序生成的高低起伏地形上时，光照阴影是软的、
# 模型又不贴地，很容易看起来像悬浮在草皮上。加一层贴地的接触暗影之后，
# 模型和地面之间就有了过渡，割裂感明显小很多。
# 资源点（WorldResource）已有的地皮贴花用的是同一张程序纹理，这里复用。

const CONTACT_COLOR: Color = Color(0.02, 0.02, 0.02, 0.40)
# 只投到世界层（地形/水面），不要把旁边的单位或建筑染上一层灰
const CONTACT_CULL_MASK: int = 1 | (1 << 19)

# half_size 是贴花水平方向的半宽（米）
static func create(half_size: float) -> GroundContact:
	var decal := GroundContact.new()
	decal.name = "GroundContact"
	decal.texture_albedo = WorldResource.ground_patch_texture()
	decal.modulate = CONTACT_COLOR
	decal.albedo_mix = 0.85
	decal.cull_mask = CONTACT_CULL_MASK
	var half: float = maxf(half_size, 0.22)
	# 垂直范围放在实体原点两侧，地面正好落在中间，不会掉进上下淡出区
	decal.size = Vector3(half * 2.0, 4.0, half * 2.0)
	decal.upper_fade = 1.0
	decal.lower_fade = 1.0
	return decal

# 按模型实际水平尺寸算接触阴影的半宽：比模型占地略小一圈，
# 太大就像地上糊了一块黑饼，太小又起不到压住模型的作用。
static func half_size_for(body_radius: float, model: Node3D) -> float:
	var footprint: float = WorldResource.ground_patch_half_size(body_radius, model)
	# ground_patch_half_size 已经外扩过一圈软边（+0.55），这里再收回来
	return maxf(0.26, (footprint - 0.55) * 0.95)
