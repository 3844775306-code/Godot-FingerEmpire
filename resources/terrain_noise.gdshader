shader_type spatial;
// 陆地地表材质：和水面一样做长波长的微小起伏 + 法线扰动，
// 让整块地面在光照下有细微的凹凸感，而不是一张贴平的贴图。
render_mode blend_mix, depth_draw_opaque, cull_back;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
// 起伏幅度：地表顶点位移多少米。取 0.04 米级别，几乎不影响单位站立高度
uniform float wave_amp : hint_range(0.0, 0.3) = 0.04;
// 起伏流动速度：比水面慢得多，地面是"缓慢呼吸"而不是翻滚
uniform float wave_speed : hint_range(0.0, 1.0) = 0.12;

varying float v_h;

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
	vec3 wv = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// 长波长缓坡：波长 10 米上下，幅度只有几厘米，肉眼看到的是明暗缓变
	float w = sin(wv.x * 0.55 + TIME * wave_speed) * cos(wv.z * 0.62 + TIME * wave_speed * 0.7) * wave_amp;
	w += sin(wv.x * 1.35 - TIME * wave_speed * 1.2) * cos(wv.z * 1.21 + TIME * wave_speed * 0.9) * wave_amp * 0.35;
	// 叠一层更细的起伏，模拟地表的碎小凹凸（波长 2 米左右）
	w += sin(wv.x * 3.1 + TIME * wave_speed * 2.1) * cos(wv.z * 2.7 - TIME * wave_speed * 1.6) * wave_amp * 0.18;
	VERTEX.y += w;
	v_h = w;
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	ALBEDO = tex.rgb;
	ALPHA = tex.a;
	// 和水面同一套思路：只做顶点位移不改变光照，必须扰法线才有凹凸感
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
	// 粗层给大起伏、细层给细密颗粒，系数都调高，光影层次才接近水面
	vec3 wn = normalize(vec3(
		(h0 - hx) * 12.0 + (g0 - gx) * 6.0,
		1.0,
		(h0 - hz) * 12.0 + (g0 - gz) * 6.0));
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
	// 波峰略亮、波谷略暗，起伏更可读
	ALBEDO *= (1.0 + v_h * 1.2);
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}
