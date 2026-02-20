-- =============================================================================
-- JC Opus Terrain Configuration
-- Physically-grounded visibility: 80km atmospheric ceiling, 20/20 acuity
-- Terrain LOD distances optimized for 5-25km slant range visual fidelity
-- Based on High.lua with extended distances and detail parameters
-- =============================================================================

distance =
{
	distance10x10 = 200000.0;      -- was 140000; extended for 80km visibility ceiling
	distanceLevel0 = 200000.0;     -- was 140000; match distance10x10
	uniqueSceneFarDistance = 30000.0;  -- was 20000; pushed to 30km for approach/departure range
	smokesSceneFarDistance = 30000.0;  -- was 20000; match uniqueScene
	minimalSquareOnScreen = 50;
	minimalSquareOnScreenFull = 100;
	
	mapLodDistance0 = 3000;         -- was 2000; pushed for higher detail at cruise altitude
	mapLodDistance1 = 6000;         -- was 4000
	mapLodDistance2 = 10000;        -- was 6000
	mapLodDistance3 = 14000;        -- was 8000
	smallShitDimention = 8000;     -- was 4000; doubled for ground detail visibility
}
distanceBlend = 
{
	townNearDistance  = 80000.0;
	townFarDistance   = 120000.0;
	fieldNearDistance = 40000.0;
	fieldFarDistance  = 140000.0;
	waterNearDistance = 40000.0;    -- was 30000; pushed for water visibility at altitude
	waterFarDistance  = 60000.0;    -- was 40000
	townLightNearDistance  = 15000.0;  -- was 10000; lights visible further
	townLightFarDistance  = 30000.0;   -- was 20000
	subforest = {30000, 60000};    -- was {20000, 40000}; extended for terrain detail
	beach = {30000, 60000};        -- was {20000, 40000}
	road = {30000, 60000};         -- was {20000, 40000}
}

--Old Noise 
land_noise =
{
	noisemin = 0.0;
	noisemax = 0.6;
	noise1front = 1000.0;
	noise1back = 80000.0;          -- was 60000; pushed to 80km atmospheric ceiling
	noise1top = 12000.0;           -- was 10000; maintain noise at higher altitudes
	noise1bottom = 2000.0;
	noise1PerSquare = 2.0;
	noise2PerSquare = 150.0;
}

land_detailNoise=
{
	Height = 600.0;                -- was 500; increased for ground detail fidelity
	Slope = 0.0;	
}

district =
{
	maxDistrictsAround = 100000;

	farDistance = 40000.0;          -- was 30000; pushed for 5-25km slant range
	farFullRenderDistance = 30000.0; -- was 20000
	nearFullRenderDistance = 5000.0; -- was 3000
	nearDistance = 5000.0;          -- was 3000; match nearFullRenderDistance
	
-- These tree values seem to be obsolete (they don't do anything)
	treesFarDistance = 1500.0;
	treesFarFullBlendRenderDistance = 1200.0;
	treesFarFullRenderDistance = 1000.0;
	treeslodDistance = 600.0;
	heightFactor = 0;
	heightRandomFactor = 0;
	ajastfactor = 1;
	
	lampFarDistance = 15000;        -- was 10000; lights visible further out
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
		maxDistance = 15000.0;      -- was 10000; match lampFarDistance
		maxAlphaDistance = 400.0;
		minAlphaDistance = 0.0;
		minAlpha = 0.0;
		maxAlpha = 1.0;
		minBrightnessDistance = 0.0;
		maxBrightnessDistance = 15000.0;	-- must be <= lampFarDistance
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
	back  = 80000.0;               -- was 70000; pushed to 80km atmospheric ceiling
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
	noiseScale = 120.0;            -- was 90.0; increased for texture detail at altitude
	rampNoisePower = 0.8;
	rampNoiseScale = 17.0;
	smallNoiseStartDistance = 400.0; -- was 200.0; extended for close-range ground detail
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
	maxDistance = 15000.0;          -- was 10000; extended lamp visibility
	maxAlphaDistance = 400.0;
	minAlphaDistance = 0.0;
	minAlpha = 0.0;
	maxAlpha = 1.0;
	minBrightnessDistance = 0.0;
	maxBrightnessDistance = 15000.0; -- was 10000
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
	minAlpha = 0.0; --0.36
	maxAlpha = 1.0; --0.26
	minBrightnessDistance = 0.0;
	maxBrightnessDistance = 30000.0; -- was 24000; pushed for lamp brightness at distance
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

--hiddensemantics={0, 2, 5, 7, 9, 23, 26};
hiddensemantics={
--	"Sea",
--	"Lake", 
--	"Island",
--	"Land",
--	"Field",
--	"Beach",
--	"Plant",
--	"Town",
--	"River",
--	"Channel",
--	"Road",
--	"Rail",
--	"Runway",
--	"Building",
--	"ELT",
--	"SmallShit",
--	"Trees",
--	"Lamp",
	};
hiddenlayer={
--	0,
--	1,
--	2, 
--	3, 
--	4, 
--	5, 
--	6, 
--	18,
--	19,		-- flat_shadows		
--	20,		-- houses
--	21,		-- trees
--	22,		-- pole
--	23,		-- lights
--	24
};
hiddenlevels={
--	0, 
--	1, 
--	2
	};
hiddencameras={
--	0, --near, 
--	1, --far
	};
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