@tool
extends EditorPlugin

## Fault-injection dock to test PLC fault handling.
## Workflow:
##   1. pick a device that can have a fault (any part with a motor / friction / lines / fault tag)
##   2. the catalog below lists every fault that exists; the ones valid for the picked device
##      are enabled, the rest are dimmed
##   3. select a fault and press "Inject" -- the fault is held every frame (re-asserted so it
##      stays down even if the PLC keeps commanding the device). "Clear" restores saved values.
## Plus an Advanced section to force any comms tag directly.
## Isolated: sets exported properties / writes tags externally; no part script is modified.

## Fault catalog -- every fault that exists "in general". `id` drives apply/restore in code.
const FAULTS: Array[Dictionary] = [
	{"id": "drive_trip", "label": "Drive trip — motor stop",
		"desc": "Force the drive off (running=off, speed=0), like a VFD trip. Held down vs PLC run."},
	{"id": "overspeed", "label": "Overspeed",
		"desc": "Force the belt/roller speed to 2.5× the setpoint."},
	{"id": "underspeed", "label": "Underspeed / drag",
		"desc": "Force the speed down to 0.25× the setpoint (worn drive)."},
	{"id": "belt_slip", "label": "Belt slip — low friction",
		"desc": "Drop the transport friction to ~0 so parcels slip and stall."},
	{"id": "roller_line", "label": "Roller line fault (per line)",
		"desc": "Flag one diverter line as faulted — drives the PLC roller-fault byte. Pick the line below."},
	{"id": "comms_drive_fault", "label": "Drive fault signal → PLC",
		"desc": "Force the device's fault tag TRUE so the PLC sees a drive fault."},
	{"id": "comms_photo_eye", "label": "Photo-eye blocked",
		"desc": "Force the light-barrier tag TRUE (stuck / blocked photo-eye)."},
]

## Faults that all write the speed property -- mutually exclusive on one device.
const SPEED_FAULTS: Array[String] = ["drive_trip", "overspeed", "underspeed"]

var _dock: Control
var _part_picker: OptionButton
var _fault_list: ItemList
var _line_row: HBoxContainer
var _line_spin: SpinBox
var _active_list: ItemList
var _info: Label

# advanced tag force
var _grp_edit: LineEdit
var _name_edit: LineEdit
var _val_check: CheckBox
var _tag_list: ItemList

var _active_faults: Array[Dictionary] = []   # [{node,dev,fault_id,label,line,was_present,saved,target,grp,tag}]
var _tag_forces: Array[Dictionary] = []      # [{group,name,value}]


func _enter_tree() -> void:
	_build_ui()
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_BL, _dock)
	set_process(true)
	_refresh_parts()


func _exit_tree() -> void:
	_clear_all_faults()
	if _dock:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null


func _has_sim() -> bool:
	return typeof(Simulation) != TYPE_NIL


