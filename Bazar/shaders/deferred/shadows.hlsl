#ifndef DEFERRED_SHADOWS_HLSL
#define DEFERRED_SHADOWS_HLSL

#define FOG_ENABLE
#include "common/fog2.hlsl"
#include "common/samplers11.hlsl"
#include "common/dithering.hlsl"
#include "enlight/materialParams.hlsl"

#define USE_ROTATE_PCF 1
#define BASE_SHADOWMAP_SIZE 4096
#define BASE_SHADOWMAP_BIAS 0.0004

// ── Normal offset bias ──────────────────────────────────────────────
// World-space offset along the surface normal applied before shadow
// map lookup.  Prevents self-shadowing by geometrically moving the
// lookup point above the receiver surface.
//
// The offset is scaled by (1 - NoL): maximum at sun-grazing angles
// where shadow texels are stretched across the surface and self-
// intersection is worst, zero at perpendicular where it's not needed.
//
// This is the primary acne prevention mechanism.  BASE_SHADOWMAP_BIAS
// handles residual depth quantization on top.
//
// Guide:
//   0.01 = minimal offset (may show acne at extreme grazing)
//   0.02 = moderate (good starting point)
//   0.04 = aggressive (eliminates most acne, may show shadow detachment
//          at extreme grazing on thin geometry)
//   0.08 = very aggressive (noticeable detachment on sharp edges)
//
// Unlike depth bias, failure is gentle: too-large values produce
// slightly rounded shadow edges rather than global peter-panning.
#define PCSS_NORMAL_OFFSET_SCALE 0.08

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
// RIM-BIASED VOGEL DISK:
//   Uses pow(t, RIM_BIAS_EXPONENT) radial distribution instead of sqrt(t).
//   Lower exponent values push more taps toward the outer rim where the
//   penumbra transition lives.  At 0.5 (standard Vogel), tap density is
//   uniform by area.  At 0.35, outer rim gets ~60-70% of taps versus
//   uniform Vogel's 40%, defining the penumbra edge more cleanly without
//   meaningfully degrading the core (where samples are redundant anyway).
//
// NORMAL OFFSET BIAS:
//   Industry-standard acne prevention (Unity, Unreal, CryEngine).
//   Before shadow map lookup, the receiver position is offset along its
//   surface normal.  The offset scales with (1 - NoL): maximum at
//   sun-grazing angles where self-shadowing is worst, zero at
//   perpendicular where it's a non-issue.  This geometrically prevents
//   self-intersection without affecting per-tap depth comparisons,
//   avoiding the fragility of receiver-plane gradient methods (Schuler
//   2006) which suffer from degenerate Jacobians at grazing angles.
//
// WIDE VOGEL-DISK BLOCKER SEARCH:
//   Adaptive-radius blocker search using a Vogel disk pattern enables
//   physical shadow widening.  Lit-side pixels near the shadow boundary
//   detect occluders through the wide search and engage PCSS, allowing
//   the PCF disk to reach back into the geometric shadow.  This produces
//   penumbrae that genuinely extend beyond the geometric silhouette.
//
// CONFIGURATION:
//   PCSS_ENABLE              -- master toggle
//   PCSS_SUN_ANGULAR_DIAMETER -- physical constant (0.00927 rad)
//   PCSS_TAPS_CASCADE_3     -- innermost cascade (nearest to camera)
//   PCSS_TAPS_CASCADE_2     -- middle cascade
//   PCSS_TAPS_CASCADE_1     -- outer-middle cascade
//   PCSS_TAPS_CASCADE_0     -- outermost cascade (farthest from camera)
//   PCSS_FLOOR_CASCADE_N    -- per-cascade PCF floor radius in texels
//   PCSS_RADIUS_OVERDRIVE   -- max multiplier on clean radius (1.0 = strict)
//   PCSS_RIM_BIAS_EXPONENT  -- Vogel radial distribution (0.35-0.5)
//   PCSS_MIN_BLOCKER_DIST   -- noise floor for blocker detection (meters)
//   PCSS_NORMAL_OFFSET_SCALE -- world-space normal offset for acne prevention
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
//    16 taps -> ~4.5 texel radius
//    32 taps -> ~6.4 texel radius
//    64 taps -> ~9.0 texel radius
//    96 taps -> ~11.0 texel radius
//   128 taps -> ~12.8 texel radius
//
// Cascade 3 (innermost, nearest camera): highest texels/m density.
// Also used for cockpit shadows via SF_FIRST_MIP_ONLY.
#define PCSS_TAPS_CASCADE_3 128

