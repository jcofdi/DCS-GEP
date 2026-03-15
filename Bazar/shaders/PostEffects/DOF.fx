// DOF.fx — GEP Ground-Up Rewrite
//
// Replaces both the stock and WIP-corrected DOF shaders with a physically
// motivated, architecturally modern depth-of-field implementation.
//
// Summary of changes from stock:
//
//   1. Physical CoC model: linear defocus (no pow(1.5) distortion), derived
//      from the thin-lens equation. CoC is proportional to |S2 - S1| / S1,
//      not |S2 - S1| / S2 (which was the stock bug that reversed behavior).
//
//   2. FOV-coupled focal length: includes context.hlsl to read gFov.
//      Telephoto zoom → shallower DoF; wide FOV → deeper DoF.
//      Scales as f² (physical CoC scaling with focal length squared).
//
//   3. Signed CoC with dual-accumulator gather: near-field (foreground) and
//      far-field (background) blur are accumulated separately, preventing
//      background color from bleeding through sharp foreground edges and
//      vice versa. Composited as layers: sharp → far → near overlay.
//
//   4. Depth-ordered sample rejection: borrows the smoothstep depth
//      comparison from motionblur.fx to softly reject samples that cross
//      depth discontinuities. Prevents the worst gather-based leak artifacts.
//
//   5. Luminance-weighted bokeh highlights: replaces the arbitrary
//      pow(col, 9) weighting with a physically motivated luminance-excess
//      model in linear HDR space. Bright points get proportionally more
//      weight, simulating real bokeh disc intensity distribution.
//
//   6. Per-sample depth reads use a scalar reconstruction (2 MAD + 1 DIV)
//      instead of a full 4×4 matrix multiply, reducing per-sample ALU cost
//      by ~10×. Valid for symmetric perspective projections (standard case).
//
//   7. Vogel spiral with proper sqrt() radial distribution for uniform disc
//      coverage, replacing the stock's incremental r += 1/r approximation.
//
// Note on cockpit geometry:
//   DOF only activates in external camera views where the cockpit is not
//   rendered. No cockpit rejection logic is needed. The stencil buffer's
//   STENCIL_COMPOSITION_COCKPIT tag is never written in external view, and
//   stencil cannot distinguish individual objects anyway (all 3D models
//   share STENCIL_COMPOSITION_MODEL). Near-distance thresholds from the
//   stock/WIP shaders have been removed as dead code.
//
// Compile-time configuration:
//
//   DEBUG_COC            0 = normal rendering, 1 = visualize CoC heatmap
//   SAMPLE_COUNT         Number of gather samples per pixel (default 128)
//
// Performance notes:
//   At 1080p with 128 samples: ~128 depth texture reads + ~400 ALU ops per
//   defocused pixel. In-focus pixels and sky early-out before the loop.
//
// ---------------------------------------------------------------------------

#include "../common/samplers11.hlsl"
#include "../common/states11.hlsl"
#include "../common/context.hlsl"
#include "../common/stencil.hlsl"

// ---------------------------------------------------------------------------
// Compile-time configuration
// ---------------------------------------------------------------------------

// Set to 1 to output a signed CoC heatmap for debugging.
// Blue = near field, red = far field, green = in focus.
#define DEBUG_COC 0

// Set to 1 to visualize the stencil buffer's material composition types.
// Used to determine what the engine writes for canopy glass, terrain, sky,
// etc. in external view. Color key (printed on screen by the shader):
//   Black        = SURFACE  (terrain)
//   Green        = MODEL    (aircraft, vehicles, buildings)
//   Blue         = WATER
//   Dark green   = FOLIAGE
//   Yellow-green = GRASS
//   Magenta      = COCKPIT  (should not appear in external view)
//   Cyan         = UNDERWATER
//   White        = EMPTY    (sky / unrendered)
//   Red          = unknown  (unexpected stencil value)
// Brightness encodes depth: bright = near, dim = far. Canopy glass that
// reads as MODEL but is dim (far depth) = the transparent surface bug.
#define DEBUG_STENCIL 0

// Gather sample count. Higher = smoother bokeh, higher cost.
//   64  = fast, slightly noisy disc edges
//   128 = good balance (default)
//   192 = smooth, moderate cost
//   256 = near-reference quality
#define SAMPLE_COUNT 128

// ---------------------------------------------------------------------------
// Resources — layout must match engine C++ bindings
// ---------------------------------------------------------------------------

Texture2D Source;

