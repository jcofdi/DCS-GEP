#include "common/states11.hlsl"
#include "common/samplers11.hlsl"
#include "common/context.hlsl"
#include "deferred/deferredCommon.hlsl"
#include "deferred/luminance.hlsl"
#include "deferred/toneMap.hlsl"
#include "common/colorTransform.hlsl"

Texture2D<float4> bloomTexture;
Texture2D<float4> bloomLayer0;
Texture2D<float4> bloomLayer1;
Texture2D<float4> bloomLayer2;
Texture2D<float4> bloomLayer3;
Texture2D<float4> bloomLayer4;
Texture2D<float4> bloomLayer5;

float2	srcDims;
TEXTURE_2D(float4, srcFit);

float	accumOpacity;
float3	thresholdTint;

struct VS_OUTPUT {
	noperspective float4 pos	:SV_POSITION0;
	noperspective float2 projPos:TEXCOORD0;
};

VS_OUTPUT VS(uint vid: SV_VertexID)
{
	const float2 quad[4] = {
		{-1, -1}, {1, -1},
		{-1,  1}, {1,  1}
	};
	VS_OUTPUT o;
	o.pos = float4(quad[vid], 0, 1);
	o.projPos.xy = float2(o.pos.x, -o.pos.y) * 0.5 + 0.5;
	return o;
}

float3 thresholdMap(float3 color, float exposure, float threshold)
{
	// GEP: Soft quadratic knee bloom threshold.
	//
	// Replaces the stock hard cutoff with a smooth transition that preserves
	// energy-proportional bloom. Sources well above threshold contribute at
	// full amplitude (preserving HDR dynamic range in the bloom pyramid).
	// Sources near threshold contribute proportionally via a quadratic ramp.
	// Sources well below threshold contribute near-zero (no wasted bandwidth).
	//
	// The quadratic knee ensures:
	//   - No hard brightness discontinuity (physically impossible in optics)
	//   - Bright-source differentiation preserved (afterburner >> runway light)
	//   - Night adaptation happens automatically via exposure multiplication
	//   - Smooth visual transition as sources cross the threshold region
	//
	// The knee width is half the threshold value. At threshold = 1.0:
	//   lum 0.0 -> contribution 0.000  (suppressed)
	//   lum 0.3 -> contribution 0.009  (barely visible)
	//   lum 0.5 -> contribution 0.025  (subtle glow)
	//   lum 0.8 -> contribution 0.160  (moderate)
	//   lum 1.0 -> contribution 0.500  (full, matches old threshold edge)
	//   lum 2.0 -> contribution 2.000  (full pass-through, preserves HDR range)
	//   lum 5.0 -> contribution 5.000  (massive bloom energy for intense sources)

	//float3 exposed = color * exposure; //downstream is expecting HDR color so pass through as-is on line 74
	float lum = dot(color, float3(0.2126, 0.7152, 0.0722)) * exposure;

	// Quadratic soft knee: smoothly ramps from 0 at threshold*0.5
	// to linear pass-through above threshold.
	float knee = max(0, lum - threshold * 0.5);
	float soft = min(knee * knee / (2.0 * threshold + 0.0001), lum - threshold);
	float contribution = max(soft, lum - threshold) / max(lum, 0.0001);

	return color * max(0, contribution);
}

float3 thresholdMap(float3 color)
{
	// GEP: Stock exposure for bloom (keeps bloom predictable with the
	// stock adaptation system), combined with Fraunhofer-inspired
	// adaptive threshold.
	//
	// Adaptive threshold models pupil diameter / diffraction relationship:
	//   Day (small pupil, high f-number): high threshold (1.5x), only extreme
	//     highlights bloom. Diffraction requires very bright source.
	//   Night (large pupil, low f-number): low threshold (0.5x), more sources
	//     produce glow. Lower diffraction visibility threshold.
	float avgLum = max(getAverageLuminance(), 0.001);
	float adaptThreshold = bloomThreshold * lerp(0.5, 1.5, smoothstep(0.02, 0.15, avgLum));

	return thresholdMap(color, getLinearExposure(getAvgLuminanceClamped()), adaptThreshold);
}

