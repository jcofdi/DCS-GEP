#ifndef DEFERRED_SHADOWS_HLSL
#define DEFERRED_SHADOWS_HLSL

#define FOG_ENABLE
#include "common/fog2.hlsl"
#include "common/samplers11.hlsl"
#include "enlight/materialParams.hlsl"
#include "common/dithering.hlsl"

#define USE_ROTATE_PCF 1
#define BASE_SHADOWMAP_SIZE 4096
#define BASE_SHADOWMAP_BIAS 0.0004

// Fixed world-space width (in meters) for the dither transition zone between
// adjacent shadow cascades. Using a fixed width instead of a percentage of the
// split distance prevents visible banding when cascade splits are pushed far out.
// 5m is wide enough for smooth IGN dithering but narrow enough to be invisible
// at any altitude.
static const float DITHER_WIDTH = 5.0;

#if USE_ROTATE_PCF
float rnd(float2 xy) {
	return frac(sin(dot(xy, float2(12.9898, 78.233))) * 43758.5453);
}
#endif

float SampleShadowMap(float3 wPos, float NoL, uniform uint idx, uniform bool usePCF, uniform uint samplesMax, uniform bool useTreeShadow, uniform float r = 3.0)
{
	float bias = BASE_SHADOWMAP_BIAS * BASE_SHADOWMAP_SIZE / ShadowMapSize;

	float4 shadowPos = mul(float4(wPos, 1.0), ShadowMatrix[idx]);
	float3 shadowCoord = shadowPos.xyz / shadowPos.w;
	float acc = cascadeShadowMap.SampleCmpLevelZero(gCascadeShadowSampler, float3(shadowCoord.xy, 3 - idx), saturate(shadowCoord.z) + bias);

	if (useTreeShadow) {
		float4 projPos = mul(float4(wPos, 1.0), gViewProj);
		float dp = cascadeShadowMap.SampleLevel(gPointClampSampler, float3(shadowCoord.xy, 3 - idx), 0).x;
		float4 p = mul(float4(shadowPos.xy, dp, 1.0), ShadowMatrixInv[idx]);
		float d = dot(p.xyz / p.w - wPos, gSunDir);
		return max(exp(-d * 0.5), acc);
	}

	if (usePCF) {
		static const float incr = 3.1415926535897932384626433832795 *(3.0 - sqrt(5.0));
		const uint count = min(16, samplesMax);

		const float radius = r / ShadowMapSize;

		float offs = 1.0 / count; 
		float angle = 0, offset = 0;;
#if USE_ROTATE_PCF
		float4 projPos = mul(float4(wPos, 1.0), gViewProj);
		angle += rnd(projPos.xy / projPos.w);  // pseudo-random rotation — sin-hash is correct here
#endif
		[unroll(count)]
		for (uint i = 1; i < count; ++i) {
			offset += offs;
			angle += incr;
			float s, c;
			sincos(angle, s, c);
			float2 delta = float2(c, s) * (offset * radius);
			acc += cascadeShadowMap.SampleCmpLevelZero(gCascadeShadowSampler, float3(shadowCoord.xy + delta, 3 - idx), saturate(shadowCoord.z) + bias * (1 + r * offset));
		}
		acc /= count;
	} 
	return saturate( min(NoL * 10, acc) );
}

//return shadow + AO
float2 SampleShadowClouds(float3 pos)
{
	if(gUseVolumetricCloudsShadow>0)
	{
		float3 uvw = pos * gCloudVolumeScale + gCloudVolumeOffset;
		float2 s = cloudsShadowTex3D.SampleLevel(gBilinearClampSampler, uvw.xzy, 0).yx;
		if(uvw.y>1) s = 1;
//		s.x *= s.x;   // squared shadow power. Replace with adjustable power control
		s.x = pow(s.x, 1.5);
		s.x = min(s.x, getFogTransparency(ProjectOriginSpaceToSphere(pos).y + gOrigin.y, gSunDir.y, 400000.0f));
		return s;
	}
	else
	{
		float4 cldShadowPos = mul(float4(pos + gOrigin.xyz, 1.0), gCloudShadowsProj);
		float shadow = cloudsShadowTex.SampleLevel(gCloudsShadowSampler, cldShadowPos.xy / cldShadowPos.w, 0).r;
		shadow = lerp(shadow, 1.0, smoothstep(gCloudsLow, gCloudsHigh, pos.y));
		return float2(shadow, 1);
	}
}

