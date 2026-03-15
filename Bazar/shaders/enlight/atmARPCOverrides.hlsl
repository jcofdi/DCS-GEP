#ifndef ATM_ARPC_OVERRIDES_HLSL
#define ATM_ARPC_OVERRIDES_HLSL

/**
 * ARPC (Atmosphere Rendering Parameter Calculator) by MayaMaya4096 / Biology2394
 * https://github.com/MayaMaya4096/ARPC
 *
 * Replaces single-wavelength approximation coefficients with spectrally-integrated
 * values using CIE 2006 2-deg XYZ color matching functions (derived from
 * Stockman & Sharpe LMS cone fundamentals) converted to sRGB. The CIE 2006
 * observer corrects the known short-wavelength overestimate in the CIE 1931
 * z-bar function, reducing blue-channel inflation from Rayleigh's lambda^-4
 * scattering and producing more perceptually accurate sunset colors.
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
 *   - Rayleigh scattering RGB:  5.8/13.5/33.1 e-3 -> 5.950/12.787/30.504 e-3 km^-1
 *   - Ozone absorption RGB:     2.291/1.540/0.0 e-3 -> 2.361/1.485/0.0 e-3 km^-1
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
    //   R: 5.9501e-06 -> 5.9501e-03
    //   G: 1.2787e-05 -> 1.2787e-02
    //   B: 3.0504e-05 -> 3.0504e-02
	atmosphere.rayleigh_scattering = float3(5.9501e-3, 1.2787e-2, 3.0504e-2);

	// --- scatteringToSingleMie (recalculated for ARPC Rayleigh / engine Mie) ---
	// Formula: (rayleigh.r / rayleigh.g, rayleigh.r / rayleigh.b) with mie.r / mie.r = 1
	// With achromatic Mie: float3(1.0, rayleigh.r/rayleigh.g, rayleigh.r/rayleigh.b)
	atmosphere.scatteringToSingleMie = float3(
        1.0,
        (5.9501e-3 / 1.2787e-2),   // = 0.46533
        (5.9501e-3 / 3.0504e-2)    // = 0.19506
    );

	// --- Ozone absorption extinction (ARPC CIE 2006 spectrally-integrated) ---
    // R: 2.3609e-06 m^-1 -> 2.3609e-03 km^-1
    // G: 1.4851e-06 m^-1 -> 1.4851e-03 km^-1
    // B: 0.0 m^-1         -> 0.0 km^-1
	atmosphere.absorption_extinction = float3(2.3609e-3, 1.4851e-3, 0.0);

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
