class_name PollinationsAuth
extends Node
## Bring-your-own-Pollen authentication for Pollinations.
##
## Two ways to authenticate:
##  1. [b]API key[/b] - set [member api_key] (or the POLLINATIONS_API_KEY
##     environment variable) to a publishable `pk_` key for development.
##  2. [b]Device flow[/b] - call [method start_device_flow]. Players visit
##     enter.pollinations.ai/device, enter the shown code and approve with
##     their own Pollen. A secret `sk_` token is returned and stored in
##     memory (optionally in project settings via [member store_token]).

signal device_flow_started(user_code: String, verification_url: String)
signal device_flow_authorized(token: String)
signal device_flow_failed(error: String)
signal device_flow_finished()  # emitted after success OR failure

const ENTER_URL := "https://enter.pollinations.ai"
const VERIFICATION_PAGE := "https://enter.pollinations.ai/device"
const HTTP_NODE_NAME := "PollinationsAuthHTTP"

## Publishable API key (pk_...). Used directly as the bearer token when set.
## NEVER put a secret sk_ token here - use the device flow for players.
@export var api_key: String = ""

## When true, a token obtained through the device flow is written to
## `pollinations/auth/secret_token` in project settings (config/user.tres).
@export var store_token: bool = true

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


## Returns the best available token: an explicit api_key, a token from the
## device flow, a previously stored user token, or the POLLINATIONS_API_KEY
## environment variable. Empty string means "try anonymous".
func get_auth_token() -> String:
	if not api_key.is_empty():
		return api_key
	if not token.is_empty():
		return token
	var stored := ProjectSettings.get_setting("pollinations/auth/secret_token", "") as String
	if not stored.is_empty():
		token = stored
		return token
	var env := OS.get_environment("POLLINATIONS_API_KEY")
	if not env.is_empty():
		token = env
		return token
	return ""


func has_token() -> bool:
	return not get_auth_token().is_empty()


## Forget the stored user token (e.g. after "log out").
func clear_token() -> void:
	token = ""
	ProjectSettings.set_setting("pollinations/auth/secret_token", "")
	ProjectSettings.save()


## STEP 1 - ask the auth server for a device code + user code.
## Emits [signal device_flow_started] with the code the player must enter.
func start_device_flow() -> Error:
	if _polling:
		return ERR_ALREADY_IN_USE
	var body := "{}"
	# A publishable client id may be provided; the endpoint also works without.
	if not api_key.is_empty() and api_key.begins_with("pk_"):
		body = JSON.stringify({"client_id": api_key})
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
			if store_token:
				ProjectSettings.set_setting("pollinations/auth/secret_token", access)
				ProjectSettings.save()
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
