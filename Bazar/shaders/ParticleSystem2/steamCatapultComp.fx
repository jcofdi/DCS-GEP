#include "common/random.hlsl"
#include "common/samplers11.hlsl"

#define CLUSTER_NO_LOCAL_MATRIX
#define CLUSTER_NO_WORLD_MATRIX
#include "ParticleSystem2/common/clusterComputeCommon.hlsl"

#define NO_DEFAULT_UNIFORMS
#include "ParticleSystem2/common/psCommon.hlsl"
#include "ParticleSystem2/common/perlin.hlsl"
#include "ParticleSystem2/common/motion.hlsl"
#include "ParticleSystem2/common/noiseSimplex.hlsl"

// RWBuffer<uint>						sbIndirectArgs;

StructuredBuffer<PuffCluster>		sbParticlesInput;	//current state
RWStructuredBuffer<PuffCluster>		sbParticles;		//next state
RWStructuredBuffer<uint>			sbSortedIndices;

Texture2D noiseTex;

float4	emitterParams;//emitter time, phase, wind.xy
float4	emitterParams2;
float	emitterParams3;
float3	startPos;
uint	emitterParamsInt;
float3	endPos;
float4	worldOffset; //xyz - world offset, w - dt

float4x4 World;

#define emitterTime		emitterParams.x
#define noiseSpeed		emitterParams.y
#define windVel			(emitterParams.zw)

#define emitterOpacity	emitterParams2.x
#define dT				emitterParams2.y
#define particleSize	emitterParams2.w

#define steamPower		emitterParams2.z
#define shuttlePos		emitterParams3.x

// V36+: increased from 5 for violent chaotic movement
static const float turbulencePower = 10;
static const float distMax = 1.5 * 1.5;//макс расстояние от линии

// V38: anisotropic turbulence ratio - lateral spread is this fraction
// of along-track turbulence. Based on reference footage showing tight
// lateral confinement with strong along-track shearing.
// 0.4 = lateral turbulence at 40% of along-track strength.
static const float lateralTurbulenceRatio = 0.9;

// =============================================
// V39: Weather-responsive steam conditions
// =============================================
// Derives a 0-1 modulation factor from mission weather and time of day.
// At conditions=1.0, all downstream values reproduce V38 behavior exactly.
// The factor only reduces steam intensity - never exceeds current maximums.
//
// Primary driver: gCloudiness (0=clear to ~800+=overcast)
//   Overcast holds surface temps lower, implies higher relative humidity,
//   and suppresses radiative warming - steam lingers and billows.
//
// Secondary driver: gSunDir.y (sine of sun elevation)
//   Low sun = cooler ambient air = larger delta-T between steam and air
//   = more visible condensation. Dawn/dusk cat shots produce more steam.
//
// Not available at shader level: temperature, humidity, season, latitude.
// gSunAttenuation tested and rejected (pure geometric extinction, not weather).
float computeSteamConditions()
{
	// Sun elevation: low sun = cooler ambient = more steam
	// gSunDir.y: ~0.048 (dawn/dusk) to ~0.912 (noon)
	// Caps at 0.85 - clear night alone cannot reach maximum steam.
	// Clouds are required to push past ~0.85 toward 1.0.
	// This prevents clear desert nights from producing full steam
	// while preserving the strong dawn/dusk vs noon contrast.
	float sunCool = 0.85 - saturate(gSunDir.y) * 0.25;

	// Cloud cover: overcast = cooler + more humid = steam lingers
	// gCloudiness: 0 (clear) to ~800+ (overcast/broken)
	// Normalize to 0..1, treat 900+ as fully overcast
	// 50% boost at full overcast - strongest real signal available
	// This is the gatekeeper for maximum steam: only cloud cover
	// plus low sun elevation can produce conditions = 1.0.
	float cloudNorm = saturate(gCloudiness / 900.0);
	float cloudCool = 1.0 + cloudNorm * 0.5;

	// Combined range: ~0.60 (noon clear) to ~1.28 (dawn overcast) -> clamped 0..1
	return saturate(sunCool * cloudCool);
}

float DistToLine(float2 pt1, float2 pt2, float2 testPt)
{
	float2 lineDir = pt2 - pt1;
	float2 perpDir = float2(lineDir.y, -lineDir.x);
	float2 dirToPt1 = pt1 - testPt;
	return abs(dot(normalize(perpDir), dirToPt1));
}

float DistToLineSq(float2 a, float2 b, float2 p)
{
	float2 n = b - a;
	float2 pa = a - p;
	float2 c = n * (dot( pa, n ) / dot( n, n ));
	float2 d = pa - c;
	return dot( d, d );
}

