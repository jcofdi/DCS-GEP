#include "common/states11.hlsl"
#include "common/samplers11.hlsl"
#include "common/context.hlsl"
#include "common/stencil.hlsl"
#include "deferred/Decoder.hlsl"

float4	g_ColorBufferViewport;
float2	g_ColorBufferSize;

float LoadDepth(float2 uv) {
	return SampleMap(DepthMap, uv, 0).r;
}

uint LoadStencil(float2 uv) {
	return SampleMap(StencilMap, uv, 0).g;
}

float2 transformColorBufferUV(float2 uv) {
	return (uv*g_ColorBufferViewport.zw + g_ColorBufferViewport.xy)*g_ColorBufferSize;
}

bool isWater(uint materialID) {
	return (materialID & STENCIL_COMPOSITION_MASK) == STENCIL_COMPOSITION_WATER;
}

#define SSR_STATIC_NOISE 1
#define SSR_Depth DepthMap
#include "enlight/ssr.hlsl"
#define SSR_GetColor getPrevFrameColor
#include "enlight/ssr.hlsl"

static const float2 quad[4] = {
	float2(-1, -1), float2(1, -1),
	float2(-1, 1),	float2(1, 1),
};

struct VS_OUTPUT {
	float4 sv_pos:		SV_POSITION;
	float2 projPos:		TEXCOORD0;
};

VS_OUTPUT VS(uint vid: SV_VertexID) {
	VS_OUTPUT o;
	o.sv_pos = float4(quad[vid], 0, 1);
	o.projPos = o.sv_pos.xy;
	return o;
}

// Attempt to get temporal resolution on SSLR reflections
Texture2D prevReflection;

float4 PS_REFLECTION(VS_OUTPUT i, uniform bool usePrevHDRBuffer = false) : SV_TARGET0
{
    float2 uv = float2(i.projPos.x, -i.projPos.y)*0.5 + 0.5;
    float2 tuv = transformColorBufferUV(uv) + 0.5;

    uint matID = LoadStencil(tuv) & (STENCIL_COMPOSITION_MASK | 7);
    if (matID != (STENCIL_COMPOSITION_MODEL | 1)
#if !USE_COCKPIT_CUBEMAP
        && matID != STENCIL_COMPOSITION_COCKPIT
#endif
        )
        return float4(0, 0, 0, 0);
    float depth = LoadDepth(tuv);
    float4 NDC = float4(i.projPos.xy, depth, 1);

    float3 wsNormal = DecodeNormal(tuv, 0);

    float4 refl;
    if (usePrevHDRBuffer)
        refl = getSSR_getPrevFrameColor(NDC, wsNormal, 0.5);
    else
        refl = getSSR(NDC, wsNormal, 0.5);

    // ---- TEMPORAL ACCUMULATION TEST ----
    // Reproject current surface position into previous frame's screen space.
    // mixPrevFrame logic adapted from waterReflection.hlsl.
    float4 prevNDC = mul(NDC, gPrevFrameTransform);
    prevNDC.xy /= prevNDC.w;
    float2 puv = float2(prevNDC.x, -prevNDC.y) * 0.5 + 0.5;
    float4 prevRefl = prevReflection.SampleLevel(
        gTrilinearBlackBorderSampler, puv, 0);

    // Disocclusion detection: if reprojected UV moved far in NDC space,
    // the surface was likely occluded last frame. Reduce history weight.
    float factor = saturate(1 - distance(prevNDC.xy, NDC.xy/NDC.w) * 10);

    // Blend toward history. 0.85 is less aggressive than water's 0.9
    // to keep model reflections more responsive to camera movement.
    float w = 0.85 * saturate(prevRefl.w * factor);

    // If prevReflection is unbound, prevRefl = (0,0,0,0), w = 0,
    // and this returns the current frame's result unchanged.
    refl.rgb = max(0, lerp(refl.rgb, prevRefl.rgb, w));
    // ---- END TEMPORAL TEST ----

    return refl;
}

#define COMMON_PART 		SetVertexShader(CompileShader(vs_5_0, VS()));	\
							SetGeometryShader(NULL);						\
							SetComputeShader(NULL);							\
							SetDepthStencilState(disableDepthBuffer, 0);	\
							SetBlendState(disableAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);	\
							SetRasterizerState(cullNone);
		

technique10 Reflection {
    pass P0	
	{
		SetPixelShader(CompileShader(ps_5_0, PS_REFLECTION()));
		COMMON_PART
	}
	pass P1
	{
		SetPixelShader(CompileShader(ps_5_0, PS_REFLECTION(true)));
		COMMON_PART
	}
}

/////////////////////// filter mips

Texture2D sourceTex;
RWTexture2D<float4> targetTex;
float2 dims;

