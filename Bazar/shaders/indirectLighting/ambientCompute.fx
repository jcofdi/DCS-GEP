#include "common/samplers11.hlsl"
#include "common/colorTransform.hlsl"
#include "common/context.hlsl"
#include "enlight/atmDefinitions.hlsl"
#include "enlight/atmFunctionsCommon.hlsl"

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
	float3 clr;
	if(id==3) clr = SampleEnvironmentCube(2, samplesPerWall, bOutdoor)*0.7;
	else	  clr = SampleEnvironmentCube(id, samplesPerWall, bOutdoor);
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
	const float3 averageHorizon = cubeWalls[6].rgb;
	
	const float heightCoef = pow(saturate(heightRelative + 0.062), 0.55); //нормализованая высота над поверхностью + минимальное смешивание с цветом горизонта

	//интерполируем цвет эмбиента
	tmpValues[0].surfAmbient = lerp(tmpValues[0].surfaceColorLast, tmpValues[0].surfaceColorNew, saturate(dParam));

	// [MOD] Cloud-occluded ground bounce: conservatively attenuate intensity
	// and desaturate terrain color based on overhead cloud cover.
	//
	// PHYSICAL BASIS:
	// Ground bounce = (light reaching ground) * (ground albedo) * (upward hemisphere).
	// Under overcast, the cloud layer blocks direct sun and reduces diffuse
	// skylight to ~20-30% of clear-sky levels. The ground can only reflect
	// upward what it actually receives, so bounce intensity must decrease.
	//
	// Additionally, cloud-diffused illumination is spectrally flatter than
	// direct sun + Rayleigh sky. The cloud layer acts as a massive scattering
	// diffuser that homogenizes the incident spectrum. Ground receives grayer
	// light, so its reflected bounce is less chromatic regardless of surface
	// material color.
	//
	// DOUBLE-COUNTING MITIGATION:
	// The terrain render texture (tex) is a C++ engine-rendered view that
	// likely already includes some cloud shadow darkening in its lighting.
	// Applying cloudAO.y as a raw multiplier would partially double-count
	// this reduction. We use lerp(1.0, cloudAO.y, 0.6) to apply only 60%
	// of the theoretical reduction, hedging against the portion the terrain
	// render already captured.
	//
	// FACE ASYMMETRY FIX:
	// BuildAmbientCube desaturates side walls (id 0,1,4,5) by ~60% via
	// lerp(..., 0.4, isSide), but the bottom wall (id=3, isSideWall=0)
	// receives zero desaturation then gets overwritten here with raw terrain
	// color. This asymmetry makes terrain chrominance disproportionately
	// strong on object undersides. Cloud-proportional desaturation corrects
	// this under overcast while preserving legitimate color on clear days.
	//
	// SAFETY:
	// cloudAO.y is clamped to minimum 0.3 — this serves dual purpose:
	// physical floor (heaviest overcast still admits ~25-30% diffuse light)
	// and robustness (if cloud shadow textures are not bound for this pass,
	// D3D11 unbound SRV reads return 0; clamp prevents total ground bounce
	// elimination).

	// Sample cloud AO over a spatially stable area beneath camera.
	// 5 Poisson samples at 8km radius for smooth, jitter-free average.
	const float sampleRadius = 8000.0;
	float2 cloudAO = 0;
	for(uint ci = 0; ci < 5; ++ci)
	{
		cloudAO += SampleShadowClouds(
			gCameraPos.xyz + float3(
				Poisson25[ci].x * sampleRadius,
				-500.0,
				Poisson25[ci].y * sampleRadius));
	}
	cloudAO /= 5.0;
	
	// Sky visibility: 1.0 = clear, 0.2-0.3 = heavy overcast.
	// Clamp to 0.3 minimum for physical floor + texture binding safety.
	float groundIllumination = max(0.3, cloudAO.y);
	
	// Conservative intensity attenuation — apply 60% of theoretical
	// reduction to account for partial double-counting with terrain render.
	// Clear sky: factor = 1.0 (no change). Heavy overcast: factor ~0.58.
	float intensityFactor = lerp(1.0, groundIllumination, 0.6);
	float3 surfColor = tmpValues[0].surfAmbient.rgb * intensityFactor;
	
	// Desaturate proportional to cloud cover.
	// Cloud cover metric: 0 = clear (no desaturation), 1 = full overcast.
	float cloudCover = 1.0 - saturate(groundIllumination);
	float desatAmount = cloudCover * 0.4; // Up to 40% desaturation at max overcast
	float surfLum = dot(surfColor, float3(0.2126, 0.7152, 0.0722));
	surfColor = lerp(surfColor, surfLum, desatAmount);

#ifdef USE_DCS_DEFERRED
	cubeWalls[3].rgb = lerp(surfColor, averageHorizon*0.7, heightCoef);
#else
	//убираем влияние цвета земли с увеличением высоты, дополнительно затемняем землю, таки это не зеркало
	cubeWalls[3].rgb = lerp(surfColor*0.6, averageHorizon*0.7, heightCoef);
#endif

	cubeWalls[7].rgb = (cubeWalls[0].rgb + cubeWalls[1].rgb + cubeWalls[2].rgb + cubeWalls[3].rgb + cubeWalls[4].rgb + cubeWalls[5].rgb) / 6.0;
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
