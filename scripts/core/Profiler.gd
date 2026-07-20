# Profiler autoload - add to project.godot autoloads as "Profiler"
extends Node

static var timers := {}
static var counts := {}
static var frame := 0

static func start(name: String):
	if not timers.has(name):
		timers[name] = 0.0
		counts[name] = 0
	timers[name] -= Time.get_ticks_usec()

static func stop(name: String):
	timers[name] += Time.get_ticks_usec()
	counts[name] += 1

func _process(_d):
	frame += 1
	if frame % 60 == 0:  # every 1 second
		var lines := ["[Profile] 60 frames:"]
		var sorted = []
		for k in timers:
			var total_ms = timers[k] / 1000.0
			sorted.append({"name": k, "ms": total_ms, "count": counts[k]})
		sorted.sort_custom(func(a, b): return a.ms > b.ms)
		for s in sorted:
			lines.append("  %s: %.1fms (%d calls)" % [s.name, s.ms, s.count])
		if sorted.size() > 0: print(" ".join(lines))

		# Reset
		for k in timers:
			timers[k] = 0.0
			counts[k] = 0