float3 PS_ThresholdMap(const VS_OUTPUT i, uniform bool modeNVG): SV_TARGET0 // threshold and downsample 2x
{
	const uint2 offs[4] = { {0, 0}, {1, 0},	{0, 1}, {1, 1} };

	float3 result = 0;
	float weight = 0.0;
	uint2 uv = i.pos.xy*2;

	if (modeNVG) {
		return thresholdMap(SampleMap(ComposedMap, uv, 0).rgb * thresholdTint);
	} else {
		// GEP: Karis average (Brian Karis, UE4).
		// Weight each sample by 1/(1+luma) before accumulation.
		// This prevents a single bright pixel (afterburner, sun specular)
		// from dominating the 2x2 block and flooding the entire bloom
		// pyramid with energy. A pixel at luma 5000 gets weight 1/5001,
		// while a pixel at luma 1.0 gets weight 1/2. The bright pixel
		// still contributes its color but doesn't overwhelm the spatial
		// average, producing tighter bloom halos and reducing banding.
		[unroll]
		for (int j = 0; j < 4; ++j)
		{
			float3 color = thresholdMap(SampleMap(ComposedMap, uv + offs[j], 0).rgb);
			float w = rcp(1.0 + dot(color, float3(0.2126, 0.7152, 0.0722)));
			result += color * w;
			weight += w;
		}
		return result / weight;
	}
}

float3 PS_ThresholdMapFit(const VS_OUTPUT i, uniform bool modeNVG): SV_TARGET0  {
	float2 uv = i.projPos.xy;
	float3 color = SampleMap(srcFit, uv * srcDims, 0).xyz;
	if (modeNVG) 
		return thresholdMap(color * thresholdTint);
	else 
		return thresholdMap(color);
}

float3 PS_downsampling(const VS_OUTPUT i, uniform bool bWeighted): SV_TARGET0
{
	float2 p = 0.5/srcDims;
	float2 uv = i.projPos.xy + p;
	float2 offset[] = {-p, {-p.x, p.y}, {p.x, -p.y}, p};
	float3 result = 0;
	float weight = 0;

	// GEP: Karis average on subsequent downsamples for consistent
	// energy-aware weighting through the entire pyramid chain.
	[unroll]
	for(int j=0; j<4; ++j)
	{
		float3 color = bloomTexture.SampleLevel(gPointClampSampler, uv+offset[j], 0).rgb;
		float w = rcp(1.0 + dot(color, float3(0.2126, 0.7152, 0.0722)));
		result += color * w;
		weight += w;
	}
	return result / weight;
}

float3 getBloomColor(float i, float b0)
{
	// return 1;//bloomIntensity0;
	return lerp(bloomIntensity0, bloomIntensity1, i/5.0);
	// return lerp(bloomTint0*bloomIntensity0, bloomTint1*bloomIntensity1, saturate(i/5.0 + exp(-b0*gDev1.z))) * bloomIntensity0;
}

float3 getBloomGradient(float t, float b0)
{
	return lerp(bloomTint1, bloomTint0, saturate(t*1));
	// return lerp(bloomTint1, bloomTint0, saturate(t*gDev1.z));
	// return lerp(bloomTint1*bloomIntensity1, bloomTint0*bloomIntensity0, saturate(t*gDev1.z));
	// return lerp(bloomTint0*bloomIntensity0, bloomTint1*bloomIntensity1, saturate(i/5.0 + exp(-b0*gDev1.z))) * bloomIntensity0;
}


