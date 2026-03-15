#include "common/states11.hlsl"
#include "common/samplers11.hlsl"
#include "common/context.hlsl"
#include "common/bc.hlsl"
#include "deferred/deferredCommon.hlsl"
#include "deferred/colorGrading.hlsl"
// #define PLOT_TONEMAP_FUNCION
#define PLOT_AVERAGE_LUMINANCE
// #define PLOT_HISTOGRAM
// #define DRAW_FOCUS
#include "deferred/toneMap.hlsl"
#include "deferred/calcAvgLum.hlsl"
#include "common/random.hlsl"
#include "common/stencil.hlsl"
#define DITHER_MODE_R2
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
    // GEP: Fixed sRGB encoding - gamma slider now drives
    // exposure instead. Using simple pow(1/2.2) rather than
    // piecewise sRGB because the original function was already
    // a pure power law, and this maintains identical behavior
    // at the previous default of 2.2.
    return pow(abs(color), 1.0 / 2.2);
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

	// GEP: Stock exposure with sub-linear perceptual compensation.
	//
	// Stock adaptation (0.18 / clampedAvgLum) normalizes every scene to
	// the same display brightness. The sub-linear correction partially
	// undoes this so bright scenes feel bright and dark scenes feel dark.
	//
	// The clamp overshoot correction compensates for scenes where true
	// avgLum exceeds the engine's clamp range (0.010-0.600). It
	// algebraically cancels the clamp, producing the equivalent of
	// pow(0.18 / trueLum, exponent) regardless of clamp state.
	//
	// gepExposureExponent controls the perceptual envelope:
	//   1.0 = no effect (stock behavior)
	//   0.80 = ~0.72 stops total swing from night to clear noon
	float exposure = getLinearExposure(lum);
	{
		static const float gepExposureExponent = 0.8;

		float trueLum = max(getAverageLuminance(), 0.001);
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
		// sceneColor = lerp(dot(sceneColor, 0.33333), sceneColor, gDev1.w) * tint;
		// sceneColor *= tint;
	}

	
	// GEP: Additive bloom composite with Fraunhofer-inspired adaptive intensity.
	//
	// Additive bloom adds scattered light energy on top of the scene,
	// matching the physical behavior of optical scatter.
	//
	// Fraunhofer adaptive intensity models the PSF energy distribution
	// difference between bright and dark adaptation states:
	//   Day (small pupil): wider PSF, more visible halos (1.3x)
	//   Night (large pupil): tighter PSF, subdued glow (0.7x)
	float trueLumBloom = max(getAverageLuminance(), 0.001);
	float pupilBloomScale = lerp(0.7, 1.3, smoothstep(0.02, 0.15, trueLumBloom));
	float bloomLum = dot(bloom, float3(0.2126, 0.7152, 0.0722));
	float bloomDesatAmount = lerp(0.5, 0.0, smoothstep(0.02, 0.10, trueLumBloom));
	float3 neutralBloom = lerp(bloom, bloomLum, bloomDesatAmount);

	// GEP: Dither bloom to break pyramid upsample banding.
	float bloomDither = ditherR2(i.pos.xy) - 0.5; // centered [-0.5, 0.5]
	neutralBloom += bloomDither * 0.05 * bloomLum;

	float3 linearColor = (sceneColor + neutralBloom * bloomLerpFactor * pupilBloomScale) * exposure;

	// GEP: Purkinje effect (scotopic vision color shift).
	// In low light, rod-dominated vision shifts perceived color toward
	// blue-gray. The scene illuminant (moonlight) is physically warm,
	// but human perception at scotopic levels is blue-biased and
	// desaturated. Only applies to dim pixels; bright local sources
	// (lights, cockpit, emissives) activate cone vision regardless
	// of scene adaptation level.
	{
		float purkinjeStrength = 1.0 - smoothstep(0.01, 0.08, trueLumBloom);
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

	// GEP: Output-side display clamp (GT7-style).
	// The ICtCp path and curve process the full HDR range correctly.
	// The display simply cannot show more than 1.0.
	screenColor = min(screenColor, 1.0);

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
	
	// DEBUG: Raw HDR and exposed luminance at screen center
	// Point center of screen at any surface to read its values.
	// Remove before release.
/*	{
		float2 px = i.pos.xy;
		float3 centerScene = SampleSceneColor(gSreenParams.xy * 0.5, 0);
		float rawLum = dot(centerScene, float3(0.2125, 0.7154, 0.0721));
		float exposedLum = rawLum * exposure;

		// Raw HDR luminance (top, what the scene actually contains)
		float2 numPos1 = float2(px.x - 10.0, 100.0 - px.y);
		plotNumber(numPos1, rawLum, screenColor);

		// Exposed luminance (below, what the curve receives)
		float2 numPos2 = float2(px.x - 10.0, 175.0 - px.y);
		plotNumber(numPos2, exposure, screenColor);
		
		// Low Light luminance 
		float2 numPos3 = float2(px.x - 10.0, 250.0 - px.y);
		plotNumber(numPos3, rawLum * 10000.0, screenColor);		

		// Average Raw luminance
		float2 numPos4 = float2(px.x - 10.0, 325.0 - px.y);
		plotNumber(numPos4, getAverageLuminance(), screenColor);

		// Average Clamped Luminance
		float2 numPos5 = float2(px.x - 10.0, 400.0 - px.y);
		plotNumber(numPos5, getAvgLuminanceClamped(), screenColor);
			
		// Sun Direction
		float2 numPos6 = float2(px.x - 10.0, 475.0 - px.y);
		plotNumber(numPos6, gSunDir.y, screenColor);
			
		// Sun Attenuation
		float2 numPos12 = float2(px.x - 10.0, 550.0 - px.y);
		plotNumber(numPos12, gSunAttenuation, screenColor);
			
		// Cloudiness
		float2 numPos7 = float2(px.x - 10.0, 625.0 - px.y);
		plotNumber(numPos7, gCloudiness, screenColor);
			
		// Sun Diffuse
		// float2 numPos8 = float2(px.x - 10.0, 700.0 - px.y);
		// plotNumber(numPos8, gSunDiffuse.rgb, screenColor);
			
		// Sun R
		// float2 numPos9 = float2(px.x - 10.0, 775.0 - px.y);
		// plotNumber(numPos9, gSunDiffuse.r, screenColor);
			
		// Sun G
		// float2 numPos10 = float2(px.x - 10.0, 850.0 - px.y);
		// plotNumber(numPos10, gSunDiffuse.g, screenColor);
			
		// Sun B
		// float2 numPos11 = float2(px.x - 10.0, 925.0 - px.y);
		// plotNumber(numPos11, gSunDiffuse.b, screenColor);
			
		//plotNumber(numPos, whiteBalanceFactor, screenColor);
		// And for the white point RGB:
		//plotNumber(numPos, AmbientWhitePoint.r, screenColor);
		//plotNumber(numPos, AmbientWhitePoint.g, screenColor);
		//plotNumber(numPos, AmbientWhitePoint.b, screenColor);
	}
*/

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
