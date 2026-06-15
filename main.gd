extends Node2D
## ============================================================================
##  NEON DRIFT — a self-contained neon arena survival shooter.
##
##  Single Node2D, single script. Everything is drawn in code (no art assets),
##  sounds are generated WAVs, entities live in plain Arrays of Dictionaries,
##  collisions are manual circle-vs-circle, input is polled directly, text uses
##  ThemeDB.fallback_font, and screen shake is applied via draw_set_transform.
##
##  Content: waves of chasers/darters/brutes/spitters, power-ups, a dash, a
##  kill-combo multiplier, a boss every few waves with bullet patterns, a local
##  top-5 leaderboard, looping music, pause, and a lot of juice.
## ============================================================================

const VERSION := "1.1.0"

enum State { MENU, PLAY, PAUSE, GAME_OVER }

# Power-up kinds
const P_RAPID := 0
const P_SPREAD := 1
const P_SHIELD := 2
const P_BOMB := 3
const P_HEAL := 4

# --- Tuning ---------------------------------------------------------------- #
const PLAYER_RADIUS := 14.0
const PLAYER_SPEED := 330.0
const PLAYER_ACCEL := 0.0012
const START_LIVES := 3
const MAX_LIVES := 5
const INVULN_TIME := 1.3
const FIRE_COOLDOWN := 0.11
const WALL_MARGIN := 26.0

const BULLET_SPEED := 780.0
const BULLET_RADIUS := 4.0
const BULLET_LIFE := 1.4

const DASH_SPEED := 1000.0
const DASH_TIME := 0.16
const DASH_CD := 1.1

const BUFF_TIME := 9.0
const COMBO_WINDOW := 2.4
const POWERUP_LIFE := 11.0
const POWERUP_DROP := 0.13
const BOSS_EVERY := 3            # boss appears when wave hits a multiple of this

# --- Palette --------------------------------------------------------------- #
const COL_GRID := Color(0.10, 0.20, 0.34, 0.30)
const COL_WALL := Color(0.25, 0.55, 1.0)
const COL_PLAYER := Color(0.20, 1.0, 0.92)
const COL_BULLET := Color(1.0, 0.92, 0.40)
const COL_TEXT := Color(0.75, 0.88, 1.0)
const COL_BOSS := Color(1.0, 0.32, 0.45)

const SAVE_PATH := "user://neon_drift.save"

# --- State ----------------------------------------------------------------- #
var font: Font
var state: int = State.MENU
var clock := 0.0
var time_alive := 0.0
var score := 0
var scores: Array = []          # leaderboard, descending, max 5
var high_score := 0
var last_rank := -1             # where the just-finished run landed (for highlight)
var new_best := false           # did the just-finished run beat the saved best?

# Player
var player_pos := Vector2.ZERO
var player_vel := Vector2.ZERO
var lives := START_LIVES
var invuln := 0.0
var fire_cd := 0.0
var aim := Vector2.RIGHT
var muzzle := 0.0

# Buffs / dash / combo
var rapid_t := 0.0
var spread_t := 0.0
var shield := false
var dash_timer := 0.0
var dash_cd_t := 0.0
var dash_vel := Vector2.ZERO
var combo := 0
var combo_timer := 0.0

# Entities
var bullets: Array = []
var enemies: Array = []
var enemy_bullets: Array = []
var particles: Array = []
var popups: Array = []
var powerups: Array = []
var stars: Array = []
var boss = null                 # Dictionary while a boss is active, else null
var bosses_killed := 0
var last_boss_wave := 0

# Spawning / difficulty
var spawn_cd := 1.0
var wave := 0

# Feel
var trauma := 0.0
var shake := Vector2.ZERO
var hitstop := 0.0
var screen_flash := 0.0

# Audio
var _sfx: Dictionary = {}
var _voices: Array = []
var _voice_i := 0
var _music: AudioStreamPlayer
var muted := false

# Input edges (computed once per frame)
var _prev_start := false
var _prev_esc := false
var _prev_dash := false
var _prev_mute := false
var _prev_quit := false
var _ed_start := false
var _ed_esc := false
var _ed_dash := false
var _ed_mute := false
var _ed_quit := false


func _ready() -> void:
	randomize()
	font = ThemeDB.fallback_font
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD   # cheap neon bloom
	material = mat
	_setup_audio()
	_load_scores()
	_init_stars()
	_reset_game()
	state = State.MENU


func _notification(what: int) -> void:
	# Release the audio streams on teardown so an abrupt quit (the engine's
	# --quit-after, a window close, or Esc->quit) doesn't leave the looping
	# music's AudioStreamWAV/playback referenced at the final resource check.
	if what == NOTIFICATION_EXIT_TREE or what == NOTIFICATION_WM_CLOSE_REQUEST:
		if is_instance_valid(_music):
			_music.stop()
			_music.stream = null


func _vp() -> Vector2:
	var s := get_viewport_rect().size
	if s.x < 1.0 or s.y < 1.0:
		return Vector2(1152, 648)
	return s


# ─────────────────────────────────────────────────────────────────────────
#  MAIN LOOP
# ─────────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	delta = minf(delta, 1.0 / 30.0)
	clock += delta
	var vp := _vp()

	# Direct input polling + manual edge detection.
	var s := _start_held();        _ed_start = s and not _prev_start;  _prev_start = s
	var es := _key(KEY_ESCAPE);     _ed_esc = es and not _prev_esc;     _prev_esc = es
	var ds := _key(KEY_SHIFT);      _ed_dash = ds and not _prev_dash;   _prev_dash = ds
	var mu := _key(KEY_M);          _ed_mute = mu and not _prev_mute;   _prev_mute = mu
	var qu := _key(KEY_Q);          _ed_quit = qu and not _prev_quit;   _prev_quit = qu

	if _ed_mute:
		_toggle_mute()

	_update_stars(delta, vp)

	match state:
		State.MENU:
			if _ed_start:
				_start_run()
			elif _ed_esc:
				get_tree().quit()
		State.PLAY:
			if _ed_esc:
				state = State.PAUSE
			else:
				_update_play(delta, vp)
		State.PAUSE:
			if _ed_esc:
				state = State.PLAY
			elif _ed_quit:
				if score > 0:           # record an abandoned run too
					_submit_score(score)
				state = State.MENU
		State.GAME_OVER:
			if _ed_start:
				_start_run()
			elif _ed_esc:
				state = State.MENU

	if state != State.PAUSE:
		_update_particles(delta)
		_update_popups(delta)
		_update_shake(delta)
		screen_flash = maxf(0.0, screen_flash - delta * 3.0)

	queue_redraw()


func _start_run() -> void:
	_reset_game()
	state = State.PLAY


