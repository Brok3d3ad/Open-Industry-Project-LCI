@tool
class_name _OIPCommsTagGroup
extends Control

signal tag_group_delete(t: _OIPCommsTagGroup)
signal tag_group_save(t: _OIPCommsTagGroup)

var save_data := {}

@onready var _name: LineEdit = $Row1/Name
@onready var polling_rate: SpinBox = $Row1/PollingRate
@onready var protocol: OptionButton = $Row1/Protocol
@onready var gateway: LineEdit = $Row2/Gateway
@onready var path: LineEdit = $Row2/Path
@onready var cpu: OptionButton = $Row2/CPURow/CPU
@onready var cpu_row: HBoxContainer = $Row2/CPURow
@onready var path_label: Label = $Row2/PathLabel
@onready var gateway_label: Label = $Row2/GatewayLabel
@onready var browse_opc_ua: Button = $Row2/BrowseOpcUa
@onready var port: LineEdit = $Row2/PortRow/Port
@onready var port_row: HBoxContainer = $Row2/PortRow
@onready var port_label: Label = $Row2/PortRow/PortLabel
@onready var read_stats: Label = $Row3/ReadStats
@onready var write_stats: Label = $Row3/WriteStats
@onready var write_queue_stats: Label = $Row3/WriteQueueStats
@onready var poll_cycle_stats: Label = $Row3/PollCycleStats

var loading_complete := false

# Throttle native getter calls to ~5 Hz; cheaper than every-frame and avoids
# spamming the singleton across all tag-group rows.
const _STATS_REFRESH_INTERVAL: float = 0.2
var _stats_refresh_accum: float = 0.0

func _ready() -> void:
	_load()
	update_protocol(protocol.selected, true)
	set_process(true)


func _process(delta: float) -> void:
	_stats_refresh_accum += delta
	if _stats_refresh_accum < _STATS_REFRESH_INTERVAL:
		return
	_stats_refresh_accum = 0.0

	if not is_instance_valid(read_stats) or not is_instance_valid(write_stats) \
			or not is_instance_valid(write_queue_stats) or not is_instance_valid(poll_cycle_stats):
		return
	var group_name: String = _name.text if is_instance_valid(_name) else ""
	if group_name.is_empty() or not OIPComms.get_sim_running():
		read_stats.text = "-/-"
		write_stats.text = "-/-"
		write_queue_stats.text = "-/-"
		poll_cycle_stats.text = "-/-"
		return

	# Each stat shows min / avg / max (ms). avg is the arithmetic mean -- the
	# "typical" latency, far less skewed by a lone spike than max.
	var r_count: int = OIPComms.get_read_latency_count(group_name)
	if r_count == 0:
		read_stats.text = "-/-"
	else:
		read_stats.text = "%.1f / %.1f / %.1f" % [
			OIPComms.get_read_latency_min_us(group_name) / 1000.0,
			OIPComms.get_read_latency_avg_us(group_name) / 1000.0,
			OIPComms.get_read_latency_max_us(group_name) / 1000.0,
		]

	var w_count: int = OIPComms.get_write_latency_count(group_name)
	if w_count == 0:
		write_stats.text = "-/-"
	else:
		write_stats.text = "%.1f / %.1f / %.1f" % [
			OIPComms.get_write_latency_min_us(group_name) / 1000.0,
			OIPComms.get_write_latency_avg_us(group_name) / 1000.0,
			OIPComms.get_write_latency_max_us(group_name) / 1000.0,
		]

	var wq_count: int = OIPComms.get_write_queue_count(group_name)
	if wq_count == 0:
		write_queue_stats.text = "-/-"
	else:
		write_queue_stats.text = "%.1f / %.1f / %.1f" % [
			OIPComms.get_write_queue_min_us(group_name) / 1000.0,
			OIPComms.get_write_queue_avg_us(group_name) / 1000.0,
			OIPComms.get_write_queue_max_us(group_name) / 1000.0,
		]

	var pc_count: int = OIPComms.get_poll_cycle_count(group_name)
	if pc_count == 0:
		poll_cycle_stats.text = "-/-"
	else:
		poll_cycle_stats.text = "%.1f / %.1f / %.1f" % [
			OIPComms.get_poll_cycle_min_us(group_name) / 1000.0,
			OIPComms.get_poll_cycle_avg_us(group_name) / 1000.0,
			OIPComms.get_poll_cycle_max_us(group_name) / 1000.0,
		]

func save() -> void:
	save_data["name"] = _name.text
	save_data["polling_rate"] = str(int(polling_rate.value))
	save_data["protocol"] = str(protocol.selected)
	save_data["gateway"] = gateway.text
	save_data["path"] = path.text
	# ADS and MQTT both keep their cpu-slot value in the free-form Port LineEdit
	# (ADS: AMS port; MQTT: user:password). Other protocols use the CPU enum.
	if protocol.selected == 4 or protocol.selected == 6:
		save_data["cpu"] = port.text
	else:
		save_data["cpu"] = cpu.text

