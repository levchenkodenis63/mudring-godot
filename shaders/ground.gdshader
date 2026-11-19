// Земля по фото соревнований: тёмная мокрая грязь колеи (блестит), травяные склоны с проплешинами сухой травы.
// Цвет вершин задаёт зону: r — доля травы (0 — грязь колеи, 1 — трава), g — влажность (темнее и глаже),
// b — положение поперёк колеи (0..1 от края до края): по нему рисуются продольные колеи от колёс.
// Деталь — из шумовой текстуры в мировых координатах (дёшево: две выборки текстуры на пиксель).
shader_type spatial;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform vec3 mud_dark : source_color = vec3(0.15, 0.12, 0.09);
uniform vec3 mud_light : source_color = vec3(0.37, 0.31, 0.23);
uniform vec3 grass_a : source_color = vec3(0.27, 0.38, 0.16);
uniform vec3 grass_b : source_color = vec3(0.43, 0.50, 0.24);
uniform vec3 straw : source_color = vec3(0.60, 0.55, 0.37);

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float n = texture(noise_tex, wpos.xz * 0.05).r;
	float d = texture(noise_tex, wpos.xz * 0.5 + vec2(0.37, 0.11)).r;
	float zone = clamp(COLOR.r + (d - 0.5) * 0.4 + (n - 0.5) * 0.3, 0.0, 1.0);   // граница трава/грязь — с неровным краем, без «камуфляжа»
	float wet = COLOR.g;
	float zl = (COLOR.b * 2.0 - 1.0) * 3.2;                                  // м поперёк колеи от центра
	float rut = smoothstep(0.55, 1.0, 0.5 + 0.5 * cos(zl * 6.5)) * smoothstep(1.7, 1.2, abs(zl)); // колеи от колёс
	float t = clamp(d * 0.7 + n * 0.3 - rut * (0.35 + d * 0.3), 0.0, 1.0);
	vec3 mud = mix(mud_dark, mud_light, t) * mix(1.0, 0.62, max(wet, rut * 0.8));
	wet = max(wet, rut * 0.7);
	vec3 gr = mix(mix(grass_a, grass_b, d), straw, smoothstep(0.48, 0.72, n));
	float g = smoothstep(0.35, 0.65, zone);
	ALBEDO = mix(mud, gr, g);
	ROUGHNESS = mix(mix(0.62, 0.2, wet) - d * 0.1, 0.95, g);
	SPECULAR = mix(0.55, 0.25, g);
}
