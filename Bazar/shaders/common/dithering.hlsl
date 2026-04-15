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
//   DITHER_MODE_BAYER         — Original 8x8 ordered dither (stock DCS)
//   DITHER_MODE_IGN           — Interleaved Gradient Noise (best WITH TAA)
//   DITHER_MODE_TPDF          — Triangular-PDF white noise (best WITHOUT TAA)
//   DITHER_MODE_R2            — R2 quasirandom low-discrepancy sequence
//   DITHER_MODE_BLUE_COMPUTED — Blue noise grid lookup (highest quality)
//
// If none is defined, defaults to DITHER_MODE_BLUE_COMPUTED as the safest general-
// purpose choice that works well with or without temporal accumulation.
//
// All individual functions remain available regardless of which mode is
// selected — the mode only controls which one the unified API dispatches to.
//
// TEXTURE SETUP (DITHER_MODE_BLUE_COMPUTED only)
// ----------------------------------------------
// Attempts to hijack any unused texture slots were fruitless, so
// could not use actual blue noise texture file. However, as blue noise
// is a 64x64 grayscale grid, can simply replicate each pixel value within
// shader by writing luminance values directly. Technically takes up more
// space but ultimately still a negligible cost with all of the resulting
// benefits that blue noise brings.
//
// ============================================================================

#if !defined(DITHER_MODE_BAYER) && !defined(DITHER_MODE_IGN) && \
    !defined(DITHER_MODE_TPDF) && !defined(DITHER_MODE_R2) && \
    !defined(DITHER_MODE_BLUE_TEXTURE) && !defined(DITHER_MODE_BLUE_COMPUTED)
  #define DITHER_MODE_BLUE_COMPUTED
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
// Each pixel's value is computed by 2D additive recurrence over screen
// position using both plastic constant reciprocals on independent axes.
// For temporal variation, pass a frame offset that shifts the sequence
// while preserving the 2D low-discrepancy spatial distribution.
//
// Output: [0, 1) quasi-uniform with blue-noise-like spatial distribution.

// Plastic constant reciprocals (1/φ₁, 1/φ₂ where φ is the plastic number)
static const float _R2_A1 = 0.7548776662466927; // 1 / plastic constant
static const float _R2_A2 = 0.5698402909980532; // 1 / plastic constant²

float ditherR2(uint2 pixel, float frameOffset)
{
    // The 0.5 seed offset avoids the origin artifact that all additive
    // recurrence sequences share.
    return frac(0.5 + float(pixel.x) * _R2_A1 + float(pixel.y) * _R2_A2 + frameOffset * _R2_A1);
}

float ditherR2(uint2 pixel)
{
    return ditherR2(pixel, 0.0);
}

// 2D variant — returns two decorrelated [0,1) values with joint low-discrepancy.
// Useful for 2D jitter (e.g., SSAO ray direction + radius).
float2 ditherR2_2D(uint2 pixel, float frameOffset)
{
    // 2D variant returning two decorrelated [0,1) values.
    return frac(0.5 + float2(
        float(pixel.x) * _R2_A1 + float(pixel.y) * _R2_A2 + frameOffset * _R2_A1,
        float(pixel.x) * _R2_A2 + float(pixel.y) * _R2_A1 + frameOffset * _R2_A2
    ));
}


// ============================================================================
//  5. COMPUTED GAUSSIAN BLUE NOISE LOOKUP (64x64, packed)
// ============================================================================
// Gaussian Blue Noise dither matrix generated via modified void-and-cluster
// with rank-adaptive sigma (Ahmed et al., 'Gaussian Blue Noise', 2022).
//
// Standard blue noise has a sharp high-pass spectral cutoff that can produce
// subtle ringing at the transition frequency. Gaussian BN replaces the hard
// step with a smooth Gaussian rolloff, eliminating ringing entirely.
//
// Generation parameters: sigma 3.0->0.5, profile width 0.55
//
// DFT-verified spectral properties:
//   - Low freq (1-3):   0.00008  (near-zero, no visible patterns)
//   - Mid freq (8-16):  0.1765   (smooth Gaussian rolloff, no ringing)
//   - High freq (25+):  0.7988   (full noise energy)
//   - Isotropy:         1.016x   (no directional bias)
//   - Histogram:        perfect uniform, 256 unique values
//   - Tiling:           seamless 64x64
//
// Packed: 4 values per uint (8-bit each), 64x16 = 1024 entries.
// Well within SM5.0 indexable literal limit of 4096.

