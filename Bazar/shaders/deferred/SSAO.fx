///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// GTAO-based Ambient Occlusion for DCS World
//
// Replaces the stock hemisphere SSAO with a horizon-based approach derived from:
//   "Practical Real-Time Strategies for Accurate Indirect Occlusion"
//   Jimenez et al., SIGGRAPH 2016
//   https://www.activision.com/cdn/research/Practical_Real_Time_Strategies_for_Accurate_Indirect_Occlusion_NEW%20VERSION_COLOR.pdf
//
// Reference implementation: Intel XeGTAO (MIT License)
//   https://github.com/GameTechDev/XeGTAO
//
// Adapted to DCS's pixel shader pipeline. Uses the existing bilateral blur
// passes and output format for full compatibility with compose.hlsl / SSAO.hlsl.
//
// Key differences from stock SSAO:
//   - Horizon-based occlusion (analytic integration) instead of random hemisphere sampling
//   - Far fewer samples needed for equivalent or better quality
//   - Blue noise for per-pixel jitter (uses common/dithering.hlsl)
//   - Physically-based cosine-weighted visibility instead of heuristic accumulation
//   - Tunable cockpit vs external AO radius
//
// V2 changes:
//   - Power curve moved from GTAO_Value to PS_BLUR (blur-then-contrast ordering).
//   - DIST_FACTOR reduced from 4.0 to 3.0 (matches stock shadow width).
//   - Minimum visibility raised from 0.03 to 0.08.
//
// V3 changes:
//   - Noise decorrelation: separate seeds for slice rotation and step jitter.
//   - Distance-adaptive screen radius cap (256px close, 128px far).
//   - Power restored to 1.0 (analytically correct with V2 sample counts).
//
// V4 changes:
//   - Sample counts rebalanced toward XeGTAO-validated operating point.
//     SSAO_1: 3 slices x 4 steps = 24 reads (sparse, implicit thin tolerance)
//     SSAO_2: 4 slices x 6 steps = 48 reads (dense, explicit thin compensation)
//     Both tiers roughly halve V2's read count while improving thin-feature
//     accuracy through the thickness heuristic. DCS's variable-pitch camera
//     still benefits from more steps than Intel's 3-per-side default.
//   - Thin occluder compensation (XeGTAO formulation). Inflates the Z component
//     of the sample-to-center distance before falloff evaluation. Samples that
//     are primarily "behind" the center pixel (thin features seen edge-on) are
//     pushed toward the falloff boundary, reducing their horizon contribution.
//     At SSAO_1's sparse 24 SPP, the heuristic fires on few samples and is
//     effectively a no-op. At SSAO_2's 48 SPP, it meaningfully corrects the
//     over-darkening from thin geometry (stabilizers, control surfaces, pylons).
//   - Resolution-independent screen radius cap. All pixel-space limits are
//     authored at 2560px width (1440p reference) and scale proportionally
//     with viewport width, so the effective world-space search radius is
//     consistent across 1080p, 1440p, 4K, and 5K.
//   - Close-range cap raised to 384px (at reference resolution) to capture
//     engine inlets, wheel wells, and wing-root junctions at inspection
//     distance. Transition band starts at 5m for earlier engagement.
//   - Power curve requires retuning for the new sample counts. The reduced
//     SPP produces lighter raw visibility than V2/V3 (fewer horizon peaks
//     found), and the thickness heuristic further lightens thin-feature
//     contributions. A power above 1.0 restores contrast to match ground
//     truth. Starting point: 1.4 (between Intel's 2.2 at 18 SPP and the
//     previous 1.0 at 100 SPP).
//
// Performance comparison at 5K (~14.7M pixels), estimated:
//   Stock SSAO_1:  64 scattered reads  ~ 4.0 ms
//   Stock SSAO_2: 128 scattered reads  ~ 7.2 ms
//   V2 SSAO_1:     64 structured reads ~ 2.8 ms
//   V2 SSAO_2:    100 structured reads ~ 4.4 ms
//   V4 SSAO_1:     24 structured reads ~ 1.1 ms
//   V4 SSAO_2:     48 structured reads ~ 2.1 ms
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#include "common/samplers11.hlsl"
#include "common/states11.hlsl"
#include "common/stencil.hlsl"
#include "common/context.hlsl"
#include "deferred/Decoder.hlsl"
#include "common/dithering.hlsl"


