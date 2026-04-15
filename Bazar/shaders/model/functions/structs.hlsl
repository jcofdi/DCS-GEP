#ifndef STRUCTS_HLSL
#define STRUCTS_HLSL

#include "functions/damage_defs.hlsl"

#ifndef POSITION_SIZE
#define POSITION_SIZE 4
#endif

struct VS_INPUT
{
	vector<float, POSITION_SIZE> pos : POSITION0;
#ifdef NORMAL_SIZE
	vector<float, NORMAL_SIZE> normal : NORMAL0;
#endif
#ifdef TANGENT_SIZE
	vector<float, TANGENT_SIZE> tangent : TANGENT0;
#endif
#ifdef BINORMAL_SIZE
	vector<float, BINORMAL_SIZE> binormal : BINORMAL0;		// TODO: deprecated, remove BINORMAL semantic
#endif
#ifdef TEXCOORD0_SIZE
	vector<float, TEXCOORD0_SIZE> tc0 : TEXCOORD0;
#endif
#ifdef TEXCOORD1_SIZE
	vector<float, TEXCOORD1_SIZE> tc1 : TEXCOORD1;
#endif
#ifdef TEXCOORD2_SIZE
	vector<float, TEXCOORD2_SIZE> tc2 : TEXCOORD2;
#endif
#ifdef TEXCOORD3_SIZE
	vector<float, TEXCOORD3_SIZE> tc3 : TEXCOORD3;
#endif
#ifdef TEXCOORD4_SIZE
	vector<float, TEXCOORD4_SIZE> tc4 : TEXCOORD4;
#endif
#ifdef TEXCOORD5_SIZE
	vector<float, TEXCOORD5_SIZE> tc5 : TEXCOORD5;
#endif

#ifdef COLOR0_SIZE
	vector<float, COLOR0_SIZE> color0 : COLOR0;
#endif

#ifdef ENABLE_SKELETAL_ANIMATION
	vector<float, BONES_WEIGHTS_SIZE> bonesWeights : COLOR1;
#endif
#ifdef AIRCRAFT_REGISTRATION
	vector<float, BONES_WEIGHTS_SIZE> bonesWeights : COLOR1; // It's not bug! You can't use both ENABLE_SKELETAL_ANIMATION and AIRCRAFT_REGISTRATION.
#endif
#ifdef DAMAGE_TANGENT_SIZE
	vector<float, DAMAGE_TANGENT_SIZE> damage_tangent : TANGENT1;
#endif
#ifdef DAMAGE_BINORMAL_SIZE
	vector<float, DAMAGE_BINORMAL_SIZE> damage_binormal : BINORMAL1;		// TODO: deprecated, remove BINORMAL semantic
#endif

#ifdef DAMAGE_ARGUMENT
	int damage_argument : COLOR2;
#endif
};

struct VS_INPUT_SHADOWS
{
    vector<float, POSITION_SIZE> pos : POSITION0;

#if defined(SHADOW_WITH_ALPHA_TEST)
    // [MOD] Normal for angular glass transmittance.
    // The vertex buffer already contains this data; adding the semantic
    // causes the input assembler to bind it.  Only present for materials
    // that need the shadow pixel shader (alpha test, transparent, glass).
    #ifdef NORMAL_SIZE
        vector<float, NORMAL_SIZE> normal : NORMAL0;
    #endif
    #ifdef TEXCOORD0_SIZE
        vector<float, TEXCOORD0_SIZE> tc0 : TEXCOORD0;
    #endif
	#ifdef TEXCOORD1_SIZE
		vector<float, TEXCOORD1_SIZE> tc1 : TEXCOORD1;
	#endif
	#ifdef TEXCOORD2_SIZE
		vector<float, TEXCOORD2_SIZE> tc2 : TEXCOORD2;
	#endif
	#ifdef TEXCOORD3_SIZE
		vector<float, TEXCOORD3_SIZE> tc3 : TEXCOORD3;
	#endif
	#ifdef TEXCOORD4_SIZE
		vector<float, TEXCOORD4_SIZE> tc4 : TEXCOORD4;
	#endif
	#ifdef TEXCOORD5_SIZE
		vector<float, TEXCOORD5_SIZE> tc5 : TEXCOORD5;
	#endif
#endif

#ifdef COLOR0_SIZE
	vector<float, COLOR0_SIZE> color0 : COLOR0;
#endif

#ifdef ENABLE_SKELETAL_ANIMATION
	vector<float, BONES_WEIGHTS_SIZE> bonesWeights : COLOR1;
#endif
#ifdef AIRCRAFT_REGISTRATION
	vector<float, BONES_WEIGHTS_SIZE> bonesWeights : COLOR1; // It's not bug! You can't use both ENABLE_SKELETAL_ANIMATION and AIRCRAFT_REGISTRATION.
#endif

#ifdef DAMAGE_ARGUMENT
	int damage_argument : COLOR2;
#endif
};