#define _BN_SIZE 64

static const uint _blueNoisePacked64[64][16] =
{
    {0xC0991DD9, 0xAA3DD56A, 0xC3657C18, 0xC90B4A2F, 0xAE6F071D, 0x0BA03F67, 0x4113A850, 0xF6C573E5, 0x8B6A0345, 0x719F2CBB, 0x06F651E3, 0x1E7EEE17, 0x07C2866A, 0x2BD06F80, 0x68C9FA7C, 0x2EA8E889},
    {0xE33A1663, 0x874778A6, 0xB1DA0FF5, 0x29DE9653, 0xE98FD6A3, 0xEAB85CCC, 0x8132698B, 0xA52A175B, 0x0FECCD84, 0x5CEECF56, 0x64A61DB5, 0x573E0E8B, 0x5EA629EB, 0xE79FB4DD, 0xE137A716, 0x49CA27B5},
    {0x5A84B574, 0xC0DD9111, 0xA1376E9D, 0x626C81F2, 0x472377FB, 0x77D21680, 0xFBC0DB26, 0xE0B99306, 0x4A9A3179, 0x900080AC, 0x48D42743, 0xAE98DEB4, 0x97F373CF, 0x598D2052, 0x98734E02, 0xE43E7E1F},
    {0x34CFF88E, 0x4D642CEB, 0x1B41E827, 0x8BB602C8, 0x0FC7B33A, 0x9A01FB30, 0x9DAC4A3B, 0x546CD20F, 0x3ADC5F23, 0xDF6818FA, 0xE97A9BC5, 0x314EC737, 0x4B1A4301, 0xD63CF6C1, 0xD943EBBF, 0x559FFB5C},
    {0x6F24A502, 0x03FBACC5, 0x5E85C458, 0xEB13DD22, 0xDB9A505A, 0xB45489AA, 0x7963F020, 0xF788AFE4, 0x09B1C23F, 0x3475BF95, 0x6E08F911, 0x65FB845B, 0xE388D9BD, 0x78682509, 0x120AAB84, 0xC00C32C5},
    {0x514513EB, 0x7F1F0A98, 0xFB90DCA5, 0xCBA67948, 0x66F51942, 0xE85FC337, 0x451A8FC7, 0x1D4E382D, 0x6413E4A3, 0xABE94FDA, 0x2CB85587, 0x781523A8, 0x7C36AA93, 0x9C33B7A1, 0x94642DFB, 0x69D886B1},
    {0xBADA7FB3, 0x3BD0E588, 0xAE7230B9, 0x2C9534C0, 0x71067FE1, 0x6D2AE393, 0x58D48209, 0xD803F0C2, 0x896F7C8F, 0x3D21A12E, 0xF093DB61, 0xE49FDCC3, 0x6C5FF70F, 0x4817EFCA, 0x6EE353B9, 0x2A4D77F4},
    {0xF1406091, 0x9574671B, 0x0D6616F5, 0x0B6A4FEC, 0xD1B19FBB, 0x404D7B1E, 0x72FBB19E, 0xB76896A5, 0xD558FB27, 0xD180F445, 0x1B0C4AB2, 0x066B8C42, 0xDD2C55C9, 0xDF5B1190, 0x231CCC8E, 0x19E4389E},
    {0xA4789DF7, 0x46C75B37, 0x9ED80753, 0xFA87C927, 0x4625DB5E, 0xF4A8BCF1, 0x230E33CC, 0xCF5D81E0, 0xBD9D340D, 0x0328B51B, 0x7EC972FB, 0x27B7513A, 0x1EBB3C48, 0xA57441B0, 0xB53E7F06, 0xBB5946CE},
    {0xD3C02F07, 0x85EDB226, 0x7D40ABDD, 0x3BA7E057, 0x56328E75, 0x18049811, 0xBF50668A, 0x43E6153D, 0xEC07AD4B, 0x6B905D78, 0xEDA3319B, 0xA9F9D262, 0xE99B8AD9, 0xC6F3834F, 0xDD5FF829, 0xD7A78900},
    {0xFB0C5421, 0x9D12014C, 0x91FCBE2B, 0x001FB61A, 0x62C6E94B, 0xDA39E485, 0xD97DE95B, 0x76A08D2B, 0x5292C8EF, 0xC0E7CF11, 0xB0D45817, 0x5C81961F, 0x037AF272, 0x37630CD4, 0x94506FB3, 0x7367F511},
    {0x896EE23D, 0x6AC47D96, 0xCC365F22, 0xC1F16370, 0xFC9DAE14, 0xB576C16B, 0x00A99527, 0x6DC0F4B3, 0xD9658421, 0x4736A440, 0x77058BF1, 0x1234C42B, 0x3166C618, 0xE091C0A4, 0xACE6169C, 0xCD8032C5},
    {0xCE63AD8E, 0xD7F233B6, 0xE64D8B78, 0x978344A1, 0x083F7CE3, 0x44532EAA, 0x49FC6DD3, 0xD4085563, 0xB8E83A2F, 0xAE812471, 0x10DE6650, 0xA1E24DF5, 0x2545B109, 0x492058F8, 0x7886CD2F, 0x9AEB4B27},
    {0x1647F5C0, 0xA25541E5, 0x040EF4B4, 0x53CD30B9, 0x22DB2A6C, 0x0BF6CB92, 0xC98513A3, 0xAD981C37, 0x01A218FC, 0x0AD9F98C, 0x9FBC3CCD, 0x8CB76C44, 0xD895CEFC, 0xF27DB770, 0xFC56096A, 0x1DA90D42},
    {0x75102938, 0x091C5DA6, 0x1799C63B, 0x38F624DD, 0x4E5BC60E, 0x8C7A1BE9, 0xE13F20E4, 0x5D89EE79, 0x2ACD7A4E, 0x1E98C160, 0x2593FC7B, 0x3F57D285, 0x395F517B, 0x3DD41487, 0xB4DAA2C4, 0x5CE1CC64},
    {0xD785DE52, 0x2DC2FC92, 0x687FDF73, 0x8D76A659, 0x82A5EFB2, 0x5E6635B7, 0x9D30AFBF, 0xDE26C6B4, 0x55E795BB, 0x5AA93249, 0x60AF2D6F, 0xE800A9F1, 0xACEF1B2E, 0xAE029EE2, 0x19358D5E, 0x7B067097},
    {0xBA0399B2, 0x8AD36824, 0xF9AF5245, 0xDABD4987, 0x71991662, 0x97C7DF03, 0x6F58F84C, 0x1345670A, 0xAD6B0C3E, 0xECD310F4, 0x36DEC715, 0x21C3740B, 0x286BC19C, 0x75FC4B0F, 0x7F24F01D, 0xF989BDED},
    {0x3EEB6CCF, 0x9CAC814D, 0xC82861F2, 0x1E96E03E, 0xFAD0420A, 0xEB3BA947, 0xDD057E2A, 0x81A9F193, 0xD88EC7F8, 0x41678577, 0x53824B8F, 0x6492D719, 0x808EDFAE, 0x439455CC, 0xD64FB7D0, 0x2E45A23B},
    {0x5834A561, 0x02E218F2, 0x1490BE20, 0xF86F0633, 0xBF567E2C, 0x15108726, 0x1ABEA5D2, 0x732CCE50, 0x0720A334, 0xB29DC539, 0xA7BFF403, 0xF77F3BED, 0xF6063349, 0x2BDA65B8, 0x6B059B83, 0x21E91559},
    {0xD079C312, 0x3870BD0E, 0xD010A4D6, 0xCA50ACF0, 0x3168DAB3, 0x556BE794, 0x61EA8A74, 0xE0B9883A, 0xB9E75E53, 0xD1EF1A28, 0x2A977623, 0x135AB76A, 0xA57742C5, 0x6EA23717, 0xFCC231F3, 0x924CD1AD},
    {0xAD8CFA08, 0x305E489B, 0x786BFC7D, 0x39835D9A, 0xACF38E9E, 0xFCBACE1F, 0xAC234299, 0x029A0EFC, 0x478A65CA, 0x577E50DD, 0x46E30862, 0xDE0DA0D3, 0x5DD45389, 0xB2E109EB, 0x8E0C6013, 0xE4B92977},
    {0xE0425170, 0x87CBF728, 0x414A57B5, 0xF123C2DF, 0x5C074B75, 0xB0017B3F, 0xCB34DF49, 0xF14A1E78, 0xA0FA17AD, 0x3595AD71, 0x318AB9F8, 0x2772FC1E, 0x1EBAF5AB, 0xCB793E90, 0xD5A7E849, 0x809C6540},
    {0x831CB630, 0xE9920669, 0xB21BE09D, 0xD664008D, 0xEBBC1219, 0x0D629FD5, 0x5B69C22D, 0x846DD99F, 0xCB407B25, 0x3DBEE92E, 0x4FCEA46D, 0x99C86081, 0x9D6E2E04, 0x578825C6, 0x527F1F96, 0xDDC81AED},
    {0x21CBEA5B, 0x503D76A4, 0x2CD0250B, 0x45B90DEF, 0x6E2BCFA3, 0x8FE05084, 0xE51782F0, 0x583CBE8E, 0x0493C1E4, 0xDF880B5C, 0xB1EC1015, 0xEC8FBA40, 0xD97F663A, 0xE7AAFB4E, 0x35CAB92A, 0x39AA8703},
    {0xF3649910, 0x17B0D8BD, 0xA17467C1, 0x54E57D35, 0xB595FC89, 0x39BC1B34, 0x05B6A472, 0x30B0EC29, 0x68DB14A1, 0x4BCD1FF6, 0x59779726, 0x4B17E302, 0x44EFB5D0, 0xD2006319, 0x72F4456A, 0x49FC24A2},
    {0x3600AF8F, 0x44FD2D57, 0x5AF884DF, 0xAD6C94C6, 0x5825793D, 0x22E9A5D9, 0x0BFD56D3, 0xFD45654F, 0x5238B60F, 0x809FAB78, 0xD267C3FD, 0x227935A2, 0xA5108656, 0x3974B732, 0x5E970D84, 0xCC6BBBD7},
    {0x4CC873E8, 0x6111978A, 0xB33A90A7, 0x2F1EF24D, 0xF166C6E1, 0x607A440A, 0xD93F9B12, 0x8CD6987D, 0x97E98172, 0x6042E3C4, 0xF11B2DB0, 0xA6FDC387, 0xC90A94DD, 0x9FC58DE4, 0xE5B31CDA, 0x7C55098B},
    {0x80DC182B, 0x7CCB6CEC, 0x04E6CF08, 0xB860D015, 0xAE4A0610, 0xF796CD8A, 0x6E88C44A, 0x221AC5AA, 0x2849C85B, 0x550E6E31, 0x45913AE2, 0x612A6D09, 0x5DF871BE, 0x14F1517A, 0x3D4DFD59, 0x43F3152F},
    {0x0D3EA6BC, 0x33E4BCA2, 0x29702153, 0xE99B8943, 0x72D7A283, 0x69B73015, 0x2FEDB028, 0xB901F536, 0xF108A4E5, 0x00F58FB2, 0xDBBD75CE, 0xE5129A53, 0x271D483C, 0x2D074099, 0x7767C2A8, 0xD79BAFD0},
    {0x5CF99250, 0xAF481D27, 0xAA94C4F8, 0x5273BDFA, 0x5D90F938, 0x83E301EE, 0xD21E07DB, 0x9C52775F, 0x62D73B6A, 0x9BB9187D, 0x5E21A684, 0x82CDF3AE, 0xBCD32FB0, 0xCB6DD8AB, 0xA4268F7D, 0x056082ED},
    {0xB46822E6, 0x9B3977E2, 0xDB5C6883, 0x1CD50C7E, 0xD0B54227, 0x52A13E20, 0x47945A74, 0x41DD8BB7, 0x4F1C85FA, 0x36DD24C9, 0xE34CFA13, 0x76058D32, 0x66EAA04F, 0x4921FA84, 0x450FD7EE, 0x70381EBD},
    {0xD584CC32, 0x14EE8E05, 0x3DBB2FD4, 0xE5A7644A, 0x9C566BC2, 0xD336C07E, 0xA015F9AA, 0x0CCB26EF, 0xAB91BB2D, 0x675A46F8, 0x7E2870CC, 0xBD1A41C8, 0x36028FFD, 0x61B39355, 0xE702349C, 0xB8FD8C57},
    {0x44549D7A, 0x4EC963A5, 0x12A0E601, 0x039233F1, 0x18ED2D7A, 0x8D62FD4C, 0xDA3BC40E, 0xA6126680, 0x03D55675, 0xE68B779E, 0x0CA1B43F, 0x5ADBAB65, 0x0E15C86A, 0x3B1976D1, 0xCC7285BB, 0xA7D36598},
    {0x2C10F01A, 0x7359BBFD, 0x8B251BB3, 0xFDBA58C9, 0xD888CCA0, 0xE22AB270, 0xAF6C7A43, 0xE2964C05, 0x6D33F2C2, 0x51BC2BE7, 0xD5EE0592, 0x2538F598, 0x447CE39C, 0x08F2BFE6, 0x4FA7FDD4, 0x490B2913},
    {0x6EDBC28A, 0x40E28136, 0xDD79FB93, 0x22826FAD, 0xA9136047, 0x23CA940B, 0x5731F31A, 0x39B6FDD3, 0x1443815E, 0xFDA80AC4, 0x851630CA, 0x4A1F7354, 0x5EBA87AF, 0x2B4DA699, 0xEA415B6A, 0x3DF3ADC2},
    {0xB195075E, 0xA80B9D21, 0x44526ACB, 0xCE0EED08, 0x34F6B33C, 0x9C68E604, 0x90C186B5, 0x89712A1F, 0xD8B02218, 0x203A8463, 0x44BC5F7C, 0xEEC390CF, 0x70F9092C, 0x7D8A2632, 0x912017B1, 0xDF6B7680},
    {0xD2774EB6, 0xF22917EC, 0xA4C38531, 0xE1669837, 0xD1758F50, 0x485B8054, 0xA0DE51EA, 0xED46C761, 0x4CFDA2D2, 0x1A58E599, 0xF86CA5D6, 0x627AAC0F, 0xD2523FDB, 0xE2C8EF1E, 0x38BAD196, 0xA0CC2FD6},
    {0x653AF51D, 0x4BBF8C47, 0x5D1FDB62, 0x2919B8D6, 0x419EEAC0, 0xA6CCF0BA, 0x0C3F7307, 0x9700AAF4, 0x8E79BF53, 0x74AFC80E, 0x294D97F0, 0x9F34E901, 0xAA90C718, 0x4658B567, 0x620CF873, 0x562504EE},
    {0xA986C1DC, 0x7AE35ACB, 0x2CEE03B6, 0xA972FD8C, 0x116B3084, 0x2D398C1D, 0x36BD16D3, 0x30E07882, 0x6F063D67, 0x3547F727, 0x3CDEC388, 0x6D88D45C, 0xE77F04B6, 0x01143C10, 0x875233A1, 0x8F43AF9C},
    {0x1200327D, 0x10A26DF9, 0x15AE3B92, 0xE34A567D, 0xFED45A01, 0x6079AE26, 0xEA6996FE, 0xB5115AD0, 0xDECAEB1C, 0x66BCA02D, 0x80B32307, 0x5713BE95, 0x75D447EB, 0x83C0FB9B, 0xE769ADEB, 0x70FBC848},
    {0xBA2BD6A7, 0xC5243E54, 0xE29A73FE, 0xC9973FC5, 0xC4A37B20, 0xC2E54D95, 0x28B38821, 0xF7C6934D, 0x55AE84A1, 0xEC8D405F, 0x73FA5414, 0xC9F742A9, 0x2936A423, 0x5ED58A4C, 0xBE1BC923, 0x170F5C7A},
    {0xE69C61E8, 0x0AE08090, 0x6946D551, 0x10F4AA06, 0x6545ECB6, 0x026EBB0C, 0x14D855A0, 0x246E41A8, 0x0F913548, 0xD77CC5EF, 0x0A31CFA3, 0x2E4F1DE5, 0x5AF66591, 0x2D6DA6BA, 0x088EE13F, 0xBB98D929},
    {0x741F4B40, 0x1BA735D1, 0x32BC6389, 0x618825E8, 0x53D19135, 0xEF32DE86, 0x08F7447E, 0x62DC8ACD, 0x74C2D87E, 0x6D011FA8, 0xBA60914A, 0xAF7B9E68, 0x06C883E2, 0x7CF20DDC, 0xA9724E9A, 0x695135F4},
    {0x07FE8AC7, 0xB9F567B0, 0xA259F22A, 0xDA4F77CF, 0xF1083B70, 0x1B3DA816, 0x7566ABD3, 0xBC99F02E, 0x4E16FA04, 0xB1FE3AE0, 0x27F3C31A, 0xC110CE8B, 0x1FAB6F3B, 0xC4344494, 0x1FCFFEB2, 0xEF81B73C},
    {0xC215AB26, 0x4C96435C, 0x829320D1, 0xAEEF180D, 0xB428A2C5, 0x8E5DCC76, 0x5B37BF4B, 0x0C3B1EB7, 0x9C6AAC59, 0x5A978526, 0x38823FE6, 0x5EFA46DC, 0x1A51EF09, 0x55DA63E8, 0x86661202, 0x930CDF9E},
    {0x7B3957D6, 0x71E22FD8, 0xEC39B37D, 0x5B9843C1, 0xDB81FA1C, 0x2BFE689A, 0xE183EE98, 0xE7527C9E, 0xD7432BD0, 0x2ED063BD, 0xB071A10D, 0x18760256, 0x7889D19B, 0x19839FBF, 0x5846DF92, 0x720460CA},
    {0xF3A3E647, 0xA50F0287, 0x6C03DF14, 0x68D52CA7, 0x572F4A8B, 0xD8B80D42, 0xCE0F0524, 0xA3C1FE19, 0x79F4838F, 0xB952EE33, 0xC920D77A, 0xE68EA4EA, 0xAF3040BD, 0xCE71F228, 0xEE792CAD, 0xB4F731AF},
    {0xBA632C11, 0xFEC7519B, 0x49C85F3E, 0x7B07FE54, 0xC100CFE7, 0xA67B1FE8, 0x8CB47050, 0x72314869, 0x081CB860, 0x468B11A3, 0x4D9206F9, 0x24B42C64, 0x59FE6A4B, 0x0A3B49D2, 0x8DD5A1F9, 0x7E991924},
    {0x1C6E90D1, 0xB569E822, 0x74E79E8C, 0x23CBB086, 0x6DAB9D13, 0x62F08738, 0xA457F6CD, 0x2201D540, 0x3EDC4BEA, 0x68E071B2, 0x33E116AA, 0x7DCDF76D, 0x0EA0D936, 0xBE5F228F, 0xC04D3769, 0xBEE26C41},
    {0xDC3DFE4E, 0x588146C4, 0x19B83126, 0x3F9137D8, 0x92F562BC, 0x9547B1D6, 0xE3C33412, 0xA9F49428, 0x599813C7, 0xD223BFFE, 0xC4B55C99, 0x96120B86, 0x0182BA61, 0xE89BB2ED, 0x75051689, 0x3454AAFE},
    {0x0878AD86, 0xD736A893, 0xF5940AEE, 0xE9A25C1E, 0x5376324E, 0x2EE10A17, 0x15803C77, 0x877AB163, 0x7CCE6C36, 0x384F0391, 0x3CF37F2A, 0xE144DA9E, 0xC616F4AB, 0x7E51D675, 0x9CEA5AD3, 0x015F1ECB},
    {0x5CE4CAA0, 0x1772F92A, 0x647B4FC2, 0x0F70CE2A, 0x27DF85C6, 0xC39F5DC8, 0xFE9AB6F1, 0x0BE0C14E, 0x2FF0A154, 0xF686D961, 0x1B7542C7, 0x1F5BB154, 0x2E3E5071, 0x32431D66, 0x0EB629A7, 0xF0D49180},
    {0x4B0D1667, 0x8961CEB8, 0xA7D642AE, 0x467FEDBD, 0xB804A8F7, 0x6B417FFE, 0x20D38B02, 0x3B5C6F07, 0x4626BBDB, 0x14A21DAC, 0x25DD90AE, 0x057BFFCB, 0xDF9E8CE8, 0xCC07F3AA, 0xE1648DF7, 0x26B03A49},
    {0xEA329942, 0x11049F7E, 0x026CFF9A, 0xB609538B, 0x213C6595, 0xE6AD4C8E, 0xA749591B, 0xAEF32DCA, 0xDE0E8D18, 0x576EEEBE, 0x6B0063E4, 0xD3308AA3, 0x57C828B7, 0x6DB49485, 0x6FC53E12, 0x74EABF2E},
    {0x8CB1FFC3, 0xE53CDC54, 0xE54821C6, 0xDE199D3A, 0xA0CF582D, 0x63CDEC6F, 0xED74DC25, 0x9A449383, 0x8368FF76, 0x4A31783F, 0xE99810BA, 0x973948BE, 0x4AFF1169, 0x2579E637, 0xFAAB559F, 0x82590A18},
    {0xD46E21D9, 0x2FB3691D, 0x33835A76, 0x6BC9F9B2, 0xDE7AF014, 0x962B0F35, 0x33B539A5, 0xE51CD767, 0x04A84CC4, 0xD50A99D1, 0x4F2EF47E, 0xEB5FDE09, 0xBD087DA8, 0xBED51961, 0x87D34DE8, 0x50A6D098},
    {0xA4381162, 0x5127F944, 0xDABC96EF, 0x41762561, 0x1CAC88BF, 0xC68654BF, 0x538FF97B, 0x6103BB0D, 0xEC562335, 0x8CFFB05E, 0xB1CE37A1, 0xBB157684, 0x72DD2141, 0x5D460DAC, 0x76200181, 0x9306ED34},
    {0xCAE8882B, 0x87C4957A, 0x1B0DD1A9, 0xE74C90A4, 0x485E0A9B, 0xEAB005F2, 0xE2CC1409, 0x7EABF728, 0xC692B4D9, 0xC0203A2A, 0x225B7119, 0x54D1A6F3, 0x9DC991F5, 0xFF2D8DEB, 0xB6EE3893, 0xE4BD455F},
    {0xB8009C3F, 0x14E1095D, 0xEA700664, 0xB082DC55, 0x92D4FF31, 0x5FDB753E, 0xA06F424E, 0x8A48975B, 0x6D16F871, 0x6652E186, 0x95E043ED, 0x2B1C653E, 0x6B334C82, 0xA7B8D23D, 0xDA9EC767, 0xAC7C1C6C},
    {0xF65673F0, 0x37B14A1A, 0x2B7FFA40, 0x00CD38B6, 0xA4285171, 0x309F6ACA, 0xC485BB19, 0xC0E6123C, 0x11A32F40, 0xA87747CE, 0x89B728CF, 0x9BE70FC7, 0xF85A02B4, 0xE07B1D26, 0x290B4213, 0xC34CF48D},
    {0x30AAD267, 0xCDEB6C81, 0x469EBE8C, 0x2110F669, 0x7DB465C3, 0xC78A23F5, 0x78E7A9FF, 0x51206AD6, 0xB9E508D2, 0x0C05F295, 0x03567C9A, 0x79BF6EF6, 0xBAA5E3D0, 0x4F055688, 0x58AFF670, 0x24149AD6},
    {0xE18B0E35, 0x75A396CA, 0xCAE44E1E, 0x8E5D9915, 0x3917D7EC, 0x47D85911, 0x00246494, 0x7CB2FF2E, 0x3664599C, 0xBC60AD7F, 0x4BE213FF, 0x8D4535A3, 0x7518640B, 0xC19AE4CB, 0x7830D186, 0xDA82B33C},
    {0xB2434FA3, 0xF2602922, 0x24AC5932, 0x79A9D586, 0xC1859E44, 0x7FB304DF, 0xB756371D, 0xDC0CA288, 0xD426EF8F, 0x8DDE414E, 0x2EAF6933, 0xFF245DDC, 0x94EA3A50, 0xED35AB48, 0xECA15F22, 0x5DFF09C5},
    {0x057BF1BE, 0xBC0B53FF, 0xFF0492D8, 0xB8F03D73, 0x4DF73357, 0x71F62C96, 0x97F3C5DC, 0x39624CCF, 0x74A8BE1C, 0xC6221AF8, 0x94CA823C, 0x9DCDB974, 0x122FD7B2, 0x0E6540FF, 0x1A4790B8, 0x916F0452}
};