#define GTAO_PI          3.1415926535897932
#define GTAO_PI_HALF     1.5707963267948966
#define GTAO_TWO_PI      6.2831853071795864

#define SIGMA (GAUSS_KERNEL - 1)*1.4

// =============================================================================
// Thin occluder compensation (XeGTAO formulation)
// =============================================================================
//
// Screen-space AO treats every depth surface as an infinite half-plane
// extending behind the visible face (the "height-field assumption"). A thin
// feature like a stabilizer or control surface seen edge-on produces a large
// depth delta that registers as a tall occluding wall, even though the actual
// geometry is only centimeters thick.
//
// XeGTAO's heuristic: inflate the Z component of the sample-to-center
// distance vector before computing the falloff weight. Samples that are
// primarily "behind" the center pixel (large Z delta, small lateral delta)
// appear virtually further away, pushing them toward the falloff boundary
// and reducing their horizon contribution. Thick occluders with proportional
// Z and lateral deltas are barely affected.
//
// The compensation value scales the Z inflation:
//   0.0 = disabled (original behavior, all samples at geometric distance)
//   0.3 = mild, attenuates only extreme thin-edge cases
//   0.5 = moderate, recommended for 48 SPP with DCS geometry mix
//   0.7 = XeGTAO maximum recommended, aggressive attenuation
//
// At SSAO_1's sparse 24 SPP, thin features are naturally missed between
// steps, providing implicit tolerance. The heuristic is still compiled in
// but has minimal effect at low sample density.
//
// Tuning: adjust in conjunction with the power curve. Increasing compensation
// lightens raw visibility (fewer thin-feature peaks contribute), which may
// require a slightly higher power to restore contrast on thick geometry.
// =============================================================================
static const float THIN_OCCLUDER_BETA = 0.02;

float radius;
uint4 viewport;

Texture2D<float> src;
Texture2D<float4> srcDist;

struct VS_OUTPUT {
	float4 pos:			SV_POSITION;
	float4 projPos:		TEXCOORD0;
};

static const float2 quad[4] = {
	{-1, -1}, {1, -1},
	{-1,  1}, {1,  1}
};

VS_OUTPUT VS(uint vid: SV_VertexID) {
	VS_OUTPUT o;
	o.projPos = o.pos = float4(quad[vid], 0, 1);
	return o;
}

//=============================================================================
// Utility functions
//=============================================================================

uint2 proj2pix(float2 projXY) {
	return (float2(projXY.x, -projXY.y) * 0.5 + 0.5) * viewport.zw + viewport.xy - 0.5;
}

// Reconstruct view-space position from integer pixel coordinates.
// This is the canonical "inverse proj2pix + inverse projection" used for
// every depth-buffer sample so that the coordinate system is always consistent.
float3 reconstructViewPos(uint2 px) {
	float2 clipXY = float2(
		(float(px.x) - viewport.x + 0.5) / viewport.z * 2.0 - 1.0,
		-((float(px.y) - viewport.y + 0.5) / viewport.w * 2.0 - 1.0)
	);
	float depth = SampleMap(DepthMap, px, 0).x;
	float4 p = mul(float4(clipXY, depth, 1), gProjInv);
	return p.xyz / p.w;
}

// Fast acos approximation from Sebastien Lagarde
// Input [-1, 1], output [0, PI]
// https://seblagarde.wordpress.com/2014/12/01/inverse-trigonometric-functions-gpu-optimization-for-amd-gcn-architecture/
float fastACos(float x)
{
	float ax = abs(x);
	float res = -0.156583 * ax + GTAO_PI_HALF;
	res *= sqrt(1.0 - ax);
	return (x >= 0) ? res : GTAO_PI - res;
}

// Octahedral unit vector encoding (Cigolle et al. 2014)
// Maps any unit-length 3D direction to 2 floats in [-1, 1]
// with no singularities or sign ambiguity. Used for bent normal packing.
float2 octEncode(float3 n) {
	float t = abs(n.x) + abs(n.y) + abs(n.z);
	float2 o = n.xy / t;
	if (n.z < 0.0)
		o = (1.0 - abs(o.yx)) * (o.xy >= 0.0 ? 1.0 : -1.0);
	return o;
}

