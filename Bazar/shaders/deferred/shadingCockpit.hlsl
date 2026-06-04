#ifndef SHADING_COCKPIT_HLSL
#define SHADING_COCKPIT_HLSL

#include "deferred/shading.hlsl"
#include "indirectLighting/indirectLighting.hlsl"

float3 SampleCockpitEnvironmentMap(float3 normal, float roughness, float mip, uniform bool bSpecularSample = false)
{
	const float3 cockpitFloorNormal = cockpitTransform._12_22_32;

	float NoF = dot(normal, cockpitFloorNormal);

	float cockpitAO = (bSpecularSample? 0.4 : 1.0) * saturate((NoF*0.5+0.5)*1.3 + 0.2);

	float3 incomingLight = SampleEnvironmentMapDetailed(cockpitFloorNormal, mip + 0.5);

	float3 envColor = SampleEnvironmentMapDetailed(normal, mip);
	float3 averageSecondaryLight = dot(incomingLight, 0.3333*cockpitAO);

	roughness = pow(roughness, 0.20);
	
	float mask = 0.95 - 0.95 * (bSpecularSample? saturate(0.2 + 0.55 * roughness + (3.0 - 2.2 * roughness) * NoF) : //blur env cube mask by roughness
									  saturate(0.2 + 0.8 * NoF));									  

	envColor = lerp(envColor, averageSecondaryLight, mask);

	return envColor;
}

float3 getEnvLightColor(float3 normal, float roughness, uniform bool useSSLR, float2 uvSSLR) {
	float roughnessMip = getMipFromRoughness(roughness, environmentMipsCount);
	float3 envLightColor = SampleCockpitEnvironmentMap(normal, roughness, roughnessMip, true);
	if (useSSLR) {
		float4 sslr = SSLRMap.SampleLevel(ClampLinearSampler, uvSSLR, roughnessMip / 2);
		envLightColor = lerp(envLightColor, sslr.rgb, sslr.a);
	}
	return envLightColor;
}