#ifdef MSAA
    Texture2DMS<float, MSAA> DepthMap;
    #define LOAD_DEPTH(pc) DepthMap.Load(uint2(pc), 0).r
#else
    Texture2D<float> DepthMap;
    #define LOAD_DEPTH(pc) DepthMap.Load(uint3(pc, 0)).r
#endif

// Engine-set uniforms (same names/types as stock — do not rename)
uint2       dims;
float4      viewport;
float4x4    invProj;
float       focalDistance, focalWidth;
float       aspect, bokehAmount;

// ---------------------------------------------------------------------------
// Stencil buffer — only compiled when debug visualization is enabled.
// If the SRV is not bound by the engine during the DOF dispatch, all reads
// return 0 on D3D11 (no crash, just reads as SURFACE everywhere).
// ---------------------------------------------------------------------------
#if DEBUG_STENCIL
    #ifdef MSAA
        Texture2DMS<uint2, MSAA> StencilMap;
        #define LOAD_STENCIL_G(pc) StencilMap.Load(uint2(pc), 0).g
    #else
        Texture2D<uint2> StencilMap;
        #define LOAD_STENCIL_G(pc) StencilMap.Load(uint3(pc, 0)).g
    #endif
#endif

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

static const float PI           = 3.14159265f;
static const float GOLDEN_ANGLE = 2.39996323f;

// ---------------------------------------------------------------------------
// Tuning parameters
// ---------------------------------------------------------------------------

// Hard cap on CoC radius in pixels. Prevents any single pixel from blurring
// the entire screen. Increase for extremely shallow DOF at telephoto zoom.
static const float maxCoCPixels = 40.0;

// CoC fade range in pixels. Controls how smoothly the blur transitions from
// in-focus to defocused. Larger = softer transition, smaller = sharper onset.
static const float cocFadeRange = 3.0;

// HDR luminance threshold for bokeh highlight emphasis. Pixels brighter than
// this (in linear HDR space) receive proportionally more weight in the gather,
// simulating the intensity-proportional area of real bokeh discs.
// Set to a high value (e.g., 10.0) if Source is LDR post-tonemap.
static const float highlightThreshold = 1.5;

// FOV baseline in mm. The focal length derived from gFov is normalized to
// this value. At the baseline, fovScale = 1.0 (no modification to focalWidth).
// 50mm is a "normal" lens for 35mm full-frame equivalent.
static const float fovBaselineMM = 50.0;

// Master CoC scale factor. Maps the engine's focalWidth (arbitrary units)
// into a pixel-space CoC via: cocPixels = focalWidth * defocus * fovScale * cocScale.
// Tune this empirically: start at 0.25, increase if DoF appears too weak
// at the engine's default focalWidth setting, decrease if too strong.
static const float cocScale = 0.25;

// ---------------------------------------------------------------------------
// Vertex shader (unchanged structure from stock)
// ---------------------------------------------------------------------------

struct VS_OUTPUT {
    noperspective float4 pos        : SV_POSITION0;
    noperspective float2 texCoords  : TEXCOORD0;
};

static const float2 quad[4] = {
    float2(-1, -1), float2(1, -1),
    float2(-1,  1), float2(1,  1),
};

VS_OUTPUT VS(uint vid : SV_VertexID) {
    VS_OUTPUT o;
    o.pos = float4(quad[vid], 0, 1);
    o.texCoords = float2(o.pos.x * 0.5 + 0.5, -o.pos.y * 0.5 + 0.5)
                * viewport.zw + viewport.xy;
    return o;
}

// ---------------------------------------------------------------------------
// Per-frame CoC parameters (uniform across all pixels in a frame)
// ---------------------------------------------------------------------------

struct CoCParams {
    float fd;           // Clamped focal distance (metres)
    float scale;        // Combined: focalWidth * fovScale * cocScale
};

CoCParams initCoCParams() {
    CoCParams p;
    p.fd = max(focalDistance, 0.01);

    // Derive 35mm-equivalent focal length from engine's vertical FOV.
    // gFov is in degrees, sourced from gNearFarFovZoom.z in context.hlsl.
    //   At 60° vFOV → ~34mm  (moderate wide angle)
    //   At 30° vFOV → ~69mm  (telephoto, shallow DoF)
    //   At 90° vFOV → ~20mm  (ultra-wide, deep DoF)
    float halfFovRad    = gFov * (PI / 360.0);
    float focalLengthMM = 18.0 / tan(max(halfFovRad, 0.01));

    // CoC scales with focal length squared (thin lens equation).
    // Normalized to fovBaselineMM so that at the baseline FOV the effect
    // matches the unscaled focalWidth behavior.
    float fovScale = (focalLengthMM * focalLengthMM)
                   / (fovBaselineMM * fovBaselineMM);

    p.scale = focalWidth * fovScale * cocScale;
    return p;
}

