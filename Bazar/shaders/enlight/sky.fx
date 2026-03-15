#include "common/context.hlsl"
#include "common/states11.hlsl"
#include "common/samplers11.hlsl"
#include "common/dithering.hlsl"
#include "enlight/skyCommon.hlsl"
#include "deferred/deferredCommon.hlsl"

#include "common/haloSampling.hlsl"

//#define USE_MILKYWAY

#ifdef USE_MILKYWAY 
TextureCube milkywayTex;
#endif

float4x4 viewProjInverse;

static const float atmDepth = paramDistMax;//km

struct VS_OUTPUT {
	float4	pos:	SV_POSITION;
	float2	coords: TEXCOORD0;
	float3	ray:	TEXCOORD1;
};


static const float2 verts[4] = {
	float2(-1.0, -1.0),
	float2( 1.0, -1.0),
	float2(-1.0,  1.0),
	float2( 1.0,  1.0)
};

VS_OUTPUT VS(uint vid: SV_VertexID) {
	float4 pos = float4(verts[vid], 0, 1);

	VS_OUTPUT o;
	o.pos = pos;
	o.coords = pos.xy * 0.5 + 0.5;
	o.ray =  mul(pos, viewProjInverse).xyz;
	return o;
}

// ========== LEGACY DITHERING (retained for reference / fallback) ==========
float3 applyDitheringOnLowLuminance(uint2 pixel, float3 color, float lumMaxInv)
{
	float lum = dot(color, 0.333333);
	return color * lerp((0.9 + 0.2*dither_ordered8x8(pixel)), 1, saturate(lum*lumMaxInv));
}

#define AIRGLOW_INTENSITY 1e-5

// Normalized so max component is 1.0; brightness controlled by AIRGLOW_INTENSITY.
static const float3 AIRGLOW_COLOR = float3(0.60, 0.75, 1.00);

float3 computeNightSkyFloor(float3 viewDir, float3 computedSkyColor)
{
    // Only contribute when the Bruneton model returns near-zero radiance.
    // This naturally handles all cases:
    //   Daytime/twilight: computedSkyColor is large, weight is 0.
    //   Moonlit night: computedSkyColor is small but nonzero, weight is 0 or small.
    //   Moonless night: computedSkyColor is approximately 0, weight is 1.
    float skyLum = dot(computedSkyColor, float3(0.2126, 0.7152, 0.0722));

    // Onset threshold: when computed sky luminance falls below this value,
    // the airglow floor begins to contribute. At 10x this value, the floor
    // contribution is zero. The transition is smooth (saturate of linear ramp).
    // Set low enough that moonlit sky (even thin crescent) suppresses the floor.
    float onsetThreshold = AIRGLOW_INTENSITY * 5.0;
    float floorWeight = saturate(1.0 - skyLum / max(onsetThreshold, 1e-12));

    float cosZenith = saturate(viewDir.y);
    float airmass = 1.0 / max(cosZenith, 0.05);  // clamp at approximately 87 degrees
    float extinction = exp(-0.3 * (airmass - 1.0));  // normalized: 1.0 at zenith

    // Below the horizon (viewDir.y < 0), suppress entirely.
    // Objects below horizon are terrain, not sky.
    float horizonMask = smoothstep(-0.02, 0.05, viewDir.y);

    return AIRGLOW_COLOR * AIRGLOW_INTENSITY * extinction * horizonMask * floorWeight;
}

float4 PS(VS_OUTPUT i, uniform bool drawSunDisk): SV_TARGET0
{
	float3 viewDir = normalize(i.ray);
	float r = length(atmEarthCenter);
	float mu = dot(atmEarthCenter, viewDir) / r;
	float3 transmittance;
	float3 singleMieScattering;
	float3 skyRadiance = GetSkyRadiance(atmEarthCenter + heightHack * gSurfaceNormal, viewDir, 0.0, atmSunDirection, transmittance, singleMieScattering, atmDepth);

	float3 skyColor = skyRadiance * gAtmIntensity;


	// Luminance-adaptive amplitude: matches atmosphere.hlsl fix.
	float _ditherLum = dot(skyColor, float3(0.2126, 0.7152, 0.0722));
	float _ditherAmp = 0.001 * saturate(_ditherLum * 100.0);
	skyColor = ditherAtmosphericHDR(skyColor, i.pos.xy, _ditherAmp, gModelTime);

	skyColor += computeNightSkyFloor(viewDir, skyColor);
	
	if(drawSunDisk)
		skyColor += transmittance * SunDisc(viewDir, atmSunDirection);
		
	if (gIceHaloParams.atmosphereFactor > 0.0)
		skyColor += singleMieScattering * sampleHalo(gBilinearClampSampler, viewDir, gSunDir) * (gAtmIntensity * gIceHaloParams.atmosphereFactor);

	static const float Rg = gEarthRadius;
	AtmosphereParameters atmosphere; initAtmosphereParameters(atmosphere);
	float dist = RayIntersectsGround(atmosphere, r, mu) ? DistanceToBottomAtmosphereBoundary(atmosphere, r, mu) : sqrt(r*r-Rg*Rg)*0.3;
	return float4(skyColor, 1.0);
}