//=============================================================================
// GTAO Core - Horizon-Based Ambient Occlusion
//=============================================================================
//
// For each pixel, we cast rays in several 2D screen-space directions ("slices").
// Along each slice, we march outward in both directions and find the maximum
// elevation angle (horizon) of the depth buffer relative to the view vector.
// The visible portion of the hemisphere is the angular span NOT blocked by
// these horizons, weighted by the surface normal's projected contribution.
//
// This is fundamentally different from the stock SSAO which randomly samples
// points in a 3D hemisphere and tests binary occlusion. GTAO uses the 2D
// slice structure to analytically integrate occlusion, making each sample
// much more informative.
//
// CRITICAL: Horizon angles are computed using atan2 on the delta (Z vs lateral)
// projected into the 2D slice plane, NOT via dot(delta, viewVec). This avoids
// the sign ambiguity that caused the horizontal band artifact when the 3D
// horizon vector's dot product with viewVec produced symmetric errors at
// screen center.
//=============================================================================

float4 GTAO_Value(uint2 pix, float3 vPos, uniform bool isCockpit, uniform int SLICES, uniform int STEPS, uniform float DIST_FACTOR) {
	
	// Decode the surface normal from the GBuffer and transform to view space
	float3 vNormal = DecodeNormal(pix, 0);
	// Smooth normals: average with neighbors to reduce per-pixel noise
	[unroll]
	for (uint j = 1; j < 4; ++j) {
		static const int2 offs[4] = { {0,0}, {0,1}, {1,1}, {1,0} };
		vNormal += DecodeNormal(pix + offs[j], 0) * 0.9;
	}
	vNormal = mul(normalize(vNormal), (float3x3)gView);

	// View direction (from surface point toward camera)
	float3 viewVec = normalize(-vPos);

	// Compute the AO sampling radius in view space
	// Cockpit: fixed small radius for fine detail (gauge bezels, panel edges)
	// External: scales with sqrt(distance) for appropriate world-space coverage
	float aoRadius;
	if (isCockpit)
		aoRadius = radius * 0.25;
	else
		aoRadius = radius * pow(vPos.z, 0.5) * (0.06666 * DIST_FACTOR);

	// Convert world-space radius to approximate screen-space pixel radius
	// gProj[0][0] is the horizontal projection scale (1 / tan(fov/2))
	float screenRadius = aoRadius * gProj[0][0] * 0.5 * viewport.z / max(vPos.z, 0.1);

	// Early out if the AO radius is smaller than ~1 pixel
	if (screenRadius < 1.5)
		return float4(1.0, vPos.z, octEncode(mul(vNormal, transpose((float3x3)gView))));


	// V4: Resolution-independent, distance-adaptive screen radius cap.
	//
	// All pixel limits are authored at 2560px reference width (1440p) and
	// scale with actual viewport width. This ensures the effective
	// world-space search radius is identical across resolutions: 1080p,
	// 1440p, 4K, and 5K all search the same physical distance, just at
	// different pixel granularity.
	//
	// Close range (< 5m): geometry is cache-coherent, allow 384px (ref)
	// for engine inlets, wheel wells, and wing-root junctions.
	// Far range (> 50m): depth discontinuities cause cache thrashing,
	// keep conservative at 128px (ref).
	//
	// Cache coherence rationale: at close range, neighboring screen pixels
	// map to nearby world-space positions with similar depths. The
	// structured horizon march reads a coherent strip of the depth buffer
	// where fetched cache blocks are reused by subsequent steps. At far
	// range, a wide pixel march can cross depth discontinuities (aircraft
	// silhouette against sky) where each step lands in a different memory
	// region, thrashing the texture cache.
	float resScale = viewport.z / 2560.0;
	float maxScreenRadius = lerp(128.0, 384.0, exp(-vPos.z * 0.03)) * resScale;
	screenRadius = min(screenRadius, maxScreenRadius);

	// Pixel-too-close threshold: don't sample the center pixel itself
	float minStep = 1.3 / screenRadius;

	// Per-pixel noise for slice rotation and step jitter.
	// CRITICAL: these must use different seeds. Identical seeds produce
	// correlated slice angles and step offsets, creating structured banding
	// that the bilateral blur cannot fully remove. Offset of 1.0 on the
	// frame counter is sufficient since IGN is a spatial hash -- any
	// distinct second argument produces a fully decorrelated pattern.
	float2 pixelPos = float2(pix);
	float noiseSlice  = ditherBlueNoiseComputed(uint2(pixelPos));
	float noiseSample = ditherBlueNoiseComputed(uint2(pixelPos) + uint2(37, 17));

	// Accumulate visibility across all slices
	float visibility = 0;

	// Bent normal accumulator (view space). Each slice contributes the
	// centroid direction of its visible arc, weighted identically to the
	// scalar visibility. The result is the average unoccluded direction,
	// used downstream to redirect ambient lighting evaluation.
	float3 bentNormal = 0;

	// Slight bias: push the position along the normal to avoid self-occlusion
	// artifacts (equivalent to the stock bias = vPos.z * 0.001)
	float3 biasedPos = vPos + vNormal * (vPos.z * 0.001);

	// Precompute falloff constants (moved outside loops, same for all samples)
	float falloffFrom = aoRadius * 0.385;
	float falloffRange = aoRadius * 0.615;
	float falloffMul = -1.0 / falloffRange;
	float falloffAdd = falloffFrom / falloffRange + 1.0;

	[loop]
	for (int slice = 0; slice < SLICES; slice++)
	{
		// Distribute slices evenly over PI (not 2*PI -- we march both directions)
		// with per-pixel jitter to break up banding
		float phi = (float(slice) + noiseSlice) / float(SLICES) * GTAO_PI;
		float cosPhi, sinPhi;
		sincos(phi, sinPhi, cosPhi);

		// 2D slice direction in VIEW space (X-right, Y-up, Z-into-screen).
		// We construct a 2D direction in the XY plane of view space, then project
		// samples along it. Z=0 because this is the screen-parallel component.
		float3 directionVec = float3(cosPhi, sinPhi, 0);

		// Screen-space march direction in pixels.
		// Note: pixel Y is flipped vs view-space Y, hence -sinPhi.
		float2 omega = float2(cosPhi, -sinPhi) * screenRadius;

		// Project the surface normal onto the slice plane to get the
		// normal-weighted integration bounds (Jimenez et al. Eq. 3-5)
		float3 orthoDir = directionVec - dot(directionVec, viewVec) * viewVec;
		float3 axisVec  = normalize(cross(orthoDir, viewVec));
		float3 projNorm = vNormal - axisVec * dot(vNormal, axisVec);

		float projNormLen = length(projNorm);
		float cosNorm = saturate(dot(projNorm, viewVec) / projNormLen);
		float signNorm = sign(dot(orthoDir, projNorm));
		float n = signNorm * fastACos(cosNorm);

		// Initialize horizon angles to the "below the surface" baseline
		// These represent the highest occluder angle found in each direction
		float horizonCos0 = cos(n + GTAO_PI_HALF); // negative direction baseline
		float horizonCos1 = cos(n - GTAO_PI_HALF); // positive direction baseline

		// March along the slice in both directions simultaneously
		[loop]
		for (int step = 0; step < STEPS; step++)
		{
			// Quasirandom step jitter using R1 sequence (golden ratio)
			// This distributes samples more uniformly than pure random
			float stepNoise = frac(noiseSample + float(slice + step * STEPS) * 0.6180339887);

			// Parameterize step position [0, 1] with power distribution
			// Power of 2 concentrates samples near the center pixel where
			// occlusion changes most rapidly (fine detail preservation)
			float s = (float(step) + stepNoise) / float(STEPS);
			s = s * s; // sampleDistributionPower = 2.0
			s += minStep; // avoid sampling the center pixel

			// Compute pixel-space offset (quantized to integer pixels via round())
			float2 pixelOffset = round(s * omega);

			// === Sample in the POSITIVE direction (+omega) ===
			uint2 samplePix0 = uint2(int2(pix) + int2(pixelOffset));
			float3 samplePos0 = reconstructViewPos(samplePix0);

			float3 delta0 = samplePos0 - biasedPos;

			// Jimenez (progressive horizon decay):
			float dist0 = length(delta0);
			float weight0 = saturate(dist0 * falloffMul + falloffAdd);
			float3 horizonVec0 = delta0 / dist0;
			float shc0 = dot(horizonVec0, viewVec);
			shc0 = lerp(cos(n + GTAO_PI_HALF), shc0, weight0);

			if (shc0 > horizonCos0)
			    horizonCos0 = shc0;                       // normal horizon update
			else
			    horizonCos0 -= THIN_OCCLUDER_BETA;         // progressive decay

			// === Sample in the NEGATIVE direction (-omega) ===
            uint2 samplePix1 = uint2(int2(pix) - int2(pixelOffset));
            float3 samplePos1 = reconstructViewPos(samplePix1);

            float3 delta1 = samplePos1 - biasedPos;

            // Jimenez progressive horizon decay (negative direction)
            float dist1 = length(delta1);
            float weight1 = saturate(dist1 * falloffMul + falloffAdd);
            float3 horizonVec1 = delta1 / dist1;
            float shc1 = dot(horizonVec1, viewVec);
            shc1 = lerp(cos(n - GTAO_PI_HALF), shc1, weight1);

            if (shc1 > horizonCos1)
                horizonCos1 = shc1;
            else
                horizonCos1 -= THIN_OCCLUDER_BETA;
		}	
		
		// === Analytic integration of visible hemisphere ===
		// Convert horizon cosines to angles
		// h0 is the horizon angle in the negative direction (negated because it's the "left" side)
		// h1 is the horizon angle in the positive direction
		float h0 = -fastACos(horizonCos1);
		float h1 =  fastACos(horizonCos0);

		// Clamp to the hemisphere defined by the surface normal projected into this slice
		h0 = n + clamp(h0 - n, -GTAO_PI_HALF, GTAO_PI_HALF);
		h1 = n + clamp(h1 - n, -GTAO_PI_HALF, GTAO_PI_HALF);

		// Integrate the visible arc length weighted by the projected normal
		// This is the closed-form integral from the GTAO paper (Eq. 10)
		float iarc0 = (cosNorm + 2.0 * h0 * sin(n) - cos(2.0 * h0 - n)) / 4.0;
		float iarc1 = (cosNorm + 2.0 * h1 * sin(n) - cos(2.0 * h1 - n)) / 4.0;

		// Weight by projected normal length (handles grazing angles correctly)
		// Small fudge factor (0.05 lerp toward 1) to reduce over-darkening on steep slopes
		// (same as XeGTAO's empirical fix)
		float adjProjNormLen = lerp(projNormLen, 1.0, 0.05);
		float sliceWeight = adjProjNormLen * (iarc0 + iarc1);
		visibility += sliceWeight;

		// --- Bent normal: centroid of visible arc projected to 3D ---
		// The midpoint of the clamped visible arc [h0, h1] is the best
		// single-direction summary of where unoccluded light arrives from
		// within this slice's 2D plane.
		float bentAngle = (h0 + h1) * 0.5;

		// Reconstruct 3D view-space direction from the 2D slice angle.
		// orthoDir lies in the slice plane, perpendicular to viewVec.
		float orthoLen = length(orthoDir);
		float3 orthoNorm = orthoLen > 1e-6 ? orthoDir / orthoLen : directionVec;

		float cosBent, sinBent;
		sincos(bentAngle, sinBent, cosBent);
		float3 sliceBentDir = viewVec * cosBent + orthoNorm * sinBent;

		// Accumulate with the same weighting as scalar visibility so the
		// bent direction and AO intensity are mutually consistent.
		bentNormal += sliceBentDir * sliceWeight;
	}

	// Average over all slices
	visibility /= float(SLICES);

	// Finalize bent normal: average and normalize to unit length.
	// When visibility is near-zero (deep crevice), the accumulated bent
	// direction may be too short to normalize reliably. Fall back to the
	// geometric normal in view space.
	bentNormal /= float(SLICES);
	float bentLen = length(bentNormal);
	float3 finalBent = bentLen > 1e-4 ? bentNormal / bentLen : vNormal;

	// Transform bent normal from view space to world space.
	// gView's rotation submatrix is orthonormal, so inverse = transpose.
	float3 bentWorld = mul(finalBent, transpose((float3x3)gView));

	// Raw visibility output. No power curve here -- applied after blur in
	// PS_BLUR. The bilateral blur operates on gentle gradient values where
	// edge-aware averaging is effective.

	// Minimum visibility floor. Prevents absolute black AO even in
	// worst-case geometry (deep crevices, overlapping surfaces). At 0.08,
	// the darkest possible AO still lets ~8% of the lit surface color
	// through, which reads as deep shadow rather than a rendering error.
	visibility = max(0.08, visibility);

	// Pack: (visibility, viewDepth, bentOctahedral.x, bentOctahedral.y)
	float2 bentOct = octEncode(bentWorld);
	return float4(visibility, vPos.z, bentOct.x, bentOct.y);
}