// ---------------------------------------------------------------------------
// Depth reconstruction
// ---------------------------------------------------------------------------

// Full matrix path: accurate for all projection types including asymmetric
// (VR/HMD). Used for the center pixel where precision matters most.
float depthToViewZ_full(float2 uv, float rawDepth) {
    float4 p = mul(float4(uv * 2.0 - 1.0, rawDepth, 1.0), invProj);
    return p.z / p.w;
}

// Scalar fast path: exploits the fact that for symmetric perspective
// projections, view-Z depends only on raw depth, not on screen XY.
// Costs 2 MAD + 1 DIV vs. ~16 MAD + 4 ADD for the full matrix multiply.
// Falls back gracefully for asymmetric projections (slight positional error
// in Z that is negligible for CoC computation).
float depthToViewZ_fast(float rawDepth) {
    return (rawDepth * invProj._m22 + invProj._m32)
         / (rawDepth * invProj._m23 + invProj._m33);
}

// ---------------------------------------------------------------------------
// Signed CoC computation
// ---------------------------------------------------------------------------
// Returns signed circle of confusion in pixel units.
// Negative = near field (pixel closer than focus plane).
// Positive = far field (pixel farther than focus plane).

float computeSignedCoC(CoCParams p, float viewZ) {
    float dist    = max(viewZ, 0.01);
    float defocus = abs(dist - p.fd) / p.fd;       // Linear defocus ratio
    float cocPx   = min(defocus * p.scale, maxCoCPixels);

    return (viewZ < p.fd) ? -cocPx : cocPx;
}

// ---------------------------------------------------------------------------
// Bokeh highlight weight
// ---------------------------------------------------------------------------
// In a real lens, each point in the scene spreads its energy uniformly
// across its CoC disc. Bright points are disproportionately visible because
// their per-texel contribution exceeds that of dim surroundings. This
// function models that effect by weighting samples proportional to their
// luminance excess above a threshold.

float bokehWeight(float3 color) {
    float lum = dot(color, float3(0.2126, 0.7152, 0.0722));
    return 1.0 + max(0.0, lum - highlightThreshold) * bokehAmount;
}

// ---------------------------------------------------------------------------
// Vogel disc sampling
// ---------------------------------------------------------------------------
// Golden-angle spiral with sqrt() radial distribution for uniform area
// coverage. Unlike the stock r += 1/r increment (which approximates sqrt),
// this is exact and produces evenly filled discs at any sample count.

float2 vogelSample(int index, int count) {
    float r     = sqrt((float(index) + 0.5) / float(count));
    float theta = float(index) * GOLDEN_ANGLE;
    float s, c;
    sincos(theta, s, c);
    return r * float2(c, s);
}

// ---------------------------------------------------------------------------
// Debug: stencil + depth visualization
// ---------------------------------------------------------------------------
#if DEBUG_STENCIL

float3 debugStencilColor(uint compositionType) {
    // Maps STENCIL_COMPOSITION_* values to distinct colors.
    // The type is already masked and shifted, so compare directly.
    switch (compositionType) {
        case STENCIL_COMPOSITION_SURFACE:    return float3(0.15, 0.15, 0.15); // dark gray (terrain)
        case STENCIL_COMPOSITION_MODEL:      return float3(0.0,  1.0,  0.0);  // green (aircraft, vehicles)
        case STENCIL_COMPOSITION_WATER:      return float3(0.0,  0.3,  1.0);  // blue
        case STENCIL_COMPOSITION_FOLIAGE:    return float3(0.0,  0.5,  0.1);  // dark green
        case STENCIL_COMPOSITION_GRASS:      return float3(0.5,  0.7,  0.0);  // yellow-green
        case STENCIL_COMPOSITION_COCKPIT:    return float3(1.0,  0.0,  1.0);  // magenta (should not appear)
        case STENCIL_COMPOSITION_UNDERWATER: return float3(0.0,  0.8,  0.8);  // cyan
        case STENCIL_COMPOSITION_EMPTY:      return float3(1.0,  1.0,  1.0);  // white (sky)
        default:                             return float3(1.0,  0.0,  0.0);  // red = unknown
    }
}

