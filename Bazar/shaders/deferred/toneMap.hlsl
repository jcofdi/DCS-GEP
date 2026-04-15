#ifndef TONEMAP_HLSL
#define TONEMAP_HLSL

// =========================================================================
// GEP toneMap.hlsl - Hybrid Tonemapping with Stock Hable Curve
// =========================================================================
// Architecture:
//   Luminance-based tonemapping for toe region (hue-preserving).
//   Per-channel tonemapping for shoulder region (natural desaturation).
//   Hybrid blend point derived from cbuffer shoulder value.
//
// The stock Hable piecewise curve with DCS's default parameters
// (slope=0.865, toe=0.617, shoulder=0.322, whiteClip=0.04) has no
// linear section (toe+shoulder < 1.0). The shoulder entry in output
// space is exactly the cbuffer "shoulder" value. Per-channel behavior
// is physically appropriate there: the decreasing curve slope naturally
// desaturates highlights in proportion to brightness, matching the
// cone saturation response. In the toe, luminance-based preserves
// hue where the eye is most sensitive to color shifts.
//
// Preserved interfaces (required by Tonemap.fx, bloom.fx, etc):
//   - getAvgLuminanceClamped(), getLinearExposure(), getLinearExposureMFD()
//   - toneMap() switch (LINEAR/EXPONENTIAL/FILMIC)
//   - simpleToneMap(), simpleToneMapFLIR()
//   - plotNumber(), plotQuad(), debugDraw()
//   - LuminanceToHistogramPos()
// =========================================================================

#include "deferred/tonemapCommon.hlsl"
#include "deferred/luminance.hlsl"
#include "common/ambientCube.hlsl"
#include "deferred/filmicCurve.hlsl"

#define OPERATOR_LUT 0

Buffer<float>		histogram;
Texture1D<float>	tonemapLUT;


// =========================================================================
// Luminance and exposure functions
// =========================================================================

float getAvgLuminanceClamped() {
	return clamp(getAverageLuminance(), sceneLuminanceMin, sceneLuminanceMax);
}

float getAvgLuminanceClampedCockpit() {
	return clamp(getAverageLuminanceCockpit(), sceneLuminanceMin, sceneLuminanceMax);
}

float getLinearExposure(float averageLuminance, float exposureCorrection = 0)
{
	float linearExposure = 0.18 / averageLuminance;
	return exp2(log2(linearExposure) + dcExposureCorrection);
}

float getLinearExposureMFD(float averageLuminance) {
	const float toneMapFactor = 0.05;
	const float exposureKey = 1.3;
	return 0.5 / (pow(averageLuminance, exposureKey) + toneMapFactor);
}


// =========================================================================
// Post-curve reshaping: adaptive shadow recovery
// =========================================================================
// Shadow detail recovery lifts very dark output pixels using a sqrt-
// proportional ramp whose strength adapts to scene luminance.
//
// highlightCompress is at no-op value (0.0). Highlight rolloff knee
// references the cbuffer shoulder value directly so it tracks any
// engine-side curve changes automatically.
// =========================================================================

static const float midtoneGamma     = 1.0;
static const float shadowStrength   = 0.40;
static const float shadowNightMin   = 0.05;
static const float shadowCeiling    = 0.06;
static const float adaptLumLow      = 0.01;
static const float adaptLumHigh     = 0.25;
static const float highlightCompress = 0.0;

float reshapeCurve(float v)
{
	// Midtone gamma (1.0 = no-op)
	v = pow(v, midtoneGamma);

	// Adaptive shadow strength based on scene luminance
	float avgLum = getAvgLuminanceClamped();
	float adaptBlend = smoothstep(log10(adaptLumLow), log10(adaptLumHigh), log10(avgLum));
	float strength = lerp(shadowNightMin, shadowStrength, adaptBlend);

	// Shadow detail recovery: sqrt-proportional lift, hard-confined
	if (v < shadowCeiling)
	{
		float t = v / shadowCeiling;
		float sqrtMapped = shadowCeiling * sqrt(t);
		float fade = 1.0 - t;
		v = lerp(v, sqrtMapped, strength * fade);
	}

	// Highlight rolloff (0.0 = no-op, knee tracks cbuffer shoulder)
	float mask = smoothstep(shoulder, 1.0, v);
	v -= highlightCompress * mask * mask;

	return v;
}


