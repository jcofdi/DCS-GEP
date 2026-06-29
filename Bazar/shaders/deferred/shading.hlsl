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

// Shadow-compensated AO: approximate missing local bounce illumination
//   0.0 = disabled, AO always at full strength (stock behavior)
static const float BOUNCE_APPROX_STRENGTH = 0.0;

float compensateAOForMissingBounce(float AO, float shadow)
{
	// Scale AO influence on IBL from full (sunlit) to reduced (shadowed).
	// shadow = 1 → aoScale = 1.0  → effectiveAO = AO  (unchanged)
	// shadow = 0 → aoScale = 0.65 → effectiveAO biased toward 1.0
	float aoScale = lerp(1.0 - BOUNCE_APPROX_STRENGTH, 1.0, shadow);
	return lerp(1.0, AO, aoScale);
}

// Specular occlusion (Lagarde, Moving Frostbite to PBR, 2014)
//
// Empirical approximation that derives specular occlusion from scalar AO,
// roughness, and viewing angle. Correctly returns 1.0 for unoccluded
// surfaces regardless of viewing angle. Smooth surfaces with low AO get
// stronger attenuation; rough surfaces are more forgiving.
//
float SpecularOcclusion(float AO, float roughness, float NoV)
{
    return saturate(pow(NoV + AO, exp2(-16.0 * roughness - 1.0)) - 1.0 + AO);
}

