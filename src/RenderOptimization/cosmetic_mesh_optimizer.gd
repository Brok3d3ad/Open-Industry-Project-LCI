@tool
class_name CosmeticMeshOptimizer
extends Node

## Walks the parent node's subtree on `_ready` and applies render
## optimisations to small "cosmetic" `MeshInstance3D` nodes — buttons,
## bezels, lenses, labels, nuts, etc. Targets the dominant cost in
## crowded scenes (5000+ small meshes): shadow-caster list build and
## per-instance frustum culling. Runs in the editor (`@tool`) so the
## editor FPS benefits, and at runtime so playback does too.
##
## Usage: add a `Node` child to your scene root, attach this script.
## Tweak the export properties in the inspector if defaults don't match
## the names in your parts. Re-saving the scene preserves the helper —
## no asset edits.
##
## Reversible: detach / delete the helper node and reload the scene.

## Substrings checked against each candidate mesh's `name` AND its
## parent's `name`. A match flags the mesh as cosmetic. Defaults cover
## the conventions used by APF / MCM / AuxDisconnect / EPC / PushButton /
## StackLight GLBs in this project.
@export var cosmetic_name_substrings: PackedStringArray = [
	"_Btn", "_Bezel", "_Desc", "_Tag", "_Nut", "_Lens", "_Cap", "_Ring",
	"_Body", "_Guard", "_Backplate", "_Backplate_", "Lbl_", "Label",
	"PilotLens", "PilotBezel", "PilotCollar",
]

## Hide cosmetic meshes past this distance (metres). 0 disables HLOD
## (still applies shadow disable). 8 m is invisible-at-distance for
## typical button/label sizes; raise if you stand far back during
## normal use.
@export_range(0.0, 100.0, 0.5, "suffix:m") var hide_distance: float = 8.0

## Disable shadow casting on cosmetic meshes. This is the bigger of the
## two wins — shadow rendering touches every caster every frame for
## every directional/positional shadow-casting light.
@export var disable_shadows: bool = true

## Nuclear option: disable shadow casting on EVERY `MeshInstance3D` in
## the subtree, regardless of name. Maximum FPS at the cost of all
## shadows in the scene. Overrides `cosmetic_name_substrings` and
## `disable_shadows` for the shadow setting.
@export var disable_all_shadows: bool = false

## Print how many meshes were optimised. Useful when tuning the patterns.
@export var log_summary: bool = true

func _ready() -> void:
	var root: Node = get_parent()
	if root == null:
		return
	var stats: Dictionary = {"shadow_off": 0, "hlod": 0, "scanned": 0}
	_walk(root, stats)
	if log_summary:
		print("[CosmeticMeshOptimizer] scanned=%d shadow_off=%d hlod=%d" % [
			int(stats["scanned"]),
			int(stats["shadow_off"]),
			int(stats["hlod"]),
		])

func _walk(node: Node, stats: Dictionary) -> void:
	if node is MeshInstance3D:
		stats["scanned"] = int(stats["scanned"]) + 1
		var mi: MeshInstance3D = node as MeshInstance3D
		if disable_all_shadows:
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			stats["shadow_off"] = int(stats["shadow_off"]) + 1
		else:
			var parent: Node = mi.get_parent()
			var parent_name: String = String(parent.name) if parent else ""
			if _is_cosmetic(String(mi.name)) or _is_cosmetic(parent_name):
				if disable_shadows:
					mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
					stats["shadow_off"] = int(stats["shadow_off"]) + 1
				if hide_distance > 0.0:
					mi.visibility_range_end = hide_distance
					stats["hlod"] = int(stats["hlod"]) + 1
	for child in node.get_children():
		_walk(child, stats)

func _is_cosmetic(node_name: String) -> bool:
	for sub: String in cosmetic_name_substrings:
		if sub in node_name:
			return true
	return false