// =========================================================================
// Hable Piecewise Filmic Curve (cbuffer parameters from engine)
// =========================================================================
// slope, toe, shoulder, blackClip, whiteClip set by engine via cbuffer.
// Operates in log10 luminance space.
//
// With stock DCS values (toe+shoulder=0.939 < 1.0), there is no
// linear midsection. Curve transitions directly from toe to shoulder.
//
// Reference: John Hable, "Filmic Tonemapping with Piecewise Power Curves"
// =========================================================================

float Curve(float c0, float c1, float ca, float curveSlope, float X)
{
	float t = 1 + c1 - c0;
	return 2*t / (1 + exp((2*curveSlope/t) * (X - ca))) - c1;
}

float TonemapFilmic(float logLuminance)
{
	float ta = (1 - toe - 0.18) / slope - 0.733;
	float sa = (shoulder - 0.18) / slope - 0.733;

	if (logLuminance < ta)
		return Curve(toe, blackClip, ta, -slope, logLuminance);
	else if (logLuminance < sa)
		return slope * (logLuminance + 0.733) + 0.18;
	else
		return 1 - Curve(shoulder, whiteClip, sa, slope, logLuminance);
}


// =========================================================================
// Hybrid tonemapping: luminance-based in the toe, per-channel in the
// shoulder, blended at the curve's shoulder entry point.
// =========================================================================

#if OPERATOR_LUT

// LUT-based path
float3 ToneMap_Filmic_Unrealic(float3 linearColor)
{
	const float3 LUM = { 0.2125, 0.7154, 0.0721 };
	float lum = dot(linearColor, LUM);

	if (lum <= 1e-6)
		return 0;

	// Luminance-based path
	float logLum = log10(lum);
	float u = (logLum - LUTLogLuminanceMin) / (LUTLogLuminanceMax - LUTLogLuminanceMin);
	float tonemappedLum = reshapeCurve(tonemapLUT.SampleLevel(gBilinearClampSampler, u, 0).r);

	float lumScale = tonemappedLum / lum;
	float3 lumResult = linearColor * lumScale;

	// Gamut safety: ratio-preserving clamp
	float maxC = max(lumResult.r, max(lumResult.g, lumResult.b));
	if (maxC > 1.0)
		lumResult /= maxC;

	// Per-channel path
	float3 logColor = log10(max(linearColor, 1e-6));
	float uR = (logColor.r - LUTLogLuminanceMin) / (LUTLogLuminanceMax - LUTLogLuminanceMin);
	float uG = (logColor.g - LUTLogLuminanceMin) / (LUTLogLuminanceMax - LUTLogLuminanceMin);
	float uB = (logColor.b - LUTLogLuminanceMin) / (LUTLogLuminanceMax - LUTLogLuminanceMin);

	float3 pcResult;
	pcResult.r = reshapeCurve(tonemapLUT.SampleLevel(gBilinearClampSampler, uR, 0).r);
	pcResult.g = reshapeCurve(tonemapLUT.SampleLevel(gBilinearClampSampler, uG, 0).r);
	pcResult.b = reshapeCurve(tonemapLUT.SampleLevel(gBilinearClampSampler, uB, 0).r);

	// Shoulder-based blend: cbuffer "shoulder" is the exact output value
	// where the curve's shoulder segment begins. Ramp width 0.20 gives
	// a smooth transition across the shoulder onset.
	float blend = smoothstep(shoulder, shoulder + 0.20, tonemappedLum);
	return lerp(lumResult, pcResult, blend);
}

#else

