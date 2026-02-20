Effect = {
	{
		Type = "steamCatapult",
		ShadingFX = "ParticleSystem2/steamCatapult.fx",
		UpdateFX  = "ParticleSystem2/steamCatapultComp.fx",
		Technique = "techSteamCatapult",
		IsComputed = true,
		Texture = "puff01.dds",
		TextureDetailNoise = "puffNoise.png",
		LODdistance1 = 1500,

		Opacity = 0.9, --JC 0.5 last 0.3
		ParticlesCount = 512,  --JC 150
		ParticleSize = 1.3,  --JC 1.3 last 0.6
		Color = {220/255.0, 220/255.0, 220/255.0}, --JC 220/255.0 last 230
	}
}
