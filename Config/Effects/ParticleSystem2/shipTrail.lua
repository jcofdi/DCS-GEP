Effect = {

	{
		Type = "kelvinWakePattern",	-- Kelvin Wake Pattern
		Target = "bowwave",
		Texture = "kelvinWakePattern_Fr_1_w13.dds",
		LODdistance = 10000,
		Slices = 10,
		WaveTexCount = 13,	-- count of traverse waves in texture
	},
	{
		Type = "shipFoam",
		Target = "bowwave",
		Texture = "ship_foam.png",
		LODdistance = 10000,
		Slices = 10,
		TrailLength = 400, 	-- length of foam trail
		ShipTexLength = 0.228, 	-- length of ship in texture coords
	},

	-- particles
	{
		--kuznetsov = 28
		--moscow = 14.5
		Type = "shipTrailFoam",
		Target = "refraction|FLIR",
		Pass = "DecalForward",

		Texture = "foam2.png",
		TextureFoam = "foam_03.dds",
		ParticlesLimit = 600,
		LODdistance = 10000,
		
		Width = 25, -- meters
		ScaleBase = 35.0, --  meters
		
		DistMax = {
			{0, 4.5},
			{15, 4.5},
			{25, 7.5},
		},
		-- Froude-motivated onset: minimal wake below ~6kt, rapid formation
		-- around hull speed, realistic length at operational speeds.
		-- Real foam wakes persist 2-5 minutes; at 15 m/s that is 1800-4500m.
		TrailLength = {
			{0, 0},
    		{3, 50},       -- below ~6kt: harbor maneuvering, minimal wake
    		{8, 800},      -- ~15kt: approaching hull speed, rapid onset
    		{15, 2500},    -- ~30kt: operational speed, realistic foam length
    		{25, 4000},    -- ~48kt: flank speed (few ships reach this)
		},
	},
	{
		Type = "shipTrail",

		Texture = "wave.dds",
		TextureFoam = "foam.png",
		Slices = 40,
		Length = 53.57, -- percent of ship width
		Width = 1.965, -- percent of ship width
		LODdistance = 10000,
	},
	{
		Type = "shipBow",
		Target = "main",

		Texture = "foam2.png",
		TextureFoam = "foam_03.dds",
		LODdistance = 10000,
		ParticlesLimit = 400,

		ScaleBase = 7.0,
		
		DistMax = {
			{0, 0.1},
			{50, 0.1},
		},

		LifeTime = {
			{0, 0.0},
			{20, 2.4},
			{50, 2.2},
		}
	}

}

