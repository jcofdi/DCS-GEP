#include "common/states11.hlsl"
#include "common/samplers11.hlsl"
#include "common/context.hlsl"
#include "common/bc.hlsl"
#include "deferred/deferredCommon.hlsl"
#include "deferred/colorGrading.hlsl"
// #define PLOT_TONEMAP_FUNCION
// #define PLOT_AVERAGE_LUMINANCE
// #define PLOT_HISTOGRAM
// #define DRAW_FOCUS
#include "deferred/toneMap.hlsl"
#include "deferred/calcAvgLum.hlsl"
#include "common/random.hlsl"
#include "common/stencil.hlsl"
#include "common/dithering.hlsl"

#include "deferred/Decoder.hlsl"

Texture2D<float4>	bloomTexture;//итоговый блум
Texture2D			lensDirtTex;

Texture3D colorGradingLUT;
//#define COCKPIT_EXP
float2	srcDims;
float2	brightnessContrast;

float3	filterColor;
float3	outputTint;
float	accumOpacity;
float	debugMult;

struct VS_OUTPUT {
	noperspective float4 pos	 : SV_POSITION0;
	noperspective float4 projPos : TEXCOORD0;
	noperspective float3 worldPos: TEXCOORD1;
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
	o.projPos.zw = o.projPos.xy * dcViewport.zw + dcViewport.xy;

	float4 wPos = mul(float4(o.pos.xy, 1, 1), gViewProjInv);
	o.worldPos = wPos / wPos.www;
	return o;
}

float Vignette(float2 uv, float q, float o) {
	//q = 0.65, o = 3.0
	float x = saturate(1 - distance(uv, 0.5) * q);
	return ( log( (o - 1.0/exp(o)) * x + 1.0/exp(o) ) + o ) / (log(o) + o);
}

float Vignette2(float2 uv, float q, float o) {
	uv *=  1.0 - uv.yx;
	float vig = uv.x * uv.y * 16.0;
	return pow(max(0, vig), o) * q + (1 - q);
}

float3 ColorGrade(float3 sourceColor, uint2 uv)
{
	// return sourceColor;
	return colorGradingLUT.SampleLevel(gTrilinearClampSampler, sourceColor*15.0/16.0 + 0.5/16.0, 0).rgb;
	// return ColorGrade_Cinecolor(sourceColor, float3(1, 0, 0));
	// return ColorGrade_Cinecolor(sourceColor, float3(1, 0.447, 0));
	// return ColorGrade_Technicolor_1(sourceColor);
	// return ColorGrade_Technicolor_2(sourceColor);
	// return ColorGrade_Technicolor_ThreeStrip(sourceColor, float3(1,0,0));
	// return ColorGrade_CGA(sourceColor, uv);
	// return ColorGrade_EGA(sourceColor, uv);
}

float3 LinearToScreenSpaceCustom(float3 color)
{
	return pow(abs(color), outputGammaInv);
}

float3 SampleSceneColor(float2 uv, uint idx, uniform uint pixelSize = 1)
{
	return SampleMap(ComposedMap, uv - (pixelSize>1 ? fmod(uv, pixelSize) : 0), idx).xyz;
}

float3 applyDitheringOnLowLuminance(uint2 pixel, float3 color, float lumMaxInv)
{
	float lum = dot(color, 0.333333);
	return color * lerp((0.9 + 0.2 * dither_ordered8x8(pixel)), 1, saturate(lum * lumMaxInv));
}

