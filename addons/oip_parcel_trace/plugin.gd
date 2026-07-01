@tool
extends EditorPlugin

## Parcel trace dock. While the simulation runs, every parcel (RigidBody3D) is tracked:
##   - a trace id (reset to #1 each run) and barcode
##   - the ordered PATH of parts it travels through (DEVICE NAME from the part's comms tag,
##     e.g. NCS2_1; node name only if the part has no tag) -- shown in the detail box
##   - live age and speed
## Select a parcel -> selected in the editor (orange box) + a ▼ marker follows it (no resizing).
## Double-click -> the 3D camera jumps to it. "Lock camera" follows it. "Pop out" floats the panel.

const PREFIXES: Array = ["OIP_", "OIP-", "PLC_"]
const SUFFIXES: Array = ["_VFD", "_RUNNING", "_RUN", "_SPEED", "_SPD", "_MOTOR", "_DRIVE",
	"_CMD", "_STS", "_FB", "_CONV", "_CONVEYOR"]
const TAG_PRIORITY: Array = ["vfd_tag_name", "running_tag_name", "run_tag_name",
	"speed_tag_name", "tag_name"]

var _dock: Control
var _list: ItemList
var _detail: RichTextLabel
var _lock_btn: CheckBox
var _popout_btn: Button

var _parcels: Dictionary = {}        # instance_id -> {id, born_ms, barcode, path:Array[String], node}
var _row_ids: Array = []
var _next_id: int = 1
var _selected: int = -1
var _last_count: int = -1
var _parts_cache: Array = []
var _parts_refresh_ms: int = 0
var _foot_cache: Dictionary = {}     # part id -> footprint AABB (refreshed with _parts_cache)
var _scan_accum: float = 0.0
var _marker: Label3D = null
var _window: Window = null
var _popped: bool = false


func _enter_tree() -> void:
	_build_ui()
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_BL, _dock)
	set_process(true)


func _exit_tree() -> void:
	if is_instance_valid(_marker):
		_marker.queue_free()
	_marker = null
	if _popped and is_instance_valid(_window):
		_window.queue_free()          # frees _dock (its child) too
		_window = null
	elif _dock:
		remove_control_from_docks(_dock)
		_dock.queue_free()
	_dock = null


func _build_ui() -> void:
	var v := VBoxContainer.new()
	v.name = "Parcels"
	v.custom_minimum_size = Vector2(300, 0)
	var top := HBoxContainer.new()
	var title := Label.new()
	title.text = "Parcel Trace"
	title.add_theme_font_size_override("font_size", 16)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	_popout_btn = Button.new()
	_popout_btn.text = "Pop out ⧉"
	_popout_btn.pressed.connect(_on_popout)
	top.add_child(_popout_btn)
	v.add_child(top)

	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(0, 220)
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_select)
	_list.item_activated.connect(_on_activate)
	v.add_child(_list)

	_lock_btn = CheckBox.new()
	_lock_btn.text = "Lock camera to selected parcel"
	v.add_child(_lock_btn)

	_detail = RichTextLabel.new()
	_detail.fit_content = true
	_detail.custom_minimum_size = Vector2(0, 120)
	_detail.bbcode_enabled = true
	v.add_child(_detail)
	_dock = v


#region pop-out window
func _on_popout() -> void:
	if _popped:
		_redock()
	else:
		_popout()


func _popout() -> void:
	remove_control_from_docks(_dock)
	_window = Window.new()
	_window.title = "Parcel Trace"
	_window.size = Vector2i(440, 620)
	_window.always_on_top = true
	_window.close_requested.connect(_redock)
	EditorInterface.get_base_control().add_child(_window)
	_window.add_child(_dock)
	(_dock as Control).set_anchors_preset(Control.PRESET_FULL_RECT)
	_window.popup_centered()
	_popped = true
	_popout_btn.text = "Dock ⧉"


func _redock() -> void:
	if is_instance_valid(_window):
		if is_instance_valid(_dock) and _dock.get_parent() == _window:
			_window.remove_child(_dock)
		_window.queue_free()
	_window = null
	_popped = false
	if is_instance_valid(_dock):
		add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_BL, _dock)
		_popout_btn.text = "Pop out ⧉"
#endregion


func _has_sim() -> bool:
	return typeof(Simulation) != TYPE_NIL


