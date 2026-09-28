extends Control
## Demo controller for the Pollinations example scene.
##
## Type a prompt and press Enter: the scene asks a Pollinations text model for
## a one-line NPC reply, generates an illustration for the prompt, and speaks
## the reply out loud with a TTS model.

@onready var prompt_input: LineEdit = $PromptInput
@onready var output: RichTextLabel = $Output
@onready var image_holder: TextureRect = $ImageHolder
@onready var status: Label = $Status

@onready var text_node: PollinationsText = $PollinationsText
@onready var image_node: PollinationsImage = $PollinationsImage
@onready var speech_node: PollinationsSpeech = $PollinationsSpeech


func _ready() -> void:
	_set_status("ready (text works anonymously; image + speech need a token)")
	prompt_input.text_submitted.connect(_on_prompt_submitted)
	text_node.completed.connect(_on_text_done)
	text_node.failed.connect(_on_text_failed)
	image_node.completed.connect(_on_image_done)
	image_node.failed.connect(_on_image_failed)
	speech_node.failed.connect(_on_speech_failed)


var _image_state := ""  # "", "ok" or an error message


func _on_prompt_submitted(prompt: String) -> void:
	if prompt.strip_edges().is_empty():
		return
	prompt_input.editable = false
	_image_state = ""
	_set_status("generating...")
	output.text = "[i]thinking...[/i]"
	image_holder.texture = null

	# 1. text reply
	text_node.generate(prompt)
	# 2. illustration for the same prompt
	image_node.generate(prompt)


func _on_text_done(text: String) -> void:
	output.text = text
	# 3. speak the reply
	speech_node.speak(text)
	_set_status("done")


func _on_text_failed(error: String) -> void:
	output.text = "[color=orange]text failed:[/color] " + error
	_maybe_done()


func _on_image_done(texture: Texture2D) -> void:
	_image_state = "ok"
	image_holder.texture = texture
	_maybe_done()


func _on_image_failed(error: String) -> void:
	_image_state = error
	output.text += "\n[color=orange]image failed:[/color] " + error
	_maybe_done()


func _on_speech_failed(error: String) -> void:
	output.text += "\n[color=orange]speech failed:[/color] " + error
	_maybe_done()


func _maybe_done() -> void:
	prompt_input.editable = true
	prompt_input.grab_focus()
	if _image_state != "" and _image_state != "ok":
		_set_status("done (image failed: see message)")


func _set_status(text: String) -> void:
	status.text = text
