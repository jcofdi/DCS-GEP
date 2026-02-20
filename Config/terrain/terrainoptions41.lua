useTerrainShaderCache = 1
preloadMetaShaders = 1

shading = 1;
shadingEditor = 0;

options = 
{
	initItemsCount = 200;
	maxSuperficialsPerFrame = 4;
	vehiclesDecimation = 1;
	flatShadowsLayerInFinalColorPass = 13;
}

resourceManager = 
{
	enable = 1;
	lazyLoadReferences = 1;
}

grass =
{
	grassType = 2; -- 0 - off, 1 - procedure grass1, 2 - procedure grass2
}


function surface5_transition_distance(near, far)
	return near + (far - near) * 2.0 / 3.0;
end

distances =
{
	commonFactor = 1;
	-- JC Opus: Pushed higher to maintain detail at cruise altitudes
	surfaceLevel0 = 45000.0;  -- was 30000; maintain highest detail to ~45km altitude
	surfaceLevel1 = 60000.0;  -- was 40000; medium detail to ~60km altitude
	
	-- JC Opus: Extended LOD ring distances for sharp terrain silhouettes at altitude
	surfaceLod =
	{
		{0, 0, 3000, 6000};                                             -- LOD 0: was 0-4km, now 0-6km
		{6000, 6000, surface5_transition_distance(6000, 14000), 14000}; -- LOD 1: was 4-8km, now 6-14km
		{14000, 14000, surface5_transition_distance(14000, 28000), 28000}; -- LOD 2: was 8-16km, now 14-28km
		{28000, 28000, 80000, 200000};                                  -- LOD 3: was 16-150km, now 28-200km
 	};

	-- JC Opus: Pushed from 20km to 30km to cover approach/departure visual range
	uniqueScene = 30000.0;  -- was 20000
	details = {256, 512, 1024, 2048, 4096, 8192, 16384, 16384, 16384, 16384, 16384, 16384, 16384};
	vehicles = 2000;
	instancerFactor = 1;
	wireMaxDistance = 900;

	roofMinDistance = 1000;
	roofMaxDistance = 3000;

	uniqueSceneAdaptive = 
	{
		enable = false;
		minimalSquareOnScreen = 50;
		minimalSquareOnScreenFull = 100;
	};
	block = 
	{
		lod0 = 200.0;
		lod1 = 600.0;
		blend = 2000.0;
		far = 2010.0;
	};

--	asyncPreloadRadius = 80000.0;  -- JC Opus: noted but left commented; see first file notes
}
lights = 
{
	lampsScaleOld = 1.0; 
	lampsScaleNear = 1.0; 
	lampsMinPixelSize = 8.0;
	
	lampsBrightness = 9.0;
	lampsBrightnessRandom = 1;
	lampsBrightnessRandomQuantity = 2;
	
	lampsDoubleBrightnessDistance = 60.0;
	
	lampsRaysBrightness = 0.002;
	lampsRaysMinPixelSize = 12; 
	
	lampsShimmerFullDistance = 10000.0;
	lampsShimmerQuantity = 0.4;
	lampsShimmerStrength = 0.16;
}
gpuCounters =
{
	{"surfaceLevel0", "surface", ""},
	{"details", "computeinstancer", ""},
	{"buildings", "flat_shadows_opaque", ""},
	{"buildings", "opaque", ""},
	{"buildings", "reflectionmap", ""},
	{"buildings", "lights", ""},
}

_fullFrameTime = 16.6
gpuTimeLimits = 
{
	type = "";
	surfaceLevel0 = 9;
	buildings = 9;
	details = 9;

	degradateThreshold = _fullFrameTime*0.6;
	strongThreshold = _fullFrameTime*0.8;
	achtungThreshold = _fullFrameTime*0.9;
	upStep = 2/128;
	downStep = 3/128;
	plotGraphics = false;
}

weather =
{
	useWindFromConfig = false;
	windDirection = {1, 1};
	windSpeed = 5;
}

-- =============================================================================
-- CLIPMAP CONFIGURATION
-- JC Opus: Quality = 2 (2048px textures, 4x area improvement over stock)
-- =============================================================================
clipmapQuality = 2  -- was 1; 2 = 2048px textures (4x area, 2x linear resolution)

clipmap = 
{
	loggingEnabled = false;
	maxUpdatePerFrame = 10;
	interlaced = 3;
	updateToGPU = 15;
	updateFlagsToGPU = true;
}

