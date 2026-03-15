#ifndef TONEMAP_HLSL
#define TONEMAP_HLSL

// =========================================================================
// GEP toneMap.hlsl - Perceptual Tonemapping with Adaptive Hable Curve
// =========================================================================
// Combines two approaches:
//
// 1. ICtCp perceptual color space (ITU-T T.302): intensity and chrominance
//    processed independently using the ST.2084 PQ transfer function.
//    Matches GT7/Polyphony Digital's reference implementation.
//    Resolves Oklab's hue twist under extreme illuminant conditions.
//
// 2. Hable piecewise filmic curve with adaptive parameters: slope, toe,
//    and whiteClip vary with scene brightness (avgLum) to match
//    perceptual contrast sensitivity across lighting conditions.
//    Night: gentle slope, deep toe crush, bright highlights.
//    Day: steep slope, open shadows, moderate highlights.
//
// Architecture:
//   Stock auto-exposure normalizes content center to ~0.18.
//   Sub-linear exponent (Tonemap.fx) provides perceptual brightness envelope.
//   Adaptive curve parameters reshape contrast per-condition.
//   ICtCp decomposition with GT7 chroma preservation handles color.
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

Buffer<float> histogram;
Texture1D<float> tonemapLUT;


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
// GEP Adaptive Hable Curve Parameters
// =========================================================================
// Three conditions define the curve shape across lighting scenarios.
// Intermediate values are smoothstep-interpolated by unclamped avgLum.
//
// Night (avgLum <= 0.010): scotopic vision, low contrast sensitivity,
//   deep shadow crush, bright point sources pop against dark background.
//
// Evening (avgLum ~0.045): mesopic transition, moderate contrast,
//   balanced shadow/highlight handling.
//
// Day (avgLum >= 0.200): photopic vision, high contrast sensitivity,
//   open shadows, punchy midrange.
//
// Shoulder and blackClip are fixed across all conditions.
// =========================================================================

// --- Night ---
static const float gepNightSlope     = 0.865;
static const float gepNightToe       = 0.550;
static const float gepNightWhiteClip = 0.125;

// --- Evening ---
static const float gepEveningSlope     = 0.900;
static const float gepEveningToe       = 0.450;
static const float gepEveningWhiteClip = 0.08;

// --- Day ---
static const float gepDaySlope     = 1.000;
static const float gepDayToe       = 0.402;
static const float gepDayWhiteClip = 0.050;

// --- Fixed across all conditions ---
static const float gepShoulder  = 0.322;
static const float gepBlackClip = 0.000;

// --- Transition points (unclamped avgLum) ---
static const float gepNightEnd   = 0.010;  // night floor, below = pure night
static const float gepEveningMid = 0.020;  // evening target
static const float gepDayStart   = 0.200;  // day ceiling, above = pure day

// GT7-style chroma preservation factor.
// 0.6 = 60% chroma preserved regardless of brightness compression.
// Perceptually motivated by the Hunt effect.
static const float gepChromaPreserve = 0.6;


// =========================================================================
// ICtCp perceptual color space conversion (ITU-T T.302)
// =========================================================================
// ICtCp separates intensity (I) from chrominance (Ct, Cp) using the
// ST.2084 PQ transfer function. Better hue stability than Oklab under
// extreme illuminant conditions (sunrise/sunset).
//
// DCS outputs BT.709/sRGB. ICtCp operates in BT.2020. Gamut conversion
// matrices bracket the transform.
//
// Reference: ITU-T T.302, GT7/Polyphony Digital (SIGGRAPH 2025)
// =========================================================================

// Gamut conversion matrices
float3 bt709ToBt2020(float3 rgb)
{
	return float3(
		0.6274 * rgb.r + 0.3293 * rgb.g + 0.0433 * rgb.b,
		0.0691 * rgb.r + 0.9195 * rgb.g + 0.0114 * rgb.b,
		0.0164 * rgb.r + 0.0880 * rgb.g + 0.8956 * rgb.b
	);
}

float3 bt2020ToBt709(float3 rgb)
{
	return float3(
		 1.6605 * rgb.r - 0.5877 * rgb.g - 0.0728 * rgb.b,
		-0.1246 * rgb.r + 1.1330 * rgb.g - 0.0084 * rgb.b,
		-0.0182 * rgb.r - 0.1006 * rgb.g + 1.1187 * rgb.b
	);
}

