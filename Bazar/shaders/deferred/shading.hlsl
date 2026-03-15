#ifndef SHADING_HLSL
#define SHADING_HLSL

#define USE_DEBUG_ROUGHNESS_METALLIC 0

#define VERSION_NEWER_2_5_6 // used in dots.fx

#ifndef PLUGIN_3DSMAX
	#include "common/shadingCommon.hlsl"
	#include "common/lighting.hlsl"
	#include "deferred/atmosphere.hlsl"
#endif

#include "deferred/environmentCube.hlsl"
#include "common/dithering.hlsl"

float modifyRoughnessByCloudShadow(float roughness, float cloudShadow)
{
    return roughness;
}

// =============================================================================
// Shadow-compensated AO: approximate missing local bounce illumination
// =============================================================================
//
// In shadowed concavities (wing roots, intake ducts, underbelly), AO correctly
// reduces IBL contribution based on reduced sky-hemisphere visibility. However,
// in a real scene, nearby sunlit surfaces bounce significant diffuse energy into
// these regions - energy the environment cubemap cannot capture because it
// represents distant sky, not local geometry.
//
// Without GI, this bounce light is entirely absent. AO then over-penalizes the
// only remaining light source (IBL), producing shadows darker than reference.
//
// Compensation: relax AO strength on IBL terms in proportion to how much the
// surface is already in shadow. When shadow ≈ 0, reduce AO penalty by
// BOUNCE_APPROX_STRENGTH fraction, approximating the bounce fill that would
// have partially offset the reduced sky visibility.
//
// The shadow value reaching ShadeSolid is finalShadow = min(cascade, terrain,
// sss, clouds), which is the correct combined signal - any shadow source
// produces the same bounce-light deficit.
//
// Tuning:
//   0.0 = disabled, AO always at full strength (stock behavior)
//
static const float BOUNCE_APPROX_STRENGTH = 0.10;

float compensateAOForMissingBounce(float AO, float shadow)
{
	// Scale AO influence on IBL from full (sunlit) to reduced (shadowed).
	// shadow = 1 → aoScale = 1.0  → effectiveAO = AO  (unchanged)
	// shadow = 0 → aoScale = 0.65 → effectiveAO biased toward 1.0
	float aoScale = lerp(1.0 - BOUNCE_APPROX_STRENGTH, 1.0, shadow);
	return lerp(1.0, AO, aoScale);
}

