// DOF.fx -- corrected, stable version
//
// Changes from original:
//
//  1. Fixed CoC formula: divides by focalDistance, not dist.
//     Original: focalWidth * abs(focalDistance - dist) / dist
//       Dividing by dist causes blur to shrink as objects get further away,
//       which is the inverse of real camera behaviour. It also meant that
//       as you zoomed (changing invProj), the reconstructed dist values
//       shifted and altered the blur amount indirectly.
//     Fixed:    focalWidth * abs(focalDistance - dist) / focalDistance
//       Blur is now proportional only to defocus distance. An object 10m
//       past the focal plane blurs the same regardless of where it is
//       in absolute space.
//
//  NOTE on zoom / FOV behaviour:
//     The engine sets focalWidth as a static value with no FOV relationship,
//     so true focal-length-scaled bokeh (telephoto = shallow DOF) requires
//     the engine to vary focalWidth with zoom. This shader cannot derive
//     that reliably from invProj alone without knowing DCS's exact matrix
//     convention and unit scale for focalDistance. The formula correction
//     above removes the *inverse* behaviour — it will no longer actively
//     get worse as you zoom — but focalWidth remains the only knob for
//     strength.
//
//  2. Per-pixel radius: getRadius() called once per output pixel, not once
//     per sample. Removes ~150 depth loads + matrix multiplies per pixel.
//
//  3. Near-depth suppression: pixels reconstructing to < minSceneDistance
//     metres are forced to radius 0 (sharp). Prevents cockpit/canopy
//     geometry from bloating the bokeh radius.
//
//  4. maxRadius hard cap: no pixel can produce a radius large enough to
//     blur the whole screen regardless of focalWidth configuration.
//
//  5. Early-out: in-focus pixels skip the loop entirely.
//
//  6. Integer loop counter for reliable GPU scheduling.

#include "../common/samplers11.hlsl"
#include "../common/states11.hlsl"

Texture2D Source;

#ifdef MSAA
    Texture2DMS<float, MSAA> DepthMap;
#else
    Texture2D<float> DepthMap;
#endif

uint2   dims;
float4  viewport;

float4x4 invProj;
float focalDistance, focalWidth;
float aspect, bokehAmount;

// ---------------------------------------------------------------------------
// Quality / tuning constants
// ---------------------------------------------------------------------------

// Sample count per pixel. Higher = smoother bokeh discs, higher cost.
//   80  = fast, slightly grainy
//   150 = original count, well-formed disc
//   256 = smooth disc, moderate cost increase
//   400 = near-reference, expensive
#define NUMBER 150

#define GOLDEN_ANGLE 2.39996323f

// Hard cap on bokeh radius in UV space.
// Keeps individual pixels from blurring the entire screen.
// Increase if you want wider maximum bokeh at very shallow focus.
static const float maxRadius = 0.012f;

// Minimum view-space distance (metres) before we accept a depth value as
// real scene geometry. Values below this are assumed to be cockpit / canopy
// glass and are set to radius 0 (sharp).
// Reduce if cockpit instruments appear incorrectly sharpened.
static const float minSceneDistance = 1.5f;

// ---------------------------------------------------------------------------
// Vertex shader (unchanged from original)
// ---------------------------------------------------------------------------

struct VS_OUTPUT {
    noperspective float4 pos        : SV_POSITION0;
    noperspective float2 texCoords  : TEXCOORD0;
};

static const float2 quad[4] = {
    float2(-1,-1), float2(1,-1),
    float2(-1, 1), float2(1, 1),
};

VS_OUTPUT VS(uint vid : SV_VertexID) {
    VS_OUTPUT o;
    o.pos = float4(quad[vid], 0, 1);
    o.texCoords = float2(o.pos.x*0.5+0.5, -o.pos.y*0.5+0.5)*viewport.zw + viewport.xy;
    return o;
}

// ---------------------------------------------------------------------------
// CoC
// ---------------------------------------------------------------------------

float getBlurFactor(float dist) {
    float fd = max(focalDistance, 0.001f);
    return focalWidth * abs(fd - dist) / fd;
}

// ---------------------------------------------------------------------------
// getRadius
// Reconstructs view-space Z from raw NDC depth at a given UV, then converts
// it to a bokeh radius in UV space.
// Called ONCE per output pixel, never inside the sample loop.
// ---------------------------------------------------------------------------

float getRadius(float2 uv) {
#ifdef MSAA
    float depth = DepthMap.Load(uint2(uv * dims), 0).r;
#else
    float depth = DepthMap.Load(uint3(uv * dims, 0)).r;
#endif

    float4 p  = mul(float4(uv * 2.0f - 1.0f, depth, 1.0f), invProj);
    float  vz = p.z / p.w;

    // Reject near geometry (cockpit glass, canopy frame).
    if (vz < minSceneDistance)
        return 0.0f;

    return min(pow(getBlurFactor(vz), 1.5f), maxRadius);
}

// ---------------------------------------------------------------------------
// Bokeh kernel — golden-angle Vogel spiral
// ---------------------------------------------------------------------------

float3 Bokeh(Texture2D tex, float2 uv, float amount) {

    float radius = getRadius(uv);

    // Skip the loop entirely for in-focus pixels.
    if (radius < 0.0001f)
        return tex.Sample(ClampLinearSampler, uv).rgb;

    float2 pixel = float2(aspect, 1.0f) * radius;

    float3 acc = 0;
    float3 div = 0;
    float  r   = 1.0f;

    [loop]
    for (int s = 0; s < NUMBER; ++s) {
        float  theta  = (float)s * GOLDEN_ANGLE;
        r += 1.0f / r;

        float2 offset = (r - 1.0f) * float2(cos(theta), sin(theta)) * 0.06f;

        // Clamp samples outside the unit disc back to its edge.
        // This replaces the original per-sample depth read for leak prevention.
        float od = length(offset);
        if (od > 1.0f)
            offset *= (1.0f / od);

        float2 tuv = uv + pixel * offset;

        float3 col   = tex.Sample(ClampLinearSampler, tuv).rgb;
        float3 bokeh = float3(5.0f, 5.0f, 5.0f) + pow(col, 9.0f) * amount;
        acc += col * bokeh;
        div += bokeh;
    }

    return acc / div;
}

// ---------------------------------------------------------------------------
// Pixel shader
// ---------------------------------------------------------------------------

float4 PS(const VS_OUTPUT i) : SV_TARGET0 {
    return float4(Bokeh(Source, i.texCoords.xy, bokehAmount), 1.0f);
}

// ---------------------------------------------------------------------------
// Technique
// ---------------------------------------------------------------------------

technique10 LinearDistance {
    pass P0 {
        SetVertexShader(CompileShader(vs_4_0, VS()));
        SetGeometryShader(NULL);
        SetPixelShader(CompileShader(ps_4_0, PS()));

        SetDepthStencilState(disableDepthBuffer, 0);
        SetBlendState(disableAlphaBlend, float4(0,0,0,0), 0xFFFFFFFF);
        SetRasterizerState(cullNone);
    }
}
