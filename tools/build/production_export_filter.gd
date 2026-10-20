@tool
extends EditorExportPlugin
const VfxCatalog = preload("res://game/presentation/combat_vfx_catalog.gd")
const UI_FONT_FILES := ["res://assets/fonts/NotoSansKR-wght.ttf","res://assets/fonts/NotoSansKR-OFL.txt"]
const ARMORED_REGISTRATION := "res://assets/art/rig/armored_runtime_v1/registration.json"
const ARMORED_PARTS := ["girdle", "head", "head_seam_underlap", "left_foot", "left_forearm", "left_shin", "left_thigh", "left_upper_arm", "neck", "plate", "posterior_underlap", "right_foot", "right_forearm", "right_shin", "right_thigh", "right_upper_arm", "torso"]
const ARMORED_IMPORT_PARAMS := {"compress/mode":0, "mipmaps/generate":false, "process/fix_alpha_border":false, "process/premult_alpha":false, "process/size_limit":0, "compress/normal_map":0, "compress/channel_pack":0, "process/channel_remap/red":0, "process/channel_remap/green":1, "process/channel_remap/blue":2, "process/channel_remap/alpha":3}
var _allowed_assets: Dictionary = {}
static func validate_armored_bundle(registration: Dictionary, mode: String) -> Dictionary:
	var denied := {"ok":false,"paths":[],"reason":"armored_runtime_bundle_invalid"}
	if not mode in ["final", "development-validation"]: return denied
	# Isolated build-tool fixtures without the armored consumer have no bundle.
	if registration.is_empty() and not FileAccess.file_exists(ARMORED_REGISTRATION) and not FileAccess.file_exists("res://game/presentation/armored/armored_raster.gd"):
		return {"ok":true,"paths":[],"reason":""}
	if mode == "final" and (not registration.get("final_export_allowed") is bool or registration.final_export_allowed != true):
		return {"ok":false,"paths":[],"reason":"armored_art_review_pending"}
	var parts = registration.get("parts")
	if not parts is Dictionary or parts.size() != ARMORED_PARTS.size(): return denied
	var paths: Array[String] = [ARMORED_REGISTRATION]
	for name in ARMORED_PARTS:
		var part = parts.get(name)
		var path := "res://assets/art/rig/armored_runtime_v1/parts/" + str(name) + ".png"
		if not part is Dictionary or not part.get("texture_path") is String or part.texture_path != path: return denied
		if not part.get("packed_png_sha256") is String or not FileAccess.file_exists(path) or FileAccess.get_sha256(path) != part.packed_png_sha256: return denied
		var config := ConfigFile.new()
		if config.load(path + ".import") != OK: return denied
		var imported := "res://.godot/imported/" + path.get_file() + "-" + path.md5_text() + ".ctex"
		if config.get_value("remap", "importer", "") != "texture" or config.get_value("remap", "type", "") != "CompressedTexture2D" or config.get_value("remap", "path", "") != imported: return denied
		if config.get_value("deps", "source_file", "") != path or config.get_value("deps", "dest_files", []) != [imported]: return denied
		for key in ARMORED_IMPORT_PARAMS:
			if config.get_value("params", key, null) != ARMORED_IMPORT_PARAMS[key]: return denied
		paths.append(path)
	return {"ok":true,"paths":paths,"reason":""}
func _get_name() -> String:
	return "ChapterOneProductionFiles"
func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	_allowed_assets.clear()
	var manifest = JSON.parse_string(FileAccess.get_file_as_string("res://assets/manifest.json"))
	if manifest is Dictionary:
		var mode := OS.get_environment("SHIGAN_EXPORT_MODE")
		if mode.is_empty(): mode = "final"
		var readiness = load("res://tools/build/export_readiness.gd").new()
		var gate: Dictionary = readiness.validate(manifest,mode)
		if not gate.ok: return
		var registration = JSON.parse_string(FileAccess.get_file_as_string(ARMORED_REGISTRATION)) if FileAccess.file_exists(ARMORED_REGISTRATION) else {}
		var armored := validate_armored_bundle(registration if registration is Dictionary else {}, mode)
		if not armored.ok: return
		for path in armored.paths:
			if path != ARMORED_REGISTRATION: _allowed_assets[path] = true
		# PNGs use Godot's normal CompressedTexture2D import/remap, not raw decoding.
		if not armored.paths.is_empty(): add_file(ARMORED_REGISTRATION,FileAccess.get_file_as_bytes(ARMORED_REGISTRATION),false)
		for record in manifest.assets.values():
			if readiness.is_runtime_asset_path(record):
				_allowed_assets[str(record.path)] = true
				# Preserve exact licensed audio bytes alongside normal playback imports.
				if record.get("kind") == "audio":
					add_file(str(record.path),FileAccess.get_file_as_bytes(str(record.path)),false)
				# VFX validates/decodes original PNG bytes at runtime, not only .ctex.
				if record.get("kind") == "effect" and VfxCatalog.render_enabled(record):
					add_file(str(record.path),FileAccess.get_file_as_bytes(str(record.path)),false)
	# Keep unmodified font bytes and its license together; no directory wildcard.
	for font_file in UI_FONT_FILES:
		_allowed_assets[font_file] = true
		# Godot exports the font through its normal imported-resource remap.
		if font_file.ends_with(".txt"):
			add_file(font_file,FileAccess.get_file_as_bytes(font_file),false)
	_add_json("res://data")
	_add_json("res://chapters")
	add_file("res://assets/manifest.json",FileAccess.get_file_as_bytes("res://assets/manifest.json"),false)
func _add_json(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null: return
	for file in dir.get_files():
		if file.ends_with(".json"):
			var full := path.path_join(file)
			add_file(full,FileAccess.get_file_as_bytes(full),false)
	for folder in dir.get_directories(): _add_json(path.path_join(folder))
func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if path == "res://addons/wings_native/resident.gdextension" and _features.has("android"): return
	if path.begins_with("res://game/") or path.begins_with("res://scenes/"): return
	if _allowed_assets.has(path): return
	skip()
