#include "common/samplers11.hlsl"
#include "common/colorTransform.hlsl"
#include "common/context.hlsl"
#include "enlight/atmDefinitions.hlsl"
#include "enlight/atmFunctionsCommon.hlsl"
#include "indirectLighting/importanceSampling.hlsl" // [MOD] FIX #13 - cosine-sampled ambient cube

#ifdef USE_DCS_DEFERRED
static const float3 minAmbient = float3(9, 26, 52) / 255.f * 0.25;
#else
static const float3 minAmbient = float3(9, 26, 52) / 255.f * 0.5;
#endif

Texture2D	tex;
TextureCube envCube;

float heightRelative;//высота над поверхностью земли [0; 1]
float dParam; //величина прибавки интерполяции
float sunDirY;

struct CubeTempValues
{
	float3 top;		//оригинальная верхняя грань куб мапы
	float3 bottom;	//оригинальная нижняя грань куб мапы
	float3 surfaceColorNew;//цвет земли заданный
	float3 surfaceColorLast;//цвет земли старый
	float3 surfAmbient;// цвет земли текущий (с учетом интерполяции)
	// float3 surfColorDelta;//изменение цвета эмбиента земли
};

RWStructuredBuffer<CubeTempValues> tmpValues;
RWStructuredBuffer<float4> cubeWalls;

static const float2 Poisson25[] = {
	{-0.841121, 0.521165},
	{-0.702933, 0.903134},
	{-0.495102, -0.232887},
	{-0.345866, -0.564379},
	{-0.182714, 0.321329},
	{-0.0564287, -0.36729},
	{0.0381787, -0.728996},
	{0.253639, 0.719535},
	{0.423627, 0.429975},
	{0.566027, -0.940489},
	{0.652089, 0.669668},
	{0.968871, 0.840449}
};

static const float3 normals[] = {
	{1,0,0},
	{-1,0,0},
	{0, 1,0},
	{0,-1,0},
	{0,0, 1},
	{0,0,-1},
};

static const float3 binormals[] = {
	{0, 1, 0},
	{0, 1, 0},
	{0, 0, 1},
	{0, 0, 1},
	{1, 0, 0},
	{1, 0, 0},
};

static const float	isSideWall[] = { 1, 1, 0, 0, 1, 1 };
static const float3 lumCoef =  {0.2125f, 0.7154f, 0.0721f};

// [MOD] Analytical sun subtraction (replaces circumsolar exclusion).
//
// The env-cube pass renders GetSkyRadiance, which includes the sun disk
// and its Mie forward lobe. The direct lighting pass separately adds
// gSunDiffuse * gSunIntensity * NoL, so including the sun in the ambient
// cube double-counts that energy.
//
// The old approach excluded a 25-degree cone around the sun from the
// importance sampling. This also removed the aureole and the natural
// Rayleigh brightness gradient near the sun — legitimate ambient energy
// that accounted for 50-90% of sun-facing wall luminance depending on
// sun elevation. The resulting dim walls could fall below the consumer's
// chrominance correction floor (0.001), triggering secondary artifacts.
//
// The new approach: sample the full hemisphere without exclusion, then
// subtract the sun's measured excess from the computed mean. The cubemap
// value at gSunDir (mip 4) minus the face mean estimates the sun's
// radiance above the sky background. Scaled by NdotSun and a geometric
// fraction, this removes the double-counted direct energy while
// preserving the aureole and sky gradient.
//
// GEP_SUN_SUB_K: fraction of sunExcess * NdotSun to subtract.
//   Derived from the mip-4 sun spread's cosine-weighted solid angle
//   fraction (~0.02), but the Monte Carlo response to a bright point
//   source concentrates more expected value per sample than the
//   geometric fraction alone predicts. Start at 0.08, tune by flight:
//   compare sun-facing vs anti-sun walls in the ambient canary.
//   Too high: sun-facing walls darker than anti-sun. Too low: sun-facing
//   walls carry visible extra energy into shadowed surfaces.
#define GEP_SUN_SUB_K 0.08

