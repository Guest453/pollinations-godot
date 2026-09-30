class_name PollinationsText
extends Node
## Chat/text generation with the Pollinations API.
##
## Minimal usage (anonymous tier):
##     @onready var ai: PollinationsText = $PollinationsText
##     func _ready() -> void:
##         ai.prompt_submitted.connect(func(p): print("asking..."))
##         ai.completed.connect(func(t): print(t))
##         ai.generate("Write a haiku about boats")
##
## Models come from the live list at gen.pollinations.ai/text/models;
## use [method list_models] to fill a picker at runtime.

signal prompt_submitted(prompt: String)
signal completed(text: String)
signal failed(error: String)

const CHAT_URL := PollinationsAPI.CHAT_COMPLETIONS_URL

## Model id from https://gen.pollinations.ai/text/models
@export var model: String = PollinationsAPI.DEFAULT_TEXT_MODEL

## System prompt sent with every request ("" disables it).
@export_multiline var system_prompt: String = ""

## Politeness setting: higher = more random, 0 = deterministic.
@export_range(0.0, 2.0, 0.05) var temperature: float = -1.0  # -1 = omit header

## API key / token. Usually left empty: PollinationsAuth::get_auth_token()
## or the POLLINATIONS_API_KEY environment variable is used instead.
var auth_token: String = ""

var _http: HTTPRequest


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.name = "TextHTTP"
	_http.timeout = 120.0
	_http.use_threads = true
	add_child(_http)


## Ask the model list endpoint which text models exist right now.
func list_models() -> Array:
	return await PollinationsAPI.fetch_models(PollinationsAPI.TEXT_MODELS_URL, _effective_token())


## Send a chat prompt and await the answer via the `completed` signal:
##     ai.completed.connect(_on_text)
##     ai.generate("Hello!")
func generate(prompt: String, history: Array = []) -> void:
	prompt_submitted.emit(prompt)
	var messages: Array = []
	if not system_prompt.is_empty():
		messages.append({"role": "system", "content": system_prompt})
	messages.append_array(history)
	messages.append({"role": "user", "content": prompt})

	var body: Dictionary = {"model": model, "messages": messages}
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Accept: application/json",
		"User-Agent: " + PollinationsAPI.USER_AGENT,
	])
	var tok := _effective_token()
	if not tok.is_empty():
		headers.append("Authorization: Bearer " + tok)
	if temperature >= 0.0:
		headers.append("x-temp: " + String.num(temperature, 3))

	var err := _http.request(CHAT_URL, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
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
	# OpenAI-compatible response shape: choices[0].message.content
	var choices: Array = parsed.get("choices", [])
	if choices.is_empty():
		failed.emit("response contained no choices")
		return
	var text := str(choices[0].get("message", {}).get("content", ""))
	completed.emit(text)


## Convenience for quick chats: returns the assistant reply directly.
func generate_once(prompt: String, history: Array = []) -> String:
	var reply := ""
	var got := [false]
	var cb := func(text: String) -> void:
		reply = text
		got[0] = true
	completed.connect(cb, CONNECT_ONE_SHOT)
	failed.connect(func(_e: String) -> void: got[0] = true, CONNECT_ONE_SHOT)
	generate(prompt, history)
	while not got[0]:
		await get_tree().process_frame
	return reply


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
	return "HTTP %d after %d bytes" % [http_code, 0]
