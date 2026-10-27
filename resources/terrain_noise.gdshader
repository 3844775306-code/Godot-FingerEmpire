shader_type spatial;
// 陆地地表材质：
//   1) 平缓处保留贴图给的草地/沙土/雪线颜色，再叠两层世界空间噪声，打散"一格一色"的贴图块；
//   2) 坡度大的地方按坡度混入岩壁色 + 横向层理 + 裂隙，山体侧面看起来是石头而不是折纸；
//   3) 法线只做小幅扰动：原来的纯噪声法线会把山体坡度抹平，现在按坡度衰减。
render_mode blend_mix, depth_draw_opaque, cull_back;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
uniform vec3 rock_dark : source_color = vec3(0.16, 0.145, 0.13);
uniform vec3 rock_mid : source_color = vec3(0.33, 0.30, 0.26);
uniform vec3 rock_light : source_color = vec3(0.55, 0.51, 0.44);
uniform float grain_strength : hint_range(0.0, 0.3) = 0.1;

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

// 岩层：沿高度分带，横向用噪声扭曲，避免出现规整的等高线
float rock_strata(vec3 w) {
	float warp = fbm(w.xz * 0.22) * 2.2;
	float band = sin((w.y * 1.15 + warp) * 3.14159) * 0.5 + 0.5;
	band = smoothstep(0.1, 0.9, band);
	float grit = fbm(w.xz * 3.4 + vec2(w.y * 0.7, 0.0));
	return clamp(band * 0.65 + grit * 0.45, 0.0, 1.0);
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	// 片元里的 VERTEX 是视图空间坐标，用 INV_VIEW_MATRIX 还原到世界空间
	vec3 wpos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 wn = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// 坡度：0 = 平地，1 = 垂直崖壁
	float steep = smoothstep(0.62, 0.22, wn.y);

	// 平地：贴图颜色 + 多尺度细噪，盖掉贴图块边界
	float g1 = fbm(wpos.xz * 2.4) * 2.0 - 1.0;
	float g2 = fbm(wpos.xz * 9.0) * 2.0 - 1.0;
	vec3 ground = tex.rgb * (1.0 + g1 * grain_strength + g2 * grain_strength * 0.45);

	// 岩壁：横向层理 + 竖向裂隙
	float s = rock_strata(wpos);
	vec3 rock = mix(rock_dark, rock_light, s);
	float crack = smoothstep(0.62, 0.95, fbm(vec2((wpos.x + wpos.z) * 1.2, wpos.y * 0.55)));
	rock = mix(rock * 0.72, rock, 1.0 - crack * 0.55);

	vec3 col = mix(ground, rock, steep);
	// 崖壁整体压暗一档，配合崖顶受光，视觉上就有"厚度"
	col *= mix(1.0, 0.74, steep * 0.8);
	ALBEDO = col;
	ALPHA = tex.a;

	// 法线扰动：只走光照不走几何；幅度随坡度降低，别把岩层糊掉
	vec2 np = wpos.xz * 1.9;
	float e = 0.05;
	float h0 = fbm(np);
	float hx = fbm(np + vec2(e, 0.0));
	float hz = fbm(np + vec2(0.0, e));
	vec2 np2 = wpos.xz * 5.5;
	float e2 = 0.03;
	float g0 = fbm(np2);
	float gx = fbm(np2 + vec2(e2, 0.0));
	float gz = fbm(np2 + vec2(0.0, e2));
	vec3 perturb_world = vec3(
		(h0 - hx) * 12.0 + (g0 - gx) * 6.0,
		0.0,
		(h0 - hz) * 12.0 + (g0 - gz) * 6.0);
	NORMAL = normalize(NORMAL + (VIEW_MATRIX * vec4(perturb_world, 0.0)).xyz * (0.35 * (1.0 - steep * 0.7)));
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}
