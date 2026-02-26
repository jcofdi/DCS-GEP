#ifndef ATM_ARPC_OVERRIDES_HLSL
#define ATM_ARPC_OVERRIDES_HLSL

/**
 * ARPC (Atmosphere Rendering Parameter Calculator) by MayaMaya4096 / Biology2394
 * https://github.com/MayaMaya4096/ARPC
 *
 * Replaces single-wavelength approximation coefficients with spectrally-integrated
 * values using CIE 1931 XYZ color matching functions converted to sRGB.
 * This corrects overly purple sunsets/sunrises common to Bruneton-based
 * atmosphere implementations.
 *
 * Applied ONLY during LUT precomputation so that the transmittance, scattering,
 * and irradiance tables contain physically-corrected spectral data, while runtime
 * shaders continue reading engine cbuffer values. This preserves the environment
 * cube / ambient cube brightness that particle shading depends on.
 *
 * Changes from stock DCS values:
 *   - Rayleigh scale height:    8.0 km      -> 8.69645 km  (ARPC fitted)
 *   - Rayleigh scattering RGB:  5.8/13.5/33.1 e-3 -> 6.605/12.345/29.413 e-3 km^-1
 *   - Ozone absorption RGB:     unchanged (already ARPC: 2.291/1.540/0.0 e-3 km^-1)
 *   - Ozone density profile:    peak 25km/hw 15km -> peak 22.35km/hw 17.83km (ARPC fitted)
 *   - scatteringToSingleMie:    recalculated for new Rayleigh/Mie ratio
 *
 * Mie parameters are left at engine cbuffer values (unchanged).
 *
 * Known trade-off: Runtime scatteringToSingleMie (from engine cbuffer gAtmScaToMie)
 * will not match the ARPC Rayleigh coefficients baked into the LUTs. This produces
 * a ~20% underestimate in green/blue Mie extraction at runtime, resulting in a
 * marginally warmer sun aureole. The visual impact is negligible.
 */
void applyARPCOverrides(inout AtmosphereParameters atmosphere)
{
	const float lenghtUnitsInMeter = 1000.0;

	// --- Rayleigh (ARPC spectrally-integrated) ---
	// Scale height: 8696.45 m -> 8.69645 km
	atmosphere.rayleigh_scale_height = 8.69645;

	// Scattering coefficients (m^-1 -> km^-1):
	//   R: 6.60493183e-06 -> 6.60493183e-03
	//   G: 1.23449188e-05 -> 1.23449188e-02
	//   B: 2.94126230e-05 -> 2.94126230e-02
	atmosphere.rayleigh_scattering = float3(6.60493183e-3, 1.23449188e-2, 2.94126230e-2);

	// --- scatteringToSingleMie (recalculated for ARPC Rayleigh / engine Mie) ---
	// Formula: (rayleigh.r / rayleigh.g, rayleigh.r / rayleigh.b) with mie.r / mie.r = 1
	// With achromatic Mie: float3(1.0, rayleigh.r/rayleigh.g, rayleigh.r/rayleigh.b)
	atmosphere.scatteringToSingleMie = float3(
		1.0,
		(6.60493183e-3 / 1.23449188e-2),  // = 0.53503
		(6.60493183e-3 / 2.94126230e-2)   // = 0.22456
	);

	// --- Ozone absorption extinction (ARPC spectrally-integrated) ---
	// R: 2.29107232e-06 m^-1 -> 2.29107232e-03 km^-1
	// G: 1.54036079e-06 m^-1 -> 1.54036079e-03 km^-1
	// B: 0.0 m^-1             -> 0.0 km^-1
	atmosphere.absorption_extinction = float3(2.29107232e-3, 1.54036079e-3, 0.0);

	// --- Ozone density profile (ARPC fitted to U.S. Standard Atmosphere 1976) ---
	// Layer base (peak):  22349.90 m   (stock was 25000.0 m)
	// Layer thickness:    35660.71 m   (stock was 30000.0 m)
	// Half-width:         17830.355 m  (stock was 15000.0 m)
	//
	// Layer 0 (below peak): density = linear_term * h + constant_term
	//   constant_term = 1 - base/half_width = 1 - 22349.90/17830.355 = -0.25348
	// Layer 1 (above peak): density = linear_term * h + constant_term
	//   constant_term = 1 + base/half_width = 1 + 22349.90/17830.355 =  2.25348
	atmosphere.absorption_density.layers[0].width = 22349.90 / lenghtUnitsInMeter;
	atmosphere.absorption_density.layers[0].exp_term = 0;
	atmosphere.absorption_density.layers[0].exp_scale = 0;
	atmosphere.absorption_density.layers[0].linear_term = 1.0 / (17830.355 / lenghtUnitsInMeter);
	atmosphere.absorption_density.layers[0].constant_term = -0.25348;
	atmosphere.absorption_density.layers[1].width = 0;
	atmosphere.absorption_density.layers[1].exp_term = 0;
	atmosphere.absorption_density.layers[1].exp_scale = 0;
	atmosphere.absorption_density.layers[1].linear_term = -1.0 / (17830.355 / lenghtUnitsInMeter);
	atmosphere.absorption_density.layers[1].constant_term = 2.25348;
}

/**
 * Convenience wrapper: stock init + ARPC overrides in one call.
 * Use this in atmPrecompute.fx instead of bare initAtmosphereParameters().
 */
void initAtmosphereParametersARPC(inout AtmosphereParameters atmosphere)
{
	initAtmosphereParameters(atmosphere);
	applyARPCOverrides(atmosphere);
}

#endif
