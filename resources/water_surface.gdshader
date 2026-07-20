shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back;

uniform float wave_amp : hint_range(0.01, 0.15) = 0.03;
uniform float wave_speed : hint_range(0.1, 1.0) = 0.2;

varying float _height;

void vertex() {
	float h = 0.0;
	h += sin(VERTEX.x * 1.2 + TIME * wave_speed) * cos(VERTEX.z * 1.1 + TIME * wave_speed * 0.7) * wave_amp;
	h += sin(VERTEX.x * 2.5 + TIME * 0.8) * cos(VERTEX.z * 2.2 - TIME * 0.6) * wave_amp * 0.35;
	VERTEX.y += h;
	_height = h;
}

void fragment() {
	// Subtle ripple
	float r1 = sin(UV.x * 27.0 + TIME * 0.05) * cos(UV.y * 23.0 + TIME * 0.04);
	float r2 = sin(UV.x * 41.0 - TIME * 0.07) * cos(UV.y * 37.0 + TIME * 0.08);
	float ripple = (r1 + r2) * 0.15 + 0.5;

	// Tiny scattered foam
	float f1 = sin(UV.x * 113.0 + TIME * 0.25) * cos(UV.y * 97.0 - TIME * 0.21);
	float f2 = sin(UV.x * 79.0 - TIME * 0.17) * cos(UV.y * 127.0 + TIME * 0.19);
	float f3 = sin((UV.x + UV.y) * 89.0 + TIME * 0.29) * cos((UV.x - UV.y) * 67.0 - TIME * 0.13);
	float foam = (f1 + f2 + f3) * 0.33;
	foam = smoothstep(0.83, 0.95, abs(foam));

	vec3 hv = normalize(normalize(VIEW) + vec3(0.0, 1.0, 0.0));
	float spec = pow(max(dot(NORMAL, hv), 0.0), 256.0) * 0.3;

	vec3 water_base = vec3(0.0, 0.75, 1.0);
	vec3 white = vec3(0.9, 0.95, 1.0);
	vec3 col = water_base * (0.75 + ripple * 0.2) + white * foam * 0.4;

	ALBEDO = col;
	ALPHA = 0.35 + foam * 0.2 + spec * 0.15;
	METALLIC = 0.0;
	ROUGHNESS = 0.2;
	SPECULAR = spec;
}