// Cascade 2: moderate density.  Covers middle blocker distances.
#define PCSS_TAPS_CASCADE_2 64

// Cascade 1: lower density.
#define PCSS_TAPS_CASCADE_1 32

// Cascade 0 (outermost, farthest camera): lowest density.
#define PCSS_TAPS_CASCADE_0 16

// Per-cascade PCF floor (in texels).  Minimum filter radius when PCSS
// produces a physical penumbra smaller than this value.  Directly
// controls contact shadow sharpness and staircase dissolution.
//
// Guide (approximate):
//   0.5  = hardware bilinear only, maximum possible sharpness
//   1.0  = minimal PCF, staircase barely dissolved
//   1.5  = good staircase coverage, still sharp contacts
//   2.0  = noticeable edge softness, complete staircase dissolution
//   3.0  = stock-equivalent softness, cleanest appearance
//
// Inner cascades have denser texels, so the same floor value produces
// sharper world-space contacts.  Outer cascades may benefit from a
// larger floor to dissolve their coarser texel grid.
#define PCSS_FLOOR_CASCADE_3 1.5
#define PCSS_FLOOR_CASCADE_2 1.75
#define PCSS_FLOOR_CASCADE_1 2.0
#define PCSS_FLOOR_CASCADE_0 2.5

// PCSS radius overdrive multiplier.  Controls how far beyond the clean
// fill threshold PCSS is allowed to extend, trading visible grain for
// wider (more physically correct) penumbrae.
//
//   1.0 = strict clean fill only (no visible noise, clamped penumbra)
//   1.5 = 42% fill, mild grain on soft gradients (acceptable sweet spot)
//   2.0 = 24% fill, visible grain (noisy but more physical)
//   0.0 = UNCLAMPED -- physical radius always used, noise at extreme ratios
//
// Set to 0 to disable clamping entirely (physical penumbra always wins).
#define PCSS_RADIUS_OVERDRIVE 0

// Vogel disk radial distribution exponent.  Controls tap density
// across the disk area.
//
//   0.5  = standard Vogel (uniform area density)
//   0.4  = mild rim bias
//   0.35 = recommended rim bias (outer 40% gets ~65% of taps)
//   0.3  = aggressive rim bias (under-samples core, sharper edges)
//
// Lower values push more samples to the outer rim where the penumbra
// transition lives.  The core region is uniformly shadowed or uniformly
// lit, so core samples are largely redundant -- biasing toward the rim
// improves edge definition at the same tap count.
#define PCSS_RIM_BIAS_EXPONENT 0.35

// Minimum blocker distance (meters) below which PCSS falls back to
// the per-cascade floor.  Prevents depth quantization noise from
// triggering false penumbrae on flat surfaces.
#define PCSS_MIN_BLOCKER_DIST 0.1

// ── Blocker search configuration ────────────────────────────────────
// The blocker search must reach far enough to find occluders for
// lit-side pixels near the shadow boundary.  Without sufficient reach,
// pixels just outside the geometric shadow never detect the blocker,
// PCSS doesn't engage, and the shadow can't widen physically.
//
// PCSS_BLOCKER_SEARCH_TAPS: number of taps in the Vogel disk blocker
// search.  These are non-comparison SampleLevel reads (cheaper than
// the PCF comparison taps).  8-16 provides good coverage.
//
// PCSS_BLOCKER_SEARCH_MIP: mip level for blocker search reads.
// At mip 0, each tap reads one texel.
// At mip 1, each tap reads a 2x2 block (averaged depth).
// At mip 2, each tap reads a 4x4 block.
// Higher mips give each tap broader coverage of the search disk,
// dramatically improving blocker detection at wide search radii.
// SET TO 0 IF DCS DOES NOT GENERATE SHADOW MAP MIP CHAINS -- higher
// mip reads will return garbage.  Test by setting to 1 and checking
// if shadow behavior degrades or produces artifacts.
#define PCSS_BLOCKER_SEARCH_TAPS 16
#define PCSS_BLOCKER_SEARCH_MIP 0


