#ifndef WATERSEA_HLSL
#define WATERSEA_HLSL

#include "enlight/waterCommon.hlsl"
#include "noise/noise2D.hlsl"

Texture2DArray g_WaveTexture;
Texture2D g_MaskTexture;

Texture2D foamTexture;

static const float3 LUM = { 0.2125f, 0.7154f, 0.0721f };
static const float  HALF= 127.0 / 255.0;

struct WaterLocalParams {
	float4 wave, flow;
	float2 mask;
};

WaterLocalParams getWaterLocalParams(float3 wpos) {

	WaterLocalParams p;

//	gLocal must be applied on rendering of mask and wave targets
	
	float4 muv = mul(float4(wpos, 1.0), g_MaskMatrix); // g_MaskMatrix and g_WaveMatrix is adjusted matrix gViewProj
	muv.xy /= muv.w;
	p.mask = g_MaskTexture.SampleLevel(gTrilinearClampSampler, muv.xy, 0).xy;

	float4 wuv = mul(float4(wpos, 1.0), g_WaveMatrix);
	wuv.xy /= wuv.w;

	p.wave = g_WaveTexture.SampleLevel(gTrilinearClampSampler, float3(wuv.xy, 0), 0);
	p.flow = g_WaveTexture.SampleLevel(gTrilinearClampSampler, float3(wuv.xy, 1), 0);

	return p;
}

float3 decodeNormal(float4 wave) {
	wave.xy = (wave.xy - HALF) * 2; // xz of normal
	float ny = sqrt(1 - wave.x * wave.x - wave.y * wave.y);
	return float3(wave.x, ny, wave.y);
}

float3 decodeDisplace(float4 wave) {
	//	float3 n = decodeNormal(wave);
	//	return	n * (wave.z - 0.5) * 10;
	return float3(0, (wave.z - 0.5) * 10, 0);
}

float2 decodeFlow(float4 flow) {
	return (flow.yz - HALF) * 50;
}

float noiseCoast(float2 wposXZ) {
	return snoise((wposXZ + gOrigin.xz) * 0.01) * 0.2;
}

float3 addNormal(float3 normal1, float3 normal2) {
	float3x3 mat;
	mat[1] = normal1;
	mat[2] = normalize(cross(float3(1.0, 0.0, 0.0), mat[1]));
	mat[0] = cross(mat[1], mat[2]);
	return mul(normal2, mat);
}

float2 NDCpos2uv(float4 NDCpos) {
	return float2(NDCpos.x, -NDCpos.y) / NDCpos.w * 0.5 + 0.5;
}

struct FlowParams {
	float2 offset0, offset1;
	float lerpFlow;
};

FlowParams calcFlowParams(float2 uv, float2 flow, float pulse, uniform bool useFlowNoise = true) {
	FlowParams o;

	float t = gModelTime * pulse;
	if (useFlowNoise)
		t += snoise(uv) * 0.5;

	float phase0 = frac(t);
	float phase1 = frac(t + 0.5);
	o.offset0 = flow * phase0;
	o.offset1 = flow * phase1 + 0.5;
#if 1
	o.lerpFlow = 2 * abs(phase0 - 0.5);						// triangle pulse
#else
	o.lerpFlow = cos(t * (2 * 3.14159265359)) * 0.5 + 0.5;	// sin pulse
#endif
	return o;
}

float4 combineWaterNormalFlow(float2 wpos2, float texScale, float2 flow, uniform bool calcNormal, uniform bool useFoamFFT) {
	float2 uv = (wpos2 * g_TexScale.x + g_TexOffset) * texScale;

	FlowParams fp = calcFlowParams(uv, flow * (g_TexScale.x * texScale), 0.25);
	StochasticUV s = stochasicUV(uv);

	if (calcNormal) {
		float2 _ddx = ddx(uv);
		float2 _ddy = ddy(uv);
		float4 n0 = stochasticSampleGradArr(g_NormalTexture, 0, gAnisotropicWrapSampler, s, _ddx, _ddy, fp.offset0);
		float4 n1 = stochasticSampleGradArr(g_NormalTexture, 0, gAnisotropicWrapSampler, s, _ddx, _ddy, fp.offset1);
		float4 n = lerp(n0, n1, fp.lerpFlow);
		float f = 0;
		if (useFoamFFT)
			f = n.w - 0.025;
		return float4(n.xyz, f);
	}
	else {
		float4 r0 = stochasticSampleLevelArr(g_NormalTexture, 1, gTrilinearWrapSampler, s, 0, fp.offset0);
		float4 r1 = stochasticSampleLevelArr(g_NormalTexture, 1, gTrilinearWrapSampler, s, 0, fp.offset1);
		float4 r = lerp(r0, r1, fp.lerpFlow);

		float f = 0.5 / texScale;	// displace multiplier
		r.xyz *= f * g_TexScale.y;
		return r;
	}
}

