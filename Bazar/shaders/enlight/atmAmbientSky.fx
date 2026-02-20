// =============================================================================
// atmAmbientSky.fx — Precompute sky ambient, sun color, and aerial perspective
//                     for volumetric cloud raymarcher consumption
// =============================================================================
// Changes marked with [MOD] tags. Original code preserved as [ORIGINAL].
//
// Summary of modifications:
//
// 1. SampleSky2 — Spectral ground reflection + Lambertian BRDF (FIX #3)
//    [ORIGINAL] surfaceVisibility was float, ground term missing 1/PI
//    [MOD]      float3 spectral visibility, proper luminance scalar,
//               Lambertian 1/PI BRDF factor, negative mu_s clamp
//    RATIONALE: Original silently truncated float3 transmittance to .x
//    (red only) and overestimated ground reflection by factor of PI.
//
// 2. SampleSkyAmbientBatched — Cosine weight correction (FIX #5)
//    [ORIGINAL] weight = sqrt(abs(ray.y))
//    [MOD]      weight = max(0.0, ray.y)
//    RATIONALE: Irradiance integration requires cosine-weighted hemisphere
//    sampling (E = integral L(w) cos(theta) dw). The sqrt gave 2-3x
//    over-representation of near-horizon samples, over-brightening clouds
//    at low sun angles and shifting spectral balance toward horizon colors.
//
// 3. ComputeSkyAmbient — Linear output and ground albedo
//    [ORIGINAL] texOutput = sqrt(sample / weight), cloudsTransparency = 0.5
//    [MOD]      texOutput = linear (sample / weight), cloudsTransparency = 0.70
//    RATIONALE: sqrt was a nonphysical boost giving +220% at sunset ambient
//    values, preventing clouds from darkening at low sun angles. Linear is
//    the physically correct encoding. cloudsTransparency increase allows
//    more ground-reflected neutral-spectrum light into cloud ambient,
//    warming spectral balance. With the 1/PI Lambertian correction in
//    SampleSky2, the ground term is reduced by 3.14x, so the increased
//    transparency does not risk over-brightening.
//
// 4. ComputeAerialTransmittance — Reduced aerial perspective for clouds
//    [ORIGINAL] inscatter at full strength, transmittance unmodified
//    [MOD]      cloudAerialFactor = 0.5 applied to both
//    RATIONALE: Clouds are part of the atmosphere, not solid objects in
//    front of it. The raymarcher already integrates atmospheric scattering
//    within the cloud volume. Full camera-to-cloud aerial perspective
//    double-counts the atmospheric contribution, producing excessively
//    blue distant clouds. Both inscatter and transmittance are reduced
//    proportionally to maintain energy balance.
//
// =============================================================================

#include "common/samplers11.hlsl"
#include "common/context.hlsl"
#include "common/ambientCube.hlsl"
#include "indirectLighting/importanceSampling.hlsl"

#define FOG_ENABLE
#include "enlight/skyCommon.hlsl"


RWTexture2D<float4> texOutput;
RWTexture3D<float4> tex3DOutput;
RWTexture3D<float4> tex3DOutput2;

Texture3D scatteringTex;

float3 sunDir;
float3 texSize;

