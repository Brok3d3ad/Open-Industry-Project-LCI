@tool
class_name _OIPCommsTagGroup
extends Control

signal tag_group_delete(t: _OIPCommsTagGroup)
signal tag_group_save(t: _OIPCommsTagGroup)

var save_data := {}

@onready var _name: LineEdit = $Row1/Name
@onready var polling_rate: SpinBox = $Row1/PollingRate
@onready var protocol: OptionButton = $Row1/Protocol
@onready var connections: SpinBox = $Row1/Connections
@onready var connections_label: Label = $Row1/ConnectionsLabel
@onready var gateway: LineEdit = $Row2/Gateway
@onready var path: LineEdit = $Row2/Path
@onready var cpu: OptionButton = $Row2/CPURow/CPU
@onready var cpu_label: Label = $Row2/CPURow/CPULabel
@onready var cpu_row: HBoxContainer = $Row2/CPURow
@onready var path_label: Label = $Row2/PathLabel
@onready var gateway_label: Label = $Row2/GatewayLabel
@onready var browse_opc_ua: Button = $Row2/BrowseOpcUa
@onready var port: LineEdit = $Row2/PortRow/Port
@onready var port_label: Label = $Row2/PortRow/PortLabel
@onready var port_row: HBoxContainer = $Row2/PortRow

var loading_complete := false

func _ready() -> void:
	_load()
	update_protocol(protocol.selected, true)

func save() -> void:
	save_data["name"] = _name.text
	save_data["polling_rate"] = str(int(polling_rate.value))
	save_data["protocol"] = str(protocol.selected)
	save_data["gateway"] = gateway.text
	save_data["path"] = path.text
	save_data["connections"] = str(int(connections.value))
	# For ADS, the cpu slot carries the AMS port (a free-form number).
	if protocol.selected == 4:
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
		connections.value = int(save_data.get("connections", "1"))
		if int(save_data["protocol"]) == 4:
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
	var libplctag_proto := _index == 0 or _index == 1
	connections.visible = libplctag_proto
	connections_label.visible = libplctag_proto
	if not libplctag_proto:
		connections.value = 1

	var gateway_tip := ""
	var path_tip := ""
	var cpu_tip := ""
	var port_tip := ""

	if _index == 2:  # opc_ua
		cpu_row.hide()
		port_row.hide()
		path_label.hide()
		path.hide()
		browse_opc_ua.show()
		gateway_label.text = "Endpoint"
		gateway_tip = "OPC UA server endpoint URL (e.g. opc.tcp://192.168.1.100:4840).\n\nTag node IDs include the namespace, so this is the only address you need."

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
		gateway_tip = "IP address of the Modbus TCP server (e.g. 192.168.1.50)."
		path_tip = "Modbus unit ID (slave address).\n\nUsually 1 for a direct device, or the gateway-assigned ID when bridging serial Modbus."

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
		gateway_tip = "IPv4 address of the Siemens S7 PLC (e.g. 192.168.1.10).\n\nPUT/GET must be enabled on the PLC and DBs must be marked non-optimized."

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
		gateway_tip = "IPv4 address of the remote Beckhoff PLC (e.g. 192.168.1.10).\n\nA route from this machine to the PLC must already be configured on the PLC side."
		path_tip = "Remote AmsNetId of the TwinCAT runtime (e.g. 5.34.142.165.1.1).\n\nVisible in TwinCAT under System > Routes."
		port_tip = "AMS port for the target runtime.\n\n851 = TwinCAT 3 PLC runtime\n801 = TwinCAT 2 PLC runtime"

		if not from_ready:
			gateway.text = ""
			path.text = ""
			port.text = "851"
	else:  # ab_eip
		cpu_row.show()
		port_row.hide()
		browse_opc_ua.hide()
		path_label.show()
		path.show()
		path_label.text = "Path"
		gateway_label.text = "Gateway"
		cpu.select(max(cpu.selected, 0))
		gateway_tip = "IP address of the Allen-Bradley device (e.g. 192.168.1.200).\n\nUse 'localhost' or '127.0.0.1' for emulators on this machine."
		path_tip = "CIP routing path to the processor.\n\nControlLogix in slot 0 of a 1756-EN2T at slot 1: '1,0'\nEmbedded-Ethernet processors: typically empty or '0'"
		cpu_tip = "Processor family. Picks the right CIP message format.\n\nControlLogix / CompactLogix: ControlLogix\nPLC-5 / SLC-500: dedicated entries\nMicro800 / MicroLogix: dedicated entries"

		if not from_ready:
			gateway.text = "localhost"
			path.text = "1,0"

	gateway_label.tooltip_text = gateway_tip
	path_label.tooltip_text = path_tip
	cpu_label.tooltip_text = cpu_tip
	port_label.tooltip_text = port_tip

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