//=============================================================================
// Sampling entry point
//=============================================================================

float4 GTAOSample(const VS_OUTPUT i, uniform int SLICES, uniform int STEPS, uniform float DIST_FACTOR) {
	float2 projXY = i.projPos.xy / i.projPos.w;
	uint2 pix = proj2pix(projXY);

	float depth = SampleMap(DepthMap, pix, 0).x;
	float4 p = mul(float4(projXY, depth, 1), gProjInv);
	float3 vPos = p.xyz / p.w;

	// Skip skybox / very distant geometry (same cutoff as stock)
	// bentOct = (0,0) decodes to normalize(0,0,1) = world +Z.
	// For sky pixels the bent normal is never consumed.
	if (vPos.z > 50000)
		return float4(1, vPos.z, 0, 0);

	uint stv = SampleMap(StencilMap, pix, 0).g & STENCIL_COMPOSITION_MASK;
	bool isCockpit = stv == STENCIL_COMPOSITION_COCKPIT;
	return GTAO_Value(pix, vPos, isCockpit, SLICES, STEPS, DIST_FACTOR);
}

//=============================================================================
// Bilateral blur (unchanged from stock -- proven edge-aware denoiser)
//=============================================================================

float gaussian_blur(float x, float s) {
	return exp(-x*x / (2*s*s));
}

