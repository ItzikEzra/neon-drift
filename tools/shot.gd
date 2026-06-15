extends SceneTree
## Dev-only screenshot tool (not shipped in the .pck — excluded via export_presets).
## Drives the game through menu / action / boss / game-over and saves PNGs.
##   Godot --path . --script tools/shot.gd

var main
var f := 0
const DT := 1.0 / 60.0

func _initialize() -> void:
	var d := DirAccess.open("res://")
	if d and not d.dir_exists("screenshots"):
		d.make_dir("screenshots")
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	main.set_process(false)            # driven manually for determinism

func _process(_delta: float) -> bool:
	f += 1
	_drive(f)
	main._process(DT)

	if f == 26:
		_grab("01_menu")
	elif f == 110:
		_grab("02_play")
	elif f == 200:
		_grab("03_boss")
	elif f == 230:
		_grab("04_gameover")
	elif f >= 236:
		if is_instance_valid(main):
			main.free()
		return true
	return false

func _drive(fr: int) -> void:
	if fr == 2:
		# Populate the leaderboard AFTER the node's _ready/_load_scores has run.
		main.scores = [5000, 4100, 3000, 1500, 800]
		main.high_score = 5000

	if fr == 28:
		main.state = 1                 # PLAY
		main._reset_game()
		main.state = 1
		main.time_alive = 44.0
		main.score = 6200
		var vp: Vector2 = main._vp()
		for i in 14:
			main._spawn_enemy(vp)

	if fr >= 30 and main.state == 1:
		# Keep the showcase alive, the player clean (full opacity), buffs lit.
		main.lives = 3
		main.invuln = 0.0
		main.combo = maxi(main.combo, 22)
		main.combo_timer = 3.0
		main.rapid_t = maxf(main.rapid_t, 2.0)
		main.shield = true
		_cull_near(118.0)

		if fr == 150:                  # bring on the boss for the boss shot
			main._spawn_boss(main._vp())
		if main.boss != null:
			var to: Vector2 = main.boss["pos"] - main.player_pos
			main.aim = to.normalized() if to.length() > 0.1 else Vector2.RIGHT
			main.boss["hp"] = int(float(main.boss["max_hp"]) * 0.62)   # partial health bar
			if fr % 9 == 0:
				main._boss_aim()
			if fr % 15 == 0:
				main._boss_radial(fr > 175)
		else:
			main.aim = Vector2(cos(fr * 0.3), sin(fr * 0.3))
		main._fire(true)               # spread fire

	if fr == 96 or fr == 100 or fr == 104:
		# A few power-ups floating near the player for the action shot.
		var a := randf() * TAU
		main._spawn_powerup(main.player_pos + Vector2(cos(a), sin(a)) * 110.0)

	if fr == 218:
		main.lives = 1
		main.invuln = 0.0
		main.score = 6200
		main._game_over()

func _cull_near(d: float) -> void:
	# Remove threats hugging the player so the hero stays clean & un-blinking.
	for i in range(main.enemies.size() - 1, -1, -1):
		if main.player_pos.distance_to(main.enemies[i]["pos"]) < d:
			main.enemies.remove_at(i)
	for i in range(main.enemy_bullets.size() - 1, -1, -1):
		if main.player_pos.distance_to(main.enemy_bullets[i]["pos"]) < d * 0.6:
			main.enemy_bullets.remove_at(i)

func _grab(name: String) -> void:
	var tex := root.get_texture()
	if tex == null:
		print("WARN: no viewport texture for ", name)
		return
	var img := tex.get_image()
	if img == null:
		print("WARN: no image for ", name)
		return
	img.save_png("res://screenshots/%s.png" % name)
	print("saved screenshots/", name, ".png")