float3 ToneMapSample(const VS_OUTPUT i, uint idx, float3 sceneColor, uniform int tonemapOperator, uniform int flags = 0)
{
	uint2 uv = i.pos.xy;

	const uint pixelSize = 1;

	uint matID = uint(SampleMap(StencilMap, uv - (pixelSize>1 ? fmod(uv, pixelSize):0), idx).g) & STENCIL_COMPOSITION_MASK;
	float lum;

#ifdef COCKPIT_EXP
	if(matID == STENCIL_COMPOSITION_COCKPIT && 1){
		//lum = getAverageLuminanceCockpit();
		//lum *= 15;
		
		//lum = clamp(lum, 0.15, 100);
		float a = getAvgLuminanceClamped();
		float d = cockpitExposureClamp;
		//lum = clamp(lum, a*(1.0-d), a*(1.0+d));;
		//lum = a-0.3;
		//lum = a - d*0.35;
		lum = a*(1-d);
		//lum = lerp(lum, a, d);
	}
	else{
		lum = getAvgLuminanceClamped();
	}
#else
	lum = getAvgLuminanceClamped();
#endif

	float3 bloom = bloomTexture.SampleLevel(gBilinearClampSampler, i.projPos.zw, 0).rgb;
	float exposure = getLinearExposure(lum);

	// --- GEP: Sub-linear perceptual exposure compensation ---
	// The stock exposure (0.18 / avgLum) perfectly normalizes every scene
	// to the same display brightness. Human vision does not do this — bright
	// scenes appear brighter than dim ones even after adaptation.
	//
	// This applies a mild power-law correction so that high-luminance scenes
	// (sunny day) receive slightly more exposure and low-luminance scenes
	// (night, heavy weather) receive slightly less.
	//
	// The correction is applied HERE (not inside getLinearExposure) so that
	// the bloom threshold path in bloom.fx is unaffected — bloom still sees
	// the original exposure, preventing unwanted bloom increase on sunny days.
	//
	// Tuning: gepExposureExponent controls the strength.
	//   1.0  = no effect (stock behavior)
	//   0.90 = mild (~15% brighter at high lum, ~15% darker at low lum)
	//   0.85 = moderate
	//   0.80 = strong (probably too much — test carefully)
	//
	// The neutral point where this has zero effect is when avgLum ≈ 0.18
	// (the middle-gray key value). Above that, scenes get brighter; below, darker.
	{
		static const float gepExposureExponent = 0.80; // TUNE THIS
		// Ratio: how far is the scene luminance from middle gray?
		// At lum=0.18, ratio=1.0 and correction=1.0 (no change).
		// At lum=2.0 (bright sun), ratio≈11, correction≈1.27 (+0.35 EV).
		// At lum=0.01 (night), ratio≈0.056, correction≈0.75 (-0.4 EV).
		float ratio = lum / 0.18;
		float correction = pow(max(ratio, 0.001), 1.0 - gepExposureExponent);
		exposure *= correction;
	}

	if(hwFactor>0)//TODO remove
	{
		// float3 tint = gDev1.xyz;
		float3 tint = lerp(1, float3(0.8, 1, 1), hwFactor);
		tint *= 3.0 / (tint.x + tint.y + tint.z);
		sceneColor *= tint;
		// sceneColor = lerp(dot(sceneColor, 0.33333), sceneColor, gDev1.w) * tint;
		// sceneColor *= tint;
	}

	
	float3 linearColor = lerp(sceneColor, bloom, bloomLerpFactor) * exposure;
	
	if(whiteBalanceFactor>0)
	{
		linearColor /= lerp(1, AmbientWhitePoint, whiteBalanceFactor);
	}

	if(flags & TONEMAP_FLAG_DIRT_EFFECT)
	{
		float NoL = dot(gSunDir, normalize(i.worldPos.xyz - gCameraPos.xyz));
		float effectMask = 0.2 + 0.15 * pow(max(0, NoL), 10);//towards the Sun
		linearColor += lensDirtTex.SampleLevel(gBilinearClampSampler, i.projPos.xy, 0).rgb * bloom * effectMask;
	}

	if(vignetteFactor>0)
	{
		linearColor *= lerp(1, Vignette2(i.pos.xy / gSreenParams.xy, 0.35, 0.15), vignetteFactor);
	}
	
	//HDR -> LDR -> screen gamma space
	float3 screenColor;
	if(flags & TONEMAP_FLAG_CUSTOM_FILTER)
		linearColor = dot(linearColor, filterColor) * outputTint;

	screenColor = LinearToScreenSpaceCustom(toneMap(linearColor, tonemapOperator));

	if(flags & TONEMAP_FLAG_CUSTOM_FILTER)
	{
		screenColor = BC(screenColor, brightnessContrast.x, brightnessContrast.y);
	}

	//fixes banding effects in atmosphere, clouds, fog, volumetric lights at low luminance
	screenColor = ditherOutput8bit(screenColor, i.pos.xy);

	if(flags & TONEMAP_FLAG_COLOR_GRADING)
	{
		// float3 whitePoint = bloomTexture.SampleLevel(gBilinearClampSampler, float2(0,0), 20).rgb;
		// whitePoint *= 3.0 / (whitePoint.r+whitePoint.g+whitePoint.b);
		// screenColor = bloomTexture[i.pos.xy].rgb / lerp(1, whitePoint, whiteBalanceFactor);
		float gradingFactor = 1.0;
		screenColor = lerp(screenColor, ColorGrade(screenColor, uv/pixelSize), gradingFactor);
	}

	debugDraw(i.projPos.xy, uv, screenColor);
	
#ifdef DRAW_FOCUS
	return calcGaussianWeight(length(i.projPos.xy*2-1) * focusWidth, focusSigma);
#endif
	
	return screenColor;
}

