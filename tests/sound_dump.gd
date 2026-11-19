extends SceneTree
## Демо звука без окна: сценарий заезда → .tmp/sound_demo.wav + замер скорости синтеза.
## godot --headless --path . -s tests/sound_dump.gd

const Synth = preload("res://scripts/synth.gd")


func _init() -> void:
	var sy = Synth.new()
	sy.active = true
	var block := 368                     # ~1/60 с
	var total := 0.0
	var frames := PackedVector2Array()
	var t := 0.0
	var fired := {}
	var t0 := Time.get_ticks_usec()
	var peak := 0.0
	var bad := 0
	while t < 16.0:
		# сценарий
		sy.load = false
		sy.water = false
		sy.over = false
		sy.winch = 0.0
		sy.running = true
		sy.bot_gain = 0.0
		if t < 1.5:
			sy.rpm = 0.12                                    # холостые
		elif t < 3.0:
			sy.load = t < 1.6 or t > 2.0                     # светофор, перегазовки
			sy.rpm = 0.12 + 0.6 * absf(sin((t - 1.5) * 4.0))
		elif t < 6.0:
			sy.load = true                                   # разгон по песку
			sy.rpm = minf(0.95, 0.3 + (t - 3.0) * 0.4)
			sy.bot_gain = 0.05
			sy.bot_rpm = 0.85
		elif t < 9.0:
			sy.load = true                                   # в воде, в зелёной зоне
			sy.water = true
			sy.rpm = 0.6 + 0.05 * sin(t * 3.0)
		elif t < 10.5:
			sy.load = true                                   # перекрут — отсечка
			sy.water = true
			sy.over = true
			sy.rpm = 0.95
		elif t < 12.0:
			sy.running = false                               # заглох
			sy.water = true
			sy.rpm = 0.12
		else:
			sy.load = true                                   # лебёдка
			sy.rpm = 0.6
			sy.winch = clampf((t - 12.0) * 2.0, 0.0, 1.0) if t < 15.0 else 0.0
		for ev in [[1.5, "l1"], [2.0, "l2"], [2.5, "l3"], [6.0, "clean"], [7.5, "splash"], [10.5, "overheat"], [12.0, "attach"], [15.0, "top"], [15.5, "finish"]]:
			if t >= ev[0] and not fired.has(ev[1]):
				fired[ev[1]] = true
				match ev[1]:
					"l1": sy.light(1)
					"l2": sy.light(2)
					"l3": sy.light(3)
					"clean": sy.clean()
					"splash": sy.splash(6.0)
					"overheat": sy.overheat()
					"attach": sy.clean()
					"top": sy.ui()
					"finish": sy.finish()
		var buf: PackedVector2Array = sy.render(block)
		for v in buf:
			if is_nan(v.x) or absf(v.x) > 1.0:
				bad += 1
			peak = maxf(peak, absf(v.x))
		frames.append_array(buf)
		t += block / Synth.RATE
	var us := Time.get_ticks_usec() - t0
	var audio_s := frames.size() / Synth.RATE
	print("SOUND %.1f с звука за %.0f мс — %.1f%% реального времени, пик %.2f, плохих сэмплов %d" % [audio_s, us / 1000.0, us / 10000.0 / audio_s, peak, bad])
	var pcm := PackedByteArray()
	pcm.resize(frames.size() * 2)
	for i in frames.size():
		pcm.encode_s16(i * 2, int(clampf(frames[i].x, -1.0, 1.0) * 32000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = int(Synth.RATE)
	wav.stereo = false
	wav.data = pcm
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.tmp"))
	wav.save_to_wav("res://.tmp/sound_demo.wav")
	print("WAV res://.tmp/sound_demo.wav")
	quit()
