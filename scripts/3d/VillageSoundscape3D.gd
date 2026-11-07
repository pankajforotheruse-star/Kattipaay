class_name VillageSoundscape3D
extends Node3D
## Original lightweight procedural village soundscape, positional in 3D.
## Wind, cicadas, birds, and earth/stone footfalls; no copyrighted samples.
## Audio is disabled in headless CI; never creates an AudioServer stream there.
const RATE := 11025
var rng := RandomNumberGenerator.new()
var wind_player: AudioStreamPlayer3D
var insect_player: AudioStreamPlayer3D
var bird_player: AudioStreamPlayer3D
var step_player: AudioStreamPlayer3D
var step_earth: AudioStreamWAV
var step_stone: AudioStreamWAV
var bird_wait := 3.0
var step_wait := 0.0
var active := false

func _ready() -> void:
	rng.seed = 71947
	if DisplayServer.get_name() == "headless":
		return
	if not bool(ProjectSettings.get_setting("chalk_gaon/3d_sound_enabled", true)):
		return
	active = true
	wind_player = _source("WindInBanyan", Vector3(-12, 3, -10), -28.0)
	wind_player.stream = _wave("wind", 1.6, true)
	wind_player.play()
	insect_player = _source("EveningCicadas", Vector3(21, 1.7, 17), -34.0)
	insect_player.stream = _wave("insects", 1.3, true)
	insect_player.play()
	bird_player = _source("CourtyardBird", Vector3(-12, 4.6, -13), -23.0)
	bird_player.stream = _wave("bird", 0.6, false)
	step_player = _source("Footfall", Vector3.ZERO, -17.0)
	step_earth = _wave("step_earth", 0.19, false)
	step_stone = _wave("step_stone", 0.17, false)

func _source(label: String, at: Vector3, volume: float) -> AudioStreamPlayer3D:
	var source := AudioStreamPlayer3D.new()
	source.name = label
	source.position = at
	source.volume_db = volume
	source.unit_size = 8.0
	add_child(source)
	return source

func _process(delta: float) -> void:
	if not active:
		return
	bird_wait -= delta
	step_wait = maxf(0.0, step_wait - delta)
	if bird_wait <= 0.0:
		bird_wait = rng.randf_range(5.0, 13.0)
		bird_player.position = Vector3(rng.randf_range(-38.0, 38.0), rng.randf_range(3.0, 6.0), rng.randf_range(-18.0, 18.0))
		bird_player.pitch_scale = rng.randf_range(0.89, 1.12)
		bird_player.play()

func footstep(at: Vector3, speed: float, on_stone: bool = false) -> void:
	if not active or step_wait > 0.0 or speed < 1.2:
		return
	step_wait = 0.36 if speed < 6.0 else 0.24
	step_player.position = at
	step_player.stream = step_stone if on_stone else step_earth
	step_player.pitch_scale = rng.randf_range(0.92, 1.10)
	step_player.play()

func _wave(kind: String, seconds: float, looping: bool) -> AudioStreamWAV:
	var count := int(float(RATE) * seconds)
	var data := PackedByteArray()
	data.resize(count * 2)
	var noise_state := 0.0
	var phase := 0.0
	for i in range(count):
		var t := float(i) / float(RATE)
		var v := 0.0
		match kind:
			"wind":
				noise_state = lerpf(noise_state, rng.randf_range(-1.0, 1.0), 0.012)
				v = noise_state * 0.20 + 0.025 * sin(TAU * 72.0 * t)
			"insects":
				v = 0.11 * sin(TAU * 2850.0 * t) * (0.5 + 0.5 * sin(TAU * 7.0 * t))
				v += 0.04 * sin(TAU * 3400.0 * t)
			"bird":
				var envelope := pow(sin(PI * minf(t / seconds, 1.0)), 2.0)
				var chirp := 1600.0 + 750.0 * sin(TAU * 3.0 * t)
				phase += chirp / float(RATE)
				v = envelope * 0.24 * sin(TAU * phase)
			"step_earth", "step_stone":
				var decay := exp(-t * (27.0 if kind == "step_earth" else 39.0))
				noise_state = lerpf(noise_state, rng.randf_range(-1.0, 1.0), 0.34 if kind == "step_earth" else 0.68)
				v = noise_state * decay * 0.35
				v += sin(TAU * (95.0 if kind == "step_earth" else 195.0) * t) * decay * 0.10
		var sample := clampi(int(v * 32767.0), -32768, 32767)
		data[i * 2] = sample & 255
		data[i * 2 + 1] = (sample >> 8) & 255
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = RATE
	stream.stereo = false
	stream.data = data
	if looping:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_end = count
	return stream
