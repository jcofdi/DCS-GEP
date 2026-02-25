#ifndef DEFERRED_ATMOSPHERE_HLSL
#define DEFERRED_ATMOSPHERE_HLSL

#include "common/AmbientCube.hlsl"
#include "deferred/deferredCommon.hlsl"
#include "common/dithering.hlsl"

#define FOG_ENABLE
#include "enlight/skyCommon.hlsl"

#ifdef GEOTERRAIN
float3 SampleSunRadiance(float3 posInOriginSpace, float3 dir)
{
	return GetSunRadiance((posInOriginSpace+gOrigin)*0.001,dir);
}
#else
float3 SampleSunRadiance(float3 posInOriginSpace, float3 dir)
{
	float altitude = posInOriginSpace.y + gOrigin.y;

	AtmosphereParameters atmParams; initAtmosphereParameters(atmParams);

	float r = atmParams.bottom_radius + max(0, altitude*0.001 + heightHack); //'max' to prevent NaN in GetSunRadiance math
	float muS = dir.y;

	return GetSunRadiance(r, muS);
}
#endif

struct EnvironmentIrradianceSample
{
	float3 skyIrradiance;
	float3 surfaceIrradiance;
};

EnvironmentIrradianceSample SampleEnvironmentIrradianceApprox(float3 pos, float shadow = 1, float cloudsAO = 1)
{
	const float3 surfaceDiffuseAlbedo = 0.2;	// in linear space
	float NoL = gSurfaceNdotL;

#ifdef GEOTERRAIN
	float3 sunIrradiance = SampleSunRadiance(pos, gSunDir) * (NoL * shadow * (gSunIntensity / atmPI));
#else
	float3 sunIrradiance = SampleSunRadiance(float3(0, 50 - gOrigin.y, 0), gSunDir) * (NoL * shadow * (gSunIntensity / atmPI));
#endif

	EnvironmentIrradianceSample o;
	o.skyIrradiance	= GetSkyIrradiance(OriginSpaceToAtmosphereSpace(pos), gSunDir) * (cloudsAO * (gSunIntensity / atmPI));

	// [MOD] FIX #6 — Physically-calibrated sky irradiance desaturation under cloud cover.
	//
	// GetSkyIrradiance() returns clear-sky atmospheric irradiance from the Bruneton
	// LUT — inherently blue-dominant from Rayleigh scattering. Under cloud cover,
	// the true downwelling irradiance is a mix of:
	//   - Open sky directions → blue Rayleigh-scattered light (what GetSkyIrradiance computes)
	//   - Cloud-occupied directions → spectrally neutral Mie-scattered light (not modeled)
	//
	// The desaturation compensates for the missing cloud-base radiance contribution.
	// The required spectral flattening is proportional to cloud hemisphere fraction.
	//
	// [ORIGINAL] saturate(3.5 - 3.5*(cloudsAO*cloudsAO))
	// The original curve reached 100% desaturation at cloudsAO = 0.8 (light SCT),
	// removing all blue sky character even when ~80% of the hemisphere is clear sky.
	//
	//   cloudsAO | Cloud frac | Original | This curve | Physical target
	//   1.0      | 0%         | 0%       | 0%         | 0%
	//   0.9      | ~10%       | 66%      | 5.5%       | ~10%
	//   0.8      | ~20%       | 100%     | 12%        | ~20%
	//   0.7      | ~30%       | 100%     | 19.5%      | ~30%
	//   0.5      | ~50%       | 100%     | 37.5%      | ~50%
	//   0.3      | ~70%       | 100%     | 59.5%      | ~70%
	//   0.0      | 100%       | 100%     | 100%       | ~100%
	//
	// The curve cloudOcclusion * (0.5 + 0.5 * cloudOcclusion) tracks the physical
	// target: gentle onset (even small cloud fraction contributes some neutral Mie
	// light via the 0.5× base), accelerating toward full desaturation as cloud base
	// increasingly dominates the hemisphere (0.5× cloudOcclusion added component).
	//
	// Boundary behavior: identity at cloudsAO=1.0 (clear sky), full desaturation
	// at cloudsAO=0.0 (dense overcast). No change to clear-sky or overcast scenes.
	float cloudOcclusion = saturate(1.0 - cloudsAO);
	float desatAmount = cloudOcclusion * (0.5 + 0.5 * cloudOcclusion);
	o.skyIrradiance = lerp(o.skyIrradiance, dot(o.skyIrradiance, 0.33333), desatAmount);

	//takes sand storm color into account depending on eye altitude and dust density
	bool bSandStorm = gFogParams.color.r != gFogParams.color.b;
	if(bSandStorm)
	{
		pos.y = (ProjectOriginSpaceToSphere(pos).y + gOrigin.y) * 0.001;
		float thicknessKm = gFogParams.layerHeight * 0.001f;
		float mask = 1 - saturate(pos.y / (thicknessKm * 2));
		float densityFactor = thicknessKm / gFogParams.visibilityKm;
		float skyVisibilityFactor = 1 - saturate(mask * densityFactor);
		o.skyIrradiance *= lerp(gFogParams.color / gFogParams.color.r, 1, skyVisibilityFactor*skyVisibilityFactor);
	}

	o.surfaceIrradiance = surfaceDiffuseAlbedo * (sunIrradiance + o.skyIrradiance);
	return o;
}

