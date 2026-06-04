#ifndef DECODER_HLSL
#define DECODER_HLSL

#include "deferred/deferredCommon.hlsl"
#include "deferred/decoderCommon.hlsl"
#include "deferred/GBuffer.hlsl"
#include "deferred/packNormal.hlsl"
#include "deferred/packColor.hlsl"
#include "deferred/packFloat.hlsl"

TEXTURE_2D_ARRAY(float4, GBufferMap);
TEXTURE_2D(float, DepthMap);
TEXTURE_2D(uint2, StencilMap);
#ifdef SEPARATE_NORMALS
	TEXTURE_2D(float2, Normals);
#endif

uint2 depthDims;

#define OLD_PACKING 1

#ifndef DEBUG_OVERRIDE_GBUFFER
	#define DEBUG_OVERRIDE_GBUFFER(baseColorSRGB, normal, aorms, emissive)
#endif

struct EncodedGBuffer
{
	float3  t0;     // .xy = color/emissive luma, .z = geoNormal Y sign
    float4  t1;
    float3  t2;     // .xy = roughness/metallic,  .z = geoNormal hemioct X
    float3  t3;     // .xy = AO/cavity,            .z = geoNormal hemioct Y
    float2  t4;

	uint	idx;
};

struct ComposerInput
{
	uint			stencil;
	float			depth;
	EncodedGBuffer	gbuffer;
	uint2			uv;
	float4			projPos;
	float3			wPos;
};

EncodedGBuffer SampleGBuffer(uint2 uv, uint msaaSample)
{
	EncodedGBuffer o;

#if OLD_PACKING
	#if defined(MSAA) && USE_SV_SAMPLEINDEX
		o.idx  = (msaaSample ^ uv.y) & 1;
		uint msaaSample2 = msaaSample + (1-(msaaSample & 1)*2);
	#else
		o.idx  = (uv.x ^ uv.y) & 1;
		uint x2 = uv.x + (1-(uv.x & 1)*2);
	#endif
	o.t1.xy		= SampleMapArray(GBufferMap, uv, 1, msaaSample).xy;
	o.t1.zw		= SampleMapArray(GBufferMap, uint2(x2, uv.y), 1, msaaSample).xy;
#else
	uint2 t1uv = uv;
	#if defined(MSAA) && USE_SV_SAMPLEINDEX
		o.idx  = (msaaSample ^ uv.y) & 1;
		uint msaaSample2 = msaaSample + (1-(msaaSample & 1)*2);
	#else
		o.idx = uv.y & 1;
		t1uv.x -= (uv.x & 1);
	#endif
	o.t1.xy		= SampleMapArray(GBufferMap, t1uv, 1, msaaSample).xy;
	o.t1.zw		= SampleMapArray(GBufferMap, uint2(t1uv.x+1, t1uv.y), 1, msaaSample).xy;
#endif

	o.t0 = SampleMapArray(GBufferMap, uv, 0, msaaSample).xyz;
    o.t2 = SampleMapArray(GBufferMap, uv, 2, msaaSample).xyz;
    o.t3 = SampleMapArray(GBufferMap, uv, 3, msaaSample).xyz;
#ifdef SEPARATE_NORMALS
	o.t4		= SampleMap(Normals, uv, msaaSample).xy;
#else
	o.t4		= SampleMapArray(GBufferMap, uv, 4, msaaSample).xy;
#endif
	return o;
}

float3 RestoreWorldPos(float depth, float2 projPos, uint msaaSample)
{
#ifdef MSAA
	projPos += MSAA_OFFSET[msaaSample] / depthDims;
#endif
	float4 pos = mul(float4(projPos, depth, 1), gViewProjInv);
	return pos.xyz / pos.w;
}

ComposerInput ReadComposerData(uint2 uv, float4 projPos, uint msaaSample)
{
	ComposerInput o;
	o.depth		= SampleMap(DepthMap, uv, msaaSample).r;
	o.stencil	= SampleMap(StencilMap, uv, msaaSample).g;
	o.gbuffer	= SampleGBuffer(uv, msaaSample);
	o.wPos		= RestoreWorldPos(o.depth, projPos.xy, msaaSample);
	o.uv		= uv;
	o.projPos	= projPos;
	return o;
}

float3 DecodeNormal(uint2 uv, int msaaSample)
{
#ifdef SEPARATE_NORMALS
	float2 t4 = SampleMap(Normals, uv, msaaSample).xy;
#else
	float2 t4 = SampleMapArray(GBufferMap, uv, 4, msaaSample).xy;
#endif
	float2 rm = SampleMapArray(GBufferMap, uv, 2, msaaSample).xy;

	float3 normal = normalize(unpackNormal(t4.xy * 2 - 1).xzy);
	normal.y = rm.x <= 0.5? normal.y : -normal.y;

	return normal;
}

