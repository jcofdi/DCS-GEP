#if GEOTERRAIN
	#define SPHERIFY 1	
#else
	#define SPHERIFY 0
#endif

#define USE_FLOW_MAP 0
#define USE_CHECKER 1

#define USE_MASK 1
#define USE_FFT_FOAM 1
#define USE_SHALLOW_FOAM 0
#define USE_SURF 0
#define USE_SURF_FOAM 0
#define USE_BOTTOM_SHADOW 1

#define USE_NOISE_COAST 1
#define USE_PS_MASK_DISCARD 1	// tunnels below sea level, for example in Arabian Gulf -camera -102.848820 0.032199 -87.677985 -cameradir 0.818830 -0.434966 0.374597

#include "enlight/waterSea.hlsl"

#define GEP_TK_GRADIENTS 0	// ShadeSolid inlined inside SSR march; gradients illegal
#include "deferred/shading.hlsl"
#include "noise/worley.hlsl"

Texture2D g_UnderwaterMask;

#ifdef MSAA
	Texture2DMS<float, MSAA> g_MainDepthTexture;	// need to build river mask -> waterMask.g
	Texture2DMS<uint2, MSAA> g_StencilTexture;
	float LoadDepth(uint2 uv) { return g_MainDepthTexture.Load(uv, 0).r; }
	uint  LoadStencil(uint2 uv) { return g_StencilTexture.Load(uv, 0).g; }
#else
	Texture2D<float> g_MainDepthTexture;
	Texture2D<uint2> g_StencilTexture;
	float LoadDepth(uint2 uv) { return g_MainDepthTexture.Load(uint3(uv, 0)).r; }
	uint  LoadStencil(uint2 uv) { return g_StencilTexture.Load(uint3(uv, 0)).g; }
#endif

struct DUMMY {
	float Dummmy : DUMMY;
};

struct VS_OUTPUT {
    float2 pos   : POSITION;
};

struct PatchData {
	float2 pos   : POSITION;

	float Edges[4]  : SV_TessFactor;
    float Inside[2]	: SV_InsideTessFactor;
};

struct DS_OUTPUT {
    float4 position:		SV_POSITION;
    float4 projPos:			TEXCOORD0;
    float3 positionWS:		TEXCOORD1;
};

static const float2 quad[4] = {
	float2(-1, -1), float2(1, -1),
	float2(-1, 1),	float2(1, 1),
};

VS_OUTPUT VS(float2 pos: POSITION) {
	VS_OUTPUT o;
	o.pos = pos*g_Scale.x;
	return o;
}

bool isWater(uint materialID) {
	return (materialID & STENCIL_COMPOSITION_MASK) == STENCIL_COMPOSITION_WATER;
}

float3 spherify(float3 wpos) {
	float3 lcp = mul(float4(gCameraPos, 1), gLocal).xyz;
	float2 d = wpos.xz - lcp.xz;
	float dist2 = dot(d, d) * 1e-6;	// gEarthRadius in km
	if (dist2 > gEarthRadius * gEarthRadius) {
		wpos.xz = lcp.xz + d * (gEarthRadius / sqrt(dist2));
		wpos.y -= gEarthRadius * 1e3;
		return wpos;
	}
	return float3(wpos.x, wpos.y - (gEarthRadius - sqrt(gEarthRadius * gEarthRadius - dist2)) * 1e3, wpos.z);
}

[domain("quad")]
[partitioning("fractional_odd")]
[outputtopology("triangle_cw")]
[outputcontrolpoints(1)]
[patchconstantfunc("PatchConstantHS")]
DUMMY HS( InputPatch<VS_OUTPUT, 1> inputPatch, uint cpid : SV_OutputControlPointID) {  return (DUMMY)0; }

[domain("quad")]
DS_OUTPUT DS(PatchData input, float2 uv : SV_DomainLocation, OutputPatch<DUMMY, 1> inputPatch, uniform bool useTilingMask)
{
    DS_OUTPUT output;
// calculating water surface geometry position and normal
	float2 wpos2 = input.pos + uv * g_TileSize - g_Offset;
	float3 wpos = float3(wpos2.x, g_Level, wpos2.y);

#if SPHERIFY	
	wpos = spherify(wpos);
#endif

// common for custom GEORERRAIN surface
	wpos = mul(float4(wpos, 1), gLocalInv).xyz;
	wpos += calculateWaterDisplace(wpos, useTilingMask); // TODO for GEORERRAIN, may need to be corrected Wave & Mask render space and move it above

// writing output params
	output.positionWS = wpos;
	output.position = output.projPos = mul(float4(wpos, 1.0), gViewProj);
    return output;
}