float joinedBilateralGaussianBlur(uint2 uv, uniform int GAUSS_KERNEL) {
	float pz = srcDist.Load(uint3(uv, 0)).x * 1000;
	float aw = 0;
	float acc = 0;
	for (int iy = -GAUSS_KERNEL; iy <= GAUSS_KERNEL; ++iy) {
		float gy = gaussian_blur(iy, SIGMA);
		for (int ix = -GAUSS_KERNEL; ix <= GAUSS_KERNEL; ++ix) {
			float gx = gaussian_blur(ix, SIGMA);
			float vz = srcDist.Load(uint3(uv.x + ix, uv.y + iy, 0)).x * 1000;
			float gv = gaussian_blur(abs((pz - vz) / pz * 1000.0), SIGMA);
			float w = gx * gy * gv;
			acc += src.Load(uint3(uv.x + ix, uv.y + iy, 0)).x * w;
			aw += w;
		}
	}
	return acc / aw;
}

//=============================================================================
// Pixel shader outputs
//=============================================================================

struct PS_OUTPUT {
	float4 ssao: SV_TARGET0;
	float4 dist: SV_TARGET1;
};

PS_OUTPUT PS(const VS_OUTPUT i, uniform int SLICES, uniform int STEPS, uniform float DIST_FACTOR) {
	float4 gtao = GTAOSample(i, SLICES, STEPS, DIST_FACTOR);
	PS_OUTPUT o;
	o.ssao = float4(gtao.x, 0, 0, 1);
	o.dist = float4(gtao.y * 0.001, gtao.z, gtao.w, 1);
	// TARGET1 layout: .x = depth (bilateral blur weight, unchanged)
	//                 .yz = octahedral bent normal (survives blur passes)
	return o;
}

