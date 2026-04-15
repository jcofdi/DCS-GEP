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
static const float BOUNCE_APPROX_STRENGTH = 0.0;

float compensateAOForMissingBounce(float AO, float shadow)
{
	// Scale AO influence on IBL from full (sunlit) to reduced (shadowed).
	// shadow = 1 → aoScale = 1.0  → effectiveAO = AO  (unchanged)
	// shadow = 0 → aoScale = 0.65 → effectiveAO biased toward 1.0
	float aoScale = lerp(1.0 - BOUNCE_APPROX_STRENGTH, 1.0, shadow);
	return lerp(1.0, AO, aoScale);
}

// Albedo-aware multi-bounce AO (Jimenez et al. 2016, Appendix B Eq. 33)
// High-albedo surfaces return more light from inter-reflections,
// so effective AO is weaker. Dark surfaces absorb and stay dark.
float3 MultiBounceAO(float ao, float3 albedo) {
    float3 a = 2.0404 * albedo - 0.3324;
    float3 b = -4.7951 * albedo + 0.6417;
    float3 c = 2.7552 * albedo + 0.6903;
    return max(ao, ((ao * a + b) * ao + c) * ao);
}

// =============================================================================
// Cone-based direct light micro-shadowing (Chan, SIGGRAPH 2018, Eq. 58)
// =============================================================================
//
// AO currently has zero effect on direct sunlight. Shadow cascades operate
// at meter-scale resolution; GTAO operates at centimeter scale. Panel gaps,
// control surface edges, intake lips, and pylon-fuselage junctions all have
// strong AO that shadow cascades miss entirely.
//
// The scalar AO visibility converts to an equivalent cone half-angle via
// the Nusselt analog (Jimenez Eq. 22): cos(theta) = sqrt(1 - AO).
// If the sun direction's N.L falls below this cone threshold, the direct
// light contribution is reduced with a squared falloff for a sharp but
// smooth transition.
//
// Surfaces with AO = 1.0 (flat, unoccluded) get microShadow = 1.0 (no
// change). Only surfaces that already have AO darkening receive additional
// direct-light attenuation.
// =============================================================================
float MicroShadow(float AO, float NoL, float3 normal, float3 bentNormal)
{
    float cosConeAngle = sqrt(1.0 - AO);
    float microShadow = saturate(NoL / max(cosConeAngle, 0.001));
    microShadow *= microShadow;

    // Engagement based on bent normal deviation from geometric normal.
    // Genuine occlusion tilts the bent normal away from the surface
    // normal. Proximity halos produce mild AO without directional
    // deviation -- the bent normal stays aligned with the geometric
    // normal because no actual hemisphere is blocked.
    float bentDeviation = 1.0 - saturate(dot(normal, bentNormal));
    // bentDeviation: 0.0 = identical (no real occlusion direction)
    //                0.3+ = significant tilt (real concavity)
    float engagement = smoothstep(0.02, 0.15, bentDeviation);
    return lerp(1.0, microShadow, engagement);
}

// Specular occlusion (Lagarde, Moving Frostbite to PBR, 2014)
//
// Empirical approximation that derives specular occlusion from scalar AO,
// roughness, and viewing angle. Correctly returns 1.0 for unoccluded
// surfaces regardless of viewing angle. Smooth surfaces with low AO get
// stronger attenuation; rough surfaces are more forgiving.
//
// Upgrade path: replace with GTSO 4D LUT (Jimenez Section 7) when a
// texture slot is available for the precomputed table.
float SpecularOcclusion(float AO, float roughness, float NoV)
{
    return saturate(pow(NoV + AO, exp2(-16.0 * roughness - 1.0)) - 1.0 + AO);
}

