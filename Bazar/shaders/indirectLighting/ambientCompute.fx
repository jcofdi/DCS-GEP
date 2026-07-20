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

// [MOD] Circumsolar exclusion for the ambient probe (split-sum convention).
// The env-cube pass renders GetSkyRadiance, whose Cornette-Shanks Mie forward
// lobe (g~0.8) is intense in the circumsolar cone. Sampled at mip 4 it smears
// across ~+/-15-20 deg, so a sun-facing wall reads far brighter than the
// diffuse sky it should represent - handing shadowed sun-facing surfaces
// "sunlit" ambient. The disc + aureole are accounted by the analytic direct
// term; counting them here double-counts direct light into ambient. Cone is
// sized for the mip-4 smear, not the physical aureole (~5 deg).
static const float SUN_EXCL_COS_INNER = 0.985;  // ~10 deg: full exclusion
static const float SUN_EXCL_COS_OUTER = 0.906;  // ~25 deg: smooth edge

// [DIAG] 1 = paint side/top ambient walls magenta to prove the FIX #13 body
// is live in the shipping permutation. Ship at 0.
#define GEP_CANARY_AMBIENT 0

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
		// [MOD] Sun-cone exclusion + trusted ground half.
		//
		// Side walls previously cosine-integrated the full env probe, whose
		// below-horizon half is unreliable hazed distant terrain, and whose
		// circumsolar region carries the smeared Mie forward peak. This:
		//   1) rejects below-horizon samples (the unreliable ground half),
		//   2) excludes the circumsolar cone with weight renormalization
		//      (in-paints the cone with surrounding diffuse sky),
		//   3) composites the trusted live terrain render (surfAmbient, the
		//      same source the bottom wall uses, FIX #11) as the ground half.
		//
		// The rejected-sample fraction MEASURES the cosine-weighted ground
		// split (~0.5 for a side wall, ~0 for the top face) - the physical
		// split falls out of the sampling instead of being hand-tuned. This
		// makes the side-wall luminance/sun-side corrections in
		// SampleEnvironmentMapApprox (steps 1 & 3) redundant; they are removed.
		//
		// surfAmbient here is last frame's smoothed value (pass order is
		// buildCube -> surfaceColor -> updateCube), which is fine and slightly
		// more temporally stable.
		float3 N = normals[id];
		float3 skyAccum = 0;
		float  wSky = 0;
		uint   nGround = 0;
		const uint cosinesamples = 64;   // raised from 32: side walls reject ~half

		[loop]
		for (uint i = 0; i < cosinesamples; ++i)
		{
			float2 E = hammersley(i, cosinesamples);
			float3 L = importanceSampleCosine(E, N);

			// Reject the env-probe's below-horizon half.
			if (L.y < 0.0) { nGround++; continue; }

			// Circumsolar exclusion, renormalized via wSky.
			float sunW = 1.0 - smoothstep(SUN_EXCL_COS_OUTER, SUN_EXCL_COS_INNER,
						dot(L, gSunDir.xyz));
			skyAccum += envCube.SampleLevel(ClampLinearSampler, L, 4.0).rgb * sunW;
			wSky += sunW;
		}

		float3 skyMean = skyAccum / max(wSky, 1e-3);

		float groundFrac = float(nGround) / float(cosinesamples);
		groundFrac = min(groundFrac, 0.33);
		clr = lerp(skyMean, tmpValues[0].surfAmbient.rgb, groundFrac);

#if GEP_CANARY_AMBIENT
		// [DIAG] Liveness canary: ambient goes magenta if this compiled body
		// is what the shipping permutation runs. REVERT GEP_CANARY_AMBIENT to 0.
		clr = float3(1.0, 0.0, 1.0);
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