float calcFoamTexture(float2 pos, float vol, uniform uint samples) {
	vol = saturate(vol);
	vol *= 0.6;
	float result = 0;
	float t = g_Time * 0.2;
	[unroll]
	for (uint i = 0; i < samples; ++i) {
		uint m = 1 << i;
		float s = snoise(float3(pos, t)*m);
//		result += vol - abs(s) * 1.0 / (m*0.5 + 0.5);
		result += vol - abs(s) * 1.0 / m;
	}
	return saturate(result);
}

GBufferWater PS(DS_OUTPUT input, bool isFrontFace: SV_IsFrontFace, uniform bool useFoamFFT, uniform bool useTilingMask, uniform bool useWaveMap) {

	float2 uv = NDCpos2uv(input.projPos);
	float4 underwaterMask = g_UnderwaterMask.SampleLevel(SamplerLinearClamp, uv, 0);
	if ((underwaterMask.x > 0.5) == isFrontFace)
		discard;

	return buildGBuffer(input.positionWS, input.projPos, useFoamFFT, useTilingMask, useWaveMap);
}


static const float2 tileTessOffs[4] = {
	float2(0, 0.5), float2(0.5, 0),
	float2(1, 0.5),	float2(0.5, 1),
};

float CalculateTessellationFactor(float distance) {
	return max(1, 1000 * g_TileSize / pow(distance, 1.5));
}

PatchData PatchConstantHS(InputPatch<VS_OUTPUT, 1> inputPatch) {

	PatchData output;

	float inside_tessellation_factor = 0;
	bool in_frustum = true;

	output.pos = inputPatch[0].pos;

#if 0
	float3 sum = 0;
	[unroll]
	for (uint i = 0; i < 4; ++i) {
		float2 pos = output.pos + (g_TileSize*(quad[i] + 1) * 0.5);
		float4 p = mul(float4(float3(pos.x, g_Level, pos.y) - g_Offset, 1), gViewProj);
#if USE_CLIP_TEST
		p.xy *= 1.5;
#endif
		p.xyz /= p.w;
		sum += float3(clamp(p.xy*0.8, -1, 1), clamp(p.z * 2 - 1, -1, 1));		// culling -1<XY<1, 0<Z<1, 0.8 - margin for possible displace vertex
	}

	//	in_frustum = abs(sum.x) < 4 && abs(sum.y) < 4 && abs(sum.z) < 4;
	in_frustum = !any(step(4, abs(sum)));
	//	in_frustum = !any(step(3, abs(sum.xy)));	// test

#endif

	if (in_frustum) {
		[unroll]
		for (uint i = 0; i < 4; ++i) {
			float2 wpos2 = output.pos - g_Offset + g_TileSize * tileTessOffs[i];

			float3 wpos = float3(wpos2.x, g_Level, wpos2.y);
			wpos = mul(float4(wpos, 1), gLocalInv).xyz;

			float distance_to_camera = length(gCameraPos.xyz - wpos);
			float tesselation_factor = CalculateTessellationFactor(distance_to_camera);
			output.Edges[i] = tesselation_factor;
			inside_tessellation_factor += tesselation_factor;
		}
		output.Inside[0] = output.Inside[1] = inside_tessellation_factor * 0.25;
	} else {
		output.Edges[0] = output.Edges[1] = output.Edges[2] = output.Edges[3] = -1;
		output.Inside[0] = output.Inside[1] = -1;
	}

	return output;
}

///////////////////////////////////////////////////////////////////////////// LOW

PatchData PatchConstantHS_LOW( InputPatch<VS_OUTPUT, 1> inputPatch ) {    
    PatchData output;
	output.pos = inputPatch[0].pos;
	output.Edges[0] = output.Edges[1] = output.Edges[2] = output.Edges[3] = output.Inside[0] = output.Inside[1] = 1;
    return output;
}

[domain("quad")]
[partitioning("fractional_odd")]
[outputtopology("triangle_cw")]
[outputcontrolpoints(1)]
[patchconstantfunc("PatchConstantHS_LOW")]
DUMMY HS_LOW( InputPatch<VS_OUTPUT, 1> inputPatch, uint cpid : SV_OutputControlPointID ) {  return (DUMMY)0; }

DS_OUTPUT DS_VS_LOW(float2 pos) {
    DS_OUTPUT output;

	// calculating water surface geometry position and normal
	float2 wpos2 = pos - g_Offset;

	float3 wpos = float3(wpos2.x, g_Level, wpos2.y);
#if SPHERIFY	
	wpos = spherify(wpos);
#endif
	wpos = mul(float4(wpos, 1), gLocalInv).xyz;

	output.positionWS = wpos;
	output.position = output.projPos = mul(float4(wpos, 1.0), gViewProj);

	return output;
}

[domain("quad")]
DS_OUTPUT DS_LOW(PatchData input, float2 uv : SV_DomainLocation, OutputPatch<DUMMY, 1> inputPatch ) {
	return DS_VS_LOW(input.pos + uv * g_TileSize);
}