func _reset_game() -> void:
	var vp := _vp()
	player_pos = vp * 0.5
	player_vel = Vector2.ZERO
	lives = START_LIVES
	invuln = 0.0
	fire_cd = 0.0
	muzzle = 0.0
	aim = Vector2.RIGHT
	rapid_t = 0.0
	spread_t = 0.0
	shield = false
	dash_timer = 0.0
	dash_cd_t = 0.0
	combo = 0
	combo_timer = 0.0
	new_best = false
	score = 0
	time_alive = 0.0
	spawn_cd = 1.0
	wave = 0
	bosses_killed = 0
	last_boss_wave = 0
	boss = null
	bullets.clear()
	enemies.clear()
	enemy_bullets.clear()
	particles.clear()
	popups.clear()
	powerups.clear()
	trauma = 0.0
	hitstop = 0.0
	screen_flash = 0.0


# ─────────────────────────────────────────────────────────────────────────
#  GAMEPLAY UPDATE
# ─────────────────────────────────────────────────────────────────────────
func _update_play(delta: float, vp: Vector2) -> void:
	if hitstop > 0.0:                       # freeze-frame for punch
		hitstop = maxf(0.0, hitstop - delta)
		return

	time_alive += delta
	invuln = maxf(0.0, invuln - delta)
	fire_cd = maxf(0.0, fire_cd - delta)
	muzzle = maxf(0.0, muzzle - delta)
	rapid_t = maxf(0.0, rapid_t - delta)
	spread_t = maxf(0.0, spread_t - delta)
	dash_cd_t = maxf(0.0, dash_cd_t - delta)
	if combo_timer > 0.0:
		combo_timer -= delta
		if combo_timer <= 0.0:
			combo = 0

	# --- Movement intent ---
	var mv := Vector2.ZERO
	if _key(KEY_W) or _key(KEY_UP):    mv.y -= 1.0
	if _key(KEY_S) or _key(KEY_DOWN):  mv.y += 1.0
	if _key(KEY_A) or _key(KEY_LEFT):  mv.x -= 1.0
	if _key(KEY_D) or _key(KEY_RIGHT): mv.x += 1.0
	if mv.length() > 0.0:
		mv = mv.normalized()

	# --- Dash trigger ---
	if _ed_dash and dash_timer <= 0.0 and dash_cd_t <= 0.0:
		var dd := mv if mv.length() > 0.0 else aim
		dd = dd.normalized() if dd.length() > 0.0 else aim
		dash_vel = dd * DASH_SPEED
		dash_timer = DASH_TIME
		dash_cd_t = DASH_CD
		add_trauma(0.08)
		_play("dash", -4.0, 1.0)

	# --- Move (dashing overrides normal control) ---
	if dash_timer > 0.0:
		dash_timer -= delta
		player_pos += dash_vel * delta
		dash_vel *= pow(0.02, delta)
		player_vel = dash_vel
		_spark(player_pos, -dash_vel * 0.08 + Vector2(randf_range(-25, 25), randf_range(-25, 25)),
			COL_PLAYER, 0.25, 3.0)
	else:
		var target := mv * PLAYER_SPEED
		player_vel = player_vel.lerp(target, 1.0 - pow(PLAYER_ACCEL, delta))
		player_pos += player_vel * delta

	var lo := WALL_MARGIN + PLAYER_RADIUS
	player_pos.x = clampf(player_pos.x, lo, vp.x - lo)
	player_pos.y = clampf(player_pos.y, lo, vp.y - lo)

	# --- Aim ---
	var to_mouse := get_viewport().get_mouse_position() - player_pos
	if to_mouse.length() > 1.0:
		aim = to_mouse.normalized()

	# --- Fire ---
	if (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or _key(KEY_SPACE)) and fire_cd <= 0.0:
		_fire(spread_t > 0.0)
		fire_cd = FIRE_COOLDOWN * (0.45 if rapid_t > 0.0 else 1.0)

	# --- Spawning (paused while a boss is on screen) ---
	if boss == null:
		spawn_cd -= delta
		if spawn_cd <= 0.0:
			_spawn_enemy(vp)
			spawn_cd = _spawn_interval()

	# --- Waves & boss trigger ---
	var w := int(time_alive / 15.0)
	if w > wave:
		wave = w
		_popup(player_pos + Vector2(0, -46), "WAVE %d" % (wave + 1), COL_WALL)
		_play("wave", -5.0, 1.0)
	if boss == null and wave > 0 and wave % BOSS_EVERY == 0 and wave != last_boss_wave:
		last_boss_wave = wave
		_spawn_boss(vp)

	_update_bullets(delta, vp)
	_update_enemies(delta, vp)
	_update_boss(delta, vp)
	_update_enemy_bullets(delta, vp)
	_update_powerups(delta, vp)
	_collisions(vp)


func _spawn_interval() -> float:
	var base := clampf(1.15 - time_alive * 0.013, 0.30, 1.15)
	return base * randf_range(0.8, 1.2)


func _fire(spread: bool) -> void:
	var dirs: Array = []
	if spread:
		dirs = [aim.rotated(-0.22), aim, aim.rotated(0.22)]
	else:
		dirs = [aim.rotated(randf_range(-0.035, 0.035))]
	for d in dirs:
		bullets.append({"pos": player_pos + d * (PLAYER_RADIUS + 6.0), "vel": d * BULLET_SPEED, "life": BULLET_LIFE})
	muzzle = 0.06
	player_vel -= aim * 40.0
	add_trauma(0.04)
	_play("shoot", -7.0, randf_range(0.95, 1.12))
	for i in 3:
		var s := aim.rotated(randf_range(-0.55, 0.55)) * randf_range(70.0, 170.0)
		_spark(player_pos + aim * PLAYER_RADIUS, s, COL_BULLET, randf_range(0.1, 0.22), randf_range(1.5, 3.0))


