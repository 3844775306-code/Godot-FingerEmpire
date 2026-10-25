class_name GroundStripMesh
extends RefCounted

# 贴地细带的公共构建工具：选中单位的范围圈（视野/作用范围）和路径指引带都靠它生成网格。
#
# 关键点是「每一个顶点单独采样地形高度」：如果整条带子只抬一个高度，走上坡就会
# 一半埋进土里、下坡又浮在半空，那正是最明显的割裂感来源。逐顶点贴地之后，
# 带子会顺着草坡、石头起伏弯曲，看起来像画在地面上的粉笔线。
#
# 渲染上统一用 unshaded + blend_mix + depth_draw_never：不写深度、不投影，
# 和地面是「叠加一层颜色」而不是「糊一块贴片」，边缘再用横向 softstep 化开。

# 抬离地面一点点：地形是三角形面片，带子贴着面片画会有深度打架（闪烁），
# 配合着色器里 6 厘米的朝相机推移，这里只要很小的抬升就够，不会看出浮空。
const SURFACE_LIFT: float = 0.10
# 带子抬高时额外做的法线偏移上限，纯平地用不到，陡坡上能减少穿插
const MAX_SEGMENT_LEN: float = 1.2

static var _shader: Shader = null

# 每个点都单独贴地，因此中心线越密越贴合地形；太稀疏会在坡上折出直线段
static func _segment_count(radius: float) -> int:
	return clampi(int(radius * 22.0), 96, 320)

# 把折线按最大步长加密：A* 路径在长距离时会被抽样成几十米一段，
# 不加密的话贴地带只有两个端点贴着地形，中间整段会斜插进土里。
static func densify(points: Array, max_step: float) -> Array:
	var out: Array = []
	if points.is_empty():
		return out
	out.append(points[0])
	for i in range(1, points.size()):
		var a: Vector3 = points[i - 1]
		var b: Vector3 = points[i]
		var d: float = Vector2(b.x - a.x, b.z - a.z).length()
		var steps: int = maxi(1, int(ceil(d / maxf(max_step, 0.2))))
		for s in range(1, steps + 1):
			var t: float = float(s) / float(steps)
			out.append(a.lerp(b, t))
	return out

static func height_fn_for(bm) -> Callable:
	# bm 可以是 RTSBattleManager，也可以是 ClientRenderer 这类能拿到地形高度的对象；
	# 拿不到就退回点的原始 y，至少不会把整条带子压到 0 高度。
	if bm == null:
		return func(p: Vector3) -> float: return p.y
	var map = null
	if bm.has_method("get_map_node"):
		map = bm.get_map_node()
	if map == null and bm.has_node("Map"):
		map = bm.get_node("Map")
	# 传进来的对象本身可能就是地形节点（测试/探针里常见）
	if map == null and bm.get("vertex_grid") != null:
		map = bm
	if map == null:
		return func(p: Vector3) -> float: return p.y
	# 地形网格的高度表：Ground 里叫 vertex_grid（每个网格顶点的高度）。
	# 优先用它做「和渲染网格完全一致」的插值，原因见 _sample_terrain_grid() 的注释。
	var grid = map.get("vertex_grid")
	if grid is Array and grid.size() > 1 and (grid[0] as Array).size() > 1:
		var n: int = grid.size() - 1
		var map_size: float = float(n)
		if map.has_method("_get_map_size"):
			map_size = float(map._get_map_size())
		return func(p: Vector3) -> float:
			return _sample_terrain_grid(grid, n, map_size, p.x, p.z)
	if map.has_method("get_height_at"):
		return func(p: Vector3) -> float: return float(map.get_height_at(p))
	return func(p: Vector3) -> float: return p.y

# 按地形网格的三角剖分做精确插值，保证采样值 == 屏幕上看到的地面高度。
#
# 这里不能用 Ground.get_height_at()：它返回的是「所在格子左下角顶点的高度」（最近邻），
# 而地面网格是两个三角形线性插值出来的。起伏地形上两者能差半米到一米，
# 贴着地面的细线一进坡就整段沉到地面以下——玩家看到的就是「线被地面挡住了」。
# Ground._create_visual_and_texture() 的剖分是 (i00,i10,i01) 与 (i10,i11,i01)，
# 对角线把格子分成 u+v<=1 和 u+v>1 两个三角形，这里照抄同样的插值。
static func _sample_terrain_grid(grid: Array, n: int, map_size: float, wx: float, wz: float) -> float:
	var fx: float = (wx / map_size + 0.5) * float(n)
	var fz: float = (wz / map_size + 0.5) * float(n)
	var x: int = clampi(int(floor(fx)), 0, n - 1)
	var z: int = clampi(int(floor(fz)), 0, n - 1)
	var u: float = clampf(fx - float(x), 0.0, 1.0)
	var v: float = clampf(fz - float(z), 0.0, 1.0)
	var row_a: Array = grid[x]
	var row_b: Array = grid[x + 1]
	var h00: float = float(row_a[z])
	var h10: float = float(row_b[z])
	var h01: float = float(row_a[z + 1])
	var h11: float = float(row_b[z + 1])
	if u + v <= 1.0:
		return h00 + u * (h10 - h00) + v * (h01 - h00)
	return h11 + (1.0 - u) * (h01 - h11) + (1.0 - v) * (h10 - h11)