#if USE_ROTATE_PCF
float rnd(float2 xy) {
	return frac(sin(dot(xy, float2(12.9898, 78.233))) * 43758.5453);
}
#endif


float SampleShadowMap(float3 wPos, float NoL, uniform uint idx, uniform bool usePCF, uniform uint samplesMax, uniform bool useTreeShadow, uniform float floorRadius = 1.5)
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

		// Start with per-cascade floor; PCSS will widen if blockers found.
		float pcssR = floorRadius;

#if PCSS_ENABLE
		// ── World-to-shadow-UV scale for this cascade ───────────────
		// Computed before blocker search because both the adaptive
		// search radius and the penumbra width need texels-per-meter.
		//
		// By linearity of the shadow matrix, offsetting the world
		// position by 1 meter perpendicular to the sun direction and
		// transforming gives us UV-per-meter directly.  The (sunPerp, 0)
		// transform depends only on uniform inputs, so the compiler
		// computes it once per draw.
		float3 sunPerp = abs(gSunDir.y) > 0.99
			? normalize(cross(gSunDir, float3(1, 0, 0)))
			: normalize(cross(gSunDir, float3(0, 1, 0)));
		float2 sunPerpUV = mul(float4(sunPerp, 0.0), ShadowMatrix[idx]).xy
			/ shadowPos.w;
		float texelsPerMeter = length(sunPerpUV) * ShadowMapSize;

		// ── Phase 1: Wide Vogel-disk blocker search ─────────────────
		// The search radius must reach far enough to find occluders
		// for lit-side pixels near the shadow boundary.  Without
		// sufficient reach, PCSS never engages outside the geometric
		// shadow and the shadow cannot widen physically.
		//
		// Adaptive search radius (Fernando 2005):
		// For a directional light, the maximum possible penumbra at
		// this receiver is produced by a blocker at the cascade near
		// plane.  The search radius equals this maximum penumbra so
		// that any blocker that could affect this pixel is found.
		//
		//   searchWorld = receiverDepthInCascade * sunAngularDiameter
		//   searchTexels = searchWorld * texelsPerMeter
		//
		// shadowCoord.z in DCS reversed-Z: larger = closer to light.
		// The receiver's depth within the cascade is proportional to
		// (1.0 - shadowCoord.z) in normalized space, but we can use
		// the world-space blocker distance reconstruction to stay
		// consistent.  For the search radius we use the simpler
		// approximation: the cascade covers a known depth range, and
		// the receiver sits somewhere within it.
		//
		// Practical cap: the search radius is clamped to prevent
		// extreme cost at very deep receivers or high density.
		// 64 texels at the search mip level covers substantial area.
		float refZ = shadowCoord.z + bias * 2.0;

		// Reconstruct receiver world depth within cascade for adaptive
		// search sizing.  Use the world-space distance along gSunDir
		// from cascade near plane.
		float4 nearPlaneWorld = mul(
			float4(shadowPos.xy, 0.0, 1.0),
			ShadowMatrixInv[idx]);
		float receiverCascadeDepth = dot(
			wPos - nearPlaneWorld.xyz / nearPlaneWorld.w, gSunDir);
		receiverCascadeDepth = max(receiverCascadeDepth, 1.0);

		// Adaptive search radius in texels.
		float searchWorld = receiverCascadeDepth * PCSS_SUN_ANGULAR_DIAMETER;
		float searchTexels = searchWorld * texelsPerMeter;
		searchTexels = min(searchTexels, 64.0 * max(1.0, (float)(1 << PCSS_BLOCKER_SEARCH_MIP)));
		float searchRadius = searchTexels / ShadowMapSize;

		// Vogel-disk blocker search with configurable mip level.
		// Non-comparison reads (SampleLevel) are cheaper than PCF taps.
		// At higher mip levels, each tap effectively covers a block of
		// texels, dramatically improving blocker detection coverage.
		float blockerSum = 0;
		float blockerCount = 0;

		// Reuse the blue noise base angle (computed later for PCF, but
		// we need it here too).  Project wPos to screen for the lookup.
		float4 projPosSearch = mul(float4(wPos, 1.0), gViewProj);
		float2 screenUVSearch = (projPosSearch.xy / projPosSearch.w) * float2(0.5, -0.5) + 0.5;
		uint2 noisePixSearch = uint2(screenUVSearch * gSreenParams.xy);
		float searchBaseAngle = ditherBlueNoiseComputed(noisePixSearch) * (2.0 * PI_VAL);

		[loop]
		for (uint si = 0; si < PCSS_BLOCKER_SEARCH_TAPS; ++si)
		{
			float st = ((float)si + 0.5) / (float)PCSS_BLOCKER_SEARCH_TAPS;
			float sa = searchBaseAngle + (float)si * goldenAngle;
			float ss, sc;
			sincos(sa, ss, sc);

			// Uniform area distribution (sqrt) for blocker search --
			// we want even coverage, not rim bias.
			float2 searchDelta = float2(sc, ss) * (sqrt(st) * searchRadius);

			float sd = cascadeShadowMap.SampleLevel(
				gPointClampSampler,
				float3(shadowCoord.xy + searchDelta, 3 - idx),
				PCSS_BLOCKER_SEARCH_MIP).x;

			if (sd > refZ)
			{
				// Center-weighted: blockers closer to the pixel center
				// are more relevant to this pixel's penumbra than those
				// at the search periphery.  Reduces noise at shadow
				// boundaries where the search partially overlaps the
				// geometric shadow.
				float weight = 1.0 - st;
				blockerSum += sd * weight;
				blockerCount += weight;
			}
		}

		if (blockerCount > 0)
		{
			float avgBlockerDepth = blockerSum / blockerCount;

			// Reconstruct world-space blocker distance.
			float4 blockerWorld = mul(
				float4(shadowPos.xy, avgBlockerDepth, 1.0),
				ShadowMatrixInv[idx]);
			float blockerDist = dot(
				blockerWorld.xyz / blockerWorld.w - wPos, gSunDir);

			if (blockerDist > PCSS_MIN_BLOCKER_DIST)
			{
				// Physical penumbra in texels.
				float penumbraTexels = blockerDist
					* PCSS_SUN_ANGULAR_DIAMETER
					* texelsPerMeter;

#if PCSS_RADIUS_OVERDRIVE > 0
				// Clamped mode: limit radius to overdrive * clean fill.
				pcssR = clamp(penumbraTexels, floorRadius,
					maxCleanRadius * PCSS_RADIUS_OVERDRIVE);
#else
				// Unclamped mode: physical radius always wins.
				// Noise at extreme ratios is expected; this mode is
				// for testing physical accuracy or when a post-PCF
				// softening pass handles the noise.
				pcssR = max(penumbraTexels, floorRadius);
#endif
			}
		}
