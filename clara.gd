extends CharacterBody2D

const SPEED = 95.0 # Slightly slower than the player for natural following
const ATTACK_RANGE = 45.0 
const AGGRO_RANGE = 180.0 # Enemy detection range
const FOLLOW_DISTANCE = 50.0 # Stopping distance when following player
const ATTACK_COOLDOWN = 1.0

@onready var animated_sprite = $AnimatedSprite2D
@onready var nav_agent = get_node_or_null("NavigationAgent2D") # A* Pathfinding fallback to prevent crashes

var level = 1
var base_attack = 1.0 # Set to 1.0 for balance (requires 3 hits to kill an orc)
var base_defense = 1.0
var max_health = 100.0
var health = max_health
var is_dead = false
var is_hurt = false
var is_attacking = false
var is_following = false # State to prevent jittering/sliding when moving
var hit_enemies = [] # Array to track hit enemies for AoE Cleave
var attack_timer = 0.0
var skill_cooldown = 0.0 # Timer for skill attack

var target_player = null
var current_enemy = null

var stuck_timer = 0.0 # Tracks how long Clara has been barely moving

func _ready():
	add_to_group("companion")
	animated_sprite.animation_finished.connect(_on_animation_finished)
	
	if nav_agent:
		# Set radius to match Clara's circular collision shape (~14px)
		# This makes the pathfinder generate paths that ALREADY avoid walls by this radius!
		nav_agent.radius = 14.0
		nav_agent.path_desired_distance = 16.0 
		nav_agent.target_desired_distance = 16.0
		# Postprocessing: Corridors = edge-centered paths that stay in the MIDDLE of tight spaces
		nav_agent.path_postprocessing = NavigationPathQueryParameters2D.PATH_POSTPROCESSING_EDGECENTERED
		
	target_player = get_tree().get_first_node_in_group("player")
	
	# Clara and Player can permanently pass through each other
	if target_player:
		add_collision_exception_with(target_player)
		if target_player.has_method("add_collision_exception_with"):
			target_player.add_collision_exception_with(self)
			
	# Allow Clara to pass through enemies while moving (for fluidity)
	for enemy in get_tree().get_nodes_in_group("enemy"):
		add_collision_exception_with(enemy)
		
	# Setup debug line for navigation
	var line = Line2D.new()
	line.name = "PathDebugLine"
	line.width = 2.0
	line.default_color = Color.RED
	line.top_level = true # Draw independently of Clara's rotation/position
	add_child(line)

