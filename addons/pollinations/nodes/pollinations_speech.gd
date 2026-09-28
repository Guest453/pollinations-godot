class_name PollinationsSpeech
extends Node
## Speech / TTS generation with the Pollinations API.
##
## Usage:
##     @onready var speech: PollinationsSpeech = $PollinationsSpeech
##     func _ready() -> void:
##         speech.speak("Welcome, adventurer!")
##
## The generated clip can also be used as a regular stream, e.g. by pointing
## an AudioStreamPlayer at `last_stream`.
## Requires a token (device flow via [PollinationsAuth] or POLLINATIONS_API_KEY).

signal generation_started(text: String)
signal completed(stream: AudioStreamWAV)
signal failed(error: String)

signal saved(path: String)

const AUDIO_URL := PollinationsAPI.AUDIO_SPEECH_URL
const SAVE_DIR := "user://pollinations"

## Model id from https://gen.pollinations.ai/audio/models
@export var model: String = PollinationsAPI.DEFAULT_AUDIO_MODEL

## Voice name offered by the model (see the `voices` array in the model list).
@export var voice: String = "Alnilam"

## Speaking speed, 1.0 = normal.
@export_range(0.25, 4.0, 0.05) var speed: float = 1.0

## Keep a copy of every generated clip in user://pollinations/ .
@export var save_to_disk: bool = true

## Play the clip through a child AudioStreamPlayer as soon as it is ready.
@export var autoplay: bool = true

## API key / token. Usually left empty: PollinationsAuth::get_auth_token()
## or the POLLINATIONS_API_KEY environment variable is used instead.
@export var auth_token: String = ""

var _http: HTTPRequest
var _player: AudioStreamPlayer
var last_stream: AudioStreamWAV


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.name = "SpeechHTTP"
	_http.timeout = 300.0
	_http.use_threads = true
	add_child(_http)
	_player = AudioStreamPlayer.new()
	_player.name = "Playback"
	add_child(_player)


## Ask the model list endpoint which audio models exist right now.
func list_models() -> Array:
	return await PollinationsAPI.fetch_models(PollinationsAPI.AUDIO_MODELS_URL, _effective_token())


## Convert `text` to speech, then either play it (autoplay) or emit it.
func speak(text: String) -> void:
	generation_started.emit(text)
	var body: Dictionary = {
		"model": model,
		"input": text,
		"voice": voice,
		"speed": speed,
		"response_format": "wav",
	}
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Accept: audio/wav",
		"User-Agent: " + PollinationsAPI.USER_AGENT,
	])
	var tok := _effective_token()
	if tok.is_empty():
		failed.emit("no API token: connect a Pollen account via PollinationsAuth or set POLLINATIONS_API_KEY")
		return
	headers.append("Authorization: Bearer " + tok)

	var err := _http.request(AUDIO_URL, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		failed.emit("request could not be started (error %d)" % err)
		return
	var result: Array = await _http.request_completed
	if result[0] != HTTPRequest.RESULT_SUCCESS:
		failed.emit("connection failed (HTTP result %d)" % result[0])
		return
	var http_code: int = result[1]
	var raw: PackedByteArray = result[3]
	var stream := _wav_to_stream(raw)
	if stream == null:
		var parsed = JSON.parse_string(raw.get_string_from_utf8())
		failed.emit(_error_message(http_code, parsed))
		return
	last_stream = stream
	if save_to_disk:
		var path := _save(raw)
		if not path.is_empty():
			saved.emit(path)
	completed.emit(stream)
	if autoplay:
		play()


## Play the most recent clip again.
func play() -> void:
	if last_stream:
		_player.stream = last_stream
		_player.play()


func stop() -> void:
	_player.stop()


## Minimal RIFF/WAVE (PCM 16-bit) parser -> AudioStreamWAV.
func _wav_to_stream(raw: PackedByteArray) -> AudioStreamWAV:
	if raw.size() < 44 or raw.slice(0, 4).get_string_from_ascii() != "RIFF":
		return null
	var pos := 12
	var fmt: Dictionary = {}
	var data := PackedByteArray()
	while pos + 8 <= raw.size():
		var chunk_id := raw.slice(pos, pos + 4).get_string_from_ascii()
		var chunk_size := _u32(raw, pos + 4)
		var body_start := pos + 8
		match chunk_id:
			"fmt ":
				fmt = {
					"audio_format": _u16(raw, body_start),
					"channels": _u16(raw, body_start + 2),
					"sample_rate": _u32(raw, body_start + 4),
					"bits": _u16(raw, body_start + 14),
				}
			"data":
				data = raw.slice(body_start, mini(body_start + chunk_size, raw.size()))
		pos = body_start + chunk_size + (chunk_size & 1)  # chunks are word-aligned
	if fmt.is_empty() or data.is_empty():
		return null
	if int(fmt.get("audio_format", -1)) != 1 or int(fmt.get("bits", 0)) != 16:
		return null  # only uncompressed PCM16 is supported
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = int(fmt.get("sample_rate", 24000))
	stream.stereo = int(fmt.get("channels", 1)) > 1
	stream.data = data
	return stream


func _u16(raw: PackedByteArray, offset: int) -> int:
	if offset + 2 > raw.size():
		return 0
	return raw[offset] | (raw[offset + 1] << 8)


func _u32(raw: PackedByteArray, offset: int) -> int:
	if offset + 4 > raw.size():
		return 0
	return raw[offset] | (raw[offset + 1] << 8) | (raw[offset + 2] << 16) | (raw[offset + 3] << 24)


func _save(raw: PackedByteArray, path: String = "") -> String:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	if path.is_empty():
		path = SAVE_DIR + "/speech_%d.wav" % Time.get_unix_time_from_system()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[PollinationsSpeech] could not save to %s" % path)
		return ""
	f.store_buffer(raw)
	f.close()
	return path


func _effective_token() -> String:
	if not auth_token.is_empty():
		return auth_token
	var auth := get_node_or_null("../PollinationsAuth") as PollinationsAuth
	if auth:
		return auth.get_auth_token()
	return OS.get_environment("POLLINATIONS_API_KEY")


func _error_message(http_code: int, parsed) -> String:
	if parsed is Dictionary and parsed.has("error"):
		var e = parsed["error"]
		if e is Dictionary and e.has("message"):
			return "HTTP %d: %s" % [http_code, str(e["message"])]
		return "HTTP %d: %s" % [http_code, str(e)]
	return "HTTP %d: response was not a WAV file" % http_code
