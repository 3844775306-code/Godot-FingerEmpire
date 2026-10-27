shader_type spatial;
// 陆地地表材质：和水面一样做长波长的微小起伏 + 法线扰动，
// 让整块地面在光照下有细微的凹凸感，而不是一张贴平的贴图。
render_mode blend_mix, depth_draw_opaque, cull_back;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
// 起伏幅度：地表顶点位移多少米。取 0.04 米级别，几乎不影响单位站立高度
// 起伏流动速度：比水面慢得多，地面是"缓慢呼吸"而不是翻滚
uniform float wave_speed : hint_range(0.0, 1.0) = 0.12;


float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float smooth_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}
float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) { v += a * smooth_noise(p); p *= 2.3; a *= 0.5; }
	return v;
}

void vertex() {
	// 不做顶点位移：地形网格比水面稀疏得多，位移会让相邻三角形之间出现折痕，
	// 屏幕上就是用户看到的一条条细线。起伏感全部交给片元的法线扰动，
	// 只走光照不走几何，就不会有接缝。
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	ALBEDO = tex.rgb;
	ALPHA = tex.a;
	// 与水面的写法保持一致：片元里的 VERTEX 已经是视图空间坐标，
	// 必须用 INV_VIEW_MATRIX 还原到世界空间；若在这里用 MODEL_MATRIX，
	// 法线扰动的图案会跟着摄像机滑动（之前就是这个 bug）
	vec3 wpos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// 与水面一致的高频差分，再叠一层更细的，避免只有大块明暗而显得粗糙
	vec2 np = wpos.xz * 1.8;
	float e = 0.05;
	float h0 = fbm(np);
	float hx = fbm(np + vec2(e, 0.0));
	float hz = fbm(np + vec2(0.0, e));
	vec2 np2 = wpos.xz * 5.5;
	float e2 = 0.03;
	float g0 = fbm(np2);
	float gx = fbm(np2 + vec2(e2, 0.0));
	float gz = fbm(np2 + vec2(0.0, e2));
	// 只把噪声的水平梯度叠加到原始地形法线上。
	// 原始 NORMAL 来自网格顶点法线，带着山体坡度和朝向，是山地立体感的来源；
	// 之前直接 NORMAL = 噪声法线 会把所有坡度抹平，山看着就塌了。
	vec3 perturb_world = vec3(
		(h0 - hx) * 12.0 + (g0 - gx) * 6.0,
		0.0,
		(h0 - hz) * 12.0 + (g0 - gz) * 6.0);
	NORMAL = normalize(NORMAL + (VIEW_MATRIX * vec4(perturb_world, 0.0)).xyz * 0.35);
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}
