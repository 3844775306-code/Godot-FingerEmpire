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
	for (int i = 0; i < 2; i++) { v += a * smooth_noise(p); p *= 2.3; a *= 0.5; }
	return v;
}

void vertex() {
	vec3 wv = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// 长波长缓坡：波长 10 米上下，幅度只有几厘米，肉眼看到的是明暗缓变
	float w = sin(wv.x * 0.55 + TIME * wave_speed) * cos(wv.z * 0.62 + TIME * wave_speed * 0.7) * wave_amp;
	w += sin(wv.x * 1.35 - TIME * wave_speed * 1.2) * cos(wv.z * 1.21 + TIME * wave_speed * 0.9) * wave_amp * 0.35;
	VERTEX.y += w;
	v_h = w;
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	ALBEDO = tex.rgb;
	ALPHA = tex.a;
	// 和水面同一套思路：只做顶点位移不改变光照，必须扰法线才有凹凸感
	vec3 wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 np = wpos.xz * 0.6;
	float e = 0.35;
	float h0 = fbm(np);
	float hx = fbm(np + vec2(e, 0.0));
	float hz = fbm(np + vec2(0.0, e));
	vec3 wn = normalize(vec3((h0 - hx) * 2.5, 1.0, (h0 - hz) * 2.5));
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
	// 波峰略亮、波谷略暗，起伏更可读
	ALBEDO *= (1.0 + v_h * 1.5);
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}
