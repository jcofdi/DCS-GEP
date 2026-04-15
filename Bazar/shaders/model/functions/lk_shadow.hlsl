#ifndef LK_SHADOW_HLSL
#define LK_SHADOW_HLSL

#include "functions/structs.hlsl"
#include "functions/vt_utils.hlsl"

VS_OUTPUT_SHADOWS lk_shadow_vs(const VS_INPUT_SHADOWS input)
{
    VS_OUTPUT_SHADOWS o;

    float4x4 posMat = get_transform_matrix(input);

    float4 Pos = mul(float4(input.pos.xyz,1.0),posMat);
    o.Position = mul(Pos, gViewProj);
    o.Pos = Pos;

#if defined(SHADOW_WITH_ALPHA_TEST)
    // [MOD] Transform normal to world space for angular glass transmittance.
    // Only compiled for materials with SHADOW_WITH_ALPHA_TEST (transparent,
    // alpha-tested, glass).  The (float3x3) cast strips translation.
    #ifdef NORMAL_SIZE
        o.Normal = normalize(mul((float3x3)posMat, input.normal.xyz));
    #endif
    #include "functions/set_texcoords.hlsl"

	#if defined(DAMAGE_UV)
		o.DamageLevel = get_damage_argument((int)input.pos.w);
	#endif
#endif

	return o;
}

void lk_shadow_ps(const VS_OUTPUT_SHADOWS input)
{
#if defined(GLASS_MATERIAL)
    // TEST: force all glass to write depth in opaque shadow path.
    // If canopy casts solid black shadow, the engine uses this path.
    // If no change, engine doesn't dispatch glass through either path.
    return;
#elif defined(SHADOW_WITH_ALPHA_TEST)
    clipByDiffuseAlpha(GET_DIFFUSE_UV(input), 0.4);
    testDamageAlpha(input, distance(input.Pos.xyz, gCameraPos.xyz) * gNearFarFovZoom.w);
#endif
}

void lk_shadow_transparent_ps(const VS_OUTPUT_SHADOWS input)
{
#if !defined(SHADOW_WITH_ALPHA_TEST)
    discard;
#else
    #if defined(DIFFUSE_UV) && (BLEND_MODE == BM_ALPHA_TEST || BLEND_MODE == BM_TRANSPARENT || (BLEND_MODE == BM_SHADOWED_TRANSPARENT))
        float4 diff = Diffuse.Sample(gAnisotropicWrapSampler, input.DIFFUSE_UV.xy + diffuseShift);

        #if defined(GLASS_MATERIAL)
            // GLASS_SHADOW_OPACITY controls the base shadow strength at
            // normal incidence.  Physical aircraft glass transmits 85-92%
            // of light, so shadow opacity is 8-15%.  0.12 is a reasonable
            // default (88% transmission, 12% shadow).

            // Tunable: base shadow opacity at normal incidence.
            // 0.08 = very faint (92% transmission)
            // 0.12 = moderate (88% transmission, default)
            // 0.20 = heavy tint (80% transmission)
            static const float GLASS_SHADOW_OPACITY = 0.12;

            // Path length through glass based on light incidence angle.
            // In the shadow pass, gCameraPos is the light source position
            // (the shadow map is rendered from the light's perspective).
            // For directional light (sun), all rays are parallel so we
            // use gSunDir directly.
            #ifdef NORMAL_SIZE
                float NoL = abs(dot(input.Normal, gSunDir.xyz));
                float pathLength = 1.0 / max(NoL, 0.1);
            #else
                float pathLength = 1.0;
            #endif

            // Combined opacity: texture alpha * base strength * path length.
            // Clamped to [0, 0.7] to prevent fully opaque glass shadows
            // even at extreme grazing angles.
            float glassOpacity = saturate(diff.a * GLASS_SHADOW_OPACITY * pathLength);
            float glassTransmittance = 1.0 - min(glassOpacity, 0.7);

            // Stochastic discard: each pixel independently decides whether
            // to write depth based on a screen-space noise value compared
            // against transmittance.  High transmittance = most pixels
            // discard = faint shadow.  Low transmittance = most pixels
            // write = strong shadow.
            float noise = frac(sin(dot(input.Position.xy,
                float2(12.9898, 78.233))) * 43758.5453);
            if (noise < glassTransmittance)
                discard;
        #else
            if(diff.a < 0.25)
                discard;
        #endif
    #endif

    testDamageAlpha(input, distance(input.Pos.xyz, gCameraPos.xyz) * gNearFarFovZoom.w);

#endif
}


#endif
