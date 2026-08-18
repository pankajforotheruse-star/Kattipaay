# AudioManager.gd — Procedural audio for CHALK GAON: Ghost Lines
#
# Generates all sounds at runtime using AudioStreamGenerator — zero asset files.
# Single AudioStreamPlayer child, ~18 KB steady-state buffer (Android budget,
# full math in docs/android-optimization.md §Audio).
#
# Sounds:
#   - argument_start:   Rising tension tone (200→600 Hz sweep, 0.5s)
#   - argument_result:  Ascending chime (success) or descending buzz (fail)
#   - timer_warning:    Tick-tock pulse
#   - accusation_blurt: Sharp noise burst (0.15s)
#   - cow_moo:          Ambient moo (0.8s — the longest sound)
#
# Memory budget (Prompt 16): every sound is a simple tone ≤ 1200 Hz (the
# timer tick), so 22.05 kHz sampling (11 kHz Nyquist) has 9x headroom over the
# highest generated frequency — transparent, but half the CPU and transient
# memory of 44.1 kHz. Frames are computed mono and mirrored to both channels.
# Packaged audio: 0 bytes (all procedural) vs the GDD §11 ≤ 4 MB budget.
# Peak transient (cow_moo): 0.8 s × 22050 × 8 B ≈ 141 KB.
# Steady state: generator buffer 0.1 s × 22050 × 8 B ≈ 17.6 KB.

extends Node

# ── Audio Params ──────────────────────────────────────────────────────────────

## Sample rate for generated streams. 22.05 kHz: the highest generated
## frequency is 1200 Hz (tick), well under the 11 kHz Nyquist limit, so the
## drop from 44.1 kHz is inaudible while halving CPU and transient memory.
## If a future sound needs > 11 kHz content, raise the rate for that sound.
const SAMPLE_RATE := 22050
const BUFFER_LENGTH := 0.1  # seconds of buffer

var _player: AudioStreamPlayer = null
var _generator: AudioStreamGenerator = null
var _playback: AudioStreamGeneratorPlayback = null

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
    _setup_audio()
    print("AudioManager: ready — procedural audio initialized")

func _setup_audio() -> void:
    # Create AudioStreamGenerator
    _generator = AudioStreamGenerator.new()
    _generator.mix_rate = SAMPLE_RATE
    _generator.buffer_length = BUFFER_LENGTH

    # Create player
    _player = AudioStreamPlayer.new()
    _player.name = "AudioManagerPlayer"
    _player.stream = _generator
    _player.volume_db = -6.0  # Slightly reduced to avoid clipping
    add_child(_player)

    _player.play()
    _playback = _player.get_stream_playback()

# ── Public Sound Methods ──────────────────────────────────────────────────────

## Rising tension tone: 200Hz → 600Hz sweep over 0.5 seconds.
func play_argument_start() -> void:
    var duration := 0.5
    var samples := int(SAMPLE_RATE * duration)
    var frames := _generate_rising_tone(samples, 200.0, 600.0, duration)
    _push_frames(frames)

## Argument result: ascending chime (success) or descending buzz (fail).
func play_argument_result(success: bool) -> void:
    if success:
        # Three quick ascending notes: C5→E5→G5 (523→659→784 Hz)
        var frames := _generate_chime_ascending()
        _push_frames(frames)
    else:
        # Descending buzz: 150Hz → 60Hz over 0.3s
        var duration := 0.3
        var samples := int(SAMPLE_RATE * duration)
        var frames := _generate_rising_tone(samples, 150.0, 60.0, duration)
        # Add distortion via amplitude modulation
        for i in range(frames.size()):
            var t := float(i) / float(SAMPLE_RATE)
            frames[i] *= 0.3 + 0.7 * sin(t * 80.0 * TAU)  # Rough buzz
        _push_frames(frames)

## Tick-tock pulse: two quick alternating ticks.
func play_timer_warning() -> void:
    var frames: Array[Vector2] = []
    var tick_duration := 0.03  # 30ms per tick
    var tick_samples := int(SAMPLE_RATE * tick_duration)
    var gap_samples := int(SAMPLE_RATE * 0.12)  # gap between ticks

    for _tick_idx in range(2):
        # Tick: short high-pitched burst at 1200Hz
        for i in range(tick_samples):
            var t := float(i) / float(SAMPLE_RATE)
            var amp := exp(-t * 40.0)  # Quick decay
            var val := amp * sin(t * 1200.0 * TAU)
            frames.append(Vector2(val, val))
        # Gap: silence
        for _i in range(gap_samples):
            frames.append(Vector2.ZERO)

    _push_frames(frames)