#region UI
func _build_ui() -> void:
	var v := VBoxContainer.new()
	v.name = "Faults"
	v.custom_minimum_size = Vector2(300, 0)
	var title := Label.new()
	title.text = "Fault Injection"
	title.add_theme_font_size_override("font_size", 16)
	v.add_child(title)

	# 1. device
	v.add_child(_section("1.  Device"))
	var h := HBoxContainer.new()
	_part_picker = OptionButton.new()
	_part_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_part_picker.item_selected.connect(_on_device_changed)
	h.add_child(_part_picker)
	var refresh := Button.new()
	refresh.text = "⟳"
	refresh.tooltip_text = "Refresh device list"
	refresh.pressed.connect(_refresh_parts)
	h.add_child(refresh)
	v.add_child(h)

	# 2. fault catalog
	v.add_child(_section("2.  Fault type"))
	_fault_list = ItemList.new()
	_fault_list.custom_minimum_size = Vector2(0, 140)
	_fault_list.item_selected.connect(_on_fault_selected)
	v.add_child(_fault_list)

	# per-line picker (only for the roller-line fault)
	_line_row = HBoxContainer.new()
	var ll := Label.new()
	ll.text = "Roller line"
	ll.custom_minimum_size = Vector2(70, 0)
	_line_row.add_child(ll)
	_line_spin = SpinBox.new()
	_line_spin.min_value = 0
	_line_spin.max_value = 23
	_line_spin.step = 1
	_line_spin.value = 0
	_line_spin.tooltip_text = "0-based diverter line index to fault"
	_line_row.add_child(_line_spin)
	_line_row.visible = false
	v.add_child(_line_row)

	_info = Label.new()
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info.add_theme_color_override("font_color", Color(0.75, 0.75, 0.78))
	_info.custom_minimum_size = Vector2(0, 34)
	v.add_child(_info)

	var hb := HBoxContainer.new()
	var inject := Button.new()
	inject.text = "Inject fault"
	inject.pressed.connect(_on_inject)
	hb.add_child(inject)
	var clr := Button.new()
	clr.text = "Clear selected"
	clr.pressed.connect(_on_clear_selected)
	hb.add_child(clr)
	var clra := Button.new()
	clra.text = "Clear all"
	clra.pressed.connect(_clear_all_faults_and_refresh)
	hb.add_child(clra)
	v.add_child(hb)

	# active faults
	v.add_child(_section("Active faults"))
	_active_list = ItemList.new()
	_active_list.custom_minimum_size = Vector2(0, 90)
	v.add_child(_active_list)

	v.add_child(HSeparator.new())

	# advanced: force any tag
	v.add_child(_section("Advanced — force any comms tag"))
	var g := HBoxContainer.new()
	var gl := Label.new()
	gl.text = "Group"
	gl.custom_minimum_size = Vector2(48, 0)
	g.add_child(gl)
	_grp_edit = LineEdit.new()
	_grp_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.add_child(_grp_edit)
	v.add_child(g)
	var nn := HBoxContainer.new()
	var nl := Label.new()
	nl.text = "Tag"
	nl.custom_minimum_size = Vector2(48, 0)
	nn.add_child(nl)
	_name_edit = LineEdit.new()
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.placeholder_text = "e.g. VR_Inputs[1].1"
	nn.add_child(_name_edit)
	v.add_child(nn)
	var tb := HBoxContainer.new()
	_val_check = CheckBox.new()
	_val_check.text = "value = TRUE"
	tb.add_child(_val_check)
	var force := Button.new()
	force.text = "Force"
	force.pressed.connect(_on_force_tag)
	tb.add_child(force)
	var rel := Button.new()
	rel.text = "Release"
	rel.pressed.connect(_on_release_tag)
	tb.add_child(rel)
	v.add_child(tb)
	_tag_list = ItemList.new()
	_tag_list.custom_minimum_size = Vector2(0, 70)
	v.add_child(_tag_list)

	_dock = v
	_rebuild_fault_catalog()


func _section(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.7, 0.8, 1.0))
	return l
#endregion


#region device + catalog
func _refresh_parts() -> void:
	_part_picker.clear()
	for n: Node in _faultable_parts():
		_part_picker.add_item(String(n.name))
	_rebuild_fault_catalog()


func _on_device_changed(_idx: int) -> void:
	_rebuild_fault_catalog()


## Show every fault; enable the ones valid for the picked device, dim the rest.
func _rebuild_fault_catalog() -> void:
	if _fault_list == null:
		return
	var dev: Node = _current_device()
	_fault_list.clear()
	for i: int in FAULTS.size():
		var f: Dictionary = FAULTS[i]
		var fid: String = String(f["id"])
		var ok: bool = dev != null and _fault_applies(dev, fid)
		_fault_list.add_item(String(f["label"]))
		_fault_list.set_item_tooltip(i, String(f["desc"]))
		_fault_list.set_item_disabled(i, not ok)
		if not ok:
			_fault_list.set_item_custom_fg_color(i, Color(0.5, 0.5, 0.5))
	_line_row.visible = false
	_info.text = ""


func _on_fault_selected(idx: int) -> void:
	if idx < 0 or idx >= FAULTS.size():
		return
	var f: Dictionary = FAULTS[idx]
	_info.text = String(f["desc"])
	var dev: Node = _current_device()
	var is_line: bool = String(f["id"]) == "roller_line"
	_line_row.visible = is_line and dev != null and _fault_applies(dev, "roller_line")


func _selected_fault_id() -> String:
	var sel: PackedInt32Array = _fault_list.get_selected_items()
	if sel.is_empty():
		return ""
	var i: int = sel[0]
	if _fault_list.is_item_disabled(i):
		return ""
	return String(FAULTS[i]["id"])


func _current_device() -> Node:
	var idx: int = _part_picker.selected
	if idx < 0:
		return null
	return _find_by_name(_part_picker.get_item_text(idx))
#endregion


