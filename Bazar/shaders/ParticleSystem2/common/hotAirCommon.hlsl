#ifndef _HOT_AIR_COMMON_HLSL
#define _HOT_AIR_COMMON_HLSL

// V3: 100m balances the V2 tightening (prevent bleed around fuselage) with
// enough depth headroom to avoid a hard shimmer cutoff. Stock was 150.
static const float hotAirDistMax = 100.0;

#endif
