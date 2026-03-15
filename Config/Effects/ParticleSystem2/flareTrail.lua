-- =============================================================================
-- flareTrail.lua -- GEP physically-grounded countermeasure flare configuration
-- =============================================================================
--
-- Parameter reference (how each maps through the shader pipeline):
--
--   ScaleBase:
--     DS formula: baseScale = 1.3 * scaleBase * (1 + ~4 * nAge^0.8 * 1.5) * 0.675
--     Birth diameter = ~0.878 * ScaleBase
--     Tail diameter  = ~6.14  * ScaleBase (average, random range [4.6 .. 7.7])
--     Real MTV smoke: 0.3-0.5 m near pellet, 2-5 m after 10-20 sec aging
--
--   Length:
--     Maximum rendered trail ribbon length behind the flare source.
--     MJU-7 burn time ~3-5 sec at decelerating speed = ~200-600 m apparent
--     trail relative to dispensing aircraft.
--
--   SegmentLength:
--     Distance between Bezier control points. Shorter = smoother ribbon curve.
--     Total segments = Length / SegmentLength.
--
--   DetailFactorMax:
--     Max particles per segment = 2^(1 + DetailFactorMax). At close range.
--     Higher values fill thinner particles to maintain visual continuity.
--
--   GlowDistFactor:
--     Billboard glow scale growth with depth: scale * (1 + factor * depth).
--     Higher = more visible glow point at long range. Compensates for
--     sub-pixel pellet size.
--
--   FlirBrightnessFactor:
--     Luminance multiplier for smoke trail in FLIR/thermal view.
--     MTV combustion products are extremely bright in 3-5 um MWIR.
--
--   Lighting:
--     Fraction of ambient+sun lighting applied to smoke particles.
--     MgF2/Al2O3 smoke is a good diffuse scatterer (high albedo).
--
-- =============================================================================

Effect = {
	{
		Type = "flareTrail",
		Texture = "smoke6_nm.dds",
		TextureGlow = "flareGlow.dds",
		GlowOnly = false,
		LODdistance = 10000,    -- m; real flare smoke visible at several km
		Length = 600,           -- m; ~3-5 sec burn at decelerating speed
		SegmentLength = 18,     -- m; ~33 segments for smooth Bezier ribbon
		ScaleBase = 0.55,       -- m; birth ~0.48 m (physical: 0.3-0.5 m)
		                        --    tail  ~3.4 m  (physical: 2-5 m)
		Lighting = 0.85,        -- high-albedo MgF2/Al2O3 smoke
		DetailFactorMax = 5.0,  -- 64 particles/segment; needed for thin particles
		GlowDistFactor = 0.0015,-- visible glow point at 10 km LOD
		DifferentGlow = false,
		FlirBrightnessFactor = 1.1, -- MTV products very bright in MWIR
	},
}

Presets = {}

-- Countermeasure flare (MJU-7A/B class)
-- Explicit preset matching base Effect for clarity.
Presets.countermeasureFlare = deepcopy(Effect)

-- Signal flare (parachute illumination round, pen flare)
-- Larger pellet, longer burn, more voluminous combustion than MTV
-- countermeasure. Smoke trail is wider, not thinner.
Presets.signalFlare = deepcopy(Effect)
Presets.signalFlare[1].LODdistance = 5000   -- m; signal flares lower altitude, shorter range
Presets.signalFlare[1].Length = 200          -- m; slow descent under parachute
Presets.signalFlare[1].SegmentLength = 20    -- m
Presets.signalFlare[1].ScaleBase = 0.65      -- m; larger charge, wider smoke column
Presets.signalFlare[1].GlowDistFactor = 0.0018

-- Tracking flare for MCLOS missiles
-- Small sustained-burn pyrotechnic; compact, tightly focused trail.
Presets.trackingFlare = deepcopy(Effect)
Presets.trackingFlare[1].LODdistance = 10000 -- m
Presets.trackingFlare[1].Length = 100         -- m; short burn duration
Presets.trackingFlare[1].SegmentLength = 10   -- m
Presets.trackingFlare[1].ScaleBase = 0.35     -- m; small charge, thin trail
Presets.trackingFlare[1].GlowDistFactor = 0.0018

-- Tracking flare stage 2
-- Larger charge, more vigorous burn than stage 1.
Presets.trackingFlare2 = deepcopy(Effect)
Presets.trackingFlare2[1].LODdistance = 10000 -- m
Presets.trackingFlare2[1].Length = 300         -- m
Presets.trackingFlare2[1].SegmentLength = 30   -- m
Presets.trackingFlare2[1].ScaleBase = 0.70     -- m; wider than stage 1
Presets.trackingFlare2[1].GlowDistFactor = 0.0018

-- Rapier tracking flare trail
-- Very small sustainer. GlowOnly = true, so ScaleBase only affects
-- the glow billboard, not a smoke ribbon.
Presets.rapierFlareTrail = deepcopy(Effect)
Presets.rapierFlareTrail[1].LODdistance = 10000
Presets.rapierFlareTrail[1].ScaleBase = 0.04 -- m; minimal glow billboard
Presets.rapierFlareTrail[1].SegmentLength = 10
Presets.rapierFlareTrail[1].Length = 50
Presets.rapierFlareTrail[1].GlowDistFactor = 0.0018
Presets.rapierFlareTrail[1].GlowOnly = true

-- Signal flare on ground
Presets.signalFlareGround = deepcopy(Effect)
Presets.signalFlareGround[1].LODdistance = 10000 -- m
Presets.signalFlareGround[1].GlowOnly = true
Presets.signalFlareGround[1].GlowDistFactor = 0.0018

-- Different glow variant
Presets.differentGlow = deepcopy(Effect)
Presets.differentGlow[1].LODdistance = 10000 -- m
Presets.differentGlow[1].DifferentGlow = true
