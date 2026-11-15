local Config = {}

Config.CellSize     = 0.21

Config.MaxGridCells = 120000
Config.MaxGridAxis  = 1024
Config.ChunkCells   = 10
Config.SleepDelay   = 0.40
Config.SleepEnergy  = 0.0009

Config.SimHz        = 30

Config.MaxCatchUp   = 1

Config.MaxStepSeconds = 1 / 30

Config.CoatDepth    = 1.00
Config.SealDepth    = 0.52
Config.CureRate     = 0.11

Config.WetOutDepth  = 0.10
Config.WetOutSeal   = 0.80

Config.Gravity      = 9.0

Config.CriticalSlope= 3.00
Config.MaxFlowSpeed = 8.0
Config.YieldDepth   = 0.50

Config.PushDepth    = 0.20
Config.FlowThickRef = 2.00

Config.FlowRateMin  = 2.00
Config.FlowRateMax  = 3.50
Config.SmoothGate   = 0.10
Config.MaxFluxFrac  = 0.17

Config.AdvectClamp  = 0.40

Config.VelDamping   = 1.6

Config.ThinDragBoost= 6.5
Config.MinVelocity  = 0.03

Config.TutorialVelDamping = 0.60
Config.TutorialThinDrag   = 1.00

Config.TutorialSealDepth  = 0.30

Config.EdgeTag      = "SealableEdge"
Config.MaxEdgeGrow  = 14
Config.EdgeFlushTol = 0.30
Config.EdgeTouchTol = 0.60

Config.RippleSpeed  = 26.0
Config.RippleDamp   = 0.952
Config.RippleClamp  = 0.40
Config.RippleGate   = 0.18
Config.WetDecay     = 0.040
Config.GlossSettle  = 0.60
Config.GlossDecay   = 0.055

Config.PourRate      = 80.0
Config.PourDump      = 75.0
Config.PourDumpGap   = 0.85

Config.PourHold      = 88.0

Config.PourPoseHold  = 0.55

Config.PourRadius    = 3.00

Config.PourLag       = 0.09

Config.PourTilt      = 62.0
Config.PourTiltEase  = 8.0

Config.PourPoseGrace = 0.20

Config.PourTiltYawMax = 65.0

Config.PourSpread    = 0.25
Config.PourRipple    = 0

Config.BucketCapacity= 500.0

Config.BucketRefill  = 125.0
Config.RefillRadius  = 12.0

Config.BladeHalfLen  = 3.20

Config.BladeReach    = 2.60
Config.BladeGrip     = 0.85

Config.BladeInwardPull = 2.4

Config.BladeCapacity = 40.0

Config.BladeGather   = 2.20
Config.BladeGatherBack = 1.30
Config.BladeGatherPull = 5.0
Config.BladeGatherRate = 9.0

Config.BladeEdgeLay  = 2.00

Config.BladeThinLift = 0.80

Config.BladeLoadRef    = 100.0

Config.BladeLoadReach  = 1.60

Config.BladeLoadDam    = 3.50
Config.SealPerPass   = 0.88
Config.PileRef       = 26.0

Config.SpreadTolLo   = 0.68
Config.SpreadTolHi   = 1.75
Config.MaxSlowdown   = 0.14

Config.BladeDrop     = 0.12
Config.ResistanceEase= 5.5

Config.RigEase       = 38.0

Config.SealedThreshold = 0.90

Config.CompleteAt      = 0.98

Config.HighlightAt     = 0.95

Config.MissedClearFrac = 0.5

Config.HighlightRescan = 0.45

Config.HighlightMaxSpots = 24

Config.HighlightScanSpots = 512

Config.ComboWindow     = 3.2
Config.ComboMax        = 8

Config.StrokeMinCells  = 53
Config.PerfectSpreadMin= 0.88
Config.SmoothSpreadLen = 11.0

Config.SunDirection  = Vector3.new(-0.42, 0.80, 0.43).Unit
Config.EyeDirection  = Vector3.new(0.10, 0.60, 0.79).Unit
Config.EdgeAlphaDepth= 0.30

Config.NormalScale   = 0.95

Config.ShadeDepthRef = 2.50

Config.ShadeGradMax  = 3.00

Config.RippleNormal  = 0

Config.SpecStrength  = 0

Config.MicroFreqLow  = 0.26
Config.MicroFreqHigh = 1.24

Config.SkyWet        = 0
Config.SkyDry        = 0

Config.SheenStrength = 0.32
Config.MicroRelief   = 0.075

Config.CrackScale    = 2.4

Config.CrackWidth    = 0.13
Config.CrackDepth    = 0.42
Config.CrackScale2   = 9.0
Config.CrackWidth2   = 0.22
Config.CrackDepth2   = 0.34
Config.PlateTone     = 0.055