DS_OUTPUT VS_FLAT(float2 pos: POSITION) {
	return DS_VS_LOW(pos*g_Scale.x);
}

DS_OUTPUT VS_RADAR(float2 pos: POSITION) {
	return DS_VS_LOW(pos*10);
}

float4 PS_DRAFT(DS_OUTPUT i) : SV_TARGET0 {
	float3 normal = restoreNormal( combineWaterNormal(i.positionWS.xz, 1, true, false).xy );
	float3 color = waterColorDraft(normal, i.positionWS);
	color = applyAtmosphereLinear(gCameraPos.xyz, i.positionWS, i.projPos, color);
	return float4(color, 1);
}

float4 PS_FLIR(DS_OUTPUT i) : SV_TARGET0 {
	float3 normal = restoreNormal(combineWaterNormal(i.positionWS.xz, 1, true, false).xy);
	return float4(waterColorFLIR(normal, i.positionWS).xxx, 1);
}

float4 PS_RADAR(DS_OUTPUT i) : SV_TARGET0 {
	return float4(0,0,0,1);
}

///////////////////////// waves

struct VS_OUTPUT_SS {
	float4 pos:			SV_POSITION;
	float2 projPos:		TEXCOORD0;
};

VS_OUTPUT_SS VS_SS(uint vid: SV_VertexID) {
	VS_OUTPUT_SS o;
	o.pos = float4(quad[vid], 1, 1);
	o.projPos = o.pos.xy;
	return o;
}

struct PS_OUTPUT {
	float4 sv_target0 : SV_TARGET0;
	float4 sv_target1 : SV_TARGET1;
};

#define PIx2 6.283185307179586476925286766559

bool isModel(uint materialID) {
	materialID &= STENCIL_COMPOSITION_MASK;
	return (materialID == STENCIL_COMPOSITION_MODEL) || (materialID == STENCIL_COMPOSITION_COCKPIT);
}

bool isSurface(uint materialID) {
	materialID &= STENCIL_COMPOSITION_MASK;
	return materialID == STENCIL_COMPOSITION_SURFACE;
}

float4 buildMask(float2 uv, float2 projPos) {
	float depth = LoadDepth(uv);	// load depth from current depth, not copy!
	float4 d = mul(float4(projPos.xy, depth, 1), gViewProjInv);
	uint matID = LoadStencil(uv);

	float2 mask = riverWaterMask(d.y / d.w);
	return float4(0, isWater(matID)*mask.x, max(max(mask.y, isModel(matID)), step(depth, 0)), 1);
}

float3 waveDeep(float2 projPos) {
	float depth = LoadDepthBuffer(transformColorBuffer(projPos));
	float4 d = mul(float4(projPos.xy, depth, 1), gViewProjInv);
	return d.xyz / d.w;
}

float3 surfWave(float3 x) {
	x = max(x, 0);
	return max(x*exp(-x) - 0.025, 0);
//	return max(sin(x*0.25)*exp(-x)*5, 0);
//	return max(sin(x) / (abs(x) + 0.2), 0);
}

float noiseWave(float3 pos) {
	return 0.25 - worley((pos.xz + gOrigin.xz)*0.01, 2);
}

float4 waveFunc(float3 water_depth, float windFactor) {
	float p = 1 + 5*(windFactor + 0.3);

	float t = g_Time * 0.33;
	float ts = sin(t);
	float a = max(0, sin(t + 1) + 0.8) *(1.0 / 1.8);

	float3 x = water_depth * 5 + p * (ts - 1);
	float3 wave = surfWave(x);

	float fw = max(1, 6 - windFactor * 10);
	float fa = 7 + windFactor * 3;
	float foam = surfWave(x*fw).x*a*fa;

	wave.xyz *= max(0, windFactor + 0.2) * 10 * a;
	return float4(wave, foam);
}

float waterDeepByMask(float2 projPosXY) {
	uint2 tuv = transformColorBuffer(projPosXY);
	float depth = LoadDepthBuffer(tuv);
	float4 wpos = mul(float4(projPosXY, depth, 1), gViewProjInv);
	float4 muv = mul(wpos, g_MaskMatrix);
	float4 mask = g_MaskTexture.SampleLevel(SamplerLinearClamp, muv.xy/muv.w, 0);
	return (mask.z - HALF) * 20.0;
}

float limitFactor(float x, float lim, float slope) {
	float f = -(x - lim) * slope;
	return max(0, f / (1 + abs(f)));
}

