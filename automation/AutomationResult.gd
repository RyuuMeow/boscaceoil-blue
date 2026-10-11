class_name AutomationResult extends RefCounted


static func success(data: Dictionary) -> Dictionary:
	return { "result": data }


static func failure(code: String, message: String, details: Dictionary = {}) -> Dictionary:
	return { "error": {
		"code": code,
		"message": message,
		"retryable": code in ["APP_BUSY", "NOT_READY"],
		"details": details,
	} }


static func is_integer(value: Variant, minimum: int, maximum: int) -> bool:
	if not (value is int || value is float):
		return false
	return is_finite(float(value)) && float(value) == floor(float(value)) && value >= minimum && value <= maximum


static func fields(params: Dictionary, allowed: Array, required: Array = []) -> Dictionary:
	for key: Variant in params:
		if key not in allowed:
			return failure("INVALID_ARGUMENT", "Unknown argument.", { "field": key })
	for key: Variant in required:
		if not params.has(key):
			return failure("INVALID_ARGUMENT", "Required argument is missing.", { "field": key })
	return {}