func _physics_process(delta):
	# Update Debug Line
	if has_node("PathDebugLine") and nav_agent:
		var path = nav_agent.get_current_navigation_path()
		if path.size() > 0:
			$PathDebugLine.points = path
		else:
			$PathDebugLine.points = PackedVector2Array()

	if is_dead or is_hurt:
		velocity = velocity.move_toward(Vector2.ZERO, 10.0)
		move_and_slide()
		return
		
	if attack_timer > 0:
		attack_timer -= delta
	if skill_cooldown > 0:
		skill_cooldown -= delta
		
	if is_attacking:
		if animated_sprite.animation == "attack1":
			# Deal damage on frames 3 to 5 (matching the sword swing animation)
			if animated_sprite.frame >= 3 and animated_sprite.frame <= 5:
				var bodies = $SwordHitBox.get_overlapping_bodies() if has_node("SwordHitBox") else []
				for b in bodies:
					if b.is_in_group("enemy") and b not in hit_enemies:
						hit_enemies.append(b)
						if b.has_method("take_damage"):
							var knockback = (b.global_position - global_position).normalized()
							var target_def = b.get("base_defense") if b.get("base_defense") != null else 0.0
							var final_damage = max(1, int((base_attack * 1.0) - target_def))
							b.take_damage(final_damage, knockback)
		elif animated_sprite.animation == "attack2":
			# Reset hit tracker between hit phases so enemies take multi-hit damage
			if animated_sprite.frame == 5 or animated_sprite.frame == 10:
				hit_enemies.clear()
				
			var is_hitting = (animated_sprite.frame >= 3 and animated_sprite.frame <= 4) or \
							 (animated_sprite.frame >= 6 and animated_sprite.frame <= 8) or \
							 (animated_sprite.frame >= 11 and animated_sprite.frame <= 13)
			
			if is_hitting:
				var bodies = $Skill1.get_overlapping_bodies() if has_node("Skill1") else []
				for b in bodies:
					if b.is_in_group("enemy") and b not in hit_enemies:
						hit_enemies.append(b)
						if b.has_method("take_damage"):
							var knockback = (b.global_position - global_position).normalized()
							var target_def = b.get("base_defense") if b.get("base_defense") != null else 0.0
							var final_damage = max(1, int((base_attack * 1.2) - target_def)) # Skill does slightly more dmg per hit
							b.take_damage(final_damage, knockback)
						
		if animated_sprite.animation == "attack2":
			var should_move = false
			if has_node("Skill1"):
				# Check if any enemy is currently inside the skill hitbox
				var enemies_in_range = false
				var bodies = $Skill1.get_overlapping_bodies()
				for b in bodies:
					if b.is_in_group("enemy") and not b.get("is_dead"):
						enemies_in_range = true
						break
						
				# If no enemies are inside the hitbox, step forward to reach them!
				if not enemies_in_range:
					should_move = true
					
			if should_move:
				# Move forward slowly while using skill (Dash effect) to catch up
				var face_dir = Vector2.LEFT if animated_sprite.flip_h else Vector2.RIGHT
				velocity = face_dir * (SPEED * 0.8) 
			else:
				velocity = Vector2.ZERO
		else:
			velocity = Vector2.ZERO
		move_and_slide()
		return

	# --- CLARA STATE MACHINE ---
	# Ensure target_player exists (fixes _ready() load order issues)
	if not target_player:
		target_player = get_tree().get_first_node_in_group("player")
		if target_player:
			add_collision_exception_with(target_player)

	# Check distance from player (Leash Mechanic)
	var dist_to_player = 0.0
	var is_too_far = false
	if target_player:
		dist_to_player = global_position.distance_to(target_player.global_position)
		if dist_to_player > 250.0: # If player leaves her too far behind, she will panic and return
			is_too_far = true

	# 1. Find the nearest enemy
	find_nearest_enemy()
	
	# 2. COMBAT PRIORITY: Attack enemies, EXCEPT when the player is too far away
	if current_enemy and is_instance_valid(current_enemy) and not current_enemy.get("is_dead") and not is_too_far:
		var dist_to_enemy = global_position.distance_to(current_enemy.global_position)
		var direction = get_smart_nav_direction(current_enemy.global_position, delta)
		
		_flip_sprite(direction.x)
		
		var enemy_in_range = false
		if has_node("SwordHitBox"):
			var bodies = $SwordHitBox.get_overlapping_bodies()
			if current_enemy in bodies:
				enemy_in_range = true
				
		if enemy_in_range and attack_timer <= 0:
			is_attacking = true
			hit_enemies.clear() # Reset the array of hit enemies
			
			if skill_cooldown <= 0 and has_node("Skill1"):
				animated_sprite.play("attack2")
				skill_cooldown = 8.0 # Skill goes on cooldown for 8 seconds
			else:
				animated_sprite.play("attack1")
				
			attack_timer = ATTACK_COOLDOWN
			velocity = Vector2.ZERO
		elif not enemy_in_range:
			var desired_velocity = direction * SPEED
			velocity = velocity.lerp(desired_velocity, 12.0 * delta)
			animated_sprite.play("walk")
			
	# 3. If no enemies are nearby, follow the Player
	elif target_player:
		if nav_agent:
			nav_agent.target_position = target_player.global_position
			
			# Calculate true path distance instead of straight-line distance!
			# This prevents Clara from getting stuck on cliffs just because she's "close" in straight-line math.
			var path_dist = nav_agent.distance_to_target()
			
			if path_dist > 40.0:
				is_following = true
			else:
				is_following = false
				
			var dynamic_speed = SPEED
			if path_dist < 90.0:
				dynamic_speed = SPEED * ((path_dist - 30.0) / 60.0)
				dynamic_speed = clamp(dynamic_speed, 0.0, SPEED)
		else:
			if dist_to_player > 35.0:
				is_following = true
			else:
				is_following = false
			var dynamic_speed = SPEED
		if is_following:
			var direction = get_smart_nav_direction(target_player.global_position, delta)
			_flip_sprite(direction.x)
			
			# Ensure we use dynamic_speed if nav_agent is null
			var current_dyn_speed = SPEED
			if nav_agent:
				current_dyn_speed = SPEED * clamp((nav_agent.distance_to_target() - 30.0) / 60.0, 0.0, 1.0)
			
			var desired_velocity = direction * current_dyn_speed
			# Lerp the entire velocity to allow smooth wall sliding around corners
			velocity = velocity.lerp(desired_velocity, 12.0 * delta)
			
			if velocity.length() > 10.0:
				animated_sprite.play("walk")
			else:
				animated_sprite.play("idle")
		else:
			# Decelerate smoothly like soft braking, avoiding rigid robotic stops
			velocity = velocity.lerp(Vector2.ZERO, 15.0 * delta)
			if velocity.length() > 5.0:
				animated_sprite.play("walk")
			else:
				animated_sprite.play("idle")
	else:
		velocity = velocity.lerp(Vector2.ZERO, 15.0 * delta)
		animated_sprite.play("idle")
		
	move_and_slide()

