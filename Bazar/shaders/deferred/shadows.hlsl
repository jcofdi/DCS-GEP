#ifndef DEFERRED_SHADOWS_HLSL
#define DEFERRED_SHADOWS_HLSL

#define FOG_ENABLE
#include "common/fog2.hlsl"
#include "common/samplers11.hlsl"
#include "enlight/materialParams.hlsl"

#define USE_ROTATE_PCF 1
#define BASE_SHADOWMAP_SIZE 4096
#define BASE_SHADOWMAP_BIAS 0.0004

// ═══════════════════════════════════════════════════════════════════════════
// [MOD] PCSS -- Percentage Closer Soft Shadows with Vogel Disk Sampling
//
// Physically-based penumbra softening driven by occluder-to-receiver
// distance and the sun's angular diameter.  Contact shadows remain razor
// sharp; distant shadows soften proportionally to real-world behavior.
//
// BUDGET MODEL:
//   The maximum clean PCF radius (no visible dithering without TAA) is
//   determined by the tap count: maxR = sqrt(count * 4 / pi).  Each
//   hardware PCF tap covers a 2x2 texel bilinear footprint, so N taps
//   fill a disk of area ~4N texels squared without gaps.
//
// VOGEL DISK SAMPLING:
//   Uses sqrt() radial distribution instead of linear, producing uniform
//   area coverage across the filter disk.  Linear spacing concentrates
//   taps near the center (where the shadow is uniformly lit or shadowed)
//   and under-samples the outer rim (where the penumbra transition lives).
//   Vogel redistributes taps proportionally to area, placing more samples
//   where they matter most -- the shadow edge gradient.
//
// CONFIGURATION:
//   PCSS_ENABLE              -- master toggle
//   PCSS_SUN_ANGULAR_DIAMETER -- physical constant (0.00927 rad)
//   PCSS_TAPS_CASCADE_3     -- innermost cascade (nearest to camera)
//   PCSS_TAPS_CASCADE_2     -- middle cascade
//   PCSS_TAPS_CASCADE_1     -- outer-middle cascade
//   PCSS_TAPS_CASCADE_0     -- outermost cascade (farthest from camera)
//   PCSS_MIN_BLOCKER_DIST   -- noise floor for blocker detection (meters)
//
// NOTE ON CASCADE NUMBERING:
//   DCS cascade 3 = nearest to camera (highest texels/m)
//   DCS cascade 0 = farthest from camera (lowest texels/m)
//   This is reversed from the Lua split distance array order.
// ═══════════════════════════════════════════════════════════════════════════

#define PCSS_ENABLE 1

// Solar angular diameter in radians.  0.53 degrees = 0.00927 rad.
// Increase slightly (0.012) for perceptually exaggerated penumbrae.
#define PCSS_SUN_ANGULAR_DIAMETER 0.00927

// Per-cascade tap budgets.
//
// Clean radius (no dithering, no TAA needed):
//   16 taps -> ~4.5 texel radius
//   24 taps -> ~5.5 texel radius
//   32 taps -> ~6.4 texel radius
//   48 taps -> ~7.8 texel radius
//   64 taps -> ~9.0 texel radius
//
// Cascade 3 (innermost, nearest camera): highest texels/m density.
// 64 taps provides physically correct penumbrae for blockers up to
// ~7-9m at typical inner cascade densities (100-150 texels/m).
// Also used for cockpit shadows via SF_FIRST_MIP_ONLY.
#define PCSS_TAPS_CASCADE_3 128

// Cascade 2: moderate density.  64 taps provides the same clean radius
// at lower texels/m, covering proportionally larger blocker distances.
#define PCSS_TAPS_CASCADE_2 64

// Cascade 1: lower density.  32 taps covers substantial blocker
// distances at the reduced texels/m of this cascade.
#define PCSS_TAPS_CASCADE_1 32

// Cascade 0 (outermost, farthest camera): lowest density.  16 taps
// covers large blocker distances because the texels/m is low enough
// that modest tap counts fill physically meaningful penumbrae.
#define PCSS_TAPS_CASCADE_0 16

// Minimum blocker distance (meters) below which PCSS falls back to
// the fixed PCF radius.  Prevents depth quantization noise from
// triggering false penumbrae on flat surfaces.
#define PCSS_MIN_BLOCKER_DIST 0.1


#if USE_ROTATE_PCF
float rnd(float2 xy) {
	return frac(sin(dot(xy, float2(12.9898, 78.233))) * 43758.5453);
}
#endif


