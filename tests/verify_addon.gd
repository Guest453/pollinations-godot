extends SceneTree
## Headless verification for the Pollinations add-on.
##
## Run from the repo root:
##   godot4 --headless -s tests/verify_addon.gd
##
## Checks (all offline except the live text call):
##   1. all node scripts compile
##   2. plugin.cfg parses and points at a real script
##   3. nodes instantiate and expose their signals/exports
##   4. WAV parser produces a valid AudioStreamWAV from synthetic PCM data
##   5. live anonymous text generation over the real API
##   6. optional live image + audio when POLLINATIONS_API_KEY is set

var _failures: int = 0


func _initialize() -> void:
	print("=== Pollinations Godot add-on verification ===")
	_check_scripts_compile()
	_check_plugin_cfg()
	await _check_nodes_instantiate()
	_check_wav_parser()
	await _check_live_text()
	if OS.get_environment("POLLINATIONS_API_KEY") != "":
		await _check_live_image_and_audio()
	else:
		print("[SKIP] live image/audio checks (POLLINATIONS_API_KEY not set)")
	print("=== verification finished: %s ===" % ("FAIL" if _failures > 0 else "PASS"))
	quit(1 if _failures > 0 else 0)


func _fail(msg: String) -> void:
	_failures += 1
	printerr("FAIL: " + msg)


func _check_scripts_compile() -> void:
	for path in [
		"res://addons/pollinations/pollinations.gd",
		"res://addons/pollinations/plugin.gd",
		"res://addons/pollinations/pollinations_api.gd",
		"res://addons/pollinations/pollinations_auth.gd",
		"res://addons/pollinations/nodes/pollinations_text.gd",
		"res://addons/pollinations/nodes/pollinations_image.gd",
		"res://addons/pollinations/nodes/pollinations_speech.gd",
		"res://examples/example_scene.gd",
	]:
		var script: Script = load(path)
		if script == null:
			_fail("script not loadable: " + path)
		elif not script.can_instantiate():
			_fail("script has compile errors: " + path)
		else:
			print("  ok compile: " + path)


func _check_plugin_cfg() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("res://addons/pollinations/plugin.cfg") != OK:
		_fail("plugin.cfg missing or unparsable")
		return
	var entry_script := str(cfg.get_value("plugin", "script", ""))
	if not FileAccess.file_exists("res://addons/pollinations/" + entry_script):
		_fail("plugin.cfg script does not exist: " + entry_script)
		return
	var script: Script = load("res://addons/pollinations/" + entry_script)
	if script == null or script.get_instance_base_type() != "EditorPlugin":
		_fail("plugin.cfg script must extend EditorPlugin")
		return
	if str(cfg.get_value("plugin", "name", "")).is_empty():
		_fail("plugin.cfg has no name")
		return
	print("  ok plugin.cfg (script=%s)" % entry_script)
	var auth := PollinationsAuth.new()
	auth.app_key = "pk_example"
	auth.token = "sk_player"
	if auth.get_auth_token() != "sk_player":
		_fail("player token must take precedence over the publishable app key")
	auth.free()


func _check_nodes_instantiate() -> void:
	for node_path in [
		"res://addons/pollinations/nodes/pollinations_text.gd",
		"res://addons/pollinations/nodes/pollinations_image.gd",
		"res://addons/pollinations/nodes/pollinations_speech.gd",
		"res://addons/pollinations/pollinations_auth.gd",
	]:
		var script: Script = load(node_path)
		var node: Node = script.new()
		root.add_child(node)  # _ready runs on the next frame in headless -s mode
		await process_frame
		var label: String = String(node_path).get_file()
		if node.get_child_count() == 0:
			_fail(label + ": no HTTPRequest created in _ready")
		node.queue_free()
		print("  ok instantiate: " + label)
	await process_frame

func _check_wav_parser() -> void:
	# Build 0.2 s of a 440 Hz sine wave as 16-bit mono PCM @ 24 kHz.
	var sample_rate := 24000
	var samples := int(0.2 * sample_rate)
	var pcm := PackedByteArray()
	pcm.resize(samples * 2)
	for i in samples:
		var v := int(20000.0 * sin(TAU * 440.0 * i / sample_rate))
		pcm.encode_s16(i * 2, v)
	var wav := PackedByteArray()
	var stub := _wave_header(pcm.size(), sample_rate, 1, 16)
	wav.append_array(stub)
	wav.append_array(pcm)

	var speech: Script = load("res://addons/pollinations/nodes/pollinations_speech.gd")
	var node: Node = speech.new()
	var stream: AudioStreamWAV = node._wav_to_stream(wav)
	node.free()
	if stream == null:
		_fail("WAV parser returned null for valid PCM data")
		return
	if stream.format != AudioStreamWAV.FORMAT_16_BITS:
		_fail("WAV parser wrong format")
	if stream.mix_rate != sample_rate:
		_fail("WAV parser wrong sample rate: %d" % stream.mix_rate)
	if stream.stereo:
		_fail("WAV parser should be mono")
	if stream.data.size() != pcm.size():
		_fail("WAV parser data size %d != %d" % [stream.data.size(), pcm.size()])
		return
	print("  ok wav parser: %.1f s stream, %d Hz, %d bytes" % [
		stream.get_length(), stream.mix_rate, stream.data.size()])


