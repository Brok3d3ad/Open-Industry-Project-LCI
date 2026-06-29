class_name BarcodeLabel
extends RefCounted

## Random parcel barcode: a human-readable id such as [code]SPx3Dvkhcv_001_v[/code], rendered
## as a 1D (linear) barcode — variable-width vertical bars, NOT a 2D / QR symbol. The id is
## what the [ScanTunnel] reports when a parcel passes its read gate.
##
## Id format: [code]SP<8 random base-62 chars>_<3-digit sequence>_<check char>[/code].
## The bar pattern is a deterministic function of the id (same id -> same bars), with quiet
## zones and start/stop guards so it reads like a real shipping label.

const PREFIX: String = "SP"
const RAND_LEN: int = 8
const _ALNUM62: String = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
const _CHECK_CHARS: String = "abcdefghijklmnopqrstuvwxyz0123456789"
const _MODULE_PX: int = 3        # pixels per narrow bar/space module
const _QUIET_MODULES: int = 10   # quiet-zone width on each side, in modules
const _BAR_H: int = 90           # bar height in pixels


## Returns {string, code, value}: the full id, a copy, and a stable numeric hash for any
## INT32 use downstream. [param sequence] is the per-run parcel counter (wraps 1..999).
static func generate(sequence: int) -> Dictionary:
	var rnd: String = ""
	for i: int in RAND_LEN:
		rnd += _ALNUM62[randi() % _ALNUM62.length()]
	var seq: int = ((sequence - 1) % 999) + 1
	var body: String = "%s%s_%03d" % [PREFIX, rnd, seq]
	var full: String = "%s_%s" % [body, _check_char(body)]
	return {"string": full, "code": full, "value": _hash(full)}


## Number of characters in a well-formed id (e.g. SPx3Dvkhcv_001_v == 16).
static func id_length() -> int:
	return PREFIX.length() + RAND_LEN + 1 + 3 + 1 + 1


## Reported when a parcel passes but no id can be decoded — present-but-unreadable label, or no
## barcode at all: a '?' run the length of a real id (e.g. [code]????????????????[/code]).
static func no_read_code() -> String:
	return "?".repeat(id_length())


## Reported when 2+ barcodes are visible on one parcel (ambiguous multi-read): a '9' run the
## length of a real id (e.g. [code]9999999999999999[/code]).
static func multi_read_code() -> String:
	return "9".repeat(id_length())


## Position-weighted modulo checksum -> one lowercase/digit character.
static func _check_char(s: String) -> String:
	var total: int = 0
	for i: int in s.length():
		total = (total + s.unicode_at(i) * (i + 1)) % _CHECK_CHARS.length()
	return _CHECK_CHARS[total]


## 31-bit FNV-1a hash, for callers that want a numeric handle on the id.
static func _hash(s: String) -> int:
	var h: int = 2166136261
	for i: int in s.length():
		h = (h ^ s.unicode_at(i)) * 16777619
		h = h & 0x7FFFFFFF
	return h


## Alternating bar/space run widths (modules), starting and ending on a bar.
static func _bar_widths(code: String) -> PackedInt32Array:
	var w: PackedInt32Array = PackedInt32Array()
	w.append(2); w.append(1); w.append(2)                 # start guard
	for i: int in code.length():
		var c: int = code.unicode_at(i)
		for k: int in 6:                                   # 6 runs per character, each 1..3
			w.append(1 + (((c >> k) & 1) + ((c >> ((k * 2 + 1) % 8)) & 1)))
	w.append(2); w.append(1); w.append(2)                 # stop guard
	if w.size() % 2 == 0:
		w.append(2)                                        # keep the strip ending on a bar
	return w


## Render [param code] as a 1D barcode: black bars on white (no baked text — the box spawner
## draws the human-readable id with a Label3D beneath the strip).
static func make_barcode_texture(code: String) -> ImageTexture:
	var widths: PackedInt32Array = _bar_widths(code)
	var quiet_px: int = _QUIET_MODULES * _MODULE_PX
	var bars_px: int = 0
	for w: int in widths:
		bars_px += w * _MODULE_PX
	var img_w: int = quiet_px * 2 + bars_px
	var img: Image = Image.create(img_w, _BAR_H, false, Image.FORMAT_RGB8)
	img.fill(Color.WHITE)
	var x: int = quiet_px
	var dark: bool = true
	for w: int in widths:
		var px_w: int = w * _MODULE_PX
		if dark:
			for px: int in px_w:
				for py: int in _BAR_H:
					img.set_pixel(x + px, py, Color.BLACK)
		x += px_w
		dark = not dark
	return ImageTexture.create_from_image(img)


## A smudged / partly torn 1D label with random bars — no valid id, so a parcel wearing it
## NO-READs at the tunnel (models a damaged / unreadable shipping label).
static func make_damaged_barcode_texture() -> ImageTexture:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	var quiet_px: int = _QUIET_MODULES * _MODULE_PX
	var widths: PackedInt32Array = PackedInt32Array()
	var bars_px: int = 0
	for i: int in 60:
		var ww: int = 1 + rng.randi() % 3
		widths.append(ww)
		bars_px += ww * _MODULE_PX
	var img: Image = Image.create(quiet_px * 2 + bars_px, _BAR_H, false, Image.FORMAT_RGB8)
	img.fill(Color(0.92, 0.89, 0.85))                      # dirty off-white sticker
	var x: int = quiet_px
	var dark: bool = true
	for ww: int in widths:
		var px_w: int = ww * _MODULE_PX
		if dark and rng.randf() < 0.7:                     # random gaps = torn bars
			for px: int in px_w:
				for py: int in _BAR_H:
					img.set_pixel(x + px, py, Color(0.1, 0.1, 0.1))
		x += px_w
		dark = not dark
	return ImageTexture.create_from_image(img)
