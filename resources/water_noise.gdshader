shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled;

uniform vec4 water_color : source_color = vec4(0.0, 0.75, 1.0, 0.50);
uniform float time_speed : hint_range(0.1, 2.0) = 0.2;
uniform sampler2D fog_tex : source_color;

// —— 水面镜面反射：屏幕空间近似（不需要额外相机/反射探针）——
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float reflect_strength : hint_range(0.0, 1.5) = 0.85;

// —— 船只航行时水面变化：附近涟漪 + 泡沫尾迹 ——
uniform vec3 boats[8];
uniform int boat_count = 0;
uniform float wake_strength : hint_range(0.0, 2.0) = 1.0;

varying float v_boat_foam;
varying float v_boat_lift;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float smooth_noise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i+vec2(1,0)), f.x), mix(hash(i+vec2(0,1)), hash(i+vec2(1,1)), f.x), f.y);
}
float fbm(vec2 p) {
	float v = 0.0; float a = 0.5; float f = 1.0;
	for (int i = 0; i < 4; i++) { v += a * smooth_noise(p * f); f *= 2.3; a *= 0.5; }
	return v;
}

void vertex() {
	vec3 wv = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float w = sin(wv.x * 1.8 + TIME * 0.35) * cos(wv.z * 2.2 + TIME * 0.3) * 0.04;
	w += sin(wv.x * 3.5 + TIME * 0.5) * cos(wv.z * 3.0 - TIME * 0.4) * 0.025;

	// 船只附近的水面起伏与泡沫：船体周围向外扩散的环形波纹
	float foam = 0.0;
	float lift = 0.0;
	for (int i = 0; i < 8; i++) {
		if (i >= boat_count) { break; }
		vec2 d = wv.xz - boats[i].xz;
		float r = length(d);
		float ring = sin(r * 5.0 - TIME * 5.0) * exp(-r * 0.9);
		float bow = exp(-r * 1.6);   // 船头/船尾附近的抬升
		w += (ring * 0.05 + bow * 0.03) * wake_strength;
		foam += (bow * 0.85 + max(0.0, ring) * 0.5) * wake_strength;
		lift += bow;
	}
	v_boat_foam = clamp(foam, 0.0, 1.6);
	v_boat_lift = clamp(lift, 0.0, 1.0);
	VERTEX.y += w;
}

void fragment() {
	vec3 world_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// 基础水色
	vec2 uv_n = UV * 8.0 + vec2(TIME * time_speed * 0.3, TIME * time_speed * 0.25);
	float n = fbm(uv_n);
	vec3 col = water_color.rgb * (0.75 + n * 0.5);
	col = mix(col * 0.7, col * 1.1, smoothstep(0.3, 0.6, n));
	float spec = smoothstep(0.55, 0.7, n) * 0.3;

	vec3 world_normal = vec3(0.0, 1.0, 0.0);
	vec3 refl_col = col;
	float fres = 0.0;
	// 低画质档 reflect_strength 设 0 时整段跳过：法线 fbm 与屏幕采样都不再付出开销
	if (reflect_strength > 0.001) {
		// 用 fbm 的有限差分近似水面波浪法线，反射会随波起伏
		vec2 np = world_pos.xz * 1.2 + vec2(TIME * time_speed * 0.6, TIME * time_speed * 0.45);
		float e = 0.15;
		float h0 = fbm(np);
		float hx = fbm(np + vec2(e, 0.0));
		float hz = fbm(np + vec2(0.0, e));
		world_normal = normalize(vec3((h0 - hx) * 6.0, 1.0, (h0 - hz) * 6.0));

		vec3 view_dir = normalize(world_pos - CAMERA_POSITION_WORLD);
		fres = pow(1.0 - clamp(dot(-view_dir, world_normal), 0.0, 1.0), 4.0);

		// 屏幕空间镜面反射：把反射方向投到屏幕采样；越接近掠射角反射越强
		vec3 refl = reflect(view_dir, world_normal);
		vec4 clip = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos + refl * 30.0, 1.0);
		if (clip.w > 0.0) {
			vec2 suv = clip.xy / clip.w * 0.5 + 0.5;
			if (suv.x > 0.002 && suv.x < 0.998 && suv.y > 0.002 && suv.y < 0.998) {
				refl_col = texture(screen_tex, suv).rgb;
			}
		}
		float refl_amt = clamp(mix(0.12, 1.0, fres) * reflect_strength, 0.0, 0.92);
		col = mix(col, refl_col, refl_amt);
	}

	// 垂直视角的浅色高光
	float f = 1.0 - abs(dot(NORMAL, normalize(VIEW)));
	f = pow(f, 2.5);
	col += f * 0.12 * vec3(0.3, 0.6, 1.0);

	// 船只泡沫尾巴：船周围泛白，尾流处更明显
	col = mix(col, vec3(0.92, 0.96, 1.0), clamp(v_boat_foam * 0.55, 0.0, 0.7));

	// Fog darkening
	vec4 fog = texture(fog_tex, UV);
	float fl = dot(fog.rgb, vec3(0.333));
	col = mix(col, vec3(0.05, 0.05, 0.08), 1.0 - smoothstep(0.08, 0.25, fl));

	ALBEDO = col + spec * vec3(1.0, 1.0, 1.0);
	ALPHA = clamp(mix(0.4, 0.65, f) + spec * 0.15 + v_boat_foam * 0.22, 0.0, 0.95);
	METALLIC = 0.15;
	ROUGHNESS = 0.12;
	SPECULAR = spec + v_boat_lift * 0.2;
}
