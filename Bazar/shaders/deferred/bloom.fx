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

SamplerState gBilinearBorderSampler {
    Filter = MIN_MAG_MIP_LINEAR;
    AddressU = BORDER;
    AddressV = BORDER;
    BorderColor = float4(0, 0, 0, 0);
};

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
    // Extended Reinhard with hue preservation
    // Compresses extreme HDR values before they enter the
    // downsample pyramid, limiting halo energy at the source
    // while preserving color ratios and moderate dynamic range.
    // whitePoint: bloom values below this pass with gentle rolloff,
    // values above converge toward it.
    static const float whitePoint = 10.0;
    float lum = dot(color, float3(0.2126, 0.7152, 0.0722));
    float mapped = lum * (1.0 + lum / (whitePoint * whitePoint)) / (1.0 + lum);
    color *= mapped / max(lum, 1e-6);
    return color;
}

float3 thresholdMap(float3 color)
{
	return thresholdMap(color, getLinearExposure(getAvgLuminanceClamped()), bloomThreshold);
}

float3 PS_ThresholdMap(const VS_OUTPUT i, uniform bool modeNVG): SV_TARGET0 // threshold and downsample 2х
{
	const uint2 offs[4] = { {0, 0}, {1, 0},	{0, 1}, {1, 1} };

	float3 result = 0;
	float weight = 0.0;
	uint2 uv = i.pos.xy*2;

	if (modeNVG) {
		return thresholdMap(SampleMap(ComposedMap, uv, 0).rgb * thresholdTint);
	} else {
		[unroll]
		for (int i = 0; i < 4; ++i)
		{
			//TODO: учесть MSAA?
			float3 color = thresholdMap(SampleMap(ComposedMap, uv + offs[i%4], 0).rgb);
			// float3 color = SampleMap(ComposedMap, uv + offs[i], 0).rgb;
			float w = rcp(color.r + color.g + color.b + 1e-5);
			result += color * w;
			weight += w;
		}
		return result / weight;
		// return thresholdMap(result / weight);
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

// GEP: Jimenez 13-tap downsample (SIGGRAPH 2014)

float3 PS_downsampling(const VS_OUTPUT i, uniform bool bWeighted): SV_TARGET0
{
	float2 t = 1.0 / srcDims;
	float2 uv = i.projPos.xy;

	// Outer ring: corners and cardinals at ±2 source texels
	float3 a  = bloomTexture.SampleLevel(gBilinearBorderSampler, uv + float2(-2, -2) * t, 0).rgb;
	float3 b  = bloomTexture.SampleLevel(gBilinearBorderSampler, uv + float2( 0, -2) * t, 0).rgb;
	float3 c  = bloomTexture.SampleLevel(gBilinearBorderSampler, uv + float2( 2, -2) * t, 0).rgb;
	float3 d  = bloomTexture.SampleLevel(gBilinearBorderSampler, uv + float2(-2,  0) * t, 0).rgb;
	float3 e  = bloomTexture.SampleLevel(gBilinearBorderSampler, uv,                       0).rgb;
	float3 f  = bloomTexture.SampleLevel(gBilinearBorderSampler, uv + float2( 2,  0) * t, 0).rgb;
	float3 g  = bloomTexture.SampleLevel(gBilinearBorderSampler, uv + float2(-2,  2) * t, 0).rgb;
	float3 h  = bloomTexture.SampleLevel(gBilinearBorderSampler, uv + float2( 0,  2) * t, 0).rgb;
	float3 i2 = bloomTexture.SampleLevel(gBilinearBorderSampler, uv + float2( 2,  2) * t, 0).rgb;

	// Inner ring: half-texel offsets (bilinear covers 2x2 each)
	float3 j  = bloomTexture.SampleLevel(gBilinearBorderSampler, uv + float2(-1, -1) * t, 0).rgb;
	float3 k  = bloomTexture.SampleLevel(gBilinearBorderSampler, uv + float2( 1, -1) * t, 0).rgb;
	float3 l  = bloomTexture.SampleLevel(gBilinearBorderSampler, uv + float2(-1,  1) * t, 0).rgb;
	float3 m  = bloomTexture.SampleLevel(gBilinearBorderSampler, uv + float2( 1,  1) * t, 0).rgb;

	return e * 0.125
	     + (a + c + g + i2) * 0.03125
	     + (b + d + f + h)  * 0.0625
	     + (j + k + l + m)  * 0.125;
}

// GEP: 3x3 tent filter for bloom layer upsampling
float3 sampleBloomTent(Texture2D<float4> tex, float2 uv)
{
	float w, h;
	tex.GetDimensions(w, h);
	float2 t = 1.0 / float2(w, h);

	float3 a = tex.SampleLevel(gBilinearClampSampler, uv + float2(-1, -1) * t, 0).rgb;
	float3 b = tex.SampleLevel(gBilinearClampSampler, uv + float2( 0, -1) * t, 0).rgb;
	float3 c = tex.SampleLevel(gBilinearClampSampler, uv + float2( 1, -1) * t, 0).rgb;
	float3 d = tex.SampleLevel(gBilinearClampSampler, uv + float2(-1,  0) * t, 0).rgb;
	float3 e = tex.SampleLevel(gBilinearClampSampler, uv,                       0).rgb;
	float3 f = tex.SampleLevel(gBilinearClampSampler, uv + float2( 1,  0) * t, 0).rgb;
	float3 g = tex.SampleLevel(gBilinearClampSampler, uv + float2(-1,  1) * t, 0).rgb;
	float3 h2 = tex.SampleLevel(gBilinearClampSampler, uv + float2( 0,  1) * t, 0).rgb;
	float3 i = tex.SampleLevel(gBilinearClampSampler, uv + float2( 1,  1) * t, 0).rgb;

	return e * 0.25 + (b + d + f + h2) * 0.125 + (a + c + g + i) * 0.0625;
}

float3 sampleBloomWide(Texture2D<float4> tex, float2 uv)
{
	float w, h;
	tex.GetDimensions(w, h);
	float2 t = 1.0 / float2(w, h);

	float3 a  = tex.SampleLevel(gBilinearClampSampler, uv + float2(-2, -2) * t, 0).rgb;
	float3 b  = tex.SampleLevel(gBilinearClampSampler, uv + float2( 0, -2) * t, 0).rgb;
	float3 c  = tex.SampleLevel(gBilinearClampSampler, uv + float2( 2, -2) * t, 0).rgb;
	float3 d  = tex.SampleLevel(gBilinearClampSampler, uv + float2(-2,  0) * t, 0).rgb;
	float3 e  = tex.SampleLevel(gBilinearClampSampler, uv,                       0).rgb;
	float3 f  = tex.SampleLevel(gBilinearClampSampler, uv + float2( 2,  0) * t, 0).rgb;
	float3 g  = tex.SampleLevel(gBilinearClampSampler, uv + float2(-2,  2) * t, 0).rgb;
	float3 h2 = tex.SampleLevel(gBilinearClampSampler, uv + float2( 0,  2) * t, 0).rgb;
	float3 i  = tex.SampleLevel(gBilinearClampSampler, uv + float2( 2,  2) * t, 0).rgb;
	float3 j  = tex.SampleLevel(gBilinearClampSampler, uv + float2(-1, -1) * t, 0).rgb;
	float3 k  = tex.SampleLevel(gBilinearClampSampler, uv + float2( 1, -1) * t, 0).rgb;
	float3 l  = tex.SampleLevel(gBilinearClampSampler, uv + float2(-1,  1) * t, 0).rgb;
	float3 m  = tex.SampleLevel(gBilinearClampSampler, uv + float2( 1,  1) * t, 0).rgb;

	return e * 0.125
	     + (a + c + g + i) * 0.03125
	     + (b + d + f + h2) * 0.0625
	     + (j + k + l + m) * 0.125;
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

	return float3(1,0,0);
}

float3 PS_sum(const VS_OUTPUT i, uniform int count): SV_TARGET0
{
    float2 uv = i.projPos.xy;

    static const float tailWeight = 0.0075;
    static const float falloff    = 1.06;
    static const float tintLum    = 1; // tune per visual preference

    float w5 = tailWeight;
    float w4 = w5 * falloff;
    float w3 = w4 * falloff;
    float w2 = w3 * falloff;
    float w1 = w2 * falloff;
    float w0 = 1.0 - (w1+w2+w3+w4+w5);

    float3 result = bloomLayer0.SampleLevel(gBilinearClampSampler, uv, 0).rgb * w0;
    result += bloomLayer1.SampleLevel(gBilinearClampSampler, uv, 0).rgb * w1;

    if(count>2) result += sampleBloomTent(bloomLayer2, uv) * w2;
    if(count>3) result += sampleBloomTent(bloomLayer3, uv) * w3;
    if(count>4) result += sampleBloomWide(bloomLayer4, uv) * w4;
    if(count>5) result += sampleBloomWide(bloomLayer5, uv) * w5;

    return result * tintLum;
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