static func shader() -> Shader:
	if _shader != null:
		return _shader
	var s := Shader.new()
	s.code = """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled, world_vertex_coords;

uniform vec4 tint : source_color = vec4(1.0);
uniform float soft_edge = 0.42;   // 横向软边比例：0 = 硬边，越大越像雾化
uniform float dash_scale = 0.0;   // 0 = 实线（范围圈）；>0 = 每米虚线重复次数（路径带）
uniform float dash_flow = 0.0;    // 虚线滚动偏移，做出「往前流动」的方向感
uniform float grain = 0.20;       // 表面斑驳，避免出现一条塑料感很强的纯色线
uniform float head_fade = 0.0;    // 起点淡出（路径带从单位脚下慢慢显出来）
uniform float depth_push = 0.06;  // 朝相机方向再推一点点，防止被地面深度吃掉

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void vertex() {
	// 带子只比地面高几厘米：远处深度缓冲精度不足、或者地形三角面与我们采样的高度
	// 有毫米级差异时，整段线会被判成「在地面以下」而直接消失（玩家看到的就是被地面挡住）。
	// world_vertex_coords 模式下 VERTEX 就是世界坐标，这里把每个顶点朝相机方向推 6 厘米，
	// 相当于给出一条稳定的深度余量，投影位置变化几乎看不出来。
	VERTEX += normalize(CAMERA_POSITION_WORLD - VERTEX) * depth_push;
}

void fragment() {
	float u = UV.x;
	float v = UV.y;

	// 横向软边：中间实、两侧透
	float edge = smoothstep(0.0, soft_edge, u) * smoothstep(1.0, 1.0 - soft_edge, u);

	// 纵向虚线：只在路径指引带启用
	float dash = 1.0;
	if (dash_scale > 0.0) {
		float phase = fract(v * dash_scale - dash_flow);
		dash = smoothstep(0.40, 0.56, phase) * (1.0 - smoothstep(0.84, 1.0, phase));
	}

	// 低频斑驳：像撒在地上的浅色粉末
	float n = hash21(floor(vec2(u * 24.0, v * 2.5)));
	float grain_mul = 1.0 - grain * n;

	// 起点淡出，让带子从单位脚下自然过渡出来
	float head = mix(1.0, smoothstep(0.0, 1.6, v), head_fade);

	ALBEDO = tint.rgb;
	ALPHA = tint.a * edge * dash * grain_mul * head;
}
"""
	_shader = s
	return _shader

# 通用材质：范围圈传实线参数，路径带传虚线参数
static func make_material(tint: Color, soft_edge: float, dash_scale: float, grain: float, head_fade: float) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = shader()
	mat.set_shader_parameter("tint", tint)
	mat.set_shader_parameter("soft_edge", soft_edge)
	mat.set_shader_parameter("dash_scale", dash_scale)
	mat.set_shader_parameter("dash_flow", 0.0)
	mat.set_shader_parameter("grain", grain)
	mat.set_shader_parameter("head_fade", head_fade)
	return mat

# 把中心线做成一条贴地的带子。
# centerline: 世界坐标中心线；half_width: 带宽的一半（米）；closed: 环状首尾相接
static func build_strip(centerline: Array, half_width: float, height_fn: Callable, closed: bool) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var n: int = centerline.size()
	if n < 2:
		return mesh
	if n == 2 and closed:
		return mesh

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# 先把每个中心线点算成「左右两条边」的世界坐标，再逐顶点贴地
	var left_pts: Array = []
	var right_pts: Array = []
	var v_coords: Array = []
	var acc: float = 0.0
	for i in n:
		var p: Vector3 = centerline[i]
		var prev: Vector3 = centerline[(i - 1 + n) % n] if (closed or i > 0) else p
		var next: Vector3 = centerline[(i + 1) % n] if (closed or i < n - 1) else p
		var tangent: Vector3 = next - prev
		tangent.y = 0.0
		if tangent.length_squared() < 0.000001:
			tangent = Vector3(1, 0, 0)
		tangent = tangent.normalized()
		# 左法线（水平面内垂直）
		var side: Vector3 = Vector3(-tangent.z, 0.0, tangent.x)
		var l: Vector3 = p + side * half_width
		var r: Vector3 = p - side * half_width
		l.y = float(height_fn.call(l)) + SURFACE_LIFT
		r.y = float(height_fn.call(r)) + SURFACE_LIFT
		if i > 0:
			var d: Vector3 = p - centerline[i - 1]
			d.y = 0.0
			acc += d.length()
		left_pts.append(l)
		right_pts.append(r)
		v_coords.append(acc)

	var seg_uv: float = 1.0
	var last_i: int = n if closed else n - 1
	for i in last_i:
		var j: int = (i + 1) % n
		var l0: Vector3 = left_pts[i]
		var r0: Vector3 = right_pts[i]
		var l1: Vector3 = left_pts[j]
		var r1: Vector3 = right_pts[j]
		# 距离过长（跳跃的点）直接跳过，避免拉出一条横穿地图的长三角
		if l0.distance_to(l1) > MAX_SEGMENT_LEN * 4.0:
			continue
		var v0: float = v_coords[i] * seg_uv
		var v1: float = (v_coords[j] if j != 0 else v_coords[i] + centerline[i].distance_to(centerline[j])) * seg_uv
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(0.0, v0)); st.add_vertex(l0)
		st.set_uv(Vector2(1.0, v0)); st.add_vertex(r0)
		st.set_uv(Vector2(1.0, v1)); st.add_vertex(r1)
		st.set_uv(Vector2(0.0, v0)); st.add_vertex(l0)
		st.set_uv(Vector2(1.0, v1)); st.add_vertex(r1)
		st.set_uv(Vector2(0.0, v1)); st.add_vertex(l1)
	return st.commit()

# 生成一圈中心线（世界坐标），供范围圈和路径终点印记共用
static func circle_points(center: Vector3, radius: float) -> Array:
	var pts: Array = []
	var segs: int = _segment_count(radius)
	for i in segs:
		var a: float = TAU * float(i) / float(segs)
		pts.append(Vector3(center.x + cos(a) * radius, center.y, center.z + sin(a) * radius))
	return pts