// =============================================================================
// Sun disc area light BRDF evaluation
// (Lagarde, Moving Frostbite to PBR 2014, Section 4.6)
// =============================================================================
// Evaluates diffuse (Frostbite renormalized Disney) at the punctual sun
// direction and specular (GGX) at the closest point on the sun disc to the
// mirror reflection direction.
float3 EvaluateSunBRDF(float3 diffuseColor, float3 specularColor,
	float roughness, float3 normal, float3 viewDir, float NoL, float NoV,
	float2 energyLobe)
{
	static const float SUN_COS_ANGLE = 0.99998918;  // cos(0.00465 rad)
	static const float SUN_SIN_ANGLE = 0.00464999;  // sin(0.00465 rad)

	// Diffuse: Frostbite renormalized Disney
	float3 H_diff = normalize(gSunDir + viewDir);
	float LdotH_diff = max(0, dot(gSunDir, H_diff));
	float energyBias = lerp(0, 0.5, roughness);
	float energyFactor = lerp(1.0, 1.0 / 1.51, roughness);
	float fd90 = energyBias + 2.0 * LdotH_diff * LdotH_diff * roughness;
	float lightScatter = 1.0 + (fd90 - 1.0) * pow(1.0 - NoL, 5);
	float viewScatter  = 1.0 + (fd90 - 1.0) * pow(1.0 - NoV, 5);
	float Fd = lightScatter * viewScatter * energyFactor;
	float3 sunDiffuse = diffuseColor * Fd * (1.0 / 3.1415926535897932);

	// Specular: closest point on sun disc to mirror reflection
	float3 R_sun = reflect(-viewDir, normal);
	float DdotR = dot(gSunDir, R_sun);
	float3 S = R_sun - DdotR * gSunDir;
	float sLen = max(length(S), 1e-6);
	float3 Lspec = DdotR < SUN_COS_ANGLE
		? normalize(SUN_COS_ANGLE * gSunDir + (S / sLen) * SUN_SIN_ANGLE)
		: R_sun;

	float3 H_spec = normalize(Lspec + viewDir);
	float NoH_spec = max(0, dot(normal, H_spec));
	float NoL_spec = max(0, dot(normal, Lspec));
	float VoH_spec = max(0, dot(viewDir, H_spec));
	float3 sunSpecular = Fresnel_schlick(specularColor, VoH_spec)
		* (D_ggx(roughness, NoH_spec) * Visibility_smithJA(roughness, NoV, NoL_spec));

	return sunDiffuse * energyLobe.x + sunSpecular * energyLobe.y;
}

// =============================================================================
// Screen-space local reflections blending
// =============================================================================
float3 BlendSSLR(float3 envLightSpecular, float2 uvSSLR, float roughnessMip, float NoV)
{
	float sslrMip = max(0.5, roughnessMip * 0.5);
	float4 sslr = SSLRMap.SampleLevel(ClampLinearSampler, uvSSLR, sslrMip);

	float2 edgeFade = smoothstep(0.0, 0.04, uvSSLR) * smoothstep(0.0, 0.04, 1.0 - uvSSLR);
	sslr.a *= edgeFade.x * edgeFade.y;
	sslr.a *= smoothstep(0.0, 0.15, NoV);
	sslr.a = saturate(sslr.a + ditherCentered(uint2(uvSSLR * gSreenParams.xy)) * 0.05);
	return lerp(envLightSpecular, sslr.rgb, sslr.a);
}

float3 ShadeSolid(EnvironmentIrradianceSample eis, float3 sunColor, float3 diffuseColor, float3 specularColor, float3 normal, float roughness, float metallic, float shadow, float cloudShadow, float AO, float3 viewDir, float3 pos, float2 energyLobe = float2(1, 1), uniform uint selectEnvCube = LERP_ENV_MAP, float lerpEnvCubeFactor = 0, uniform bool useSSLR = false, float2 uvSSLR = float2(0, 0), uniform bool insideCockpit = false, float3 bentNormal = float3(0,0,0))
{
	bool hasBentNormal = dot(bentNormal, bentNormal) > 0.5;

	// Suppress GTAO convex-surface artifacts at grazing angles.
	float grazingAOFade = smoothstep(0.1, 0.4, dot(normal, viewDir));
	float fadedAO = lerp(1.0, AO, grazingAOFade);

	float roughnessSun = modifyRoughnessByCloudShadow(roughness, cloudShadow);
	float NoL = max(0, dot(normal, gSunDir));
	float NoV = max(0, dot(normal, viewDir)) + 1e-5;

	// Direct sun: disc area light with split diffuse/specular evaluation
	float3 sunBRDF = EvaluateSunBRDF(diffuseColor, specularColor,
		roughnessSun, normal, viewDir, NoL, NoV, energyLobe);
	float3 lightAmount = sunColor * (gSunIntensity * NoL * shadow
		* MicroShadow(fadedAO, NoL, normal, hasBentNormal ? bentNormal : normal));
	float3 finalColor = sunBRDF * lightAmount;

	// IBL AO
	float iblAO = compensateAOForMissingBounce(fadedAO, shadow);

	// Diffuse IBL
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
	float3 mbAO = MultiBounceAO(iblAO, diffuseColor);
	finalColor += diffuseColor * envLightDiffuse * (gIBLIntensity * mbAO * energyLobe.x);

	// Specular IBL
	float a = roughness * roughness;
	float3 R = normal * NoV * 2 - viewDir;
	R = normalize(lerp(normal, R, (1 - a) * (sqrt(1 - a) + a)));
	float roughnessMip = getMipFromRoughness(roughness, environmentMipsCount);

	float3 envLightSpecular;
#if USE_COCKPIT_CUBEMAP
	if (insideCockpit) {
		#if USE_DEBUG_COCKPIT_CUBEMAP
			if (gDev1.y > 0.5) roughness = 0;
		#endif
	#if defined(GLASS_MATERIAL) && !defined(GLASS_INSTRUMENTAL)
		float mip = getMipFromRoughness(roughness, environmentMipsCount);
		envLightSpecular = SampleCockpitCubeMapMip(pos, R, mip, true) * gCockpitIBL.y;
	#else
		envLightSpecular = SampleCockpitCubeMap(pos, R, roughness) * gCockpitIBL.y;
	#endif
		#if USE_DEBUG_COCKPIT_CUBEMAP
			if (gDev1.x > 0.5) return envLightSpecular;
			float3 oldLightSpecular = SampleEnvironmentMap(eis, R, roughness, roughnessMip, selectEnvCube, lerpEnvCubeFactor);
			envLightSpecular = gDev0.y > 0.5 ? oldLightSpecular : envLightSpecular;
		#endif
	} else
#endif
	{
		if (selectEnvCube == LERP_ENV_MAP)
			envLightSpecular = SampleEnvironmentMapDetailed(R, roughnessMip);
		else
			envLightSpecular = SampleEnvironmentMap(eis, R, roughness, roughnessMip, selectEnvCube, lerpEnvCubeFactor);

		if (useSSLR)
			envLightSpecular = BlendSSLR(envLightSpecular, uvSSLR, roughnessMip, NoV);
	}

#if USE_BRDF_K
	float3 specColor = EnvBRDFApproxK(specularColor, roughness, NoV, gDev1.w);
#else
	float3 specColor = EnvBRDFApprox(specularColor, roughness, NoV);
#endif
	specColor *= SpecularEnergyCompensation(specularColor, roughness, NoV);

	float specOcc = SpecularOcclusion(fadedAO, roughness, NoV);
	finalColor += envLightSpecular * specColor * (specOcc * energyLobe.y);

	return finalColor;
}

