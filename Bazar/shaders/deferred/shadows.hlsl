#if USE_ROTATE_PCF
		float4 projPos = mul(float4(wPos, 1.0), gViewProj);
		angle += rnd(projPos.xy / projPos.w);  // pseudo-random rotation — sin-hash is correct here
#endif