func _process(delta: float) -> void:
	if _dock == null:
		return
	if not (_has_sim() and Simulation.is_running()):
		if not _parcels.is_empty():
			_parcels.clear()
			_hide_marker()
			_next_id = 1
			_selected = -1
			_last_count = -1
			_refresh_list()
		return
	# Throttle the full-scene scan to ~7 Hz (cheap on huge scenes); marker/detail stay live.
	_scan_accum += delta
	if _scan_accum >= 0.15:
		_scan_accum = 0.0
		_track()
		if _parcels.size() != _last_count:
			_refresh_list()
			_last_count = _parcels.size()
	_update_detail()
	var box: Node3D = _selected_box()
	if box != null:
		_update_marker(box)
		if _lock_btn.button_pressed:
			_aim_camera_at(box)
	else:
		_hide_marker()


func _track() -> void:
	var boxes: Array = _all_boxes()
	var seen: Dictionary = {}
	for b: Variant in boxes:
		var node: Node3D = b as Node3D
		if node == null:
			continue
		var iid: int = node.get_instance_id()
		seen[iid] = true
		if not _parcels.has(iid):
			_parcels[iid] = {
				"id": _next_id, "born_ms": Time.get_ticks_msec(),
				"barcode": _barcode(node), "path": [], "node": node,
			}
			_next_id += 1
		var cur: String = _current_part(node)
		if cur != "":
			var path: Array = _parcels[iid]["path"]
			if path.is_empty() or String(path[path.size() - 1]) != cur:
				path.append(cur)
	for iid: Variant in _parcels.keys():
		if not seen.has(iid):
			_parcels.erase(iid)


func _refresh_list() -> void:
	_list.clear()
	_row_ids.clear()
	for iid: Variant in _parcels.keys():
		var rec: Dictionary = _parcels[iid]
		_list.add_item("#%d   %s" % [int(rec["id"]), String(rec["barcode"])])   # id + barcode only
		_row_ids.append(iid)
		if int(rec["id"]) == _selected:
			_list.select(_row_ids.size() - 1)


func _on_select(row: int) -> void:
	if row >= 0 and row < _row_ids.size():
		var rec: Dictionary = _parcels.get(_row_ids[row], {})
		_selected = int(rec.get("id", -1))
		_select_in_editor(rec.get("node"))
	_update_detail()


func _on_activate(row: int) -> void:
	_on_select(row)
	var box: Node3D = _selected_box()
	if box != null:
		_aim_camera_at(box)


func _selected_box() -> Node3D:
	for iid: Variant in _parcels.keys():
		if int(_parcels[iid]["id"]) == _selected:
			var n: Node3D = _parcels[iid]["node"]
			if is_instance_valid(n):
				return n
			return null
	return null


func _update_detail() -> void:
	var found: Dictionary = {}
	for iid: Variant in _parcels.keys():
		if int(_parcels[iid]["id"]) == _selected:
			found = _parcels[iid]
			break
	if found.is_empty():
		_detail.text = "[i]Select a parcel above.[/i]"
		return
	var node: Node3D = found["node"]
	var age: float = float(Time.get_ticks_msec() - int(found["born_ms"])) / 1000.0
	var spd: float = 0.0
	if is_instance_valid(node) and node is RigidBody3D:
		spd = (node as RigidBody3D).linear_velocity.length()
	var path: Array = found["path"]
	var route: String = " → ".join(PackedStringArray(path)) if not path.is_empty() else "-"
	_detail.text = "[b]Parcel #%d[/b]\nBarcode: %s\nAge: %.1f s\nSpeed: %.2f m/s\nPath: %s" % [
		int(found["id"]), String(found["barcode"]), age, spd, route]


#region marker
func _update_marker(box: Node3D) -> void:
	if not is_instance_valid(_marker):
		_marker = Label3D.new()
		_marker.name = "_TraceMarker"
		_marker.text = "▼"
		_marker.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_marker.no_depth_test = true
		_marker.font_size = 140
		_marker.outline_size = 34
		_marker.modulate = Color(1, 0.9, 0.1)
		_marker.outline_modulate = Color(0, 0, 0)
		_marker.pixel_size = 0.001
		var root: Node = _scene_root()
		if root != null:
			root.add_child(_marker, false, Node.INTERNAL_MODE_FRONT)
	if is_instance_valid(_marker):
		_marker.visible = true
		_marker.global_position = box.global_position + Vector3(0, 0.6, 0)


func _hide_marker() -> void:
	if is_instance_valid(_marker):
		_marker.visible = false
#endregion


#region editor selection + camera
func _select_in_editor(node: Variant) -> void:
	if not (node is Node) or not is_instance_valid(node):
		return
	var sel: EditorSelection = EditorInterface.get_selection()
	if sel:
		sel.clear()
		sel.add_node(node)


func _editor_camera() -> Camera3D:
	if not EditorInterface.has_method("get_editor_viewport_3d"):
		return null
	var vp: SubViewport = EditorInterface.get_editor_viewport_3d(0)
	if vp == null:
		return null
	return vp.get_camera_3d()