func lock_name() -> void:
	if _name:
		_name.editable = false

func _load() -> void:
	if "name" in save_data:
		_name.text = save_data["name"]
		if save_data.get("saved", false):
			_name.editable = false
		polling_rate.value = int(save_data["polling_rate"])
		protocol.select(int(save_data["protocol"]))
		gateway.text = save_data["gateway"]
		path.text = save_data["path"]
		if int(save_data["protocol"]) == 4 or int(save_data["protocol"]) == 6:
			port.text = save_data["cpu"]
		else:
			cpu.text = save_data["cpu"]
		loading_complete = true

func _on_Delete_pressed() -> void:
	tag_group_delete.emit(self)

func _on_text_changed(_new_text: String) -> void:
	if loading_complete:
		save()
		tag_group_save.emit(self)

func _on_Gateway_text_changed(_new_text: String) -> void:
	_on_text_changed(_new_text)

func _on_Path_text_changed(_new_text: String) -> void:
	_on_text_changed(_new_text)

func update_protocol(_index: int, from_ready := false) -> void:
	if _index == 2:  # opc_ua
		cpu_row.hide()
		port_row.hide()
		path_label.hide()
		path.hide()
		browse_opc_ua.show()
		gateway_label.text = "Endpoint"

		if not from_ready:
			gateway.text = "opc.tcp://localhost:4840"
	elif _index == 1:  # modbus_tcp
		cpu_row.hide()
		port_row.hide()
		browse_opc_ua.hide()
		path_label.show()
		path.show()
		path_label.text = "Unit ID"
		gateway_label.text = "Gateway"

		if not from_ready:
			gateway.text = "localhost"
			path.text = "1"
	elif _index == 3:  # siemens s7 put/get
		cpu_row.hide()
		port_row.hide()
		browse_opc_ua.hide()
		path_label.hide()
		path.hide()
		gateway_label.text = "PLC IP address"

		if not from_ready:
			gateway.text = ""
	elif _index == 4:  # ads
		cpu_row.hide()
		port_row.show()
		browse_opc_ua.hide()
		path_label.show()
		path.show()
		path_label.text = "AmsNetId"
		gateway_label.text = "PLC IP address"
		port_label.text = "Port"

		if not from_ready:
			gateway.text = ""
			path.text = ""
			port.text = "851"
	elif _index == 5:  # rtde (Universal Robots)
		cpu_row.hide()
		port_row.hide()
		browse_opc_ua.hide()
		path_label.hide()
		path.hide()
		gateway_label.text = "Robot IP"

		if not from_ready:
			gateway.text = ""
	elif _index == 6:  # mqtt
		# Port LineEdit is reused for "user:password" credentials; the existing
		# CPU OptionButton is for ab_eip processor types and doesn't apply.
		cpu_row.hide()
		port_row.show()
		browse_opc_ua.hide()
		path_label.show()
		path.show()
		path_label.text = "Client ID"
		gateway_label.text = "Broker"
		port_label.text = "Auth"

		if not from_ready:
			gateway.text = "localhost:1883"
			path.text = ""
			port.text = ""
	elif _index == 7:
		cpu_row.hide()
		port_row.hide()
		browse_opc_ua.hide()
		path_label.hide()
		path.hide()
		gateway_label.text = "Bundle (oip-plc.js)"

		if not from_ready:
			gateway.text = "res://oip-plc.js"
			path.text = ""
	else:  # ab_eip
		cpu_row.show()
		port_row.hide()
		browse_opc_ua.hide()
		path_label.show()
		path.show()
		path_label.text = "Path"
		gateway_label.text = "Gateway"
		cpu.select(max(cpu.selected, 0))

		if not from_ready:
			gateway.text = "localhost"
			path.text = "1,0"

func _on_item_selected(_index: int) -> void:
	update_protocol(protocol.selected)
	if loading_complete:
		save()
		tag_group_save.emit(self)

func _on_value_changed(_value: float) -> void:
	if loading_complete:
		save()
		tag_group_save.emit(self)

func _on_browse_opc_ua_pressed() -> void:
	if not Engine.has_meta("opc_ua_browser_dock"):
		push_warning("OPC UA Browser dock not found. Enable the OPC UA Browser plugin.")
		return
	var dock: EditorDock = Engine.get_meta("opc_ua_browser_dock")
	dock.make_visible()
	if Engine.has_meta("opc_ua_browser_content"):
		var browser = Engine.get_meta("opc_ua_browser_content")
		browser.connect_to_endpoint(gateway.text.strip_edges())