// Draws a compact color key legend in the top-left corner.
// Each swatch is 12×12px with a 2px gap between them.
float3 debugStencilLegend(uint2 pixCoord) {
    static const float3 legendColors[8] = {
        float3(0.15, 0.15, 0.15), // SURFACE
        float3(0.0,  1.0,  0.0),  // MODEL
        float3(0.0,  0.3,  1.0),  // WATER
        float3(0.0,  0.5,  0.1),  // FOLIAGE
        float3(0.5,  0.7,  0.0),  // GRASS
        float3(1.0,  0.0,  1.0),  // COCKPIT
        float3(0.0,  0.8,  0.8),  // UNDERWATER
        float3(1.0,  1.0,  1.0),  // EMPTY
    };
    // Legend position: top-left, 8px margin
    int2 lp = int2(pixCoord) - int2(8, 8);
    if (lp.x >= 0 && lp.y >= 0 && lp.x < 14 * 8 && lp.y < 14) {
        int idx = lp.x / 14;
        int2 local = int2(lp.x % 14, lp.y);
        if (idx < 8 && local.x < 12 && local.y < 12)
            return legendColors[idx];
    }
    return float3(-1, -1, -1); // sentinel: not in legend area
}

float3 debugStencilVis(float2 uv, uint2 pixCoord) {
    // Check if we're drawing the legend
    float3 legend = debugStencilLegend(pixCoord);
    if (legend.x >= 0.0)
        return legend;

    // Read stencil
    uint rawStencil = LOAD_STENCIL_G(pixCoord);
    uint matType    = rawStencil & STENCIL_COMPOSITION_MASK;
    float3 matColor = debugStencilColor(matType);

    // Encode depth as brightness so you can distinguish near MODEL (canopy
    // at aircraft distance = bright green) from far MODEL (should not exist)
    // or near-depth sky behind canopy glass (bright white = suspicious).
    float rawDepth = LOAD_DEPTH(pixCoord);
    float depthBrightness;
    if (rawDepth >= 0.9999) {
        // Sky / far plane — show at half brightness
        depthBrightness = 0.4;
    } else {
        // Map view-space distance to brightness: 0m=1.0, 2000m=0.2
        float vz = depthToViewZ_full(uv, rawDepth);
        depthBrightness = lerp(1.0, 0.2, saturate(vz / 2000.0));
    }

    return matColor * depthBrightness;
}

#endif // DEBUG_STENCIL

// ---------------------------------------------------------------------------
// Main gather function
// ---------------------------------------------------------------------------

