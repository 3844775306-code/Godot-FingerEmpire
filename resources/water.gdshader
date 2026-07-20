shader_type spatial;
render_mode blend_mix, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 water_color : source_color = vec4(0.08, 0.25, 0.55, 0.6);
uniform float wave_height : hint_range(0.05, 0.5) = 0.15;
uniform float wave_speed : hint_range(0.1, 2.0) = 0.6;

void vertex() {
	float wave = sin(VERTEX.x * 3.5 + TIME * wave_speed)
	           * cos(VERTEX.z * 3.0 + TIME * wave_speed * 0.7)
	           * wave_height;
	wave += sin(VERTEX.x * 6.0 + TIME * wave_speed * 1.3)
	      * cos(VERTEX.z * 5.5 - TIME * wave_speed * 1.0)
	      * wave_height * 0.5;
	wave += sin((VERTEX.x + VERTEX.z) * 4.5 + TIME * 0.7)
	      * wave_height * 0.35;
	VERTEX.y += wave;
}

void fragment() {
	// Animated ripple pattern (visible at all angles)
	vec2 uv1 = UV * 15.0 + vec2(TIME * 0.1, TIME * 0.06);
	vec2 uv2 = UV * 28.0 - vec2(TIME * 0.15, TIME * 0.2);
	float ripple = sin(uv1.x * 1.5) * cos(uv1.y * 1.8)
	             + sin(uv2.x * 2.0) * cos(uv2.y * 2.2);
	ripple = ripple * 0.12 + 0.88; // subtle brightness variation

	// moving light bands (caustic-like)
	float caustic = sin(uv1.x + uv1.y + TIME) * cos(uv1.x - uv1.y + TIME * 0.7);
	caustic = abs(caustic) * 0.08;

	// Foam lines along wave crests (using world position)
	float foam = sin(VERTEX.x * 8.0 + TIME) * cos(VERTEX.z * 8.0 - TIME * 0.6);
	foam = smoothstep(0.7, 0.85, abs(foam)) * 0.25;

	vec3 color = water_color.rgb * (ripple + caustic) + foam * vec3(0.6, 0.8, 1.0);

	// Specular
	vec3 half_vec = normalize(normalize(VIEW) + vec3(0.0, 1.0, 0.0));
	float spec = pow(max(dot(NORMAL, half_vec), 0.0), 128.0) * 0.4;

	ALBEDO = color;
	ALPHA = water_color.a;
	METALLIC = 0.0;
	ROUGHNESS = 0.2;
	SPECULAR = spec;
}
