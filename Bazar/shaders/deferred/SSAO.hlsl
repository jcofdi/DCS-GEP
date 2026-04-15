#ifndef SSAO_HLSL
#define SSAO_HLSL

Texture2D<float> SSAOMap;
Texture2D<float4> SSAODist;
uint2 SSAOSize;

// Octahedral unit vector decoding (Cigolle et al. 2014)
// Inverse of octEncode in SSAO.fx. Maps 2 floats in [-1, 1] back
// to a unit-length 3D direction with no singularities.
float3 octDecode(float2 o) {
	float3 n = float3(o, 1.0 - abs(o.x) - abs(o.y));
	if (n.z < 0.0) {
		float2 s = n.xy >= 0.0 ? 1.0 : -1.0;
		n.xy = (1.0 - abs(n.yx)) * s;
	}
	return normalize(n);
}

float2 sampleValue(uint2 uv) {
	float ssao = SSAOMap.Load(uint3(uv, 0)).x;
	float dist = SSAODist.Load(uint3(uv, 0)).x;
	return float2(ssao, dist);
}

float gaussian(float x, float s) {
	return exp(-(x * x) / (2 * s * s));
}

float joinedBilateralUpsample(float2 uv, float dist) {
	dist *= 0.001;

	float2 pixel = uv * SSAOSize + 0.5;
	float2 f = frac(pixel);
	uint2 px = floor(pixel) - 0.5;
	
	float2 v00 = sampleValue(px + uint2(0, 0));
	float2 v01 = sampleValue(px + uint2(0, 1));
	float2 v10 = sampleValue(px + uint2(1, 0));
	float2 v11 = sampleValue(px + uint2(1, 1));

	const float sigma = 1;
	const float dw = 100 / dist;	// distance weight factor

	float2 f1 = 1 - f;
	float w00 = gaussian((dist - v00.y) * dw, sigma) * f1.x * f1.y;
	float w01 = gaussian((dist - v01.y) * dw, sigma) * f1.x * f.y;
	float w10 = gaussian((dist - v10.y) * dw, sigma) * f.x  * f1.y;
	float w11 = gaussian((dist - v11.y) * dw, sigma) * f.x  * f.y;

	w00 += 1e-12;
	return (v00.x * w00 + v01.x * w01 + v10.x * w10 + v11.x * w11) / (w00 + w01 + w10 + w11);
}


float getSSAO(float2 uv, float viewPosZ) {
	return joinedBilateralUpsample(uv, viewPosZ);
//	return SSAOMap.SampleLevel(gTrilinearClampSampler, uv, 0).x;
}

// Fetch bent normal from SSAO dist buffer (.yz channels).
// The bent normal is stored at half resolution without bilateral blur
// (it's a direction, not a scalar). Nearest-neighbor fetch from the
// half-res buffer is appropriate since linear interpolation of unit
// vectors across depth discontinuities would produce incorrect
// directions.
float3 getBentNormal(float2 uv) {
	float2 pixel = uv * SSAOSize + 0.5;
	uint2 px = floor(pixel) - 0.5;
	float2 bentOct = SSAODist.Load(uint3(px, 0)).yz;
	return octDecode(bentOct);
}


#endif