// Inline path (active)
float3 ToneMap_Filmic_Unrealic(float3 linearColor)
{
	const float3 LUM = { 0.2125, 0.7154, 0.0721 };
	float lum = dot(linearColor, LUM);

	if (lum <= 1e-6)
		return 0;

	// Luminance-based path (toe: hue-preserving)
	float logLum = log10(lum);
	float tonemappedLum = reshapeCurve(TonemapFilmic(logLum));

	float lumScale = tonemappedLum / lum;
	float3 lumResult = linearColor * lumScale;

	// Gamut safety: ratio-preserving clamp
	float maxC = max(lumResult.r, max(lumResult.g, lumResult.b));
	if (maxC > 1.0)
		lumResult /= maxC;

	// Per-channel path (shoulder: natural highlight desaturation)
	float3 logColor = log10(max(linearColor, 1e-6));
	float3 pcResult;
	pcResult.r = reshapeCurve(TonemapFilmic(logColor.r));
	pcResult.g = reshapeCurve(TonemapFilmic(logColor.g));
	pcResult.b = reshapeCurve(TonemapFilmic(logColor.b));

	// Shoulder-based blend: cbuffer "shoulder" is the exact output value
	// where the curve's shoulder segment begins. Below this, luminance-
	// based preserves hue in the toe. Above this, per-channel provides
	// natural desaturation from the curve's decreasing slope.
	float blend = smoothstep(shoulder, shoulder + 0.20, tonemappedLum);
	return lerp(lumResult, pcResult, blend);
}

#endif


// =========================================================================
// Alternative tonemap operators (required by toneMap() switch)
// =========================================================================

float3 ToneMap_Hable(float3 x)
{
	float hA = 0.15;
	float hB = 0.50;
	float hC = 0.10;
	float hD = 0.20;
	float hE = 0.02;
	float hF = 0.30;

	return ((x*(hA*x+hC*hB)+hD*hE) / (x*(hA*x+hB)+hD*hF)) - hE/hF;
}

float3 ToneMap_atmHDR(float3 L) {
	L = L < 1.413 ? (abs(L) * 0.38317) : pow(max(0, 1.0 - exp(-L)), 2.2);
	return L;
}

float3 ToneMap_Linear(float3 L) {
	return L;
}

float3 ToneMap_Exp(float3 L) {
	return pow(max(0, 1 - exp(-L*tmPower)), tmExp);
}

float3 ToneMap_Exp2(float3 L) {
	return (1 - exp(-L*tmPower)) * (1 - exp(-L*tmExp));
}


// =========================================================================
// Tonemap operator switch (called by Tonemap.fx)
// =========================================================================

float3 toneMap(float3 linearColor, uniform int tonemapOperator)
{
	float3 tonmappedColor;

	switch(tonemapOperator)
	{
	case TONEMAP_OPERATOR_LINEAR:       tonmappedColor = ToneMap_Linear(linearColor); break;
	case TONEMAP_OPERATOR_EXPONENTIAL:  tonmappedColor = ToneMap_Exp(linearColor); break;
	case TONEMAP_OPERATOR_FILMIC:       tonmappedColor = ToneMap_Filmic_Unrealic(linearColor); break;
	}

	return tonmappedColor;
}


// =========================================================================
// Simple tonemap paths (FLIR, MFD, etc)
// =========================================================================

float3 simpleToneMapFLIR(float3 color, uniform bool gammaSpace) {
	float averageLuminance = avgLuminance[LUMINANCE_AVERAGE].x;
	float exposure = getLinearExposureMFD(averageLuminance);
	exposure = lerp(exposure, 3.5, 0.25);
	float3 tonmappedColor = ToneMap_Exp(color * exposure);
	if(gammaSpace)
		return LinearToGammaSpace(tonmappedColor);
	else
		return tonmappedColor;
}

float3 simpleToneMap(float3 color) {
	float averageLuminance = avgLuminance[LUMINANCE_AVERAGE].x;
	float exposure = getLinearExposureMFD(averageLuminance);
	float3 tonmappedColor = ToneMap_Exp(color * exposure);
	return LinearToGammaSpace(tonmappedColor);
}


// =========================================================================
// Debug drawing functions
// =========================================================================

#define drawGrid(uv, eps) ((abs(uv.x-0.5)<eps || abs(uv.x-1.0)<eps || abs(uv.x-1.5)<eps || abs(uv.y - 0.5)<eps) ? 1.0 : 0.0)

#define plotGrid(uv, colorOut, gridColor) {colorOut = lerp(colorOut, gridColor.rgb, gridColor.a*drawGrid(p, 2*1e-3));}

