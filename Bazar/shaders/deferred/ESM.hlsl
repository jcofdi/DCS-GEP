#ifndef ESM_HLSL
#define ESM_HLSL

#include "enlight/materialParams.hlsl"

static const float esm_factor = 0.8;

float linstep(float a, float b, float v) {
	return saturate((v - a) / (b - a));
}

float ESM(float depth) {
	return (exp(esm_factor * depth) - 1) / (exp(esm_factor) - 1);
}

float ESM_Shadow(float moment, float depth) {
	float occluder = moment * (exp(esm_factor) - 1) + 1;
	float receiver = exp(-esm_factor * depth);
	float esm = saturate(occluder * receiver);
	return linstep(0.99, 1.0, esm);
}

float VSM(float depth) {
	return depth*depth;
}

float VSM_Shadow(float2 moments, float depth) {
	const float k0 = 0.00001;
	const float k1 = 0.9;	// 0.2 .. 0.8 to supress light bleeding
	float variance = moments.y - (moments.x*moments.x);
	variance = max(variance, k0);

	float d = moments.x - depth;
	float pMax = variance / (variance + d * d);
	pMax = linstep(k1, 1.0, pMax); 

	return depth <= moments.x ? 1.0 : pMax;
};

float terrainShadowsSSM(float4 pos) {
	float4 shadowPos = mul(pos, gTerrainShadowMatrix);
	float3 shadowCoord = shadowPos.xyz / shadowPos.w;
	float bias = 0.0001;
	return terrainShadowMap.SampleCmpLevelZero(gCascadeShadowSampler, shadowCoord.xy, saturate(shadowCoord.z) + bias);
}


float3 terrainShadowsUVW(float4 pos)
{
	float4 shadowPos = mul(pos, gTerrainShadowMatrix);
	return shadowPos.xyz / shadowPos.w;
}

float terrainShadowsSample(float3 shadowCoord) {
	float val = terrainESM.SampleLevel(gTrilinearWhiteBorderSampler, shadowCoord.xy, 0).x;
	float z = 1 - shadowCoord.z;
	float sMax = linstep(0.95, 1.0, z);
	return max(sMax, ESM_Shadow(val, z));
}

float terrainShadows(float4 pos) {
	float3 uvw = terrainShadowsUVW(pos);
	return terrainShadowsSample(uvw);
}


// ═══════════════════════════════════════════════════════════════════════════
// [MOD] Secondary shadow map (spotlight) PCF + PCSS -- v4
//
// v1-v3: PCF replacement for stock single-tap spotlight shadows.
//        Fixed stair-stepping, shadow acne, matched cascade bias model,
//        screen-space noise for spiral rotation.
//
// v4: Adds depth-ratio PCSS for physically-based penumbra softening.
//
//   Spotlights use perspective projection, so shadow-space depth is
//   proportional to 1/distance_from_light.  The ratio of blocker depth
//   to receiver depth directly encodes the geometric penumbra factor:
//
//     penumbraRatio = blockerDepth / receiverDepth - 1.0
//
//   This requires no inverse matrix, no light position, no shadow map
//   resolution -- just two depth values.  Multiply by a constant
//   representing the light source's angular size in shadow UV space
//   and you have the penumbra width.
//
//   Contact shadows (ratio near zero) stay razor sharp.  Shadows far
//   from their caster produce physically wider penumbrae.
//
//   The max clean radius is derived from the tap count, same as cascade
//   PCSS: maxR_UV = sqrt(taps * 4 / pi) / estimatedResolution.
// ═══════════════════════════════════════════════════════════════════════════

// Master toggle for spotlight PCSS.  Set to 0 for fixed-radius PCF only.
#define SPOT_PCSS_ENABLE 1

// Number of PCF taps for spotlight shadows.
#define SECONDARY_SSM_SAMPLES 8

// Minimum PCF filter radius in shadow UV space.  This is the fixed-radius
// floor -- the smallest the filter can be, regardless of PCSS.
// At 2048 resolution, 0.00055 is approx 1.1 texels.  Dissolves stair-
// stepping at contact without over-softening.
#define SECONDARY_SSM_FILTER_RADIUS 0.00055

// Base depth bias and per-tap escalation, matching cascade conventions.
#define SECONDARY_SSM_BIAS 0.0008
#define SECONDARY_SSM_BIAS_SLOPE 3.0

// ── PCSS parameters ─────────────────────────────────────────────────────

// Light source angular size in shadow UV space.  Controls how quickly
// penumbrae grow with blocker-to-receiver separation.
//
// Physically, a 30cm deck flood at 10m subtends ~0.03 rad.  In the
// spotlight's shadow projection, this maps to a fraction of the UV
// range depending on the spot's FOV.  A spot with 90-degree FOV maps
// ~1.57 rad to [0,1] UV, so 0.03 rad ≈ 0.019 UV.
//
// Tuning: increase for softer penumbrae (larger apparent light source),
// decrease for harder shadows (smaller point-like source).
// 0.02 is a reasonable physical starting point for carrier deck floods.
#define SPOT_PCSS_LIGHT_SIZE 0.02