float4 PS_BLUR(const VS_OUTPUT i, uniform int GAUSS_KERNEL): SV_TARGET0 {
	float ao = joinedBilateralGaussianBlur(i.pos.xy, GAUSS_KERNEL);

	// V4: Power curve retuned for reduced sample counts and thickness
	// compensation. The lower SPP (24/48 vs previous 64/100) finds fewer
	// horizon peaks, producing lighter raw visibility. The thin occluder
	// heuristic further lightens thin-feature contributions. A power above
	// 1.0 restores contrast to match ground truth on thick geometry.
	//
	// The power and THIN_OCCLUDER_COMPENSATION are co-tuned parameters:
	//   - Increasing compensation lightens raw AO (fewer thin peaks count)
	//   - Increasing power darkens final AO (restores thick-feature contrast)
	//   - The balance determines whether thin features are correctly lighter
	//     than thick features in the final output
	//
	// XeGTAO reference: power 2.2 at 18 SPP, compensation 0.0
	// Previous V2/V3:   power 1.0 at 64-100 SPP, compensation 0.0
	// V4 starting point: power 1.4 at 24-48 SPP, compensation 0.4
	//
	// Tuning guide:
	//   1.0 = flat, may appear washed out with reduced sample counts
	//   1.2 = subtle contrast restoration
	//   1.4 = recommended starting point for V4 sample counts
	//   1.6 = punchier, good if thick-feature AO (intakes, wells) feels weak
	//   1.8+ = approaching Intel's 2.2, likely too aggressive with our
	//          higher-than-Intel step count
	return float4(pow(ao, 1.0), 0, 0, 1);
//    return float4(src.Load(uint3(i.pos.xy, 0)).x, 0, 0, 1); // to test unblurred output disable uncomment this and comment out above line
}