float4 buildWave(float3 p0, float3 p1, float3 waterDeep, float waterDeepFoam, uniform bool useFoam) {

#if USE_SURF
	float noise = noiseWave(p0);
	waterDeep += noise;

	float slopeFactor = max(abs(waterDeep.y - waterDeep.x), abs(waterDeep.z - waterDeep.x));
	float fc = limitFactor(slopeFactor, 0.025, 20);		// fade steep bank
	fc *= step(1e-9, slopeFactor);						// fade on absolutely flat shelf like in StraitOfDover, produce artifact like fingerprint on surf foam, only in PS_WAVE

	float windFactor = saturate((g_WindForce - 6.4)*(1.0 / (22.0 - 6.4))); // normalized windfactor

	float4 wave = waveFunc(waterDeep, windFactor)*fc;

	float2 bnormal = p1.xz - p0.xz;
	float3 w1 = float3(-bnormal.y, wave[2] - wave[0], bnormal.x);
	float3 w2 = float3(bnormal.x, wave[1] - wave[0], bnormal.y);
	float3 wnorm = normalize(cross(w1, w2));			// normal of wave

	float dist = distance(p0, gCameraPos);

	float foam = 0;

	if (useFoam) {
#if USE_SHALLOW_FOAM
#if USE_NOISE_COAST
		waterDeepFoam += max(0, noiseCoast(p0.xz));
#endif
		//	foam = max(foam, max(0, 1 - waterDeepFoam / (1 + windFactor))*sigmoid(windFactor, 0.1));
		foam = max(foam, max(0, (1 - waterDeepFoam) * exp(-dist * 0.001)));
#endif

#if USE_SURF_FOAM
		float fn = saturate((noise + 0.25) * 5.0);
		foam = max(foam, wave.w*fn);
#endif
	}

	float fade = 1 - exp(-dist * 0.0001);
	return lerp(float4(wnorm.xz*0.5 + HALF, wave[0] * 0.5 + HALF, foam), float4(HALF, HALF, HALF, 0), fade);
#else
	return float4(HALF, HALF, HALF, 0);
#endif
}

float3 _projOnWaterLevel(float2 projPosXY) {
	float4 d = mul(float4(projPosXY, 0, 1), gViewProjInv);
	float3 dir = d.xyz / d.w - gCameraPos;
	return gCameraPos + dir * ( ((g_Level - gOrigin.y) - gCameraPos.y) / dir.y );
}

float4 PS_WAVE(VS_OUTPUT_SS i): SV_TARGET0 {

	float3 p0 = _projOnWaterLevel(i.projPos.xy);
	float3 p1 = _projOnWaterLevel(i.projPos.xy - float2(0, 2.0 / g_ColorBufferSize.y));

	float3 waterDeep = float3(waterDeepByMask(i.projPos.xy),
							  waterDeepByMask(i.projPos.xy + float2(2.0 / g_ColorBufferSize.x, 0)),
							  waterDeepByMask(i.projPos.xy - float2(0, 2.0 / g_ColorBufferSize.y)) );

	return buildWave(p0, p1, waterDeep, waterDeep.x, true);
}

PS_OUTPUT PS_WAVE_MASK(VS_OUTPUT_SS i) {

	float4 d = mul(float4(i.projPos.xy, 1, 1), gViewProjInv);
	float3 dir = d.xyz / d.w - gCameraPos;
	dir = normalize(dir);

	uint2 tuv = transformColorBuffer(i.projPos);
	float depth = LoadDepthBuffer(tuv);

	d = mul(float4(i.projPos.xy, depth, 1), gProjInv);

	float dist = d.z / d.w;
	d = mul(float4(i.projPos.xy, depth, 1), gViewProjInv);

	float waterDeep0 = -(d.y / d.w + gOrigin.y - g_Level);

	float3 p0 = d.xyz / d.w;

	float3 water1 = waveDeep(i.projPos.xy + float2(2.0 / g_ColorBufferSize.x, 0));
	float3 water2 = waveDeep(i.projPos.xy - float2(0, 2.0 / g_ColorBufferSize.y));

	float waterDeep1 = -(water1.y + gOrigin.y - g_Level);
	float waterDeep2 = -(water2.y + gOrigin.y - g_Level);

	PS_OUTPUT o;

	float modelDeep = isModel(LoadStencil(tuv)) * 10;

	o.sv_target0 = buildWave(p0, water2, max(float3(waterDeep0, waterDeep1, waterDeep2), modelDeep), max(waterDeep0, modelDeep), false);
	o.sv_target1 = buildMask(tuv, i.projPos);

	return o;
}

float3 DecodeGBufferRefraction(uint2 uv) {
	const uint msaaSample = 0;
	float4 aorms;
	float3 normal, emissive, diffuse;

	DecodeGBuffer(SampleGBuffer(uv, msaaSample), uv, msaaSample, diffuse, normal, aorms, emissive);
	return diffuse;
}