float3 SimpleToneMapSample(const VS_OUTPUT i, uint idx) {
	return simpleToneMap(SampleMap(ComposedMap, i.pos.xy, idx).xyz);
}

float4 PS_DebugToneMap(const VS_OUTPUT i, uint idx: SV_SampleIndex): SV_TARGET0 {
	uint2 uv = i.pos.xy;
	return SampleMap(ComposedMap, uv, idx).rgba*debugMult;
}

float4 PS_ToneMap(const VS_OUTPUT i, uint sidx: SV_SampleIndex, uniform int tonemapOperator, uniform int flags = 0): SV_TARGET0
{
	return float4(ToneMapSample(i, sidx, SampleSceneColor(i.pos.xy, sidx), tonemapOperator, flags), 1);
}

#ifdef MSAA
float4 PS_ToneMapResolveMSAA(const VS_OUTPUT i, uniform int tonemapOperator, uniform int flags = 0): SV_TARGET0
{
	float3 color = 0;
	float3 sceneColorRef = SampleSceneColor(i.pos.xy, 0);
	float3 tonmappedColorRef = color = ToneMapSample(i, 0, sceneColorRef, tonemapOperator, flags);

	[unroll]
	for(uint id=1; id<MSAA; ++id)
	{
		float3 sceneColor = SampleSceneColor(i.pos.xy, id);
		if(any(sceneColor != sceneColorRef))
			color += ToneMapSample(i, id, sceneColor, tonemapOperator, flags);
		else
			color += tonmappedColorRef;
	}

	return float4(color / MSAA, 1);
}
#endif

float4 PS_SimpleToneMap(const VS_OUTPUT i): SV_TARGET0 {	// without bloom
	return float4(SimpleToneMapSample(i, 0), 1);
}

float4 PS_SimpleToneMapFLIR(const VS_OUTPUT i, uniform bool gammaSpace) : SV_TARGET0 {
	float3 c = simpleToneMapFLIR(SampleMap(ComposedMap, i.pos.xy, 0).xyz, gammaSpace);
	return float4(c, 1);
}

#ifdef MSAA
float4 PS_SimpleToneMapResolveMSAA(const VS_OUTPUT i): SV_TARGET0
{
	float3 color = 0;
	[unroll]
	for(uint id=0; id<MSAA; ++id)
		color += SimpleToneMapSample(i, id);
	return float4(color / MSAA, 1);
}

float4 PS_SimpleToneMapFLIRResolveMSAA(const VS_OUTPUT i, uniform bool gammaSpace) : SV_TARGET0 {
	float3 color = 0;
	[unroll]
	for(uint id=0; id<MSAA; ++id)
		color += simpleToneMapFLIR(SampleMap(ComposedMap, i.pos.xy, id).xyz, gammaSpace);
	return float4(color / MSAA, 1);
}
#endif


VertexShader vsComp = CompileShader(vs_5_0, VS());
// PixelShader psComp = ComplieShader(ps_5_0, ps())

#define PASS_BODY(ps) { SetVertexShader(vsComp); SetGeometryShader(NULL); SetPixelShader(CompileShader(ps_5_0, ps)); \
	SetDepthStencilState(disableDepthBuffer, 0); \
	SetBlendState(disableAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF); \
	SetRasterizerState(cullNone);}
	
#define PASS_NAME(prefix, suffix) prefix##suffix