float SampleShadowCascade(float3 wPos, float depth, float3 normal, uniform bool usePCF, uniform bool useNormalBias, uniform bool useTreeShadow=false, uniform uint samplesMax=32, uniform bool useOnlyFirstMap = false) {	// normal in world space

	float NoL = 1;
	if (useNormalBias) {
		NoL = dot(normal, gSunDir.xyz);
		if (NoL < 0)
			return 0;
	}

	if (useOnlyFirstMap) {
		return SampleShadowMap(wPos, NoL, ShadowFirstMap, usePCF, samplesMax, false);
	} else {
		// === IGN dither for cascade transitions ===
		// Project to screen space once for the noise coordinate
		float4 projPos = mul(float4(wPos, 1.0), gViewProj);
		float2 screenPos = (projPos.xy / projPos.w) * 0.5 + 0.5;
		float2 pixelPos = screenPos * gSreenParams.xy;
		float noise = interleavedGradientNoise(pixelPos);

		// Cascade 0 (farthest = highest depth value boundary)
		if (depth > ShadowDistance[0])
			return SampleShadowMap(wPos, NoL, 0, usePCF, samplesMax, useTreeShadow);

		// --- Dithered transition: Cascade 0 -> 1 ---
		float z01 = ShadowDistance[0] + DITHER_WIDTH;
		if (depth > ShadowDistance[1]) {
			if (depth < z01) {
				float t = (depth - ShadowDistance[0]) / DITHER_WIDTH;
				return (noise > t)
					? SampleShadowMap(wPos, NoL, 0, usePCF, samplesMax, useTreeShadow)
					: SampleShadowMap(wPos, NoL, 1, usePCF, samplesMax, useTreeShadow);
			}
			return SampleShadowMap(wPos, NoL, 1, usePCF, samplesMax, useTreeShadow);
		}

		// --- Dithered transition: Cascade 1 -> 2 (formation flight critical zone) ---
		float z12 = ShadowDistance[1] + DITHER_WIDTH;
		if (depth > ShadowDistance[2]) {
			if (depth < z12) {
				float t = (depth - ShadowDistance[1]) / DITHER_WIDTH;
				return (noise > t)
					? SampleShadowMap(wPos, NoL, 1, usePCF, samplesMax, useTreeShadow)
					: SampleShadowMap(wPos, NoL, 2, usePCF, samplesMax, useTreeShadow, 2.5);
			}
			return SampleShadowMap(wPos, NoL, 2, usePCF, samplesMax, useTreeShadow, 2.5);
		}

		// --- Dithered transition: Cascade 2 -> 3 ---
		float z23 = ShadowDistance[2] + DITHER_WIDTH;
		if (depth > ShadowDistance[3]) {
			if (depth < z23) {
				float t = (depth - ShadowDistance[2]) / DITHER_WIDTH;
				float hiRes = SampleShadowMap(wPos, NoL, 2, usePCF, samplesMax, useTreeShadow, 2.5);
				float loRes;
				if (useTreeShadow)
					loRes = max(SampleShadowMap(wPos, NoL, 3, usePCF, samplesMax, true, 2), smoothstep(ShadowDistance[2], ShadowDistance[3], depth));
				else
					loRes = max(SampleShadowMap(wPos, NoL, 3, usePCF, samplesMax, false, 2), smoothstep(ShadowCascadeFadeDepth, ShadowDistance[3], depth));
				return (noise > t) ? hiRes : loRes;
			}

			// Past the dither zone — cascade 3 with its existing smoothstep fade
			if (useTreeShadow)
				return max(SampleShadowMap(wPos, NoL, 3, usePCF, samplesMax, true, 2), smoothstep(ShadowDistance[2], ShadowDistance[3], depth));
			else
				return max(SampleShadowMap(wPos, NoL, 3, usePCF, samplesMax, false, 2), smoothstep(ShadowCascadeFadeDepth, ShadowDistance[3], depth));
		}
		return 1;
	}
}	

float SampleShadowMapVertex(float3 wPos, uniform uint idx) {

	float bias = 0.0025;

	float4 shadowPos = mul(float4(wPos, 1.0), ShadowMatrix[idx]);
	float3 shadowCoord = shadowPos.xyz / shadowPos.w;
	return cascadeShadowMap.SampleCmpLevelZero(gCascadeShadowSampler, float3(shadowCoord.xy, 3 - idx), saturate(shadowCoord.z) + bias);
}

float SampleShadowCascadeVertex(float3 wPos, float depth) {

	[unroll]
	for (uint i = 0; i < 4; ++i) 
		if (depth > ShadowDistance[i])
			return SampleShadowMapVertex(wPos, i);

	return 1;
}

float SampleShadow(float4 ippos, float3 normal, uniform bool bPCF = true, uniform bool useNormalBias = true) {
	return SampleShadowCascade(ippos.xyz, ippos.w, normal, bPCF, useNormalBias);
}

float SampleShadowTerrain(float4 ippos, float3 normal, uniform bool bPCF = true, uniform bool useNormalBias = true) {
	return 1 - ((1 - SampleShadow(ippos, normal, bPCF, useNormalBias)) * saturate(FlatShadowDistance[0]));
}

#endif