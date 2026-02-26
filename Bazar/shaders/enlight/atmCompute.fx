#include "common/samplers11.hlsl"
#include "common/context.hlsl"
// #define EXTERN_ATMOSPHERE_INSCATTER_ID
#include "common/atmosphereSamples.hlsl"
#define FOG_ENABLE
#include "enlight/skyCommon.hlsl"

#include "deferred/ESM.hlsl"
#include "deferred/atmosphere.hlsl"
#include "deferred/deferredCommon.hlsl"

StructuredBuffer<float3> positions;
RWStructuredBuffer<AtmosphereSample> atmosphereResults;

float2 cameraHeightNorm;

AtmosphereSample SampleAtmosphereWithFogToPoint(float3 posInOriginSpace, float3 cameraPosInOriginSpace, float cameraAltitude, float cameraAltitudeNorm)
{
	float2 cloudsShadowAO = SampleShadowClouds(posInOriginSpace);
	float shadow = min(cloudsShadowAO.x, terrainShadows(float4(posInOriginSpace, 1)));
	
	AtmosphereSample o;
	ComputeFogAndAtmosphereCombinedFactors(posInOriginSpace - cameraPosInOriginSpace, 0, cameraAltitude, cameraAltitudeNorm, o.transmittance, o.inscatter);

	// [MOD] Match the INSCATTER_STRENGTH reduction from atmosphere.hlsl
	//
	// atmosphere.hlsl applies a 0.7 inscatter multiplier to all opaque
	// deferred surfaces below 3-10 km camera altitude, compensating for
	// the increased Rayleigh scale height from ARPC (8.0 -> 8.697 km).
	// Without this, ARPC's thicker atmosphere produces ~20% more integrated
	// inscatter than the stock atmospheric profile.
	//
	// Particle effects (overwing vapor, contrails, smoke, explosions) use
	// precomputed atmosphere samples from THIS shader rather than the
	// atmosphere.hlsl path. Without the matching reduction, particles
	// receive 43% more inscatter than the surfaces behind them (1.0/0.7),
	// causing them to appear darker and more blue-shifted than the scene.
	//
	// cameraAltitude is in meters. The ramp matches atmosphere.hlsl exactly:
	//   Below 3 km:  full 0.7 reduction
	//   3-10 km:     linear fade back to 1.0
	//   Above 10 km: no reduction (ARPC scale height effect negligible)
	const float INSCATTER_STRENGTH = 0.7;
	float cameraAltitudeKm = cameraAltitude * 0.001;
	float altitudeFactor = saturate((cameraAltitudeKm - 3.0) / 7.0);
	float inscatterMultiplier = lerp(INSCATTER_STRENGTH, 1.0, altitudeFactor);
	o.inscatter *= inscatterMultiplier;

	o.sunColor = SampleSunRadiance(posInOriginSpace, gSunDir) * (gSunIntensity * shadow);
	return o;
}

[numthreads(COMPUTE_THREADS_XY, COMPUTE_THREADS_XY, 1)]
void ComputeAtmosphereSamples(uint3 gid: SV_GroupId, uint gidx: SV_GroupIndex)
{
	uint idx = gid.x*COMPUTE_THREADS_XY*COMPUTE_THREADS_XY+gidx;

	float3 pos = positions[idx]; // относительно мировой позиции камеры

	atmosphereResults[idx] = SampleAtmosphereWithFogToPoint(pos, gCameraPos.xyz, cameraHeightNorm.x, cameraHeightNorm.y);
}

technique10 Inscatter
{
	pass P0 { SetComputeShader(CompileShader(cs_5_0, ComputeAtmosphereSamples())); }
}