float3 ShadeSolid(EnvironmentIrradianceSample eis, float3 sunColor, float3 diffuseColor, float3 specularColor, float3 normal, float roughness, float metallic, float shadow, float cloudShadow, float AO, float3 viewDir, float3 pos, float2 energyLobe = float2(1, 1), uniform uint selectEnvCube = LERP_ENV_MAP, float lerpEnvCubeFactor = 0, uniform bool useSSLR = false, float2 uvSSLR = float2(0, 0), uniform bool insideCockpit = false)
{
	float roughnessSun = modifyRoughnessByCloudShadow(roughness, cloudShadow);
	float NoL = max(0, dot(normal, gSunDir));
	float3 lightAmount = sunColor * (gSunIntensity * NoL * shadow);
	float3 finalColor = ShadingDefault(diffuseColor, specularColor, roughnessSun, normal, viewDir, gSunDir, energyLobe) * lightAmount;

	// Compensate AO on IBL terms for missing local bounce light.
	// Only applied to the IBL multiplier — direct sun term above is unaffected.
	float iblAO = compensateAOForMissingBounce(AO, shadow);

	//diffuse IBL
	float3 envLightDiffuse;
#if USE_COCKPIT_CUBEMAP
	if (insideCockpit) {
		
		envLightDiffuse = SampleCockpitCubeMapMip(pos, normal, environmentMipsCount) * gCockpitIBL.x;

		#if USE_DEBUG_COCKPIT_CUBEMAP 
			float3 oldLightDiffuse = SampleEnvironmentMap(eis, normal, 1.0, environmentMipsCount, selectEnvCube, lerpEnvCubeFactor);
			envLightDiffuse = gDev0.x > 0.5 ? oldLightDiffuse : envLightDiffuse;
		#endif
	} else
#endif
	{
		envLightDiffuse = SampleEnvironmentMap(eis, normal, 1.0, environmentMipsCount, selectEnvCube, lerpEnvCubeFactor);
	}
	finalColor += diffuseColor * envLightDiffuse * (gIBLIntensity * iblAO * energyLobe.x);

	//specular IBL
	float NoV = max(0, dot(normal, viewDir));
	float a = roughness * roughness;
	float3 R = normal * NoV * 2 - viewDir;
	// float3 R = -reflect(viewDir, normal);
	R = normalize(lerp(normal, R, (1 - a) * (sqrt(1 - a) + a)));

	float roughnessMip = getMipFromRoughness(roughness, environmentMipsCount);

	float3 envLightSpecular;
#if USE_COCKPIT_CUBEMAP
	if (insideCockpit) {

	#if USE_DEBUG_COCKPIT_CUBEMAP 
		if (gDev1.y > 0.5)
			roughness = 0;
	#endif
	
#if defined(GLASS_MATERIAL) && !defined(GLASS_INSTRUMENTAL)
		float mip = getMipFromRoughness(roughness, environmentMipsCount);
		envLightSpecular = SampleCockpitCubeMapMip(pos, R, mip, true) * gCockpitIBL.y;
#else
		envLightSpecular = SampleCockpitCubeMap(pos, R, roughness) * gCockpitIBL.y;
#endif

	#if USE_DEBUG_COCKPIT_CUBEMAP 
		if (gDev1.x > 0.5)
			return envLightSpecular;
		float3 oldLightSpecular = SampleEnvironmentMap(eis, R, roughness, roughnessMip, selectEnvCube, lerpEnvCubeFactor);
		envLightSpecular = gDev0.y > 0.5 ? oldLightSpecular : envLightSpecular;
	#endif
	} else
#endif
	{
		envLightSpecular = SampleEnvironmentMap(eis, R, roughness, roughnessMip, selectEnvCube, lerpEnvCubeFactor);
		if (useSSLR) {
		// Remove original floor of Mip1 and use constant mutliplier to adjust for rough and smooth surfaces as needed.
		// Original calc was roughly times 0.5 so begin with that baseline.
		float sslrMip = roughnessMip * 0.5;
		float4 sslr = SSLRMap.SampleLevel(ClampLinearSampler, uvSSLR, sslrMip);

		// Fade reflections near screen edges to prevent hard cutoff when
		// reflected geometry exits the viewport. The 8% border width
		// produces a smooth fallback to the environment cubemap.
		float2 edgeFade = smoothstep(0.0, 0.04, uvSSLR) * smoothstep(0.0, 0.04, 1.0 - uvSSLR);
		sslr.a *= edgeFade.x * edgeFade.y;
		sslr.a *= smoothstep(0.0, 0.15, NoV);
		// Stochastic softening at stencil boundary: ±0.05 dither on alpha
		// breaks the hard edge where material transitions to non-reflective.
		sslr.a = saturate(sslr.a + ditherCentered(uint2(uvSSLR * gSreenParams.xy)) * 0.05);
		envLightSpecular = lerp(envLightSpecular, sslr.rgb, sslr.a);
	}
	}

#if	USE_BRDF_K
	float3 specColor = EnvBRDFApproxK(specularColor, roughness, NoV, gDev1.w);
#else
	float3 specColor = EnvBRDFApprox(specularColor, roughness, NoV);
#endif
	// Multiscatter energy compensation recovers energy lost by
	// single-scattering GGX on rough metallic surfaces.
	specColor *= SpecularEnergyCompensation(specularColor, roughness, NoV);

	finalColor += envLightSpecular * specColor * (iblAO * energyLobe.y);

	return finalColor;
}