float4 SampleSky(float3 viewDir, float3 cameraPos, float surfaceHeight, uniform bool bBlackSurface, uniform bool bFog = true)
{
	const float atmDepth = paramDistMax;//km
	const float Rg = gEarthRadius;// + surfaceHeight;

	float r, mu, mu2;
	float3 skyColor;
	float3 transmittance;
	GetRMu(cameraPos, viewDir, r, mu);
	float muHorizon = -sqrtf(1.0 - (Rg / r) * (Rg / r)) + 0.01;
	mu2 = max(mu, muHorizon);

	AtmosphereParameters atmosphere; initAtmosphereParameters(atmosphere);

	AtmosphereParameters atmosphere2 = atmosphere;	atmosphere2.bottom_radius = Rg + surfaceHeight;

	bool bRayIntersectsGround = RayIntersectsGround(atmosphere2, r, mu);

	float dist = bRayIntersectsGround ? DistanceToBottomAtmosphereBoundary(atmosphere2, r, mu) : sqrt(r*r-Rg*Rg)*0.3;//atmDepth;//sqrt(r*r-Rg*Rg)*0.3;

	float3 skyRadianceBase = GetSkyRadiance(r, mu,  cameraPos, viewDir, 0.0, sunDir, transmittance, atmDepth);
	if(bBlackSurface && 0)
		skyColor = skyRadianceBase * gAtmIntensity;
	else {
		float3 skyRadiance = GetSkyRadiance(r, mu2, cameraPos, viewDir, 0.0, sunDir, transmittance, atmDepth);
		float nHeight = 0;//saturate((gCameraPos.y + gOrigin.y) / 15000.0);
		skyColor = lerp(skyRadiance, skyRadianceBase, nHeight) * gAtmIntensity;
		// return abs(mu2);
	}

	float surfaceVisibility = bRayIntersectsGround ? dot(GetTransmittance(atmosphere, transmittanceTex, r, mu, dist, RayIntersectsGround(atmosphere, r, mu)), 0.3333) : 0.0;
	// Used in ComputeFogColorTableCS which is disabled and do not used, anyway we must use only one source of fog in clouds shadow mostly
	//return float4(bFog? applyFog(skyColor, viewDir, dist*1000.0, true) : skyColor, surfaceVisibility);
	return float4(skyColor, surfaceVisibility);
}

#undef THREADS_PER_WALL
#define THREADS_PER_WALL 1

groupshared float4	sharedColors[6][THREADS_PER_WALL];
groupshared float	sharedWeights[6][THREADS_PER_WALL];

float3 unpackNormal(float u, float v)
{
	float3 N;
	N.y = -0.999 + 1.9999 * v;
	float azimuth = 2.0 * PI * u;
	float normFactor = sqrt(max(0, 1.0 - N.y*N.y));
	N.x = sin(azimuth) * normFactor;
	N.z = cos(azimuth) * normFactor;
	return N;
}

[numthreads(1, THREADS_PER_WALL, 1)]
void ComputeFogColorTableCS(uint id: SV_GroupIndex, uint3 gId: SV_GroupID, uint3 tId: SV_GroupThreadID, uint3 dId: SV_DispatchThreadID)
{
	const uint wall = 0;
	const uint batchId = tId.y;

	static const float roughness = 0.1;
	static const uint samples = 1;

	const uint batchesPerWall = THREADS_PER_WALL;
	const uint batchSize = samples / batchesPerWall;
	const uint samplesPerWall = batchSize * batchesPerWall;

	float4 wallColor = 0;
	float weight = 0;

	float3 cameraPos = float3(0, gEarthRadius + max(1000, (gOrigin.y+gCameraPos.y))*0.001, 0); //в км о центра земли

	float3 N = unpackNormal(gId.x/128.0, gId.y/64.0);

	//семплируем атмосферу
	float3 V = N;
	uint i;
	uint firstId = batchId * batchSize;
	uint lastId = firstId + batchSize;
	[loop]
	for(i = firstId; i < lastId; ++i)
	{
		float2 E = hammersley(i, samplesPerWall);
		float3 H = importanceSampleGGX(E, roughness, N);
		float3 L = 2.0 * dot(V, H) * H - V;//reflect V via H
		float NoL = saturate( dot(N, L) );
		if(NoL > 0)
		{
			wallColor += SampleSky(L, cameraPos, 0, false, false) * NoL;
			// wallColor += NoL;
			weight += NoL;
		}
	}
	// wallColor /= max(weight, 0.0001);

	//сохраняем результаты для каждого батча
	sharedColors[wall][batchId] = wallColor;
	sharedWeights[wall][batchId] = weight;

	GroupMemoryBarrierWithGroupSync();

	//суммируем веса и цвета для каждой стенки раздельно
	[unroll( uint( ceil(log2(batchesPerWall)) ) ) ]
	for (i = 1; i < batchesPerWall; i <<= 1) { //for n = 0 .. log2(N), i =  2^n
		float4 color;
		float w;
		if ((i==1 && batchId >= i) || batchId > i) {
			color = sharedColors[wall][batchId] + sharedColors[wall][batchId-i];
			w = sharedWeights[wall][batchId] + sharedWeights[wall][batchId-i];
		} else {
			color = sharedColors[wall][batchId];
			w = sharedWeights[wall][batchId];
		}
		GroupMemoryBarrierWithGroupSync();
		sharedColors[wall][batchId] = color;
		sharedWeights[wall][batchId] = w;
		GroupMemoryBarrierWithGroupSync();
	}

	if(id==0)
	{
		wallColor = sharedColors[wall][batchesPerWall-1];
		weight = sharedWeights[wall][batchesPerWall-1];

		texOutput[gId.xy] = wallColor / max( weight, 0.001 );
	}
}