#endif // PCSS_ENABLE

		const float radius = pcssR / ShadowMapSize;

		// ── Rim-biased Vogel disk PCF ───────────────────────────────
		// Golden-angle spiral with configurable radial distribution for
		// non-uniform tap density.  Each tap is positioned at:
		//   angle = baseRotation + i * goldenAngle
		//   r     = pow((i + 0.5)/count, RIM_BIAS_EXPONENT) * radius
		//
		// At exponent 0.5 this is standard Vogel (uniform area density).
		// Lower exponents push taps toward the rim where the penumbra
		// transition lives, defining the edge more cleanly.
		//
		// Acne prevention is handled by normal offset bias applied
		// upstream in SampleShadowCascade.  Per-tap depth uses a simple
		// constant bias for residual quantization noise.
		float baseAngle = 0;
#if USE_ROTATE_PCF
		// Blue noise rotation: decorrelates adjacent pixels more cleanly
		// than white noise, producing smoother perceived gradients when
		// the disk is sparsely filled (PCSS overdrive territory).
		float4 projPos = mul(float4(wPos, 1.0), gViewProj);
		float2 screenUV = (projPos.xy / projPos.w) * float2(0.5, -0.5) + 0.5;
		uint2 noisePix = uint2(screenUV * gSreenParams.xy);
		baseAngle = ditherBlueNoiseComputed(noisePix) * (2.0 * PI_VAL);
