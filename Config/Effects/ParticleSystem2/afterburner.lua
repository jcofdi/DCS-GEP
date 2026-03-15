Effect = {
	{
		Type = "afterburner",
		Texture = "afterburner.dds",
		TextureCircle = "afterburner_circle.dds",
		TextureGlow = "flareGlow.dds",
		LODdistance0 = 1500,
		LODdistance1 = 8000,
	},
	{
		Type = "afterburner",
		Target = "hotAir",
		-- V3: LOD ramp aligned with effective shimmer range (hotAirDistMax=100m).
		-- 120m start fade, 200m fully off. Stock was 300/300 (hard pop).
		LODdistance0 = 120,
		LODdistance1 = 200,
		Texture = "afterburner.dds",
		TextureCircle = "afterburner_circle.dds",
		TextureGlow = "flareGlow.dds",
	},
}

Presets =
{
	forMissile =
	{
		{
			Type = "afterburner",
			Texture = "afterburner.dds",
			TextureCircle = "afterburner_circle.dds",
			TextureGlow = "flareGlow.dds",
			StuttPower = 5,
			TrailLength = 9,
			TrailScale = 0.5,
			CircleBrightness = 5,
			VolumeBrightness = 3,
			LODdistance0 = 1500,
			LODdistance1 = 8000,
			Offset = {0.07, 0.08, 0.0}		
		}
	}
}

-- staticEffect = true -- перестает обновляться позиция bbox'а если не смотреть на эффект