// [MOD] FIX #7 — Inject horizon irradiance from the ambient cube as a third pole.
//
// The original SampleEnvironmentMapApprox uses a two-pole vertical blend:
// up → skyIrradiance, down → surfaceIrradiance. For horizontal-facing normals
// (vertical surfaces, object sides), it returns roughly the average of both poles.
// Under cloud shadow, both poles are darkened by cloudsAO and shadow, so horizontal
// normals receive the average of two dark values.
//
// Meanwhile, the ambient cube's side walls (AmbientAverageHorizon) already contain
// the correct horizon brightness — rendered from the actual scene each frame. On a
// partially cloudy day, the horizon is bright with scattered sunlight from distant
// clear atmosphere and sunlit terrain. This data is physically correct by construction
// and self-attenuates naturally: under overcast, the horizon walls also darken because
// the rendered cubemap sees the same grey sky.
//
// The blend uses (1 - |ny|)² to weight the horizon contribution, peaking for
// horizontal normals and falling to zero for pure up/down normals, avoiding
// interference with the existing vertical poles. The 0.5 mix limit ensures the
// horizon supplements rather than replaces the analytical model.
//
// [ORIGINAL] Two-pole blend only:
//   return lerp(eis.surfaceIrradiance, eis.skyIrradiance, saturate(y*0.5+0.5))
//        + float3(1e-3, 1e-4, 1e-5)*ny;
float3 SampleEnvironmentMapApprox(EnvironmentIrradianceSample eis, float3 normal, float roughness = 1.0)
{
	const float ny = dot(gSurfaceNormal, normal);
	const float y = ny * 10 - 9 * (1 - roughness * roughness);
	float t = saturate(y * 0.5 + 0.5);

	// Existing two-pole vertical blend (up = skyIrradiance, down = surfaceIrradiance)
	float3 verticalIrradiance = lerp(eis.surfaceIrradiance, eis.skyIrradiance, t);

	// Horizon contribution from actual ambient cube — strongest for horizontal normals.
	// AmbientAverageHorizon is the average of the 4 side walls (+X, -X, +Z, -Z),
	// already computed each frame in BuildAmbientCube and stored in AmbientMap[6].rgb.
	// It naturally contains the correct brightness: bright on partially cloudy days
	// (distant sunlit atmosphere), dim under overcast (rendered cubemap sees grey sky).
	float horizonWeight = 1.0 - abs(ny);   // peaks at horizontal, zero at up/down
	horizonWeight *= horizonWeight;          // sharpen falloff toward poles
	float3 horizonIrradiance = AmbientAverageHorizon;

	return lerp(verticalIrradiance, horizonIrradiance, horizonWeight * 0.5)
		 + float3(1e-3, 1e-4, 1e-5) * ny;
}

float3 SampleEnvironmentMapApprox(float3 pos, float3 normal, float roughness = 1.0)
{
	float2 cloudShadowAO = SampleShadowClouds(pos);

	EnvironmentIrradianceSample eis = SampleEnvironmentIrradianceApprox(pos, cloudShadowAO.x, cloudShadowAO.y);
	return SampleEnvironmentMapApprox(eis, normal, roughness);
}

// ========== ATMOSPHERE APPLICATION WITH DITHERED INSCATTER ==========
// pixelPos: screen-space pixel coordinate (SV_POSITION.xy) for noise generation.
// When a caller does not have pixel position available, use the non-dithered overload below.
float3 atmApplyLinearDithered(float3 v, float distance, float3 color, float2 pixelPos)
{
	float3 transmittance;
	float3 cameraPos = gEarthCenter + heightHack*gSurfaceNormal;
	float3 inscatterColor = GetSkyRadianceToPoint(cameraPos, cameraPos + v*distance, 0.0/*shadow*/, gSunDir, transmittance);
	
	// ========== INSCATTER STRENGTH REDUCTION ==========
	const float INSCATTER_STRENGTH = 0.7;
	float cameraAltitudeKm = length(cameraPos) - gEarthRadius;
	float altitudeFactor = saturate((cameraAltitudeKm - 3.0) / 7.0);
	float inscatterMultiplier = lerp(INSCATTER_STRENGTH, 1.0, altitudeFactor);
	// ========== END INSCATTER REDUCTION ==========
	
	float3 result = color * transmittance + inscatterColor * (gAtmIntensity * inscatterMultiplier);
	
	// ========== PRE-TONEMAP ATMOSPHERIC DITHERING ==========
	// Break LUT quantization banding by adding luminance-adaptive IGN noise to the
	// final atmospheric color in linear HDR space. This targets the inscatter component
	// specifically — transmittance attenuation is smooth and doesn't need dithering.
	//
	// The 0.004 scale means: at luminance ~0.004 the noise amplitude equals the signal,
	// which is well below visible range after tonemapping. At luminance ~1.0, noise is
	// only 0.4% of the signal — completely invisible. The sweet spot where banding is
	// perceptible (luminance ~0.01-0.1 in HDR) gets noise of 4-40% of one quantization
	// step, which is enough to break the bands without adding visible grain.
	result = ditherAtmosphericHDR(result, pixelPos, 0.004);
	// ========== END ATMOSPHERIC DITHERING ==========
	
	return result;
}

