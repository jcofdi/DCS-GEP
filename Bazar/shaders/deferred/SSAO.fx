// GTAO-based Ambient Occlusion for DCS World
//
// Replaces the stock hemisphere SSAO with a horizon-based approach derived from:
//   "Practical Real-Time Strategies for Accurate Indirect Occlusion"
//   Jimenez et al., SIGGRAPH 2016
//   https://www.activision.com/cdn/research/Practical_Real_Time_Strategies_for_Accurate_Indirect_Occlusion_NEW%20VERSION_COLOR.pdf
//
// Reference implementation: Intel XeGTAO (MIT License)
//   https://github.com/GameTechDev/XeGTAO

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

// Thin occluder compensation (XeGTAO formulation)
static const float THIN_OCCLUDER_BETA = 0.00; //disabled for ground-truth testing
// static const float THIN_OCCLUDER_BETA = 0.02; 


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

float3 calcGeoNormal(uint2 px, float3 center) {
    float3 pL = reconstructViewPos(px - uint2(1, 0));
    float3 pR = reconstructViewPos(px + uint2(1, 0));
    float3 pU = reconstructViewPos(px - uint2(0, 1));
    float3 pD = reconstructViewPos(px + uint2(0, 1));
    float3 ddx = abs(pR.z - center.z) < abs(pL.z - center.z) ? (pR - center) : (center - pL);
    float3 ddy = abs(pD.z - center.z) < abs(pU.z - center.z) ? (pD - center) : (center - pU);
    float3 n = normalize(cross(ddx, ddy));
    return dot(n, center) > 0 ? -n : n;
}

// GTAO Core - Horizon-Based Ambient Occlusion

float4 GTAO_Value(uint2 pix, float3 vPos, uniform bool isCockpit, uniform int SLICES, uniform int STEPS, uniform float DIST_FACTOR) {
	
	// Reconstruct geometric normal from depth buffer neighbors.
	float3 vNormal = calcGeoNormal(pix, vPos);
	float centerDepth = vPos.z;
	[unroll]
	for (uint j = 1; j < 4; ++j) {
		static const int2 offs[4] = { {0,0}, {0,1}, {1,1}, {1,0} };
		uint2 npix = pix + offs[j];
		float3 nPos = reconstructViewPos(npix);
		float depthWeight = abs(nPos.z - centerDepth) < (centerDepth * 0.05) ? 0.9 : 0.0;
		vNormal += calcGeoNormal(npix, nPos) * depthWeight;
	}
	vNormal = normalize(vNormal);
	
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
		return float4(1.0, vPos.z, 0, 0);


	// V4: Resolution-independent, distance-adaptive screen radius cap.
	float resScale = viewport.z / 2560.0;
	float maxScreenRadius = lerp(128.0, 384.0, exp(-vPos.z * 0.03)) * resScale;
	screenRadius = min(screenRadius, maxScreenRadius);

	// Pixel-too-close threshold: don't sample the center pixel itself
	float minStep = 1.3 / screenRadius;

	// Per-pixel noise for slice rotation and step jitter.
	float2 pixelPos = float2(pix);
	float noiseSlice  = ditherBlueNoiseComputed(uint2(pixelPos));
	float noiseSample = ditherBlueNoiseComputed(uint2(pixelPos) + uint2(37, 17));

	// Accumulate visibility across all slices
	float visibility = 0;

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
	}

	visibility /= float(SLICES);

visibility = max(0.08, visibility);

return float4(visibility, vPos.z, 0, 0);
}

// Sampling entry point

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

// Bilateral blur (unchanged from stock -- proven edge-aware denoiser)

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

// Pixel shader outputs

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

// Technique -- same structure as stock so DCS's render graph is unchanged

#define COMMON_PART			SetVertexShader(CompileShader(vs_5_0, VS()));				\
		SetGeometryShader(NULL);														\
		SetDepthStencilState(disableDepthBuffer, 0);									\
		SetBlendState(disableAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);	\
		SetRasterizerState(cullNone);

technique10 SSAO {
	//                          Slices, Steps, DistFactor
	pass SSAO_1	{
		SetPixelShader(CompileShader(ps_5_0, PS(16, 32, 3.0)));
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