float3 DecodeNormal(EncodedGBuffer i)
{
	float2 t4 = i.t4;
	float2 rm = i.t2;

	float3 normal = normalize(unpackNormal(t4.xy * 2 - 1).xzy);
	normal.y = rm.x <= 0.5? normal.y : -normal.y;

	return normal;
}

float3 DecodeGeometricNormal(EncodedGBuffer i)
{
    float3 gn = normalize(unpackNormal(float2(i.t2.z, i.t3.z) * 2 - 1).xzy);
    gn.y = i.t0.z > 0.5 ? gn.y : -gn.y;

    return gn;
}

float3 DecodeGeometricNormal(uint2 uv, int msaaSample)
{
    float  gnSign = SampleMapArray(GBufferMap, uv, 0, msaaSample).z;
    float  gnHemioctX = SampleMapArray(GBufferMap, uv, 2, msaaSample).z;
    float  gnHemioctY = SampleMapArray(GBufferMap, uv, 3, msaaSample).z;

    float3 gn = normalize(unpackNormal(float2(gnHemioctX, gnHemioctY) * 2 - 1).xzy);
    gn.y = gnSign > 0.5 ? gn.y : -gn.y;

    return gn;
}

bool DecodeGBuffer(EncodedGBuffer i, uint2 uv, uint msaaSample, out float3 Diffuse, out float3 Normal, out float4 aorms, out float3 emissive)
{
	Normal = DecodeNormal(i);

	float2 t0 = i.t0.xy;
	float2 t1[2] = {i.t1.xy, i.t1.zw};
	uint idx = i.idx;

	bool bValidEmissive = t0.y >= emissiveLumMin;

#if USE_MASK_IC
	t1[idx].xy   = bValidEmissive ? t1[idx].xy : t1[0];
	t1[1-idx].xy = bValidEmissive ? t1[1-idx].xy : float2(0, 0);
#endif

	Diffuse = decodeColorYCC( float3(t0.x, t1[idx].xy) );
	emissive = bValidEmissive ? decodeColorYCC( float3(t0.y, t1[1-idx].xy) ) : 0;

	emissive = any(emissive<-0.1)? 0 : max(0, emissive);

	emissive *= emissive * emissiveValueMax;

	aorms.xw = i.t3.xy;
    aorms.yz = i.t2.xy;

	aorms.y = unpackFloat1Bit(aorms.y);

	DEBUG_OVERRIDE_GBUFFER(Diffuse, Normal, aorms, emissive);

	return true;
}

bool DecodeGBuffer(float2 projPos, uint2 uv, int msaaSample, out float3 WPos, out float3 Diffuse, out float3 Normal, out float4 aorms, out float3 emissive)
{
	EncodedGBuffer gbuffer = SampleGBuffer(uv, msaaSample);
	float depth	= SampleMap(DepthMap, uv, msaaSample).r;
	WPos = RestoreWorldPos(depth, projPos, msaaSample);
	return DecodeGBuffer(gbuffer, uv, msaaSample, Diffuse, Normal, aorms, emissive);
}

void DecodeGBufferGrass(EncodedGBuffer i, uint2 uv, int msaaSample, out float3 Diffuse, out float3 Normal, out float Height, out float surfaceNoL)
{
	Normal = float3(i.t2.x, 0, i.t2.y);
	Diffuse = decodeColorYCC(float3(i.t0.x, i.t1.xy));
	surfaceNoL = i.t3.x;
	Height = i.t3.y;
}

float3 unpackWaterNormal(float2 packedNormal) {
	float3 n = unpackNormal(packedNormal * 2 - 1);
	return normalize(float3(n.x, -n.z, n.y));
}

float3 DecodeWaterNormal(uint2 uv, int msaaSample) {
#ifdef SEPARATE_NORMALS
	float2 t4 = SampleMap(Normals, uv, msaaSample).xy;
#else
	float2 t4 = SampleMapArray(GBufferMap, uv, 4, msaaSample).xy;
#endif
	return unpackWaterNormal(t4.xy);
}

// VV modified
void DecodeGBufferWater(EncodedGBuffer i, uint2 uv, int msaaSample, out float3 Normal, out float wLevel, out float foam, out float isWake, out float deepFactor, out float riverLerp) {
	wLevel	= i.t2.x;
	float scaled  = i.t2.y * 2048.0;
	isWake        = step(1024.0, scaled);
	float foamBin = max(0.0, scaled - isWake * 1029.0);
	foam          = saturate(foamBin / 1019.0);
	deepFactor = i.t3.x;
	riverLerp = i.t3.y;
	Normal = unpackWaterNormal(i.t4.xy);
}

#endif
