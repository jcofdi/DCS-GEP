-- =============================================================================
-- JC Opus View Distance: Terrain Distance Configuration
-- Physically-grounded: 80km atmospheric ceiling, 120km atmFarDistance
--
-- Based on Extreme/Insane with targeted improvements:
-- - mapLodDistance0-3 pushed out (stock never scales these; they're 2/4/6/8 at ALL levels)
-- - district/uniqueScene at Insane-level distances
-- - water/subforest/beach/road blend matched to Insane (80km atmo limit)
-- - land_detailNoise.Height at Insane level (1500m)
-- - noise1back/noise1top at Insane level
-- =============================================================================

distance =
{
	distance10x10 = 140000.0;          -- constant across all levels
	distanceLevel0 = 140000.0;         -- constant across all levels
	uniqueSceneFarDistance = 45000.0;   -- Low:10k High:20k Extreme:30k Insane:60k -> 45k
	smokesSceneFarDistance = 45000.0;   -- matched to uniqueScene
	minimalSquareOnScreen = 50;
	minimalSquareOnScreenFull = 100;
	
	-- These are 2/4/6/8k at EVERY stock level including Insane. ED never tuned them.
	-- Pushing these out is the single biggest lever for terrain mesh detail at altitude.
	-- These control which terrain mesh LOD ring is active at what camera distance.
	mapLodDistance0 = 3000;             -- was 2000 at all levels: +50%
	mapLodDistance1 = 6000;             -- was 4000 at all levels: +50%
	mapLodDistance2 = 10000;            -- was 6000 at all levels: +67%
	mapLodDistance3 = 14000;            -- was 8000 at all levels: +75%
	smallShitDimention = 4000;          -- same as High/Extreme/Insane
}
distanceBlend = 
{
	-- town/field: constant across all levels, keep them
	townNearDistance  = 80000.0;
	townFarDistance   = 120000.0;
	fieldNearDistance = 40000.0;
	fieldFarDistance  = 140000.0;

	-- water: match Insane (Low:20/30 High:30/40 Extreme:40/80 Insane:60/120)
	waterNearDistance = 60000.0;
	waterFarDistance  = 120000.0;

	-- lights: constant across all levels
	townLightNearDistance  = 10000.0;
	townLightFarDistance  = 20000.0;

	-- match Insane (all max out at 80k far, capped by atmosphere)
	subforest = {20000, 80000};
	beach = {30000, 80000};
	road = {30000, 80000};
}

--Old Noise 
land_noise =
{
	noisemin = 0.0;
	noisemax = 0.6;
	noise1front = 1000.0;
	-- Low:40k High:60k Extreme:80k Insane:120k -> match Insane
	noise1back = 120000.0;
	-- Low:8k High:10k Extreme:12k Insane:18k -> match Insane
	noise1top = 18000.0;
	noise1bottom = 2000.0;
	noise1PerSquare = 2.0;
	noise2PerSquare = 150.0;
}

land_detailNoise=
{
	-- Low:300 High:500 Extreme:700 Insane:1500 -> match Insane
	Height = 1500.0;
	Slope = 0.0;	
}

district =
{
	maxDistrictsAround = 100000;

	-- Low:13k High:30k Extreme:50k Insane:80k -> match Insane
	farDistance = 80000.0;
	-- Low:10k High:20k Extreme:30k Insane:60k -> match Insane
	farFullRenderDistance = 60000.0;
	-- Low:1k High:3k Extreme:5k Insane:8k -> match Insane
	nearFullRenderDistance = 8000.0;
	nearDistance = 8000.0;
	
-- These tree values seem to be obsolete (they don't do anything)
	treesFarDistance = 1500.0;
	treesFarFullBlendRenderDistance = 1200.0;
	treesFarFullRenderDistance = 1000.0;
	treeslodDistance = 600.0;
	heightFactor = 0;
	heightRandomFactor = 0;
	ajastfactor = 1;
	
	lampFarDistance = 10000;
	splineBlockFarDistance = 500.0;

--	renderType = "texture"; -- simple, texture, instance
	renderType = "simple"; -- simple, texture, instance
	
	lamp =
	{
		lampOn = 1;	
		maxSize = 8.4;
		staticSize = 4.0;
		spriteScale = 0.001;
		minDistance = 150.0;
		maxDistance = 10000.0;
		maxAlphaDistance = 400.0;
		minAlphaDistance = 0.0;
		minAlpha = 0.0;
		maxAlpha = 1.0;
		minBrightnessDistance = 0.0;
		maxBrightnessDistance = 10000.0;	-- must be <= lampFarDistance	
		dsLightRadius = 60;
		dsLightBrightness = 4;
	};
}

flat_shadow =
{
	farDistance = 1500.0; -- doesn't do anything
	fullFarDistance = 0.0; -- doesn't do anything 
}

fog =
{
	front = 1000.0;
	back  = 70000.0;     -- constant across all levels
}

layerfog =
{
	fog_begin = 0.0;
	fog_end = 1000.0;
	fog_strength = 10000.0;
	fog_color = {1.0, 1.0, 1.0};
}

infrared =
{
	landDetail = 0.8;
	landDarkness = 1.0;
	riverDarkness = 0.7;
	roadDarkness = 1.5;
	runwayDarkness = 1.7;
}

noise =
{
	noiseStartDistance = 3000.0;
	noiseEndDistance = 200.0;
	noiseMaxBlend = 0.7;
	noiseScale = 90.0;  --15.0 (Low uses 15; High/Extreme/Insane all use 90)
	rampNoisePower = 0.8;
	rampNoiseScale = 17.0;
	smallNoiseStartDistance = 200.0;
	smallNoiseEndDistance = 1.0;
	smallNoiseMaxBlend = 0.5;
	smallNoiseScale = 450.0;		
}

lamp31 =
{
	lampOn = 1;	
	maxSize = 8.4;
	staticSize = 4.0;
	spriteScale = 0.001;
	minDistance = 150.0;
	maxDistance = 10000.0;
	maxAlphaDistance = 400.0;
	minAlphaDistance = 0.0;
	minAlpha = 0.0;
	maxAlpha = 1.0;
	minBrightnessDistance = 0.0;
	maxBrightnessDistance = 10000.0;
	dsLightRadius = 60;
	dsLightBrightness = 4;
}

lamp =
{
	lampOn = 1;	
	maxSize = 5.4;
	staticSize = 2.9;
	spriteScale = 0.0012; 
	minDistance = 100.0;
	maxDistance = 3385.0;
	maxAlphaDistance = 1300.0;
	minAlphaDistance = 250.0;
	minAlpha = 0.0;
	maxAlpha = 1.0;
	minBrightnessDistance = 0.0;
	maxBrightnessDistance = 24000.0; 
}

fan = 
{
	read = 0;
	
	pos = {-117, 0.3, 120};
	dir = {0, -1, 0};
	power = 8000;
	radius = 30;
	
	oscillator = 0.2;
	frequency = 15;
};

hiddensemantics={};
hiddenlayer={};
hiddenlevels={};
hiddencameras={};
debug = 
{
	switchoffDrawRoutine = 0;
	switchoffEdm = 0;
	switchoffFetchSurface = 0;
	switchoffFetchUniqueScenes = 0;
	switchoffFetchDistricts = 0;
	switchoffFetchSmokes = 0;
	switchoffFetchLights = 0;
	switchoffRenderLights = 0;
}