#region inject / clear
func _on_inject() -> void:
	var n: Node = _current_device()
	if n == null:
		_info.text = "Pick a device first."
		return
	var fid: String = _selected_fault_id()
	if fid.is_empty():
		_info.text = "Pick a fault that applies to this device."
		return
	var dev: String = String(n.name)
	var line: int = int(_line_spin.value)
	# speed faults are mutually exclusive on one device
	if fid in SPEED_FAULTS:
		_clear_conflicting(dev)
	var key: String = _rec_key(dev, fid, line)
	if _has_active(key):
		_info.text = "That fault is already active on this device."
		return

	var rec: Dictionary = {
		"node": n, "dev": dev, "fault_id": fid, "line": line,
		"was_present": false, "saved": {}, "target": 0.0, "grp": "", "tag": "",
		"label": _rec_label(fid, line),
	}
	var saved: Dictionary = {}
	match fid:
		"drive_trip":
			if "running" in n:
				saved["running"] = n.get("running")
			if "speed" in n:
				saved["speed"] = n.get("speed")
		"overspeed":
			saved["speed"] = n.get("speed")
			var base_up: float = maxf(absf(float(n.get("speed"))), 0.5)
			rec["target"] = base_up * 2.5
		"underspeed":
			saved["speed"] = n.get("speed")
			rec["target"] = absf(float(n.get("speed"))) * 0.25
		"belt_slip":
			saved["surface_friction"] = n.get("surface_friction")
		"roller_line":
			var arr: PackedInt32Array = n.get("faulted_lines")
			rec["was_present"] = arr.find(line) != -1
		"comms_drive_fault":
			rec["grp"] = String(n.get("fault_tag_group_name"))
			rec["tag"] = String(n.get("fault_tag_name"))
		"comms_photo_eye":
			rec["grp"] = String(n.get("lb_tag_group_name"))
			rec["tag"] = String(n.get("lb_tag_name"))
	rec["saved"] = saved
	_active_faults.append(rec)
	_apply_fault(rec)
	_refresh_active_list()
	_info.text = "Injected: %s on %s." % [rec["label"], dev]


func _on_clear_selected() -> void:
	var sel: PackedInt32Array = _active_list.get_selected_items()
	if sel.is_empty():
		return
	var i: int = sel[0]
	if i < 0 or i >= _active_faults.size():
		return
	_restore_fault(_active_faults[i])
	_active_faults.remove_at(i)
	_refresh_active_list()


func _clear_conflicting(dev: String) -> void:
	var i: int = _active_faults.size() - 1
	while i >= 0:
		var rec: Dictionary = _active_faults[i]
		if String(rec["dev"]) == dev and String(rec["fault_id"]) in SPEED_FAULTS:
			_restore_fault(rec)
			_active_faults.remove_at(i)
		i -= 1


func _clear_all_faults() -> void:
	for rec: Dictionary in _active_faults:
		_restore_fault(rec)
	_active_faults.clear()


func _clear_all_faults_and_refresh() -> void:
	_clear_all_faults()
	_refresh_active_list()


func _has_active(key: String) -> bool:
	for rec: Dictionary in _active_faults:
		if _rec_key(String(rec["dev"]), String(rec["fault_id"]), int(rec["line"])) == key:
			return true
	return false


func _rec_key(dev: String, fid: String, line: int) -> String:
	if fid == "roller_line":
		return "%s|%s|%d" % [dev, fid, line]
	return "%s|%s" % [dev, fid]


func _rec_label(fid: String, line: int) -> String:
	for f: Dictionary in FAULTS:
		if String(f["id"]) == fid:
			if fid == "roller_line":
				return "Roller line %d fault" % line
			return String(f["label"])
	return fid


func _refresh_active_list() -> void:
	_active_list.clear()
	for rec: Dictionary in _active_faults:
		_active_list.add_item("⛔ %s — %s" % [String(rec["dev"]), String(rec["label"])])
#endregion


