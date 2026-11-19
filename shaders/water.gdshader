// Мутная вода в ванне: лёгкие волны, блики, круги и пена вокруг квадроцикла игрока.
shader_type spatial;
render_mode cull_disabled, specular_schlick_ggx, ambient_light_disabled;

uniform vec4 water_color : source_color = vec4(0.40, 0.37, 0.31, 0.95);   // серо-коричневая, как на фото
uniform vec4 sky_color : source_color = vec4(0.74, 0.82, 0.88, 1.0);
uniform vec4 foam_color : source_color = vec4(0.70, 0.62, 0.48, 1.0);
uniform float wave_amp = 0.025;
// x, z — положение квадроцикла игрока, w — сила (скорость/пробуксовка), 0 — вне воды
uniform vec4 wake = vec4(0.0, 0.0, 0.0, 0.0);

varying vec3 wpos;

float waves(vec2 p, float t) {
	return sin(p.x * 1.7 + t * 2.0) * 0.6 + sin(p.y * 2.3 - t * 1.6) * 0.4 + sin((p.x + p.y) * 3.1 + t * 2.7) * 0.25;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += waves(wpos.xz, TIME) * wave_amp;
}

void fragment() {
	vec2 p = wpos.xz;
	float t = TIME;
	float e = 0.05;
	float h0 = waves(p, t);
	float hx = waves(p + vec2(e, 0.0), t);
	float hz = waves(p + vec2(0.0, e), t);
	vec3 n = vec3(-(hx - h0) / e * wave_amp * 7.0, 1.0, -(hz - h0) / e * wave_amp * 7.0);
	// круги от квадроцикла
	vec2 d = p - wake.xy;
	float dist = length(d * vec2(0.6, 1.0));
	float ring = sin(dist * 9.0 - t * 9.0) * exp(-dist * 0.9) * wake.w;
	n.xz += normalize(d + 1e-4) * ring * 0.35;
	NORMAL = normalize((VIEW_MATRIX * vec4(normalize(n), 0.0)).xyz);
	float foam = smoothstep(1.6, 0.4, dist) * wake.w * (0.55 + 0.45 * sin(p.x * 13.0 + t * 6.0) * sin(p.y * 11.0 - t * 5.0));
	// отражение неба: под острым углом вода светлеет (Френель), рябь его ломает
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.5);
	vec3 base = mix(water_color.rgb, sky_color.rgb, clamp(0.06 + fres * 0.4, 0.0, 0.45));
	ALBEDO = mix(base, foam_color.rgb, clamp(foam, 0.0, 0.8));
	// вода непрозрачная: прозрачность дорога на мобильных GPU (Mali), а мутную воду всё равно не видно насквозь
	ROUGHNESS = mix(0.22, 0.7, clamp(foam, 0.0, 1.0));
	SPECULAR = 0.22;
}
