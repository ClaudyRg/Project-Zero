extends CharacterBody2D

const SPEED = 25.0
const ATTACK_RANGE = 40.0
const DETECTION_RANGE = 150.0
const ATTACK_COOLDOWN = 2.0

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

func _ready():
	add_to_group("enemy")
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

func _physics_process(delta):
	if is_dead or is_hurt:
		# Apply friction during knockback
		velocity = velocity.move_toward(Vector2.ZERO, 10.0)
		move_and_slide()
		return
		
	if attack_timer > 0:
		attack_timer -= delta
		
	if is_attacking:
		# Deals damage on frame 2 to avoid instantaneous hits! Adjust frame if needed.
		if animated_sprite.frame == 2 and not has_hit:
			has_hit = true
			if has_node("attack"):
				var bodies = $attack.get_overlapping_bodies()
				for b in bodies:
					if (b.is_in_group("player") or b.is_in_group("companion")) and b.has_method("take_damage"):
						var knockback = (b.global_position - global_position).normalized()
						var target_def = b.get("base_defense") if b.get("base_defense") != null else 0.0
						var final_damage = max(1, int((base_attack * 1.0) - target_def))
						b.take_damage(final_damage, knockback)
						break
					
		velocity = Vector2.ZERO
		apply_separation()
		move_and_slide()
		return
		
	find_nearest_target()
	
	if current_target:
		var distance_to_target = global_position.distance_to(current_target.global_position)
		
		if distance_to_target > DETECTION_RANGE:
			velocity = Vector2.ZERO
			animated_sprite.play("idle")
			apply_separation()
			move_and_slide()
			return
			
		var direction = (current_target.global_position - global_position).normalized()
		
		if direction.x < 0:
			animated_sprite.flip_h = true
			if has_node("attack"): $attack.scale.x = -1
		elif direction.x > 0:
			animated_sprite.flip_h = false
			if has_node("attack"): $attack.scale.x = 1
			
		var target_in_range = false
		if has_node("attack"):
			var bodies = $attack.get_overlapping_bodies()
			if current_target in bodies:
				target_in_range = true
			
		if target_in_range and attack_timer <= 0:
			is_attacking = true
			has_hit = false
			animated_sprite.play("attack1")
			attack_timer = ATTACK_COOLDOWN
			velocity = Vector2.ZERO
		elif not target_in_range:
			velocity = direction * SPEED
			animated_sprite.play("walk")
		else:
			velocity = Vector2.ZERO
			animated_sprite.play("idle")
	else:
		velocity = Vector2.ZERO
		animated_sprite.play("idle")
			
	apply_separation()
	move_and_slide()

func take_damage(amount: int, knockback_dir: Vector2 = Vector2.ZERO):
	if is_dead: return
	
	health -= amount
	is_hurt = true
	is_attacking = false
	animated_sprite.play("hurt")
	
	# Apply knockback force
	velocity = knockback_dir * 100.0
	
	if health <= 0:
		die()

func die():
	is_dead = true
	is_hurt = false
	is_attacking = false
	animated_sprite.play("death")
	# Collision disabled on death
	$CollisionShape2D.set_deferred("disabled", true)

func _on_animation_finished():
	if animated_sprite.animation == "hurt":
		is_hurt = false
	elif animated_sprite.animation == "attack1": # Changed to attack1
		is_attacking = false
	elif animated_sprite.animation == "death":
		# Remove slime from scene after death animation finishes
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