#endif
		// Start from i=1 because i=0 is the center tap already in acc.
		[loop]
		for (uint i = 1; i < count; ++i) {
			float t = ((float)i + 0.5) / (float)count;
			float angle = baseAngle + (float)i * goldenAngle;

			float s, c;
			sincos(angle, s, c);

			// Rim-biased Vogel: exponent < 0.5 pushes taps outward.
			float2 delta = float2(c, s) * (pow(t, PCSS_RIM_BIAS_EXPONENT) * radius);

			acc += cascadeShadowMap.SampleCmpLevelZero(
				gCascadeShadowSampler,
				float3(shadowCoord.xy + delta, 3 - idx),
				saturate(shadowCoord.z) + bias);
		}
		acc /= count;
	}
	// return saturate(min(NoL * 10, acc));
	return saturate(acc);
}

//return shadow + AO
float2 SampleShadowClouds(float3 pos)
{
	if(gUseVolumetricCloudsShadow>0)
	{
		float3 uvw = pos * gCloudVolumeScale + gCloudVolumeOffset;
		float2 s = cloudsShadowTex3D.SampleLevel(gBilinearClampSampler, uvw.xzy, 0).yx;
		if(uvw.y>1) s = 1;
		float extinctionScale = 6.0;
		s.x = exp(-extinctionScale * (1.0 - s.x));
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

		// ── Normal offset bias ──────────────────────────────────
		// Shift the shadow lookup position along the surface normal.
		// At grazing sun angles (low NoL), shadow map texels stretch
		// across the surface and self-intersection is severe.  The
		// offset lifts the lookup point above the surface, preventing
		// the shadow map from seeing the receiver as its own occluder.
		//
		// At perpendicular sun angles (NoL near 1), the offset is
		// near zero -- no correction needed, no shadow detachment.
		//
		// This is applied to wPos before all cascade lookups so every
		// cascade benefits from the same geometric correction.
		wPos += normal * PCSS_NORMAL_OFFSET_SCALE * (BASE_SHADOWMAP_SIZE / ShadowMapSize) * (1.0 - NoL);
	}

	if (useOnlyFirstMap) {
		return SampleShadowMap(wPos, NoL, ShadowFirstMap, usePCF, PCSS_TAPS_CASCADE_3, false, PCSS_FLOOR_CASCADE_3);
	} else {
		// DCS cascade numbering: 0 = farthest, 3 = nearest.
		// ShadowDistance[0] is the farthest boundary,
		// ShadowDistance[3] is the nearest.
		if (depth > ShadowDistance[0])
			return SampleShadowMap(wPos, NoL, 0, usePCF, PCSS_TAPS_CASCADE_0, useTreeShadow, PCSS_FLOOR_CASCADE_0);

		if (depth > ShadowDistance[1])
			return SampleShadowMap(wPos, NoL, 1, usePCF, PCSS_TAPS_CASCADE_1, useTreeShadow, PCSS_FLOOR_CASCADE_1);

		if (depth > ShadowDistance[2])
			return SampleShadowMap(wPos, NoL, 2, usePCF, PCSS_TAPS_CASCADE_2, useTreeShadow, PCSS_FLOOR_CASCADE_2);

		if (depth > ShadowDistance[3]) {
			if (useTreeShadow)
				return max(SampleShadowMap(wPos, NoL, 3, usePCF, PCSS_TAPS_CASCADE_3, true, PCSS_FLOOR_CASCADE_3), smoothstep(ShadowDistance[2], ShadowDistance[3], depth));
			else
				return max(SampleShadowMap(wPos, NoL, 3, usePCF, PCSS_TAPS_CASCADE_3, false, PCSS_FLOOR_CASCADE_3), smoothstep(ShadowCascadeFadeDepth, ShadowDistance[3], depth));
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
