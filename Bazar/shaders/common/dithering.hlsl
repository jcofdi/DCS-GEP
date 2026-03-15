#ifndef DITHERING_HLSL
#define DITHERING_HLSL

// ============================================================================
// DCS World — Unified Dithering Library
// ============================================================================
//
// COMPILE-TIME CONFIGURATION
// --------------------------
// Define ONE of these before including this header to select the default
// noise strategy used by the unified dither() / ditherAtmosphericHDR() API:
//
//   DITHER_MODE_BAYER        — Original 8x8 ordered dither (stock DCS)
//   DITHER_MODE_IGN          — Interleaved Gradient Noise (best WITH TAA)
//   DITHER_MODE_TPDF         — Triangular-PDF white noise (best WITHOUT TAA)
//   DITHER_MODE_R2           — R2 quasirandom low-discrepancy sequence
//   DITHER_MODE_BLUE_TEXTURE — Blue noise texture lookup (highest quality)
//
// If none is defined, defaults to DITHER_MODE_TPDF as the safest general-
// purpose choice that works well with or without temporal accumulation.
//
// All individual functions remain available regardless of which mode is
// selected — the mode only controls which one the unified API dispatches to.
//
// TEXTURE SETUP (DITHER_MODE_BLUE_TEXTURE only)
// ----------------------------------------------
// Requires a tileable blue noise texture bound to register t47 (last static
// slot before the dynamic commonPool at t48-t128). Format: R8_UNORM or
// R16_UNORM, dimensions should be power-of-two (64x64 or 128x128 typical).
// Point-wrap sampling via gPointWrapSampler (s9) preserves the spectral
// properties — filtering would destroy the blue noise distribution.
//
// If the texture is not bound, the shader will sample the engine's
// missing_texture fallback, producing ~0.5 constant. The TPDF procedural
// path is recommended as the automatic fallback for any build where the
// blue noise texture may not be present.
//
// ============================================================================

// ---- Default mode selection ------------------------------------------------
#if !defined(DITHER_MODE_BAYER) && !defined(DITHER_MODE_IGN) && \
    !defined(DITHER_MODE_TPDF) && !defined(DITHER_MODE_R2) && \
    !defined(DITHER_MODE_BLUE_TEXTURE)
  #define DITHER_MODE_TPDF
#endif


// ============================================================================
//  1. BAYER 8×8 ORDERED DITHER  (stock DCS)
// ============================================================================
// Classic threshold matrix. Produces a fixed, deterministic pattern that tiles
// every 8 pixels. Visually structured but guaranteed stable. Primary use in
// DCS is alpha-test dithering in modelShading.hlsl (dither8x8 discard).
//
// Output: [0, 1) uniform distribution over the 64 threshold levels.

static const uint ditherArray[8][8] =
{
    { 0, 32,  8, 40,  2, 34, 10, 42},   /* 8x8 Bayer ordered dithering  */
    {48, 16, 56, 24, 50, 18, 58, 26},   /* pattern. Each input pixel    */
    {12, 44,  4, 36, 14, 46,  6, 38},   /* is scaled to the 0..63 range */
    {60, 28, 52, 20, 62, 30, 54, 22},   /* before looking in this table */
    { 3, 35, 11, 43,  1, 33,  9, 41},   /* to determine the action.     */
    {51, 19, 59, 27, 49, 17, 57, 25},
    {15, 47,  7, 39, 13, 45,  5, 37},
    {63, 31, 55, 23, 61, 29, 53, 21}
};

float dither_ordered8x8(uint2 pixel)
{
    uint2 coord = uint2(pixel.xy) % 8;
    return (ditherArray[coord.x][coord.y] + 0.5) / 64.0;
}


// ============================================================================
//  2. INTERLEAVED GRADIENT NOISE  (Jimenez 2014)
// ============================================================================
// Non-repeating at screen scale, avoids Bayer's grid structure, and decorrelates
// cleanly with temporal offsets. The diagonal structure IS the feature — it gives
// TAA a maximally separable pattern to converge on. Without TAA, that same
// diagonal reads as visible banding on smooth gradients (sky, atmosphere).
//
// Output: [0, 1) quasi-uniform, spatially structured with high-frequency diagonal.
//
// Use: Optimal when TAA is enabled. Pass frame index for temporal variation.

