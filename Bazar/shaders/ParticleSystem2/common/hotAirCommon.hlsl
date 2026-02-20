#ifndef _HOT_AIR_COMMON_HLSL
#define _HOT_AIR_COMMON_HLSL

// Reduced from 150.0 to 80.0 metres to tighten the depth range over which
// heat distortion renders. This prevents the effect bleeding into space
// around the aircraft body and keeps it closer to the actual exhaust stream.
static const float hotAirDistMax = 80.0;

#endif