// ---- Static (spatial-only) lookup ----
float ditherBlueNoiseComputed(uint2 pixel)
{
    uint2 coord = pixel % _BN_SIZE;
    uint packed = _blueNoisePacked64[coord.y][coord.x >> 2u];
    uint shift  = (coord.x & 3u) * 8u;
    return (float((packed >> shift) & 0xFFu) + 0.5) / 256.0;
}

// ---- Temporal variant (golden ratio offset per frame) ----
float ditherBlueNoiseComputed(uint2 pixel, float frame)
{
    uint timeBits = asuint(frame);
    uint hash = timeBits * 0x967A889Bu;  // fast multiply hash
    uint offsetX = hash % _BN_SIZE;
    uint offsetY = (hash >> 8u) % _BN_SIZE;
    uint2 coord = (pixel + uint2(offsetX, offsetY)) % _BN_SIZE;
    uint packed = _blueNoisePacked64[coord.y][coord.x >> 2u];
    uint shift  = (coord.x & 3u) * 8u;
    return (float((packed >> shift) & 0xFFu) + 0.5) / 256.0;
}

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
#elif defined(DITHER_MODE_BLUE_COMPUTED)
    return ditherBlueNoiseComputed(pixel);
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
#elif defined(DITHER_MODE_BLUE_COMPUTED)
    return ditherBlueNoiseComputed(pixel, frame);
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
#elif defined(DITHER_MODE_BLUE_COMPUTED)
    float noise = ditherBlueNoiseComputed(uint2(pixelPos)) - 0.5;
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
#elif defined(DITHER_MODE_BLUE_COMPUTED)
    float noise = ditherBlueNoiseComputed(uint2(pixelPos), frame) - 0.5;
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