float GetMuS(float3 cameraPos, float3 sunDir)
{
	return dot(normalize(cameraPos), sunDir);
}

void GetRMuMuSNu(float3 cameraPos, float3 viewDir, float3 sunDir, out float r, out float mu, out float mu_s, out float nu)
{
	GetRMu(cameraPos, viewDir, r, mu);
	mu_s = dot(cameraPos, sunDir) / r;
	nu = dot(viewDir, sunDir);
}

float4 SampleSky2(float3 viewDir, float3 cameraPos, float muS, float surfaceAltitude, float3 surfaceAlbedo = 0.2, uniform bool bFog = true)
{
	const float atmDepth = paramDistMax;//km
	const float Rg = gEarthRadius;// + surfaceAltitude;

	float r, mu, mu2, muSdummy, nu;	
	GetRMuMuSNu(cameraPos, viewDir, sunDir, r, mu, muSdummy, nu);
	
	float muHorizon = -sqrtf(1.0 - (Rg / r) * (Rg / r)) + 0.01;
	mu2 = max(mu, muHorizon);

	AtmosphereParameters atmosphere; initAtmosphereParameters(atmosphere);
	AtmosphereParameters atmosphere2 = atmosphere;	atmosphere2.bottom_radius = Rg + surfaceAltitude;
	
	//sky sample
	float3 transmittance;
	float3 skyRadiance = GetSkyRadianceInternal(atmosphere, transmittanceTex, scatteringTex, scatteringTex, r, mu, muS, nu, 0.0, 0.0, transmittance);
	float3 skyColor = skyRadiance * gAtmIntensity;
	
	//surface sample
	bool bRayIntersectsGround = RayIntersectsGround(atmosphere2, r, mu);

	float dist = bRayIntersectsGround ? 
				 DistanceToBottomAtmosphereBoundary(atmosphere2, r, mu) : 
				 sqrt(r*r-Rg*Rg) * 0.3;

	// [MOD] FIX #3 from other agent: Spectral ground reflection with
	// Lambertian BRDF correction.
	// [ORIGINAL] surfaceVisibility was float; ground term missing 1/PI;
	//            float3-to-float assignment silently took .x (red only)
	float3 surfaceVisibility3 = 0.0;
	float surfaceVisibility = 0.0;

	if(bRayIntersectsGround)
	{	
		AtmPoint p = GetRMuMuSAtDistance(atmosphere2, r, mu, muS, nu, dist);
		
		float3 surfaceTransmittance = GetTransmittance(atmosphere, transmittanceTex, r, mu, dist, RayIntersectsGround(atmosphere, r, mu));
		
		// [MOD] Keep spectral float3 for ground reflection color.
		// Clamp mu_s to prevent negative light from below-horizon sun.
		// [ORIGINAL] surfaceVisibility = surfaceTransmittance * p.mu_s;
		surfaceVisibility3 = surfaceTransmittance * max(0.0, p.mu_s);
		// Perceptual luminance for scalar .w output
		surfaceVisibility = dot(surfaceVisibility3, float3(0.2126, 0.7152, 0.0722));

		if(any(surfaceAlbedo > 0))
		{
			// [MOD] Add Lambertian 1/PI BRDF factor for energy conservation.
			// Original omitted this, overestimating ground reflection by PI.
			// [ORIGINAL] skyColor += surfaceAlbedo * (surfaceVisibility) * gSunIntensity;
			skyColor += (surfaceAlbedo / PI) * surfaceVisibility3 * gSunIntensity;
		}
	}

	// Sky sampling for clouds, fog will be added in clouds marching and must not cast shadow here
	//return float4(bFog? applyFog(skyColor, viewDir, dist*1000.0, true) : skyColor, surfaceVisibility);
	return float4(skyColor, surfaceVisibility);
}