float3 ShadeSolid(float3 pos, float3 sunColor, float3 diffuseColor, float3 specularColor, float3 normal, float roughness, float metallic, float shadow, float AO, float2 cloudShadowAO, float3 viewDir, float2 energyLobe = float2(1,1), uniform uint selectEnvCube = LERP_ENV_MAP, float lerpEnvCubeFactor = 0, uniform bool useSSLR = false, float2 uvSSLR =  float2(0,0), uniform bool insideCockpit = false, float3 bentNormal = float3(0,0,0))
{
#if	USE_DEBUG_ROUGHNESS_METALLIC
	roughness = clamp(roughness + gDev0.z, 0.02, 0.99);
	metallic = saturate(metallic + gDev0.w);
#endif

	EnvironmentIrradianceSample eis = (EnvironmentIrradianceSample)0;
	if(selectEnvCube != NEAR_ENV_MAP)
		eis = SampleEnvironmentIrradianceApprox(pos, cloudShadowAO.x, cloudShadowAO.y);

	return ShadeSolid(eis, sunColor, diffuseColor, specularColor, normal, roughness, metallic, shadow, cloudShadowAO.x, AO, viewDir, pos, energyLobe, selectEnvCube, lerpEnvCubeFactor, useSSLR, uvSSLR, insideCockpit, bentNormal);
}

float3 ShadeHDR(uint2 sv_pos_xy, float3 sunColor, float3 diffuse, float3 normal, float roughness, float metallic, float3 emissive, float shadow, float AO, float2 cloudShadowAO, float3 viewDir, float3 pos, float2 energyLobe = {1,1}, uniform uint selectEnvCube = LERP_ENV_MAP, uniform bool useSSLR = false, float2 uvSSLR = float2(0, 0), uniform uint LightsList = LL_SOLID, uniform bool insideCockpit = false, uniform bool useSecondaryShadowmap = false, float3 bentNormal = float3(0,0,0))
{
	float3 baseColor = GammaToLinearSpace(diffuse);

	float3 diffuseColor = baseColor * (1.0 - metallic);
	float3 specularColor = lerp(0.04, baseColor, metallic);

	roughness = clamp(roughness, 0.02, 0.99);

	float lerpEnvCubeFactor = selectEnvCube == LERP_ENV_MAP ? exp(-distance(pos, gCameraPos)*(1.0 / 500.0)) : 0;

	float3 finalColor = ShadeSolid(pos, sunColor, diffuseColor, specularColor, normal, roughness, metallic, shadow, AO, cloudShadowAO, viewDir, energyLobe, selectEnvCube, lerpEnvCubeFactor, useSSLR, uvSSLR, insideCockpit, bentNormal);

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
