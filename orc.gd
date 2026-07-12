extends CharacterBody2D

const SPEED = 40.0
const ATTACK_RANGE = 35.0 # Increased slightly to match the new axe size
const DETECTION_RANGE = 180.0
const ATTACK_COOLDOWN = 1.5

@onready var animated_sprite = $AnimatedSprite2D

var level = 1
var base_attack = 1.0
var base_defense = 0.0
var max_health = 3.0
var health = max_health

var current_target = null
var is_dead = false
var is_hurt = false
var is_attacking = false
var attack_timer = 0.0
var has_hit = false
var invincibility_timer = 0.0

# Smart AI Variables
var is_aggro = false
var aggro_timer = 0.0
const AGGRO_DURATION = 5.0 # Memory timer: how long Orc remembers target after losing LOS
var nav_agent: NavigationAgent2D
var los_raycast: RayCast2D

# Patrol Variables
var spawn_position = Vector2.ZERO
var patrol_timer = 0.0
var is_patrolling = false

func _ready():
	add_to_group("enemy")
	spawn_position = global_position # Set initial patrol center
	animated_sprite.animation_finished.connect(_on_animation_finished)
	
	# Ignore collision with other enemies so they can stack/pass through each other
	for other_enemy in get_tree().get_nodes_in_group("enemy"):
		if other_enemy != self:
			add_collision_exception_with(other_enemy)
			if other_enemy.has_method("add_collision_exception_with"):
				other_enemy.add_collision_exception_with(self)
				
	# Ignore collision with player and companion permanently
	for p in get_tree().get_nodes_in_group("player"):
		add_collision_exception_with(p)
		if p.has_method("add_collision_exception_with"):
			p.add_collision_exception_with(self)
			
	for c in get_tree().get_nodes_in_group("companion"):
		add_collision_exception_with(c)
		if c.has_method("add_collision_exception_with"):
			c.add_collision_exception_with(self)

	# --- SMART AI SETUP ---
	# Dynamically add NavigationAgent2D if it doesn't exist
	nav_agent = get_node_or_null("NavigationAgent2D")
	if not nav_agent:
		nav_agent = NavigationAgent2D.new()
		nav_agent.name = "NavigationAgent2D"
		nav_agent.radius = 12.0
		add_child(nav_agent)
		
	# Dynamically add RayCast2D (Line of Sight) if it doesn't exist
	los_raycast = get_node_or_null("RayCast2D")
	if not los_raycast:
		los_raycast = RayCast2D.new()
		los_raycast.name = "RayCast2D"
		los_raycast.add_exception(self) # Don't hit yourself
		for other in get_tree().get_nodes_in_group("enemy"):
			los_raycast.add_exception(other) # Enemies don't block each other's sight
		add_child(los_raycast)

func _physics_process(delta):
	if is_dead or is_hurt:
		# Apply friction during knockback
		velocity = velocity.move_toward(Vector2.ZERO, 10.0)
		move_and_slide()
		
		# Still decrease invincibility timer even when hurt
		if invincibility_timer > 0:
			invincibility_timer -= delta
		return
		
	if invincibility_timer > 0:
		invincibility_timer -= delta
		
	if attack_timer > 0:
		attack_timer -= delta
		
	if is_attacking:
		# Orc deals damage on frame 2 to avoid instantaneous hits!
		if animated_sprite.frame == 2 and not has_hit:
			has_hit = true
			if has_node("Axe"):
				var bodies = $Axe.get_overlapping_bodies()
				for b in bodies:
					if b.is_in_group("player") and b.has_method("take_damage"):
						var knockback = (b.global_position - global_position).normalized()
						var target_def = b.get("base_defense") if b.get("base_defense") != null else 0.0
						var final_damage = max(1, int((base_attack * 1.0) - target_def))
						b.take_damage(final_damage, knockback)
						break
			else:
				if current_target and global_position.distance_to(current_target.global_position) <= ATTACK_RANGE + 10.0:
					if current_target.has_method("take_damage"):
						var knockback = (current_target.global_position - global_position).normalized()
						var target_def = current_target.get("base_defense") if current_target.get("base_defense") != null else 0.0
						var final_damage = max(1, int((base_attack * 1.0) - target_def))
						current_target.take_damage(final_damage, knockback)
					
		velocity = Vector2.ZERO
		apply_separation()
		move_and_slide()
		return
		
	find_nearest_target()
	
	if current_target:
		var distance_to_target = global_position.distance_to(current_target.global_position)
		
		# 1. Check Line of Sight (LOS)
		if distance_to_target <= DETECTION_RANGE and los_raycast:
			los_raycast.target_position = current_target.global_position - global_position
			los_raycast.force_raycast_update()
			
			var collider = los_raycast.get_collider()
			if los_raycast.is_colliding() and collider == current_target:
				# We have Line of Sight! Trigger Aggro and reset memory timer
				is_aggro = true
				aggro_timer = AGGRO_DURATION
				
		# 2. Aggro Timer (Memory)
		if aggro_timer > 0:
			aggro_timer -= delta
		else:
			is_aggro = false # Lost target completely
			
		# 3. Chase/Attack Logic (Only if Aggro)
		if is_aggro:
			var direction = Vector2.ZERO
			
			# Use Pathfinding to go around obstacles
			if nav_agent:
				nav_agent.target_position = current_target.global_position
				if not nav_agent.is_navigation_finished():
					var next_path_pos = nav_agent.get_next_path_position()
					direction = global_position.direction_to(next_path_pos)
			else:
				# Fallback if no navmesh
				direction = (current_target.global_position - global_position).normalized()
				
			if direction.x < 0:
				animated_sprite.flip_h = true
				if has_node("Axe"): $Axe.scale.x = -1
			elif direction.x > 0:
				animated_sprite.flip_h = false
				if has_node("Axe"): $Axe.scale.x = 1
				
			var target_in_range = false
			if has_node("Axe"):
				var bodies = $Axe.get_overlapping_bodies()
				if current_target in bodies:
					target_in_range = true
			
			if target_in_range and attack_timer <= 0:
				is_attacking = true
				has_hit = false
				animated_sprite.play("attack")
				attack_timer = ATTACK_COOLDOWN
				velocity = Vector2.ZERO
			elif not target_in_range:
				velocity = direction * SPEED
				animated_sprite.play("idle")
			else:
				velocity = Vector2.ZERO
				animated_sprite.play("idle")
		else:
			# Not Aggro (Lost LOS and memory timer ran out)
			_handle_patrol(delta)
	else:
		# No target in map
		_handle_patrol(delta)
			
	apply_separation()
	move_and_slide()