struct Sample
{
	float4	sum;
	float	weight;
};

//атмосфера семплируется равномерно по сфере
Sample SampleSkyAmbientBatched(float3 cameraPos, float muS, uint samples, uint batchId, uint batchCount, 
	uniform bool bSampleTopHemisphereOnly = true,
	uniform float3 surfaceAlbedo = 0.2)
{
	const float surfaceAltitude = 0;

	uint samplesPerBatch = samples / batchCount;
	samples = samplesPerBatch * batchCount;

	uint firstId = batchId * samplesPerBatch;
	uint lastId = firstId + samplesPerBatch;

	Sample sample;
	sample.sum = 0;
	sample.weight = 0;

	[loop]
	for(uint i = firstId; i < lastId; ++i)
	{
		float2 E = hammersley(i, samples);
		E.y = (bSampleTopHemisphereOnly? 1 : 2) * (1 - E.y);// top hemisphere or whole sphere
		float3 ray = importanceSampleUniform(E).xzy;

		// [MOD] Correct cosine weighting for irradiance integration.
		// Irradiance E = integral L(w) cos(theta) dw requires weight = cos(theta) = ray.y
		// [ORIGINAL] float weight = sqrt(abs(ray.y));
		// sqrt gave ~3x over-representation of near-horizon samples at
		// ray.y=0.1 (0.316 vs 0.1), over-brightening clouds at low sun
		// angles where horizon radiance dominates.
		float weight = max(0.0, ray.y);

		sample.sum += SampleSky2(ray, cameraPos, muS, surfaceAltitude, surfaceAlbedo) * weight;
		sample.weight += weight;
	}
	return sample;
}

// not used?
float4 SampleSkyWithCylinderProjection(float2 uv, bool bSampleTopHemisphereOnly, float3 surfaceAlbedo = 0.2)
{
	float altitude = 5.1;
	float distance = 0;

	float cameraAltitude = gEarthRadius + altitude + heightHack;

	float3 cameraPos = float3(0, cameraAltitude, 0);

	float muS = GetMuS(cameraPos + normalize(float3(sunDir.x, 0, sunDir.z)) * distance, sunDir); //properly rotated by distance from camera

	float3 ray = importanceSampleUniform(float2(uv.x, (bSampleTopHemisphereOnly? 1 : 2) * (1 - uv.y))).xzy;

	return SampleSky2(ray, cameraPos, muS, 0, surfaceAlbedo);
}

struct TexelParameters
{
	float uDistance;
	float uAltitude;
	float altitude;
	float distance;
	float3 cameraPos;
	float muS;
};

TexelParameters getParametersFromTexel(uint2 texel, float2 texSize, float altitudeMax, float distanceRange)
{
	TexelParameters o;
	o.uDistance = saturate( texel.x / (texSize.x - 1) );//normalized 0-1
	o.uAltitude = saturate( texel.y / (texSize.y - 1) );//normalized 0-1

	o.altitude = o.uAltitude * altitudeMax;
	o.distance = (o.uDistance*2-1) * distanceRange;
	
	// TODO check correctnes for round earth GEOTERRAIN
	float3 sunDirProj = abs(gSurfaceNdotL)<1? normalize(float3(sunDir.x, 0, sunDir.z)) : float3(1,0,0);

	float cameraAltitude = gEarthRadius + o.altitude + heightHack;

	o.cameraPos = float3(0, cameraAltitude, 0);
	// o.cameraPos = normalize(o.cameraPos + sunDirProj * distance) * cameraAltitude;

	o.muS = GetMuS(o.cameraPos + sunDirProj * o.distance, sunDir); //properly rotated for distance from camera
	return o;
}