// Vertex shader o structure
struct VS_OUTPUT
{
	float4 Position		: SV_POSITION0;		// vertex position in projection space
	float3 Normal	: COLOR0;		// normal, unnormalized yet!
#ifdef NORMAL_MAP_UV
	float4 Tangent	: COLOR1;		// tangent, unnormalized yet!
#endif
	float4 Pos			: COLOR3;		// vertex position in world space, w component holds height in world coordinates

#ifdef COLOR0_SIZE
	vector<float, COLOR0_SIZE> color : COLOR2;
#endif

#ifdef TEXCOORD0_SIZE
	vector<float, TEXCOORD0_SIZE> tc0 : TEXCOORD0;
#endif
#ifdef TEXCOORD1_SIZE
	vector<float, TEXCOORD1_SIZE> tc1 : TEXCOORD1;
#endif
#ifdef TEXCOORD2_SIZE
	vector<float, TEXCOORD2_SIZE> tc2 : TEXCOORD2;
#endif
#ifdef TEXCOORD3_SIZE
	vector<float, TEXCOORD3_SIZE> tc3 : TEXCOORD3;
#endif
#ifdef TEXCOORD4_SIZE
	vector<float, TEXCOORD4_SIZE> tc4 : TEXCOORD4;
#endif
#ifdef TEXCOORD5_SIZE
	vector<float, TEXCOORD5_SIZE> tc5 : TEXCOORD5;
#endif

	float4 projPos : TEXCOORD6;
	float4 prevFrameProjPos : TEXCOORD7;

	DAMAGE_VS_OUTPUT

#ifdef AIRCRAFT_REGISTRATION
	nointerpolation float2 TailNumber : TEXCOORD9;
#endif

};

struct VS_OUTPUT_RADAR
{
	float4 Position		: SV_POSITION0;		// vertex position in projection space
	float4 projPos		: TEXCOORD6;
	float4 Pos			: COLOR0;
	float3 Normal		: NORMAL0;

#ifdef COLOR0_SIZE
	vector<float, COLOR0_SIZE> color : COLOR1;
#endif

#ifdef TEXCOORD0_SIZE
	vector<float, TEXCOORD0_SIZE> tc0 : TEXCOORD0;
#endif
#ifdef TEXCOORD1_SIZE
	vector<float, TEXCOORD1_SIZE> tc1 : TEXCOORD1;
#endif
#ifdef TEXCOORD2_SIZE
	vector<float, TEXCOORD2_SIZE> tc2 : TEXCOORD2;
#endif
#ifdef TEXCOORD3_SIZE
	vector<float, TEXCOORD3_SIZE> tc3 : TEXCOORD3;
#endif
#ifdef TEXCOORD4_SIZE
	vector<float, TEXCOORD4_SIZE> tc4 : TEXCOORD4;
#endif
#ifdef TEXCOORD5_SIZE
	vector<float, TEXCOORD5_SIZE> tc5 : TEXCOORD5;
#endif

	DAMAGE_VS_OUTPUT
};

struct VS_OUTPUT_SHADOWS
{
    float4 Position     : SV_POSITION0;
    float4 Pos          : COLOR0;

#if defined(SHADOW_WITH_ALPHA_TEST)
    // [MOD] World-space normal for angular glass transmittance.
    // One float3 interpolator, only for alpha-tested/transparent materials.
    #ifdef NORMAL_SIZE
        float3 Normal   : COLOR1;
    #endif
    #ifdef TEXCOORD0_SIZE
        vector<float, TEXCOORD0_SIZE> tc0 : TEXCOORD0;
    #endif
	#ifdef TEXCOORD1_SIZE
		vector<float, TEXCOORD1_SIZE> tc1 : TEXCOORD1;
	#endif
	#ifdef TEXCOORD2_SIZE
		vector<float, TEXCOORD2_SIZE> tc2 : TEXCOORD2;
	#endif
	#ifdef TEXCOORD3_SIZE
		vector<float, TEXCOORD3_SIZE> tc3 : TEXCOORD3;
	#endif
	#ifdef TEXCOORD4_SIZE
		vector<float, TEXCOORD4_SIZE> tc4 : TEXCOORD4;
	#endif
	#ifdef TEXCOORD5_SIZE
		vector<float, TEXCOORD5_SIZE> tc5 : TEXCOORD5;
	#endif

	DAMAGE_VS_OUTPUT
#endif
};

// Pixel shader o structure
struct PS_OUTPUT
{
	float4 RGBColor : SV_TARGET0;  // Pixel color
};

#endif