func _spawn_enemy(vp: Vector2) -> void:
	var p := Vector2.ZERO
	match randi() % 4:
		0: p = Vector2(randf() * vp.x, -30.0)
		1: p = Vector2(vp.x + 30.0, randf() * vp.y)
		2: p = Vector2(randf() * vp.x, vp.y + 30.0)
		_: p = Vector2(-30.0, randf() * vp.y)

	var kind := 0
	var roll := randf()
	if time_alive > 35.0 and roll < 0.18:
		kind = 3
	elif time_alive > 25.0 and roll < 0.38:
		kind = 2
	elif time_alive > 12.0 and roll < 0.60:
		kind = 1

	var e := {"pos": p, "vel": Vector2.ZERO, "rot": randf() * TAU, "anim": 0.0, "flash": 0.0, "kind": kind, "fire_t": randf_range(1.0, 2.0)}
	match kind:
		0:
			e["r"] = 16.0; e["hp"] = 1; e["speed"] = 72.0; e["value"] = 100
			e["col"] = Color(1.0, 0.35, 0.7); e["spin"] = randf_range(-2.0, 2.0)
		1:
			e["r"] = 12.0; e["hp"] = 1; e["speed"] = 142.0; e["value"] = 150
			e["col"] = Color(1.0, 0.75, 0.2); e["spin"] = randf_range(-4.0, 4.0)
		2:
			e["r"] = 24.0; e["hp"] = 4; e["speed"] = 54.0; e["value"] = 300
			e["col"] = Color(0.62, 0.42, 1.0); e["spin"] = randf_range(-1.2, 1.2)
		_:
			e["r"] = 14.0; e["hp"] = 2; e["speed"] = 70.0; e["value"] = 250
			e["col"] = Color(0.5, 1.0, 0.55); e["spin"] = randf_range(-1.5, 1.5)
	e["max_hp"] = e["hp"]
	e["speed"] = float(e["speed"]) * (1.0 + time_alive * 0.02)
	enemies.append(e)


func _update_bullets(delta: float, vp: Vector2) -> void:
	for b in bullets:
		b["pos"] += b["vel"] * delta
		b["life"] -= delta
	for i in range(bullets.size() - 1, -1, -1):
		var b: Dictionary = bullets[i]
		if b["life"] <= 0.0 or not _in_bounds(b["pos"], vp, 60.0):
			bullets.remove_at(i)


func _update_enemies(delta: float, vp: Vector2) -> void:
	for e in enemies:
		e["anim"] = float(e["anim"]) + delta
		e["rot"] = float(e["rot"]) + float(e["spin"]) * delta
		e["flash"] = maxf(0.0, float(e["flash"]) - delta)
		var to_p: Vector2 = player_pos - e["pos"]
		var d := to_p.length()
		var dir: Vector2 = to_p / d if d > 0.001 else Vector2.RIGHT
		var desired: Vector2
		if int(e["kind"]) == 3:                       # spitter — keep distance & shoot
			var pref := 300.0
			if d > pref + 40.0:
				desired = dir * float(e["speed"])
			elif d < pref - 40.0:
				desired = -dir * float(e["speed"])
			else:
				desired = Vector2(-dir.y, dir.x) * float(e["speed"]) * 0.6
			e["fire_t"] = float(e["fire_t"]) - delta
			if float(e["fire_t"]) <= 0.0 and d < 540.0:
				_enemy_bullet(e["pos"], dir * 240.0, Color(0.6, 1.0, 0.5))
				e["fire_t"] = randf_range(1.4, 2.2)
				_play("shoot", -12.0, 0.7)
		else:
			desired = dir * float(e["speed"])
		e["vel"] = (e["vel"] as Vector2).lerp(desired, 1.0 - pow(0.02, delta))
		e["pos"] += e["vel"] * delta

	# Light separation so they don't perfectly stack.
	var n := enemies.size()
	for i in range(n):
		for j in range(i + 1, n):
			var a: Dictionary = enemies[i]
			var b: Dictionary = enemies[j]
			var off: Vector2 = a["pos"] - b["pos"]
			var dd := off.length()
			var mind: float = float(a["r"]) + float(b["r"])
			if dd > 0.001 and dd < mind:
				var push := off / dd * (mind - dd) * 0.5
				a["pos"] += push
				b["pos"] -= push


func _enemy_bullet(pos: Vector2, vel: Vector2, col: Color) -> void:
	enemy_bullets.append({"pos": pos, "vel": vel, "life": 4.5, "r": 6.0, "col": col})


func _update_enemy_bullets(delta: float, vp: Vector2) -> void:
	for b in enemy_bullets:
		b["pos"] += b["vel"] * delta
		b["life"] -= delta
	for i in range(enemy_bullets.size() - 1, -1, -1):
		var b: Dictionary = enemy_bullets[i]
		if b["life"] <= 0.0 or not _in_bounds(b["pos"], vp, 40.0):
			enemy_bullets.remove_at(i)


# ─────────────────────────────────────────────────────────────────────────
#  BOSS
# ─────────────────────────────────────────────────────────────────────────
func _spawn_boss(vp: Vector2) -> void:
	var hp := 40 + bosses_killed * 30
	boss = {
		"pos": Vector2(vp.x * 0.5, -70.0), "hp": hp, "max_hp": hp, "r": 46.0,
		"phase": 1, "t_radial": 2.0, "t_aim": 1.4, "t_spawn": 4.0,
		"anim": 0.0, "flash": 0.0, "swirl": randf() * TAU,
	}
	_popup(vp * Vector2(0.5, 0.18), "!!  BOSS  !!", COL_BOSS)
	add_trauma(0.5)
	_play("wave", 0.0, 0.55)


func _update_boss(delta: float, vp: Vector2) -> void:
	if boss == null:
		return
	boss["anim"] = float(boss["anim"]) + delta
	boss["flash"] = maxf(0.0, float(boss["flash"]) - delta)
	boss["swirl"] = float(boss["swirl"]) + delta * 0.5
	if int(boss["phase"]) == 1 and int(boss["hp"]) <= int(boss["max_hp"]) * 0.5:
		boss["phase"] = 2
		add_trauma(0.4)
		_popup(boss["pos"], "ENRAGED", COL_BOSS)

	var p2: bool = int(boss["phase"]) == 2
	var center := Vector2(vp.x * 0.5, vp.y * 0.30)
	var tgt := center + Vector2(cos(float(boss["swirl"])) * vp.x * 0.28, sin(float(boss["swirl"]) * 1.3) * 40.0)
	boss["pos"] = (boss["pos"] as Vector2).lerp(tgt, 1.0 - pow(0.12, delta))

	boss["t_radial"] = float(boss["t_radial"]) - delta
	if float(boss["t_radial"]) <= 0.0:
		_boss_radial(p2)
		boss["t_radial"] = 1.5 if p2 else 2.4
	boss["t_aim"] = float(boss["t_aim"]) - delta
	if float(boss["t_aim"]) <= 0.0:
		_boss_aim()
		boss["t_aim"] = 0.85 if p2 else 1.4
	boss["t_spawn"] = float(boss["t_spawn"]) - delta
	if float(boss["t_spawn"]) <= 0.0:
		var count := 2 if p2 else 1
		for i in count:
			_spawn_minion(boss["pos"])
		boss["t_spawn"] = 3.0 if p2 else 4.5


func _boss_radial(p2: bool) -> void:
	var count := 18 if p2 else 12
	var off: float = float(boss["anim"]) if p2 else 0.0
	for i in count:
		var a := TAU * float(i) / float(count) + off
		_enemy_bullet(boss["pos"], Vector2(cos(a), sin(a)) * 205.0, Color(1.0, 0.4, 0.5))
	add_trauma(0.08)
	_play("shoot", -5.0, 0.55)


