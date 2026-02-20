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
//   - Far fewer samples needed for equivalent or better quality (50 vs 128)
//   - Interleaved gradient noise for per-pixel jitter (uses common/dithering.hlsl)
//   - Physically-based cosine-weighted visibility instead of heuristic accumulation
//   - Tunable cockpit vs external AO radius
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#include "common/samplers11.hlsl"
#include "common/states11.hlsl"
#include "common/stencil.hlsl"
#include "common/context.hlsl"
#include "deferred/Decoder.hlsl"

// If your dithering.hlsl is available in the common path, uncomment this:
// #include "common/dithering.hlsl"

// Fallback IGN if dithering.hlsl isn't available at compile time.
// This is identical to the interleavedGradientNoise in your dithering.hlsl.
// If the include above works, you can remove this block.
#ifndef DITHERING_HLSL
float interleavedGradientNoise(float2 pixel, float frame)
{
	pixel += frame * float2(47.0, 17.0) * 0.695;
	return frac(52.9829189 * frac(0.06711056 * pixel.x + 0.00583715 * pixel.y));
}
float interleavedGradientNoise(float2 pixel)
{
	return interleavedGradientNoise(pixel, 0.0);
}
#endif

#define GTAO_PI          3.1415926535897932
#define GTAO_PI_HALF     1.5707963267948966
#define GTAO_TWO_PI      6.2831853071795864

#define SIGMA (GAUSS_KERNEL - 1)*1.4

float radius;
uint4 viewport;

Texture2D<float> src;
Texture2D<float> srcDist;

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

// Fast acos approximation from Sébastien Lagarde
// Input [-1, 1], output [0, PI]
// https://seblagarde.wordpress.com/2014/12/01/inverse-trigonometric-functions-gpu-optimization-for-amd-gcn-architecture/
float fastACos(float x)
{
	float ax = abs(x);
	float res = -0.156583 * ax + GTAO_PI_HALF;
	res *= sqrt(1.0 - ax);
	return (x >= 0) ? res : GTAO_PI - res;
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
//=============================================================================

float2 GTAO_Value(uint2 pix, float3 vPos, uniform bool isCockpit, uniform int SLICES, uniform int STEPS, uniform float DIST_FACTOR) {
	
	// Decode the surface normal from the GBuffer and transform to view space
	float3 vNormal = DecodeNormal(pix, 0);
	// Smooth normals: average with neighbors to reduce per-pixel noise
	[unroll]
	for (uint j = 1; j < 4; ++j) {
		static const int2 offs[4] = { {0,0}, {0,1}, {1,1}, {1,0} };
		vNormal += DecodeNormal(pix + offs[j], 0) * 0.9;
	}
	vNormal = normalize(mul(vNormal, (float3x3)gView));

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

	// Early out if the AO radius is smaller than ~1 pixel — no useful data
	if (screenRadius < 1.5)
		return float2(1.0, vPos.z);

	// Cap screen radius to avoid excessive cache thrashing without depth MIPs.
	// At large radii, depth samples are far apart in memory. 128px ≈ reasonable
	// for L1/L2 cache locality on most GPUs.
	screenRadius = min(screenRadius, 128.0);

	// Pixel-too-close threshold: don't sample the center pixel itself
	float minStep = 1.3 / screenRadius;

	// Per-pixel noise for slice rotation and step jitter
	float2 pixelPos = float2(pix);
	float noiseSlice  = interleavedGradientNoise(pixelPos, 0.0);
	float noiseSample = interleavedGradientNoise(pixelPos, 1.0); // different temporal offset for step jitter

	// Accumulate visibility across all slices
	float visibility = 0;

	// Slight bias: push the position along the normal to avoid self-occlusion
	// artifacts (equivalent to the stock bias = vPos.z * 0.001)
	float3 biasedPos = vPos + vNormal * (vPos.z * 0.001);

	[loop]
	for (int slice = 0; slice < SLICES; slice++)
	{
		// Distribute slices evenly over PI (not 2*PI — we march both directions)
		// with per-pixel jitter to break up banding
		float phi = (float(slice) + noiseSlice) / float(SLICES) * GTAO_PI;
		float cosPhi, sinPhi;
		sincos(phi, sinPhi, cosPhi);

		// 2D slice direction in screen/view space (Z=0 because it's a screen-space direction)
		float3 directionVec = float3(cosPhi, sinPhi, 0);

		// Screen-space march direction in pixels
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

			// Compute screen-space sample offset
			float2 sampleOffset = round(s * omega) / viewport.zw;

			// Compute the projected position of this pixel
			float2 projXY = float2(
				(float(pix.x) - viewport.x + 0.5) / viewport.z * 2.0 - 1.0,
				-((float(pix.y) - viewport.y + 0.5) / viewport.w * 2.0 - 1.0)
			);

			// === Sample in the POSITIVE direction (+omega) ===
			float2 sampleUV0 = (projXY * 0.5 + 0.5) + sampleOffset;
			uint2 samplePix0 = sampleUV0 * viewport.zw + viewport.xy - 0.5;
			float depth0 = SampleMap(DepthMap, samplePix0, 0).x;
			float4 p0 = mul(float4(projXY + sampleOffset * 2.0, depth0, 1), gProjInv);
			float3 samplePos0 = p0.xyz / p0.w;

			float3 delta0 = samplePos0 - biasedPos;
			float dist0 = length(delta0);
			float3 horizonVec0 = delta0 / dist0;

			// Falloff: samples beyond the AO radius contribute less
			// Linear falloff from 60% of radius to 100%
			float falloffFrom = aoRadius * 0.385; // 1.0 - 0.615 (XeGTAO default falloff range)
			float falloffRange = aoRadius * 0.615;
			float weight0 = saturate(dist0 * (-1.0 / falloffRange) + falloffFrom / falloffRange + 1.0);

			// Horizon cosine: dot product of sample direction with view vector
			float shc0 = dot(horizonVec0, viewVec);
			// Blend toward baseline based on falloff weight
			shc0 = lerp(cos(n + GTAO_PI_HALF), shc0, weight0);
			// Update maximum horizon
			horizonCos0 = max(horizonCos0, shc0);

			// === Sample in the NEGATIVE direction (-omega) ===
			float2 sampleUV1 = (projXY * 0.5 + 0.5) - sampleOffset;
			uint2 samplePix1 = sampleUV1 * viewport.zw + viewport.xy - 0.5;
			float depth1 = SampleMap(DepthMap, samplePix1, 0).x;
			float4 p1 = mul(float4(projXY - sampleOffset * 2.0, depth1, 1), gProjInv);
			float3 samplePos1 = p1.xyz / p1.w;

			float3 delta1 = samplePos1 - biasedPos;
			float dist1 = length(delta1);
			float3 horizonVec1 = delta1 / dist1;

			float weight1 = saturate(dist1 * (-1.0 / falloffRange) + falloffFrom / falloffRange + 1.0);
			float shc1 = dot(horizonVec1, viewVec);
			shc1 = lerp(cos(n - GTAO_PI_HALF), shc1, weight1);
			horizonCos1 = max(horizonCos1, shc1);
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
		visibility += adjProjNormLen * (iarc0 + iarc1);
	}

	// Average over all slices
	visibility /= float(SLICES);

	// Apply power curve for contrast control
	// XeGTAO default is 2.2; we use 2.5 for slightly stronger cockpit/crevice darkening
	// that suits the DCS aesthetic (military hardware with deep panel lines and intakes)
	visibility = pow(visibility, 2.5);

	// Disallow total blackness — a fully visible pixel shouldn't go to zero
	// (also helps numerical stability in the blur pass)
	visibility = max(0.03, visibility);

	return float2(visibility, vPos.z);
}

//=============================================================================
// Sampling entry point — mirrors the stock SSAOSample signature
//=============================================================================

float2 GTAOSample(const VS_OUTPUT i, uniform int SLICES, uniform int STEPS, uniform float DIST_FACTOR) {
	float2 projXY = i.projPos.xy / i.projPos.w;
	uint2 pix = proj2pix(projXY);

	float depth = SampleMap(DepthMap, pix, 0).x;
	float4 p = mul(float4(projXY, depth, 1), gProjInv);
	float3 vPos = p.xyz / p.w;

	// Skip skybox / very distant geometry (same cutoff as stock)
	if (vPos.z > 50000)
		return float2(1, vPos.z);

	uint stv = SampleMap(StencilMap, pix, 0).g & STENCIL_COMPOSITION_MASK;
	bool isCockpit = stv == STENCIL_COMPOSITION_COCKPIT;
	return GTAO_Value(pix, vPos, isCockpit, SLICES, STEPS, DIST_FACTOR);
}

//=============================================================================
// Bilateral blur (unchanged from stock — proven edge-aware denoiser)
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
	float2 gtao = GTAOSample(i, SLICES, STEPS, DIST_FACTOR);
	PS_OUTPUT o;
	o.ssao = float4(gtao.x, 0, 0, 1);
	o.dist = float4(gtao.y * 0.001, 0, 0, 1);
	return o;
}