## Sharp noise burst — 0.15 second chaotic tone.
func play_accusation_blurt() -> void:
    var duration := 0.15
    var samples := int(SAMPLE_RATE * duration)
    var frames: Array[Vector2] = []

    for i in range(samples):
        var t := float(i) / float(SAMPLE_RATE)
        # Noise-like: mix of frequencies with fast decay
        var amp := exp(-t * 25.0) * 0.6
        var val := amp * (sin(t * 800.0 * TAU) + sin(t * 950.0 * TAU) * 0.7 + sin(t * 1100.0 * TAU) * 0.5) / 2.2
        frames.append(Vector2(val, val))

    _push_frames(frames)

## Cow moo: 200Hz base with vibrato ±15Hz at 5Hz, 0.8s total.
## Attack 0.1s, sustain 0.4s, release 0.3s.
func play_cow_moo() -> void:
    var duration := 0.8
    var samples := int(SAMPLE_RATE * duration)
    var frames: Array[Vector2] = []
    var phase: float = 0.0

    for i in range(samples):
        var t := float(i) / float(SAMPLE_RATE)

        # Vibrato: ±15Hz modulation at 5Hz
        var vibrato := sin(t * 5.0 * TAU) * 15.0
        var freq := 200.0 + vibrato

        # Envelope: attack 0.1 / sustain 0.4 / release 0.3
        var env: float = 1.0
        var attack_end := 0.1
        var sustain_end := attack_end + 0.4  # 0.5

        if t < attack_end:
            env = t / attack_end
        elif t < sustain_end:
            env = 1.0
        else:
            var release_time := duration - sustain_end  # 0.3
            env = maxf(0.0, (duration - t) / release_time)

        phase += freq / float(SAMPLE_RATE)
        phase = fmod(phase, 1.0)

        var val := env * 0.4 * sin(phase * TAU)
        frames.append(Vector2(val, val))

    _push_frames(frames)

# ── Generator Helpers ─────────────────────────────────────────────────────────

## Generate a frequency sweep from start_hz to end_hz over duration.
func _generate_rising_tone(samples: int, start_hz: float, end_hz: float, duration: float) -> Array[Vector2]:
    var frames: Array[Vector2] = []
    var phase: float = 0.0

    for i in range(samples):
        var t := float(i) / float(SAMPLE_RATE)
        var freq := lerpf(start_hz, end_hz, t / duration)

        # Envelope: fade in quickly, hold, fade out
        var env: float = 1.0
        var fade_in := 0.02
        var fade_out := 0.08
        if t < fade_in:
            env = t / fade_in
        elif t > duration - fade_out:
            env = (duration - t) / fade_out

        phase += freq / float(SAMPLE_RATE)
        phase = fmod(phase, 1.0)  # Keep in [0, 1)

        var val := env * 0.4 * sin(phase * TAU)
        frames.append(Vector2(val, val))

    return frames

## Generate three quick ascending chime notes (C5→E5→G5).
func _generate_chime_ascending() -> Array[Vector2]:
    var notes := [523.25, 659.25, 783.99]  # C5, E5, G5
    var note_duration := 0.1
    var gap_duration := 0.03
    var frames: Array[Vector2] = []

    for note_idx in range(notes.size()):
        var freq: float = float(notes[note_idx])
        var note_samples := int(SAMPLE_RATE * note_duration)
        var phase: float = 0.0

        for i in range(note_samples):
            var t := float(i) / float(SAMPLE_RATE)
            var env := exp(-t * 8.0)  # Gentle percussive decay
            phase += freq / float(SAMPLE_RATE)
            phase = fmod(phase, 1.0)
            var val := env * 0.35 * sin(phase * TAU)
            frames.append(Vector2(val, val))

        # Short gap between notes
        var gap_samples := int(SAMPLE_RATE * gap_duration)
        for _i in range(gap_samples):
            frames.append(Vector2.ZERO)

    return frames

## Push generated frames to the audio playback buffer.
func _push_frames(frames: Array[Vector2]) -> void:
    if not _playback:
        return
    for frame in frames:
        _playback.push_frame(frame)