// Estimated secondary shadow map resolution.  Used only to compute the
// max clean PCF radius from tap count.  Empirically confirmed at 2048.
#define SPOT_PCSS_MAP_SIZE 2048.0

// Minimum depth ratio below which PCSS is skipped.  Prevents depth
// quantization noise from triggering false penumbrae on flat surfaces.
#define SPOT_PCSS_MIN_RATIO 0.002


// Screen-space noise for per-pixel spiral rotation, matching
// SampleShadowMap in shadows.hlsl.
float secondarySSM_rnd(float2 xy) {
	return frac(sin(dot(xy, float2(12.9898, 78.233))) * 43758.5453);
}

float secondarySSM(float4 pos, uniform uint idx) {

	float4 shadowPos = mul(pos, gSecondaryShadowmapMatrix[idx]);
	float3 shadowCoord = shadowPos.xyz / shadowPos.w;

	// ── Per-pixel rotation via screen-space hash ────────────────────
	float4 clipPos = mul(float4(pos.xyz, 1.0), gViewProj);
	float noise = secondarySSM_rnd(clipPos.xy / clipPos.w);

	// ── PCSS: depth-ratio blocker search ────────────────────────────
	// Maximum clean radius from tap count (UV space).
	// sqrt(taps * 4 / pi) gives texels; divide by resolution for UV.
	static const float PI_VAL = 3.14159265;
	static const float maxCleanUV = sqrt((float)SECONDARY_SSM_SAMPLES * 4.0 / PI_VAL)
		/ SPOT_PCSS_MAP_SIZE;

	float filterRadius = SECONDARY_SSM_FILTER_RADIUS;

#if SPOT_PCSS_ENABLE
	// Read raw (non-compared) depth at the receiver's shadow coordinate.
	// This texel was just comparison-sampled on the first PCF tap's
	// location, so it is sitting in L1 cache.
	float blockerDepth = secondaryShadowMap.SampleLevel(
		gPointClampSampler,
		float3(shadowCoord.xy, idx), 0).x;

	float receiverDepth = shadowCoord.z;

	// DCS uses reversed-Z: larger depth = closer to light.
	// A blocker closer to the light has blockerDepth > receiverDepth.
	//
	// In reversed-Z perspective: depth ~ near / distance
	//   dist_blocker ~ 1 / blockerDepth
	//   dist_receiver ~ 1 / receiverDepth
	//   penumbraRatio = (dist_receiver - dist_blocker) / dist_blocker
	//                 = blockerDepth / receiverDepth - 1
	//
	// Positive when a blocker exists, zero at contact, grows with
	// blocker-to-receiver separation.  No inverse matrix needed.
	float depthRatio = blockerDepth / receiverDepth - 1.0;

	if (depthRatio > SPOT_PCSS_MIN_RATIO)
	{
		float penumbraUV = depthRatio * SPOT_PCSS_LIGHT_SIZE;

		// Clamp between floor (fixed PCF radius) and ceiling (what
		// the tap count can fill cleanly without dithering).
		filterRadius = clamp(penumbraUV, SECONDARY_SSM_FILTER_RADIUS, maxCleanUV);
	}
#endif // SPOT_PCSS_ENABLE

	// ── Golden-angle spiral PCF ─────────────────────────────────────
	static const float goldenAngle = 2.39996323;  // pi * (3 - sqrt(5))
	float angle = noise;
	static const float invSamples = 1.0 / (float)SECONDARY_SSM_SAMPLES;
	float spiralOffset = invSamples * 0.5 + noise * invSamples;

	float acc = 0.0;

	[unroll]
	for (uint i = 0; i < SECONDARY_SSM_SAMPLES; ++i)
	{
		float s, c;
		sincos(angle, s, c);

		float r = sqrt(spiralOffset) * filterRadius;
		float2 offset = float2(c, s) * r;

		// Per-tap escalating bias scales with the actual filter radius.
		// Wider penumbrae span more depth variation and need more bias.
		// Convert filterRadius from UV to approximate texel count for
		// bias scaling (same convention as cascade PCF).
		float tapBiasScale = filterRadius * SPOT_PCSS_MAP_SIZE;
		float tapBias = SECONDARY_SSM_BIAS
			* (1.0 + tapBiasScale * spiralOffset);

		acc += secondaryShadowMap.SampleCmpLevelZero(
			gCascadeShadowSampler,
			float3(shadowCoord.xy + offset, idx),
			saturate(shadowCoord.z) + tapBias);

		angle += goldenAngle;
		spiralOffset += invSamples;
	}
	acc *= invSamples;

	// ── Border fade (preserved from stock) ──────────────────────────
	float2 sp = saturate(shadowCoord.xy) * 2.0 - 1.0;
	float lf = dot(sp, sp);
	return lerp(acc, 1.0, lf * lf * lf);
}

#endif