float4 PS2(VS_OUTPUT i, uniform bool bFadeByHeight): SV_TARGET0
{
	const float Rg = gEarthRadius;
	float3 viewDir = normalize(i.ray);
	float r, mu, mu2;
	float3 skyColor;
	float3 transmittance;
	float3 singleMieScattering;
	GetRMu(atmEarthCenter, viewDir, r, mu);
	mu2 = max(mu, -sqrtf(1.0 - (Rg / r) * (Rg / r))+0.01);
	if(bFadeByHeight)
	{
		float3 skyRadianceBase = GetSkyRadiance(r, mu,  atmEarthCenter, viewDir, 0.0, atmSunDirection, transmittance, singleMieScattering, atmDepth);
		float3 skyRadiance     = GetSkyRadiance(r, mu2, atmEarthCenter, viewDir, 0.0, atmSunDirection, transmittance, singleMieScattering, atmDepth);
		
		float nHeight = saturate((gCameraPos.y + gOrigin.y) / 15000.0);
		skyColor = lerp(skyRadiance, skyRadianceBase, nHeight) * gAtmIntensity;
		skyColor += computeNightSkyFloor(viewDir, skyColor);
	}
	else
	{
		skyColor = GetSkyRadiance(r, mu2, atmEarthCenter, viewDir, 0.0, atmSunDirection, transmittance, singleMieScattering, atmDepth) * gAtmIntensity;
	}

	skyColor = ditherAtmosphericHDR(skyColor, i.pos.xy, 0.004);
	skyColor += computeNightSkyFloor(viewDir, skyColor);

	if (gIceHaloParams.atmosphereFactor > 0.0)
		skyColor += sampleHalo(gBilinearClampSampler, viewDir, gSunDir) * singleMieScattering * (gAtmIntensity * gIceHaloParams.atmosphereFactor);
	
	AtmosphereParameters atmosphere; initAtmosphereParameters(atmosphere);
	float dist = RayIntersectsGround(atmosphere, r, mu) ? DistanceToBottomAtmosphereBoundary(atmosphere, r, mu) : sqrt(r*r-Rg*Rg)*0.3;
	
	return float4(skyColor, 1.0);
}

technique10 Sky
{
	pass clearSky
	{
		SetVertexShader(CompileShader(vs_4_0, VS()));
		SetGeometryShader(NULL);
		SetPixelShader(CompileShader(ps_4_0, PS(false)));

		SetDepthStencilState(disableDepthBuffer, 0);
		SetBlendState(disableAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);
		SetRasterizerState(cullNone);
	}
	pass clearSkyWithSunDisk
	{
		SetVertexShader(CompileShader(vs_4_0, VS()));
		SetGeometryShader(NULL);
		SetPixelShader(CompileShader(ps_4_0, PS(true)));

		SetDepthStencilState(disableDepthBuffer, 0);
		SetBlendState(disableAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);
		SetRasterizerState(cullNone);
	}
	pass skyWithFogOnTheGround
	{
		SetVertexShader(CompileShader(vs_4_0, VS()));
		SetGeometryShader(NULL);
		SetPixelShader(CompileShader(ps_4_0, PS2(false)));

		SetDepthStencilState(disableDepthBuffer, 0);
		SetBlendState(disableAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);
		SetRasterizerState(cullNone);
	}
	pass skyForEnvironmentCube
	{
		SetVertexShader(CompileShader(vs_4_0, VS()));
		SetGeometryShader(NULL);
		SetPixelShader(CompileShader(ps_4_0, PS2(true)));

		SetDepthStencilState(disableDepthBuffer, 0);
		SetBlendState(disableAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);
		SetRasterizerState(cullNone);
	}
}