// V36+: per-particle uniqueOffset breaks coherent snaking
// V36+: noise scrolls on both UV axes for more organic movement
float4 getTurbulence(float3 pos, float uniqueOffset)
{
	float scale = 0.05;
	float2 uv = pos.xz * scale * 0.1
	           + float2(gModelTime * 0.1 * noiseSpeed, gModelTime * 0.07 * noiseSpeed)
	           + uniqueOffset;
	return noiseTex.SampleLevel(gBilinearWrapSampler, uv, 0);
}

PuffCluster initParticle(PuffCluster p, float3 from, float3 to, uint id)
{
	float uniqueId = p.sizeLifeOpacityRnd.w*14.8512364917 + gModelTime;

	float4 rnd = noise4((uniqueId + float4(0, 0.612312932, 0.22378683, 0.5312313)) * float4(1, 1.5231, 1.125231, 1.65423));

	p.posRadius.xyz = lerp(from, to, rnd.x);

	// V36+: reduced from particleSize*0.25 so particles spawn at slot level
	p.posRadius.y += particleSize * 0.05;

	// Original shuttle-following logic preserved exactly
	float particlePower = steamPower * step(rnd.x, shuttlePos);

	// V36+: pass rnd.y as unique offset per particle
	float4 t = getTurbulence(p.posRadius.xyz, rnd.y);

	p.reserved.x = pow(t.w, 3.0 - 2.0*particlePower); //max opacity

	// =============================================
	// V39: Weather-responsive spawn suppression
	// =============================================
	// Primary "less steam" lever: under dry conditions, a percentage of
	// particles spawn as invisible ghosts (zero opacity). They still
	// simulate in the buffer — no way around that with a fixed pool —
	// but contribute nothing visually. This reduces visible particle
	// count without compressing spatial distribution: surviving particles
	// retain full V38 lifetime, rise, drift, turbulence, and shear.
	//
	// Spawn rate uses conditions^2 for an aggressive but smooth curve:
	//   conditions=1.00 (overcast dawn)  -> 100% visible
	//   conditions=0.85 (clear night)    ->  72% visible
	//   conditions=0.60 (clear noon)     ->  36% visible
	//
	// Idle particles (particlePower~0) get additional suppression via
	// double-squaring the spawn rate. Active launch steam is pressurized
	// and blasts through regardless of ambient conditions. Idle leakage
	// is residual heat meeting ambient air — far more weather-sensitive.
	//   Clear noon active: 36% spawn  |  Clear noon idle: 13% spawn
	//   Overcast dawn:    100% spawn  |  Overcast idle:  100% spawn
	float conditions = computeSteamConditions();
	float spawnRate = conditions * conditions;
	// Idle: square again for aggressive suppression; active: unchanged
	spawnRate = lerp(spawnRate * spawnRate, spawnRate, particlePower);
	// rnd.w is the 4th noise channel — already computed, unused elsewhere
	// in initParticle. Gives each particle a stable coin flip at birth:
	// either fully visible or ghost for its entire lifetime. No flickering.
	float spawnChance = step(rnd.w, spawnRate);

	// V39: mild opacity scaling on surviving particles
	// Gives visible wisps a slightly thinner, more translucent quality
	// under dry conditions without changing their spatial behavior.
	//   conditions=1.0 -> opacityScale = 1.0 (unchanged)
	//   conditions=0.6 -> opacityScale = 0.82
	float opacityScale = lerp(0.7, 1.0, conditions);

	p.reserved.x = t.w * t.w * emitterOpacity * (0.1 + 0.9*particlePower) * spawnChance * opacityScale;
	p.reserved.y = particlePower;
	p.reserved.w = gModelTime;//birth time

	// V38: per-particle brightness jitter stored in .z of reserved
	// Range: 0.7 to 1.0 ...
	p.reserved.z = 0.7 + 0.3 * abs(rnd.z);

	// =============================================
	// V39: lifetime - V38 range with weather modulation
	// =============================================
	// Base behavior identical to V38 at conditions=1.0.
	// Under dry/hot conditions (low factor), lifetime contracts:
	//   conditions=1.0 -> lifetime multiplier = 1.0 (unchanged)
	//   conditions=0.7 -> lifetime multiplier = 0.82
	//   conditions=0.6 -> lifetime multiplier = 0.76
	// This means fewer particles alive simultaneously under dry conditions,
	// reading as "less steam" without changing the particle count.
	// Lingerer logic preserved - 5% still get 2x life regardless,
	// but their absolute duration also scales with conditions.
	float baseLife = 1.5 * (0.3 + 0.7*t.w) * (1 + 0.25 * particlePower) * lerp(0.4, 1.0, conditions);
	float lingerChance = step(0.95, abs(rnd.z)); // ~5% of particles
	float lingerBoost = 1.0 + lingerChance * 1.0; // 2x life for lingerers
	p.sizeLifeOpacityRnd.y = baseLife * lingerBoost;
	
	return p;
}

