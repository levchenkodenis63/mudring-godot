// Квадроцикл из models/atv.glb: цвет — в вершинах, UV.x — код перекраски (см. tools/blender/atv.py):
// 1 — свой цвет, 0 — краска корпуса, 0.25 — акцент, 0.5 — джерси, 0.75 — шлем. Плюс налипающая грязь (dirt 0..1).
shader_type spatial;

uniform vec3 paint : source_color = vec3(0.878, 0.706, 0.094);
uniform vec3 accent : source_color = vec3(0.106, 0.106, 0.125);
uniform vec3 jersey : source_color = vec3(0.949, 0.812, 0.275);
uniform vec3 helmet : source_color = vec3(0.090, 0.090, 0.106);
uniform vec3 mud : source_color = vec3(0.26, 0.23, 0.19);   // тёмная серо-коричневая, как на фото
uniform float dirt = 0.0;
uniform float dirt_low = 0.0;   // высота (в координатах детали), ниже которой грязь гуще

varying float noise_v;   // шум грязи — считается в вершинах (на мобильном GPU по пикселям дорого)
varying float low_v;

float hash(vec3 p) {
	return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = mix(mix(hash(i), hash(i + vec3(1, 0, 0)), f.x), mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y);
	float b = mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x), mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y);
	return mix(a, b, f.z);
}

void vertex() {
	vec3 p = VERTEX;
	noise_v = vnoise(p * 16.0) * 0.5 + vnoise(p * 41.0) * 0.3 + vnoise(p * 5.0) * 0.2;
	low_v = clamp((dirt_low + 0.75 - p.y) * 1.2, 0.0, 1.0);        // снизу гуще
}

void fragment() {
	float code = UV.x;
	vec3 c = COLOR.rgb;
	if (code < 0.125) {
		c = paint;
	} else if (code < 0.375) {
		c = accent;
	} else if (code < 0.625) {
		c = jersey;
	} else if (code < 0.875) {
		c = helmet;
	}
	// грязь: пятнами (шум), гуще снизу
	float n = noise_v;
	float low = low_v;
	float m = smoothstep(0.15, 0.85, dirt * (0.55 + low * 1.1) + (n - 0.5) * 0.6);
	vec3 wet = mud * (0.75 + 0.5 * n);                                     // неоднородная, местами темнее
	ALBEDO = mix(c, wet, m * 0.9);
	ROUGHNESS = mix(0.5, 0.95, m);
	SPECULAR = 0.4;
}