func _boss_aim() -> void:
	var d := (player_pos - (boss["pos"] as Vector2))
	d = d.normalized() if d.length() > 0.001 else Vector2.DOWN
	for k in [-0.2, 0.0, 0.2]:
		_enemy_bullet(boss["pos"], d.rotated(k) * 265.0, Color(1.0, 0.6, 0.3))
	_play("shoot", -7.0, 0.7)


func _spawn_minion(at: Vector2) -> void:
	var a := randf() * TAU
	enemies.append({
		"pos": at + Vector2(cos(a), sin(a)) * 50.0, "vel": Vector2(cos(a), sin(a)) * 120.0,
		"rot": randf() * TAU, "anim": 0.0, "flash": 0.0, "kind": 0, "fire_t": 0.0,
		"r": 16.0, "hp": 1, "max_hp": 1, "speed": 90.0 * (1.0 + time_alive * 0.02),
		"value": 100, "col": Color(1.0, 0.35, 0.7), "spin": randf_range(-2.0, 2.0),
	})


func _kill_boss() -> void:
	var at: Vector2 = boss["pos"]
	bosses_killed += 1
	var gained := int(round(5000.0 * _mult()))
	score += gained
	_popup(at, "+%d" % gained, Color(1.0, 0.9, 0.4))
	for i in 7:
		_explosion(at + Vector2(randf_range(-34, 34), randf_range(-34, 34)), COL_BOSS, 30.0)
	add_trauma(1.0)
	hitstop = 0.18
	screen_flash = 0.6
	_play("bossdie", 2.0, 1.0)
	enemy_bullets.clear()
	for i in 2:
		_spawn_powerup(at + Vector2(randf_range(-40, 40), randf_range(-40, 40)))
	boss = null


# ─────────────────────────────────────────────────────────────────────────
#  POWER-UPS
# ─────────────────────────────────────────────────────────────────────────
func _spawn_powerup(at: Vector2) -> void:
	var r := randf()
	var t := P_HEAL
	if r < 0.30: t = P_RAPID
	elif r < 0.55: t = P_SPREAD
	elif r < 0.78: t = P_SHIELD
	elif r < 0.90: t = P_BOMB
	powerups.append({"pos": at, "vel": Vector2(randf_range(-50, 50), randf_range(-50, 50)),
		"type": t, "life": POWERUP_LIFE, "anim": randf() * TAU})


func _update_powerups(delta: float, vp: Vector2) -> void:
	for pu in powerups:
		pu["anim"] = float(pu["anim"]) + delta
		pu["life"] = float(pu["life"]) - delta
		pu["pos"] += pu["vel"] * delta
		pu["vel"] = (pu["vel"] as Vector2) * pow(0.25, delta)
		var to: Vector2 = player_pos - pu["pos"]
		if to.length() < 130.0:                  # gentle magnet
			pu["pos"] += to.normalized() * 90.0 * delta
	for i in range(powerups.size() - 1, -1, -1):
		var pu: Dictionary = powerups[i]
		if float(pu["life"]) <= 0.0:
			powerups.remove_at(i)
			continue
		if player_pos.distance_to(pu["pos"]) <= PLAYER_RADIUS + 16.0:
			_apply_powerup(int(pu["type"]), pu["pos"])
			powerups.remove_at(i)


func _apply_powerup(t: int, at: Vector2) -> void:
	var c := _pu_color(t)
	match t:
		P_RAPID:  rapid_t = BUFF_TIME;  _popup(at, "RAPID FIRE", c)
		P_SPREAD: spread_t = BUFF_TIME; _popup(at, "SPREAD", c)
		P_SHIELD: shield = true;        _popup(at, "SHIELD", c)
		P_BOMB:   _bomb();              _popup(at, "BOMB!", c)
		P_HEAL:   lives = mini(lives + 1, MAX_LIVES); _popup(at, "+1 LIFE", c)
	_play("powerup", -2.0, randf_range(0.97, 1.06))
	_ring(player_pos, c, 14.0, 40.0, 0.35)


func _bomb() -> void:
	for e in enemies:
		if not e.get("dead", false):
			e["dead"] = true
			_explosion(e["pos"], e["col"], float(e["r"]))
			score += int(round(float(e["value"]) * 0.5))
	if boss != null:
		boss["hp"] = int(boss["hp"]) - int(float(boss["max_hp"]) * 0.15)
		boss["flash"] = 0.12
		if int(boss["hp"]) <= 0:
			_kill_boss()
	enemy_bullets.clear()
	add_trauma(0.8)
	hitstop = 0.12
	screen_flash = 0.6
	_play("bomb", 0.0, 1.0)


func _pu_color(t: int) -> Color:
	match t:
		P_RAPID:  return Color(1.0, 0.7, 0.2)
		P_SPREAD: return Color(0.3, 1.0, 0.9)
		P_SHIELD: return Color(0.4, 0.7, 1.0)
		P_BOMB:   return Color(1.0, 0.3, 0.5)
		_:        return Color(0.4, 1.0, 0.5)


func _pu_letter(t: int) -> String:
	match t:
		P_RAPID:  return "R"
		P_SPREAD: return "3"
		P_SHIELD: return "S"
		P_BOMB:   return "B"
		_:        return "+"


# ─────────────────────────────────────────────────────────────────────────
#  COLLISIONS
# ─────────────────────────────────────────────────────────────────────────
func _mult() -> float:
	return clampf(1.0 + float(combo) * 0.1, 1.0, 5.0)