Presets = {

	ArleighBurke = {
		{
			Type = "shipWake",
			Target = "bowwave|FLIR",
--			Target = "FLIR",
			Texture = "shipWake_ArleighBurke_12mps_20f.dds",
			ShipTexSize = {0.027, 0.6226, 0.2988}, 	-- bow, stern, width in texture coords
			ShipSize = {150, 18},					-- footage calculated for ship {length, width} m
			ShipSpeed = 12,							-- footage calculated for ship speed m/s
			FrameRate = 15,
			FrameCount = 20,
			Slices = 5,
			DisplaceMult = 1.5,
			LODdistance = 50000,
		},

		{
			Type = "kelvinWakePattern",	-- Kelvin Wake Pattern
			Target = "bowwave",
			Texture = "kelvinWakePattern_Fr_1_w13.dds",
			Slices = 10,
			WaveTexCount = 13,	-- count of traverse waves in texture
			LODdistance = 50000,
		},

		--- particles
		{
			Type = "shipTrailFoam",
			Target = "bowwave|FLIR",

			Texture = "foam2.png",
			TextureFoam = "foam_03.dds",
			ParticlesLimit = 600,
			LODdistance = 50000,

			Width = 25, -- meters
			ScaleBase = 90.0, --  meters
		
			DistMax = {
				{0, 4.5},
				{8, 4.5},
				{15, 5.5},
				{25, 8.0},
			},
			TrailLength = {
				{0, 0},
				{3, 50},       -- harbor creep
				{8, 900},      -- hull speed transition
				{15, 3000},    -- operational cruise
				{25, 4500},    -- flank
			}
		},

		{
			Type = "shipBow",
			Target = "main",

			Texture = "foam2.png",
			TextureFoam = "foam_03.dds",
			ParticlesLimit = 400,
			LODdistance = 50000,

			SpeedMultiplier = 0.6,
			ScaleBase = 15.0,
		
			DistMax = {
				{0, 0.1},
				{50, 0.1},
			},

			LifeTime = {
				{0, 0.0},
				{20, 2.4},
				{50, 2.2},
			}
		}
	},

	Nimitz = {
		{
			Type = "shipWake",
			Target = "bowwave|FLIR",
			Texture = "shipWake_Nimitz_12mps_20f.dds",
			LODdistance = 50000,
			ShipTexSize = {0.009, 0.6685, 0.34375}, 	-- bow, stern, width in texture coords
			ShipSize = {316, 42},					-- footage calculated for ship {length, width} m
			ShipSpeed = 12,							-- footage calculated for ship speed m/s
			FrameRate = 15,
			FrameCount = 20,
			Slices = 5,
			DisplaceMult = 1.25,
		},

		{
			Type = "kelvinWakePattern",	-- Kelvin Wake Pattern
			Target = "bowwave",
			Texture = "kelvinWakePattern_Fr_1_w13.dds",
			LODdistance = 50000,
			Slices = 10,
			WaveTexCount = 13,	-- count of traverse waves in texture
		},

		--- particles
		{
			Type = "shipTrailFoam",
			Target = "bowwave|FLIR",

			Texture = "foam2.png",
			TextureFoam = "foam_03.dds",
			ParticlesLimit = 600,
			LODdistance = 50000,
		
			Width = 35, -- meters
			ScaleBase = 70.0, --  meters
		
			DistMax = {
				{0, 4.5},
				{8, 4.5},
				{15, 6.5},
				{25, 9.0},
			},
			TrailLength = {
				{0, 0},
				{3, 80},       -- minimal harbor wake
				{8, 1000},     -- hull speed onset
				{15, 3500},    -- operational speed
				{25, 5000},    -- flank speed
			}
		},

		{
			Type = "shipBow",
			Target = "main",

			Texture = "foam2.png",
			TextureFoam = "foam_03.dds",

			LODdistance = 50000,
			ParticlesLimit = 400,

			SpeedMultiplier = 0.8,
			ScaleBase = 15.0,
		
			DistMax = {
				{0, 0.1},
				{50, 0.1},
			},

			LifeTime = {
				{0, 0.0},
				{20, 2.4},
				{50, 2.2},
			}
		}
	},
	
	
	NimitzReverse = {
		--- particles
		{
			Type = "shipTrailFoam",
			Target = "bowwave|FLIR",

			Texture = "foam2.png",
			TextureFoam = "foam_03.dds",
			ParticlesLimit = 600,
			LODdistance = 50000,
		
			Width = 35, -- meters
			ScaleBase = 70.0, --  meters
		
			DistMax = {
				{0, 4.5},
				{50, 4.5},
			},
			TrailLength = {
				{0, 0},
				{50, 2500},
			}
		}
	},

	Kilo636 = {
		{
			Type = "shipWake",
			Target = "bowwave|FLIR",
			Texture = "shipWake_Kilo636_9mps_20f.dds",
			LODdistance = 50000,
			ShipTexSize = {0.015, 0.5566, 0.156146}, 	-- bow, stern, width in texture coords
			ShipSize = {64, 10},					-- footage calculated for ship {length, width} m
			ShipSpeed = 9,							-- footage calculated for ship speed m/s
			FrameRate = 15,
			FrameCount = 20,
			Slices = 5,
		},

		{
			Type = "kelvinWakePattern",	-- Kelvin Wake Pattern
			Target = "bowwave",
			Texture = "kelvinWakePattern_Fr_1_w13.dds",
			LODdistance = 50000,
			Slices = 10,
			WaveTexCount = 13,	-- count of traverse waves in texture
		},

		--- particles
		{
			Type = "shipTrailFoam",
			Target = "bowwave|FLIR",

			Texture = "foam2.png",
			TextureFoam = "foam_03.dds",
			LODdistance = 50000,
			ParticlesLimit = 600,
		
			Width = 25, -- meters
			ScaleBase = 65.0, --  meters
		
			DistMax = {
				{0, 4.5},
				{10, 4.5},
				{18, 5.5},
			},
			TrailLength = {
				{0, 0},
				{2, 30},       -- very low speed
				{5, 500},      -- hull speed onset (earlier for short hull)
				{10, 1800},    -- operational speed
				{18, 3000},    -- max surface speed
			}
		}
	},

	Molniya = {
		{
			Type = "shipWake",
			Target = "bowwave|FLIR",
			Texture = "shipWake_Molniya_12mps_20f.dds",
			LODdistance = 50000,
			ShipTexSize = {0.0453, 0.4371, 0.2402}, 	-- bow, stern, width in texture coords
			ShipSize = {50, 10},					-- footage calculated for ship {length, width} m
			ShipSpeed = 12,							-- footage calculated for ship speed m/s
			FrameRate = 15,
			FrameCount = 20,
			Slices = 5,
			DisplaceMult = 1.0,
		},

		{
			Type = "kelvinWakePattern",	-- Kelvin Wake Pattern
			Target = "bowwave",
			Texture = "kelvinWakePattern_Fr_1_w13.dds",
			LODdistance = 50000,
			Slices = 10,
			WaveTexCount = 13,	-- count of traverse waves in texture
		},

		--- particles
		{
			Type = "shipTrailFoam",
			Target = "bowwave|FLIR",

			Texture = "foam2.png",
			TextureFoam = "foam_03.dds",
			LODdistance = 50000,
			ParticlesLimit = 600,
		
			Width = 25, -- meters
			ScaleBase = 90.0, --  meters
		
			DistMax = {
				{0, 4.5},
				{15, 4.5},
				{25, 6.5},
			},
			TrailLength = {
				{0, 0},
				{2, 40},       -- very early onset for short hull
				{6, 700},
				{15, 2500},
				{25, 3500},
			}
		},

		{
			Type = "shipBow",
			Target = "main",

			Texture = "foam2.png",
			TextureFoam = "foam_03.dds",
			LODdistance = 50000,
			ParticlesLimit = 400,

			SpeedMultiplier = 1.0,
			ScaleBase = 15.0,
		
			DistMax = {
				{0, 0.1},
				{50, 0.1},
			},

			LifeTime = {
				{0, 0.0},
				{20, 2.4},
				{50, 2.2},
			}
		}
	},

	HandyWind = {
		{
			Type = "shipWake",
			Target = "bowwave|FLIR",
			Texture = "shipWake_HandyWind_8mps_20f.dds",
			LODdistance = 50000,
			ShipTexSize = {0.05263, 0.7238, 0.3379}, 	-- bow, stern, width in texture coords
			ShipSize = {180, 24},					-- footage calculated for ship {length, width} m
			ShipSpeed = 8,							-- footage calculated for ship speed m/s
			FrameRate = 15,
			FrameCount = 20,
			Slices = 5,
		},

		{
			Type = "kelvinWakePattern",	-- Kelvin Wake Pattern
			Target = "bowwave",
			Texture = "kelvinWakePattern_Fr_1_w13.dds",
			LODdistance = 50000,
			Slices = 10,
			WaveTexCount = 13,	-- count of traverse waves in texture
		},

		--- particles
		{
			Type = "shipTrailFoam",
			Target = "bowwave|FLIR",

			Texture = "foam2.png",
			TextureFoam = "foam_03.dds",
			ParticlesLimit = 600,
			LODdistance = 50000,
		
			Width = 7, -- meters
			ScaleBase = 37.0, --  meters
		
			DistMax = {
				{0, 4.5},
				{12, 4.5},
				{20, 6.5},
			},
			TrailLength = {
				{0, 0},
				{3, 40},
				{8, 700},
				{12, 2000},
				{20, 3500},
			}
		},

	},

	SeawiseGiant = {
		{
			Type = "shipWake",
			Target = "bowwave|FLIR",
			Texture = "shipWake_SeawiseGiant_8mps_20f.dds",
			LODdistance = 50000,
			ShipTexSize = {0.036, 0.801, 0.4609}, 	-- bow, stern, width in texture coords
			ShipSize = {446, 69},					-- footage calculated for ship {length, width} m
			ShipSpeed = 8,							-- footage calculated for ship speed m/s
			FrameRate = 15,
			FrameCount = 20,
			Slices = 3,
		},

		{
			Type = "kelvinWakePattern",	-- Kelvin Wake Pattern
			Target = "bowwave",
			Texture = "kelvinWakePattern_Fr_1_w13.dds",
			LODdistance = 50000,
			Slices = 10,
			WaveTexCount = 13,	-- count of traverse waves in texture
		},

		--- particles
		{
			Type = "shipTrailFoam",
			Target = "bowwave|FLIR",

			Texture = "foam2.png",
			TextureFoam = "foam_03.dds",
			ParticlesLimit = 600,
			LODdistance = 50000,
		
			Width = 45, -- meters
			ScaleBase = 120.0, --  meters
		
			DistMax = {
				{0, 4.5},
				{10, 4.5},
				{16, 6.5},
			},
			TrailLength = {
				{0, 0},
				{3, 60},
				{6, 500},      -- onset delayed by long hull
				{10, 1800},
				{16, 3500},
			}
		},

	},

	groundVehicle = {
		--- particles
		{
			Type = "shipTrailFoam",
			Target = "bowwave|FLIR",

			Texture = "foam2.png",
			TextureFoam = "foam_03.dds",
			ParticlesLimit = 200,
			LODdistance = 1000,
		
			Width = 0.5, -- meters
			ScaleBase = 5.0, --  meters
		
			DistMax = {
				{0, 0.5},
				{5, 0.5},
			},
			TrailLength = {
				{0, 0},
				{2, 25},
			}
		}
	},
	
	groundVehicle2 = 
	{
		{
			Type = "shipFoam",
			Target = "bowwave",
			Texture = "ship_foam.png",
			LODdistance = 1000,
			Slices = 10,
			TrailLength = 40, 	-- length of foam trail
			ShipTexLength = 1.0, 	-- length of ship in texture coords
		}
	},

}

updateTimeMin = 0.015
updateTimeMax = 0.15
updateDistMin = 500
updateDistMax = 4000
