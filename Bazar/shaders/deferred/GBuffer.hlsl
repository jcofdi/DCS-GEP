#ifndef GBUFFER_HLSL
#define GBUFFER_HLSL

#include "common/context.hlsl"
#include "deferred/packNormal.hlsl"
#include "deferred/packColor.hlsl"
#include "deferred/packFloat.hlsl"
#include "deferred/deferredCommon.hlsl"

#define USE_SV_SAMPLEINDEX	0
#define USE_MASK_IC			1
#define USE_SEPARATE_AO		1
#define USE_MOTION_VECTORS	1

#if defined(MSAA) && USE_SV_SAMPLEINDEX
	#undef USE_MASK_IC
	#define USE_MASK_IC 0
#endif

struct GBuffer {
	float4 target0 : SV_TARGET0;
	float4 target1 : SV_TARGET1;
	float4 target2 : SV_TARGET2;
	float4 target3 : SV_TARGET3;

	float4 target4 : SV_TARGET4;

#if USE_MOTION_VECTORS
	float4 target5 : SV_TARGET5;
#endif
};

static const float4 MAX_SPECULAR = float4(100.0, 3.0, 1, 1);
static const float emissiveValueMax = 0.1;
static const float emissiveLumMin = 0.1 / 255.0;

float2 speculamapToRoughnessMetallic(float4 specularMap) {
	specularMap /= MAX_SPECULAR;
	float roughness = clamp((1-specularMap.y*2.3), 0.02, 0.99);
	float metallic = specularMap.z;
	return float2(roughness, metallic);
}

float2 packInterlaced(uint2 pidx, float2 v1, float2 v2) {
	uint idx = (pidx.x ^ pidx.y) & 1;
	return idx ? v2 : v1;
}

#if USE_MOTION_VECTORS
float2 calcMotionVector(float4 projPos, float4 prevProjPos) {
	float2 v = (prevProjPos.xy / prevProjPos.w - projPos.xy / projPos.w) * 0.5 * gTargetDims;
	return float2(v.x, -v.y);
}

float2 calcMotionVectorStatic(float4 projPos) {
	return calcMotionVector(projPos, mul(projPos, gPrevFrameTransform));
}
#endif

GBuffer BuildGBuffer(float2 sv_pos_xy,
#if USE_SV_SAMPLEINDEX
    uint sv_sampleIndex,
#endif
    float4 color, float3 normal, float4 aorms, float3 emissive,
#if USE_MOTION_VECTORS
    float2 motionVector,
#endif
    float normalBlendTreshold = 0.5,
    float3 geoNormal = float3(0, 0, 0)) {
	GBuffer o;

#if USE_SV_SAMPLEINDEX
	uint2 idx = uint2(uint(sv_pos_xy.x)*GetRenderTargetSampleCount()+sv_sampleIndex, sv_pos_xy.y);
#else
	uint2 idx = uint2(uint(sv_pos_xy.x), sv_pos_xy.y);
#endif

	emissive = sqrt( saturate(emissive * (1.0 / emissiveValueMax)) );

	float3 ec = encodeColorYCC(color.xyz);
	float3 ic = encodeColorYCC(emissive);

	bool bValidEmissive = ic.x >= emissiveLumMin;

	float normalAlpha = step(normalBlendTreshold, color.a);

	// Pack geometric normal into .z channels of target0, target2, target3.
    // If no geometric normal was provided (zero vector), fall back to
    // the authored normal so downstream consumers always get valid data.
    float3 gn = dot(geoNormal, geoNormal) > 0.5 ? normalize(geoNormal) : normal;
    float2 gnPacked = packNormal(float3(gn.xz, -abs(gn.y))) * 0.5 + 0.5;

    o.target0 = float4(ec.x, ic.x, gn.y > 0 ? 1.0 : 0.0, color.a);

	float2 c = packInterlaced(idx, ec.yz, ic.yz);
#if USE_MASK_IC
	o.target1 = float4(bValidEmissive ? c : ec.yz, 0, color.a);
#else
	o.target1 = float4(c, 0, color.a);
#endif

	aorms.y = packFloat1Bit(aorms.y, normal.y>0);
    o.target2 = float4(aorms.yz, gnPacked.x, color.a);

    o.target3 = float4(aorms.xw, gnPacked.y, color.a);

	o.target4 = float4(packNormal(float3(normal.xz, -abs(normal.y))) * 0.5 + 0.5, 0, normalAlpha);

#if USE_MOTION_VECTORS
	o.target5 = float4(motionVector, 0, color.a);
#endif
	return o;
}

struct GBufferWater {
	float4 target0 : SV_TARGET0;
	float4 target1 : SV_TARGET1;
	float4 target2 : SV_TARGET2;
	float4 target3 : SV_TARGET3;
};

// VV modified
GBufferWater BuildGBufferWater(float3 normal, float wLevel, float foamFFT, float foamWake, float deepFactor, float4 projPos, float riverLerp, float alpha) {
	GBufferWater o;
	static const float WAKE_THRESHOLD = 0.001;
	float foam       = saturate(foamFFT + foamWake);
	float isWake     = step(WAKE_THRESHOLD, foamWake);
	float foamBin    = floor(foam * 1019.0);
	float packedFoam = (isWake * 1029.0 + foamBin) / 2048.0;
	o.target0 = float4(wLevel, packedFoam, 0, alpha);
	o.target1 = float4(deepFactor, riverLerp, 0, alpha);
	o.target2 = float4(packNormal(float3(normal.xz, -abs(normal.y))) * 0.5 + 0.5, 0, alpha);

	o.target3 = float4(calcMotionVectorStatic(projPos), 0, alpha);
	return o;
}

#endif