#define TONEMAP_OPERATOR_VARIANTS(name, operatorId, psName) \
	pass PASS_NAME(name, 0)			PASS_BODY(psName(operatorId, 0))\
	pass PASS_NAME(name, 1)			PASS_BODY(psName(operatorId, 1))\
	pass PASS_NAME(name, 2)			PASS_BODY(psName(operatorId, 2))\
	pass PASS_NAME(name, 3)			PASS_BODY(psName(operatorId, 3))\
	pass PASS_NAME(name, 4)			PASS_BODY(psName(operatorId, 4))\
	pass PASS_NAME(name, 5)			PASS_BODY(psName(operatorId, 5))\
	pass PASS_NAME(name, 6)			PASS_BODY(psName(operatorId, 6))\
	pass PASS_NAME(name, 7)			PASS_BODY(psName(operatorId, 7))


technique10 ToneMap {
	TONEMAP_OPERATOR_VARIANTS(Linear,		TONEMAP_OPERATOR_LINEAR,		PS_ToneMap)
	TONEMAP_OPERATOR_VARIANTS(Exponential,	TONEMAP_OPERATOR_EXPONENTIAL,	PS_ToneMap)
	TONEMAP_OPERATOR_VARIANTS(Filmic,		TONEMAP_OPERATOR_FILMIC,		PS_ToneMap)

	pass Debug					PASS_BODY(PS_DebugToneMap())
}

#ifdef MSAA
technique10 ToneMapResolveMSAA {
	TONEMAP_OPERATOR_VARIANTS(Linear,		TONEMAP_OPERATOR_LINEAR,		PS_ToneMapResolveMSAA)
	TONEMAP_OPERATOR_VARIANTS(Exponential,	TONEMAP_OPERATOR_EXPONENTIAL,	PS_ToneMapResolveMSAA)
	TONEMAP_OPERATOR_VARIANTS(Filmic,		TONEMAP_OPERATOR_FILMIC,		PS_ToneMapResolveMSAA)

	pass Debug					PASS_BODY(PS_DebugToneMap())
}
#endif

technique10 SimpleToneMap {
	pass NORMAL					PASS_BODY(PS_SimpleToneMap())
	pass FLIR					PASS_BODY(PS_SimpleToneMapFLIR(false))
	pass FLIR_MATERIAL			PASS_BODY(PS_SimpleToneMapFLIR(true))
}

#ifdef MSAA
technique10 SimpleToneMapResolveMSAA {
	pass NORMAL					PASS_BODY(PS_SimpleToneMap())
	pass FLIR					PASS_BODY(PS_SimpleToneMapFLIR(false))
	pass FLIR_MATERIAL			PASS_BODY(PS_SimpleToneMapFLIR(true))
}
#endif

technique10 LuminanceMap {
	pass luminanceBySinglePass			{ SetComputeShader(CompileShader(cs_5_0, CS_Lum(LUMINANCE_ONE_PASS)));	}
	pass fromScreenToLumTarget			{ SetComputeShader(CompileShader(cs_5_0, CS_Lum(LUMINANCE_PASS_0)));	}
	pass fromLumTargetToStructBuffer	{ SetComputeShader(CompileShader(cs_5_0, CS_Lum(LUMINANCE_PASS_1))); 	}
	pass fromLumTargetToStructBufferWithoutAdaptation { SetComputeShader(CompileShader(cs_5_0, CS_Lum(LUMINANCE_PASS_1_WITHOUT_ADAPTATION))); }
}


#define ADAPTATION_PASS(Flags)	pass P##Flags {						\
	SetComputeShader(CompileShader(cs_5_0, CS_Adaptation(Flags)));	\
	SetVertexShader(NULL);											\
	SetGeometryShader(NULL);										\
	SetPixelShader(NULL);		}

technique10 Adaptation {
	ADAPTATION_PASS(0)
	ADAPTATION_PASS(1)
	ADAPTATION_PASS(2)
	ADAPTATION_PASS(3)
	ADAPTATION_PASS(4)
	ADAPTATION_PASS(5)
	ADAPTATION_PASS(6)
	ADAPTATION_PASS(7)
	ADAPTATION_PASS(8)
	ADAPTATION_PASS(9)
	ADAPTATION_PASS(10)
	ADAPTATION_PASS(11)
	ADAPTATION_PASS(12)
	ADAPTATION_PASS(13)
	ADAPTATION_PASS(14)
	ADAPTATION_PASS(15)
}