// constructing the displacement amount and normal for water surface geometry
float4 CombineWaterCommon(float2 wpos2, float2 flow, float tilingMask, uniform bool useTilingMask, uniform bool calcNormal, uniform bool useFoamFFT) {

	float4 result;

	if (useTilingMask) {
		float3 tiling = 1 + tilingMask * 3;
		int3 e = log2(tiling);
		int3 scale = (1 << e);

#if USE_FLOW_MAP
		float4 r0 = combineWaterNormalFlow(wpos2, scale[2], flow, calcNormal, useFoamFFT ? scale[0] & 1 : false);
		float4 r1 = combineWaterNormalFlow(wpos2, 2 * scale[1], flow, calcNormal, 0);
#else
		float4 r0 = combineWaterNormal(wpos2, scale[2], calcNormal, useFoamFFT ? scale[0] & 1 : false);
		float4 r1 = combineWaterNormal(wpos2, 2 * scale[1], calcNormal, 0);
#endif
		float factor = (tiling[0] - scale[0]) / float(scale[0]);
		result = lerp(r0, r1, factor);
	}
	else {
#if USE_FLOW_MAP
		result = combineWaterNormalFlow(wpos2, 1, flow, calcNormal, useFoamFFT);
#else
		result = combineWaterNormal(wpos2, 1, calcNormal, useFoamFFT);
#endif
	}
	return result;
}


///////////////////////// interface functions

float3 calculateWaterDisplace(float3 wpos, WaterLocalParams localParams, uniform bool useTilingMask) {

    float2 wpos2 = wpos.xz;

	float3 water_displace = CombineWaterCommon(wpos2, decodeFlow(localParams.flow), localParams.flow.x, useTilingMask, false, false).xyz;
	// result.xy - normal.xz
	// result.z	 - displace.y

	float3 wave_displace = decodeDisplace(localParams.wave);

	water_displace += wave_displace;

#if GEOTERRAIN	// disable displace fade and noise
	return water_displace;
#endif

#if USE_NOISE_COAST
	wave_displace += noiseCoast(wpos2);
#endif

	bool underwater = (g_Level - gOrigin.y) > gCameraPos.y;
	float deepMask = max(localParams.mask.y, underwater) * (1 - localParams.mask.x);
	float deep = (deepMask - HALF) * 20.0;

	deep += wave_displace.y;
	water_displace.y = deep > 0 ? max(water_displace.y, -deep) : 0;

	float sm = abs(sigmoid(deep, 0.1));	// abs of sigmoid
	water_displace.y *= sm;

	float d = distance(wpos, gCameraPos);
	//	water_displace *= exp(-d*0.0005);
	water_displace *= max(0, 0.5 - d / (d + 2000)) * 2;

	water_displace.xz *= saturate(d - 4);
	return water_displace;
}

float3 calculateWaterDisplace(float3 wpos, uniform bool useTilingMask) {
	WaterLocalParams localParams = getWaterLocalParams(wpos);
	return calculateWaterDisplace(wpos, localParams, useTilingMask);
}

GBufferWater buildGBuffer(float3 wpos, float4 NDCpos, uniform bool useFoamFFT, uniform bool useTilingMask, uniform bool useWaveMap) {

	float2 uv = NDCpos2uv(NDCpos);

	WaterLocalParams localParams = getWaterLocalParams(wpos);

	float2 wpos2 = mul(float4(wpos, 1), gLocal).xz;

#if USE_PS_MASK_DISCARD
	if (useWaveMap) {
		if (!any(localParams.wave.xyz))
			discard;
	}
#endif

	float2 flow = decodeFlow(localParams.flow);
	float4 result = CombineWaterCommon(wpos2, flow, localParams.flow.x, useTilingMask, true, useFoamFFT);
	// result.xy - normal.xz
	// result.z	 - displace.y
	// result.w  - foam

	float wLevel = result.z;
	float3 normal = restoreNormal(result.xy);

	float foam = 0;
	// [MOD] Increased foam multiplier from 1.5 to 2.5.
	if (useFoamFFT) {
#if 1
    foam += result.w * 2.5;
#else
		float2 p = (wpos.xz + gOrigin.xz) / 128;
		float n = snoise(float3(p, g_Time * 0.05)) + 1;
		foam += saturate(result.w * n * 1.5);
#endif
	}

	if (useWaveMap) {
		float3 n = decodeNormal(localParams.wave);
		normal = addNormal(normal, n);
		foam += localParams.wave.w;
		float displaceY = n.y * ((localParams.wave.z - 0.5) * 10);
		wLevel = saturate(((wLevel - 0.5) * 8 + displaceY) * 0.125 + 0.5);	// repack wLevel	// WTF?
	}

	// sample detailed foam texture
	{
		const float foamScale = 0.04;
		float2 uv = (wpos2 + g_TexOffset / g_TexScale.x) * foamScale;

#if USE_FLOW_MAP
		FlowParams fp = calcFlowParams(uv, flow * foamScale, 0.25, false);
		StochasticUV s = stochasicUV(uv);
		float2 _ddx = ddx(uv);
		float2 _ddy = ddy(uv);
		float f0 = dot(stochasticSampleGrad(foamTexture, gAnisotropicWrapSampler, s, _ddx, _ddy, fp.offset0).xyz, LUM);
		float f1 = dot(stochasticSampleGrad(foamTexture, gAnisotropicWrapSampler, s, _ddx, _ddy, fp.offset1).xyz, LUM);
		float f = lerp(f0, f1, fp.lerpFlow);
#else
		float f = dot(stochasticSample(foamTexture, gAnisotropicWrapSampler, uv).xyz, LUM);
#endif
//		foam *= pow(f, 2 - foam) * 2;
		foam = f * foam;
	}

	float water_depth = calcWaterDepth(wpos, uv);
	float deepFactor = calcWaterDeepFactor(water_depth, 0);
	float alpha = 1 - localParams.mask.x;
	alpha *= alpha;

	normal = mul(normal, (float3x3)gLocalInv); // TODO: GEOTERRAIN spherify normals

	return BuildGBufferWater(normal, wLevel, foam, deepFactor, NDCpos, 0, alpha);
}

#endif
