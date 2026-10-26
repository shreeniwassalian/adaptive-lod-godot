extends RefCounted
## Buffers rows in memory (no disk I/O while measuring) and writes a UTF-8 CSV with a header line.
## A null value is written as an empty cell, which means "not available" (0 is written as 0).

var columns: PackedStringArray
var _lines := PackedStringArray()


func _init(column_names: PackedStringArray) -> void:
	columns = column_names


func add_row(values: Array) -> void:
	assert(values.size() == columns.size(), "CSV row has %d values, expected %d" % [values.size(), columns.size()])
	var cells := PackedStringArray()
	for value in values:
		cells.append(_format(value))
	_lines.append(",".join(cells))


func row_count() -> int:
	return _lines.size()


## Returns OK or a FileAccess error code.
func save(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_line(",".join(columns))
	for line in _lines:
		file.store_line(line)
	file.close()
	return OK


func _format(value: Variant) -> String:
	if value == null:
		return ""
	if value is float:
		return String.num(value, 4)
	return str(value)