// [DIAG] Test mode selector for ambient cube producer diagnostics.
//   0 = Ship (cosine sampling + sun subtraction, current GEP)
//   1 = TEST 1: Mip-8 revert (stock producer, answers "does the producer cause the glow?")
//   2 = TEST 2a: Cosine sampling with groundFrac cap raised to 0.50
//   3 = TEST 2b: Per-face color canary (which face dominates at distance?)
//   4 = Magenta liveness canary
#define GEP_AMBIENT_TEST 1

groupshared float3	sharedCubeWalls[6];

//при нормальном HDR корректировать тут нечего, тогда и выпилить
inline float getSunAttenuation()
{
	return pow(max(0, sunDirY),0.65)*0.1+0.9;
}

//делаем выборки из грани куба
float3 SampleEnvironmentCube(uint id, uniform uint samples, uniform bool isOutdoor = true)
{
	float3 normal = normals[id];

#if USE_DCS_DEFERRED == 1
	return envCube.SampleLevel(ClampLinearSampler, normal, 8.0).rgb;
#else
	float3 clr = 0;
	float3 normResult;
	float isSide = isSideWall[id];
	
	float3x3 M = {
		normal, 
		binormals[id], 
		cross(normal, binormals[id])
		};

	[unroll]
	for(uint i=0; i<samples; ++i)
	{
		normResult = mul(float3(1, Poisson25[i].x, Poisson25[i].y), M);
		if(isOutdoor)
			normResult.y = lerp(normResult.y, abs(normResult.y)*0.5, isSide);

		clr += envCube.SampleLevel(ClampLinearSampler,normalize(normResult), 0).rgb;
	}
	return clr/samples;
#endif
}

float3 SampleWhitePoint(float3 averageCube, bool bOutdoor)
{
	float3 white = averageCube;
	
	if(bOutdoor)
	{
		const float groundAlbedo = 0.25;
		const float radius = 10000;

		float3 skyIrradiance = GetSkyIrradiance(OriginSpaceToAtmosphereSpace(gCameraPos.xyz), gSunDir) * (1.0 / atmPI);

		float2 cloudShadowAO = 0;
		for(uint i=0; i<12; ++i)
			cloudShadowAO += SampleShadowClouds(gCameraPos.xyz + float3(Poisson25[i].x*radius, -1000.0, Poisson25[i].y*radius)).x;
		cloudShadowAO += SampleShadowClouds(gCameraPos.xyz + float3(0, -1000.0, 0)).xy;
		cloudShadowAO /= 13;

		cloudShadowAO.x = lerp(cloudShadowAO.x, 1, 0.7);

		float3 white = gSunDiffuse.rgb * ((0.25/3.1415) *  max(0, gSurfaceNdotL) * cloudShadowAO.x) + skyIrradiance * cloudShadowAO.y;

		// white = lerp(white, averageCube, 0.5);
	}
	white *= 3.0 / (white.r+white.g+white.b);
	return white;
}