func _aim_camera_at(box: Node3D) -> void:
	if not is_instance_valid(box):
		return
	var cam: Camera3D = _editor_camera()
	if cam == null:
		return
	var tgt: Vector3 = box.global_position
	var eye: Vector3 = tgt + Vector3(0.0, 3.0, 5.0)
	var t := Transform3D(Basis(), eye)
	cam.global_transform = t.looking_at(tgt, Vector3.UP)
#endregion


#region scene scan + names
func _barcode(node: Node3D) -> String:
	if node.has_meta("barcode_string"):
		return String(node.get_meta("barcode_string"))
	if node.has_meta("barcode_value"):
		return str(node.get_meta("barcode_value"))
	return ""


func _scene_root() -> Node:
	return EditorInterface.get_edited_scene_root()


func _all_boxes() -> Array:
	var out: Array = []
	var root: Node = _scene_root()
	if root == null:
		return out
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c: Node in n.get_children():
			stack.append(c)
		if n is RigidBody3D:
			out.append(n)
	return out


func _trackable_parts() -> Array:
	if Time.get_ticks_msec() - _parts_refresh_ms < 1000 and not _parts_cache.is_empty():
		return _parts_cache
	_parts_refresh_ms = Time.get_ticks_msec()
	_parts_cache = []
	_foot_cache.clear()
	var root: Node = _scene_root()
	if root == null:
		return _parts_cache
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c: Node in n.get_children():
			stack.append(c)
		if n == root or not (n is Node3D):
			continue
		var nm: String = String(n.name)
		if n.has_method("get_snap_features") or nm.contains("Conveyor") \
				or nm.contains("VR") or nm.contains("Belt") or nm.contains("Roller") or nm.contains("Diverter"):
			_parts_cache.append(n)
	return _parts_cache


func _current_part(box: Node3D) -> String:
	var p: Vector3 = box.global_position
	for part: Variant in _trackable_parts():
		var pn: Node = part as Node
		if pn == null or not is_instance_valid(pn):
			continue
		var pid: int = pn.get_instance_id()
		var a: AABB
		if _foot_cache.has(pid):
			a = _foot_cache[pid]
		else:
			a = _part_footprint(pn)
			_foot_cache[pid] = a
		var amin: Vector3 = a.position
		var amax: Vector3 = a.position + a.size
		if p.x >= amin.x and p.x <= amax.x and p.z >= amin.z and p.z <= amax.z \
				and p.y >= amin.y - 0.4 and p.y <= amax.y + 1.2:
			return _device_name(pn)
	return ""


func _device_name(part: Node) -> String:
	var tag: String = _part_tag(part)
	if tag.is_empty():
		return String(part.name)
	return _derive(tag)


func _part_tag(part: Node) -> String:
	for pname: String in TAG_PRIORITY:
		if pname in part:
			var v: Variant = part.get(pname)
			if v is String and not (v as String).strip_edges().is_empty():
				return v
	for prop: Dictionary in part.get_property_list():
		var nm: String = String(prop.get("name", ""))
		if nm.ends_with("tag_name"):
			var v: Variant = part.get(nm)
			if v is String and not (v as String).strip_edges().is_empty():
				return v
	return ""


func _derive(tag_name: String) -> String:
	var s: String = tag_name.strip_edges()
	var br: int = s.find("[")
	if br >= 0:
		s = s.substr(0, br)
	if not s.contains("[") and s.count(".") == 1 and s.split(".")[1].is_valid_int():
		s = s.split(".")[0]
	var up: String = s.to_upper()
	for p: String in PREFIXES:
		if up.begins_with(p.to_upper()):
			s = s.substr(p.length())
			break
	up = s.to_upper()
	for suf: String in SUFFIXES:
		if up.ends_with(suf.to_upper()):
			s = s.substr(0, s.length() - suf.length())
			break
	return s.strip_edges()


func _part_footprint(node: Node) -> AABB:
	var has: bool = false
	var mn := Vector3(1e9, 1e9, 1e9)
	var mx := Vector3(-1e9, -1e9, -1e9)
	var stack: Array = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c: Node in n.get_children():
			stack.append(c)
		if n is MeshInstance3D:
			var mi: MeshInstance3D = n
			var box: AABB = mi.get_aabb()
			var xf: Transform3D = mi.global_transform
			for i: int in 8:
				var pt: Vector3 = xf * box.get_endpoint(i)
				mn = mn.min(pt); mx = mx.max(pt); has = true
	if not has:
		var gp: Vector3 = (node as Node3D).global_position if node is Node3D else Vector3.ZERO
		return AABB(gp - Vector3(0.5, 0.5, 0.5), Vector3.ONE)
	return AABB(mn, mx - mn)
#endregion