float SampleShadowMap(float3 wPos, float NoL, uniform uint idx, uniform bool usePCF, uniform uint samplesMax, uniform bool useTreeShadow)
{
	float bias = BASE_SHADOWMAP_BIAS * BASE_SHADOWMAP_SIZE / ShadowMapSize;

	float4 shadowPos = mul(float4(wPos, 1.0), ShadowMatrix[idx]);
	float3 shadowCoord = shadowPos.xyz / shadowPos.w;
	float acc = cascadeShadowMap.SampleCmpLevelZero(gCascadeShadowSampler, float3(shadowCoord.xy, 3 - idx), saturate(shadowCoord.z) + bias);

	if (useTreeShadow) {
		float4 projPos = mul(float4(wPos, 1.0), gViewProj);
		float dp = cascadeShadowMap.SampleLevel(gPointClampSampler, float3(shadowCoord.xy, 3 - idx), 0).x;
		float4 p = mul(float4(shadowPos.xy, dp, 1.0), ShadowMatrixInv[idx]);
		float d = dot(p.xyz / p.w - wPos, gSunDir);
		return max(exp(-d * 0.5), acc);
	}

	if (usePCF) {
		static const float goldenAngle = 3.1415926535897932384626433832795 * (3.0 - sqrt(5.0));
		static const float PI_VAL = 3.1415926535897932384626433832795;
		const uint count = samplesMax;

		// Maximum clean PCF radius from tap count: sqrt(count * 4 / pi).
		// Each tap covers ~4 texels squared (hardware bilinear footprint).
		// This guarantees gap-free coverage without temporal filtering.
		const float maxCleanRadius = sqrt((float)count * 4.0 / PI_VAL);

		// ── Dynamic PCF floor from screen-space derivatives ─────
		// Compute how many shadow map texels span one screen pixel.
		// This determines the minimum PCF radius needed to dissolve
		// the texel staircase at the current viewing scale.
		//
		// ddx/ddy of shadow UVs is valid here -- SampleShadowMap is
		// called from compose pixel shaders (no dynamic loops).
		// The secondary shadow path in ESM.hlsl cannot use this
		// technique, but cascade shadows can.
		//
		// texelsPerPixel < 1: shadow texel is sub-pixel, staircase
		//   invisible, floor drops to 0.5 (minimal AA).
		// texelsPerPixel = 2: one shadow texel spans 2 screen pixels,
		//   need ~1.5 texel radius to dissolve the step.
		// texelsPerPixel > 4: very coarse shadow, floor rises to 3.0
		//   (matches stock maximum, prevents excessive softening).
		//
		// The 0.75 multiplier accounts for hardware bilinear filtering
		// which inherently provides ~0.5 texel of smoothing on top of
		// the PCF radius.
		float2 shadowDudx = ddx(shadowCoord.xy);
		float2 shadowDudy = ddy(shadowCoord.xy);
		float texelsPerPixel = max(length(shadowDudx), length(shadowDudy)) * ShadowMapSize;
		float dynamicFloor = clamp(texelsPerPixel * 2.0, 0.5, 3.0);

		float pcssR = dynamicFloor;

#if PCSS_ENABLE
		// ── Phase 1: Cross-shaped blocker search ────────────────────
		// Sample center + 4 cardinal neighbors to find occluders.
		// The single-tap search produces a binary discontinuity at
		// shadow edges: the center texel flips from occluder to ground
		// and PCSS disengages abruptly, truncating the penumbra.
		// The cross search ensures at least one neighbor detects the
		// occluder for 1-2 texels beyond the edge, allowing PCSS to
		// remain engaged through the full penumbra transition.
		//
		// Cost: 4 additional SampleLevel reads (non-comparison, cheaper
		// than SampleCmpLevelZero).  The center read is L1-cached from
		// the comparison sample above.
		float texelStep = 1.0 / ShadowMapSize;
		float refZ = shadowCoord.z + bias * 2.0;
		float blockerSum = 0;
		float blockerCount = 0;

		// Center
		float d0 = cascadeShadowMap.SampleLevel(
			gPointClampSampler,
			float3(shadowCoord.xy, 3 - idx), 0).x;
		if (d0 > refZ) { blockerSum += d0; blockerCount += 1.0; }

		// Cardinal neighbors: +X, -X, +Y, -Y (1 texel offset)
		float d1 = cascadeShadowMap.SampleLevel(
			gPointClampSampler,
			float3(shadowCoord.xy + float2(texelStep, 0), 3 - idx), 0).x;
		if (d1 > refZ) { blockerSum += d1; blockerCount += 1.0; }

		float d2 = cascadeShadowMap.SampleLevel(
			gPointClampSampler,
			float3(shadowCoord.xy + float2(-texelStep, 0), 3 - idx), 0).x;
		if (d2 > refZ) { blockerSum += d2; blockerCount += 1.0; }

		float d3 = cascadeShadowMap.SampleLevel(
			gPointClampSampler,
			float3(shadowCoord.xy + float2(0, texelStep), 3 - idx), 0).x;
		if (d3 > refZ) { blockerSum += d3; blockerCount += 1.0; }

		float d4 = cascadeShadowMap.SampleLevel(
			gPointClampSampler,
			float3(shadowCoord.xy + float2(0, -texelStep), 3 - idx), 0).x;
		if (d4 > refZ) { blockerSum += d4; blockerCount += 1.0; }

		if (blockerCount > 0)
		{
			// Average only the depths that found blockers.
			// At shadow edges, this naturally blends: deep in shadow
			// all 5 hit (stable average), at the edge 1-2 hit (still
			// valid distance from the nearest occluder texels).
			float avgBlockerDepth = blockerSum / blockerCount;

			// Reconstruct world-space blocker position from averaged
			// depth.  Same technique as the tree shadow path.
			float4 blockerWorld = mul(
				float4(shadowPos.xy, avgBlockerDepth, 1.0),
				ShadowMatrixInv[idx]);
			float blockerDist = dot(
				blockerWorld.xyz / blockerWorld.w - wPos, gSunDir);

			if (blockerDist > PCSS_MIN_BLOCKER_DIST)
			{
				// ── World-to-shadow-UV scale for this cascade ───────
				// By linearity of the shadow matrix, offsetting the world
				// position by 1 meter perpendicular to the sun direction
				// and transforming gives us UV-per-meter directly.
				// The (sunPerp, 0) transform depends only on uniform
				// inputs, so the compiler computes it once per draw.
				float3 sunPerp = abs(gSunDir.y) > 0.99
					? normalize(cross(gSunDir, float3(1, 0, 0)))
					: normalize(cross(gSunDir, float3(0, 1, 0)));
				float2 sunPerpUV = mul(float4(sunPerp, 0.0), ShadowMatrix[idx]).xy
					/ shadowPos.w;
				float uvPerMeter = length(sunPerpUV);

				// Physical penumbra in texels:
				//   world = blockerDist * sunAngularDiameter (meters)
				//   uv    = world * uvPerMeter
				//   texels = uv * ShadowMapSize
				float penumbraTexels = blockerDist
					* PCSS_SUN_ANGULAR_DIAMETER
					* uvPerMeter
					* ShadowMapSize;

				// Clamp between the screen-derived floor and the maximum
				// the tap count can fill cleanly without dithering.
				pcssR = clamp(penumbraTexels, dynamicFloor, maxCleanRadius * 2.0);
			}
		}
#endif // PCSS_ENABLE

		const float radius = pcssR / ShadowMapSize;

		// ── Vogel disk PCF ──────────────────────────────────────────
		// Golden-angle spiral with sqrt() radial distribution for
		// uniform area coverage.  Each tap is positioned at:
		//   angle = baseRotation + i * goldenAngle
		//   r     = sqrt((i + 0.5) / count) * radius
		//
		// The sqrt() converts uniform index spacing to uniform area
		// density -- more taps at the outer rim where the penumbra
		// transition lives, proportional to circumference at each
		// radius.  The +0.5 offset centers each sample within its
		// annular ring, avoiding a tap exactly at the origin (which
		// duplicates the center sample already taken above).
		float baseAngle = 0;
#if USE_ROTATE_PCF
		float4 projPos = mul(float4(wPos, 1.0), gViewProj);
		baseAngle = rnd(projPos.xy / projPos.w) * (2.0 * PI_VAL);
#endif
		// Start from i=1 because i=0 is the center tap already in acc.
		[loop]
		for (uint i = 1; i < count; ++i) {
			float t = ((float)i + 0.5) / (float)count;
			float angle = baseAngle + (float)i * goldenAngle;

			float s, c;
			sincos(angle, s, c);

			// sqrt(t) produces Vogel disk: uniform area distribution.
			float2 delta = float2(c, s) * (sqrt(t) * radius);

			// Per-tap escalating bias: outer taps span more depth
			// variation and need proportionally more bias to prevent
			// acne.  sqrt(t) ranges 0 to 1 mapping to disk center
			// to edge, matching the cascade PCF's bias * (1 + r * offset)
			// pattern with r = pcssR.
			float tapBias = bias * (1.0 + pcssR * sqrt(t));

			acc += cascadeShadowMap.SampleCmpLevelZero(
				gCascadeShadowSampler,
				float3(shadowCoord.xy + delta, 3 - idx),
				saturate(shadowCoord.z) + tapBias);
		}
		acc /= count;
	}
	return saturate(min(NoL * 10, acc));
}