/*
на боковых гранях сэмплы берутся только с верхней половины, сделано чтобы не учитывать вклад земли, 
которая теперь рисуется в environment.
*/
[numthreads(6,1,1)]
void BuildAmbientCube(uint id: SV_GroupIndex, uniform uint samplesPerWall, uniform bool bOutdoor)
{
	// [MOD] FIX #14 - EDGE gate removed; FIX #13 body is now unconditional.
	//
	// Evidence the #ifdef EDGE branch never compiled in shipping builds:
	//   1) No fxo.edcz identity permutation of this file defines EDGE (batch
	//      compiler never errored on a hard syntax error inside the branch).
	//   2) Clean-slate FXO deploys generate zero new shaders - DCS never
	//      requests a permutation outside the fxo.edcz set for this effect.
	//   3) This is a technique10 effect, outside the terrain meta2 channel.
	// Stock's EDGE-only delta (bottom wall = top x 0.7) is superseded by
	// UpdateAmbientCubeBottomWall (FIX #11) regardless, so nothing of value
	// existed in the gate. The consumer-side removals in
	// SampleEnvironmentMapApprox (former steps 1 & 3) depend on this body
	// actually running; unconditional compilation makes that pairing real.
	//
	// [MOD] FIX #13 - Cosine importance-sampled ambient cube faces.
	//
	// Stock EDGE path: single envCube.SampleLevel(normal, 8.0) - a GGX-prefiltered
	// mip 8 point sample that averages the entire face, conflating sky and ground
	// into one sky-dominated value for side walls.
	//
	// Replacement: 32 cosine importance-sampled directions at mip 4, giving a
	// proper cosine-weighted irradiance integral per face. Cosine weighting
	// emphasizes directions near the face normal and de-emphasizes face edges
	// where the opposing hemisphere bleeds in. Runs once per frame in compute.
	//
	// Face 3 (bottom) is placeholder - overwritten by UpdateAmbientCubeBottomWall.
	float3 clr;
	if (id == 3)
	{
		clr = SampleEnvironmentCube(2, samplesPerWall, bOutdoor) * 0.7;
	}
	else
	{
#if GEP_AMBIENT_TEST == 1
		// TEST 1: Stock mip-8 producer. If the glow disappears, the cosine
		// sampling is the source. If it persists, look consumer-side.
		clr = SampleEnvironmentCube(id, samplesPerWall, bOutdoor);

#elif GEP_AMBIENT_TEST == 3
		// TEST 2b: Per-face diagnostic colors at matched luminance.
		// +X=red, -X=green, +Y=blue, +Z=yellow, -Z=cyan.
		// The object's tint at distance reveals which face dominates nSquared.
		static const float3 faceColors[] = {
			float3(1.0, 0.1, 0.1),  // 0: +X  red
			float3(0.1, 1.0, 0.1),  // 1: -X  green
			float3(0.2, 0.2, 1.0),  // 2: +Y  blue
			float3(0.0, 0.0, 0.0),  // 3: -Y  (placeholder, overwritten)
			float3(1.0, 1.0, 0.1),  // 4: +Z  yellow
			float3(0.1, 1.0, 1.0),  // 5: -Z  cyan
		};
		clr = faceColors[id] * 0.5;

#elif GEP_AMBIENT_TEST == 4
		// Magenta liveness canary.
		clr = float3(1.0, 0.0, 1.0);

#else
		// Mode 0 (ship) and mode 2 (groundFrac test): full cosine sampling.
		float3 N = normals[id];
		float3 skyAccum = 0;
		float  wSky = 0;
		uint   nGround = 0;
		const uint cosinesamples = 64;

		[loop]
		for (uint i = 0; i < cosinesamples; ++i)
		{
			float2 E = hammersley(i, cosinesamples);
			float3 L = importanceSampleCosine(E, N);

			if (L.y < 0.0) { nGround++; continue; }

			float w = 1.0;
			skyAccum += envCube.SampleLevel(ClampLinearSampler, L, 4.0).rgb * w;
			wSky += w;
		}

		float3 skyMean = skyAccum / max(wSky, 1e-3);

		float NdotSun = max(0, dot(N, gSunDir.xyz));
		if (NdotSun > 0)
		{
			float3 sunPeak = envCube.SampleLevel(ClampLinearSampler, gSunDir.xyz, 4.0).rgb;
			float3 sunExcess = max(0, sunPeak - skyMean);
			skyMean = max(0, skyMean - sunExcess * NdotSun * GEP_SUN_SUB_K);
		}

		float groundFrac = float(nGround) / float(cosinesamples);
	#if GEP_AMBIENT_TEST == 2
		groundFrac = min(groundFrac, 0.50);  // TEST 2a: natural 50/50 split
	#else
		groundFrac = min(groundFrac, 0.33);  // shipping cap
	#endif
		clr = lerp(skyMean, tmpValues[0].surfAmbient.rgb, groundFrac);
#endif
	}

#ifndef USE_DCS_DEFERRED
	if(bOutdoor)
	{
		//убираем насыщенность
		float isSide = isSideWall[id];
		float lum = dot(lumCoef, clr);
		clr = lerp(clr, lerp(float3(lum,lum,lum)*0.75, clr, 0.4), isSide);
		//ограничиваем минимальный эмбиент
		sharedCubeWalls[id] = max(minAmbient, clr*getSunAttenuation());
		
		if(id==2)
		{
			clr = rgb2hsv(sharedCubeWalls[id] / lerp(getSunAttenuation()*0.9, 1, max(0, sunDirY*sunDirY)));//осветляем когда солнце в горизонте, чтобы земля не была такой темной
			clr.y *= 1-0.28*pow(max(0, sunDirY),0.65);//уменьшаем насыщенность верхней грани куба когда солнце в зените, и не трогаем когда в горизонте	
			sharedCubeWalls[id] = hsv2rgb(clr);
		}
		cubeWalls[id].rgb = sharedCubeWalls[id];
	}
	else
#endif
	{
		sharedCubeWalls[id] = clr;
		cubeWalls[id].rgb = clr;
	}
	GroupMemoryBarrierWithGroupSync();
	
	if(id==0)
	{
		float3 sum = sharedCubeWalls[0].rgb + sharedCubeWalls[1].rgb + sharedCubeWalls[4].rgb + sharedCubeWalls[5].rgb;
		float3 averageHorizon = sum / 4.0;
		float3 averageCube = (sum + sharedCubeWalls[2].rgb + sharedCubeWalls[3].rgb) / 6.0;
		
		cubeWalls[6].rgb = averageHorizon;
		cubeWalls[7].rgb = averageCube;
		cubeWalls[8].rgb = SampleWhitePoint(averageCube, bOutdoor);
	}
}

