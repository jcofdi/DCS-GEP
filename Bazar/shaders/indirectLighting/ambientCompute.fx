#include "common/samplers11.hlsl"
#include "common/colorTransform.hlsl"
#include "common/context.hlsl"
#include "enlight/atmDefinitions.hlsl"
#include "enlight/atmFunctionsCommon.hlsl"
#include "indirectLighting/importanceSampling.hlsl" // [MOD] FIX #13 — cosine-sampled ambient cube

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
#ifdef EDGE
	// [MOD] FIX #13 — Cosine importance-sampled ambient cube faces.
	//
	// Stock EDGE path: single envCube.SampleLevel(normal, 8.0) — a GGX-prefiltered
	// mip 8 point sample that averages the entire face, conflating sky and ground
	// into one sky-dominated value for side walls.
	//
	// Replacement: 32 cosine importance-sampled directions at mip 4, giving a
	// proper cosine-weighted irradiance integral per face. Cosine weighting
	// emphasizes directions near the face normal and de-emphasizes face edges
	// where the opposing hemisphere bleeds in. Runs once per frame in compute.
	//
	// Face 3 (bottom) is placeholder — overwritten by UpdateAmbientCubeBottomWall.
	float3 clr;
	if (id == 3)
	{
		clr = SampleEnvironmentCube(2, samplesPerWall, bOutdoor) * 0.7;
	}
	else
	{
		float3 N = normals[id];
		float3 result = 0;
		const uint cosinesamples = 32;

		[loop]
		for (uint i = 0; i < cosinesamples; ++i)
		{
			float2 E = hammersley(i, cosinesamples);
			float3 L = importanceSampleCosine(E, N);
			result += envCube.SampleLevel(ClampLinearSampler, L, 4.0).rgb;
		}
		clr = result / float(cosinesamples);
	}
#else
	float3 clr = SampleEnvironmentCube(id, samplesPerWall, bOutdoor);
#endif

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
	// Interpolate terrain color — dParam provides temporal smoothing
	tmpValues[0].surfAmbient = lerp(tmpValues[0].surfaceColorLast,
	                                tmpValues[0].surfaceColorNew,
	                                saturate(dParam));

	// [MOD] FIX #11 — Use engine terrain render as bottom wall source.
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
