// Сгенерированная модель квадроцикла (models/atv_gen.glb): запечённые цвет и нормали.
// Боты перекрашиваются сдвигом оттенка: меняются только насыщенные цвета (пластик, экипировка),
// грязь, резина и чёрные детали остаются как есть.
shader_type spatial;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_disable;
uniform float hue = 0.0;        // 0..1 — на сколько повернуть оттенок

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
	vec3 p = abs(fract(c.xxx + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
	return c.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

void fragment() {
	vec3 c = texture(albedo_tex, UV).rgb;
	if (hue != 0.0) {
		vec3 h = rgb2hsv(c);
		float k = smoothstep(0.25, 0.5, h.y) * smoothstep(0.03, 0.1, h.z);
		h.x = fract(h.x + hue);
		c = mix(c, hsv2rgb(h), k);
	}
	ALBEDO = c;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	ROUGHNESS = 0.75;
	SPECULAR = 0.35;
}