float3 ShadeSolid(float3 pos, float3 sunColor, float3 diffuseColor, float3 specularColor, float3 normal, float roughness, float metallic, float shadow, float AO, float2 cloudShadowAO, float3 viewDir, float2 energyLobe = float2(1,1), uniform uint selectEnvCube = LERP_ENV_MAP, float lerpEnvCubeFactor = 0, uniform bool useSSLR = false, float2 uvSSLR =  float2(0,0), uniform bool insideCockpit = false)
{
#if	USE_DEBUG_ROUGHNESS_METALLIC
	roughness = clamp(roughness + gDev0.z, 0.02, 0.99);
	metallic = saturate(metallic + gDev0.w);
#endif

	EnvironmentIrradianceSample eis = (EnvironmentIrradianceSample)0;
	if(selectEnvCube != NEAR_ENV_MAP)
		eis = SampleEnvironmentIrradianceApprox(pos, cloudShadowAO.x, cloudShadowAO.y);

	return ShadeSolid(eis, sunColor, diffuseColor, specularColor, normal, roughness, metallic, shadow, cloudShadowAO.x, AO, viewDir, pos, energyLobe, selectEnvCube, lerpEnvCubeFactor, useSSLR, uvSSLR, insideCockpit);
}

float3 ShadeHDR(uint2 sv_pos_xy, float3 sunColor, float3 diffuse, float3 normal, float roughness, float metallic, float3 emissive, float shadow, float AO, float2 cloudShadowAO, float3 viewDir, float3 pos, float2 energyLobe = {1,1}, uniform uint selectEnvCube = LERP_ENV_MAP, uniform bool useSSLR = false, float2 uvSSLR = float2(0, 0), uniform uint LightsList = LL_SOLID, uniform bool insideCockpit = false, uniform bool useSecondaryShadowmap = false)
{
	float3 baseColor = GammaToLinearSpace(diffuse);

	float3 diffuseColor = baseColor * (1.0 - metallic);
	float3 specularColor = lerp(0.04, baseColor, metallic);

	roughness = clamp(roughness, 0.02, 0.99);

	float lerpEnvCubeFactor = selectEnvCube == LERP_ENV_MAP ? exp(-distance(pos, gCameraPos)*(1.0 / 500.0)) : 0;

	float3 finalColor = ShadeSolid(pos, sunColor, diffuseColor, specularColor, normal, roughness, metallic, shadow, AO, cloudShadowAO, viewDir, energyLobe, selectEnvCube, lerpEnvCubeFactor, useSSLR, uvSSLR, insideCockpit);

	finalColor += CalculateDynamicLightingTiled(sv_pos_xy, diffuseColor, specularColor, roughness, normal, viewDir, pos, insideCockpit, energyLobe, 0, LightsList, true, useSecondaryShadowmap);

	finalColor += emissive;

	return finalColor;
}

float3 ShadeTransparent(uint2 sv_pos_xy, float3 sunColor, float3 diffuse, float alpha, float3 normal, float roughness, float metallic, float3 emissive, float shadow, float2 cloudShadowAO, float3 viewDir, float3 pos,
	uniform bool bPremultipliedAlpha = false, uniform bool insideCockpit = false)
{
	//альфа-блендинг не должен влиять на силу спекулярного света, если srcСolor умножается на srcAlpha - компенсируем спекулярный вклад
	//иначе альфу применяем только к диффузной части освещения
	float2 energyLobe;
	energyLobe.x = bPremultipliedAlpha? alpha : 1.0;
	energyLobe.y = bPremultipliedAlpha? 1.0 : rcp(max(1.0 / 255.0, alpha));
	
	return ShadeHDR(sv_pos_xy, sunColor, diffuse, normal, roughness, metallic, emissive, shadow, 1, cloudShadowAO, viewDir, pos, energyLobe, LERP_ENV_MAP, false, float2(0, 0), LL_TRANSPARENT, insideCockpit, true);
}

#endif