float3 ShadeSolidCockpitGI(float3 sunColor, float3 diffuseColor, float3 specularColor, float3 normal, float roughness, float metallic, float shadow, float cloudShadow, float AO, float3 viewDir, float3 pos, float2 energyLobe = float2(1,1), uniform bool useSSLR = false, float2 uvSSLR = float2(0, 0), float bakedAO = 1.0)
{
	bool hasBentNormal = dot(bentNormal, bentNormal) > 0.5;

	float roughnessSun = modifyRoughnessByCloudShadow(roughness, cloudShadow);
	float NoL = max(0, dot(normal, gSunDir));
	float NoV = max(0, dot(normal, viewDir)) + 1e-5;

	// Suppress GTAO convex-surface artifacts at grazing for diffuse IBL.
	float novFade = smoothstep(0.1, 0.4, dot(geoNormal, viewDir));
	float fadedAO = lerp(bakedAO, AO, novFade);

	// Hill-corrected multi-scatter energy (see ShadeSolid for derivation)
	float2 GF_lut = preintegratedGF.SampleLevel(gBilinearClampSampler, float2(roughness, NoV), 0);
	float Ess = GF_lut.x + GF_lut.y;
	float3 Fss = specularColor * GF_lut.x + saturate(50.0 * specularColor.g) * GF_lut.y;
	float2 GF_avg = preintegratedGF.SampleLevel(gBilinearClampSampler, float2(roughness, 0.5), 0);
	float Eavg = GF_avg.x + GF_avg.y;
	float3 Favg = specularColor + (1.0 / 21.0) * (1.0 - specularColor);
	float3 Fms = (Favg * Favg * Eavg) / max(1.0 - Favg * (1.0 - Eavg), 0.001);
	float3 energyComp = 1.0 + Fms * (1.0 / max(Ess, 0.001) - 1.0);

	// Fdez-Agüera (JCGT 2019): multi-scatter through irradiance
	float3 FmsEms = Fms * (1.0 - Ess);
	float3 specColor_ss = Fss;
	float3 kD = diffuseColor * (1.0 - (Fss + FmsEms));

	// Direct sun
	float3 sunBRDF = EvaluateSunBRDF(diffuseColor, specularColor,
		roughnessSun, normal, viewDir, NoL, NoV, energyLobe,
		metallic, energyComp, cloudShadow);

	// Baked AO micro-shadow on direct sun
	float microShadow = 1.0;
	if (bakedAO < 0.999) {
		float cosConeAngle = sqrt(1.0 - bakedAO);
		microShadow = saturate(NoL / max(cosConeAngle, 0.001));
		microShadow *= microShadow;
	}
	float3 lightAmount = sunColor * (gSunIntensity * NoL
		* min(shadow, microShadow));
	float3 finalColor = sunBRDF * lightAmount;

	// IBL AO
	float iblAO = compensateAOForMissingBounce(fadedAO, shadow);

	//sun IBL
	//todo: умножение на sunColor унести в предрасчет
	float4 indirectSunLightAO = CalculateIndirectSunLight(pos, normal);
	finalColor += diffuseColor * indirectSunLightAO.rgb * sunColor;

	//diffuse IBL
#if 0 // USE_COCKPIT_CUBEMAP
	float3 envLightDiffuse = SampleCockpitCubeMapMip(pos, normal, environmentMipsCount) * gCockpitIBL.x;
#else
	float3 envLightDiffuse = SampleCockpitEnvironmentMap(normal, roughness, environmentMipsCount) * gCockpitIBL.z;
#endif

	float3 mbAO = MultiBounceAO(iblAO, diffuseColor);
	float diffMBBlend = smoothstep(0.15, 0.6, iblAO);
	mbAO = lerp(iblAO, mbAO, diffMBBlend * 0.333);
	finalColor += (FmsEms + kD) * envLightDiffuse * (indirectSunLightAO.a * mbAO);

	//specular IBL
	float a = roughness * roughness;
	float3 R = normal*NoV*2 - viewDir;
	R = normalize( lerp( normal, R, (1 - a) * ( sqrt(1 - a) + a ) ) );
	// float4 specularAO = cockpitAOMap.SampleLevel(ClampLinearSampler, -R, 6);
	
#if 0
	// float3 viewDir = pos - CamPos;
	float3 rdir = -reflect(viewDir, normal);
	//BPCEM
	float3 nrdir = normalize(rdir);
	float3 rbmax = (ILVBBmax - pos)/nrdir;
	float3 rbmin = (ILVBBmin - pos)/nrdir;
	float3 rbminmax = (nrdir>0.0f)? rbmax : rbmin;
	float fa = min(min(rbminmax.x, rbminmax.y), rbminmax.z);
	float3 posonbox = pos + nrdir*fa;
	rdir = posonbox - float3(0,0,0);
	//PBCEM end
	// float3 env = texCUBE(envMap, rdir);
	float3 envLightSpecular = cockpitEnvironmentMap.SampleLevel(ClampLinearSampler, rdir, getMipFromRoughness(roughness, environmentMipsCount)).rgb;
	// float3 envLightColor = cockpitEnvironmentMap.SampleLevel(ClampLinearSampler, R, getMipFromRoughness(roughness, environmentMipsCount)).rgb;
#else
	#if USE_COCKPIT_CUBEMAP
		float3 envLightSpecular = SampleCockpitCubeMap(pos, R, roughness) * gCockpitIBL.y;
	#else
		float3 envLightSpecular = getEnvLightColor(R, roughness, useSSLR, uvSSLR);
	#endif
#endif

	// Rim tinting (see ShadeSolid for derivation)
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

	// LUT-calibrated specular occlusion (see ShadeSolid for derivation)
	float specOcc = saturate(pow(NoV + fadedAO, Ess) - 1.0 + fadedAO);
	specOcc = max(specOcc, 0.08);

	float3 mbSpecOcc = MultiBounceSpecOcc(specOcc, specularColor);
	float mbBlend = smoothstep(0.2, 0.5, fadedAO) * 0.333;
	float3 finalSpecOcc = lerp(specOcc, mbSpecOcc, mbBlend);
	finalColor += envLightSpecular * specColor_ss * (finalSpecOcc * indirectSunLightAO.a * energyLobe.y);

	return finalColor;
}