//вызывается один раз, когда заново отрендерили землю в таргет для эмбиента
[numthreads(1,1,1)]
void GetSurfaceColor(uniform uint samples)
{
	float3 clr = 0;
	
	[unroll]
	for(uint i=0; i<samples; ++i)
	{
		clr += tex.SampleLevel(gBilinearClampSampler, Poisson25[i]*0.5+0.5, 0).rgb;
	}

	tmpValues[0].surfaceColorLast.rgb = tmpValues[0].surfAmbient;//старый цвет земли
	tmpValues[0].surfaceColorNew.rgb = min(1, clr / samples);//новое значение
}

[numthreads(1,1,1)]
void UpdateAmbientCubeBottomWall()
{
	// Interpolate terrain color - dParam provides temporal smoothing
	tmpValues[0].surfAmbient = lerp(tmpValues[0].surfaceColorLast,
	                                tmpValues[0].surfaceColorNew,
	                                saturate(dParam));

	// [MOD] FIX #11 - Use engine terrain render as bottom wall source.
	//
	// The engine renders a dedicated downward-looking view into a 2D texture
	// each frame, capturing actual terrain color, cloud tops when above cloud
	// layers, and atmospheric effects. This data is temporally smoothed via
	// dParam interpolation between surfaceColorLast and surfaceColorNew.
	//
	// Stock behavior discarded this data at altitude, replacing it with
	// averageHorizon * 0.7 via a heightCoef blend. Testing confirmed that
	// the terrain render correctly captures cloud tops at 16,000+ ft and
	// responds spatially to individual cloud formations below the camera.
	// Verified functional through 60,000 ft.
	cubeWalls[3].rgb = tmpValues[0].surfAmbient.rgb;

	cubeWalls[7].rgb = (cubeWalls[0].rgb + cubeWalls[1].rgb + cubeWalls[2].rgb +
	                    cubeWalls[3].rgb + cubeWalls[4].rgb + cubeWalls[5].rgb) / 6.0;
}

technique10 ambientCubeTech
{
	pass buildCubeIndoor
	{
		SetComputeShader(CompileShader(cs_5_0, BuildAmbientCube(12, false)));
	}
	pass buildCubeOutdoor
	{
		SetComputeShader(CompileShader(cs_5_0, BuildAmbientCube(12, true)));
	}
	pass surfaceColor
	{
		SetComputeShader(CompileShader(cs_5_0, GetSurfaceColor(12)));
	}
	
	pass updateCube
	{
		SetComputeShader(CompileShader(cs_5_0, UpdateAmbientCubeBottomWall()));
	}
}
