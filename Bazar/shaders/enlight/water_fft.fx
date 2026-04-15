#include "FFT_512.hlsl"

RWTexture2D<float> u_Phase;
RWTexture2DArray<float4> u_Normal;
Texture2DArray<float> u_WindMap;

Texture2DArray<float4> u_NormalRead;
#define u_WindMapWrite u_Phase		// reuse uPhase 

float u_windmapLerp;

float2 u_wind;
uint u_resolution;
float u_size;
float u_deltaTime;
float u_choppiness;

static const float G = 9.81;
static const float KM = 370.0;
static const float CM = 0.23;

float square(float x) {
	return x * x;
}

float omega(float k) {
	return sqrt(G * k * (1.0 + square(k / KM)));
}

float tanh(float x) {
	return (1.0 - exp(-2.0 * x)) / (1.0 + exp(-2.0 * x));
}

float rand(float2 co) {  
	return frac(sin(dot(co.xy, float2(12.9898,78.233))) * 43758.5453);
}

float2 multiplyComplex(float2 a, float2 b) {
	return float2(a[0] * b[0] - a[1] * b[1], a[1] * b[0] + a[0] * b[1]);
}

float2 multiplyByI(float2 z) {
	return float2(-z[1], z[0]);
}

float spectrumInit(float2 coordinates) {
	float n = (coordinates.x < u_resolution * 0.5) ? coordinates.x : coordinates.x - u_resolution;
	float m = (coordinates.y < u_resolution * 0.5) ? coordinates.y : coordinates.y - u_resolution;
	float2 waveVector = (2.0 * PI * float2(n, m)) / u_size;
	float k = length(waveVector) + 1e-9;

	float U10 = length(u_wind);

	float Omega = 0.84;
	float kp = G * square(Omega / U10);

	float c = omega(k) / k;
	float cp = omega(kp) / kp;

	float Lpm = exp(-1.25 * square(kp / k));
	float gamma = 1.7;
	float sigma = 0.08 * (1.0 + 4.0 * pow(Omega, -3.0));
	float Gamma = exp(-square(sqrt(k / kp) - 1.0) / 2.0 * square(sigma));
	float Jp = pow(gamma, Gamma);
	float Fp = Lpm * Jp * exp(-Omega / sqrt(10.0) * (sqrt(k / kp) - 1.0));
	float alphap = 0.006 * sqrt(Omega);
	float Bl = 0.5 * alphap * cp / c * Fp;

	float z0 = 0.000037 * square(U10) / G * pow(U10 / cp, 0.9);
	float uStar = 0.41 * U10 / log(10.0 / z0);
	float alpham = 0.01 * ((uStar < CM) ? (1.0 + log(uStar / CM)) : (1.0 + 3.0 * log(uStar / CM)));
	float Fm = exp(-0.25 * square(k / KM - 1.0));
	float Bh = 0.5 * alpham * CM / c * Fm * Lpm;

	float a0 = log(2.0) / 4.0;
	float am = 0.13 * uStar / CM;
	float Delta = tanh(a0 + 4.0 * pow(c / cp, 2.5) + am * pow(CM / c, 2.5));

	float cosPhi = dot(normalize(u_wind), waveVector / k);

	float S = (1.0 / (2.0 * PI)) * pow(k, -4.0) * (Bl + Bh) * (1.0 + Delta * (2.0 * cosPhi * cosPhi - 1.0));

	float dk = 2.0 * PI / u_size;
	return sqrt(S / 2.0) * dk;
}

[numthreads(32, 32, 1)]
void CS_PHASE(uint2 coordinates : SV_DispatchThreadId) {
	u_Phase[coordinates] = rand(coordinates / float(u_resolution)) * 2.0 * PI;
}

