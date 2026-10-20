@tool
extends EditorPlugin
func _enter_tree() -> void:
	if not OS.get_environment("SHIGAN_EXPORT_KIND").is_empty(): call_deferred("_export")
func _export() -> void:
	await get_tree().create_timer(2.0).timeout
	while EditorInterface.get_resource_filesystem().is_scanning(): await get_tree().create_timer(0.1).timeout
	var kind := OS.get_environment("SHIGAN_EXPORT_KIND")
	if kind == "android":
		var native_descriptor := "res://addons/wings_native/resident.gdextension"
		if not ProjectSettings.get_setting("wings/native_pursuit",false) or not GDExtensionManager.is_extension_loaded(native_descriptor) or not ClassDB.class_exists("WingsResidentContext"):
			printerr("EXPORT_BLOCKED reason=native_product_startup_not_registered")
			get_tree().quit(3)
			return
		if FileAccess.get_file_as_string("res://.godot/extension_list.cfg") != native_descriptor + "\n":
			printerr("EXPORT_BLOCKED reason=native_product_extension_list_not_exact")
			get_tree().quit(3)
			return
	var source := OS.get_environment("SHIGAN_EXPORT_TEMPLATE")
	var output := OS.get_environment("SHIGAN_EXPORT_OUTPUT")
	if source.is_empty() or output.is_empty() or not kind in ["android","web"]:
		printerr("EXPORT_INPUT_INVALID")
		get_tree().quit(2)
		return
	var manifest = JSON.parse_string(FileAccess.get_file_as_string("res://assets/manifest.json"))
	var export_mode := OS.get_environment("SHIGAN_EXPORT_MODE")
	if export_mode.is_empty(): export_mode = "final"
	var readiness: Dictionary = load("res://tools/build/export_readiness.gd").new().validate(manifest if manifest is Dictionary else {},export_mode)
	if not readiness.ok:
		printerr("EXPORT_BLOCKED reason=%s assets=%s" % [readiness.reason,str(readiness.blocked_ids)])
		get_tree().quit(3)
		return
	var filter = load("res://tools/build/production_export_filter.gd").new()
	var registration = JSON.parse_string(FileAccess.get_file_as_string(filter.ARMORED_REGISTRATION)) if FileAccess.file_exists(filter.ARMORED_REGISTRATION) else {}
	var armored: Dictionary = filter.validate_armored_bundle(registration if registration is Dictionary else {}, export_mode)
	if not armored.ok:
		printerr("EXPORT_BLOCKED reason=" + str(armored.reason))
		get_tree().quit(3)
		return
	add_export_plugin(filter)
	var platform: EditorExportPlatform = EditorExportPlatformAndroid.new() if kind == "android" else EditorExportPlatformWeb.new()
	var preset := platform.create_preset()
	preset.set("custom_template/debug",source)
	if kind == "android":
		preset.set("gradle_build/use_gradle_build",false)
		preset.set("package/unique_name","com.shaterguy.wingsofhumanity.dev")
		preset.set("package/name","진격의 거인 인류의 날개")
		preset.set("package/signed",false)
		preset.set("launcher_icons/main_192x192","res://assets/art/ui/game_icon.png")
		preset.set("version/code",20)
		preset.set("version/name","0.1.0-dev20-candidate-native-pursuit-r6d")
		preset.set("architectures/armeabi-v7a",false)
		preset.set("architectures/arm64-v8a",true)
		preset.set("architectures/x86",false)
		preset.set("architectures/x86_64",false)
		preset.set("permissions/internet",false)
	else:
		preset.set("variant/thread_support",false)
		preset.set("variant/extensions_support",false)
		preset.set("html/export_icon",false)
	var result := platform.export_project(preset,true,output)
	remove_export_plugin(filter)
	print("EXPORT_RESULT kind=%s code=%d" % [kind,result])
	get_tree().quit(0 if result == OK else 1)
