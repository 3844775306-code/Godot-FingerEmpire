shader_type spatial;
// 地形四周裙边（切面）材质：地图边缘、悬崖底部从侧面看是一层厚岩石，
// 而不是零厚度的单面网格。双面渲染，镜头转到地图外也成立。
render_mode blend_mix, depth_draw_opaque, cull_disabled;

uniform vec3 rock_dark : source_color = vec3(0.13, 0.12, 0.11);
uniform vec3 rock_mid : source_color = vec3(0.29, 0.27, 0.24);
uniform vec3 rock_light : source_color = vec3(0.47, 0.43, 0.37);

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

void fragment() {
	// 双面材质：背面要把法线翻过来，否则从地图外看会整片发黑
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	vec3 wpos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// 横向层理，和地表岩壁保持同一套视觉语言
	float warp = fbm(wpos.xz * 0.4) * 2.4;
	float band = sin((wpos.y * 0.85 + warp) * 3.14159) * 0.5 + 0.5;
	band = smoothstep(0.15, 0.85, band);
	float grit = fbm(wpos.xz * 2.2 + vec2(wpos.y * 0.9, 0.0));
	vec3 col = mix(rock_dark, rock_light, band * 0.7 + grit * 0.4);
	// 越靠下越暗，像埋进土里的地基
	col *= mix(0.45, 1.0, smoothstep(-7.0, 0.6, wpos.y));
	ALBEDO = col;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}