float interleavedGradientNoise(float2 pixel, float frame)
{
    pixel += frame * float2(47.0, 17.0) * 0.695;
    return frac(52.9829189 * frac(0.06711056 * pixel.x + 0.00583715 * pixel.y));
}

float interleavedGradientNoise(float2 pixel)
{
    return interleavedGradientNoise(pixel, 0.0);
}


// ============================================================================
//  3. TRIANGULAR-PDF WHITE NOISE  (recommended for non-TAA)
// ============================================================================
// Two uncorrelated uniform hashes are summed and recentered to produce a
// triangular probability distribution on [-1, 1]. This is the same principle
// as TPDF dither in professional audio (Lipshitz, Wannamaker & Vanderkooy).
//
// Why triangular PDF is perceptually superior for quantization dither:
//   - Uniform dither (Bayer, IGN) adds equal probability of large and small
//     perturbations. On smooth gradients, the large perturbations are visible
//     as grain even after quantization.
//   - Triangular dither concentrates probability near zero: most pixels get
//     minimal perturbation, while the tail provides enough energy to fully
//     decorrelate quantization error from the input signal. The result is
//     that quantization error becomes constant-power, signal-independent
//     white noise — the mathematically optimal result for a single frame.
//   - With TPDF, the expected value of the dithered signal exactly equals the
//     original signal (zero mean error), AND the variance of the error is
//     independent of the signal. No other single-frame dither achieves both.
//
// The hash function uses integer arithmetic (pcg-family) rather than
// frac(sin(...)) to avoid precision issues on different GPU architectures.
// The sin-dot-frac pattern produces correlated clusters on some AMD GCN
// configurations and loses entropy on half-precision paths.
//
// Output: [-1, 1] triangular distribution, zero-mean. Caller scales to taste.
// For [0, 1) uniform output, use ditherTPDF_uniform() instead.