PS_OUTPUT PS_REFRACTION(VS_OUTPUT_SS i, uniform bool useMask)  {

	PS_OUTPUT o;

	uint2 tuv = transformColorBuffer(i.projPos);

	float depth = LoadDepthBuffer(tuv);

	float4 wpos = mul(float4(i.projPos.xy, depth, 1), gViewProjInv);
	wpos.xyz /= wpos.w;
	float3 v = wpos.xyz - gCameraPos;

	if (depth == 0) {
		float3 env = SampleEnvironmentMapDetailed(v, 0).xyz;
		o.sv_target0 = float4(env, 1);
		o.sv_target1 = float4(1, 0, 0, 1);
		return o;
	}

	float3 color = DecodeGBufferRefraction(tuv);
	float3 normal = LoadNormal(tuv);
	float NoL = max(0, dot(normal, gSunDir));

	float dist = length(v);
	float waterDepth = g_Level - (wpos.y + gOrigin.y);	// thickness of water

#if  USE_BOTTOM_SHADOW	// project shadow to bottom
	float2 cloudsShadowAO = SampleShadowClouds(wpos.xyz);
	float bottomShadow = min(cloudsShadowAO.x, SampleShadowCascade(wpos.xyz, depth, gSunDir.xyz*NoL, true, true, false, 1));
	bottomShadow = lerp(1, bottomShadow, calcWaterDeepFactor(waterDepth*0.2, 0));
	NoL = min(NoL, bottomShadow);
#endif

	float isRiver = false;
	if (useMask) {
		//	float waterDeep = waterDeepByMask(i.projPos.xy);
		float4 muv = mul(float4(wpos.xyz, 1), g_MaskMatrix);
		float4 mask = g_MaskTexture.SampleLevel(SamplerLinearClamp, muv.xy/muv.w, 0);
		float waterDeep = (mask.z - HALF) * 20.0;

		uint matID = LoadStencil(tuv);
		isRiver = isSurface(matID) * mask.y;

		waterDepth = lerp(waterDeep, waterDepth, exp(-dist / 2000));	// fix blinking at far, lack of accuracy of waterDepth
	} else {
		waterDepth = lerp(50.0, waterDepth, exp(-dist / 10000));	// fix blinking at far, lack of accuracy of waterDepth
	}

	float deepFactor = calcWaterDeepFactor(waterDepth, 0);
	NoL = lerp(0, NoL, deepFactor);

	float2 uv = float2(i.projPos.x, -i.projPos.y)*0.5 + 0.5;
	float4 uw = g_UnderwaterMask.SampleLevel(ClampLinearSampler, uv, 0);

	float wy = (wpos.y + gOrigin.y - g_Level - 1) * (1 - uw.x);
	float alpha = max(isRiver, max(exp(-max(wy, 0)), 1 + 1.0 / 255 - exp(-dist / 10000))) * g_UseRefractionFilter;	// prepare for filtering

	o.sv_target0 = float4(color, alpha);
	o.sv_target1 = float4(NoL,0,0,alpha);
	return o;
}

Texture2D sourceTex;
Texture2DArray sourceTexArray;
uint2 dims;

static const float2 filterOffset[] = {
	float2(0, 1),  float2( 1, 0),
	float2(0,-1),  float2(-1, 0)
};

float4 psFilterRefraction(VS_OUTPUT_SS input, uniform uint dist): SV_TARGET0 {
    float2 uv = float2(input.projPos.x, -input.projPos.y) * 0.5 + 0.5;
	float4 acc = 0;
	float accNoL = 0;
	[unroll(4)]
	for (uint i = 0; i < 4; ++i) {
		[unroll(dist)]
		for (uint j = 0; j < dist; ++j) {
			float2 offset = filterOffset[i] * (dist - j) / dims;
			float4 col = sourceTexArray.SampleLevel(gPointClampSampler, float3(uv + offset, 0), 0);
			col.a /= (j + 1);
			acc += float4(col.rgb*col.a, col.a);
			accNoL += sourceTexArray.SampleLevel(gPointClampSampler, float3(uv + offset, 1), 0).x*col.a;
		}
	}
	float mul = 1.0 / max(acc.a, 0.0001);
	return float4(acc.rgb * mul, accNoL * mul);
}

PS_OUTPUT psFilterRefractionBack(VS_OUTPUT_SS i) {
	float2 uv = float2(i.projPos.x, -i.projPos.y)*0.5 + 0.5;
	PS_OUTPUT o;
	float4 t = sourceTex.SampleLevel(ClampLinearSampler, uv, 0);
	o.sv_target0 = float4(t.xyz, 1);
	o.sv_target1 = float4(t.w,0,0,1);
	return o;
}

