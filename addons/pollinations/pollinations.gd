class_name Pollinations
extends Object
## Shared constants and small helpers for the Pollinations add-on.

const GEN_URL := "https://gen.pollinations.ai"
const USER_AGENT := "Pollinations-Godot/1.0 (Godot 4 add-on)"

const DEFAULT_TEXT_MODEL := "openai/gpt-5.4-nano"
const DEFAULT_IMAGE_MODEL := "tongyi-mai/z-image-turbo"
const DEFAULT_AUDIO_MODEL := "google/gemini-3.8-flash-lite-tts"

const TEXT_MODELS_URL := GEN_URL + "/text/models"
const IMAGE_MODELS_URL := GEN_URL + "/image/models"
const AUDIO_MODELS_URL := GEN_URL + "/audio/models"
const CHAT_COMPLETIONS_URL := GEN_URL + "/v1/chat/completions"
const IMAGE_GENERATIONS_URL := GEN_URL + "/v1/images/generations"
const IMAGE_EDITS_URL := GEN_URL + "/v1/images/edits"
const AUDIO_SPEECH_URL := GEN_URL + "/v1/audio/speech"


## GET a Pollinations model list. Returns an Array of Dictionaries with at
## least `name`, `title`, `description`; empty array on failure.
static func fetch_models(url: String, token: String = "") -> Array:
	var headers := PackedStringArray([
		"Accept: application/json",
		"User-Agent: " + USER_AGENT,
	])
	if not token.is_empty():
		headers.append("Authorization: Bearer " + token)
	var http := HTTPRequest.new()
	http.timeout = 30.0
	Engine.get_main_loop().root.add_child(http)
	var err := http.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return []
	var result: Array = await http.request_completed
	http.queue_free()
	if result[0] != HTTPRequest.RESULT_SUCCESS:
		return []
	var parsed = JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8())
	return parsed if parsed is Array else []


## Extract just the model ids from a model list response.
static func model_names(models: Array) -> PackedStringArray:
	var names := PackedStringArray()
	for m in models:
		if m is Dictionary and m.has("name"):
			names.append(str(m["name"]))
	return names