Config.CrackRelief   = 0.11

Config.LiquidColor   = Vector3.new(0.030, 0.029, 0.031)
Config.SealedColor   = Vector3.new(0.052, 0.050, 0.049)
Config.SpecColor     = Vector3.new(0.86, 0.90, 1.00)
Config.SheenColor    = Vector3.new(0.16, 0.18, 0.23)

Config.TexFlipX = true
Config.TexFlipY = true

Config.Use3DLiquid    = true

Config.MeshStep       = 5

Config.LiquidHeight   = 0.025

Config.LiquidHeightExtra = 0.075
Config.LiquidMaxHeight= 0.32

Config.SheetGloss     = 0.10
Config.MeshSink       = 0.180

Config.MeshEmerge     = 0.010

Config.MeshSealShow   = 0.20

Config.ConcreteColor  = Vector3.new(0.475, 0.467, 0.439)

Config.ConcreteTint   = 0

Config.TruckPark     = Vector3.new(0, 0.05, 216)

Config.YardZoneMin   = Vector3.new(-36, -20, 150)
Config.YardZoneMax   = Vector3.new(38, 40, 244)

Config.YardZoneSlack = 6

Config.HideYardRigs  = true
Config.TruckYaw      = 0
Config.TruckLength   = 22.0
Config.TruckWidth    = 7.6
Config.WheelRadius   = 1.80
Config.WheelWidth    = 1.05
Config.FrontAxleZ    = -8.20
Config.RearAxleZ     = 6.10
Config.DeckY         = 2.55

Config.TruckTopSpeed  = 34.0

Config.TruckTorque    = 1400
Config.TruckBrake     = 1400
Config.TruckHoldFrac  = 0.45
Config.TruckSteerMax  = 36.0

Config.TruckSteerEase = 0.34
Config.TruckSteerRate = 16.0

Config.TruckSteerSmooth = 9.0

Config.TruckDriveEase = 3.0
Config.TruckBrakeEase = 2.2
Config.TruckHoldSpeed = 3.0

Config.BallastMass    = 5200

Config.SuspensionSag       = 0.30
Config.SuspensionStiffness = 12000
Config.SuspensionDamping   = 1100
Config.SuspensionTravel    = 0.45
Config.SuspensionDroop     = 0.45

Config.SuspensionArm       = 1.20

Config.WheelDensity   = 0.50

Config.TankCapacity  = 7500.0

Config.TankRefill    = 440.0

Config.TankFillSeconds = 12.0

Config.TankRefillRadius = 16.0

Config.AgitatorRPM   = 42

Config.FillReach = 14.0

Config.FillGrab = 0.25

Config.FillLeash = 4.0

Config.HoseMaxLength  = 140.0
Config.HoseTaut       = 0.78
Config.HoseSegments   = 30
Config.HoseRadius     = 0.23
Config.HoseSag        = 0.17
Config.HoseSagMax     = 7.0
Config.HoseGroundClear= 0.26
Config.HoseDragMax    = 0.42
Config.HoseRetractRate= 30.0

Config.HoseRewindRate = 12.0
Config.HoseColor      = Color3.fromRGB(96, 22, 20)

Config.WandReach     = 15.0
Config.WandLag       = 0.05

Config.WandRadius    = 2.40

Config.WandRate      = 104.0

Config.TruckBladeWidth  = 9.6
Config.TruckBladePivot  = Vector3.new(0, 2.90, -11.40)
Config.TruckBladeReach  = 1.20

Config.TruckBladeSink   = 2.35

Config.TruckBladeRaise  = 58
Config.TruckBladeEase   = 3.4

Config.TruckBladeCapacity = 260

Config.TruckBladeMinSpeed = 2.0

Config.TruckPourWidth   = Config.TruckBladeWidth

Config.TruckPourReach   = 3.00
Config.TruckPourPerStud = 1.45
Config.TruckPourIdle    = 2.20

Config.TruckPourPumpShare = 0.24

Config.TruckPourFeedGain  = 3.00

Config.TruckPourMaxRate = 520

Config.TruckPourSpacing = 0.80
Config.TruckPourMaxPts  = 16

Config.TruckDropEvery    = 7.00
Config.TruckDropInterval = 0.55

Config.TruckDropPoints   = 3
Config.TruckDropRadius   = 1.45

Config.TruckDropPerStud  = 0.58

Config.MaxAreaPerSecond = 2000
Config.MinCoveragePerSecond = 0.12

function Config.maxCoverageRate(slab: BasePart): number
	local area = slab.Size.X * slab.Size.Z
	if area <= 0 then return 1 end
	return math.max(Config.MinCoveragePerSecond, Config.MaxAreaPerSecond / area)
end

return Config
