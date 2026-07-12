extends CharacterBody2D

const SPEED = 100.0
const DASH_SPEED = 250.0
const HOLD_THRESHOLD = 0.15 # Minimum hold time of 0.15s to trigger DASH

@onready var animated_sprite = $AnimatedSprite2D
@onready var sword_hitbox = $SwordHitBox/CollisionShape2D

var level = 1
var base_attack = 1.0
var base_defense = 0.0
var max_health = 5.0
var health = max_health
var is_hurt = false
var is_dead = false

var is_attacking = false
var is_dash_attacking = false
var facing_direction = Vector2.RIGHT
var hit_enemies = []
var attack_hold_timer = 0.0 # Stopwatch to track how long the attack button is held

func _ready():
	add_to_group("player")
	animated_sprite.animation_finished.connect(_on_animation_finished)

func _physics_process(delta):
	if is_dead or is_hurt:
		velocity = velocity.move_toward(Vector2.ZERO, 10.0)
		move_and_slide()
		return
		
	# ===== ATTACK LOGIC =====
	if is_attacking:
		# Calculate how long the user holds the attack button
		if Input.is_action_pressed("attack"):
			attack_hold_timer += delta
			# Converts to DASH attack if held for more than 0.15 seconds!
			if attack_hold_timer >= HOLD_THRESHOLD and not is_dash_attacking:
				is_dash_attacking = true
		
		if animated_sprite.frame >= 3:
			# We don't need to toggle hitbox disabled state from script!
			# Keep it active in the editor, we only check for overlaps during frame 3/4.
			
			# Manually check for targets hit by sword (more stable than body_entered!)
			var bodies = $SwordHitBox.get_overlapping_bodies()
			for b in bodies:
				if b != self and b.is_in_group("enemy") and b not in hit_enemies:
					hit_enemies.append(b)
					if b.has_method("take_damage"):
						var knockback = (b.global_position - global_position).normalized()
						
						# Final Damage = (Base Attack * Skill Multiplier) - Enemy Defense
						var multiplier = 1.5 if is_dash_attacking else 1.0
						var target_def = b.get("base_defense") if b.get("base_defense") != null else 0.0
						var final_damage = max(1, int((base_attack * multiplier) - target_def))
						
						b.take_damage(final_damage, knockback)
			
			if is_dash_attacking:
				velocity = facing_direction * DASH_SPEED
		else:
			if is_dash_attacking:
				velocity = velocity.move_toward(Vector2.ZERO, 20.0)
		
		# Lock movement during DASH attack
		if is_dash_attacking:
			move_and_slide()
			return
		
		# Allow normal walking during standard attack!
		var direction = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
		if direction:
			velocity = direction * SPEED
			if direction.x < 0:
				animated_sprite.flip_h = true
				facing_direction = Vector2.LEFT
				$SwordHitBox.position.x = -abs($SwordHitBox.position.x)
			elif direction.x > 0:
				animated_sprite.flip_h = false
				facing_direction = Vector2.RIGHT
				$SwordHitBox.position.x = abs($SwordHitBox.position.x)
		else:
			velocity = Vector2.ZERO
		move_and_slide()
		return
		
	# ===== ATTACK CHECK =====
	if Input.is_action_just_pressed("attack"):
		is_attacking = true
		is_dash_attacking = false
		hit_enemies.clear()
		attack_hold_timer = 0.0 # Reset stopwatch!
		animated_sprite.play("attack-sword")
		return

	# ===== NORMAL LOGIC (WALKING) =====
	var direction = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	
	if direction:
		velocity = direction * SPEED
		animated_sprite.play("walk")
		
		if direction.x < 0:
			animated_sprite.flip_h = true
			facing_direction = Vector2.LEFT
			$SwordHitBox.position.x = -abs($SwordHitBox.position.x)
		elif direction.x > 0:
			animated_sprite.flip_h = false
			facing_direction = Vector2.RIGHT
			$SwordHitBox.position.x = abs($SwordHitBox.position.x)
	else:
		velocity = Vector2.ZERO
		animated_sprite.play("idle")
		
	move_and_slide()

func _on_animation_finished():
	if animated_sprite.animation == "attack-sword":
		is_attacking = false
		is_dash_attacking = false
	elif animated_sprite.animation == "hurt":
		is_hurt = false
	elif animated_sprite.animation == "death":
		# Add game over logic here later
		pass



func take_damage(amount: int, knockback_dir: Vector2 = Vector2.ZERO):
	if is_dead: return
	
	health -= amount
	is_hurt = true
	is_attacking = false
	is_dash_attacking = false
	
	animated_sprite.play("hurt")
	
	# Apply knockback force
	velocity = knockback_dir * 150.0
	
	if health <= 0:
		die()

func die():
	is_dead = true
	is_hurt = false
	is_attacking = false
	is_dash_attacking = false
	animated_sprite.play("death")
	print("PLAYER DIED!")