float4 PS_BUILD_UNDERWATER_MASK(VS_OUTPUT_SS i, uniform bool useTilingMask) : SV_TARGET0 {

	float4 np = mul(float4(0, 0, 1, 1), gProj);
	float4 wpos = mul(float4(i.projPos.xy, np.z/np.w, 1), gViewProjInv);
	wpos.xyz /= wpos.w;

	WaterLocalParams localParams = getWaterLocalParams(wpos.xyz);
#if USE_PS_MASK_DISCARD
	if (!any(localParams.wave.xyz)) 
		discard;
#endif
	float3 displace = calculateWaterDisplace(wpos.xyz, localParams, useTilingMask);

//	return float4(depth, 0, 0, 1);

	bool underwater = wpos.y < g_Level - gOrigin.y + displace.y;
	return float4(underwater, 0, 0, 1);
}

void PS_APPLY_UNDERWATER_MASK(VS_OUTPUT_SS i) {
	float2 uv = float2(i.projPos.x, -i.projPos.y)*0.5 + 0.5;
	float4 m = g_UnderwaterMask.SampleLevel(ClampLinearSampler, uv, 0);
	if (m.x < 0.5)
		discard;
}


#if USE_CHECKER

float3 testTilingMask(float2 pos) {
	float2 p = abs((fmod(pos, 10000.0) * 0.0001));
	bool2 b1 = p > 0.5;
	bool2 b2 = fmod(p, 0.5) * 2 > 0.5;
	bool2 b3 = fmod(p, 0.25) * 4 > 0.5;

	float t = ((b1.x^b1.y) + (b2.x^b2.y) + (b3.x^b3.y)) / 3.0;
	float2 f = (b1 - b2) * 0.5 + b3 * 0.25;

	return float3(t, f*0.5 + 0.5);
}

float3 testTilingMaskBlur(float2 pos) {
	const int count = 10;

	float rat = 2.0*3.1415926535 / ((1 + sqrt(5.0)) / 2.0);
	float3 acc = 0;
	for (int i = 0; i < count; i++) {
		float a = float(i)*rat;
		float s, c;
		sincos(a, s, c);
		float2 p = sqrt(float(i))*float2(c, s);
		acc += testTilingMask(pos + p * 25);
	}
	return acc / float(count);
}

PS_OUTPUT PS_WAVE_CHECKER(VS_OUTPUT_SS i) {
	float4 pp = mul(float4(i.projPos.xy, 1, 1), gViewProjInv);
	float3 ray = normalize(pp.xyz / pp.w - gCameraPos);
	float2 p = gCameraPos.xz - ray.xz * ((gCameraPos.y + gOrigin.y - g_Level) / ray.y) + gOrigin.xz;
	float3 f = testTilingMaskBlur(p);

	PS_OUTPUT o;
	o.sv_target0 = float4(HALF, HALF, HALF, 0);
	float s = 0.02;
	float2 vel = float2(sin(p.y*s), cos(p.x*s));
	float ps = length(vel);
	o.sv_target1 = float4(0, vel * 0.5 + 0.5, ps * 0.5);
	return o;
}

#endif

///////////////////////////////////////////////////// Techniques

RasterizerState WireframeMS {
    CullMode = NONE;
    FillMode = WIREFRAME;
    MultisampleEnable = TRUE;
};

RasterizerState rsBiasWater {
	CullMode = None;
	FillMode = Solid;
	MultisampleEnable = FALSE;
	SlopeScaledDepthBias = -0.01;		// fix z-fighting with far terrain LOD
//	DepthClipEnable = FALSE;
};

BlendState waterGBufferAlphaBlend {
	BlendEnable[0] = TRUE; // normal
	SrcBlend[0] = SRC_ALPHA;
	DestBlend[0] = INV_SRC_ALPHA;
	BlendOp[0] = ADD;

	BlendEnable[1] = TRUE;
	SrcBlend[1] = SRC_ALPHA;
	DestBlend[1] = INV_SRC_ALPHA;
	BlendOp[1] = ADD;
 
	BlendEnable[2] = TRUE;
	SrcBlend[2] = SRC_ALPHA;
	DestBlend[2] = INV_SRC_ALPHA;
	BlendOp[2] = ADD;

	BlendEnable[3] = TRUE;
	SrcBlend[3] = SRC_ALPHA;
	DestBlend[3] = INV_SRC_ALPHA;
	BlendOp[3] = ADD;

	RenderTargetWriteMask[0] = 0x07;
	RenderTargetWriteMask[1] = 0x07;
	RenderTargetWriteMask[2] = 0x07;
	RenderTargetWriteMask[3] = 0x07;
};

BlendState waterGBufferDisableAlphaBlend {
	BlendEnable[0] = FALSE; 
	BlendEnable[1] = FALSE;
	BlendEnable[2] = FALSE;
	BlendEnable[3] = FALSE;

	RenderTargetWriteMask[0] = 0x07;
	RenderTargetWriteMask[1] = 0x07;
	RenderTargetWriteMask[2] = 0x07;
	RenderTargetWriteMask[3] = 0x07;
};