func _collisions(vp: Vector2) -> void:
	# Player bullets vs enemies.
	for b in bullets:
		if b.get("dead", false):
			continue
		for e in enemies:
			if e.get("dead", false):
				continue
			if (b["pos"] as Vector2).distance_to(e["pos"]) <= BULLET_RADIUS + float(e["r"]):
				b["dead"] = true
				e["hp"] = int(e["hp"]) - 1
				e["flash"] = 0.12
				_hit_sparks(b["pos"], e["col"])
				add_trauma(0.04)
				if int(e["hp"]) <= 0:
					_kill_enemy(e)
				else:
					_play("hit", -17.0, 1.4)
				break

	# Player bullets vs boss.
	if boss != null:
		for b in bullets:
			if b.get("dead", false):
				continue
			if (b["pos"] as Vector2).distance_to(boss["pos"]) <= BULLET_RADIUS + float(boss["r"]):
				b["dead"] = true
				boss["hp"] = int(boss["hp"]) - 1
				boss["flash"] = 0.10
				_hit_sparks(b["pos"], Color(1.0, 0.5, 0.6))
				if int(boss["hp"]) <= 0:
					_kill_boss()
					break

	# Dash is offensive: ram enemies / chip the boss.
	if dash_timer > 0.0:
		for e in enemies:
			if e.get("dead", false):
				continue
			if player_pos.distance_to(e["pos"]) <= PLAYER_RADIUS + 8.0 + float(e["r"]):
				e["hp"] = int(e["hp"]) - 1
				e["flash"] = 0.12
				_hit_sparks(e["pos"], e["col"])
				if int(e["hp"]) <= 0:
					_kill_enemy(e)
		if boss != null and player_pos.distance_to(boss["pos"]) <= PLAYER_RADIUS + 8.0 + float(boss["r"]):
			boss["hp"] = int(boss["hp"]) - 2
			boss["flash"] = 0.12
			if int(boss["hp"]) <= 0:
				_kill_boss()

	# Things that hurt the player (skipped while invulnerable or dashing).
	if invuln <= 0.0 and dash_timer <= 0.0:
		var hurt := false
		for e in enemies:
			if e.get("dead", false):
				continue
			if player_pos.distance_to(e["pos"]) <= PLAYER_RADIUS + float(e["r"]):
				var dir := ((e["pos"] as Vector2) - player_pos)
				dir = dir.normalized() if dir.length() > 0.001 else Vector2.RIGHT
				e["pos"] += dir * 64.0
				e["vel"] = dir * 260.0
				_player_hit(e["pos"])
				hurt = true
				break
		if not hurt and boss != null and player_pos.distance_to(boss["pos"]) <= PLAYER_RADIUS + float(boss["r"]):
			_player_hit(boss["pos"])
			hurt = true
		if not hurt:
			for b in enemy_bullets:
				if b.get("dead", false):
					continue
				if player_pos.distance_to(b["pos"]) <= PLAYER_RADIUS + float(b["r"]):
					b["dead"] = true
					_player_hit(b["pos"])
					break

	# Cull the dead.
	for i in range(enemies.size() - 1, -1, -1):
		if enemies[i].get("dead", false):
			enemies.remove_at(i)
	for i in range(bullets.size() - 1, -1, -1):
		if bullets[i].get("dead", false):
			bullets.remove_at(i)
	for i in range(enemy_bullets.size() - 1, -1, -1):
		if enemy_bullets[i].get("dead", false):
			enemy_bullets.remove_at(i)


func _kill_enemy(e: Dictionary) -> void:
	e["dead"] = true
	combo += 1
	combo_timer = COMBO_WINDOW
	var gained := int(round(float(e["value"]) * _mult()))
	score += gained
	_explosion(e["pos"], e["col"], float(e["r"]))
	_popup(e["pos"], "+%d" % gained, e["col"])
	add_trauma(0.16)
	_play("explosion", -6.0, randf_range(0.9, 1.15))
	if randf() < POWERUP_DROP:
		_spawn_powerup(e["pos"])


func _player_hit(src: Vector2) -> void:
	if shield:
		shield = false
		invuln = 0.6
		add_trauma(0.4)
		hitstop = 0.06
		_play("shield", -2.0, 1.0)
		_ring(player_pos, Color(0.4, 0.7, 1.0), 18.0, 55.0, 0.4)
		return
	lives -= 1
	invuln = INVULN_TIME
	combo = 0
	combo_timer = 0.0
	add_trauma(0.7)
	hitstop = 0.10
	_play("hit", -2.0, 0.8)
	var dir := (player_pos - src)
	dir = dir.normalized() if dir.length() > 0.001 else Vector2.UP
	player_vel = dir * 210.0
	_explosion(player_pos, COL_PLAYER, 18.0)
	if lives <= 0:
		_game_over()


func _game_over() -> void:
	state = State.GAME_OVER
	new_best = score > high_score        # capture before _submit_score mutates high_score
	add_trauma(1.0)
	_play("gameover", 0.0, 1.0)
	_submit_score(score)


# ─────────────────────────────────────────────────────────────────────────
#  PARTICLES / POPUPS / SHAKE
# ─────────────────────────────────────────────────────────────────────────
func _spark(pos: Vector2, vel: Vector2, col: Color, life: float, size: float) -> void:
	particles.append({"pos": pos, "vel": vel, "life": life, "max_life": life, "col": col, "size": size})


func _ring(pos: Vector2, col: Color, r0: float, spread: float, life: float) -> void:
	particles.append({"pos": pos, "vel": Vector2.ZERO, "life": life, "max_life": life,
		"col": col, "size": 0.0, "ring": true, "r0": r0, "spread": spread})


func _explosion(pos: Vector2, col: Color, r: float) -> void:
	_ring(pos, col, r * 0.5, r * 2.6, 0.4)
	var n := int(10 + r * 0.6)
	for i in n:
		var a := randf() * TAU
		var sp := randf_range(60.0, 260.0) * (0.6 + r / 24.0)
		_spark(pos, Vector2(cos(a), sin(a)) * sp, col, randf_range(0.25, 0.6), randf_range(2.0, 4.0))
	for i in 5:
		var a := randf() * TAU
		_spark(pos, Vector2(cos(a), sin(a)) * randf_range(120.0, 320.0), Color(1, 1, 1), randf_range(0.15, 0.3), randf_range(1.5, 3.0))


func _hit_sparks(pos: Vector2, col: Color) -> void:
	for i in 4:
		var a := randf() * TAU
		_spark(pos, Vector2(cos(a), sin(a)) * randf_range(60.0, 180.0), col, randf_range(0.12, 0.25), randf_range(1.5, 3.0))


func _popup(pos: Vector2, text: String, col: Color) -> void:
	popups.append({"pos": pos, "vel": Vector2(0, -52), "life": 0.9, "max_life": 0.9, "text": text, "col": col})


func _update_particles(delta: float) -> void:
	for i in range(particles.size() - 1, -1, -1):
		var p: Dictionary = particles[i]
		p["life"] = float(p["life"]) - delta
		if float(p["life"]) <= 0.0:
			particles.remove_at(i)
			continue
		if not p.get("ring", false):
			p["vel"] = (p["vel"] as Vector2) * pow(0.12, delta)
			p["pos"] += p["vel"] * delta


func _update_popups(delta: float) -> void:
	for i in range(popups.size() - 1, -1, -1):
		var p: Dictionary = popups[i]
		p["life"] = float(p["life"]) - delta
		if float(p["life"]) <= 0.0:
			popups.remove_at(i)
			continue
		p["pos"] += p["vel"] * delta
		p["vel"] = (p["vel"] as Vector2) * pow(0.2, delta)


func add_trauma(amount: float) -> void:
	trauma = minf(1.0, trauma + amount)