// Bilateral depth sensitivity for edge-aware filtering.
// Controls how aggressively depth discontinuities are preserved.
// Higher = sharper edges but less blur. Lower = softer, more like stock.
// At 5e7: raw Z difference of ~0.001 gives bilateralW ~0.95 (same surface),
// raw Z difference of ~0.005 gives bilateralW ~0.29 (different surface).
static const float BILATERAL_SENSITIVITY = 5e7;

float4 filterMip(float2 uv, float radius, uniform uint count) {

	static const float incr = 3.1415926535897932384626433832795 *(3.0 - sqrt(5.0));

	// Depth-aware bilateral filtering (Wronski / Guerrilla GDC 2014):
	// Read center pixel depth to reject spiral samples that cross depth
	// discontinuities. This prevents reflection color from bleeding across
	// object edges (e.g. reflected text ghosting onto adjacent surfaces).
	//
	// Uses the same depth UV transform as ssr.hlsl getDepth(). DepthSampler
	// is defined in ssr.hlsl with BORDER addressing (returns 0 out of bounds).
	// If DepthMap SRV is not bound during the compute dispatch, all reads
	// return 0, all dz = 0, all bilateralW = 1.0, and the filter degrades
	// gracefully to stock (non-bilateral) behavior.
	float2 centerDepthUV = uv * g_ColorBufferViewport.zw + g_ColorBufferViewport.xy;
#ifndef MSAA
	float centerZ = DepthMap.SampleLevel(DepthSampler, centerDepthUV, 0).x;
#else
	float centerZ = 0;
#endif

	float offs = 1.0 / count;
	float angle = 0, offset = 0;

	float4 acc = 0;
	float wSum = 0;

	[unroll(count)]
	for (uint i = 0; i < count; ++i) {
		offset += offs;
		angle += incr;
		float s, c;
		sincos(angle, s, c);
		float2 delta = float2(c, s) * (offset * offset * radius);
		float4 col = sourceTex.SampleLevel(ClampLinearSampler, uv + delta, 0);

		// Bilateral weight: Gaussian falloff on raw depth difference.
		// Raw Z works because nearby surfaces have similar Z values
		// while depth discontinuities produce large jumps regardless
		// of distance from camera.
#ifndef MSAA
		float2 sDepthUV = (uv + delta) * g_ColorBufferViewport.zw + g_ColorBufferViewport.xy;
		float sampleZ = DepthMap.SampleLevel(DepthSampler, sDepthUV, 0).x;
		float dz = centerZ - sampleZ;
		float bilateralW = exp(-dz * dz * BILATERAL_SENSITIVITY);
#else
		float bilateralW = 1.0;
#endif

		acc += float4(col.rgb * col.a, col.a) * bilateralW;
		wSum += bilateralW;
	}

	// RGB: alpha-premultiplied weighted average (bilateral cancels in ratio).
	// Alpha: normalize by bilateral weight sum (not raw count) to preserve
	// reflection intensity when edge samples are rejected.
	return float4(acc.rgb / max(acc.a, 0.0001), acc.a / max(wSum, 0.0001));

}

float4 psFilterMipBack(VS_OUTPUT i): SV_TARGET0 {
	float2 uv = float2(i.projPos.x, -i.projPos.y)*0.5 + 0.5;
	return sourceTex.SampleLevel(ClampLinearSampler, uv, 0);
}

[numthreads(16, 16, 1)]
void csFilterMip(uint3 id: SV_DispatchThreadID, uniform uint count) {
	const uint2 pixel = id.xy;
	targetTex[pixel] = filterMip((pixel + 0.5)/dims, 0.025, count);
}

technique10 FilterMipComp {
	pass P0 {
		SetComputeShader(CompileShader(cs_5_0, csFilterMip(64)));
		SetVertexShader(NULL);
		SetGeometryShader(NULL);
		SetPixelShader(NULL);
	}
}

BlendState mipAlphaBlend {
	BlendEnable[0] = TRUE;
	SrcBlend = INV_DEST_ALPHA;
	DestBlend = DEST_ALPHA;
	BlendOp = ADD;

//	SrcBlendAlpha = SRC_ALPHA;
//	DestBlendAlpha = INV_SRC_ALPHA;
//	BlendOpAlpha = ADD;

//	SrcBlendAlpha = INV_DEST_ALPHA;
//	DestBlendAlpha = DEST_ALPHA;
//	BlendOpAlpha = ADD;

	SrcBlendAlpha = ONE;
	DestBlendAlpha = ZERO;
	BlendOpAlpha = ADD;
	RenderTargetWriteMask[0] = 0x0f;
};


technique10 FilterMipBack {
	pass P0	{
		SetVertexShader(CompileShader(vs_5_0, VS()));
		SetPixelShader(CompileShader(ps_5_0, psFilterMipBack()));
		SetGeometryShader(NULL);
		SetComputeShader(NULL);
		SetDepthStencilState(disableDepthBuffer, 0);
		SetBlendState(mipAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);
		SetRasterizerState(cullNone);
	}
}
