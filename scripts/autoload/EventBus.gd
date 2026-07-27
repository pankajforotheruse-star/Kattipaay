# EventBus.gd — Global publish/subscribe event system
# All inter-system communication flows through this singleton.
# No system holds a direct reference to another system.

extends Node

# Internal storage: { "event.name": [Callable, Callable, ...] }
var _listeners: Dictionary = {}

## Subscribe to an event. The callback receives one argument: the payload.
func on(event_name: String, callback: Callable) -> void:
	if not _listeners.has(event_name):
		_listeners[event_name] = []
	var arr: Array = _listeners[event_name]
	if callback not in arr:
		arr.append(callback)

## Unsubscribe from an event.
func off(event_name: String, callback: Callable) -> void:
	if not _listeners.has(event_name):
		return
	var arr: Array = _listeners[event_name]
	var idx := arr.find(callback)
	if idx != -1:
		arr.remove_at(idx)
	# Clean up empty arrays
	if arr.is_empty():
		_listeners.erase(event_name)

## Emit an event with an optional payload. All subscribers are called.
func emit(event_name: String, payload = null) -> void:
	if not _listeners.has(event_name):
		return
	# Iterate over a copy — subscribers might add/remove during iteration
	var arr: Array = _listeners[event_name].duplicate()
	for callback in arr:
		if payload != null:
			callback.call(payload)
		else:
			callback.call()

## Remove all listeners (used on scene teardown or full reset).
func clear_all() -> void:
	_listeners.clear()

## Debug: list all registered events and subscriber counts.
func debug_print() -> void:
	print("=== EventBus Listeners ===")
	for event_name in _listeners:
		print("  %s → %d subscriber(s)" % [event_name, _listeners[event_name].size()])
	print("==========================")