#undef COMMON_PART
#define COMMON_PART 		SetGeometryShader(NULL);		\
							SetComputeShader(NULL);			\
							SetDepthStencilState(Water_DepthStencilState, STENCIL_COMPOSITION_WATER);		\
							SetRasterizerState(rsBiasWater);

technique10 Surface {
	pass P0 {
		SetVertexShader(CompileShader(vs_5_0, VS()));
		SetHullShader(CompileShader(hs_5_0, HS_LOW()));
		SetDomainShader(CompileShader(ds_5_0, DS_LOW()));
		SetPixelShader(CompileShader(ps_5_0, PS(false, false, false)));
		SetBlendState(waterGBufferDisableAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);
		COMMON_PART
	}
	pass P1 {
		SetVertexShader(CompileShader(vs_5_0, VS()));
		SetHullShader(CompileShader(hs_5_0, HS()));
		SetDomainShader(CompileShader(ds_5_0, DS(false)));
		SetPixelShader(CompileShader(ps_5_0, PS(true, false, true)));
#if USE_MASK
		SetBlendState(waterGBufferAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);
#else
		SetBlendState(waterGBufferDisableAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);
#endif
		COMMON_PART
	}
	pass P2 {
		SetVertexShader(CompileShader(vs_5_0, VS()));
		SetHullShader(CompileShader(hs_5_0, HS()));
		SetDomainShader(CompileShader(ds_5_0, DS(true)));
		SetPixelShader(CompileShader(ps_5_0, PS(true, true, true)));
#if USE_MASK
		SetBlendState(waterGBufferAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);
#else
		SetBlendState(waterGBufferDisableAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);
#endif
		COMMON_PART
//			SetDepthStencilState(Water_DepthStencilState, STENCIL_COMPOSITION_WATER);		
//			SetRasterizerState(WireframeMS);

	}
	pass P3 {														// far water for flat (always flat)
		SetVertexShader(CompileShader(vs_5_0, VS_FLAT()));
		SetPixelShader(CompileShader(ps_5_0, PS(false, false, false)));
		SetHullShader(NULL);
		SetDomainShader(NULL);
		SetBlendState(waterGBufferDisableAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);
		COMMON_PART
	}
	pass P4 {														// far water (always flat)
		SetVertexShader(CompileShader(vs_5_0, VS_FLAT()));
		SetPixelShader(CompileShader(ps_5_0, PS(false, false, true)));
		SetHullShader(NULL);
		SetDomainShader(NULL);
#if USE_MASK
		SetBlendState(waterGBufferAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);
#else
		SetBlendState(waterGBufferDisableAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);
#endif
		COMMON_PART
	}

};

#undef COMMON_PART
#define COMMON_PART 		SetGeometryShader(NULL);		\
							SetComputeShader(NULL);			\
							SetHullShader(NULL);			\
							SetDomainShader(NULL);			\
							SetDepthStencilState(Water_DepthStencilState, STENCIL_COMPOSITION_WATER);		\
							SetBlendState(disableAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);	\
							SetRasterizerState(rsBiasWater);

technique10 Draft {
    pass P0	{          
		SetVertexShader(CompileShader(vs_5_0, VS_FLAT()));
		SetPixelShader(CompileShader(ps_5_0, PS_DRAFT()));
		COMMON_PART
	}
	pass P1	{
		SetVertexShader(CompileShader(vs_5_0, VS_FLAT()));
		SetPixelShader(CompileShader(ps_5_0, PS_FLIR()));
		COMMON_PART
	}
	pass P3	{
		SetVertexShader(CompileShader(vs_5_0, VS_RADAR()));
		SetPixelShader(CompileShader(ps_5_0, PS_RADAR()));
		COMMON_PART
	}

}

#undef COMMON_PART
#define COMMON_PART 		SetGeometryShader(NULL);		\
							SetComputeShader(NULL);			\
							SetHullShader(NULL);			\
							SetDomainShader(NULL);			\
							SetDepthStencilState(disableDepthBuffer, 0);		\
							SetBlendState(disableAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);	\
							SetRasterizerState(cullNone);

technique10 Wave {
    pass P0	{          
		SetVertexShader(CompileShader(vs_5_0, VS_SS()));
		SetPixelShader(CompileShader(ps_5_0, PS_WAVE_MASK()));
		COMMON_PART
    }
	pass P1	{
		SetVertexShader(CompileShader(vs_5_0, VS_SS()));
		SetPixelShader(CompileShader(ps_5_0, PS_WAVE()));
		COMMON_PART
	}
#if USE_CHECKER
	pass P2 {
		SetVertexShader(CompileShader(vs_5_0, VS_SS()));
		SetPixelShader(CompileShader(ps_5_0, PS_WAVE_CHECKER()));
		COMMON_PART
	}
#endif
}