func _update_shake(delta: float) -> void:
	trauma = maxf(0.0, trauma - delta * 1.6)
	var amt := trauma * trauma
	shake = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * amt * 20.0


# ─────────────────────────────────────────────────────────────────────────
#  STARS / INPUT HELPERS
# ─────────────────────────────────────────────────────────────────────────
func _init_stars() -> void:
	stars.clear()
	for i in 80:
		stars.append({"np": Vector2(randf(), randf()), "z": randf_range(0.3, 1.0),
			"seed": randf() * TAU, "spd": randf_range(0.01, 0.05)})


func _update_stars(delta: float, _vp_unused: Vector2) -> void:
	for s in stars:
		var np: Vector2 = s["np"]
		np.x -= float(s["spd"]) * delta * float(s["z"])
		if np.x < 0.0:
			np.x += 1.0
			np.y = randf()
		s["np"] = np


func _key(k: int) -> bool:
	return Input.is_key_pressed(k)


func _start_held() -> bool:
	return _key(KEY_SPACE) or _key(KEY_ENTER) or _key(KEY_KP_ENTER) or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)


func _in_bounds(p: Vector2, vp: Vector2, m: float) -> bool:
	return p.x > -m and p.y > -m and p.x < vp.x + m and p.y < vp.y + m


# ─────────────────────────────────────────────────────────────────────────
#  RENDERING
# ─────────────────────────────────────────────────────────────────────────
func _draw() -> void:
	var vp := _vp()
	draw_set_transform(shake, 0.0, Vector2.ONE)
	_draw_background(vp)
	_draw_walls(vp)
	if state != State.MENU:
		_draw_particles()
		_draw_powerups()
		_draw_enemy_bullets()
		_draw_bullets()
		_draw_enemies()
		_draw_boss()
		if state == State.PLAY or state == State.PAUSE:
			_draw_player()
		_draw_popups()

	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if screen_flash > 0.0:
		draw_rect(Rect2(0, 0, vp.x, vp.y), Color(1, 1, 1, clampf(screen_flash, 0.0, 1.0) * 0.4))
	match state:
		State.MENU:      _draw_menu(vp)
		State.PLAY:      _draw_hud(vp)
		State.PAUSE:     _draw_hud(vp); _draw_pause(vp)
		State.GAME_OVER: _draw_gameover(vp)
	if muted:
		_text("MUTED (M)", Vector2(vp.x - 92, vp.y - 14), 12, Color(0.6, 0.5, 0.5))


# --- Glow primitives ------------------------------------------------------- #
func _glow_circle(pos: Vector2, r: float, col: Color) -> void:
	draw_circle(pos, r * 2.2, Color(col.r, col.g, col.b, col.a * 0.05))
	draw_circle(pos, r * 1.5, Color(col.r, col.g, col.b, col.a * 0.10))
	draw_circle(pos, r, col)


func _glow_line(a: Vector2, b: Vector2, col: Color, w: float) -> void:
	draw_line(a, b, Color(col.r, col.g, col.b, col.a * 0.12), w * 3.0)
	draw_line(a, b, Color(col.r, col.g, col.b, col.a * 0.25), w * 1.8)
	draw_line(a, b, col, w)


func _glow_poly(points: PackedVector2Array, col: Color) -> void:
	draw_colored_polygon(points, Color(col.r, col.g, col.b, col.a * 0.12))
	var n := points.size()
	for i in n:
		_glow_line(points[i], points[(i + 1) % n], col, 2.0)


