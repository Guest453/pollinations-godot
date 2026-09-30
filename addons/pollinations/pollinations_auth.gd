class_name PollinationsAuth
extends Node
## Bring-your-own-Pollen authentication for Pollinations.
##
## Two ways to authenticate:
##  1. [b]Development key[/b] - set POLLINATIONS_API_KEY in the environment.
##  2. [b]Device flow[/b] - set a publishable app_key and call
##     [method start_device_flow]. Players visit
##     enter.pollinations.ai/device, enter the shown code and approve with
##     their own Pollen. Their `sk_` token is kept in memory only.

signal device_flow_started(user_code: String, verification_url: String)
signal device_flow_authorized(token: String)
signal device_flow_failed(error: String)
signal device_flow_finished()  # emitted after success OR failure

const ENTER_URL := "https://enter.pollinations.ai"
const VERIFICATION_PAGE := "https://enter.pollinations.ai/device"
const HTTP_NODE_NAME := "PollinationsAuthHTTP"

## Publishable app key (pk_...) identifying your game for the device flow.
## Never put a secret sk_ token in an exported property.
@export var app_key: String = ""

## Poll interval for the device flow, in seconds. The server asks for 5.
@export var poll_interval: float = 5.0

var token: String = ""
var _device_code: String = ""
var _deadline_ms: int = 0
var _polling: bool = false

@onready var _http: HTTPRequest = _make_http()


func _make_http() -> HTTPRequest:
	var h := HTTPRequest.new()
	h.name = HTTP_NODE_NAME
	h.timeout = 30.0
	h.use_threads = true
	add_child(h)
	return h


## Returns a player token or a development key from the environment.
## Empty string means "try anonymous". app_key is not a generation token.
func get_auth_token() -> String:
	if not token.is_empty():
		return token
	var env := OS.get_environment("POLLINATIONS_API_KEY")
	if not env.is_empty():
		token = env
		return token
	return ""


func has_token() -> bool:
	return not get_auth_token().is_empty()


## Forget the in-memory user token (e.g. after "log out").
func clear_token() -> void:
	token = ""


## STEP 1 - ask the auth server for a device code + user code.
## Emits [signal device_flow_started] with the code the player must enter.
func start_device_flow() -> Error:
	if _polling:
		return ERR_ALREADY_IN_USE
	if not app_key.begins_with("pk_"):
		device_flow_failed.emit("Set your game's publishable app key (pk_...) before connecting")
		return ERR_INVALID_PARAMETER
	var body := JSON.stringify({"client_id": app_key})
	var err := _http.request(
		ENTER_URL + "/api/device/code",
		["Content-Type: application/json", "Accept: application/json"],
		HTTPClient.METHOD_POST, body)
	if err != OK:
		device_flow_failed.emit("request failed: %d" % err)
		return err
	var result: Array = await _http.request_completed
	if not _check(result, "device code request"):
		return ERR_CONNECTION_ERROR
	var data: Dictionary = _json(result[3])
	if data.has("error"):
		device_flow_failed.emit(str(data["error"]))
		return ERR_QUERY_FAILED
	_device_code = str(data.get("device_code", ""))
	var user_code := str(data.get("user_code", ""))
	var verification_url := str(data.get("verification_uri_complete", data.get("verification_uri", VERIFICATION_PAGE)))
	_deadline_ms = Time.get_ticks_msec() + int(data.get("expires_in", 1800)) * 1000
	if _device_code.is_empty() or user_code.is_empty():
		device_flow_failed.emit("invalid device code response")
		return ERR_INVALID_DATA
	device_flow_started.emit(user_code, verification_url)
	_poll_loop()
	return OK


func _poll_loop() -> void:
	_polling = true
	while _polling:
		await get_tree().create_timer(poll_interval).timeout
		if not _polling or not is_inside_tree():
			return
		if Time.get_ticks_msec() > _deadline_ms:
			_polling = false
			device_flow_failed.emit("device code expired, start the flow again")
			device_flow_finished.emit()
			return
		var err := _http.request(
			ENTER_URL + "/api/device/token",
			["Content-Type: application/json", "Accept: application/json"],
			HTTPClient.METHOD_POST, JSON.stringify({"device_code": _device_code}))
		if err != OK:
			continue
		var result: Array = await _http.request_completed
		var data: Dictionary = _json(result[3])
		var access := str(data.get("access_token", ""))
		if access.begins_with("sk_"):
			_polling = false
			token = access
			device_flow_authorized.emit(access)
			device_flow_finished.emit()
			return
		match str(data.get("error", "")):
			"authorization_pending":
				pass  # keep waiting
			"slow_down":
				poll_interval = minf(poll_interval + 5.0, 30.0)
			"access_denied":
				_stop("authorization declined")
				return
			"expired_token":
				_stop("device code expired, start the flow again")
				return
			_:
				pass  # transport hiccups etc - keep polling until deadline


## Stop waiting for the player to approve.
func cancel_device_flow() -> void:
	_stop("cancelled")


func _stop(message: String) -> void:
	if _polling:
		_polling = false
		device_flow_failed.emit(message)
		device_flow_finished.emit()


func _check(result: Array, what: String) -> bool:
	if result[0] != HTTPRequest.RESULT_SUCCESS:
		device_flow_failed.emit("%s: HTTP result %d" % [what, result[0]])
		return false
	return true


func _json(raw: PackedByteArray) -> Dictionary:
	var parsed = JSON.parse_string(raw.get_string_from_utf8())
	return parsed if parsed is Dictionary else {}