[numthreads(32, 32, 1)]
void CS_SPECTRUM(uint2 coordinates : SV_DispatchThreadId) {

	float n = (coordinates.x < float(u_resolution) * 0.5) ? coordinates.x : coordinates.x - float(u_resolution);
	float m = (coordinates.y < float(u_resolution) * 0.5) ? coordinates.y : coordinates.y - float(u_resolution);
	float2 waveVector = (2.0 * PI * float2(n, m)) / u_size;

	float phase;
	{	// update phase
		float deltaTime = 1.0 / 60.0;
		phase = u_Phase[coordinates.xy];
		float deltaPhase = omega(length(waveVector)) * u_deltaTime;
		phase = fmod(phase + deltaPhase, 2.0 * PI);
		u_Phase[coordinates.xy] = phase;
	}
	{	// update spectrum
		float2 phaseVector = float2(cos(phase), sin(phase));

		float2 h0 = spectrumInit(coordinates.xy);
		float2 h0Star = spectrumInit(u_resolution - coordinates.xy);
		h0Star.y *= -1.0;

		float2 h = multiplyComplex(h0, phaseVector) + multiplyComplex(h0Star, float2(phaseVector.x, -phaseVector.y));

		float rwv = 1.0 / (length(waveVector) + 1e-9);
		float2 hX = -multiplyByI(h * waveVector.x * rwv) * u_choppiness;
		float2 hZ = -multiplyByI(h * waveVector.y * rwv) * u_choppiness;

		hX = hX + multiplyByI(h);
	
		u_FFT[uint3(coordinates.xy, 0)] = hX;
		u_FFT[uint3(coordinates.xy, 1)] = hZ;
	}
}

float3 get_displace(int2 coordinates) {
	coordinates = (-coordinates + u_resolution*2) % u_resolution;
	float2 hX = u_FFT[uint3(coordinates, 0)];
	float2 hZ = u_FFT[uint3(coordinates, 1)];
	return float3(hX.x, (hX.y + hZ.y)*0.5, hZ.x);
}

[numthreads(32, 32, 1)]
void CS_NORMAL(int2 coordinates : SV_DispatchThreadId) {

	float texelSize = u_size / u_resolution;

	float3 center = get_displace(coordinates);

	float3 dx = float3(texelSize, 0, 0) + get_displace(coordinates + int2(1, 0)) - center;
	float3 dy = float3(0, 0, texelSize) + get_displace(coordinates + int2(0, 1)) - center;
	float3 normal = normalize(cross(dy, dx));

	int tx = 30; // gDev0.x;
	float fx1 = get_displace(int2(coordinates) + int2( tx, 0)).z - center.z;
	float fx2 = get_displace(int2(coordinates) + int2(-tx, 0)).z - center.z;
	float fy1 = get_displace(int2(coordinates) + int2( 0, tx)).z - center.z;
	float fy2 = get_displace(int2(coordinates) + int2(0, -tx)).z - center.z;

	// [MOD] Increased foam sensitivity from 0.05 to 0.12.
	// The foam value is saturated to [0,1] before output, so increasing the
	// scale cannot produce values above 1.0; it simply makes the transition
	// from "no foam" to "full foam" happen at lower convergence thresholds.
	float foam = max(-fx1 - fx2 - fy1 - fy2, 0) * max(center.y, 0) * (u_resolution / 256.0 * 0.12);

	float c0 = u_WindMap[uint3(coordinates, 0)];
	float c1 = u_WindMap[uint3(coordinates, 1)];
	float mul = 1.5 - abs(u_windmapLerp - 0.5);
	float windMap = lerp(c0, c1, u_windmapLerp) * mul;

	u_Normal[uint3(coordinates, 0)] = float4(normal.xz, center.y * 0.25, saturate(foam)); // normal + foam
	u_Normal[uint3(coordinates, 1)] = float4(center, windMap); // displace + wind map
}

[numthreads(32, 32, 1)]
void CS_WIND_MAP_SHOT(uint2 coordinates : SV_DispatchThreadId) {
	u_WindMapWrite[coordinates] = u_NormalRead[uint3(coordinates, 1)].x;
}

#define COMMON_CS_PART 		SetVertexShader(NULL);		\
							SetHullShader(NULL);		\
							SetDomainShader(NULL);		\
							SetGeometryShader(NULL);	\
							SetPixelShader(NULL);							

technique10 Tech {
	pass P0	{
		SetComputeShader(CompileShader(cs_5_0, CS_PHASE()));
		COMMON_CS_PART
	}
	pass P1	{
		SetComputeShader(CompileShader(cs_5_0, CS_SPECTRUM()));
		COMMON_CS_PART
	}
	pass P2	{
		SetComputeShader(CompileShader(cs_5_0, CS_FFT(true)));
		COMMON_CS_PART
	}
	pass P3	{
		SetComputeShader(CompileShader(cs_5_0, CS_FFT(false)));
		COMMON_CS_PART
	}
	pass P4	{
		SetComputeShader(CompileShader(cs_5_0, CS_NORMAL()));
		COMMON_CS_PART
	}
	pass P5	{
		SetComputeShader(CompileShader(cs_5_0, CS_WIND_MAP_SHOT()));
		COMMON_CS_PART
	}
}

