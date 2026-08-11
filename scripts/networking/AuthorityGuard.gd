# AuthorityGuard.gd — Client-side enforcement of the authority model
# (Prompt 17, item 5).
#
# The Nakama server (online) or elected host (offline) is the single source
# of truth. This guard is the client's FIRST line of defence: every action a
# system wants to send over the network is checked against the local role
# BEFORE it is queued, so out-of-role actions never leave the device.
# The server/host re-validates everything on receipt — the guard is
# defense-in-depth, never a substitute for authoritative validation.
#
# Roles (mirrors NetworkManager.Authority):
#   SERVER  — authoritative game logic (Nakama match handler / sim server)
#   HOST    — elected authority in offline (WiFi Direct) mode
#   CLIENT  — regular player (online or offline)
#   SPECTATOR — observer (no gameplay actions)

class_name AuthorityGuard
extends RefCounted

enum Role {
	NONE = 0,
	SERVER = 1,
	HOST = 2,
	CLIENT = 3,
	SPECTATOR = 4,
}

## action name → roles allowed to perform it.
const ACTION_ROLES := {
	"line.draw": [Role.CLIENT, Role.HOST, Role.SERVER],
	"ghost.place": [Role.HOST, Role.SERVER],          # only the authority places ghost lines
	"ghost.discover": [Role.CLIENT, Role.HOST, Role.SERVER],
	"accusation.start": [Role.CLIENT, Role.HOST, Role.SERVER],
	"accusation.resolve": [Role.HOST, Role.SERVER],   # resolution is authority-only
	"score.commit": [Role.HOST, Role.SERVER],
	"state.change": [Role.HOST, Role.SERVER],
	"lobby.close": [Role.HOST],
	"match.start": [Role.HOST],
	"ready.toggle": [Role.CLIENT, Role.HOST, Role.SERVER],
}

## Actions that may only affect THIS device's own player (ownership check).
const SELF_ONLY_ACTIONS := {
	"line.draw": true,
	"ready.toggle": true,
	"accusation.start": true,
}

var role: int = Role.NONE
var session_player_id := -1


func set_role(new_role: int) -> void:
	role = new_role


func set_player_id(player_id: int) -> void:
	session_player_id = player_id


func is_authority() -> bool:
	return role == Role.HOST or role == Role.SERVER


## Check whether `player_id` may perform `action` under the current role.
## When player_id == -1, only the role table is checked.
func can(action: String, player_id := -1) -> bool:
	if not ACTION_ROLES.has(action):
		return false
	var allowed: Array = ACTION_ROLES[action]
	if role not in allowed:
		return false
	if SELF_ONLY_ACTIONS.has(action) and player_id >= 0:
		if player_id != session_player_id:
			return false
	return true


## Guard entry point for systems: emits EV_NET_ACTION_REJECTED on refusal
## (local rejection BEFORE the action reaches the network) and returns false.
func assert_action(action: String, player_id := -1) -> bool:
	if can(action, player_id):
		return true
	var reason := "role"
	if SELF_ONLY_ACTIONS.has(action) and player_id >= 0 and player_id != session_player_id:
		reason = "ownership"
	EventBus.emit(EventBus.EV_NET_ACTION_REJECTED, {
		"action": action,
		"player_id": player_id,
		"reason": reason,
		"role": role,
	})
	push_warning("AuthorityGuard: rejected '%s' (player %d, role %d, reason %s)" % [action, player_id, role, reason])
	return false
