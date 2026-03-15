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
// [MOD] Secondary shadow map (spotlight) PCF replacement
//
//
// ═══════════════════════════════════════════════════════════════════════════

// Number of PCF taps for spotlight shadows.
// 8 gives excellent quality at negligible cost.  4 is a cheaper fallback
// if profiling shows pressure; 12–16 for ultra-smooth penumbrae.
#define SECONDARY_SSM_SAMPLES 16

// Filter radius in shadow UV space.  This is the approximate size of
// 1.5 texels at 1024² resolution (1.5/1024 ≈ 0.00146).  If the engine
// uses a different resolution, adjust proportionally:
//    512  → 0.0029
//   1024  → 0.00146  (default)
//   2048  → 0.00073
// The value is intentionally slightly larger than 1-texel to dissolve
// stair-steps without visibly softening contact shadows.
#define SECONDARY_SSM_FILTER_RADIUS 0.00050

float secondarySSM(float4 pos, uniform uint idx) {

	float4 shadowPos = mul(pos, gSecondaryShadowmapMatrix[idx]);
	float3 shadowCoord = shadowPos.xyz / shadowPos.w;

	float bias = 0.00015;
	float refDepth = saturate(shadowCoord.z) + bias;

	// ── Per-pixel noise from world position ─────────────────────────
	// We need a per-pixel value to rotate the sample disk so adjacent
	// pixels don't share the same tap pattern.  Screen-space derivatives
	// (ddx/ddy) are FORBIDDEN here because this function is called
	// inside a dynamic loop in CalculateDynamicLightingTiled().
	//
	// Instead we hash the shadow UV coordinates, which are unique per
	// pixel and per light.  This is cheap (two frac + dot) and produces
	// good spatial distribution.  TAA further smooths any residual noise.
	float noise = frac(52.9829189 * frac(dot(shadowCoord.xy, float2(443.8975, 397.2973))));

	// ── Golden-angle spiral PCF ─────────────────────────────────────
	static const float PI2 = 6.28318530;
	static const float goldenAngle = 2.39996323;  // π(3−√5)
	float angle = noise * PI2;
	static const float invSamples = 1.0 / (float)SECONDARY_SSM_SAMPLES;
	float spiralOffset = invSamples * 0.5 + noise * invSamples;

	float acc = 0.0;

	[unroll]
	for (uint i = 0; i < SECONDARY_SSM_SAMPLES; ++i)
	{
		float s, c;
		sincos(angle, s, c);

		// sqrt() converts uniform radial to uniform area distribution.
		float r = sqrt(spiralOffset) * SECONDARY_SSM_FILTER_RADIUS;
		float2 offset = float2(c, s) * r;

		acc += secondaryShadowMap.SampleCmpLevelZero(
			gCascadeShadowSampler,
			float3(shadowCoord.xy + offset, idx),
			refDepth);

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
