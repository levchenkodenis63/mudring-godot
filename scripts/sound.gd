extends Node
## Проигрывание синтезатора (synth.gd) через AudioStreamGenerator: каждый кадр досыпаем столько
## сэмплов, сколько освободилось в буфере.

const Synth = preload("res://scripts/synth.gd")

var synth = Synth.new()
var _player: AudioStreamPlayer
var _pb: AudioStreamGeneratorPlayback
var synth_us := 0             # сколько мкс ушло на синтез (для замера на телефоне)


func _ready() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = Synth.RATE
	gen.buffer_length = 0.1
	_player = AudioStreamPlayer.new()
	_player.stream = gen
	add_child(_player)
	_player.play()
	_pb = _player.get_stream_playback()


func _process(_delta: float) -> void:
	if _pb == null:
		return
	var n := _pb.get_frames_available()
	if n > 0:
		var t0 := Time.get_ticks_usec()
		_pb.push_buffer(synth.render(n))
		synth_us += Time.get_ticks_usec() - t0