# Smart pathfinding that avoids corners and breaks free from stuck positions
func get_smart_nav_direction(target_global_pos: Vector2, delta: float) -> Vector2:
	var direction = Vector2.ZERO
	
	if nav_agent:
		nav_agent.target_position = target_global_pos
		var path = nav_agent.get_current_navigation_path()
		var target_pos = nav_agent.get_next_path_position()
		
		# CORNER AVOIDANCE: Push waypoints away from wall corners
		if path.size() >= 3:
			var p0 = path[0]
			var p1 = path[1]
			var p2 = path[2]
			var dir_in = (p1 - p0).normalized()
			var dir_out = (p2 - p1).normalized()
			var push_away_vector = (dir_out - dir_in).normalized()
			
			if push_away_vector != Vector2.ZERO:
				# 32px push = wide enough clearance for Clara's circular body
				target_pos = p1 + (push_away_vector * 32.0)
		
		direction = global_position.direction_to(target_pos)
		
		# STUCK DETECTION: If Clara is barely moving but far from target, nudge her sideways
		var dist_remaining = nav_agent.distance_to_target()
		if velocity.length() < 8.0 and dist_remaining > 30.0:
			stuck_timer += delta
			if stuck_timer > 0.3:
				# Perpendicular nudge: rotate direction 90 degrees to slide off the corner
				var perp = Vector2(-direction.y, direction.x)
				direction = (direction + perp * 0.8).normalized()
		else:
			stuck_timer = 0.0
	else:
		direction = (target_global_pos - global_position).normalized()
	
	return direction

func _flip_sprite(dir_x):
	if dir_x < 0:
		animated_sprite.flip_h = true
		if has_node("SwordHitBox"): 
			$SwordHitBox.scale.x = -1
	elif dir_x > 0:
		animated_sprite.flip_h = false
		if has_node("SwordHitBox"): 
			$SwordHitBox.scale.x = 1

func find_nearest_enemy():
	current_enemy = null
	
	# Fallback if ScanArea hasn't been created yet
	if not has_node("ScanArea"):
		return
		
	# Only scan enemies that are currently overlapping our sensor sphere
	var enemies = $ScanArea.get_overlapping_bodies()
	var nearest_dist = INF 
	
	for enemy in enemies:
		if enemy.is_in_group("enemy") and is_instance_valid(enemy) and not enemy.get("is_dead"):
			var dist = global_position.distance_to(enemy.global_position)
			if dist < nearest_dist:
				nearest_dist = dist
				current_enemy = enemy

func take_damage(amount: int, knockback_dir: Vector2 = Vector2.ZERO):
	if is_dead: return
	health -= amount
	is_hurt = true
	is_attacking = false
	animated_sprite.play("hurt")
	velocity = knockback_dir * 100.0
	if health <= 0:
		die()

func die():
	is_dead = true
	is_hurt = false
	is_attacking = false
	animated_sprite.play("death")
	$CollisionShape2D.set_deferred("disabled", true)

func _on_animation_finished():
	if animated_sprite.animation == "hurt":
		is_hurt = false
	elif animated_sprite.animation == "attack1" or animated_sprite.animation == "attack2":
		is_attacking = false