updatesClipmapPerFrame = 1
clipmapsForcedRGBA = false
clipmapTextureSize = 1024 * clipmapQuality  -- 2048 for JC Opus (Q=2)
clipmapUpdateStep = 32 * clipmapQuality     -- 64 for JC Opus (Q=2)
clipmaptextures =	
{
	colortexture = 
	{
		textureSize = clipmapTextureSize,
		updateStep  = clipmapUpdateStep,
		updatesPerFrame = updatesClipmapPerFrame,
		forcedRGBA = clipmapsForcedRGBA,
	},
	source = 
	{
		textureSize = clipmapTextureSize,
		updateStep  = clipmapUpdateStep,
		updatesPerFrame = updatesClipmapPerFrame,
		forcedRGBA = clipmapsForcedRGBA,
	},
	normalmap = 
	{
		textureSize = clipmapTextureSize,
		updateStep  = clipmapUpdateStep,
		updatesPerFrame = updatesClipmapPerFrame,
		forcedRGBA = clipmapsForcedRGBA,
	},
	shadowmap = 
	{
		textureSize = clipmapTextureSize,
		updateStep  = clipmapUpdateStep,
		updatesPerFrame = updatesClipmapPerFrame,
		forcedRGBA = clipmapsForcedRGBA,
	},
	lightsmap = 
	{
		textureSize = clipmapTextureSize,
		updateStep  = clipmapUpdateStep,
		updatesPerFrame = updatesClipmapPerFrame,
		forcedRGBA = clipmapsForcedRGBA,
	},
	splatmap = 
	{
		textureSize = clipmapTextureSize,
		updateStep  = clipmapUpdateStep,
		updatesPerFrame = updatesClipmapPerFrame,
		forcedRGBA = clipmapsForcedRGBA,
	},

}

waves = 
{
 waveMaxWindValue = 20;
 lowWind = 
 {
  waveLength = 2;
  waveSpeed = 0.3;
  wavePowerX = 0.2;
  wavePowerY = 0.2;
  waveHeight = 0.5;
 };
 highWind = 
 {
  waveLength = 60;
  waveSpeed = 4;
  wavePowerX = 1;
  wavePowerY = 0.6;
  waveHeight = 5;
 };
}

hiddensemantics = {};

checkHiddenSemanticsSurface = 0
hiddensemanticsSurface = {};

hiddenqueuelayers = {};

hiddenlayer = {};

hiddenlevels = {};

hiddenqueues = {};

hiddenLibraries = {};
viewOnlyLibraries = {};
hiddenFiles = {};

instancer =
{
	computeStrategy = "single";

	bufferSize = 30000;
	checkBufferSize = false;

	multiAppendBufferSize = 524288;
	parentBufferSize = 20000;
	childsBufferSize = 100000;

	vertexInstancer = true;
	geometryReference = true;

	singleBufferSize = 4194304;
	singleBlockSize = 128;
}

debug = 
{
	useParseContext = 0;

	dumpFilteredByCondition = 0;
	dumpFilteredByNeedRender = 0;
	dumpFilteredByHidden = 0;
	dumpFilteredByLod = 0;
	dumpInstancedObjects = 0;
	loggingParse = 0;

	switchoffDrawTerrainObject = 0;
	switchoffRenderTerrainObject = 0;
	switchoffEdm = 0;
	switchoffFetchSurface = 0;
	switchoffFetchSuperficial = 0;
	switchoffRenderSuperficial = 0;
	switchoffSurfaceDetails = 0;
	switchoffAssetRuntimeSurfaceDetails = 0;
	switchoffFetchUniqueScenes = 0;
	switchoffFetchRoadDetails = 0;
	switchoffFetchDistricts = 0;
	switchoffFetchSmokes = 0;
	switchoffFetchLights = 0;
	switchoffRenderLights = 0;
	switchoffRenderLockonTrees = 0;
	switchoffSomething = 0;
	switchoffVehicle = 0;
	switchoffVehicleMath = 0;
	switchoffDataFiles = 0;
	switchoffInstancers = 0;
	switchoffInstancerSubobjects = 0;
	switchoffParseInstances = 0;
	clipmapDebugTextures = 0;
	switchoffClipmapUpdates = 0;
	switchonLayerGpuTime = 0;
	roadNetworkView = false;
	disableVTITextureLoad = 0;
	disableVTITextureArrayUpdate = 0;

	blockTreesScale = 1.0;
	splineBlockTreesScale = 1.0;

	useAsynchGeometries = 1;
	switchoffGeometryLoading = 0;

	testSmokeRender = 0;

	test1 = 0;
	test2 = 0;
	test3 = 0;
	test4 = 0;
	test5 = 0;

	surfaceRenderCheckered = 0;
	surfaceSquareSize = 2048 * 4;
	surfaceRenderOneSquare = 0;
	surfaceSquareIndex = 0;
}