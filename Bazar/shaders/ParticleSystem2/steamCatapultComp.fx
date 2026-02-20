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

// V38: anisotropic turbulence ratio — lateral spread is this fraction
// of along-track turbulence. Based on reference footage showing tight
// lateral confinement with strong along-track shearing.
// 0.4 = lateral turbulence at 40% of along-track strength.
static const float lateralTurbulenceRatio = 0.4;

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
	p.reserved.x = t.w * t.w * emitterOpacity * (0.1 + 0.9*particlePower); //max opacity
	p.reserved.y = particlePower;
	p.reserved.w = gModelTime;//birth time

	// V38: per-particle brightness jitter stored in .z of reserved
	// Range: 0.7 to 1.0 — some puffs are dimmer, simulating internal
	// density variation within the steam cloud. rnd.z is already available
	// and uncorrelated with position (rnd.x) and turbulence offset (rnd.y).
	// Combined with the linear lighting opacity fix in GetClusterInfo,
	// this breaks up the flat uniform blob — jitter provides density
	// variation while the lighting system handles directional contrast.
	p.reserved.z = 0.7 + 0.3 * abs(rnd.z);

	// =============================================
	// V38: lifetime — tight range with rare lingerers
	// =============================================
	// Base range: ~0.5-1.9s active, ~0.45-1.5s idle
	// Covers 95% of particles. Real catapult steam dissipates quickly
	// in headwind — most wisps gone within 1-2s. Active launch boost
	// is only 1.25x because launch steam is hotter and under more
	// pressure differential, dispersing faster than idle residual.
	//
	// ~5% of particles get 2x life (lingerers) — dense steam pockets
	// in humid/calm micro-conditions that persist up to ~3.5s.
	// These use rnd.z near extremes (abs > 0.95), which also correlates
	// with high brightness jitter (~0.985) — physically consistent
	// since dense steam lasts longer due to higher thermal mass.
	float baseLife = 1.5 * (0.3 + 0.7*t.w) * (1 + 0.25 * particlePower);
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
	// V37: Size lifecycle - grow, shrink, then fade
	// =============================================

	// Growth phase: 0-50% of life, ease-out curve
	// Fast initial billow that plateaus at peak
	float growthPhase = saturate(nAge / 0.5);
	float easeGrowth  = growthPhase * (2.0 - growthPhase);

	// V37: reduced max growth from 0.4*age to nAge-based 0.45 peak
	// Tighter puffs that don't expand into large blobs
	float maxGrowth = 0.45;
	float peakSize  = 1.0 + maxGrowth;
	float grownSize = 1.0 + maxGrowth * easeGrowth;

	// Shrink phase: 50-85% of life
	// Steam cools and condenses into a tighter wisp before vanishing
	// Shrinks to 60% of peak - visibly tightens without collapsing to nothing
	float shrinkPhase  = saturate((nAge - 0.5) / 0.35);
	float shrinkTarget = peakSize * 0.6;
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