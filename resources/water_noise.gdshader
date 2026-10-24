shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled;

uniform vec4 water_color : source_color = vec4(0.0, 0.75, 1.0, 0.50);
uniform float time_speed : hint_range(0.1, 2.0) = 0.2;
uniform sampler2D fog_tex : source_color;

// —— 水面镜面反射：屏幕空间近似（不需要额外相机/反射探针）——
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float reflect_strength : hint_range(0.0, 2.0) = 1.0;
// 平面反射：水面上方场景由镜像相机渲染到这张纹理
uniform sampler2D reflection_tex : filter_linear;
uniform float reflection_enabled : hint_range(0.0, 1.0) = 0.0;
// 镜像相机渲染出的图像上下颠倒，取样时要翻转 Y
uniform float reflection_vflip : hint_range(0.0, 1.0) = 1.0;

// —— 船只航行时水面变化：附近涟漪 + 泡沫尾迹 ——
uniform vec3 boats[8];
uniform vec3 boat_dirs[8];   // 每艘船的水平航向（未移动时为 0），用于拉出尾流带
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
	// 大尺度涌浪：幅度加大到肉眼可见（原来只有 4cm，几乎看不出起伏）
	float w = sin(wv.x * 1.1 + TIME * 0.5) * cos(wv.z * 1.4 + TIME * 0.4) * 0.05;
	w += sin(wv.x * 2.6 + TIME * 0.7) * cos(wv.z * 2.2 - TIME * 0.6) * 0.03;

	// 船只附近：向外扩散的环形涟漪 + 船体抬起的船首波 + 后方尾流带
	float foam = 0.0;
	float lift = 0.0;
	for (int i = 0; i < 8; i++) {
		if (i >= boat_count) { break; }
		vec2 rel = wv.xz - boats[i].xz;
		float r = length(rel);
		float ring = sin(r * 3.2 - TIME * 4.5) * exp(-r * 0.5);
		float bow = exp(-r * 0.7);
		w += (ring * 0.05 + bow * 0.02) * wake_strength;
		foam += (bow * 1.5 + max(0.0, ring) * 1.0) * wake_strength;
		lift += bow;
		// 尾流带：沿航行反方向拉长的泡沫条
		vec2 bd = boat_dirs[i].xz;
		if (dot(bd, bd) > 0.01) {
			float along = dot(rel, bd);
			float across = length(rel - bd * along);
			if (along < 0.0) {
				float wake = exp(-across * 1.25) * exp(along * 0.22);
				foam += wake * 1.6 * wake_strength;
				w += wake * 0.015 * wake_strength;
			}
		}
	}
	v_boat_foam = clamp(foam, 0.0, 2.0);
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

	// —— 波浪法线：始终计算并写回 NORMAL，这是"涟漪看得见"的关键 ——
	// 只做顶点位移不会改变光照，水面看起来仍是平板；扰动法线才会出现波光与倒影扭曲。
	vec2 np = world_pos.xz * 1.4 + vec2(TIME * time_speed * 0.8, TIME * time_speed * 0.55);
	float e = 0.06;
	float h0 = fbm(np);
	float hx = fbm(np + vec2(e, 0.0));
	float hz = fbm(np + vec2(0.0, e));
	vec3 wn = normalize(vec3((h0 - hx) * 14.0, 1.0, (h0 - hz) * 14.0));

	// 船只涟漪的法线扰动：与顶点位移用同一套环形波
	for (int i = 0; i < 8; i++) {
		if (i >= boat_count) { break; }
		vec2 rel = world_pos.xz - boats[i].xz;
		float r = length(rel);
		vec2 dir = (r > 0.001) ? (rel / r) : vec2(1.0, 0.0);
		float ring = cos(r * 3.2 - TIME * 4.5) * exp(-r * 0.5);
		float bow = exp(-r * 0.7);
		wn.xz += dir * (ring * 1.1 + bow * 0.6) * wake_strength;
		// 尾流带也扰动法线，航行时后方能看到明显的水纹
		vec2 bd = boat_dirs[i].xz;
		if (dot(bd, bd) > 0.01) {
			float along = dot(rel, bd);
			float across = length(rel - bd * along);
			if (along < 0.0) {
				float wake = exp(-across * 1.25) * exp(along * 0.22);
				wn.xz += bd * (sin(across * 6.0 - TIME * 3.0) * wake * 0.8 * wake_strength);
			}
		}
	}
	wn = normalize(wn);
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);

	// 波峰波谷的明暗变化：只扰法线时远处的波纹仍不明显，这里直接给颜色加层次
	col *= (0.78 + 0.44 * h0);

	vec3 view_dir = normalize(world_pos - CAMERA_POSITION_WORLD);
	// 指数取 2：RTS 俯视角本身接近垂直，用 4 次方会让反射几乎完全消失
	float fres = pow(1.0 - clamp(dot(-view_dir, wn), 0.0, 1.0), 2.0);

	if (reflect_strength > 0.001) {
		// 屏幕空间镜面反射：把反射方向投到屏幕采样；越接近掠射角反射越强。
		// 没有天空盒时屏幕上方常是暗色，用程序化天空色兜底，保证反射始终是"亮蓝"的
		vec3 refl = reflect(view_dir, wn);
		vec4 clip = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos + refl * 30.0, 1.0);
		float up = clamp(refl.y, 0.0, 1.0);
		vec3 sky_refl = mix(vec3(0.52, 0.72, 0.92), vec3(0.22, 0.42, 0.74), up) * (0.9 + 0.1 * n);
		vec3 refl_col = sky_refl;
		// NDC 的 y 向上、屏幕 UV 的 y 向下，取样前必须翻转，否则倒影会上下颠倒
		vec2 suv = vec2(-1.0, -1.0);
		if (clip.w > 0.0) {
			suv = vec2(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
		}
		bool in_screen = (suv.x > 0.002 && suv.x < 0.998 && suv.y > 0.002 && suv.y < 0.998);
		if (reflection_enabled > 0.5) {
			// 镜像相机是主相机关于水面的镜像：同一屏幕坐标上，它看到的正是
			// 主相机在水面该点反射出去的内容，直接按屏幕坐标取样即得倒影。
			vec2 ruv = vec2(SCREEN_UV.x, mix(SCREEN_UV.y, 1.0 - SCREEN_UV.y, reflection_vflip));
			vec3 rc = texture(reflection_tex, ruv).rgb;
			// 反射纹理里的天空是一片很暗的纯背景色，用程序化天空替换掉，
			// 物体部分保留，水面就既有亮天空倒影又能看到船/建筑的影子
			float rlum = dot(rc, vec3(0.333));
			refl_col = mix(sky_refl, rc * 2.2, smoothstep(0.03, 0.30, rlum));
		} else if (in_screen) {
			vec3 sc = texture(screen_tex, suv).rgb;
			// 采样区太暗（天空洞/阴影）时降低屏幕权重，避免整片水面发黑
			float slum = dot(sc, vec3(0.333));
			float wgt = smoothstep(0.03, 0.22, slum);
			refl_col = mix(sky_refl, sc, 0.9 * wgt);
		}
		// 俯视角也保留较高基础反射，否则水面看起来只是一块半透明色块
		float refl_amt = clamp(mix(0.72, 0.99, fres) * reflect_strength, 0.0, 0.96);
		col = mix(col, refl_col, refl_amt);
	}

	// 垂直视角的浅色高光
	float f = 1.0 - abs(dot(NORMAL, normalize(VIEW)));
	f = pow(f, 2.5);
	col += f * 0.12 * vec3(0.3, 0.6, 1.0);

	// 船只泡沫尾巴：船体周围泛白，尾流处更明显
	col = mix(col, vec3(0.93, 0.97, 1.0), clamp(v_boat_foam * 0.6, 0.0, 0.85));

	// Fog darkening：底图暗的时候只压暗一半，避免整片水面变成黑色
	vec4 fog = texture(fog_tex, UV);
	float fl = dot(fog.rgb, vec3(0.333));
	float fog_amt = (1.0 - smoothstep(0.08, 0.25, fl)) * 0.45;
	col = mix(col, vec3(0.05, 0.05, 0.08), fog_amt);

	ALBEDO = col + spec * vec3(1.0, 1.0, 1.0);
	// 金属度保持很低：场景没有天空/反射探针，金属反射取到的是黑色，水会整片发黑
	ALPHA = clamp(mix(0.5, 0.74, f) + spec * 0.15 + v_boat_foam * 0.25, 0.0, 0.96);
	METALLIC = 0.02;
	ROUGHNESS = 0.25;
	SPECULAR = spec + v_boat_lift * 0.25;
}