#region apply / restore (held every frame)
func _apply_fault(rec: Dictionary) -> void:
	var n: Node = rec["node"]
	if not is_instance_valid(n):
		return
	match String(rec["fault_id"]):
		"drive_trip":
			if "running" in n and bool(n.get("running")):
				n.set("running", false)
			if "speed" in n and absf(float(n.get("speed"))) > 0.0001:
				n.set("speed", 0.0)
		"overspeed", "underspeed":
			var tgt: float = float(rec["target"])
			if "speed" in n and absf(float(n.get("speed")) - tgt) > 0.001:
				n.set("speed", tgt)
		"belt_slip":
			if "surface_friction" in n and float(n.get("surface_friction")) > 0.025:
				n.set("surface_friction", 0.02)
		"roller_line":
			if "faulted_lines" in n:
				var arr: PackedInt32Array = n.get("faulted_lines")
				var ln: int = int(rec["line"])
				if arr.find(ln) == -1:
					arr = arr.duplicate()
					arr.append(ln)
					n.set("faulted_lines", arr)
		"comms_drive_fault", "comms_photo_eye":
			if _has_sim() and Simulation.is_running():
				var grp: String = String(rec["grp"])
				var tag: String = String(rec["tag"])
				if not tag.is_empty():
					OIPComms.write_bit(grp, tag, true)


func _restore_fault(rec: Dictionary) -> void:
	var n: Node = rec["node"]
	if not is_instance_valid(n):
		return
	var saved: Dictionary = rec["saved"]
	match String(rec["fault_id"]):
		"drive_trip", "overspeed", "underspeed":
			for k: Variant in saved.keys():
				n.set(k, saved[k])
		"belt_slip":
			for k: Variant in saved.keys():
				n.set(k, saved[k])
		"roller_line":
			if "faulted_lines" in n and not bool(rec["was_present"]):
				var arr: PackedInt32Array = n.get("faulted_lines")
				var ix: int = arr.find(int(rec["line"]))
				if ix >= 0:
					arr = arr.duplicate()
					arr.remove_at(ix)
					n.set("faulted_lines", arr)
		"comms_drive_fault", "comms_photo_eye":
			if _has_sim() and Simulation.is_running():
				var tag: String = String(rec["tag"])
				if not tag.is_empty():
					OIPComms.write_bit(String(rec["grp"]), tag, false)
#endregion


#region tag forces (advanced)
func _on_force_tag() -> void:
	var grp: String = _grp_edit.text.strip_edges()
	var nm: String = _name_edit.text.strip_edges()
	if nm.is_empty():
		return
	_tag_forces.append({"group": grp, "name": nm, "value": _val_check.button_pressed})
	_refresh_tag_list()


func _on_release_tag() -> void:
	var sel: PackedInt32Array = _tag_list.get_selected_items()
	if sel.is_empty():
		return
	var i: int = sel[0]
	if i >= 0 and i < _tag_forces.size():
		_tag_forces.remove_at(i)
	_refresh_tag_list()


func _refresh_tag_list() -> void:
	_tag_list.clear()
	for f: Dictionary in _tag_forces:
		_tag_list.add_item("%s / %s = %s" % [String(f["group"]), String(f["name"]), str(bool(f["value"]))])
#endregion


func _process(_delta: float) -> void:
	if _dock == null:
		return
	for rec: Dictionary in _active_faults:
		_apply_fault(rec)
	if _has_sim() and Simulation.is_running():
		for f: Dictionary in _tag_forces:
			OIPComms.write_bit(String(f["group"]), String(f["name"]), bool(f["value"]))


#region applicability
func _fault_applies(n: Node, fid: String) -> bool:
	match fid:
		"drive_trip":
			return ("running" in n) or ("speed" in n)
		"overspeed", "underspeed":
			return "speed" in n
		"belt_slip":
			return "surface_friction" in n
		"roller_line":
			return "faulted_lines" in n
		"comms_drive_fault":
			return _has_tag(n, "fault_tag_name")
		"comms_photo_eye":
			return _has_tag(n, "lb_tag_name")
	return false


func _has_tag(n: Node, prop: String) -> bool:
	if not (prop in n):
		return false
	var v: Variant = n.get(prop)
	return v is String and not (v as String).strip_edges().is_empty()
#endregion


#region scene scan
func _scene_root() -> Node:
	return EditorInterface.get_edited_scene_root()


func _faultable_parts() -> Array:
	var out: Array = []
	var root: Node = _scene_root()
	if root == null:
		return out
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c: Node in n.get_children():
			stack.append(c)
		if n == root or not (n is Node3D):
			continue
		if ("running" in n) or ("speed" in n) or ("faulted_lines" in n) or ("surface_friction" in n):
			out.append(n)
	return out


func _find_by_name(part_name: String) -> Node:
	var root: Node = _scene_root()
	if root == null:
		return null
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c: Node in n.get_children():
			stack.append(c)
		if n != root and n.name == part_name:
			return n
	return null
#endregion