float3 ShadeSolidCockpit(float3 sunColor, float3 diffuseColor, float3 specularColor, float3 normal, float roughness, float metallic, float shadow, float cloudShadow, float AO, float3 viewDir, float3 pos, float2 energyLobe = float2(1, 1), uniform bool useSSLR = false, float2 uvSSLR = float2(0, 0), float bakedAO = 1.0) {

	bool hasBentNormal = dot(bentNormal, bentNormal) > 0.5;

	float roughnessSun = modifyRoughnessByCloudShadow(roughness, cloudShadow);
	float NoL = max(0, dot(normal, gSunDir));
	float NoV = max(0, dot(normal, viewDir)) + 1e-5;

	// Grazing-angle AO fade (see ShadeSolid for full bent-normal variant)
	float fadedAO = lerp(1.0, AO, smoothstep(0.1, 0.4, dot(normal, viewDir)));

	// Hill-corrected multi-scatter energy (see ShadeSolid for derivation)
	float2 GF_lut = preintegratedGF.SampleLevel(gBilinearClampSampler, float2(roughness, NoV), 0);
	float Ess = GF_lut.x + GF_lut.y;
	float3 Fss = specularColor * GF_lut.x + saturate(50.0 * specularColor.g) * GF_lut.y;
	float2 GF_avg = preintegratedGF.SampleLevel(gBilinearClampSampler, float2(roughness, 0.5), 0);
	float Eavg = GF_avg.x + GF_avg.y;
	float3 Favg = specularColor + (1.0 / 21.0) * (1.0 - specularColor);
	float3 Fms = (Favg * Favg * Eavg) / max(1.0 - Favg * (1.0 - Eavg), 0.001);
	float3 energyComp = 1.0 + Fms * (1.0 / max(Ess, 0.001) - 1.0);

	// Fdez-Agüera (JCGT 2019): multi-scatter through irradiance
	float3 FmsEms = Fms * (1.0 - Ess);
	float3 specColor_ss = Fss;
	float3 kD = diffuseColor * (1.0 - (Fss + FmsEms));

	// Direct sun
	float3 sunBRDF = EvaluateSunBRDF(diffuseColor, specularColor,
		roughnessSun, normal, viewDir, NoL, NoV, energyLobe,
		metallic, energyComp, cloudShadow);

	// Baked AO micro-shadow on direct sun
	float microShadow = 1.0;
	if (bakedAO < 0.999) {
		float cosConeAngle = sqrt(1.0 - bakedAO);
		microShadow = saturate(NoL / max(cosConeAngle, 0.001));
		microShadow *= microShadow;
	}
	float3 lightAmount = sunColor * (gSunIntensity * NoL
		* min(shadow, microShadow));
	float3 finalColor = sunBRDF * lightAmount;

	// IBL AO
	float iblAO = compensateAOForMissingBounce(fadedAO, shadow);

	float a = roughness * roughness;
	float3 R = normal * NoV * 2 - viewDir;
	R = normalize(lerp(normal, R, (1 - a) * (sqrt(1 - a) + a)));

	//diffuse IBL
#if USE_COCKPIT_CUBEMAP
	float3 envLightDiffuse = SampleCockpitCubeMapMip(pos, normal, environmentMipsCount) * gCockpitIBL.x;

	#if USE_DEBUG_COCKPIT_CUBEMAP 
		float3 oldLightDiffuse = SampleCockpitEnvironmentMap(normal, roughness, environmentMipsCount);
		envLightDiffuse = gDev0.x > 0.5 ? oldLightDiffuse : envLightDiffuse;
	#endif
#else
	float3 envLightDiffuse = SampleCockpitEnvironmentMap(normal, roughness, environmentMipsCount);
#endif

	float3 mbAO = MultiBounceAO(iblAO, diffuseColor);
	float diffMBBlend = smoothstep(0.15, 0.6, iblAO);
	mbAO = lerp(iblAO, mbAO, diffMBBlend * 0.333);
	finalColor += (FmsEms + kD) * envLightDiffuse * (gIBLIntensity * mbAO * energyLobe.x);

	//specular IBL
#if USE_COCKPIT_CUBEMAP

	#if USE_DEBUG_COCKPIT_CUBEMAP 
		if (gDev1.y > 0.5)
			roughness = 0;
	#endif

	float3 envLightSpecular = SampleCockpitCubeMap(pos, R, roughness) * gCockpitIBL.y;

	#if USE_DEBUG_COCKPIT_CUBEMAP 
		if (gDev1.x > 0.5)
			return envLightSpecular;
		float3 oldLightSpecular = SampleCockpitEnvironmentMap(normal, roughness, getMipFromRoughness(roughness, environmentMipsCount), true);
		envLightSpecular = gDev0.y > 0.5 ? oldLightSpecular : envLightSpecular;
	#endif
#else
	float3 envLightSpecular = getEnvLightColor(R, roughness, useSSLR, uvSSLR);
#endif

	// Rim tinting (see ShadeSolid for derivation)
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

	// LUT-calibrated specular occlusion (see ShadeSolid for derivation)
	float specOcc = saturate(pow(NoV + fadedAO, Ess) - 1.0 + fadedAO);
	specOcc = max(specOcc, 0.08);

	float3 mbSpecOcc = MultiBounceSpecOcc(specOcc, specularColor);
	float mbBlend = smoothstep(0.2, 0.5, fadedAO) * 0.333;
	float3 finalSpecOcc = lerp(specOcc, mbSpecOcc, mbBlend);
	finalColor += envLightSpecular * specColor_ss * (finalSpecOcc * energyLobe.y);

	return finalColor;
}

