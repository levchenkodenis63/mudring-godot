// Ассеты окружения из models/env.glb (через MultiMesh): цвет — в вершинах, UV.x < 0.5 — цвет экземпляра
// (INSTANCE_CUSTOM: куртки зрителей), UV.y — сила качания на ветру (трава, флаги, кроны).
shader_type spatial;
render_mode cull_disabled;

varying vec3 col;

void vertex() {
	col = COLOR.rgb;
	if (UV.x < 0.5) {
		col = INSTANCE_CUSTOM.rgb;
	}
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float s = UV.y * max(VERTEX.y, 0.0);
	VERTEX.x += sin(TIME * 1.6 + w.x * 0.35 + w.z * 0.2) * s * 0.06;
	VERTEX.z += cos(TIME * 1.3 + w.x * 0.25) * s * 0.03;
}

void fragment() {
	ALBEDO = col;
	ROUGHNESS = 0.9;
	SPECULAR = 0.2;
}
