# Cluster.gd — Lightweight data class for a chalk-line cluster
#
# A cluster is a group of ≥5 chalk lines that are within PROXIMITY_THRESHOLD (50px)
# of each other, forming a connected component in the proximity graph.
# Clusters are HIDDEN from the player — they only learn about them when scoring reveals the bonus.
#
# Properties:
#   - cluster_id: unique int per match
#   - line_ids: which chalk lines belong to this cluster
#   - is_surviving: false if any line was broken/expired before scoring
#   - multiplier: always 1.5
#   - formed_at: Time.get_ticks_msec() timestamp
#   - bounds: cached Rect2 union of all line bounding boxes (expanded by threshold margin)
#
# This is a pure RefCounted data class — no lifecycle logic lives here.
# All mutation is done by ClusterSystem.

class_name Cluster
extends RefCounted

## Unique cluster ID within a match. Assigned by ClusterSystem.
var cluster_id: int = -1

## IDs of all ChalkLine resources in this cluster.
var line_ids: Array[int] = []

## Whether the cluster is still intact. Set false when any member line expires or is removed.
var is_surviving: bool = true

## Score multiplier applied to ghosts banished within this cluster's bounds.
var multiplier: float = 1.5

## Timestamp (Time.get_ticks_msec()) when this cluster was first formed.
var formed_at: float = 0.0

## Cached bounding rectangle (union of all line bounds, expanded by threshold).
## Computed by ClusterSystem when the cluster is formed or mutated.
var bounds: Rect2 = Rect2()


## Check whether a given line ID is a member of this cluster.
func contains_line(id: int) -> bool:
	return id in line_ids


## Number of lines in this cluster.
func size() -> int:
	return line_ids.size()


## Return the cached bounding box for ghost-overlap checks.
## This is the union of all member line bounding boxes, expanded by PROXIMITY_THRESHOLD.
func get_bounds() -> Rect2:
	return bounds