// Multi-bounce specular occlusion (extends Jimenez 2016 Appendix B
// to the specular channel). High-reflectance metallic surfaces in
// concavities retain more specular energy through inter-reflection.
// Same polynomial as MultiBounceAO but driven by specularColor:
// each bounce multiplies by the surface's spectral reflectance,
// so gold tints warm, aluminum stays neutral, dielectrics at 0.04
// get negligible lift.
float3 MultiBounceSpecOcc(float specOcc, float3 specularColor) {
    float3 a = 2.0404 * specularColor - 0.3324;
    float3 b = -4.7951 * specularColor + 0.6417;
    float3 c = 2.7552 * specularColor + 0.6903;
    return max(specOcc, ((specOcc * a + b) * specOcc + c) * specOcc);
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
	float2 energyLobe, float metallic, float3 energyComp, float cloudShadow)
{
	// Dynamic sun disc: cloud cover forward-scatters sunlight into a
	// broader apparent source. Clear sky uses the physical 0.265° radius.
	// Quadratic ramp emphasizes broadening at heavy cloud where
	// forward scattering dominates.
	float cloudInfluence = 1.0 - cloudShadow;
	float sunAngle = lerp(0.00465, 0.12, cloudInfluence * cloudInfluence);
	// Small-angle approximation: cos(x) ≈ 1-x²/2, sin(x) ≈ x
	float sunCosAngle = 1.0 - 0.5 * sunAngle * sunAngle;
	float sunSinAngle = sunAngle;

	// Diffuse: Frostbite renormalized Disney
	float3 H_diff = normalize(gSunDir + viewDir);
	float LdotH_diff = max(0, dot(gSunDir, H_diff));
	float energyBias = lerp(0, 0.5, roughness);
	float energyFactor = lerp(1.0, 1.0 / 1.51, roughness);
	float fd90 = energyBias + 2.0 * LdotH_diff * LdotH_diff * roughness;
	float lightScatter = 1.0 + (fd90 - 1.0) * pow(1.0 - NoL, 5);
	float viewScatter  = 1.0 + (fd90 - 1.0) * pow(1.0 - NoV, 5);
	float Fd = lightScatter * viewScatter * energyFactor;

	// Specular: closest point on sun disc to mirror reflection
	float3 R_sun = reflect(-viewDir, normal);
	float DdotR = dot(gSunDir, R_sun);
	float3 S = R_sun - DdotR * gSunDir;
	float sLen = max(length(S), 1e-6);
	float3 Lspec = DdotR < sunCosAngle
		? normalize(sunCosAngle * gSunDir + (S / sLen) * sunSinAngle)
		: R_sun;

	float3 H_spec = normalize(Lspec + viewDir);
	float NoH_spec = max(0, dot(normal, H_spec));
	float NoL_spec = max(0, dot(normal, Lspec));
	float VoH_spec = max(0, dot(viewDir, H_spec));

	// Fresnel at specular half-vector angle
	float3 F = Fresnel_schlick(specularColor, VoH_spec);

	// Direct sun specular with multi-scatter energy compensation.
	// Microsurface inter-reflections are light-source-agnostic.
	float3 sunSpecular = F
		* (D_ggx(roughness, NoH_spec) * Visibility_smithGGX(roughness, NoV, NoL_spec));
	sunSpecular *= energyComp;

	// Direct sun diffuse Fresnel coupling: (1-F) partitions energy
	// between specular and diffuse for punctual lights. For IBL, the
	// hemispherically integrated E_ms is correct instead.
	float3 kD_direct = (1.0 - F) * (1.0 - metallic);
	float3 sunDiffuse = kD_direct * diffuseColor * Fd * (1.0 / 3.1415926535897932);

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

float3 ShadeSolid(EnvironmentIrradianceSample eis, float3 sunColor, float3 diffuseColor, float3 specularColor, float3 normal, float roughness, float metallic, float shadow, float cloudShadow, float AO, float3 viewDir, float3 pos, float2 energyLobe = float2(1, 1), uniform uint selectEnvCube = LERP_ENV_MAP, float lerpEnvCubeFactor = 0, uniform bool useSSLR = false, float2 uvSSLR = float2(0, 0), uniform bool insideCockpit = false, float bakedAO = 1.0)
{

	// Suppress GTAO convex-surface artifacts at grazing for diffuse IBL.
	float novFade = smoothstep(0.1, 0.3, dot(normal, viewDir));
	float fadedAO = lerp(bakedAO, AO, novFade);

	float roughnessSun = modifyRoughnessByCloudShadow(roughness, cloudShadow);
	float NoL = max(0, dot(normal, gSunDir));
	float NoV = max(0, dot(normal, viewDir)) + 1e-5;

	// ===================================================================
	// Preintegrated BRDF LUT — single fetch drives all energy consumers.
	// Hill-corrected multi-scatter (selfshadow.com 2018, Part 2):
	// Favg² numerator prevents desaturation on colored metals by properly
	// modeling Fresnel compounding across multiple microsurface bounces.
	// ===================================================================
	float2 GF_lut = preintegratedGF.SampleLevel(gBilinearClampSampler, float2(roughness, NoV), 0);
	float Ess = GF_lut.x + GF_lut.y;
	float3 Fss = specularColor * GF_lut.x + saturate(50.0 * specularColor.g) * GF_lut.y;

	// Hemisphere-averaged single-scatter albedo: Eavg is the cosine-weighted
	// mean of Ess over all viewing angles, used by the multi-scatter geometric
	// series. Sampled at NoV=0.5 (~60°, the cosine-weighted mean direction).
	float2 GF_avg = preintegratedGF.SampleLevel(gBilinearClampSampler, float2(roughness, 0.5), 0);
	float Eavg = GF_avg.x + GF_avg.y;

	// Hemisphere-averaged Fresnel (closed-form for Schlick)
	float3 Favg = specularColor + (1.0 / 21.0) * (1.0 - specularColor);
	// Hill's Favg² fix (selfshadow.com 2018, Part 2): each additional bounce
	// attenuates by Favg. Eavg (not Ess) is the escape probability per bounce
	// because inter-microfacet scattering randomizes direction.
	float3 Fms = (Favg * Favg * Eavg) / max(1.0 - Favg * (1.0 - Eavg), 0.001);
	float3 energyComp = 1.0 + Fms * (1.0 / max(Ess, 0.001) - 1.0);

	// Fdez-Agüera (JCGT 2019): multi-scatter energy routed through hemisphere
	// irradiance rather than directional cubemap. Single-scatter retains
	// directional information; multi-scatter has lost it after multiple bounces.
	float3 FmsEms = Fms * (1.0 - Ess);

	// Specular IBL: single-scatter weight (directional cubemap)
	float3 specColor_ss = Fss;

	// Diffuse coupling (Fdez-Agüera eq. for dielectrics):
	// diffuse receives energy not claimed by single-scatter or multi-scatter.
	float3 kD = diffuseColor * (1.0 - (Fss + FmsEms));

	// Direct sun: disc area light with split diffuse/specular evaluation
	// (retains multiplicative energyComp — Dassault f_ms lobe is a future refinement)
	float3 sunBRDF = EvaluateSunBRDF(diffuseColor, specularColor,
		roughnessSun, normal, viewDir, NoL, NoV, energyLobe,
		metallic, energyComp, cloudShadow);
	float microShadow = 1.0;
	if (bakedAO < 0.999) {
		float cosConeAngle = sqrt(1.0 - bakedAO);
		microShadow = saturate(NoL / max(cosConeAngle, 0.001));
		microShadow *= microShadow;
	}
	float3 lightAmount = sunColor * (gSunIntensity * NoL * min(shadow, microShadow)); // using min() for microshadow addition to prevent microshadow from overdarkening any areas previously already in shadow
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
	
	finalColor += (FmsEms + kD) * envLightDiffuse * (gIBLIntensity * iblAO * energyLobe.x);

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

	// Re-tint specular IBL at grazing angles on rough surfaces.
	// Cubemap mip blur destroys directional color at high roughness;
	// the ambient cube retains it. Operates in chromaticity space:
	// only hue shifts, luminance is preserved exactly.
	{
		float rimTintWeight = saturate(roughness - 0.3) * saturate(pow(1.0 - NoV, 3) * 2.0);
		float3 ambientTint = AmbientLight(R);
		float ambientLum  = dot(ambientTint, float3(0.2126, 0.7152, 0.0722));
		float specularLum = dot(envLightSpecular, float3(0.2126, 0.7152, 0.0722));

		float3 specChroma    = envLightSpecular / max(specularLum, 0.001);
		float3 ambientChroma = ambientTint / max(ambientLum, 0.001);
		float3 blendedChroma = lerp(specChroma, ambientChroma, rimTintWeight);
		envLightSpecular = blendedChroma * specularLum;
	}

	// LUT-calibrated specular occlusion. Same Lagarde structure but the
	// exponent comes from the preintegrated BRDF (Ess = single-scatter
	// directional albedo) rather than the empirical exp2(-16r-1) fit.
	// Tight BRDF lobes (high Ess) track AO closely; wide lobes (low Ess)
	// are forgiving because the lobe overlaps most of the visible hemisphere.
	float specOcc = saturate(pow(NoV + fadedAO, exp2(-16.0 * roughness - 1.0)) - 1.0 + fadedAO);
	specOcc = max(specOcc, 0.08);

	// Multi-bounce specular: gate lift by hemisphere visibility.
	// At low AO, minimal light enters the cavity to inter-reflect.
	// At moderate-high AO, inter-reflection is physically meaningful.
	float3 mbSpecOcc = MultiBounceSpecOcc(specOcc, specularColor);
	float mbBlend = smoothstep(0.1, 0.4, fadedAO);
	float3 finalSpecOcc = lerp(specOcc, mbSpecOcc, mbBlend);

	// Single-scatter specular IBL: directional cubemap × Fss (no energyComp).
	// Multi-scatter energy is routed through irradiance above.
	finalColor += envLightSpecular * specColor_ss * (finalSpecOcc * energyLobe.y);

	return finalColor;
}

float3 ShadeSolid(float3 pos, float3 sunColor, float3 diffuseColor, float3 specularColor, float3 normal, float roughness, float metallic, float shadow, float AO, float2 cloudShadowAO, float3 viewDir, float2 energyLobe = float2(1,1), uniform uint selectEnvCube = LERP_ENV_MAP, float lerpEnvCubeFactor = 0, uniform bool useSSLR = false, float2 uvSSLR =  float2(0,0), uniform bool insideCockpit = false, float bakedAO = 1.0)
{
#if	USE_DEBUG_ROUGHNESS_METALLIC
	roughness = clamp(roughness + gDev0.z, 0.02, 0.99);
	metallic = saturate(metallic + gDev0.w);
#endif

	EnvironmentIrradianceSample eis = (EnvironmentIrradianceSample)0;
	if(selectEnvCube != NEAR_ENV_MAP)
		eis = SampleEnvironmentIrradianceApprox(pos, cloudShadowAO.x, cloudShadowAO.y);

	return ShadeSolid(eis, sunColor, diffuseColor, specularColor, normal, roughness, metallic, shadow, cloudShadowAO.x, AO, viewDir, pos, energyLobe, selectEnvCube, lerpEnvCubeFactor, useSSLR, uvSSLR, insideCockpit, bakedAO);
}

float3 ShadeHDR(uint2 sv_pos_xy, float3 sunColor, float3 diffuse,
	float3 normal, float roughness, float metallic, float3 emissive,
	float shadow, float AO, float2 cloudShadowAO, float3 viewDir,
	float3 pos, float2 energyLobe = {1,1},
	uniform uint selectEnvCube = LERP_ENV_MAP,
	uniform bool useSSLR = false,
	float2 uvSSLR = float2(0, 0),
	uniform uint LightsList = LL_SOLID,
	uniform bool insideCockpit = false,
	uniform bool useSecondaryShadowmap = false,
	float bakedAO = 1.0)
{
	float3 baseColor = GammaToLinearSpace(diffuse);

	float3 diffuseColor = baseColor * (1.0 - metallic);
	float3 specularColor = lerp(0.04, baseColor, metallic);

	roughness = clamp(roughness, 0.02, 0.99);

	float lerpEnvCubeFactor = selectEnvCube == LERP_ENV_MAP ? exp(-distance(pos, gCameraPos)*(1.0 / 500.0)) : 0;

	float3 finalColor = ShadeSolid(pos, sunColor, diffuseColor, specularColor, normal, roughness, metallic, shadow, AO, cloudShadowAO, viewDir, energyLobe, selectEnvCube, lerpEnvCubeFactor, useSSLR, uvSSLR, insideCockpit, bakedAO);

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