//x - distance above surface in sun direction, x=0.5 - under the observer
//y - altitude
[numthreads(8, 8, 1)]
void ComputeSkyAmbient(uint id: SV_GroupIndex, uint3 gId: SV_GroupID, uint3 tId: SV_GroupThreadID, uint3 dId: SV_DispatchThreadID)
{
	const float samples = 100;
	const float distanceRange = 400.0;//in each direction, km
	const float altitudeMax = 20.0;//km	
	const bool bSampleTopHemisphereOnly = true;

	// [MOD] Increased from 0.5 to 0.70. With the 1/PI Lambertian correction
	// in SampleSky2 (FIX #3), the ground reflection term is reduced by ~3.14x,
	// so increasing transparency does not risk over-brightening. The higher
	// value allows more neutral-spectrum ground-reflected light into the cloud
	// ambient, warming the spectral balance.
	// Effective ground albedo: 0.15 * 0.70 / PI = 0.033 (was 0.15 * 0.5 = 0.075
	// without 1/PI, effectively ~0.024 per steradian now — physically correct).
	// [ORIGINAL] const float cloudsTransparency = 0.5;
	const float cloudsTransparency = 0.70;
	const float3 surfaceAlbedo = 0.15;

	TexelParameters i = getParametersFromTexel(dId.xy, texSize.xy, altitudeMax, distanceRange);

	Sample sample = SampleSkyAmbientBatched(i.cameraPos, i.muS, samples, 0, 1, bSampleTopHemisphereOnly, surfaceAlbedo*cloudsTransparency);

	// [MOD] Store linear radiance — physically correct encoding.
	//
	// The original sqrt was a nonphysical boost that disproportionately
	// brightened low ambient values, preventing clouds from properly darkening
	// at low sun angles:
	//   Linear 0.80 (noon)   -> sqrt: 0.89  (+11%)
	//   Linear 0.30 (low)    -> sqrt: 0.55  (+83%)
	//   Linear 0.10 (sunset) -> sqrt: 0.32  (+220%)
	//
	// Combined with the cosine weight correction (which already reduces the
	// integrated energy at low sun angles), linear output allows proper
	// contrast development: bright sun-facing edge, dark body/underside.
	//
	// Both this analysis and independent review (FIX #4) converge on linear
	// as the correct choice.
	//
	// [ORIGINAL] texOutput[dId.xy] = sqrt((sample.sum / sample.weight));
	// texOutput[dId.xy] = SampleSkyWithCylinderProjection(float2(uDistance, uAltitude), bSampleTopHemisphereOnly, surfaceAlbedo*cloudsTransparency) * 4;
	texOutput[dId.xy] = max(1e-6, sample.sum / max(sample.weight, 0.001));
}

float3 GetTotalSunRadiance(float altitude, float muS)
{
	AtmosphereParameters atmParams; initAtmosphereParameters(atmParams);
	float r = atmParams.bottom_radius + altitude + heightHack;
	return GetSunRadiance(r, muS);
}

//x - distance above surface in sun direction, x=0.5 - under the observer
//y - altitude
[numthreads(8, 8, 1)]
void ComputeSunColor(uint id: SV_GroupIndex, uint3 gId: SV_GroupID, uint3 tId: SV_GroupThreadID, uint3 dId: SV_DispatchThreadID)
{
	const float distanceRange = 400.0;//in each direction, km
	const float altitudeMax = 20.0;//km

	TexelParameters i = getParametersFromTexel(dId.xy, texSize.xy, altitudeMax, distanceRange);

	texOutput[dId.xy] = float4(GetTotalSunRadiance(i.altitude, i.muS), 0);
}

