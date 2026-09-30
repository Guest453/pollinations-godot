class_name PollinationsImage
extends Node
## Image generation with the Pollinations API.
##
## Usage:
##     @onready var img: PollinationsImage = $PollinationsImage
##     func _ready() -> void:
##         img.completed.connect(func(tex): $Sprite2D.texture = tex)
##         img.generate("a red cube on white background")
##
## Requires a token (device flow via [PollinationsAuth] or POLLINATIONS_API_KEY).

signal generation_started(prompt: String)
signal completed(texture: Texture2D)
signal failed(error: String)

signal saved(path: String)

const IMAGE_URL := PollinationsAPI.IMAGE_GENERATIONS_URL
const SAVE_DIR := "user://pollinations"

## Model id from https://gen.pollinations.ai/image/models
@export var model: String = PollinationsAPI.DEFAULT_IMAGE_MODEL

## Image width/height in pixels.
@export var width: int = 1024
@export var height: int = 1024

## Keep a copy of every generated image in user://pollinations/ .
@export var save_to_disk: bool = false

## API key / token. Usually left empty: PollinationsAuth::get_auth_token()
## or the POLLINATIONS_API_KEY environment variable is used instead.
var auth_token: String = ""

var _http: HTTPRequest
var last_texture: Texture2D


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.name = "ImageHTTP"
	_http.timeout = 300.0
	_http.use_threads = true
	add_child(_http)


## Ask the model list endpoint which image models exist right now.
func list_models() -> Array:
	return await PollinationsAPI.fetch_models(PollinationsAPI.IMAGE_MODELS_URL, _effective_token())


## Generate an image for `prompt`. Emits `completed` with a Texture2D that can
## be assigned straight to a Sprite2D / TextureRect.
func generate(prompt: String) -> void:
	generation_started.emit(prompt)
	var body: Dictionary = {
		"model": model,
		"prompt": prompt,
		"width": width,
		"height": height,
	}
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Accept: application/json",
		"User-Agent: " + PollinationsAPI.USER_AGENT,
	])
	var tok := _effective_token()
	if tok.is_empty():
		failed.emit("no API token: connect a Pollen account via PollinationsAuth or set POLLINATIONS_API_KEY")
		return
	headers.append("Authorization: Bearer " + tok)

	var err := _http.request(IMAGE_URL, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		failed.emit("request could not be started (error %d)" % err)
		return
	var result: Array = await _http.request_completed
	if result[0] != HTTPRequest.RESULT_SUCCESS:
		failed.emit("connection failed (HTTP result %d)" % result[0])
		return
	var http_code: int = result[1]
	var parsed = JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8())
	if http_code != 200 or not (parsed is Dictionary):
		failed.emit(_error_message(http_code, parsed))
		return
	var data: Array = parsed.get("data", [])
	if data.is_empty():
		failed.emit("response contained no image data")
		return
	var b64 := str(data[0].get("b64_json", ""))
	if b64.is_empty():
		failed.emit("response contained no b64_json field")
		return
	var img := Image.new()
	var buf := PackedByteArray()
	buf.append_array(Marshalls.base64_to_raw(b64))
	var decode_error := img.load_jpg_from_buffer(buf)
	if decode_error != OK:
		decode_error = img.load_png_from_buffer(buf)
	if decode_error != OK:
		failed.emit("could not decode image bytes (unsupported format)")
		return
	var texture := ImageTexture.create_from_image(img)
	last_texture = texture
	if save_to_disk:
		var path := _save(img)
		if not path.is_empty():
			saved.emit(path)
	completed.emit(texture)


## Save the last generated image under user://pollinations/.
func save_last(path: String = "") -> String:
	if last_texture == null:
		return ""
	var img := last_texture.get_image()
	return _save(img, path)


func _save(img: Image, path: String = "") -> String:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	if path.is_empty():
		path = SAVE_DIR + "/image_%d.png" % Time.get_unix_time_from_system()
	var save_error := img.save_png(path)
	if save_error != OK:
		push_warning("[PollinationsImage] could not save to %s (error %d)" % [path, save_error])
		return ""
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
	return "HTTP %d (raw image response could not be parsed)" % http_code