BlendState mipAlphaBlend {
	BlendEnable[0] = TRUE;
	SrcBlend[0] = INV_DEST_ALPHA;
	DestBlend[0] = DEST_ALPHA;
	BlendOp[0] = ADD;
	SrcBlendAlpha[0] = ZERO;
	DestBlendAlpha[0] = ZERO;
	BlendOpAlpha[0] = ADD;
	RenderTargetWriteMask[0] = 0x0f;

	BlendEnable[1] = TRUE;
	SrcBlend[1] = INV_DEST_ALPHA;
	DestBlend[1] = DEST_ALPHA;
	BlendOp[1] = ADD;
	RenderTargetWriteMask[1] = 0x01;
};

BlendState refractionAlphaBlend {
	BlendEnable[0] = FALSE;
	BlendEnable[1] = FALSE;
	RenderTargetWriteMask[0] = 0x0f;
	RenderTargetWriteMask[1] = 0x09;
};

#undef COMMON_PART
#define COMMON_PART 		SetGeometryShader(NULL);		\
							SetComputeShader(NULL);			\
							SetHullShader(NULL);			\
							SetDomainShader(NULL);			\
							SetDepthStencilState(disableDepthBuffer, 0);	\
							SetRasterizerState(cullNone);              

technique10 Refraction {
    pass P0	{          
		SetVertexShader(CompileShader(vs_5_0, VS_SS()));
		SetPixelShader(CompileShader(ps_5_0, PS_REFRACTION(false)));
		SetBlendState(refractionAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);
		COMMON_PART
	}
	pass P1 {
		SetVertexShader(CompileShader(vs_5_0, VS_SS()));
		SetPixelShader(CompileShader(ps_5_0, PS_REFRACTION(true)));
		SetBlendState(refractionAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);
		COMMON_PART
	}
	pass P2 {
		SetVertexShader(CompileShader(vs_5_0, VS_SS()));
		SetPixelShader(CompileShader(ps_5_0, psFilterRefraction(4)));
		SetBlendState(disableAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);
		COMMON_PART
	}
	pass P3 {
		SetVertexShader(CompileShader(vs_5_0, VS_SS()));
		SetPixelShader(CompileShader(ps_5_0, psFilterRefractionBack()));
		SetBlendState(mipAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);
		COMMON_PART
	}
}

DepthStencilState writeUnderwaterStencil {
	DepthEnable = FALSE;
	DepthWriteMask = ZERO;
	DepthFunc = DEPTH_FUNC;
	WRITE_COMPOSITION_TYPE_TO_STENCIL;
};

DepthStencilState writeUnderwaterDepth {
	DepthEnable = TRUE;
	DepthWriteMask = ALL;
	DepthFunc = ALWAYS;

	StencilEnable = TRUE;
	StencilReadMask = STENCIL_COMPOSITION_MASK;
	StencilWriteMask = 0;

	FrontFaceStencilFunc = EQUAL;
	FrontFaceStencilPass = KEEP;
	FrontFaceStencilFail = KEEP;

	BackFaceStencilFunc = EQUAL;
	BackFaceStencilPass = KEEP;
	BackFaceStencilFail = KEEP;
};


#undef COMMON_PART
#define COMMON_PART 		SetGeometryShader(NULL);		\
							SetComputeShader(NULL);			\
							SetHullShader(NULL);			\
							SetDomainShader(NULL);			\
							SetBlendState(disableAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF); \
							SetRasterizerState(cullNone);

technique10 UnderwaterMask {
	pass P0 {
		SetVertexShader(CompileShader(vs_5_0, VS_SS()));
		SetPixelShader(CompileShader(ps_5_0, PS_BUILD_UNDERWATER_MASK(true)));
		SetDepthStencilState(disableDepthBuffer, 0);
		COMMON_PART
	}
	pass P1 {
		SetVertexShader(CompileShader(vs_5_0, VS_SS()));
		SetPixelShader(CompileShader(ps_5_0, PS_BUILD_UNDERWATER_MASK(false)));
		SetDepthStencilState(disableDepthBuffer, 0);
		COMMON_PART
	}
	pass P2 {												// apply underwater mask
		SetVertexShader(CompileShader(vs_5_0, VS_SS()));
		SetPixelShader(CompileShader(ps_5_0, PS_APPLY_UNDERWATER_MASK()));
		SetDepthStencilState(writeUnderwaterStencil, STENCIL_COMPOSITION_UNDERWATER);
		COMMON_PART
	}
	pass P3 {												// apply underwater mask to depth to cut transparents
		SetVertexShader(CompileShader(vs_5_0, VS_SS()));
		SetPixelShader(NULL);
		SetDepthStencilState(writeUnderwaterDepth, STENCIL_COMPOSITION_UNDERWATER);
		COMMON_PART
	}
}

#include "waterReflection.hlsl"

