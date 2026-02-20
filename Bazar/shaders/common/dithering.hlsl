#ifndef DITHERING_HLSL
#define DITHERING_HLSL

static const uint ditherArray[8][8] = 
{
	{ 0, 32, 8, 40, 2, 34, 10, 42}, /* 8x8 Bayer ordered dithering */
	{48, 16, 56, 24, 50, 18, 58, 26}, /* pattern. Each input pixel */
	{12, 44, 4, 36, 14, 46, 6, 38}, /* is scaled to the 0..63 range */
	{60, 28, 52, 20, 62, 30, 54, 22}, /* before looking in this table */
	{ 3, 35, 11, 43, 1, 33, 9, 41}, /* to determine the action. */
	{51, 19, 59, 27, 49, 17, 57, 25},
	{15, 47, 7, 39, 13, 45, 5, 37},
	{63, 31, 55, 23, 61, 29, 53, 21}
};

float dither_ordered8x8(uint2 pixel)
{
	uint2 coord = uint2(pixel.xy) % 8;
	return (ditherArray[coord.x][coord.y] + 0.5) / 64.0;
}

// ========== INTERLEAVED GRADIENT NOISE ==========
// Jorge Jimenez, "Next Generation Post Processing in Call of Duty: Advanced Warfare"
// SIGGRAPH 2014. Produces perceptually superior results to Bayer ordered dithering
// for smooth gradients (atmosphere, volumetrics, fog). The pattern is non-repeating
// at screen scale, avoids the grid structure of Bayer, and is temporally stable.
//
// Returns a value in [0, 1). Pass an optional frame index for temporal variation
// (e.g. when using TAA — each frame gets a different noise offset).
float interleavedGradientNoise(float2 pixel, float frame)
{
	pixel += frame * float2(47.0, 17.0) * 0.695;
	return frac(52.9829189 * frac(0.06711056 * pixel.x + 0.00583715 * pixel.y));
}

// Convenience overload without temporal offset (static noise, no TAA dependency)
float interleavedGradientNoise(float2 pixel)
{
	return interleavedGradientNoise(pixel, 0.0);
}

// ========== ATMOSPHERIC DITHER HELPER ==========
// Pre-tonemap ADDITIVE dithering for HDR atmospheric color. Breaks LUT quantization
// bands by adding a fixed absolute noise value in linear HDR space.
//
// The key insight: LUT banding produces fixed-size steps in radiance regardless of
// brightness. A single quantization step in the scattering LUT might be ~0.001 in
// HDR radiance units. We need additive noise at that same absolute scale to break
// the bands — NOT multiplicative noise that scales with the signal.
//
// ditherAmplitude: absolute noise amplitude in HDR radiance units. This should be
//   tuned to roughly match one quantization step of the scattering LUT. Values in
//   the range 0.0005 - 0.002 are typical. After tonemapping and gamma, this
//   translates to ~1 code value of noise in 8-bit output, which is imperceptible.
//
// IMPORTANT: This adds the SAME noise value to all three channels (grayscale noise)
//   to avoid introducing false chrominance / color shifts. LUT banding is primarily
//   a luminance quantization artifact — chrominance noise would be far more visible.
float3 ditherAtmosphericHDR(float3 color, float2 pixelPos, float ditherAmplitude)
{
	float noise = interleavedGradientNoise(pixelPos) - 0.5; // centered [-0.5, 0.5]
	return color + noise * ditherAmplitude;
}

#endif