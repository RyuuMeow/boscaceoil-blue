extends Node


func _ready() -> void:
	# Use the real application scene but suppress the first-run guide for automation.
	Controller.settings_manager._first_time = false
	add_child(load("res://Main.tscn").instantiate())