#define plotFunction(uv, p, funcName, colorOut, funcColor) { if(abs((1-p.y) - funcName(p.x).x)<0.002)\
	colorOut = lerp(colorOut, funcColor.rgb, funcColor.a);}

uint digit(float2 p, float n) {
	uint i = uint(p.y+0.5), b = uint(exp2(floor(30.000 - p.x - n*3.0)));
	i = ( p.x<=0.0||p.x>3.0? 0: i==5u? 972980223u: i==4u? 690407533u: i==3u? 704642687u: i==2u? 696556137u:i==1u? 972881535u: 0u ) / b;
	return i-(i>>1) * 2u;
}

void plotNumber(float2 p, float number, inout float3 colorOut)
{
	float2 i = p/10.0;
	for (float n=2.0; n>-4.0; n--) {
		if ((i.x-=4.)<3.) {
			colorOut = lerp(colorOut, float3(1,0,0), digit(i, floor(fmod((number+1.0e-7)/pow(10.0, n), 10.0))) );
			break;
		}
	}
}

void plotQuad(float2 pixel, float2 quadBottomLeft, float2 quadSize, float4 color, inout float3 colorOut)
{
	pixel -= quadBottomLeft;
	float alpha = color.a;
	if(!all(pixel>=0 & pixel<quadSize))
		alpha = 0;
	colorOut = color.rgb * alpha + colorOut * (1 - alpha);
}

float LuminanceToHistogramPos(float luminance)
{
	float logLuminance = log2(luminance);
	return saturate(logLuminance * inputLuminanceScaleOffset.x + inputLuminanceScaleOffset.y);
}

void debugDraw(float2 uvNorm, float2 pixel, inout float3 sourceColor)
{
#ifdef PLOT_TONEMAP_FUNCION
	const float plotOpacity = 0.7;
	float2 p = uvNorm * float2(2.5, 1);
	p.x = pow(10, (p.x-1.5) * 2);
	plotFunction(uvNorm, p, ToneMap_Filmic_Unrealic, sourceColor, float4(0,0,1,0.5*plotOpacity));
#endif

#ifdef PLOT_AVERAGE_LUMINANCE
	float2 lumPix = pixel;
	lumPix.y = 768 - lumPix.y;
	plotNumber(lumPix, getAvgLuminanceClamped(), sourceColor);
#endif

#ifdef PLOT_HISTOGRAM
	const float2 histogramPos = {50, 400};
	const float2 histogramSize = {200, 150};
	const uint nHistogramBins = 32;
	const float4 histogramColor = float4(0.7,1,0,0.5);
	const float4 borderColor = float4(0.7,1,0,0.5);

	float binWidth = floor(histogramSize.x / nHistogramBins);

	float2 hisPix = pixel;
	hisPix.y = histogramPos.y - hisPix.y;
	[loop]
	for(uint i=0; i<nHistogramBins; ++i)
		plotQuad(hisPix, float2(histogramPos.x + (binWidth+1)*i, 0), float2(binWidth, 4*histogramSize.y*histogram[i]/1.0), histogramColor, sourceColor);
	float2 size = float2((binWidth+1)*nHistogramBins, histogramSize.y);
	plotQuad(hisPix, float2(histogramPos.x, 0),          float2(1, size.y),          borderColor, sourceColor);
	plotQuad(hisPix, float2(histogramPos.x + size.x, 0), float2(1, histogramSize.y), borderColor, sourceColor);
	plotQuad(hisPix, float2(histogramPos.x, -1),         float2(size.x, 1),          borderColor, sourceColor);
	plotQuad(hisPix, float2(histogramPos.x, size.y),     float2(size.x, 1),          borderColor, sourceColor);

	float pos = LuminanceToHistogramPos(avgLuminance[LUMINANCE_AVERAGE].x);
	plotQuad(hisPix, float2(histogramPos.x + pos * size.x, 0),        float2(1, size.y), float4(1,1,1,0.7), sourceColor);
	plotQuad(hisPix, float2(histogramPos.x + percentMin * size.x, 0), float2(1, size.y), float4(0,0,1,0.2), sourceColor);
	plotQuad(hisPix, float2(histogramPos.x + percentMax * size.x, 0), float2(1, size.y), float4(0,0,1,0.2), sourceColor);
#endif
}

#endif
