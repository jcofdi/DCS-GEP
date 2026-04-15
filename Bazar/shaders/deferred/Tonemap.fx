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
#define DITHER_MODE_BLUE_COMPUTED
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
}

float3 LinearToScreenSpaceCustom(float3 color)
{
	// GEP: Fixed sRGB encoding. Gamma slider now drives exposure bias
	// instead (see user EV bias below). Using simple pow(1/2.2) rather
	// than the engine's outputGammaInv so that the gamma slider is free
	// to control brightness without changing the transfer function.
	return pow(abs(color), 1.0 / 2.2);
}

float3 SampleSceneColor(float2 uv, uint idx, uniform uint pixelSize = 1)
{
	return SampleMap(ComposedMap, uv - (pixelSize>1 ? fmod(uv, pixelSize) : 0), idx).xyz;
}

float3 applyDitheringOnLowLuminance(uint2 pixel, float3 color, float lumMaxInv)
{
    float lum = dot(color, 0.333333);
    return color * lerp((0.9 + 0.2 * dither(pixel)), 1, saturate(lum * lumMaxInv));
}

float3 ToneMapSample(const VS_OUTPUT i, uint idx, float3 sceneColor, uniform int tonemapOperator, uniform int flags = 0)
{
	uint2 uv = i.pos.xy;

	const uint pixelSize = 1;

	uint matID = uint(SampleMap(StencilMap, uv - (pixelSize>1 ? fmod(uv, pixelSize):0), idx).g) & STENCIL_COMPOSITION_MASK;
	float lum;

#ifdef COCKPIT_EXP
	if(matID == STENCIL_COMPOSITION_COCKPIT && 1){
		float a = getAvgLuminanceClamped();
		float d = cockpitExposureClamp;
		lum = a*(1-d);
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
	// Stock adaptation (0.18 / clampedAvgLum) normalizes every scene to
	// the same display brightness. This partially undoes that so bright
	// scenes feel bright and dark scenes feel dark, matching how human
	// vision retains a brightness envelope after adaptation.
	//
	// Split exponent: gentler at night (0.92), full strength daytime
	// (0.80). Transition smoothstep(0.03, 0.08) sits below the clamp
	// floor (0.010), so the switch happens in the rapid dawn onset
	// where it is masked by the natural brightness change. Everything
	// from twilight (0.08) upward sees the proven 0.80 exponent.
	//
	// clampOvershoot cancels the engine's sceneLuminanceMin clamp so
	// the correction operates on true unclamped avgLum. This prevents
	// a -0.83 EV dimming spike at the clamp boundary. Below the clamp,
	// overshoot nearly cancels the correction, keeping very dark scenes
	// close to stock exposure.
	//
	// Zero point: trueLum = 0.18 (middle gray key). Below 0.18, scenes
	// are slightly dimmed. Above 0.18, slightly brightened. The 0.80
	// exponent gives ~+0.35 EV at bright sun (avgLum 0.600) and ~-0.17
	// EV at light overcast (avgLum 0.100).
	{
		float trueLum = max(getAverageLuminance(), 0.001);
		float blend = smoothstep(0.03, 0.08, trueLum);
		float gepExposureExponent = lerp(0.92, 0.80, blend);

		float ratio = trueLum / 0.18;
		float correction = pow(max(ratio, 0.001), 1.0 - gepExposureExponent);
		float clampOvershoot = lum / max(trueLum, 0.001);
		exposure *= correction * clampOvershoot;
	}

	// --- GEP: User exposure bias (repurposed gamma slider) ---
	// The engine passes 1/gammaSlider as outputGammaInv.
	// Default slider = 2.2 -> outputGammaInv = 0.4545.
	// We recover the slider, map linearly to an EV offset
	// (2.2 -> 0 EV, center of range), and apply as a stop shift.
	//
	// Mapping:  slider 1.0 -> -1.2 EV (darker)
	//           slider 2.2 ->  0.0 EV (no change)
	//           slider 3.5 -> +1.3 EV (brighter)
	{
		float userGamma  = 1.0 / outputGammaInv;
		float userEVBias = (userGamma - 2.2) * 2.0;
		exposure *= exp2(userEVBias);
	}

	if(hwFactor>0)//TODO remove
	{
		// float3 tint = gDev1.xyz;
		float3 tint = lerp(1, float3(0.8, 1, 1), hwFactor);
		tint *= 3.0 / (tint.x + tint.y + tint.z);
		sceneColor *= tint;
	}


	// Stock bloom composite (lerp-based)
	float3 linearColor = lerp(sceneColor, bloom, bloomLerpFactor) * exposure;

	if(whiteBalanceFactor>0)
	{
		linearColor /= lerp(1, AmbientWhitePoint, whiteBalanceFactor);
	}

	// --- GEP: Purkinje effect (scotopic vision color shift) ---
	// In low light, rod-dominated vision shifts perceived color toward
	// blue-gray. Only applies to dim pixels; bright local sources
	// activate cone vision regardless of scene adaptation level.
	{
		float trueLum = max(getAverageLuminance(), 0.001);
		float purkinjeStrength = 1.0 - smoothstep(0.01, 0.08, trueLum);
		if (purkinjeStrength > 0)
		{
			float3 lumCoeff = float3(0.2125, 0.7154, 0.0721);
			float pixelLum = dot(linearColor, lumCoeff);
			float gray = pixelLum;
			float3 scotopic = gray * float3(0.75, 0.85, 1.0);

			float localCone = smoothstep(0.005, 0.05, pixelLum);
			float effectAmount = purkinjeStrength * 0.7 * (1.0 - localCone);

			linearColor = lerp(linearColor, scotopic, effectAmount);
		}
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

	// GEP: Ratio-preserving display clamp.
	// If any channel exceeds 1.0 after gamma, scale all channels equally
	// so the brightest channel lands at 1.0. Preserves hue through the
	// clamp rather than per-channel hard clipping.
	float maxChannel = max(screenColor.r, max(screenColor.g, screenColor.b));
	if (maxChannel > 1.0)
		screenColor *= 1.0 / maxChannel;

	if(flags & TONEMAP_FLAG_CUSTOM_FILTER)
	{
		screenColor = BC(screenColor, brightnessContrast.x, brightnessContrast.y);
	}

	// Fixes banding in atmosphere, clouds, fog, volumetric lights at low luminance
	screenColor = ditherOutput8bit(screenColor, i.pos.xy);

	if(flags & TONEMAP_FLAG_COLOR_GRADING)
	{
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