//return shadow + AO
float2 SampleShadowClouds(float3 pos)
{
	if(gUseVolumetricCloudsShadow>0)
	{
		float3 uvw = pos * gCloudVolumeScale + gCloudVolumeOffset;
		float2 s = cloudsShadowTex3D.SampleLevel(gBilinearClampSampler, uvw.xzy, 0).yx;
		if(uvw.y>1) s = 1;
		float shadowFloor = 0.30;
		s.x = saturate((s.x - shadowFloor) / (1.0 - shadowFloor));
		s.x = smoothstep(-0.1, 1.1, s.x); // soften transitions
		s.x = min(s.x, getFogTransparency(ProjectOriginSpaceToSphere(pos).y + gOrigin.y, gSunDir.y, 400000.0f));
		return s;
	}
	else
	{
		float4 cldShadowPos = mul(float4(pos + gOrigin.xyz, 1.0), gCloudShadowsProj);
		float shadow = cloudsShadowTex.SampleLevel(gCloudsShadowSampler, cldShadowPos.xy / cldShadowPos.w, 0).r;
		shadow = lerp(shadow, 1.0, smoothstep(gCloudsLow, gCloudsHigh, pos.y));
		return float2(shadow, 1);
	}
}

float SampleShadowCascade(float3 wPos, float depth, float3 normal, uniform bool usePCF, uniform bool useNormalBias, uniform bool useTreeShadow=false, uniform uint samplesMax=32, uniform bool useOnlyFirstMap = false) {	// normal in world space

	float NoL = 1;
	if (useNormalBias) {
		NoL = dot(normal, gSunDir.xyz);
		if (NoL < 0)
			return 0;
	}

	if (useOnlyFirstMap) {
		return SampleShadowMap(wPos, NoL, ShadowFirstMap, usePCF, PCSS_TAPS_CASCADE_3, false);
	} else {
		// DCS cascade numbering: 0 = farthest, 3 = nearest.
		// ShadowDistance[0] is the farthest boundary,
		// ShadowDistance[3] is the nearest.
		if (depth > ShadowDistance[0])
			return SampleShadowMap(wPos, NoL, 0, usePCF, PCSS_TAPS_CASCADE_0, useTreeShadow);

		if (depth > ShadowDistance[1])
			return SampleShadowMap(wPos, NoL, 1, usePCF, PCSS_TAPS_CASCADE_1, useTreeShadow);

		if (depth > ShadowDistance[2])
			return SampleShadowMap(wPos, NoL, 2, usePCF, PCSS_TAPS_CASCADE_2, useTreeShadow);

		if (depth > ShadowDistance[3]) {
			if (useTreeShadow)
				return max(SampleShadowMap(wPos, NoL, 3, usePCF, PCSS_TAPS_CASCADE_3, true), smoothstep(ShadowDistance[2], ShadowDistance[3], depth));
			else
				return max(SampleShadowMap(wPos, NoL, 3, usePCF, PCSS_TAPS_CASCADE_3, false), smoothstep(ShadowCascadeFadeDepth, ShadowDistance[3], depth));
		}
		return 1;
	}
}	

float SampleShadowMapVertex(float3 wPos, uniform uint idx) {

	float bias = 0.0025;

	float4 shadowPos = mul(float4(wPos, 1.0), ShadowMatrix[idx]);
	float3 shadowCoord = shadowPos.xyz / shadowPos.w;
	return cascadeShadowMap.SampleCmpLevelZero(gCascadeShadowSampler, float3(shadowCoord.xy, 3 - idx), saturate(shadowCoord.z) + bias);
}

float SampleShadowCascadeVertex(float3 wPos, float depth) {

	[unroll]
	for (uint i = 0; i < 4; ++i) 
		if (depth > ShadowDistance[i])
			return SampleShadowMapVertex(wPos, i);

	return 1;
}

float SampleShadow(float4 ippos, float3 normal, uniform bool bPCF = true, uniform bool useNormalBias = true) {
	return SampleShadowCascade(ippos.xyz, ippos.w, normal, bPCF, useNormalBias);
}

float SampleShadowTerrain(float4 ippos, float3 normal, uniform bool bPCF = true, uniform bool useNormalBias = true) {
	return 1 - ((1 - SampleShadow(ippos, normal, bPCF, useNormalBias)) * saturate(FlatShadowDistance[0]));
}

#endif
