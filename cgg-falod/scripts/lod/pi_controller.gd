extends RefCounted
## Bounded proportional-integral controller that turns "the renderer is slower than the target" into a single
## LOD bias. Pure arithmetic with no engine access, so it is tested with synthetic timings (adaptive_selftest.gd).
##
## Sign convention (shared by every policy): bias > 0 means COARSER detail, bias < 0 finer, 0 = the baseline
## distance thresholds. Policies see an effective distance of `distance * (1 + bias)`, so a bias of 1 halves every
## threshold in metres. Bias is dimensionless.
##
##   error     e = (signal - target) / target            relative, > 0 when the frame is too slow
##   e_eff     = e shrunk toward 0 by `deadband`          (0 inside the dead band)
##   P         = kp * e_eff
##   I        += ki * e_eff * dt                          only if the output is not already saturated in that direction
##   wanted    = clamp(P + I, bias_min, bias_max)
##   bias      = clamp(wanted, bias - max_fall, bias + max_rise)       per update (rate limit)
##
## Anti-windup: I is clamped to [bias_min, bias_max] and frozen while the output is saturated in the direction
## of the error; when the rate limit holds the output back, I is pulled back to (bias - P) so it never runs ahead
## of the bias that was actually applied. max_fall < max_rise on purpose: coarsen quickly under sustained pressure,
## recover detail slowly.
##
## Units: kp [bias per unit relative error], ki [bias per (unit relative error * second)], dt in seconds,
## max_rise / max_fall [bias per update], deadband [relative error].

var kp: float = 0.6
var ki: float = 0.4
## Finest and coarsest permitted bias. 0 as the minimum means "never finer than the baseline distances".
var bias_min: float = 0.0
var bias_max: float = 2.0
var max_rise: float = 0.10
var max_fall: float = 0.03
var deadband: float = 0.03

var bias: float = 0.0
var integral: float = 0.0
var p_term: float = 0.0
var error: float = 0.0
## -1 = at bias_min, +1 = at bias_max, 0 = free.
var saturation: int = 0
var updates: int = 0


func reset(initial_bias: float = 0.0) -> void:
	bias = clampf(initial_bias, bias_min, bias_max)
	integral = bias
	p_term = 0.0
	error = 0.0
	saturation = 0
	updates = 0


## One controller step. `signal_ms` and `target_ms` use the same unit; `dt` is the time since the last step.
## Returns the new bias.
func update(signal_ms: float, target_ms: float, dt: float) -> float:
	updates += 1
	error = (signal_ms - target_ms) / maxf(target_ms, 0.001)
	var e := 0.0
	if absf(error) > deadband:
		e = error - signf(error) * deadband
	p_term = kp * e
	var unsaturated := p_term + integral
	var integrate := not ((unsaturated >= bias_max and e > 0.0) or (unsaturated <= bias_min and e < 0.0))
	if integrate:
		integral = clampf(integral + ki * e * dt, bias_min, bias_max)
	var wanted := clampf(p_term + integral, bias_min, bias_max)
	var applied := clampf(wanted, bias - max_fall, bias + max_rise)
	if applied != wanted:
		integral = clampf(applied - p_term, bias_min, bias_max)
	bias = clampf(applied, bias_min, bias_max)
	saturation = 1 if bias >= bias_max else (-1 if bias <= bias_min else 0)
	return bias


func describe() -> Dictionary:
	return {
		"kp": kp, "ki": ki, "bias_min": bias_min, "bias_max": bias_max, "max_rise_per_update": max_rise,
		"max_fall_per_update": max_fall, "deadband": deadband,
		"equations": "e=(signal-target)/target; P=kp*e_eff; I+=ki*e_eff*dt (anti-windup); bias=clamp(P+I) rate-limited per update; bias>0 = coarser",
	}