func _poly(center: Vector2, r: float, sides: int, rot: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in sides:
		var a := rot + TAU * float(i) / float(sides)
		pts.append(center + Vector2(cos(a), sin(a)) * r)
	return pts


func _draw_background(vp: Vector2) -> void:
	for s in stars:
		var pos := Vector2(float(s["np"].x) * vp.x, float(s["np"].y) * vp.y)
		var tw := 0.4 + 0.6 * absf(sin(clock * 1.5 + float(s["seed"])))
		draw_circle(pos, float(s["z"]) * 1.6, Color(0.6, 0.8, 1.0, float(s["z"]) * tw * 0.5))
	var step := 48.0
	var gx := step
	while gx < vp.x:
		draw_line(Vector2(gx, 0), Vector2(gx, vp.y), COL_GRID, 1.0)
		gx += step
	var gy := step
	while gy < vp.y:
		draw_line(Vector2(0, gy), Vector2(vp.x, gy), COL_GRID, 1.0)
		gy += step


func _draw_walls(vp: Vector2) -> void:
	var r := Rect2(WALL_MARGIN, WALL_MARGIN, vp.x - 2.0 * WALL_MARGIN, vp.y - 2.0 * WALL_MARGIN)
	var pts := PackedVector2Array([r.position, r.position + Vector2(r.size.x, 0), r.position + r.size, r.position + Vector2(0, r.size.y)])
	for i in 4:
		_glow_line(pts[i], pts[(i + 1) % 4], COL_WALL, 2.0)


func _draw_player() -> void:
	var blink := 1.0
	if invuln > 0.0:
		blink = 0.30 + 0.70 * (0.5 + 0.5 * sin(clock * 40.0))
	var a := aim.angle()
	var col := Color(COL_PLAYER.r, COL_PLAYER.g, COL_PLAYER.b, blink)
	var tip := player_pos + Vector2(cos(a), sin(a)) * (PLAYER_RADIUS + 9.0)
	var l := player_pos + Vector2(cos(a + 2.5), sin(a + 2.5)) * PLAYER_RADIUS
	var r := player_pos + Vector2(cos(a - 2.5), sin(a - 2.5)) * PLAYER_RADIUS
	_glow_poly(PackedVector2Array([tip, l, r]), col)
	_glow_circle(player_pos, 5.0, Color(1, 1, 1, blink))
	if shield:
		var sr := PLAYER_RADIUS + 9.0 + 2.0 * sin(clock * 6.0)
		draw_arc(player_pos, sr, 0.0, TAU, 32, Color(0.4, 0.7, 1.0, 0.6), 2.0, true)
	if player_vel.length() > 25.0 or dash_timer > 0.0:
		var back := player_pos - Vector2(cos(a), sin(a)) * PLAYER_RADIUS
		_glow_circle(back, 4.0 * randf_range(0.6, 1.2), Color(1.0, 0.6, 0.2, blink))
	if muzzle > 0.0:
		_glow_circle(tip, 7.0, Color(COL_BULLET.r, COL_BULLET.g, COL_BULLET.b, muzzle / 0.06))


func _draw_bullets() -> void:
	for b in bullets:
		var p: Vector2 = b["pos"]
		var tail := p - (b["vel"] as Vector2).normalized() * 11.0
		_glow_line(tail, p, COL_BULLET, 2.0)
		_glow_circle(p, BULLET_RADIUS, COL_BULLET)


func _draw_enemy_bullets() -> void:
	for b in enemy_bullets:
		_glow_circle(b["pos"], float(b["r"]), b["col"])


func _draw_enemies() -> void:
	for e in enemies:
		var c: Color = e["col"]
		var flash: float = float(e["flash"])
		if flash > 0.0:
			c = c.lerp(Color(1, 1, 1), clampf(flash / 0.12, 0.0, 1.0) * 0.85)
		var center: Vector2 = e["pos"]
		var r: float = float(e["r"])
		var sides := 4
		match int(e["kind"]):
			0: sides = 4
			1: sides = 3
			2: sides = 6
			_: sides = 5
		var pr := r * (1.0 + 0.05 * sin(float(e["anim"]) * 6.0))
		_glow_poly(_poly(center, pr, sides, float(e["rot"])), c)
		_glow_circle(center, r * 0.32, c)


func _draw_boss() -> void:
	if boss == null:
		return
	var c := COL_BOSS
	var flash: float = float(boss["flash"])
	if flash > 0.0:
		c = c.lerp(Color(1, 1, 1), clampf(flash / 0.10, 0.0, 1.0) * 0.9)
	var center: Vector2 = boss["pos"]
	var r: float = float(boss["r"])
	var an: float = float(boss["anim"])
	_glow_poly(_poly(center, r * (1.0 + 0.04 * sin(an * 4.0)), 8, an * 0.5), c)
	_glow_poly(_poly(center, r * 0.6, 6, -an * 0.8), Color(1.0, 0.6, 0.3))
	_glow_circle(center, r * 0.28, Color(1, 1, 1))


func _draw_powerups() -> void:
	for pu in powerups:
		var t := int(pu["type"])
		var c := _pu_color(t)
		var center: Vector2 = pu["pos"]
		var an: float = float(pu["anim"])
		var blink := 1.0
		if float(pu["life"]) < 3.0:                # blink when about to expire
			blink = 0.4 + 0.6 * (0.5 + 0.5 * sin(an * 14.0))
		var cc := Color(c.r, c.g, c.b, blink)
		var sz := 13.0 * (1.0 + 0.12 * sin(an * 7.0))
		_glow_poly(_poly(center, sz, 4, an * 1.2), cc)
		_text_center(_pu_letter(t), center, 16, cc)


func _draw_particles() -> void:
	for p in particles:
		var t := clampf(float(p["life"]) / float(p["max_life"]), 0.0, 1.0)
		var c: Color = p["col"]
		if p.get("ring", false):
			var rr := float(p["r0"]) + (1.0 - t) * float(p["spread"])
			draw_arc(p["pos"], rr, 0.0, TAU, 28, Color(c.r, c.g, c.b, t * 0.6), 2.0 + t * 2.0, true)
		else:
			draw_circle(p["pos"], maxf(0.5, float(p["size"]) * t), Color(c.r, c.g, c.b, t))


func _draw_popups() -> void:
	for p in popups:
		var t := clampf(float(p["life"]) / float(p["max_life"]), 0.0, 1.0)
		var c: Color = p["col"]
		_text_center(String(p["text"]), p["pos"], 16, Color(c.r, c.g, c.b, t))


# --- Text helpers ---------------------------------------------------------- #
func _text(s: String, pos: Vector2, size: int, col: Color) -> void:
	draw_string(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _text_center(s: String, center: Vector2, size: int, col: Color) -> void:
	var ss := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
	draw_string(font, center - Vector2(ss.x * 0.5, -ss.y * 0.25), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _title(s: String, center: Vector2, col: Color) -> void:
	var size := 64
	var ss := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
	var base := center - Vector2(ss.x * 0.5, -ss.y * 0.25)
	for o in [Vector2(0, 0), Vector2(2, 0), Vector2(-2, 0), Vector2(0, 2), Vector2(0, -2)]:
		draw_string(font, base + o, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(col.r, col.g, col.b, 0.22))
	draw_string(font, base, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


# --- HUD / screens --------------------------------------------------------- #
func _draw_hud(vp: Vector2) -> void:
	_text("SCORE  %d" % score, Vector2(22, 36), 22, COL_BULLET)
	if combo > 1:
		_text("x%.1f  COMBO" % _mult(), Vector2(24, 60), 17, Color(1.0, 0.55, 0.9))

	var hi := "BEST  %d" % maxi(high_score, score)
	var hw := font.get_string_size(hi, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
	_text(hi, Vector2(vp.x - 22 - hw, 32), 18, COL_TEXT)

	var ws := "WAVE  %d" % (wave + 1)
	var ww := font.get_string_size(ws, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
	_text(ws, Vector2(vp.x * 0.5 - ww * 0.5, 32), 18, COL_WALL)

	if boss != null:
		_draw_boss_bar(vp)

	for i in lives:
		_life_icon(Vector2(28 + i * 28, vp.y - 30))

	_draw_buffs(vp)


func _draw_boss_bar(vp: Vector2) -> void:
	var w := vp.x * 0.5
	var h := 11.0
	var x := vp.x * 0.5 - w * 0.5
	var y := 56.0
	var frac := clampf(float(boss["hp"]) / float(boss["max_hp"]), 0.0, 1.0)
	draw_rect(Rect2(x, y, w, h), Color(0.3, 0.06, 0.12, 0.5))
	draw_rect(Rect2(x, y, w * frac, h), Color(1.0, 0.3, 0.4, 0.85))
	for i in 4:
		var pts := PackedVector2Array([Vector2(x, y), Vector2(x + w, y), Vector2(x + w, y + h), Vector2(x, y + h)])
		_glow_line(pts[i], pts[(i + 1) % 4], COL_BOSS, 1.0)


func _life_icon(pos: Vector2) -> void:
	var pts := PackedVector2Array([pos + Vector2(9, 0), pos + Vector2(-6, 6), pos + Vector2(-6, -6)])
	_glow_poly(pts, COL_PLAYER)


func _draw_buffs(vp: Vector2) -> void:
	var x := vp.x * 0.5 - 90.0
	var y := vp.y - 40.0
	if rapid_t > 0.0:
		_buff_chip(Vector2(x, y), _pu_letter(P_RAPID), _pu_color(P_RAPID), rapid_t / BUFF_TIME)
		x += 44.0
	if spread_t > 0.0:
		_buff_chip(Vector2(x, y), _pu_letter(P_SPREAD), _pu_color(P_SPREAD), spread_t / BUFF_TIME)
		x += 44.0
	if shield:
		_buff_chip(Vector2(x, y), _pu_letter(P_SHIELD), _pu_color(P_SHIELD), 1.0)
		x += 44.0
	# Dash readiness (bottom-right).
	var ready := dash_cd_t <= 0.0
	var dc := Color(0.3, 1.0, 0.9) if ready else Color(0.3, 0.45, 0.5)
	_text("DASH" if ready else "dash", Vector2(vp.x - 64, vp.y - 28), 14, dc)


func _buff_chip(pos: Vector2, letter: String, col: Color, frac: float) -> void:
	_glow_poly(_poly(pos + Vector2(13, 0), 13.0, 4, PI * 0.25), col)
	_text_center(letter, pos + Vector2(13, 0), 14, col)
	draw_rect(Rect2(pos.x, pos.y + 16, 26.0 * clampf(frac, 0.0, 1.0), 3.0), col)


func _draw_pause(vp: Vector2) -> void:
	_title("PAUSED", Vector2(vp.x * 0.5, vp.y * 0.42), COL_PLAYER)
	_text_center("ESC  resume      Q  quit to menu", Vector2(vp.x * 0.5, vp.y * 0.55), 20, COL_TEXT)


func _draw_menu(vp: Vector2) -> void:
	var cx := vp.x * 0.5
	_title("NEON DRIFT", Vector2(cx, vp.y * 0.24), COL_PLAYER)
	_text_center("ARENA  SURVIVAL", Vector2(cx, vp.y * 0.24 + 46), 22, COL_TEXT)

	var blink := 0.5 + 0.5 * sin(clock * 4.0)
	_text_center("Press SPACE or CLICK to start", Vector2(cx, vp.y * 0.48), 24, Color(1, 1, 1, blink))
	_text_center("WASD move   Mouse aim   Click/Space fire   Shift dash   M mute",
		Vector2(cx, vp.y * 0.56), 16, COL_TEXT)

	# Leaderboard
	_text_center("— BEST RUNS —", Vector2(cx, vp.y * 0.66), 18, COL_BULLET)
	if scores.is_empty():
		_text_center("no scores yet — go set one", Vector2(cx, vp.y * 0.66 + 28), 16, Color(0.5, 0.6, 0.8))
	else:
		for i in scores.size():
			_text_center("%d.   %d" % [i + 1, int(scores[i])], Vector2(cx, vp.y * 0.66 + 28 + i * 22), 16, COL_TEXT)

	_text("v" + VERSION, Vector2(14, vp.y - 14), 12, Color(0.4, 0.5, 0.7))


func _draw_gameover(vp: Vector2) -> void:
	var cx := vp.x * 0.5
	_title("GAME OVER", Vector2(cx, vp.y * 0.24), COL_BOSS)
	_text_center("SCORE   %d" % score, Vector2(cx, vp.y * 0.38), 30, COL_BULLET)
	if new_best:
		_text_center("NEW BEST!", Vector2(cx, vp.y * 0.45), 22, Color(1.0, 0.9, 0.4))
	elif last_rank >= 0:
		_text_center("#%d on the board" % (last_rank + 1), Vector2(cx, vp.y * 0.45), 20, COL_TEXT)

	_text_center("— BEST RUNS —", Vector2(cx, vp.y * 0.54), 18, COL_BULLET)
	for i in scores.size():
		var hl: Color = Color(1.0, 0.9, 0.4) if i == last_rank else COL_TEXT
		_text_center("%d.   %d" % [i + 1, int(scores[i])], Vector2(cx, vp.y * 0.54 + 26 + i * 22), 16, hl)

	var blink := 0.5 + 0.5 * sin(clock * 4.0)
	_text_center("Press SPACE or CLICK to play again", Vector2(cx, vp.y * 0.86), 20, Color(1, 1, 1, blink))


# ─────────────────────────────────────────────────────────────────────────
#  LEADERBOARD PERSISTENCE  (user://)
# ─────────────────────────────────────────────────────────────────────────
func _load_scores() -> void:
	scores = []
	if FileAccess.file_exists(SAVE_PATH):
		var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
		if f != null:
			while not f.eof_reached():
				var line := f.get_line().strip_edges()
				# Length guard BEFORE to_int() so an oversized/corrupt value can
				# never trigger an int64-overflow engine error; range-clamp too.
				if line.is_valid_int() and line.length() <= 12:
					var v := line.to_int()
					if v >= 0 and v < 1000000000:
						scores.append(v)
			f.close()
	scores.sort()
	scores.reverse()
	if scores.size() > 5:
		scores = scores.slice(0, 5)
	high_score = int(scores[0]) if scores.size() > 0 else 0


func _submit_score(s: int) -> void:
	scores.append(s)
	scores.sort()
	scores.reverse()
	if scores.size() > 5:
		scores = scores.slice(0, 5)
	last_rank = scores.find(s)
	high_score = int(scores[0]) if scores.size() > 0 else 0
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f != null:
		for v in scores:
			f.store_line(str(int(v)))
		f.close()


# ─────────────────────────────────────────────────────────────────────────
#  AUDIO
# ─────────────────────────────────────────────────────────────────────────
func _setup_audio() -> void:
	for sfx_name in ["shoot", "explosion", "hit", "gameover", "wave", "powerup", "dash", "shield", "bomb", "bossdie"]:
		var path := "res://sfx/%s.wav" % sfx_name
		if ResourceLoader.exists(path):
			var snd := load(path)
			if snd != null:
				_sfx[sfx_name] = snd
	for i in 20:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_voices.append(p)

	if ResourceLoader.exists("res://sfx/music.wav"):
		var ms := load("res://sfx/music.wav")
		if ms is AudioStreamWAV:
			ms.loop_mode = AudioStreamWAV.LOOP_FORWARD
			ms.loop_begin = 0
			ms.loop_end = ms.data.size() / 2     # 16-bit mono => 2 bytes/frame
		if ms != null:
			_music = AudioStreamPlayer.new()
			_music.stream = ms
			_music.volume_db = -16.0
			add_child(_music)
			# Skip playback under the headless dummy-audio driver (no output
			# anyway) so a looping stream is never left playing at force-quit.
			if DisplayServer.get_name() != "headless":
				_music.play()


func _play(sfx_name: String, vol_db: float = 0.0, pitch: float = 1.0) -> void:
	if muted or not _sfx.has(sfx_name) or _voices.is_empty():
		return
	var p: AudioStreamPlayer = _voices[_voice_i]
	_voice_i = (_voice_i + 1) % _voices.size()
	p.stream = _sfx[sfx_name]
	p.volume_db = vol_db
	p.pitch_scale = pitch
	p.play()


func _toggle_mute() -> void:
	muted = not muted
	if _music != null:
		_music.volume_db = -80.0 if muted else -16.0