PuffCluster updateParticle(PuffCluster p, uint id, float distFromLineSq)
{
	// V36+: per-particle offset from birth time breaks snaking in update too
	float uniqueOffset = p.reserved.w * 0.37;
	float4 t = getTurbulence(p.posRadius.xyz, uniqueOffset);
	
	float distFromLine = sqrt(distFromLineSq);
	float age = gModelTime - p.reserved.w;
	float nAge = age / p.sizeLifeOpacityRnd.y;

	float windPower = length(windVel);

	// =============================================
	// V38: anisotropic turbulence
	// =============================================
	// Headwind creates turbulent eddies primarily in the along-track
	// direction. Lateral spread is driven by secondary vortices and is
	// significantly weaker. Decompose noise into track-aligned and
	// perpendicular components, scaling lateral by lateralTurbulenceRatio.
	// This keeps the violent along-track shearing while producing the
	// tight lateral confinement seen in carrier deck reference footage.
	//
	// Safety check: if startPos and endPos are too close (degenerate track),
	// fall back to dampened isotropic turbulence to avoid NaN from normalize.
	// NaN wouldn't crash the GPU but would cause particles to vanish and
	// z-sort anomalies from undefined radix sort keys.
	float2 noiseDir = (t.xy * 2 - 1) * (t.z * 2 - 1);

	float2 trackVec = endPos.xz - startPos.xz;
	float trackLen = length(trackVec);

	if (trackLen > 0.1)
	{
		float2 trackDir = trackVec / trackLen;
		float2 lateralDir = float2(-trackDir.y, trackDir.x);

		float alongComponent = dot(noiseDir, trackDir);
		float lateralComponent = dot(noiseDir, lateralDir);

		noiseDir = trackDir * alongComponent
		         + lateralDir * lateralComponent * lateralTurbulenceRatio;
	}
	else
	{
		// Fallback: isotropic but at reduced power (~60% of full)
		// to approximate the average of anisotropic behavior
		noiseDir *= 0.6;
	}

	p.posRadius.xz += noiseDir * dT * turbulencePower * (0.5 + 0.5 * saturate(windPower));
	p.posRadius.xz += windVel * dT * (0.2 + 0.8 * saturate(p.posRadius.y*0.5));

	// V37: rise rate back up to 0.4 - shorter life means less total drift
	// but steam still rises visibly before dying
	p.posRadius.y += p.reserved.x * dT * 0.4 * (1 + windPower*0.08);

	// =============================================
	// V39: Size lifecycle - grow, shrink, then fade
	// (weather-modulated growth and shrink)
	// =============================================

	// V39: recompute conditions (deterministic, cheap - no texture fetches)
	float conditions = computeSteamConditions();

	// Growth phase: 0-50% of life, ease-out curve
	// Fast initial billow that plateaus at peak
	float growthPhase = saturate(nAge / 0.5);
	float easeGrowth  = growthPhase * (2.0 - growthPhase);

	// V39: growth modulated by conditions
	// At conditions=1.0: maxGrowth = 0.45 (unchanged from V38)
	// At conditions=0.6: maxGrowth = 0.45 * 0.91 = 0.41
	// Under dry/hot conditions, puffs billow less — tighter condensation
	// plume due to faster turbulent mixing with hotter ambient air.
	// Mild range (0.85-1.0) preserves spatial character while visibly
	// tightening the puffs. Combined with spawn suppression, the few
	// visible wisps under dry conditions are noticeably smaller.
	float maxGrowth = 0.45 * lerp(0.85, 1.0, conditions);
	float peakSize  = 1.0 + maxGrowth;
	float grownSize = 1.0 + maxGrowth * easeGrowth;

	// Shrink phase: 50-85% of life
	// V39: shrink target modulated by conditions
	// At conditions=1.0: shrinkTarget = peakSize * 0.60 (unchanged from V38)
	// At conditions=0.6: shrinkTarget = peakSize * 0.50
	// Under dry conditions, steam evaporates faster at droplet edges —
	// wisps tighten more aggressively before vanishing.
	float shrinkPhase  = saturate((nAge - 0.5) / 0.35);
	float shrinkTarget = peakSize * lerp(0.40, 0.6, conditions);
	float sizeFactor   = lerp(grownSize, shrinkTarget, shrinkPhase);
	
	p.sizeLifeOpacityRnd.x = particleSize * sizeFactor * (1 + 2.0*p.reserved.y);

	// =============================================
	// V37: Opacity - "steam or not" sharp cutoff
	// =============================================

	// Fast fade-in (age*4 unchanged)
	// V37: fade-out over last 15% of life only (was 50%)
	// Steam stays opaque until it hits ambient temp then cuts off quickly
	// Note: /sizeFactor naturally brightens slightly during shrink phase
	// as denominator decreases - wisp appears to intensify before vanishing
	// V38: multiply by per-particle brightness jitter (reserved.z)
	p.sizeLifeOpacityRnd.z  = saturate(age*4) * saturate((1-nAge)/0.15);
	p.sizeLifeOpacityRnd.z *= saturate(1 - (distFromLine - distMax*0.7) / (distMax - distMax*0.7)) / sizeFactor * p.reserved.x * p.reserved.z;

	return p;
}

