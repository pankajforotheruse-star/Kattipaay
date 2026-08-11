# SaveManager.gd — Local + server save/load abstraction
# Prototype: only local save is implemented.

extends Node

## Save a dictionary to local storage as JSON.
func save_local(key: String, data: Dictionary) -> void:
	var file := FileAccess.open("user://%s.dat" % key, FileAccess.WRITE)
	if not file:
		push_error("SaveManager: could not open file for writing: %s" % key)
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	EventBus.emit(EventBus.EV_SAVE_LOCAL_COMPLETE, {"key": key})

## Load a dictionary from local storage. Returns default if file missing or corrupt.
func load_local(key: String, default: Dictionary) -> Dictionary:
	if not FileAccess.file_exists("user://%s.dat" % key):
		return default

	var file := FileAccess.open("user://%s.dat" % key, FileAccess.READ)
	if not file:
		return default

	var text := file.get_as_text()
	file.close()

	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		push_warning("SaveManager: corrupt save file '%s', using default" % key)
		return default

	var result = json.get_data()
	if typeof(result) != TYPE_DICTIONARY:
		return default
	return result

## Stub: server save (will use Nakama Storage).
func save_server(_collection: String, _data: Dictionary) -> void:
	push_warning("SaveManager: server save not implemented in prototype")

## Stub: server load.
func load_server(_collection: String, _key: String):
	push_warning("SaveManager: server load not implemented in prototype")