func _handle_patrol(delta):
	# Stop attacking
	is_attacking = false
	
	if not is_patrolling:
		velocity = velocity.move_toward(Vector2.ZERO, 15.0)
		animated_sprite.play("idle")
		patrol_timer -= delta
		if patrol_timer <= 0:
			# Start a new patrol
			is_patrolling = true
			var random_offset = Vector2(randf_range(-120, 120), randf_range(-120, 120))
			if nav_agent:
				nav_agent.target_position = spawn_position + random_offset
	else:
		# Move to patrol destination
		if nav_agent and not nav_agent.is_navigation_finished():
			var next_path_pos = nav_agent.get_next_path_position()
			var direction = global_position.direction_to(next_path_pos)
			velocity = direction * (SPEED * 0.55) # Walk slowly while patrolling (55% speed)
			animated_sprite.play("idle") # Keep using idle animation for movement since Orc doesn't have a walk animation
			
			if direction.x < 0:
				animated_sprite.flip_h = true
				if has_node("Axe"): $Axe.scale.x = -1
			elif direction.x > 0:
				animated_sprite.flip_h = false
				if has_node("Axe"): $Axe.scale.x = 1
		else:
			# Reached patrol destination (or stuck)
			is_patrolling = false
			patrol_timer = randf_range(2.0, 5.0) # Rest for 2-5 seconds before next patrol
			velocity = Vector2.ZERO

func take_damage(amount: int, knockback_dir: Vector2 = Vector2.ZERO):
	# Don't take damage if already dead or currently invincible (I-Frames)
	if is_dead or invincibility_timer > 0: return
	
	health -= amount
	is_hurt = true
	is_attacking = false
	
	# Give the Orc 0.6 seconds of invincibility so Clara can't stunlock it
	invincibility_timer = 0.6 
	
	# Reset attack timer so the Orc can counter-attack immediately after recovering
	attack_timer = 0.0 
	
	animated_sprite.play("hurt")
	
	# Apply knockback force
	velocity = knockback_dir * 150.0
	
	if health <= 0:
		die()

func die():
	is_dead = true
	is_hurt = false
	is_attacking = false
	animated_sprite.play("death")

func _on_animation_finished():
	if animated_sprite.animation == "hurt":
		is_hurt = false
	elif animated_sprite.animation == "attack":
		is_attacking = false
	elif animated_sprite.animation == "death":
		# Remove orc from scene after death animation finishes
		queue_free()

func apply_separation():
	var separation = Vector2.ZERO
	for other in get_tree().get_nodes_in_group("enemy"):
		if other != self and is_instance_valid(other) and not other.get("is_dead"):
			var dist = global_position.distance_to(other.global_position)
			if dist < 25.0 and dist > 0:
				separation += (global_position - other.global_position).normalized() * (25.0 - dist)
	
	if separation != Vector2.ZERO:
		velocity += separation * 5.0

func find_nearest_target():
	var targets = []
	targets.append_array(get_tree().get_nodes_in_group("player"))
	targets.append_array(get_tree().get_nodes_in_group("companion"))
	
	var nearest_dist = DETECTION_RANGE
	current_target = null
	
	for t in targets:
		if is_instance_valid(t) and not t.get("is_dead"):
			var dist = global_position.distance_to(t.global_position)
			if dist < nearest_dist:
				nearest_dist = dist
				current_target = t
