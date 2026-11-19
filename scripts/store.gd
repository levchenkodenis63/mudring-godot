extends Node
## Имя игрока и рекорды. Локально — user://store.json (имя, id игрока, свои результаты, очередь отправки);
## общая таблица — сервер MUD RACING (../mudracing/server), маршрут /ring3d/scores, таблица ring3d_scores
## (своя: MUD RING 3D с веб-версией не сравнима). Сервер хранит лучший результат игрока на каждом уровне каждой трассы.

const API := "https://mudracing-scores.levchenkodenis63.workers.dev/ring3d/scores"
const FILE := "user://store.json"
const KEEP := 100                     # сколько своих результатов хранить локально

var online := true                    # false — в автопилоте (тесты не пишут в общую таблицу)
var data := {"name": "", "cid": "", "records": [], "pending": [], "car": -1.0, "car_hue": 0.0, "diff": "normal", "tyre": "mudlite", "track": "random"}   # гараж: модель (−1 — случайно), окраска, уровень, резина


func _ready() -> void:
	_load()
	if data["cid"] == "":
		data["cid"] = _new_cid()
		_save()


# ---------- имя ----------
var player_name: String:
	get:
		return data["name"]
	set(v):
		data["name"] = clean_name(v, "")
		_save()


## то же правило, что на сервере: HTML не пропускаем, 2–14 символов, буквы/цифры/пробел/-/.
static func clean_name(raw: String, fallback: String) -> String:
	for ch in ["<", ">", "\"", "'", "`"]:
		if raw.contains(ch):
			return fallback
	var re := RegEx.new()
	re.compile("[^A-Za-z0-9_\\s\\-.\\x{0400}-\\x{04FF}]")
	var s := re.sub(raw, " ", true)
	var sp := RegEx.new()
	sp.compile("\\s+")
	s = sp.sub(s, " ", true).strip_edges().substr(0, 14).strip_edges()
	var letters := RegEx.new()
	letters.compile("[A-Za-z0-9_\\x{0400}-\\x{04FF}]")
	if letters.search_all(s).size() < 2:
		return fallback
	return s


# ---------- локальные рекорды ----------
## добавить результат; возвращает место среди своих результатов на этом уровне (1 — личный рекорд)
func add(diff: String, track: String, total: float, best_lap: float, place: int) -> int:
	var rec := {"n": data["name"] if data["name"] != "" else "Гонщик", "t": snappedf(total, 0.01), "d": diff, "k": track,
		"b": snappedf(best_lap, 0.01), "p": place, "ts": int(Time.get_unix_time_from_system() * 1000.0)}
	var list: Array = data["records"]
	list.append(rec)
	list.sort_custom(func(a, b): return a["t"] < b["t"])
	if list.size() > KEEP:
		list.resize(KEEP)
	data["pending"].append(rec)
	_save()
	var rank := 1
	for r in list:
		if r["d"] == diff and r.get("k", "oval") == track and r["t"] < rec["t"]:
			rank += 1
	return rank


func local_top(diff: String, track: String, n := 20) -> Array:
	var out: Array = []
	for r in data["records"]:
		if r["d"] == diff and r.get("k", "oval") == track:
			out.append(r)
			if out.size() >= n:
				break
	return out


# ---------- сервер ----------
## отправить накопленные результаты (лучший на каждом уровне); cb(ответ сервера по последнему) — для экрана итогов
func sync(cb := Callable()) -> void:
	if not online or data["pending"].is_empty():
		if cb.is_valid():
			cb.call({"ok": false, "error": "offline" if not online else "nothing"})
		return
	var best := {}                                    # лучший на каждом уровне каждой трассы
	for r in data["pending"]:
		var key: String = r["d"] + "|" + r.get("k", "oval")
		if not best.has(key) or r["t"] < best[key]["t"]:
			best[key] = r
	var left: Array = best.values()
	_post_next(left, cb, {})


func _post_next(left: Array, cb: Callable, last: Dictionary) -> void:
	if left.is_empty():
		data["pending"].clear()
		_save()
		if cb.is_valid():
			cb.call(last)
		return
	var r: Dictionary = left.pop_front()
	var body := JSON.stringify({"cid": data["cid"], "name": data["name"] if data["name"] != "" else "Гонщик",
		"diff": r["d"], "track": r.get("k", "oval"), "total": r["t"], "bestLap": r["b"], "place": r["p"], "ts": r["ts"]})
	_request(API, HTTPClient.METHOD_POST, body, _on_posted.bind(left, cb, r))


func _on_posted(res: Dictionary, left: Array, cb: Callable, r: Dictionary) -> void:
	if not res.get("ok", false):
		if cb.is_valid():
			cb.call(res)              # не вышло — очередь остаётся, отправим в следующий раз
		return
	res["diff"] = r["d"]
	_post_next(left, cb, res)


## общая таблица уровня (easy|normal|hard|extreme) на трассе: cb({ok, top:[{n,t,d,b,p,me}], mine:{n,t,rank}|null, count})
func fetch(diff: String, track: String, cb: Callable) -> void:
	if not online:
		cb.call({"ok": false, "error": "offline"})
		return
	_request("%s?diff=%s&track=%s&me=%s" % [API, diff, track, data["cid"]], HTTPClient.METHOD_GET, "", cb)


func _request(url: String, method: int, body: String, cb: Callable) -> void:
	var h := HTTPRequest.new()
	h.timeout = 8.0
	add_child(h)
	h.request_completed.connect(_on_done.bind(h, cb))
	var err := h.request(url, ["Content-Type: application/json"], method, body)
	if err != OK:
		h.queue_free()
		cb.call({"ok": false, "error": "network"})


func _on_done(result: int, code: int, _headers: PackedStringArray, raw: PackedByteArray, h: HTTPRequest, cb: Callable) -> void:
	h.queue_free()
	var res = null
	if result == HTTPRequest.RESULT_SUCCESS:
		res = JSON.parse_string(raw.get_string_from_utf8())
	if typeof(res) != TYPE_DICTIONARY:
		res = {"ok": false, "error": "network" if result != HTTPRequest.RESULT_SUCCESS else "bad response %d" % code}
	cb.call(res)


## выбор в гараже: модель (−1 — случайно), сдвиг оттенка, уровень соперников, резина (для Экстрима)
func set_garage(model: int, hue: float, diff: String, tyre: String) -> void:
	data["car"] = float(model)
	data["car_hue"] = hue
	data["diff"] = diff
	data["tyre"] = tyre
	_save()


# ---------- файл ----------
func _load() -> void:
	var f := FileAccess.open(FILE, FileAccess.READ)
	if f == null:
		return
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(d) == TYPE_DICTIONARY:
		for k in data:
			if d.has(k) and typeof(d[k]) == typeof(data[k]):
				data[k] = d[k]


func _save() -> void:
	var f := FileAccess.open(FILE, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data))
		f.close()


static func _new_cid() -> String:
	var b := Crypto.new().generate_random_bytes(16)
	return "m3d-" + b.hex_encode()