// ST.2084 PQ transfer function
static const float PQ_REFERENCE_LUMINANCE = 100.0;
static const float PQ_MAX_LUMINANCE = 10000.0;

float pqForward(float v)
{
	float y = max(v * PQ_REFERENCE_LUMINANCE, 0) / PQ_MAX_LUMINANCE;

	static const float m1 = 0.1593017578125;
	static const float m2 = 78.84375;
	static const float c1 = 0.8359375;
	static const float c2 = 18.8515625;
	static const float c3 = 18.6875;

	float ym = pow(y, m1);
	return pow((c1 + c2 * ym) / (1.0 + c3 * ym), m2);
}

float pqInverse(float n)
{
	n = clamp(n, 0, 1);

	static const float m1 = 0.1593017578125;
	static const float m2 = 78.84375;
	static const float c1 = 0.8359375;
	static const float c2 = 18.8515625;
	static const float c3 = 18.6875;

	float np = pow(n, 1.0 / m2);
	float l = max(np - c1, 0) / (c2 - c3 * np);
	l = pow(l, 1.0 / m1);

	return l * PQ_MAX_LUMINANCE / PQ_REFERENCE_LUMINANCE;
}

// ICtCp conversion
float3 linearRGBToICtCp(float3 rgb709)
{
	float3 rgb2020 = bt709ToBt2020(rgb709);

	float l = (rgb2020.r * 1688.0 + rgb2020.g * 2146.0 + rgb2020.b * 262.0) / 4096.0;
	float m = (rgb2020.r * 683.0  + rgb2020.g * 2951.0 + rgb2020.b * 462.0) / 4096.0;
	float s = (rgb2020.r * 99.0   + rgb2020.g * 309.0  + rgb2020.b * 3688.0) / 4096.0;

	float lPQ = pqForward(l);
	float mPQ = pqForward(m);
	float sPQ = pqForward(s);

	return float3(
		(2048.0 * lPQ + 2048.0 * mPQ) / 4096.0,
		(6610.0 * lPQ - 13613.0 * mPQ + 7003.0 * sPQ) / 4096.0,
		(17933.0 * lPQ - 17390.0 * mPQ - 543.0 * sPQ) / 4096.0
	);
}

float3 iCtCpToLinearRGB(float3 ictcp)
{
	float lPQ = ictcp.x + 0.00860904 * ictcp.y + 0.11103 * ictcp.z;
	float mPQ = ictcp.x - 0.00860904 * ictcp.y - 0.11103 * ictcp.z;
	float sPQ = ictcp.x + 0.560031 * ictcp.y - 0.320627 * ictcp.z;

	float l = pqInverse(lPQ);
	float m = pqInverse(mPQ);
	float s = pqInverse(sPQ);

	float3 rgb2020 = float3(
		max( 3.43661 * l - 2.50645 * m + 0.06985 * s, 0),
		max(-0.79133 * l + 1.98360 * m - 0.19227 * s, 0),
		max(-0.02595 * l - 0.09891 * m + 1.12486 * s, 0)
	);

	return bt2020ToBt709(rgb2020);
}


// =========================================================================
// Hable Piecewise Filmic Curve (adaptive parameters)
// =========================================================================
// Toe and shoulder are power curve segments joined at a slope-controlled
// junction. The curve operates in log10 luminance space.
//
// Parameters adapt to scene brightness via two-stage smoothstep:
//   Night -> Evening -> Day
//
// Reference: John Hable, "Filmic Tonemapping with Piecewise Power Curves"
// http://filmicworlds.com/blog/filmic-tonemapping-with-piecewise-power-curves/
// =========================================================================

float Curve(float c0, float c1, float ca, float curveSlope, float X)
{
	float t = 1 + c1 - c0;
	return 2*t / (1 + exp((2*curveSlope/t) * (X - ca))) - c1;
}

