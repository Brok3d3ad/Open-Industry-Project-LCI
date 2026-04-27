@tool
extends Node3D

## Forwarder for the OIP "Use" (C) shortcut. Attached to interactive child
## nodes of an `EPC` instance (e.g. the red `ButtonCap`) so that selecting
## the visible mesh in the viewport and pressing C still trips the parent
## EPC, without the user having to navigate up the scene tree first.
func use() -> void:
	var node: Node = get_parent()
	while node != null:
		if node is EPC:
			(node as EPC).use()
			return
		node = node.get_parent()