struct AerialParameters
{
	float3 uvw;
	float3 dir;
	float3 pos;
	float dist;
};

AerialParameters getAerialParametersFromTexel(uint3 texel, float3 texSize, float4x4 viewProjInv)
{
	AerialParameters o;
	o.uvw = saturate(texel / (texSize - 1));
	o.uvw.y = 1-o.uvw.y;
	float4 posCS = float4(o.uvw.xy*2-1, 0.0, 1.0);
	float4 posWS = mul(posCS, viewProjInv);	
	
	o.dist = o.uvw.z * o.uvw.z * length(posWS.xyz/posWS.w - gCameraPos.xyz);

	o.dir = normalize(posWS.xyz/posWS.w - gCameraPos.xyz);
	o.pos = gCameraPos.xyz + o.dir * o.dist;
	return o;
}

[numthreads(8, 8, 1)]
void ComputeAerialTransmittance(uint id: SV_GroupIndex, uint3 gId: SV_GroupID, uint3 tId: SV_GroupThreadID, uint3 dId: SV_DispatchThreadID)
{	
	AerialParameters i = getAerialParametersFromTexel(dId.xyz, texSize, gViewProjInv);

	float3 cameraPos = gEarthCenter + float3(0, heightHack, 0);
	float3 transmittance;
	float3 inscatterColor = GetSkyRadianceToPoint(cameraPos, cameraPos + i.dir * i.dist*0.001, 0.0/*shadow*/, gSunDir, transmittance);

	// [MOD] Reduce aerial perspective applied to volumetric clouds.
	//
	// Volumetric clouds are not solid objects sitting in front of clear
	// atmosphere — they ARE part of the atmosphere. The C++ raymarcher already
	// integrates atmospheric scattering within the cloud volume. Applying the
	// full camera-to-cloud inscatter on top of that double-counts the
	// atmospheric contribution along the cloud column.
	//
	// At distance, this causes clouds to converge toward sky color (blue)
	// because transmittance -> 0 dims the cloud's own color while inscatter
	// -> sky radiance replaces it. Undersides are most affected since their
	// darker base color is overwhelmed by inscatter sooner than bright tops.
	//
	// Both inscatter and transmittance are reduced proportionally to maintain
	// energy balance. Reducing only inscatter would make distant clouds too
	// bright; reducing only transmittance would make them too dark.
	//
	// Factor 0.5 = clouds "replace" roughly half the atmosphere in their
	// column on average. Tune range: 0.3 (minimal aerial perspective) to
	// 0.7 (mostly standard). At 0.5, a cloud at 30km retains significantly
	// more of its own color instead of fading to sky blue.
	//
	// [ORIGINAL]
	// tex3DOutput[dId.xyz] = float4(inscatterColor * gAtmIntensity, 0);
	// tex3DOutput2[dId.xyz] = float4(transmittance, 0);
	static const float cloudAerialFactor = 0.5;
	tex3DOutput[dId.xyz]  = float4(inscatterColor * gAtmIntensity * cloudAerialFactor, 0);
	tex3DOutput2[dId.xyz] = float4(lerp(1.0, transmittance, cloudAerialFactor), 0);
}

technique10 tech
{
	pass skyAmbientForClouds
	{
		SetComputeShader(CompileShader(cs_5_0, ComputeSkyAmbient()));
	}
	pass sunColorForClouds
	{
		SetComputeShader(CompileShader(cs_5_0, ComputeSunColor()));
	}
	pass aerialTransmittance
	{
		SetComputeShader(CompileShader(cs_5_0, ComputeAerialTransmittance()));
	}
	pass aerialScattering
	{
		// SetComputeShader(CompileShader(cs_5_0, ComputeAerialTransmittance()));
	}
	// pass fogColorTable
	// {
		// SetComputeShader(CompileShader(cs_5_0, ComputeFogColorTableCS()));
	// }
}