// Non-dithered path — original signature preserved for callers without pixel position
float3 atmApplyLinear(float3 v, float distance, float3 color)
{
	float3 transmittance;
	float3 cameraPos = gEarthCenter + heightHack*gSurfaceNormal;
	float3 inscatterColor = GetSkyRadianceToPoint(cameraPos, cameraPos + v*distance, 0.0/*shadow*/, gSunDir, transmittance);
	
	// ========== INSCATTER STRENGTH REDUCTION ==========
	const float INSCATTER_STRENGTH = 0.7;
	float cameraAltitudeKm = length(cameraPos) - gEarthRadius;
	float altitudeFactor = saturate((cameraAltitudeKm - 3.0) / 7.0);
	float inscatterMultiplier = lerp(INSCATTER_STRENGTH, 1.0, altitudeFactor);
	// ========== END INSCATTER REDUCTION ==========
	
	return color * transmittance + inscatterColor * (gAtmIntensity * inscatterMultiplier);
}

float3 applyAtmosphereLinearInternal(float3 camera, float3 pos, float3 color, float3 skyColor, float2 pixelPos)
{
	float3 cpos = (pos-camera)*0.001;	// in km
	float d = length(cpos);
	float3 view = cpos/d;
#ifdef GEOTERRAIN
	float skyLerpFactor = 0;//smoothstep(atmNearDistance, atmFarDistance, d);
#else
	float skyLerpFactor = smoothstep(atmNearDistance, atmFarDistance, d);
#endif

	color = atmApplyLinearDithered(view, d, color, pixelPos);
	return lerp(color, skyColor, skyLerpFactor);
}

// Original signature overload — routes to non-dithered path
float3 applyAtmosphereLinearInternal(float3 camera, float3 pos, float3 color, float3 skyColor)
{
	float3 cpos = (pos-camera)*0.001;	// in km
	float d = length(cpos);
	float3 view = cpos/d;
#ifdef GEOTERRAIN
	float skyLerpFactor = 0;
#else
	float skyLerpFactor = smoothstep(atmNearDistance, atmFarDistance, d);
#endif

	color = atmApplyLinear(view, d, color);
	return lerp(color, skyColor, skyLerpFactor);
}

float3 applyAtmosphereLinear(float3 camera, float3 pos, float4 projPos, float3 color) {

#ifdef NO_ATMOSPHERE
	return color;
#endif

	float2 tc = float2(0.5f *projPos.x/projPos.w + 0.5, -0.5f * projPos.y/projPos.w + 0.5);	
	float3 skyColor = skyTex.SampleLevel(gBilinearClampSampler, tc.xy, 0).rgb;

	// Derive pixel position from projPos for dithering
	float2 pixelPos = float2(0.5 * projPos.x/projPos.w + 0.5, -0.5 * projPos.y/projPos.w + 0.5) * gSreenParams.xy;

	return applyAtmosphereLinearInternal(camera, pos, color, skyColor, pixelPos);
}

float3 applyAtmosphereLinear(float3 camera, float3 pos, float4 projPos, float3 color, float3 skyColor)
{
#ifdef NO_ATMOSPHERE
	return color;
#endif
	float2 pixelPos = float2(0.5 * projPos.x/projPos.w + 0.5, -0.5 * projPos.y/projPos.w + 0.5) * gSreenParams.xy;
	return applyAtmosphereLinearInternal(camera, pos, color, skyColor, pixelPos);
}

float3 sampleSkyCS(float2 c) {
	uint2 c1 = floor(c);
	uint2 c2 = ceil(c);
	return lerp(lerp(skyTex.Load(uint3(c1, 0)).rgb, skyTex.Load(uint3(c2.x, c1.y, 0)).rgb, frac(c.x)),
			    lerp(skyTex.Load(uint3(c1.x, c2.y, 0)).rgb, skyTex.Load(uint3(c2, 0)).rgb, frac(c.x)), frac(c.y));
}

#endif
