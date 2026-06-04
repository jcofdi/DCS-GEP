#ifndef DEFERRED_ATMOSPHERE_HLSL
#define DEFERRED_ATMOSPHERE_HLSL

#include "common/AmbientCube.hlsl"
#include "deferred/deferredCommon.hlsl"
#include "common/context.hlsl"
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
	float cloudsAO; // [MOD] FIX #12 — pass through for cloud-gated contrast correction
};

EnvironmentIrradianceSample SampleEnvironmentIrradianceApprox(float3 pos, float shadow = 1, float cloudsAO = 1)
{
	// [MOD] FIX #10 — Terrain-adaptive ground albedo.
	//
	// [ORIGINAL] const float3 surfaceDiffuseAlbedo = 0.2;
	// The hardcoded 0.2 neutral grey ignores terrain type entirely: aircraft
	// bellies received the same ground bounce over snow as over ocean.
	//
	// AmbientBottom (AmbientMap[3]) already contains terrain-rendered color
	// from the UpdateAmbientCubeBottomWall compute pass. We estimate the
	// effective ground albedo from its luminance, then reconstruct a tinted
	// albedo that preserves the terrain's chrominance (warm over desert,
	// blue over water, neutral over snow).
	//
	// The estimate is one frame behind (AmbientBottom comes from the previous
	// frame's compute pass) - this is acceptable for slowly-varying data.
	//
	// Clamp range [0.05, 0.60] prevents division artifacts at night (where
	// AmbientBottom → 0) and unrealistic energy amplification over snow
	// (real snow albedo ~0.8 but the cubemap bottom face captures a mix of
	// terrain, sky-copy remnant, and altitude-blended horizon at 0.7×, so
	// the raw ratio would overestimate).
	float bottomLum = dot(AmbientBottom, float3(0.2126, 0.7152, 0.0722));
	float topLum    = max(0.001, dot(AmbientTop, float3(0.2126, 0.7152, 0.0722)));
	float albedoEstimate = saturate(bottomLum / topLum);
	albedoEstimate = clamp(albedoEstimate, 0.05, 0.60);

	// Reconstruct tinted albedo: preserve AmbientBottom's chrominance (hue),
	// scale magnitude to the estimated albedo. Falls back to neutral 0.2
	// when bottom luminance is near zero (night / deep shadow).
	float3 surfaceDiffuseAlbedo = (bottomLum > 0.001)
		? AmbientBottom * (albedoEstimate / bottomLum)
		: 0.2;

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
	// [ORIGINAL] saturate(3.5 - 3.5*(cloudsAO*cloudsAO))
	// The original curve reached 100% desaturation at cloudsAO = 0.8 (light SCT),
	// removing all blue sky character even when ~80% of the hemisphere is clear sky.
	//
	// Boundary behavior: identity at cloudsAO=1.0 (clear sky), full desaturation
	// at cloudsAO=0.0 (dense overcast). No change to clear-sky or overcast scenes.
	float cloudOcclusion = saturate(1.0 - cloudsAO);
	float desatAmount = cloudOcclusion * (0.5 + 0.5 * cloudOcclusion);
	o.skyIrradiance = lerp(o.skyIrradiance, dot(o.skyIrradiance, 0.33333), desatAmount);

	// Cloud base diffuse fill - cloud occlusion isn't dark,
	// it transmits diffuse light. No thickness variable so have to tune.
	float cloudBaseFill = (1.0 - cloudsAO) * 0.75;
	o.skyIrradiance *= (1.0 + cloudBaseFill);

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

	// [MOD] FIX #9a — Sky chrominance correction from measured cube top.
	//
	// GetSkyIrradiance() is a pure atmosphere LUT tap with no cloud awareness.
	// Under overcast, it delivers dimmed blue when the actual sky is grey.
	// AmbientTop (cube face +Y) contains the rendered sky including clouds.
	//
	// When their chrominance agrees (clear sky): correction ≈ 0, preserving
	// ARPC spectral accuracy. When they diverge (overcast grey vs analytical
	// blue): pull analytical color toward measured. Luminance is untouched —
	// only chrominance is corrected.
	{
		float3 lumW = float3(0.2126, 0.7152, 0.0722);
		float skyLum = max(0.001, dot(o.skyIrradiance, lumW));
		float topLum = max(0.001, dot(AmbientTop, lumW));

		float3 skyChroma = o.skyIrradiance / skyLum;
		float3 topChroma = AmbientTop / topLum;

		// Chrominance distance: near zero when both blue (clear sky),
		// large when analytical is blue but measured is grey (overcast).
		float chromaDist = length(skyChroma - topChroma);
		float correction = saturate(chromaDist * 2.0);

		// Blend chrominance toward measured when they disagree.
		// Cap at 0.7 to retain some analytical influence even under
		// full disagreement — the Bruneton model's color isn't entirely
		// wrong under cloud, just biased.
		o.skyIrradiance = skyLum * lerp(skyChroma, topChroma, correction * 0.7);
	}
	o.surfaceIrradiance = surfaceDiffuseAlbedo * (sunIrradiance + o.skyIrradiance);
	o.cloudsAO = cloudsAO;
	return o;
}