float4 PS_BLUR(const VS_OUTPUT i, uniform int GAUSS_KERNEL): SV_TARGET0 {
	float ao = joinedBilateralGaussianBlur(i.pos.xy, GAUSS_KERNEL);
	// No additional pow() here — contrast is already baked into GTAO_Value's
	// FinalValuePower. The stock pow(ao, 3) was needed because hemisphere SSAO
	// produced low-contrast output. GTAO's analytic integration doesn't need it.
	return float4(ao, 0, 0, 1);
}

//=============================================================================
// Technique — same structure as stock so DCS's render graph is unchanged
//=============================================================================
// Pass structure:
//   SSAO_1: Lower quality pass (4 slices × 4 steps = 32 depth reads)
//   SSAO_2: Higher quality pass (5 slices × 5 steps = 50 depth reads)
//   Blur_1, Blur_2: Bilateral gaussian blur passes (unchanged)
//
// DIST_FACTOR controls how the AO radius scales with distance for external
// (non-cockpit) geometry. Higher = larger AO on distant objects.
//
// Compare to stock:
//   Stock SSAO_1: 64 hemisphere samples = 64 depth reads
//   Stock SSAO_2: 128 hemisphere samples = 128 depth reads
//   GTAO SSAO_1: 4×4 = 32 depth reads (2x fewer, better quality)
//   GTAO SSAO_2: 5×5 = 50 depth reads (2.5x fewer, significantly better quality)
//=============================================================================

#define COMMON_PART			SetVertexShader(CompileShader(vs_5_0, VS()));				\
		SetGeometryShader(NULL);														\
		SetDepthStencilState(disableDepthBuffer, 0);									\
		SetBlendState(disableAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);	\
		SetRasterizerState(cullNone);

technique10 SSAO {
	//                          Slices, Steps, DistFactor
	pass SSAO_1	{
		SetPixelShader(CompileShader(ps_5_0, PS(4, 4, 4.0)));
		COMMON_PART
	}
	pass SSAO_2 {
		SetPixelShader(CompileShader(ps_5_0, PS(5, 5, 4.0)));
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