#include "common/States11.hlsl"
#include "common/samplers11.hlsl"
#include "common/context.hlsl"
#include "common/AmbientCube.hlsl"
#include "common/random.hlsl"
#define ATMOSPHERE_COLOR
#define PS_HALO		
#define PS_NORMAL_LIGHT
#include "ParticleSystem2/common/psCommon.hlsl"

float3 wPos;
float4 diffuseColor;
float3 scale;//scale, scaleDistFactor
float4 speed; // speed.xyz, flirBrightnessFactor

#define seed scale.z

Texture2D texNorm;

static const float opacityMax = 2.0;

static const float4 quad[4] = {
	float4( -0.5, -0.5, 0, 0),
	float4( -0.5,  0.5, 0, 0),
	float4(  0.5, -0.5, 0, 0),
	float4(  0.5,  0.5, 0, 0)
};

struct PS_INPUT
{
	float4 pos: SV_POSITION;
	float3 uv : TEXCOORD0;
};


PS_INPUT vsGlow(uint vertId:  SV_VertexID)
{
	PS_INPUT o;
	float rnd = frac(sin((gModelTime + 123.865132*seed)*321513.5123));
	float4 vPos = quad[vertId];

	o.pos = mul(float4(wPos,1), gView);
	float scaleFactor = 0.5*scale.x * (1 + scale.y * max(0, o.pos.z));
	o.pos += vPos * scaleFactor * (5 + rnd);
	o.pos = mul(o.pos, gProj);

	float ang = smoothNoise1(gModelTime*10+rnd*0.1)*6.2832;
	o.uv.xy = mul(vPos.xy, rotMatrix2x2(ang)) + 0.5;
	o.uv.z = opacityMax*(0.9 + 0.1*rnd);
	return o;
}


float4 psGlow(PS_INPUT i, uniform bool bClouds): SV_TARGET0
{
	float4 alpha = tex.Sample(ClampLinearSampler, i.uv.xy).rrrr;

	float4 color = diffuseColor * diffuseColor * (alpha * alpha * i.uv.z);

	// [MOD] Issue F1: Physically correct perceptual glow modulation.
	//
	// ORIGINAL:
	//   color.rgb *= 0.25 + 1.75 * sqrt(max(0, gSurfaceNdotL));
	//
	// The original scaled glow brightness by sun-surface dot product,
	// producing 0.25x at night and 2.0x at noon. This is physically
	// backwards for a self-luminous pyrotechnic source: MTV flare
	// combustion (~2000-2300 K) has constant radiance regardless of
	// ambient lighting. The perceived glow/bloom is actually far more
	// prominent at night due to dark adaptation and reduced contrast
	// masking from the background.
	//
	// Replacement uses sun elevation (gSunDir.y) and world-space
	// altitude (wPos.y) to modulate perceived glow prominence:
	//   - nightVisibility: 1.0 at full day, ramps to 1.9 at night
	//     as sun drops below horizon. Reflects increased scotopic
	//     sensitivity and lower background luminance.
	//   - altitudeClarity: up to 1.2 at 10 km. Thinner atmosphere
	//     means less scattering that would wash out the glow.
	//   - Baseline 0.8 keeps noon/sea-level glow slightly below
	//     stock peak (0.8 vs 2.0), preventing additive blowout
	//     against bright sky.
	//
	// Follows the same pattern as afterburner getGlowModulator().
	float nightVisibility = 1.0 + 0.9 * saturate(-gSunDir.y);
	float altitudeClarity = 1.0 + 0.2 * saturate(wPos.y / 10000.0);
	color.rgb *= 0.8 * nightVisibility * altitudeClarity;

	if(bClouds)
		color.a *= getAtmosphereTransmittance(0).r;
	
	return color;
}

float luminance(float3 v){
	return 0.3*v.x + 0.59*v.y + 0.11*v.z;
}


float4 psGlowFlir(PS_INPUT i, uniform bool bClouds): SV_TARGET0
{
	float4 alpha = tex.Sample(ClampLinearSampler, i.uv.xy).rrrr;

	float4 color = diffuseColor * diffuseColor * (alpha * alpha * i.uv.z);

	float flirBrightnessFactor = speed.w;
	float lum = luminance(color.rgb) * flirBrightnessFactor;
	
	return float4(lum, lum, lum, color.a);
}


technique10 flareGlowTech
{
	pass p0
	{
		DISABLE_CULLING;
		ENABLE_RO_DEPTH_BUFFER;
		SetBlendState(additiveAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);
		
		SetVertexShader(CompileShader(vs_4_0, vsGlow()));
		SetHullShader(NULL);
		SetDomainShader(NULL);
		SetGeometryShader(NULL);
		SetComputeShader(NULL);
		SetPixelShader(CompileShader(ps_4_0, psGlow(false))); 
	}
	
	pass withClouds
	{
		DISABLE_CULLING;
		ENABLE_RO_DEPTH_BUFFER;
		SetBlendState(additiveAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);
		
		SetVertexShader(CompileShader(vs_4_0, vsGlow()));
		SetHullShader(NULL);
		SetDomainShader(NULL);
		SetGeometryShader(NULL);
		SetComputeShader(NULL);
		SetPixelShader(CompileShader(ps_4_0, psGlow(true))); 
	}

	pass p0Flir
	{
		DISABLE_CULLING;
		ENABLE_RO_DEPTH_BUFFER;
		SetBlendState(additiveAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);
		
		SetVertexShader(CompileShader(vs_4_0, vsGlow()));
		SetHullShader(NULL);
		SetDomainShader(NULL);
		SetGeometryShader(NULL);
		SetComputeShader(NULL);
		SetPixelShader(CompileShader(ps_4_0, psGlowFlir(false))); 
	}
	
	pass withCloudsFlir
	{
		DISABLE_CULLING;
		ENABLE_RO_DEPTH_BUFFER;
		SetBlendState(additiveAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);
		
		SetVertexShader(CompileShader(vs_4_0, vsGlow()));
		SetHullShader(NULL);
		SetDomainShader(NULL);
		SetGeometryShader(NULL);
		SetComputeShader(NULL);
		SetPixelShader(CompileShader(ps_4_0, psGlowFlir(true))); 
	}

}