// [MOD] FIX #12 — Cube-first nSquared with targeted corrections.
//
// The ambient cube is authoritative for brightness and chrominance — it is
// the only data source that sees actual weather, altitude, terrain, and
// cloud tops. Under clear sky, golden hour, altitude inversion, and all
// non-cloud conditions, cube top and bottom pass through unmodified.
//
// Four targeted corrections address known cube defects:
//
// 1) SUN-SIDE ATTENUATION: The cubemap renders the full sky including
//    sun-brightened Mie scatter on the sun-facing side. For specular
//    reflections this is correct, but diffuse ambient primarily fills
//    shadowed surfaces that by definition cannot see the sun direction.
//    The sun-facing wall is pulled toward the average of the other three
//    walls (what a shadowed surface actually sees). Gated by sun elevation
//    — below horizon, full twilight directionality is preserved.
//
// 2) SIDE WALL LUMINANCE: Mip 8 face averages conflate bright sky half
//    with dark ground half. Redistributed using 80:20 sky:ground weight.
//    Always active.
//
// 3) SIDE WALL CHROMINANCE: Distance Rayleigh haze correction. Pulled
//    toward top face when wall variance is low. Self-disables at golden
//    hour. Always active.
//
// 4) TOP/BOTTOM CONTRAST: Cloud-gated. Under cloud, cube sees dark cloud
//    bases that don't represent diffuse lighting through the layer.
//    Analytical contrast ratio (time-of-day aware), compressed by cloudsAO,
//    redistributes top/bottom luminance using side wall average as the
//    energy budget. Only active when cloudsAO < 1.0.
//
// nSquared evaluation (Valve/McTaggart 2004) on corrected faces.
//
// [REPLACES] FIX #7/7b and the two-pole analytical vertical lerp.
float3 SampleEnvironmentMapApprox(EnvironmentIrradianceSample eis, float3 normal, float roughness = 1.0)
{
	const float ny = dot(gSurfaceNormal, normal);
	float3 n = normal;
	float3 lumW = float3(0.2126, 0.7152, 0.0722);

	// Read cube faces into locals for correction
	float3 top    = AmbientTop;        // [2] +Y
	float3 bottom = AmbientBottom;     // [3] -Y
	float3 px     = AmbientMap[0].rgb; // +X
	float3 mx     = AmbientMap[1].rgb; // -X
	float3 pz     = AmbientMap[4].rgb; // +Z
	float3 mz     = AmbientMap[5].rgb; // -Z

	// === 1) SUN-SIDE ATTENUATION ===
	// Diffuse ambient primarily fills shadowed surfaces. Shadowed surfaces
	// cannot see the sun-side sky, so the sun-brightened wall over-represents
	// light that most ambient-dependent surfaces never receive. Pull each
	// wall toward the average of the other three proportional to how much
	// it faces the sun.
	//
	// Below horizon (gSunDir.y <= 0): no correction. Twilight/golden hour
	// directionality is preserved — the subtle warm/cool gradients at low
	// sun angles are the most visually important ambient color variation
	// and occur when sun contribution to wall brightness is minimal.
	//
	// Sun elevation ramp: 0° → 0 (off), ~15° → 0.5, ~25°+ → 1.0 (full).
	// Gradual onset avoids harsh transition at sunrise.
	float sunElevation = saturate(gSunDir.y * 2.5);

	if (sunElevation > 0.01)
	{
		// Project sun direction onto horizontal plane
		float3 sunHoriz = normalize(float3(gSunDir.x, 0.001, gSunDir.z));

		// How much each wall faces the sun [0..1]
		// +X normal = (1,0,0), -X = (-1,0,0), +Z = (0,0,1), -Z = (0,0,-1)
		float4 sunFacing = saturate(float4(
			sunHoriz.x,     // +X faces sun when sun is in +X direction
			-sunHoriz.x,    // -X faces sun when sun is in -X direction
			sunHoriz.z,     // +Z
			-sunHoriz.z     // -Z
		));

		// For each wall, compute average of the other three as fallback.
		// This represents what a shadowed surface actually sees from that
		// general direction — the non-sun-brightened sky.
		float3 wallSum = px + mx + pz + mz;
		float3 avgNotPx = (wallSum - px) * (1.0 / 3.0);
		float3 avgNotMx = (wallSum - mx) * (1.0 / 3.0);
		float3 avgNotPz = (wallSum - pz) * (1.0 / 3.0);
		float3 avgNotMz = (wallSum - mz) * (1.0 / 3.0);

		// Attenuate: sun-facing walls blend toward their non-sun average.
		// Walls perpendicular or opposite to sun are unaffected (sunFacing ≈ 0).
		px = lerp(px, avgNotPx, sunFacing.x * sunElevation);
		mx = lerp(mx, avgNotMx, sunFacing.y * sunElevation);
		pz = lerp(pz, avgNotPz, sunFacing.z * sunElevation);
		mz = lerp(mz, avgNotMz, sunFacing.w * sunElevation);
	}

	// === 2) HAZE VARIANCE CHECK (on sun-corrected walls, before luminance) ===
	float4 wallLums = float4(dot(px, lumW), dot(mx, lumW),
	                         dot(pz, lumW), dot(mz, lumW));
	float wallMean = dot(wallLums, 0.25);
	float4 wallDev = abs(wallLums - wallMean);
	float wallVariance = dot(wallDev, 0.25) / max(0.001, wallMean);

	float hazeCorrection = saturate(1.0 - wallVariance * 4.0);

	float topLum = max(0.001, dot(top, lumW));
	float3 topChroma = top / topLum;

	// === 3) SIDE WALL LUMINANCE CORRECTION ===
	float cubeTopLum = max(0.001, dot(top, lumW));
	float cubeBotLum = max(0.001, dot(bottom, lumW));

	float skyWeight = 0.80;
	float expectedSideLum = cubeTopLum * skyWeight + cubeBotLum * (1.0 - skyWeight);

	float pxLum = max(0.001, wallLums.x);
	float mxLum = max(0.001, wallLums.y);
	float pzLum = max(0.001, wallLums.z);
	float mzLum = max(0.001, wallLums.w);

	px *= expectedSideLum / pxLum;
	mx *= expectedSideLum / mxLum;
	pz *= expectedSideLum / pzLum;
	mz *= expectedSideLum / mzLum;

	// === 4) SIDE WALL CHROMINANCE HAZE CORRECTION ===
	float corrPxLum = max(0.001, dot(px, lumW));
	float corrMxLum = max(0.001, dot(mx, lumW));
	float corrPzLum = max(0.001, dot(pz, lumW));
	float corrMzLum = max(0.001, dot(mz, lumW));

	px = corrPxLum * lerp(px / corrPxLum, topChroma, hazeCorrection * 0.5);
	mx = corrMxLum * lerp(mx / corrMxLum, topChroma, hazeCorrection * 0.5);
	pz = corrPzLum * lerp(pz / corrPzLum, topChroma, hazeCorrection * 0.5);
	mz = corrMzLum * lerp(mz / corrMzLum, topChroma, hazeCorrection * 0.5);

	// === 5) CLOUD-GATED TOP/BOTTOM CONTRAST CORRECTION ===
	// Only active under cloud. Clear sky, above clouds, golden hour:
	// cube top and bottom pass through completely unmodified.
	float cloudInfluence = 1.0 - eis.cloudsAO;

	if (cloudInfluence > 0.01)
	{
		float sideAvgLum = max(0.001, dot(wallLums, 0.25));

		float skyPoleLum = max(0.001, dot(eis.skyIrradiance, lumW));
		float gndPoleLum = max(0.001, dot(eis.surfaceIrradiance, lumW));
		float analyticalContrast = skyPoleLum / (skyPoleLum + gndPoleLum) - 0.5;

		float effectiveRatio = 0.5 + analyticalContrast * eis.cloudsAO;

		float targetTopLum = sideAvgLum * 2.0 * effectiveRatio;
		float targetBotLum = sideAvgLum * 2.0 * (1.0 - effectiveRatio);

		top *= lerp(1.0, targetTopLum / cubeTopLum, cloudInfluence);
		bottom *= lerp(1.0, targetBotLum / cubeBotLum, cloudInfluence);
	}

	// === NSQUARED EVALUATION ON CORRECTED FACES ===
	float3 nSq = n * n;

	float3 faceX = (n.x >= 0) ? px : mx;
	float3 faceY = (n.y >= 0) ? top : bottom;
	float3 faceZ = (n.z >= 0) ? pz : mz;

	float3 irradiance = nSq.x * faceX
	                  + nSq.y * faceY
	                  + nSq.z * faceZ;

	return max(0, irradiance) + float3(1e-3, 1e-4, 1e-5) * ny;
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
	
	// [MOD] Cloud-aware inscatter correction.
	// Under overcast, the cloud layer filters the solar contribution to
	// the atmospheric column below it. Inscatter becomes spectrally
	// neutral (gray) and reduced in intensity. gCloudiness: 0 = clear,
	// 1 = full overcast. Delayed onset via smoothstep preserves correct
	// warm haze on scattered days; rapid transition through broken-to-
	// overcast matches the physical threshold where cloud diffusion
	// dominates the sub-cloud light field.
	float cloudFactor = smoothstep(0.4, 0.9, gCloudiness);
	float3 neutralInscatter = dot(inscatterColor, float3(0.2126, 0.7152, 0.0722));
	inscatterColor = lerp(inscatterColor, neutralInscatter, cloudFactor * 0.7);
	inscatterColor *= 1.0 - cloudFactor * 0.6;

	float3 result = color * transmittance + inscatterColor * gAtmIntensity;
	
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
	// Luminance-adaptive amplitude: 0.001 peak (per documentation range),
	// fading to zero below HDR luminance 0.01 where dither dominates signal.
	float _ditherLum = dot(result, float3(0.2126, 0.7152, 0.0722));
	float _ditherAmp = 0.001 * saturate(_ditherLum * 100.0);
	result = ditherAtmosphericHDR(result, pixelPos, _ditherAmp, gModelTime);
	// ========== END ATMOSPHERIC DITHERING ==========
	
	return result;
}

// Non-dithered path — original signature preserved for callers without pixel position
float3 atmApplyLinear(float3 v, float distance, float3 color)
{
	float3 transmittance;
	float3 cameraPos = gEarthCenter + heightHack*gSurfaceNormal;
	float3 inscatterColor = GetSkyRadianceToPoint(cameraPos, cameraPos + v*distance, 0.0/*shadow*/, gSunDir, transmittance);
	
	// [MOD] Cloud-aware inscatter correction (see atmApplyLinearDithered).
	float cloudFactor = smoothstep(0.4, 0.9, gCloudiness);
	float3 neutralInscatter = dot(inscatterColor, float3(0.2126, 0.7152, 0.0722));
	inscatterColor = lerp(inscatterColor, neutralInscatter, cloudFactor * 0.7);
	inscatterColor *= 1.0 - cloudFactor * 0.6;

	return color * transmittance + inscatterColor * gAtmIntensity;
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
