extends SceneTree
## Иконка 512×512 без графического редактора: небо, грязевая волна, колесо, жёлтая полоса.
## godot --headless --path . -s tools/make_icon.gd  → img/icon.png

func _init() -> void:
	var N := 512
	var img := Image.create(N, N, false, Image.FORMAT_RGBA8)
	var sky := Color("#e0b418")
	var mud := Color("#4a3520")
	var mud2 := Color("#6b5636")
	var tyre := Color("#141416")
	var rim := Color("#f2cf46")
	for y in N:
		for x in N:
			var c := sky.lerp(Color("#f2cf46"), float(y) / N * 0.6)
			var wave := N * 0.68 + sin(x * 0.025) * 14.0
			if y > wave:
				c = mud2 if y < wave + 18.0 else mud
			# колесо
			var d := Vector2(x - N * 0.5, y - N * 0.52).length()
			if d < N * 0.27:
				c = tyre
				var a := atan2(y - N * 0.52, x - N * 0.5)
				if d > N * 0.23 and fmod(a * 12.0 / TAU + 10.0, 1.0) < 0.5:
					c = Color("#26262a")            # грунтозацепы
				if d < N * 0.12:
					c = rim
				if d < N * 0.04:
					c = tyre
				if y > wave + 6.0 and d > N * 0.12:
					c = c.lerp(mud, 0.55)          # колесо в грязи
			# брызги
			for k in 7:
				var p := Vector2(N * (0.16 + k * 0.11), N * (0.6 - 0.06 * sin(k * 1.7)) - 30.0 * (k % 2))
				if Vector2(x, y).distance_to(p) < 9.0 + (k % 3) * 4.0:
					c = mud2
			img.set_pixel(x, y, c)
	img.save_png("res://img/icon.png")
	print("icon OK")
	quit()
