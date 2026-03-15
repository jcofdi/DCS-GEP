#include "common/samplers11.hlsl"
#include "common/states11.hlsl"
#include "common/context.hlsl"
#include "ParticleSystem2/common/perlin.hlsl"
#include "ParticleSystem2/common/hotAirCommon.hlsl"

Texture2D<float2> HeatMap;
Texture3D<float2> HeatTex;
Texture2D<float> DepthMap;

Texture2D Source;

int2 	Dims;
float4	viewport;
float	time;

static const float2 quad[4] = {	{ -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } };

struct VS_OUTPUT {
	noperspective float4 pos:		SV_POSITION0;
	noperspective float4 texCoords:	TEXCOORD0;
};

VS_OUTPUT vsHeatAir(uint vid : SV_VertexID) {
	VS_OUTPUT o;
	float2 pos = quad[vid];
	o.pos = float4(pos, 0, 1);
	o.texCoords.xy = (float2(pos.x, -pos.y)*0.5+0.5)*viewport.zw + viewport.xy;
	o.texCoords.zw = o.texCoords.xy;
	return o;
}

static const float2 Poisson4[] = {
	{-0.841121, 0.521165},
	{-0.495102, -0.232887},
	{-0.182714, 0.321329},
	{0.0381787, -0.728996},
	// {0.423627, 0.429975},
	// {0.652089, 0.669668},
};

float2 calcDistortedCoord(in float2 texCoords, in uint id, in float2 dir, in float2 normal, in float heat, in float2 amplitude, in float distortion) 
{
	// V3: reduced amplitude floor from 0.1 to 0.05 to eliminate phantom
	// shimmer at the heat map boundary. mad(heat,0.6,0.4) distortion
	// floor left unchanged -- it affects directional scatter, not amplitude.
	return texCoords + (amplitude * mad(heat, 0.95, 0.05)) * (dir - ((id+2) * heat) * normal.xy + Poisson4[id] * (distortion * mad(heat,0.6,0.4)));
}

float4 getSourceColor(in float2 uv, uniform int sampleId = -1) {
	return Source.SampleLevel(gBilinearClampSampler, saturate(uv), 0);
}

float4 getSourceDepth(in float2 uv) {
	return DepthMap.SampleLevel(gPointClampSampler, uv, 0);
}

//простое размытие
float4 psHeatAir(const VS_OUTPUT i, uniform bool bUseDepthMap): SV_TARGET0
{
	float2 heatOpacityDist = HeatMap.SampleLevel(gBilinearClampSampler, i.texCoords.zw, 0).rg;
	if(heatOpacityDist.x<0.01)
		discard;

	float2 normal = HeatTex.Sample(gBilinearWrapSampler, float3(i.texCoords.zw*10, time))*2-1;
	//return float4(normal.xy*0.5+0.5, 0, 1);
	
	float2 sc;
	sincos(noise2D(i.texCoords.zw+time*0.0001)*3.1415926, sc.x, sc.y);
	
	float4 clr=0;
	const float distortion = 7.5;
	float2 amplitude = 0.001;
	amplitude.y *= float(Dims.x)/Dims.y;

	if(bUseDepthMap)
	{
		float nSamples = 0;
		float dist = heatOpacityDist.y * hotAirDistMax; //meters
		float4 heatDepth = mul(float4(0, 0, dist, 1), gProj);
		heatDepth.z /= heatDepth.w;

		[unroll]
		for(uint ii=0; ii<4; ++ii)
		{
			float2 uv = calcDistortedCoord(i.texCoords.xy, ii, sc, normal, heatOpacityDist.x, amplitude, distortion);
			
			float4 color = getSourceColor(uv, 0);
			float depth = getSourceDepth(uv).x;

			if(depth < heatDepth.z + 1.0e-4)
			{
				clr += color;
				nSamples += 1.0;
			}
		}
		if(nSamples == 0)
			discard;

		return clr / nSamples;
	}
	else
	{
		[unroll]
		for(uint ii=0; ii<4; ++ii)
		{
			float2 uv = calcDistortedCoord(i.texCoords.xy, ii, sc, normal, heatOpacityDist.x, amplitude, distortion);		
			clr += getSourceColor(uv);
		}
		return clr * 0.25;
	}
}

float4 psCopy(const VS_OUTPUT i): SV_TARGET0 {
	return Source.SampleLevel(gBilinearClampSampler, i.texCoords.zw, 0);
}

#define COMON_PART 		SetGeometryShader(NULL);														\
						SetDepthStencilState(disableDepthBuffer, 0);									\
						SetBlendState(disableAlphaBlend, float4(0.0f, 0.0f, 0.0f, 0.0f), 0xFFFFFFFF);	\
						SetRasterizerState(cullNone);

technique10 Standard {
	pass heatAirLow	{
		SetVertexShader(CompileShader(vs_4_0, vsHeatAir()));
		SetPixelShader(CompileShader(ps_4_0, psHeatAir(false)));
		COMON_PART
	}
	pass heatAirHigh {
		SetVertexShader(CompileShader(vs_4_0, vsHeatAir()));
		SetPixelShader(CompileShader(ps_4_0, psHeatAir(true)));
		COMON_PART
	}
	pass copy {
		SetVertexShader(CompileShader(vs_4_0, vsHeatAir()));
		SetPixelShader(CompileShader(ps_4_0, psCopy()));
		COMON_PART
	}
}