float TonemapFilmic(float logLuminance)
{
	// Two-stage interpolation keyed off unclamped avgLum.
	// Night -> Evening: smoothstep(nightEnd, eveningMid)
	// Evening -> Day:   smoothstep(eveningMid, dayStart)
	float avgLum = max(getAverageLuminance(), 0.001);
	float tNightToEvening = smoothstep(gepNightEnd, gepEveningMid, avgLum);
	float tEveningToDay   = smoothstep(gepEveningMid, gepDayStart, avgLum);

	float curveSlope = lerp(lerp(gepNightSlope,     gepEveningSlope,     tNightToEvening), gepDaySlope,     tEveningToDay);
	float curveToe   = lerp(lerp(gepNightToe,       gepEveningToe,       tNightToEvening), gepDayToe,       tEveningToDay);
	float curveWC    = lerp(lerp(gepNightWhiteClip,  gepEveningWhiteClip, tNightToEvening), gepDayWhiteClip, tEveningToDay);

	float ta = (1 - curveToe - 0.18) / curveSlope - 0.733;
	float sa = (gepShoulder - 0.18) / curveSlope - 0.733;

	if (logLuminance < ta)
		return Curve(curveToe, gepBlackClip, ta, -curveSlope, logLuminance);
	else if (logLuminance < sa)
		return curveSlope * (logLuminance + 0.733) + 0.18;
	else
		return 1 - Curve(gepShoulder, curveWC, sa, curveSlope, logLuminance);
}


// =========================================================================
// GEP: Perceptual color volume tonemapping (ICtCp)
// =========================================================================
// The Hable curve is applied to scalar luminance in log10 space. ICtCp
// decomposes color into intensity and chrominance on perceptually uniform
// axes. Chroma is scaled using GT7's linear preservation blend
// (gepChromaPreserve), providing a perceptual floor that prevents visible
// desaturation for moderate brightness compression while still
// desaturating extreme highlights toward white.
//
// Near-black fallback: PQ has finite slope at zero (stable), but
// BT.709-to-BT.2020 rounding can shift color at very low values.
// Blend to simple luminance scaling below lum 0.005.
//
// Near-neutral protection: ICtCp round-trip through BT.2020 can
// produce pinkish tint on near-gray content (concrete, clouds) due
// to small gamut conversion rounding errors amplified on near-zero
// chroma. Blend to simple scaling when chroma magnitude is tiny.
// =========================================================================

float3 ToneMap_Filmic_Unrealic(float3 linearColor)
{
	const float3 LUM = { 0.2125, 0.7154, 0.0721 };
	float lum = dot(linearColor, LUM);

	if (lum <= 1e-6)
		return 0;

	// Apply the Hable curve to scalar luminance
	float logLum = log10(lum);
	float tonemappedLum = TonemapFilmic(logLum);

	// Simple luminance scaling path (always stable, hue-preserving)
	float scale = tonemappedLum / lum;
	float3 simpleResult = max(linearColor * scale, 0);

	// Near-black: BT.709-to-BT.2020 rounding at very low values
	float ictcpBlend = smoothstep(0.001, 0.005, lum);

	// ICtCp path: perceptually uniform intensity/chroma decomposition
	float3 ictcp = linearRGBToICtCp(linearColor);
	float I_in = ictcp.x;

	float I_out = linearRGBToICtCp(float3(tonemappedLum, tonemappedLum, tonemappedLum)).x;

	// GT7-style linear chroma preservation blend.
	// gepChromaPreserve = 0.6: 60% chroma preserved regardless of compression.
	// Perceptually motivated by the Hunt effect.
	float I_ratio = (I_in > 1e-6) ? (I_out / I_in) : 0;

	// Fade the chroma floor for extreme compression.
	// At moderate compression (I_ratio 0.3-1.0), full preserve active.
	// At extreme compression (I_ratio < 0.1), preserve fades toward
	// zero, letting the sun and extreme highlights desaturate to white.
	float preserveFade = smoothstep(0.02, 0.15, I_ratio);
	float effectivePreserve = gepChromaPreserve * preserveFade;
	float chromaScale = I_ratio * (1.0 - effectivePreserve) + effectivePreserve;
	float2 ctcp_out = ictcp.yz * chromaScale;

	float3 ictcpResult = max(iCtCpToLinearRGB(float3(I_out, ctcp_out)), 0);

	// Near-neutral protection: ICtCp round-trip on near-gray content
	// can produce pinkish tint from BT.2020 gamut conversion rounding.
	float chromaMagnitude = length(ictcp.yz);
	float neutralBlend = smoothstep(0.001, 0.01, chromaMagnitude);

	return lerp(simpleResult, ictcpResult, neutralBlend * ictcpBlend);
}


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