float3 GatherDoF(float2 uv) {
    uint2 pixCoord = uint2(uv * dims);
    float3 sharp   = Source.Sample(ClampLinearSampler, uv).rgb;

#if DEBUG_STENCIL
    return debugStencilVis(uv, pixCoord);
#endif

    // ----- Center pixel depth and CoC -----

    float rawDepth = LOAD_DEPTH(pixCoord);

    // Sky / far plane: no blur (infinite focus)
    if (rawDepth >= 0.9999)
        return sharp;

    float centerZ = depthToViewZ_full(uv, rawDepth);

    CoCParams cp    = initCoCParams();
    float signedCoC = computeSignedCoC(cp, centerZ);
    float absCoC    = abs(signedCoC);

    // In-focus early-out: sub-pixel CoC means no visible blur
    if (absCoC < 0.5)
        return sharp;

#if DEBUG_COC
    // Visualize signed CoC: blue = near, red = far, green = focused
    float t = saturate(absCoC / maxCoCPixels);
    if (signedCoC < 0)
        return float3(0, 0, t);         // Near field: blue
    else
        return float3(t, 0, 0);         // Far field: red
#endif

    // ----- Gather kernel setup -----

    // Kernel radius in UV space, aspect-corrected
    float kernelRadius = absCoC / float(dims.y);
    float2 pixelScale  = float2(aspect, 1.0) * kernelRadius;

    // UV bounds for sample clamping
    float2 uvMin = viewport.xy;
    float2 uvMax = viewport.xy + viewport.zw;

    // ----- Dual-accumulator gather -----
    //
    // Two separate accumulators prevent cross-field contamination:
    //
    //   Far accumulator:  gathers samples at or behind the center pixel.
    //                     Rejects near-field samples that would bleed
    //                     foreground color into the background.
    //
    //   Near accumulator: gathers samples at or in front of the center pixel.
    //                     Captures foreground blur that should overlay
    //                     everything behind it.
    //
    // Composited as layers: sharp → far blur → near blur (front-to-back).

    float3 farAcc  = 0;
    float  farWSum = 0;
    float3 nearAcc = 0;
    float  nearWSum= 0;

    [loop]
    for (int s = 0; s < SAMPLE_COUNT; ++s) {

        float2 offset   = vogelSample(s, SAMPLE_COUNT);
        float2 sampleUV = clamp(uv + offset * pixelScale, uvMin, uvMax);

        // Sample scene color
        float3 col = Source.Sample(ClampLinearSampler, sampleUV).rgb;

        // Sample depth → view-Z → signed CoC (scalar fast path)
        uint2  spc       = uint2(sampleUV * dims);
        float  sRaw      = LOAD_DEPTH(spc);
        float  sampleZ   = depthToViewZ_fast(sRaw);
        float  sampleCoC = computeSignedCoC(cp, sampleZ);
        float  absSmplCoC= abs(sampleCoC);

        // --- Depth ordering ---
        // Soft depth comparison borrowed from motionblur.fx.
        // isBehind ≈ 1 when sample is at or behind center, ≈ 0 when in front.
        // The 1% tolerance band prevents hard edges at depth discontinuities.
        float isBehind = smoothstep(centerZ * 0.99, centerZ * 1.01, sampleZ);

        // --- Scatter-as-gather reach test ---
        // A defocused sample "scatters" its color across its own CoC disc.
        // We're gathering from the center pixel's perspective, so we should
        // only accept a sample's contribution if its CoC is large enough
        // that its scatter disc would reach the center pixel. This prevents
        // sharp in-focus samples from being erroneously smeared by the
        // kernel of a nearby defocused pixel.
        float sampleReach = saturate(absSmplCoC / max(absCoC, 0.5));

        // Bokeh highlight emphasis
        float bw = bokehWeight(col);

        // --- Far-field accumulation ---
        // Accept samples that are behind the center AND far-defocused.
        // The saturate(sampleCoC) term is > 0 only for far-field samples.
        float farW = isBehind
                   * saturate(sampleCoC)
                   * sampleReach
                   * bw;
        farAcc  += col * farW;
        farWSum += farW;

        // --- Near-field accumulation ---
        // Accept samples that are in front of the center AND near-defocused.
        // The saturate(-sampleCoC) term is > 0 only for near-field samples.
        float nearW = (1.0 - isBehind)
                    * saturate(-sampleCoC)
                    * bw;
        nearAcc  += col * nearW;
        nearWSum += nearW;
    }

    // ----- Composite -----

    // Far-field result: weighted average of far-defocused samples.
    // Falls back to sharp if no valid far-field samples were gathered
    // (e.g., pixel is near-defocused and all samples are in front).
    float3 farResult = (farWSum > 0.001) ? (farAcc / farWSum) : sharp;

    // Near-field result: weighted average of near-defocused samples.
    float3 nearResult = (nearWSum > 0.001) ? (nearAcc / nearWSum) : sharp;

    // Signed CoC → per-field blend alpha.
    // Positive signedCoC fades in far blur; negative fades in near blur.
    // cocFadeRange controls the transition softness in pixel-CoC units.
    float farAlpha  = smoothstep(0.0, cocFadeRange,  signedCoC);
    float nearAlpha = smoothstep(0.0, cocFadeRange, -signedCoC);

    // Layer compositing: sharp base → far blur overlay → near blur on top
    float3 result = lerp(sharp,  farResult,  farAlpha);
    result        = lerp(result, nearResult, nearAlpha);

    return result;
}

// ---------------------------------------------------------------------------
// Pixel shader
// ---------------------------------------------------------------------------

float4 PS(const VS_OUTPUT i) : SV_TARGET0 {
    return float4(GatherDoF(i.texCoords.xy), 1.0);
}

// ---------------------------------------------------------------------------
// Technique — name and pass structure must match stock for engine dispatch
// ---------------------------------------------------------------------------

technique10 LinearDistance {
    pass P0 {
        SetVertexShader(CompileShader(vs_5_0, VS()));
        SetGeometryShader(NULL);
        SetPixelShader(CompileShader(ps_5_0, PS()));

        SetDepthStencilState(disableDepthBuffer, 0);
        SetBlendState(disableAlphaBlend, float4(0, 0, 0, 0), 0xFFFFFFFF);
        SetRasterizerState(cullNone);
    }
}