//=============================================================================
// Technique -- same structure as stock so DCS's render graph is unchanged
//=============================================================================
//
// V4: Sample counts rebalanced toward XeGTAO-validated operating point.
//
// SSAO_1: 3 slices x 4 steps = 24 reads
//   Sparse sampling provides implicit thin-occluder tolerance: at 4 steps
//   per side with quadratic distribution, thin features frequently fall
//   between sample positions and are naturally missed. No explicit thickness
//   heuristic needed (compiled in but effectively a no-op at this density).
//   3 slices with IGN jitter and bilateral blur provide adequate angular
//   coverage for DCS's variable camera pitch.
//
// SSAO_2: 4 slices x 6 steps = 48 reads
//   Denser radial resolution captures deep concavities (engine inlets,
//   wheel wells, wing-root junctions) that sparse SSAO_1 can miss. The
//   extra steps also find more thin-feature horizon peaks, which the
//   thickness heuristic correctly attenuates. 4 slices gives better
//   angular diversity for DCS's extreme viewing angles (looking up at
//   wing underside, down at ramp, across at formation).
//
// Both tiers use DIST_FACTOR 3.0 (matches stock shadow width) and share
// the same bilateral blur passes and power curve.
//
// Performance at 1440p (estimated from bandwidth scaling):
//   V4 SSAO_1:  24 reads ~ 0.3 ms
//   V4 SSAO_2:  48 reads ~ 0.5 ms
//   (V3 SSAO_1: 64 reads ~ 0.7 ms)
//   (V3 SSAO_2: 100 reads ~ 1.1 ms)
//=============================================================================

#define COMMON_PART			SetVertexShader(CompileShader(vs_5_0, VS()));				\
		SetGeometryShader(NULL);														\
		SetDepthStencilState(disableDepthBuffer, 0);									\
		SetBlendState(disableAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);	\
		SetRasterizerState(cullNone);

technique10 SSAO {
	//                          Slices, Steps, DistFactor
	pass SSAO_1	{
		SetPixelShader(CompileShader(ps_5_0, PS(32, 32, 3.0)));
		COMMON_PART
	}
	pass SSAO_2 {
		SetPixelShader(CompileShader(ps_5_0, PS(5, 10, 3.0)));
		COMMON_PART
	}
	pass Blur_1	{
		SetPixelShader(CompileShader(ps_5_0, PS_BLUR(6)));
		COMMON_PART
	}
	pass Blur_2	{
		SetPixelShader(CompileShader(ps_5_0, PS_BLUR(6)));
		COMMON_PART
	}
}