// ---- Integer hash core (PCG family) ----------------------------------------
// Single-round PCG-like hash. Two avalanche multiplies give full-period
// decorrelation from a 32-bit seed. Cost: 2 IMUL + 2 IADD + 2 shift = ~3 clk.
uint _pcgHash(uint input)
{
    uint state = input * 747796405u + 2891336453u;
    uint word  = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

// 2D → 1D seed: Szudzik pairing function (bijective for positive integers,
// unlike Cantor which wastes half the output range on negative values).
uint _seed2D(uint2 pixel)
{
    uint a = pixel.x;
    uint b = pixel.y;
    return (a >= b) ? (a * a + a + b) : (b * b + a);
}

// Uniform [0, 1) white noise at a pixel. Fast, no visible structure.
float _whiteNoise(uint2 pixel, uint salt)
{
    return float(_pcgHash(_seed2D(pixel) ^ salt)) / 4294967296.0; // / 2^32
}

// Triangular PDF [-1, 1] from two independent uniform samples.
// The `salt` values must differ to ensure independence.
float ditherTPDF(uint2 pixel, uint salt0, uint salt1)
{
    float u0 = _whiteNoise(pixel, salt0);
    float u1 = _whiteNoise(pixel, salt1);
    return u0 + u1 - 1.0; // sum of two [0,1) uniforms, recentered
}

// Convenience: static TPDF (no temporal variation). Uses fixed salts derived
// from primes that produce good spatial decorrelation across the frame.
float ditherTPDF(uint2 pixel)
{
    return ditherTPDF(pixel, 0x1B873593u, 0xCC9E2D51u);
}

// Convenience: TPDF with temporal variation driven by gModelTime.
// Hashes gModelTime into the salt so each frame gets a different pattern,
// providing temporal averaging for free even without explicit TAA.
// Requires context.hlsl to be included upstream (for gModelTime).
#ifdef CONTEXT_HLSL
float ditherTPDF_temporal(uint2 pixel)
{
    uint timeSalt = asuint(gModelTime);
    return ditherTPDF(pixel, timeSalt, _pcgHash(timeSalt));
}
#endif

// Uniform [0, 1) output variant — for callers that need the same range as
// dither_ordered8x8() or interleavedGradientNoise().
float ditherTPDF_uniform(uint2 pixel)
{
    return _whiteNoise(pixel, 0x1B873593u);
}

float ditherTPDF_uniform(uint2 pixel, uint salt)
{
    return _whiteNoise(pixel, salt);
}


// ============================================================================
//  4. R2 QUASIRANDOM SEQUENCE  (Martin Roberts)
// ============================================================================
// The R2 sequence is a 2D low-discrepancy sequence based on the plastic
// constant (the unique real root of x³ = x + 1). It produces sample points
// that are maximally spread across the unit square — closer to blue noise
// than any other known algebraic sequence.
//
// Unlike IGN, it has no visible directional structure. Unlike white noise,
// it avoids clumping. It's essentially "poor man's blue noise" with zero
// texture cost and a single FMA per dimension.
//
// The per-pixel index is derived from screen position. For temporal variation,
// pass a frame offset (each frame shifts the sequence by one step, which
// maintains the low-discrepancy property across the spatiotemporal domain).
//
// Output: [0, 1) quasi-uniform with blue-noise-like spatial distribution.

// Plastic constant reciprocals (1/φ₁, 1/φ₂ where φ is the plastic number)
static const float _R2_A1 = 0.7548776662466927; // 1 / plastic constant
static const float _R2_A2 = 0.5698402909980532; // 1 / plastic constant²

float ditherR2(uint2 pixel, float frameOffset)
{
    // Use pixel index as the sequence step. The 0.5 seed offset avoids
    // the origin artifact that all additive recurrence sequences share.
    float index = float(pixel.x + pixel.y * 1920u) + frameOffset; // 1920 arbitrary coprime
    return frac(0.5 + index * _R2_A1);
}

float ditherR2(uint2 pixel)
{
    return ditherR2(pixel, 0.0);
}

// 2D variant — returns two decorrelated [0,1) values with joint low-discrepancy.
// Useful for 2D jitter (e.g., SSAO ray direction + radius).
float2 ditherR2_2D(uint2 pixel, float frameOffset)
{
    float index = float(pixel.x + pixel.y * 1920u) + frameOffset;
    return frac(0.5 + index * float2(_R2_A1, _R2_A2));
}


// ============================================================================
//  5. BLUE NOISE TEXTURE LOOKUP
// ============================================================================
// The gold standard for single-frame dithering. A precomputed blue noise
// texture has energy concentrated in high spatial frequencies with no low-
// frequency content — meaning no visible patterns, clumps, or structure at
// any scale. The result looks like fine, uniform film grain.
//
// Register t47: last static slot before the dynamic pool (t48+).
// Sampled with gPointWrapSampler (s9) to preserve spectral properties.
// Tiling is handled by the wrap addressing mode.
//
// If a DITHER_BLUE_NOISE_SIZE define is provided, the texture dimensions
// are used for proper integer-coordinate addressing. Otherwise, defaults
// to 64 (the most common blue noise tile size).
//
// To use: place a tileable blue noise .dds (R8_UNORM or R16_UNORM, 64x64
// or 128x128) at a path the engine will load into t47. See the project
// documentation for viable injection points (lightPalette.tif ghost slot,
// or a custom texture resource declaration).

#ifndef DITHER_BLUE_NOISE_SIZE
  #define DITHER_BLUE_NOISE_SIZE 64
#endif

#ifdef DITHER_MODE_BLUE_TEXTURE
  // Declare only when this mode is selected, to avoid binding errors
  // in shader permutations that don't have the texture available.
  Texture2D<float> gBlueNoiseTexture : register(t47);
#endif

// Explicit lookup — always available if caller declares the texture themselves.
// Takes the texture as a parameter so it works regardless of register binding.
float ditherBlueNoise(Texture2D<float> blueTex, uint2 pixel)
{
    uint2 coord = pixel % DITHER_BLUE_NOISE_SIZE;
    return blueTex.Load(int3(coord, 0));
}

float ditherBlueNoise(Texture2D<float> blueTex, uint2 pixel, float frame)
{
    // Temporal: shift the tile offset each frame. The golden ratio offset
    // (Kronecker/R1 sequence) gives optimal temporal low-discrepancy.
    uint temporalOffset = uint(frame * DITHER_BLUE_NOISE_SIZE * 0.7548776662) % DITHER_BLUE_NOISE_SIZE;
    uint2 coord = (pixel + uint2(temporalOffset, temporalOffset * 3u + 7u)) % DITHER_BLUE_NOISE_SIZE;
    return blueTex.Load(int3(coord, 0));
}

// Convenience overloads using the default gBlueNoiseTexture binding.
#ifdef DITHER_MODE_BLUE_TEXTURE
float ditherBlueNoise(uint2 pixel)
{
    return ditherBlueNoise(gBlueNoiseTexture, pixel);
}
float ditherBlueNoise(uint2 pixel, float frame)
{
    return ditherBlueNoise(gBlueNoiseTexture, pixel, frame);
}
#endif


// ============================================================================
//  6. UNIFIED API
// ============================================================================
// These functions dispatch to the selected mode at compile time. All callers
// of the old ditherAtmosphericHDR() get the upgraded path automatically.
//
// dither(pixel)          → [0, 1) suitable for threshold comparisons
// ditherCentered(pixel)  → [-0.5, 0.5] suitable for additive noise
// ditherTriangular(pixel)→ [-1, 1] triangular PDF (TPDF only; others approximate)

// ---- [0, 1) uniform output -------------------------------------------------
float dither(uint2 pixel)
{
#if defined(DITHER_MODE_BAYER)
    return dither_ordered8x8(pixel);
#elif defined(DITHER_MODE_IGN)
    return interleavedGradientNoise(float2(pixel));
#elif defined(DITHER_MODE_TPDF)
    return ditherTPDF_uniform(pixel);
#elif defined(DITHER_MODE_R2)
    return ditherR2(pixel);
#elif defined(DITHER_MODE_BLUE_TEXTURE)
    return ditherBlueNoise(pixel);
#endif
}

float dither(uint2 pixel, float frame)
{
#if defined(DITHER_MODE_BAYER)
    return dither_ordered8x8(pixel); // Bayer has no temporal variant
#elif defined(DITHER_MODE_IGN)
    return interleavedGradientNoise(float2(pixel), frame);
#elif defined(DITHER_MODE_TPDF)
    uint timeSalt = asuint(frame * 60.0); // approximate frame index from time
    return ditherTPDF_uniform(pixel, timeSalt);
#elif defined(DITHER_MODE_R2)
    return ditherR2(pixel, frame);
#elif defined(DITHER_MODE_BLUE_TEXTURE)
    return ditherBlueNoise(pixel, frame);
#endif
}

// ---- [-0.5, 0.5] centered output -------------------------------------------
float ditherCentered(uint2 pixel)
{
    return dither(pixel) - 0.5;
}

float ditherCentered(uint2 pixel, float frame)
{
    return dither(pixel, frame) - 0.5;
}

// ---- [-1, 1] triangular PDF output -----------------------------------------
// TPDF mode returns native triangular distribution. Other modes approximate
// by remapping their uniform output through an inverse-triangular CDF, which
// is algebraically exact: TPDF = u0 + u1 - 1 ≈ (sign * sqrt) remap of single
// uniform. The remap costs one sqrt and one compare but maintains the zero-mean,
// signal-independent-variance property that makes TPDF optimal.
float ditherTriangular(uint2 pixel)
{
#if defined(DITHER_MODE_TPDF)
    return ditherTPDF(pixel);
#else
    // Approximate TPDF from uniform: inverse triangular CDF remap
    float u = dither(pixel);
    // Piecewise: if u < 0.5 → -1 + sqrt(2u), else 1 - sqrt(2(1-u))
    return (u < 0.5)
        ? -1.0 + sqrt(2.0 * u)
        :  1.0 - sqrt(2.0 * (1.0 - u));
#endif
}


// ============================================================================
//  7. ATMOSPHERIC DITHER HELPER
// ============================================================================
// Pre-tonemap ADDITIVE dithering for HDR atmospheric color. Breaks LUT
// quantization banding by adding noise in linear HDR space.
//
// The key insight: LUT banding produces fixed-size steps in radiance. We need
// additive noise at that absolute scale to break the bands — NOT multiplicative
// noise that scales with signal.
//
// TPDF is the correct distribution here: it makes quantization error both
// zero-mean AND signal-independent in variance — the only single-frame dither
// distribution that achieves both. (Uniform dither is zero-mean but its error
// variance depends on where the signal sits within the quantization interval.)
//
// ditherAmplitude: absolute noise amplitude in HDR radiance units. Should
//   roughly match one quantization step of the scattering LUT. Typical range:
//   0.0005 – 0.002. After tonemapping + gamma → ~1 code value in 8-bit.
//
// IMPORTANT: Same noise value on all three channels (grayscale dither) to
// avoid introducing chrominance artifacts. LUT banding is primarily a
// luminance quantization issue.

float3 ditherAtmosphericHDR(float3 color, float2 pixelPos, float ditherAmplitude)
{
#if defined(DITHER_MODE_TPDF)
    // Native triangular: zero-mean, optimal error statistics.
    float noise = ditherTPDF(uint2(pixelPos)) * 0.5; // normalize [-1,1] to [-0.5,0.5]
#elif defined(DITHER_MODE_BLUE_TEXTURE)
    // Blue noise texture remapped to centered [-0.5, 0.5] for atmospheric use.
    // The spatial distribution is excellent; we sacrifice TPDF's error-variance
    // optimality for blue noise's superior spatial decorrelation.
    float noise = ditherBlueNoise(uint2(pixelPos)) - 0.5;
#elif defined(DITHER_MODE_R2)
    float noise = ditherR2(uint2(pixelPos)) - 0.5;
#elif defined(DITHER_MODE_IGN)
    float noise = interleavedGradientNoise(pixelPos) - 0.5;
#else
    float noise = dither_ordered8x8(uint2(pixelPos)) - 0.5;
#endif

    return color + noise * ditherAmplitude;
}

// Overload with temporal parameter for modes that benefit from it.
float3 ditherAtmosphericHDR(float3 color, float2 pixelPos, float ditherAmplitude, float frame)
{
#if defined(DITHER_MODE_TPDF)
    uint timeSalt = asuint(frame * 60.0);
    float noise = ditherTPDF(uint2(pixelPos), timeSalt, timeSalt ^ 0xDEADBEEFu) * 0.5;
#elif defined(DITHER_MODE_BLUE_TEXTURE)
    float noise = ditherBlueNoise(uint2(pixelPos), frame) - 0.5;
#elif defined(DITHER_MODE_R2)
    float noise = ditherR2(uint2(pixelPos), frame) - 0.5;
#elif defined(DITHER_MODE_IGN)
    float noise = interleavedGradientNoise(pixelPos, frame) - 0.5;
#else
    float noise = dither_ordered8x8(uint2(pixelPos)) - 0.5;
#endif

    return color + noise * ditherAmplitude;
}


// ============================================================================
//  8. QUANTIZATION-AWARE OUTPUT DITHER
// ============================================================================
// Final-stage dither for the tonemap output, targeting the specific bit-depth
// of the render target. This replaces the truncation error of float→UNORM
// conversion with optimal noise.
//
// Apply AFTER tonemapping, BEFORE the hardware does float→UNORM conversion.
// The noise amplitude is exactly ±0.5 code values in the target format.
//
// For 8-bit (R8G8B8A8_UNORM):  step = 1/255
// For 10-bit (R10G10B10A2):    step = 1/1023

float3 ditherOutput8bit(float3 color, uint2 pixel)
{
    float noise = ditherTriangular(pixel);
    float lum = max(color.r, max(color.g, color.b));
    float strength = lerp(0.25, 1.0, smoothstep(0.0, 0.12, lum));
    return color + noise * (0.5 / 255.0) * strength;
}

float3 ditherOutput10bit(float3 color, uint2 pixel)
{
    float noise = ditherTriangular(pixel);
    return color + noise * (0.5 / 1023.0);
}


#endif // DITHERING_HLSL