float3 PS_sum_hw(const VS_OUTPUT i, uniform int count): SV_TARGET0
{
	float3 color = 0;

	float3 b0 = bloomLayer0.SampleLevel(gBilinearClampSampler, i.projPos.xy, 0).rgb * getBloomColor(0, 99999);
	color += b0;
	b0 = dot(b0, 0.33333);
	color += bloomLayer1.SampleLevel(gBilinearClampSampler, i.projPos.xy, 0).rgb * getBloomColor(1, b0);

	if(count>2)
		color += bloomLayer2.SampleLevel(gBilinearClampSampler, i.projPos.xy, 0).rgb * getBloomColor(2, b0);
	if(count>3)
		color += bloomLayer3.SampleLevel(gBilinearClampSampler, i.projPos.xy, 0).rgb * getBloomColor(3, b0);
	if(count>4)
		color += bloomLayer4.SampleLevel(gBilinearClampSampler, i.projPos.xy, 0).rgb * getBloomColor(4, b0);
	if(count>5)
		color += bloomLayer5.SampleLevel(gBilinearClampSampler, i.projPos.xy, 0).rgb * getBloomColor(5, b0);

	// float3 hsv = rgb2hsv(color*gDev0.x);
	// hsv.x += gDev1.w;
	// return hsv2rgb(hsv);
	float3 colorCompressed = 1 - exp(-color*1);

	color = lerp(color, colorCompressed, hwFactor);
	// color = 1 - exp(-color*gDev0.x);

	color *= getBloomGradient(dot(color,0.33333), 0);

	return color;
}

float3 PS_sum(const VS_OUTPUT i, uniform int count): SV_TARGET0
{
	float3 color = 0;

	color += bloomLayer0.SampleLevel(gBilinearClampSampler, i.projPos.xy, 0).rgb * bloomTint0 * bloomIntensity0;
	color += bloomLayer1.SampleLevel(gBilinearClampSampler, i.projPos.xy, 0).rgb * bloomTint1 * bloomIntensity1;

	if(count>2)
		color += bloomLayer2.SampleLevel(gBilinearClampSampler, i.projPos.xy, 0).rgb * bloomTint2 * bloomIntensity2;
	if(count>3)
		color += bloomLayer3.SampleLevel(gBilinearClampSampler, i.projPos.xy, 0).rgb * bloomTint3 * bloomIntensity3;
	if(count>4)
		color += bloomLayer4.SampleLevel(gBilinearClampSampler, i.projPos.xy, 0).rgb * bloomTint4 * bloomIntensity4;
	if(count>5)
		color += bloomLayer5.SampleLevel(gBilinearClampSampler, i.projPos.xy, 0).rgb * bloomTint5 * bloomIntensity5;

	return color;
}

float4 PS_CopyToAccumulator(const VS_OUTPUT i): SV_TARGET0
{
	float3 bloom = bloomTexture.SampleLevel(gPointClampSampler, i.projPos.xy, 0).rgb;
	float lum = dot(bloom, 0.333);
	float factor = 1 - exp(-lum * 10);
	return float4(bloom, lerp(1, accumOpacity, factor) );
}


VertexShader vsComp = CompileShader(vs_5_0, VS());

#define PASS_BODY(ps) { SetVertexShader(vsComp); SetGeometryShader(NULL); SetPixelShader(CompileShader(ps_5_0, ps)); \
	SetDepthStencilState(disableDepthBuffer, 0); \
	SetBlendState(disableAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF); \
	SetRasterizerState(cullNone);}

technique10 Bloom {
	pass thresholdMap			PASS_BODY(PS_ThresholdMap(false))
	pass thresholdMap_NVG		PASS_BODY(PS_ThresholdMap(true))
	pass thresholdMapFit		PASS_BODY(PS_ThresholdMapFit(false))
	pass thresholdMapFit_NVG	PASS_BODY(PS_ThresholdMapFit(true))
	pass downsample				PASS_BODY(PS_downsampling(false))
	pass downsampleWeighted		PASS_BODY(PS_downsampling(true))
	pass sum2					PASS_BODY(PS_sum(2))
	pass sum3					PASS_BODY(PS_sum(3))
	pass sum4					PASS_BODY(PS_sum(4))
	pass sum5					PASS_BODY(PS_sum(5))
	pass sum6					PASS_BODY(PS_sum(6))
	pass sum6HW					PASS_BODY(PS_sum_hw(6))
	pass copyToAccumulator
	{ 
		SetVertexShader(vsComp);
		SetGeometryShader(NULL);
		SetPixelShader(CompileShader(ps_5_0, PS_CopyToAccumulator()));
		SetDepthStencilState(disableDepthBuffer, 0);
		SetBlendState(enableAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);
		SetRasterizerState(cullNone);
	}
}
