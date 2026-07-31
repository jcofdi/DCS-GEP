#ifndef AMBIENT_CUBE_HLSL
#define AMBIENT_CUBE_HLSL

//глобальный эмбиент куб сцены

#if defined(EDGE) && defined(METASHADER)
	StructuredBuffer<float4> irendercontext::AmbientCube;
	#define AmbientMap irendercontext::AmbientCube
#else
	cbuffer cAmbientMap: register(b8)
	{
		float4 AmbientMap[9];	// 6 ambient walls, average horizon, average cube
	};
#endif

#define AmbientTop				AmbientMap[2].rgb
#define AmbientBottom			AmbientMap[3].rgb
// [MOD] FIX #17b - Average-tier sovereignty. [6] measured engine-written
// (hot under black canary); [7] measured delivered-dark but clamped anyway
// for uniformity (clamp is inert on honest values). Bound by the delivered
// top+bottom mean, chroma preserved. Ceiling shares FIX #17 rationale.
#define GEP_AVG_LC        float3(0.2126, 0.7152, 0.0722)
#define GEP_AVG_CAP       (3.0 * (dot(AmbientMap[2].rgb + AmbientMap[3].rgb, GEP_AVG_LC) * 0.5) + 1e-6)
#define GEP_AVG_BOUND(v)  ((v) * min(1.0, GEP_AVG_CAP / max(dot((v), GEP_AVG_LC), 1e-6)))
#define AmbientAverageHorizon	GEP_AVG_BOUND(AmbientMap[6].rgb)
#define AmbientAverage			GEP_AVG_BOUND(AmbientMap[7].rgb)
#define AmbientWhitePoint		AmbientMap[8].rgb //средний цвет куба с учетом альбедо поверхности земли = 1.0

float3 AmbientLight( const float3 worldNormal )
{
	float3 nSquared = worldNormal * worldNormal;
	uint3 isNegative = ( worldNormal < 0.0 );

	float3 clr;
	clr =	nSquared.x * AmbientMap[isNegative.x].rgb +
			nSquared.y * AmbientMap[isNegative.y+2].rgb +
			nSquared.z * AmbientMap[isNegative.z+4].rgb;

	return clr;
}

float4 SampleAmbientCube(float3 worldNormal, uniform uint offset = 0)
{
	float3 nSquared = worldNormal * worldNormal;
	uint3 isNegative = offset + ( worldNormal < 0.0 );

	return	nSquared.x * AmbientMap[isNegative.x] +
			nSquared.y * AmbientMap[isNegative.y+2] +
			nSquared.z * AmbientMap[isNegative.z+4];
}

//сжимаем и поднимаем границу смешивания земли и неба
float3 AmbientLightStretchGround( float3 worldNormal )
{
	worldNormal.y -= (1 - min(1, worldNormal.y+1))*1.3;// при отрицательном Y ходит от 0 до 1, единица когда Y минимальный
	worldNormal = normalize(worldNormal);
	
	float3 nSquared = worldNormal * worldNormal;
	uint3 isNegative = ( worldNormal < 0.0 );

	float3 clr;
	clr =	nSquared.x * AmbientMap[isNegative.x].rgb +
			nSquared.y * AmbientMap[isNegative.y+2].rgb +
			nSquared.z * AmbientMap[isNegative.z+4].rgb;

	return clr;
}

#endif