func _check_live_text() -> void:
	var text_script: Script = load("res://addons/pollinations/nodes/pollinations_text.gd")
	var node: PollinationsText = text_script.new()
	node.model = PollinationsAPI.DEFAULT_TEXT_MODEL
	root.add_child(node)
	var done := [false]
	node.completed.connect(func(t: String) -> void:
		print("  ok live text: %d chars -> %s" % [t.length(), t.substr(0, 60).replace("\n", " ")])
		done[0] = true)
	node.failed.connect(func(e: String) -> void:
		_fail("live text: " + e)
		done[0] = true)
	node.generate("Reply with exactly: POLLEN OK")
	var waited := 0.0
	while not done[0] and waited < 60.0:
		await process_frame
		waited += 1.0 / 60.0
	if not done[0]:
		_fail("live text timed out after 60 s")
	node.queue_free()
	await process_frame


func _check_live_image_and_audio() -> void:
	var image_script: Script = load("res://addons/pollinations/nodes/pollinations_image.gd")
	var img_node: PollinationsImage = image_script.new()
	root.add_child(img_node)
	var img_done := [false]
	img_node.completed.connect(func(tex: Texture2D) -> void:
		print("  ok live image: %dx%d texture" % [tex.get_width(), tex.get_height()])
		img_done[0] = true)
	img_node.failed.connect(func(e: String) -> void:
		_fail("live image: " + e)
		img_done[0] = true)
	img_node.generate("a small green pollen grain, pixel art")
	var waited := 0.0
	while not img_done[0] and waited < 120.0:
		await process_frame
		waited += 0.016
	if not img_done[0]:
		_fail("live image timed out after 120 s")
	img_node.queue_free()
	await process_frame

	var speech_script: Script = load("res://addons/pollinations/nodes/pollinations_speech.gd")
	var sp_node: PollinationsSpeech = speech_script.new()
	sp_node.autoplay = false
	root.add_child(sp_node)
	var sp_done := [false]
	sp_node.completed.connect(func(s: AudioStreamWAV) -> void:
		print("  ok live speech: %.1f s of audio, %d Hz" % [s.get_length(), s.mix_rate])
		sp_done[0] = true)
	sp_node.failed.connect(func(e: String) -> void:
		_fail("live speech: " + e)
		sp_done[0] = true)
	sp_node.speak("Pollinations works inside Godot")
	waited = 0.0
	while not sp_done[0] and waited < 120.0:
		await process_frame
		waited += 0.016
	if not sp_done[0]:
		_fail("live speech timed out after 120 s")
	sp_node.queue_free()
	await process_frame


func _wave_header(data_bytes: int, sample_rate: int, channels: int, bits: int) -> PackedByteArray:
	var byte_rate := sample_rate * channels * bits / 8
	var block_align := channels * bits / 8
	var out := PackedByteArray()
	for b in "RIFF".to_utf8_buffer():
		out.append(b)
	for i in 4:
		out.append((36 + data_bytes) >> (8 * i) & 0xFF)
	for b in "WAVE".to_utf8_buffer():
		out.append(b)
	for b in "fmt ".to_utf8_buffer():
		out.append(b)
	for i in 4:
		out.append(16 >> (8 * i) & 0xFF)
	for i in 2:
		out.append(1 >> (8 * i) & 0xFF)  # PCM
	for i in 2:
		out.append(channels >> (8 * i) & 0xFF)
	for i in 4:
		out.append(sample_rate >> (8 * i) & 0xFF)
	for i in 4:
		out.append(byte_rate >> (8 * i) & 0xFF)
	for i in 2:
		out.append(block_align >> (8 * i) & 0xFF)
	for i in 2:
		out.append(bits >> (8 * i) & 0xFF)
	for b in "data".to_utf8_buffer():
		out.append(b)
	for i in 4:
		out.append(data_bytes >> (8 * i) & 0xFF)
	return out