void simulate(uint gi)
{
	PuffCluster p0 = sbParticlesInput[gi];

	float age = gModelTime - p0.reserved.w;
	float distFromLineSq = DistToLine(startPos.xz, endPos.xz, p0.posRadius.xz) * (1-0.5*p0.reserved.x*p0.reserved.x) * (1-0.7 * p0.reserved.y);
	
	if(distFromLineSq>distMax || age>p0.sizeLifeOpacityRnd.y)
	{
		p0 = initParticle(p0, startPos, endPos, gi);
	}

	sbParticles[gi] = updateParticle(p0, gi, distFromLineSq);
}

[numthreads(THREAD_X, THREAD_Y, 1)]
void csSteamCatapult(uint gi : SV_GroupIndex)
{
	simulate(gi);
}

technique11 techSteamCatapult
{
	pass { SetComputeShader( CompileShader( cs_5_0, csSteamCatapult() ) );	}
}

#define RADIX_BIT_MAX			31
// #define RADIX_BIT_MIN		26
// #define RADIX_BIT_MIN		20
#define RADIX_BIT_MIN			15

#define RADIX_OUTPUT_BUFFER		sbSortedIndices
#define RADIX_THREAD_X			THREAD_X
#define RADIX_THREAD_Y			THREAD_Y
#define RADIX_TECH_NAME			techRadixSort
#define RADIX_KEY_FUNCTION_BODY(id) \
	float3 p = sbParticles[id].posRadius.xyz + worldOffset.xyz  - gCameraPos.xyz; \
	return floatToUInt(dot(p,p));
// #define RADIX_NO_LOCAL_INDICES
#define RADIX_NO_COMPUTE_SHADER
#include "ParticleSystem2/common/radixSort.hlsl"

void GetClusterInfo(uint id, out float3 pos, out float radius, out float opacity)
{
	float4 posRadius = sbParticles[id].posRadius;
	float4 sizeLifeOpacityRnd = sbParticles[id].sizeLifeOpacityRnd;

	pos     = posRadius.xyz;
	radius  = sizeLifeOpacityRnd.x;// + posRadius.w;
	// V38: linear opacity for lighting instead of squared (was z * z * 0.4)
	// Squared opacity compressed the range too much, making the lighting
	// system see all mid-opacity particles as nearly transparent. This
	// reduced light/shadow contrast across the cloud, contributing to the
	// flat uniform blob appearance. Linear response lets the cluster lighting
	// system properly differentiate sun-facing vs shadow-facing particles.
	opacity = sizeLifeOpacityRnd.z * 0.6;
}

#define LIGHTING_OUTPUT(id)				sbParticles[id].clusterLightAge.x
#define LIGHTING_THREAD_X				THREAD_X
#define LIGHTING_THREAD_Y				THREAD_Y
#define LIGHTING_TECH_NAME				techLighting
#define LIGHTING_PARTICLE_GET_FUNC		GetClusterInfo
#define LIGHTING_FLAGS					(LF_CLUSTER_OPACITY /*| LF_NEW_DECAY */ | LF_NO_COMPUTE_SHADER /*| LF_CASCADE_SHADOW*/)
#define LIGHTING_WORLD_OFFSET			(worldOffset.xyz)
#include "ParticleSystem2/common/clusterLighting.hlsl"

[numthreads(THREAD_X, THREAD_Y, 1)]
void csSortAndLight(uint GI: SV_GroupIndex)
{
	ParticleLightInfo p = GetParticleLightInfo(techLighting)(GI);

	//шейдер выполняется чутка быстрее если сначала идет освещенк�� и потом сортировка
	LIGHTING_OUTPUT(GI) = ComputeLightingInternal(techLighting)(GI, p, 0.9, 0, 0, LIGHTING_FLAGS);

	float3 s = p.pos.xyz + worldOffset.xyz - gCameraPos.xyz;
	float sortKey = floatToUInt(dot(s, s));	
	ComputeRadixSortInternal(RADIX_TECH_NAME)(GI, sortKey);
}

technique11 techSortAndLight
{
	pass { SetComputeShader(CompileShader(cs_5_0, csSortAndLight()));	}
}