// #define USE_VS_GI

float3 ShadeCockpit(uint2 uv, uniform bool bApplyGI, float3 sunColor, float3 diffuse, float3 normal, float roughness, float metallic, float3 emissive, float shadow, float AO, float2 cloudShadowAO, float3 viewDir, float3 pos,
					float2 energyLobe = float2(1,1), uniform bool bTransparent = false, float alpha = 1.0, uniform bool useSSLR = false, float2 uvSSLR = float2(0, 0), float bakedAO = 1.0)
{
#if	USE_DEBUG_ROUGHNESS_METALLIC
	roughness = clamp(roughness + gDev0.z, 0.02, 0.99);
	metallic = saturate(metallic + gDev0.w);
#endif

	float3 baseColor = GammaToLinearSpace(diffuse);

	float3 diffuseColor = baseColor * (1.0 - metallic);
	float3 specularColor = lerp(bApplyGI ? 0.035 : 0.03, baseColor, metallic);

	roughness = clamp(roughness, 0.02, 0.99);

	if(bTransparent) //альфа-блендинг не должен влиять на силу спекулярного света, компенсируем
		energyLobe.y *= rcp(max(1.0 / 255.0, alpha));

	float3 finalColor;

#ifndef USE_VS_GI
	if(bApplyGI)
		finalColor = ShadeSolidCockpitGI(sunColor, diffuseColor, specularColor, normal, roughness, metallic, shadow, cloudShadowAO.x, AO, viewDir, pos, energyLobe, useSSLR, uvSSLR, bakedAO);
	else
#endif
		finalColor = ShadeSolidCockpit(sunColor, diffuseColor, specularColor, normal, roughness, metallic, shadow, cloudShadowAO.x, AO, viewDir, pos, energyLobe, useSSLR, uvSSLR, bakedAO);

	finalColor += CalculateDynamicLightingTiled(uv, diffuseColor, specularColor, roughness, normal, viewDir, pos, 1, float2(1, 1), 0, bTransparent ? LL_TRANSPARENT : LL_SOLID);

#ifndef USE_VS_GI
	finalColor += emissive;
#else
	finalColor += emissive * diffuseColor * sunColor;//* (gSunIntensity * gILVSunFactor);
#endif

	return finalColor;
}

#endif
