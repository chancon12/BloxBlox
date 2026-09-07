-- GitHub-side Auto Bounty module.
-- External options are intentionally limited to Team, Weapon, Attack, FastTP,
-- AutoHop, ESP, NoClip, TweenSpeed, SafeModeY, health thresholds, hitbox settings,
-- PlayerFollowTime, NoDamageTimeout, SkipPreviousTargets, OrbitEnabled, RaceV3, RaceV4,
-- ClickAttack, HitboxOffset, TweenHitbox, SafeZoneRadius, combo timings, panic movement,
-- SeaHeightFirst, SeaHeightStallTimeout, GunOpenerEnabled, GunEngageDistance, MaxTargetDistance,
-- and optional ReadSkillCooldown.
-- Race flags belong in Config.Settings and require an explicit true.
-- NoDamageTimeout allows time for a target health drop or confirmed local InCombat after hitbox entry.
-- Either qualifies the current target for this check until a different target acquisition.
-- SkipPreviousTargets defaults to true; set false to allow previous targets through this filter.
-- OrbitEnabled defaults to true; set false to follow the target directly without circling.
-- ClickAttack defaults to true; set false to disable normal attacks while skills are cooling down.
-- ClickAttack also pauses while the local player's health is below 20% of MaxHealth.
-- HitboxOffset defaults to Vector3.new(0, 0, 0), relative to the target's CFrame:
-- +X right, +Y up, -Z front, +Z behind. Positions stay inside the hitbox and above sea level.
-- Empty targets during combat: request the nearest entrance once per wait/character, then wait to hop.
-- SafeZoneRadius defaults to 100 studs from each zone part's center (3D distance).
-- For a zone inside a Model, use the nearest ancestor Model's valid PrimaryPart when available.
-- SafeModePanicEnabled defaults to true; SafeModePanicRadius defaults to 200 studs.
-- Combo order follows Weapon.Order and each weapon's SkillOrder (default Z, X, C, V, F).
-- ComboDelay defaults to 0.03 seconds, replacing weapon Delay between casts.
-- Optional ComboHold overrides every skill Hold; omit it to keep per-skill holds.
-- ComboRetryDelay defaults to 1 second when cooldown activation cannot be confirmed.
-- SeaHeightStallTimeout defaults to 3 seconds without vertical progress: retry once, then switch.
-- SeaHeightFirst defaults to false for direct chasing; set true to restore the sea-level stage.
-- TweenHitbox defaults: Enabled=true, Size=Vector3.new(100,100,100), TimeMultiplier=2.
-- This separate target-relative box multiplies chase/orbit tween duration, including the existing hitbox slowdown.
-- GunOpenerEnabled defaults to true; fire one RemoteFunctionShoot opener within GunEngageDistance (100 studs).
-- Other weapons start inside the combat hitbox. The opener requires Weapon.Gun.Enabled, not Gun skill flags.
-- MaxTargetDistance defaults to 10000 studs (3D): direct targets first, then entrance routes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Teams = game:GetService("Teams")
local RunService = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local VirtualUser = game:GetService("VirtualUser")
local Workspace = game:GetService("Workspace")

local Environment = getgenv and getgenv() or _G
local Config = Environment.AutoBountyConfig
local LoaderToken = Environment.__AutoBountyLoaderToken
local BootstrapToken = {}

Environment.__AutoBountyBootstrapToken = BootstrapToken

local function bootstrapStillCurrent()
    return Environment.__AutoBountyBootstrapToken == BootstrapToken
        and (LoaderToken == nil or Environment.__AutoBountyLoaderToken == LoaderToken)
end

assert(type(Config) == "table", "AutoBountyConfig must be configured before loading AutoBounty.lua")
assert(
    Config.Team == "Pirates" or Config.Team == "Marines",
    'AutoBountyConfig.Team must be either "Pirates" or "Marines"'
)

local Settings = type(Config.Settings) == "table" and Config.Settings or {}
local WeaponConfig = type(Config.Weapon) == "table" and Config.Weapon or {}
local HitboxConfig = type(Settings.Hitbox) == "table" and Settings.Hitbox or {}
local TweenHitboxConfig = type(Settings.TweenHitbox) == "table" and Settings.TweenHitbox or {}

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local FastTPEnabled = Settings.FastTP ~= false
local ESPEnabled = Settings.ESPPlayer ~= false
local SkipPreviousTargets = Settings.SkipPreviousTargets ~= false
local OrbitEnabled = Settings.OrbitEnabled ~= false
local ClickAttackEnabled = Settings.ClickAttack ~= false
local GunOpenerEnabled = Settings.GunOpenerEnabled ~= false
local GunEngageDistance = Settings.GunEngageDistance == nil
    and 100 or tonumber(Settings.GunEngageDistance)
local MaxTargetDistance = Settings.MaxTargetDistance == nil
    and 10000 or tonumber(Settings.MaxTargetDistance)
local TweenHitboxEnabled = TweenHitboxConfig.Enabled ~= false
local TweenHitboxSize = TweenHitboxConfig.Size or Vector3.new(100, 100, 100)
local TweenHitboxTimeMultiplier = TweenHitboxConfig.TimeMultiplier == nil
    and 2 or tonumber(TweenHitboxConfig.TimeMultiplier)
local RawAutoHop = Settings.AutoHop
local AutoHopEnabled = RawAutoHop == nil and true or RawAutoHop
local RawAttack = Settings.Attack
local AttackEnabled = RawAttack == nil and true or RawAttack
local RawNoClip = Settings.NoClip
local NoClipEnabled = RawNoClip == nil and true or RawNoClip
local RawTweenSpeed = Settings.TweenSpeed
local TweenSpeed = RawTweenSpeed == nil and 180 or tonumber(RawTweenSpeed)
local RawSafeModeY = Settings.SafeModeY
local SafeModeY = RawSafeModeY == nil and 1000 or tonumber(RawSafeModeY)
local SafeModePanicEnabled = Settings.SafeModePanicEnabled ~= false
local SafeModePanicRadius = Settings.SafeModePanicRadius == nil
    and 200 or tonumber(Settings.SafeModePanicRadius)
local LowHealth = tonumber(Settings.LowHealth) or 8000
local RecoveryHealth = tonumber(Settings.MaxHealth) or 10000
local RawPlayerFollowTime = Settings.PlayerFollowTime
local PlayerFollowTime = RawPlayerFollowTime == nil and 30 or tonumber(RawPlayerFollowTime)
local RawNoDamageTimeout = Settings.NoDamageTimeout
local NoDamageTimeout = RawNoDamageTimeout == nil and 30 or tonumber(RawNoDamageTimeout)
local RawSafeZoneRadius = Settings.SafeZoneRadius
local SafeZoneRadius = RawSafeZoneRadius == nil and 100 or tonumber(RawSafeZoneRadius)
local HitboxOffset = Settings.HitboxOffset

if not isFiniteNumber(GunEngageDistance) or GunEngageDistance <= 0 then
    warn("[AutoBounty] GunEngageDistance must be a finite number above 0; using 100 studs.")
    GunEngageDistance = 100
end

if not isFiniteNumber(MaxTargetDistance) or MaxTargetDistance <= 0 then
    warn("[AutoBounty] MaxTargetDistance must be a finite number above 0; using 10000 studs.")
    MaxTargetDistance = 10000
end

if typeof(TweenHitboxSize) ~= "Vector3"
    or not isFiniteNumber(TweenHitboxSize.X)
    or not isFiniteNumber(TweenHitboxSize.Y)
    or not isFiniteNumber(TweenHitboxSize.Z)
    or TweenHitboxSize.X <= 0
    or TweenHitboxSize.Y <= 0
    or TweenHitboxSize.Z <= 0 then

    warn("[AutoBounty] Settings.TweenHitbox.Size is invalid; using Vector3.new(100, 100, 100).")
    TweenHitboxSize = Vector3.new(100, 100, 100)
end

if not isFiniteNumber(TweenHitboxTimeMultiplier) or TweenHitboxTimeMultiplier < 1 then
    warn("[AutoBounty] Settings.TweenHitbox.TimeMultiplier must be finite and at least 1; using 2.")
    TweenHitboxTimeMultiplier = 2
end

if HitboxOffset == nil then
    HitboxOffset = Vector3.new(0, 0, 0)
elseif typeof(HitboxOffset) ~= "Vector3"
    or not isFiniteNumber(HitboxOffset.X)
    or not isFiniteNumber(HitboxOffset.Y)
    or not isFiniteNumber(HitboxOffset.Z) then

    warn("[AutoBounty] Settings.HitboxOffset must be a finite Vector3; using Vector3.new(0, 0, 0).")
    HitboxOffset = Vector3.new(0, 0, 0)
end

if type(AutoHopEnabled) ~= "boolean" then
    warn("[AutoBounty] AutoHop must be true or false; using true.")
    AutoHopEnabled = true
end

if type(AttackEnabled) ~= "boolean" then
    warn("[AutoBounty] Attack must be true or false; using true.")
    AttackEnabled = true
end

if type(NoClipEnabled) ~= "boolean" then
    warn("[AutoBounty] NoClip must be true or false; using true.")
    NoClipEnabled = true
end

if not isFiniteNumber(TweenSpeed) or TweenSpeed <= 0 then
    warn("[AutoBounty] TweenSpeed must be a finite number above 0; using 180 studs per second.")
    TweenSpeed = 180
end

if not isFiniteNumber(SafeModeY) or SafeModeY <= 0 then
    warn("[AutoBounty] SafeModeY must be a finite world Y position above 0; using 1000.")
    SafeModeY = 1000
end

if not isFiniteNumber(SafeModePanicRadius) or SafeModePanicRadius <= 0 then
    warn("[AutoBounty] SafeModePanicRadius must be a finite number above 0; using 200 studs.")
    SafeModePanicRadius = 200
end

if not isFiniteNumber(PlayerFollowTime) or PlayerFollowTime <= 0 then
    warn("[AutoBounty] PlayerFollowTime must be a finite number above 0; using 30 seconds.")
    PlayerFollowTime = 30
end

if not isFiniteNumber(NoDamageTimeout) or NoDamageTimeout <= 0 then
    warn("[AutoBounty] NoDamageTimeout must be a finite number above 0; using 30 seconds.")
    NoDamageTimeout = 30
end

if not isFiniteNumber(SafeZoneRadius) or SafeZoneRadius <= 0 then
    warn("[AutoBounty] SafeZoneRadius must be a finite number above 0; using 100 studs.")
    SafeZoneRadius = 100
end

if not isFiniteNumber(LowHealth) then
    warn("[AutoBounty] LowHealth is not finite; using 8000.")
    LowHealth = 8000
end

if not isFiniteNumber(RecoveryHealth) then
    warn("[AutoBounty] MaxHealth is not finite; using 10000.")
    RecoveryHealth = 10000
end

if LowHealth < 0 then
    LowHealth = 0
end

if RecoveryHealth <= LowHealth then
    warn("[AutoBounty] MaxHealth must be above LowHealth; MaxHealth has been raised by 1 for hysteresis.")
    RecoveryHealth = LowHealth + 1
end

local ConfiguredHitboxSize = HitboxConfig.Size

if typeof(ConfiguredHitboxSize) ~= "Vector3"
    or not isFiniteNumber(ConfiguredHitboxSize.X)
    or not isFiniteNumber(ConfiguredHitboxSize.Y)
    or not isFiniteNumber(ConfiguredHitboxSize.Z)
    or ConfiguredHitboxSize.X <= 0
    or ConfiguredHitboxSize.Y <= 0
    or ConfiguredHitboxSize.Z <= 0 then

    warn("[AutoBounty] Settings.Hitbox.Size is invalid; using Vector3.new(30, 30, 30).")
    ConfiguredHitboxSize = Vector3.new(30, 30, 30)
end

local HitboxEnabled = HitboxConfig.Enabled ~= false
local ConfiguredHitboxTransparency = tonumber(HitboxConfig.Transparency)

if not isFiniteNumber(ConfiguredHitboxTransparency) then
    warn("[AutoBounty] Settings.Hitbox.Transparency is invalid; using 0.5.")
    ConfiguredHitboxTransparency = 0.5
elseif ConfiguredHitboxTransparency < 0 or ConfiguredHitboxTransparency > 1 then
    warn("[AutoBounty] Settings.Hitbox.Transparency must be between 0 and 1; clamping it.")
    ConfiguredHitboxTransparency = math.clamp(ConfiguredHitboxTransparency, 0, 1)
end

local INTERNAL = {
    MaxLevelDifference = 800,
    TargetRefreshInterval = 0.25,
    EmptyListGrace = 5,
    PendingTargetGrace = 8,
    FriendRefreshInterval = 2,
    NonFriendCacheTTL = 300,
    PvPRetryDelay = 0.75,
    PvPMaxAttempts = 5,
    InHitboxSpeedMultiplier = 2 / 7,
    MinimumTweenY = 0,
    VerticalChaseDistance = 1000,
    ChaseMoveDuration = 1,
    ChasePauseDuration = 0.1,
    SeaHeightTweenSpeed = 50,
    SeaHeightMoveDuration = 0.5,
    SeaHeightPauseDuration = 0.1,
    FastTPArrivalTimeout = 3,
    FastTPCooldown = 2,
    ServerRetryDelay = 3,
    ExternalHopURL = "https://raw.githubusercontent.com/WhiteX1208/Scripts/refs/heads/main/KaitunFindFruit.luau",
    ExternalHopDownloadTimeout = 15,
    ExternalHopMaxAbandonedDownloads = 3,
}

local function isFiniteVector3(value)
    return typeof(value) == "Vector3"
        and isFiniteNumber(value.X)
        and isFiniteNumber(value.Y)
        and isFiniteNumber(value.Z)
end

local function clampCFrameAboveSea(cframe)
    if typeof(cframe) ~= "CFrame" or not isFiniteVector3(cframe.Position) then
        return nil
    end

    local position = cframe.Position

    if position.Y >= INTERNAL.MinimumTweenY then
        return cframe
    end

    return CFrame.new(
        position.X,
        INTERNAL.MinimumTweenY,
        position.Z
    ) * cframe.Rotation
end

local ENTRANCES = {
    [2753915549] = {
        Vector3.new(61163.8515625, 11.6796875, 1819.7841796875),
        Vector3.new(-4607.82275, 872.54248, -1667.55688),
        Vector3.new(-7894.6176757813, 5547.1416015625, -380.29119873047),
    },
    [4442272183] = {
        Vector3.new(923.21252441406, 126.9760055542, 32852.83203125),
        Vector3.new(-6508.5581054688, 5000.034996032715, -132.83953857422),
        Vector3.new(2284.912109375, 15.537666320801, 905.48291015625),
    },
    [7449423635] = {
        Vector3.new(-5083.26025390625, 314.6056823730469, -3175.673095703125),
        Vector3.new(-12471.169921875, 374.94024658203, -7551.677734375),
        Vector3.new(28286.355, 14896.534, 102.625),
        Vector3.new(5661.529, 1017.275, -334.962),
        Vector3.new(-16813.439, 61.606, 304.874),
    },
    [100117331123089] = {
        Vector3.new(-5083.26025390625, 314.6056823730469, -3175.673095703125),
        Vector3.new(-12471.169921875, 374.94024658203, -7551.677734375),
        Vector3.new(28286.355, 14896.534, 102.625),
        Vector3.new(5661.529, 1017.275, -334.962),
        Vector3.new(-16813.439, 61.606, 304.874),
    },
}

if not game:IsLoaded() then
    game.Loaded:Wait()
end

if not bootstrapStillCurrent() then
    return
end

local LocalPlayer = Players.LocalPlayer

while not LocalPlayer and bootstrapStillCurrent() do
    task.wait(0.1)
    LocalPlayer = Players.LocalPlayer
end

if not bootstrapStillCurrent() then
    return
end

assert(LocalPlayer, "[AutoBounty] LocalPlayer is unavailable")
print("[AutoBounty] Module started for " .. LocalPlayer.Name)

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
assert(Remotes, "[AutoBounty] ReplicatedStorage.Remotes was not found within 30 seconds")

local CommF = Remotes:WaitForChild("CommF_", 30)
assert(CommF, "[AutoBounty] ReplicatedStorage.Remotes.CommF_ was not found within 30 seconds")

if not bootstrapStillCurrent() then
    return
end

local PreviousRuntime = Environment.__AutoBountyRuntime

if PreviousRuntime and type(PreviousRuntime.Stop) == "function" then
    pcall(function()
        PreviousRuntime:Stop("reload")
    end)
end

if not bootstrapStillCurrent() then
    return
end

-- Select the team first. In the current client, DataLoaded's presence is the
-- usable marker; its BoolValue.Value can remain false after gameplay is ready.
print("[AutoBounty] Selecting team: " .. Config.Team)
local TeamRequestOk, TeamRequestResult = pcall(function()
    return CommF:InvokeServer("SetTeam", Config.Team)
end)

if not bootstrapStillCurrent() then
    print("[AutoBounty] Startup superseded after team request")
    return
end

assert(
    TeamRequestOk,
    "[AutoBounty] SetTeam failed: " .. tostring(TeamRequestResult)
)

local TeamDeadline = os.clock() + 15

while bootstrapStillCurrent() and os.clock() < TeamDeadline do
    if LocalPlayer.Team and LocalPlayer.Team.Name == Config.Team then
        break
    end

    task.wait(0.1)
end

if not bootstrapStillCurrent() then
    return
end

assert(
    LocalPlayer.Team and LocalPlayer.Team.Name == Config.Team,
    "[AutoBounty] The requested team was not confirmed within 15 seconds"
)

print("[AutoBounty] Team confirmed; waiting for DataLoaded marker and Data.Level")

local DataLoadedDeadline = os.clock() + 60
local DataLoaded
local LoadedData
local LoadedLevelObject
local LoadedLevel
local StableDataLoaded
local StableData
local StableLevelObject
local ReadySince
local LastTeamName = "<missing>"
local LastMarkerState = "<missing>"
local LastLevelState = "<missing>"

while bootstrapStillCurrent() and os.clock() < DataLoadedDeadline do
    local current = LocalPlayer:FindFirstChild("DataLoaded")
    local currentTeam = LocalPlayer.Team
    local teamMatches = currentTeam and currentTeam.Name == Config.Team
    local data = LocalPlayer:FindFirstChild("Data")
    local levelObject = data and data:FindFirstChild("Level")
    local level = levelObject
        and levelObject:IsA("ValueBase")
        and tonumber(levelObject.Value)

    if current and not current:IsA("BoolValue") then
        error("[AutoBounty] LocalPlayer.DataLoaded must be a BoolValue")
    end

    LastTeamName = currentTeam and currentTeam.Name or "<missing>"
    LastMarkerState = current
        and (current.ClassName .. " Value=" .. tostring(current.Value))
        or "<missing>"
    LastLevelState = level and tostring(level) or "<missing-or-invalid>"

    local ready = teamMatches
        and current
        and data
        and levelObject
        and isFiniteNumber(level)
        and level >= 1

    if ready then
        if StableDataLoaded == current
            and StableData == data
            and StableLevelObject == levelObject then

            if os.clock() - ReadySince >= 0.5 then
                DataLoaded = current
                LoadedData = data
                LoadedLevelObject = levelObject
                LoadedLevel = level
                break
            end
        else
            StableDataLoaded = current
            StableData = data
            StableLevelObject = levelObject
            ReadySince = os.clock()
        end
    else
        StableDataLoaded = nil
        StableData = nil
        StableLevelObject = nil
        ReadySince = nil
    end

    task.wait(0.1)
end

if not bootstrapStillCurrent() then
    return
end

local finalLevel = LoadedLevelObject
    and LoadedLevelObject:IsA("ValueBase")
    and tonumber(LoadedLevelObject.Value)
local readinessStillValid = LocalPlayer.Team
    and LocalPlayer.Team.Name == Config.Team
    and DataLoaded
    and LocalPlayer:FindFirstChild("DataLoaded") == DataLoaded
    and DataLoaded.Parent == LocalPlayer
    and LoadedData
    and LocalPlayer:FindFirstChild("Data") == LoadedData
    and LoadedLevelObject
    and LoadedData:FindFirstChild("Level") == LoadedLevelObject
    and LoadedLevelObject.Parent == LoadedData
    and isFiniteNumber(finalLevel)
    and finalLevel >= 1

if not readinessStillValid then
    error(
        "[AutoBounty] Readiness timed out or changed: team="
            .. LastTeamName
            .. ", DataLoaded="
            .. LastMarkerState
            .. ", Level="
            .. LastLevelState
    )
end

LoadedLevel = finalLevel
print(
    "[AutoBounty] Readiness confirmed; DataLoaded.Value="
        .. tostring(DataLoaded.Value)
        .. ", Level="
        .. tostring(LoadedLevel)
)

if not bootstrapStillCurrent() then
    return
end

local Runtime = {
    Running = true,
    Mode = "INITIALIZE",
    Status = "Initializing",
    CurrentTarget = nil,
    CurrentTargetInfo = nil,
    CurrentTool = nil,
    TargetEpoch = 0,
    CharacterEpoch = 0,
    SafeEpoch = 0,
    Character = nil,
    Humanoid = nil,
    Root = nil,
    InsideHitbox = false,
    ChaseMoveCycle = nil,
    ChaseTweenTimeMultiplier = nil,
    SeaHeightMove = nil,
    ActiveTween = nil,
    FollowNoCombatSince = nil,
    FollowTimerEpoch = nil,
    FollowTimerCharacterEpoch = nil,
    DamageCheckDeadline = nil,
    DamageCheckLastHealth = nil,
    DamageCheckEpoch = nil,
    DamageCheckCharacterEpoch = nil,
    DamageCheckExpired = false,
    DamageObserved = false,
    AimActive = false,
    GunAimActive = false,
    GunShotRequest = nil,
    GunShotOwner = nil,
    GunMouseHeld = nil,
    SafeMode = false,
    SafeModeAtAltitude = false,
    SafeModeMovement = nil,
    LocalDead = true,
    Teleporting = false,
    EntranceBusy = false,
    LastEntranceAt = 0,
    HopPending = false,
    EmptyCombatEntranceAttempt = nil,
    HopReason = nil,
    FollowTimeoutHopDetail = nil,
    HopWorkerRunning = false,
    HopAttemptEpoch = 0,
    ExternalHopLaunch = nil,
    ExternalHopLaunched = false,
    ExternalHopTerminalFailure = false,
    ExternalHopAbandonedDownloads = 0,
    EmptySince = nil,
    Candidates = {},
    CandidateInfo = {},
    CandidateReasons = {},
    PendingSince = {},
    PendingCandidateCount = 0,
    NoProgressCharacters = {},
    FollowTimeoutCharacters = {},
    PreviouslyTargeted = {},
    RouteFailures = {},
    TargetConnections = {},
    Connections = {},
    CharacterConnections = {},
    PressedKeys = {},
    HitboxSnapshot = nil,
    LocalCollisionSnapshot = {},
    LocalCollisionCharacter = nil,
    AttackEnabled = AttackEnabled,
    AutoHopEnabled = AutoHopEnabled,
    SafeModeY = SafeModeY,
    NoClipEnabled = NoClipEnabled,
    BodyClip = nil,
    BodyClipRoot = nil,
    FriendCache = {},
    FriendCheckedAt = {},
    FriendAuditComplete = false,
    ESPObjects = {},
    SafeZoneParts = {},
    SafeZonesFolder = nil,
    SafeZonesReady = false,
    SafeZoneConnections = {},
    CameraBindName = "AutoBountyCamera_" .. tostring(LocalPlayer.UserId),
    CameraBound = false,
    GUI = nil,
    Labels = {},
}

Environment.__AutoBountyRuntime = Runtime

local Warned = {}

local function warnOnce(key, message)
    if Warned[key] then
        return
    end

    Warned[key] = true
    warn("[AutoBounty] " .. message)
end

local function connect(signal, callback, characterScoped)
    local connection = signal:Connect(callback)

    if characterScoped then
        table.insert(Runtime.CharacterConnections, connection)
    else
        table.insert(Runtime.Connections, connection)
    end

    return connection
end

local function disconnectConnections(connections)
    for _, connection in ipairs(connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end

    table.clear(connections)
end

local function readBooleanAttribute(instance, name, fallback)
    if not instance then
        warnOnce("attribute:no-instance:" .. name, "Cannot read missing attribute " .. name .. " because its instance is unavailable.")
        return fallback, false
    end

    local value = instance:GetAttribute(name)
    local identity = instance:IsA("Player")
        and (instance.Name .. " (" .. tostring(instance.UserId) .. ")")
        or instance:GetFullName()
    local warningKey = "attribute:" .. identity .. ":" .. name

    if value == nil then
        warnOnce(
            warningKey,
            "Attribute " .. name .. " is missing on " .. identity .. "; using " .. tostring(fallback) .. "."
        )
        return fallback, false
    end

    if typeof(value) ~= "boolean" then
        warnOnce(
            warningKey .. ":type",
            "Attribute " .. name .. " on " .. identity .. " is not a boolean; using " .. tostring(fallback) .. "."
        )
        return fallback, false
    end

    return value, true
end

local function readLocalInCombat()
    return readBooleanAttribute(Runtime.Character, "InCombat", nil)
end

local function setRequiredLocalAttribute(name)
    local currentValue = LocalPlayer:GetAttribute(name)

    if currentValue == nil then
        warnOnce(
            "attribute:local:" .. name,
            "Attribute " .. name .. " is missing on LocalPlayer; creating it with value true."
        )
    elseif typeof(currentValue) ~= "boolean" then
        warnOnce(
            "attribute:local:" .. name .. ":type",
            "Attribute " .. name .. " on LocalPlayer is not a boolean; replacing it with true."
        )
    end

    local success, result = pcall(function()
        LocalPlayer:SetAttribute(name, true)
    end)

    if not success or LocalPlayer:GetAttribute(name) ~= true then
        warnOnce(
            "attribute:local:" .. name .. ":set-failed",
            "Could not set LocalPlayer attribute " .. name .. " to true: " .. tostring(result)
        )
    end
end

local function getAliveCharacter(player)
    if not player or player.Parent ~= Players then
        return nil
    end

    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")

    if not character
        or not character.Parent
        or not humanoid
        or not root
        or humanoid.Health <= 0 then

        return nil
    end

    return character, humanoid, root
end

local function formatNumber(value)
    local formatted = tostring(math.floor(tonumber(value) or 0))

    while true do
        local replacements
        formatted, replacements = formatted:gsub("^(-?%d+)(%d%d%d)", "%1,%2")

        if replacements == 0 then
            break
        end
    end

    return formatted
end

local function createTextLabel(parent, name, position, size, text, textSize)
    local label = Instance.new("TextLabel")
    label.Name = name
    label.Parent = parent
    label.BackgroundTransparency = 1
    label.Position = position
    label.Size = size
    label.Font = Enum.Font.GothamSemibold
    label.Text = text
    label.TextColor3 = Color3.fromRGB(235, 235, 235)
    label.TextSize = textSize or 14
    label.TextXAlignment = Enum.TextXAlignment.Left
    return label
end

local function createGUI()
    local playerGui = LocalPlayer:WaitForChild("PlayerGui")
    local oldGui = playerGui:FindFirstChild("AutoBountyStatus")

    if oldGui then
        oldGui:Destroy()
    end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "AutoBountyStatus"
    screenGui.ResetOnSpawn = false
    screenGui.IgnoreGuiInset = false
    screenGui.DisplayOrder = 50
    screenGui.Parent = playerGui

    local frame = Instance.new("Frame")
    frame.Name = "Panel"
    frame.Parent = screenGui
    frame.AnchorPoint = Vector2.new(1, 0)
    frame.Position = UDim2.new(1, -18, 0, 18)
    frame.Size = UDim2.fromOffset(310, 150)
    frame.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
    frame.BackgroundTransparency = 0.12
    frame.BorderSizePixel = 0

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(75, 110, 180)
    stroke.Transparency = 0.25
    stroke.Thickness = 1
    stroke.Parent = frame

    Runtime.Labels.Title = createTextLabel(
        frame,
        "Title",
        UDim2.fromOffset(12, 8),
        UDim2.new(1, -24, 0, 22),
        "AUTO BOUNTY",
        16
    )
    Runtime.Labels.Bounty = createTextLabel(frame, "Bounty", UDim2.fromOffset(12, 36), UDim2.new(1, -24, 0, 20), "Bounty/Honor: Loading...", 14)
    Runtime.Labels.Team = createTextLabel(frame, "Team", UDim2.fromOffset(12, 58), UDim2.new(1, -24, 0, 20), "Team: " .. Config.Team, 14)
    Runtime.Labels.Target = createTextLabel(frame, "Target", UDim2.fromOffset(12, 80), UDim2.new(1, -24, 0, 20), "Target: None", 14)
    Runtime.Labels.Candidates = createTextLabel(frame, "Candidates", UDim2.fromOffset(12, 102), UDim2.new(1, -24, 0, 20), "Eligible players: 0", 14)
    Runtime.Labels.Status = createTextLabel(frame, "Status", UDim2.fromOffset(12, 124), UDim2.new(1, -24, 0, 20), "Status: Initializing", 13)
    Runtime.Labels.Status.TextColor3 = Color3.fromRGB(130, 200, 255)

    Runtime.GUI = screenGui
end

local function setStatus(status)
    Runtime.Status = status

    if Runtime.Labels.Status then
        Runtime.Labels.Status.Text = "Status: " .. status
    end
end

local function isEmptyListHopReady()
    return Runtime.SafeZonesFolder ~= nil
        and Runtime.SafeZonesFolder.Parent ~= nil
        and Runtime.SafeZonesReady
        and Runtime.FriendAuditComplete
        and Runtime.EmptySince ~= nil
        and os.clock() - Runtime.EmptySince >= INTERNAL.EmptyListGrace
        and #Runtime.Candidates == 0
        and Runtime.PendingCandidateCount == 0
end

local function updateTargetGUI()
    if Runtime.Labels.Target then
        Runtime.Labels.Target.Text = "Target: " .. (
            Runtime.CurrentTarget and Runtime.CurrentTarget.Name or "None"
        )
    end

    if Runtime.Labels.Candidates then
        Runtime.Labels.Candidates.Text = "Eligible players: " .. tostring(#Runtime.Candidates)
    end
end

local function startBountyValueBinder()
    task.spawn(function()
        local activeStat
        local statConnection

        while Runtime.Running do
            if not activeStat or not activeStat.Parent then
                if statConnection then
                    statConnection:Disconnect()
                    statConnection = nil
                    Runtime.BountyConnection = nil
                end

                local leaderstats = LocalPlayer:FindFirstChild("leaderstats")
                local bountyStat = leaderstats and leaderstats:FindFirstChild("Bounty/Honor")

                if bountyStat and bountyStat:IsA("ValueBase") then
                    activeStat = bountyStat

                    local function update()
                        if Runtime.Labels.Bounty then
                            Runtime.Labels.Bounty.Text = "Bounty/Honor: " .. formatNumber(bountyStat.Value)
                        end
                    end

                    update()
                    statConnection = bountyStat:GetPropertyChangedSignal("Value"):Connect(update)
                    Runtime.BountyConnection = statConnection
                else
                    warnOnce(
                        "leaderstats:bounty-honor",
                        'Could not find LocalPlayer.leaderstats["Bounty/Honor"]; the GUI will keep retrying.'
                    )
                end
            end

            task.wait(1)
        end

        if statConnection then
            statConnection:Disconnect()
            Runtime.BountyConnection = nil
        end
    end)
end

local function pointInsidePart(part, worldPosition, epsilon)
    if not part or not part.Parent or not part:IsA("BasePart") then
        return false
    end

    local localPosition = part.CFrame:PointToObjectSpace(worldPosition)
    local halfSize = part.Size * 0.5
    local allowance = epsilon or 0

    return math.abs(localPosition.X) <= halfSize.X + allowance
        and math.abs(localPosition.Y) <= halfSize.Y + allowance
        and math.abs(localPosition.Z) <= halfSize.Z + allowance
end

local function rebuildSafeZoneCache()
    table.clear(Runtime.SafeZoneParts)
    Runtime.SafeZonesReady = false

    local folder = Runtime.SafeZonesFolder

    if not folder or not folder.Parent then
        return
    end

    for _, descendant in ipairs(folder:GetDescendants()) do
        if descendant:IsA("BasePart") then
            Runtime.SafeZoneParts[descendant] = true
            Runtime.SafeZonesReady = true
        end
    end

    if not Runtime.SafeZonesReady then
        warnOnce("safe-zones:empty", "The SafeZones folder has no replicated BasePart yet; targeting is paused.")
    end
end

local function findSafeZonesFolder()
    local worldOrigin = Workspace:FindFirstChild("_WorldOrigin")
    return worldOrigin and worldOrigin:FindFirstChild("SafeZones")
end

local function unbindSafeZones()
    disconnectConnections(Runtime.SafeZoneConnections)
    Runtime.SafeZonesFolder = nil
    Runtime.SafeZonesReady = false
    table.clear(Runtime.SafeZoneParts)
end

local function bindSafeZones(folder)
    if Runtime.SafeZonesFolder == folder then
        return
    end

    disconnectConnections(Runtime.SafeZoneConnections)
    Runtime.SafeZonesFolder = folder
    rebuildSafeZoneCache()

    local addedConnection = folder.DescendantAdded:Connect(function(descendant)
        if Runtime.SafeZonesFolder == folder and descendant:IsA("BasePart") then
            Runtime.SafeZoneParts[descendant] = true
            Runtime.SafeZonesReady = true
        end
    end)

    local removingConnection = folder.DescendantRemoving:Connect(function(descendant)
        if Runtime.SafeZonesFolder == folder then
            Runtime.SafeZoneParts[descendant] = nil
            Runtime.SafeZonesReady = next(Runtime.SafeZoneParts) ~= nil
        end
    end)

    table.insert(Runtime.SafeZoneConnections, addedConnection)
    table.insert(Runtime.SafeZoneConnections, removingConnection)
end

local function startSafeZoneBinder()
    task.spawn(function()
        while Runtime.Running do
            local folder = findSafeZonesFolder()

            if folder then
                bindSafeZones(folder)
            else
                if Runtime.SafeZonesFolder then
                    unbindSafeZones()
                end

                warnOnce(
                    "safe-zones:missing",
                    "workspace._WorldOrigin.SafeZones is missing; targeting is paused until it appears."
                )
            end

            task.wait(1)
        end
    end)
end

local function getSafeZoneCenterPart(part, folder)
    if not part
        or not part.Parent
        or not part:IsA("BasePart")
        or not part:IsDescendantOf(folder) then

        return nil
    end

    local ancestor = part.Parent

    while ancestor and ancestor ~= folder do
        if ancestor:IsA("Model") then
            local primary = ancestor.PrimaryPart

            if primary
                and primary.Parent
                and primary:IsA("BasePart")
                and primary:IsDescendantOf(ancestor)
                and primary:IsDescendantOf(folder) then

                return primary
            end
        end

        ancestor = ancestor.Parent
    end

    return part
end

local function isInsideSafeZone(worldPosition)
    if not Runtime.SafeZonesFolder
        or not Runtime.SafeZonesFolder.Parent
        or not Runtime.SafeZonesReady
        or not isFiniteVector3(worldPosition) then

        return nil
    end

    local checkedCenters = {}
    local hasValidCenter = false

    for part in pairs(Runtime.SafeZoneParts) do
        local centerPart = getSafeZoneCenterPart(part, Runtime.SafeZonesFolder)

        if centerPart and not checkedCenters[centerPart] then
            checkedCenters[centerPart] = true
            local center = centerPart.Position

            if isFiniteVector3(center) then
                hasValidCenter = true

                if (worldPosition - center).Magnitude <= SafeZoneRadius then
                    return true
                end
            end
        end
    end

    if not hasValidCenter then
        return nil
    end

    return false
end

Runtime.ReleaseGunClick = function(owner)
    if not Runtime.GunMouseHeld or (owner and Runtime.GunMouseHeld ~= owner) then
        return
    end

    Runtime.GunMouseHeld = nil
    pcall(function()
        VirtualUser:Button1Up(Vector2.new(1280, 672))
    end)
end

local function releaseAllKeys()
    Runtime.ReleaseGunClick()

    for keyName, keyCode in pairs(Runtime.PressedKeys) do
        pcall(function()
            VirtualInputManager:SendKeyEvent(false, keyCode, false, game)
        end)
    end

    table.clear(Runtime.PressedKeys)
end

local function pressKeyDown(keyName)
    local keyCode = Enum.KeyCode[keyName]

    if not keyCode then
        warnOnce("skill:key:" .. tostring(keyName), "Unsupported skill key " .. tostring(keyName) .. ".")
        return false
    end

    local success, result = pcall(function()
        VirtualInputManager:SendKeyEvent(true, keyCode, false, game)
    end)

    if success then
        Runtime.PressedKeys[keyName] = keyCode
        return true
    end

    warnOnce("skill:key-down:" .. keyName, "Could not press " .. keyName .. ": " .. tostring(result))
    return false
end

local function releaseKey(keyName)
    local keyCode = Runtime.PressedKeys[keyName] or Enum.KeyCode[keyName]

    if keyCode then
        pcall(function()
            VirtualInputManager:SendKeyEvent(false, keyCode, false, game)
        end)
    end

    Runtime.PressedKeys[keyName] = nil
end

local function restoreTargetHitbox()
    local snapshot = Runtime.HitboxSnapshot
    Runtime.HitboxSnapshot = nil

    if not snapshot or not snapshot.Part or not snapshot.Part.Parent then
        return
    end

    pcall(function()
        if snapshot.Part.Size == ConfiguredHitboxSize then
            snapshot.Part.Size = snapshot.Size
        end

        if snapshot.Part.CanCollide == false then
            snapshot.Part.CanCollide = snapshot.CanCollide
        end

        if snapshot.Part.Massless == true then
            snapshot.Part.Massless = snapshot.Massless
        end

        if snapshot.Part.Transparency == ConfiguredHitboxTransparency then
            snapshot.Part.Transparency = snapshot.Transparency
        end
    end)
end

local function applyTargetHitbox(root)
    if not HitboxEnabled or not root or not root.Parent then
        return
    end

    local snapshot = Runtime.HitboxSnapshot

    if snapshot and snapshot.Part == root then
        pcall(function()
            root.Size = ConfiguredHitboxSize
            root.CanCollide = false
            root.Transparency = ConfiguredHitboxTransparency
        end)
        return
    end

    restoreTargetHitbox()
    Runtime.HitboxSnapshot = {
        Part = root,
        Size = root.Size,
        CanCollide = root.CanCollide,
        Massless = root.Massless,
        Transparency = root.Transparency,
    }

    pcall(function()
        root.Size = ConfiguredHitboxSize
        root.CanCollide = false
        root.Transparency = ConfiguredHitboxTransparency
    end)
end

local function destroyLocalBodyClip()
    local bodyClip = Runtime.BodyClip

    Runtime.BodyClip = nil
    Runtime.BodyClipRoot = nil

    if bodyClip then
        pcall(function()
            bodyClip:Destroy()
        end)
    end
end

local function restoreLocalCollision()
    destroyLocalBodyClip()

    for part, canCollide in pairs(Runtime.LocalCollisionSnapshot) do
        pcall(function()
            if part.Parent and part.CanCollide == false then
                part.CanCollide = canCollide
            end
        end)
    end

    table.clear(Runtime.LocalCollisionSnapshot)
    Runtime.LocalCollisionCharacter = nil
end

local function applyLocalNoClip()
    local character = Runtime.Character
    local root = Runtime.Root

    if not NoClipEnabled then
        restoreLocalCollision()
        return
    end

    if not character
        or character ~= LocalPlayer.Character
        or not character.Parent
        or not root
        or not root.Parent
        or not root:IsDescendantOf(character) then

        restoreLocalCollision()
        return
    end

    if (Runtime.LocalCollisionCharacter
            and Runtime.LocalCollisionCharacter ~= character)
        or (Runtime.BodyClipRoot and Runtime.BodyClipRoot ~= root) then

        restoreLocalCollision()
    end

    Runtime.LocalCollisionCharacter = character

    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("BasePart") then
            if Runtime.LocalCollisionSnapshot[descendant] == nil then
                Runtime.LocalCollisionSnapshot[descendant] = descendant.CanCollide
            end

            descendant.CanCollide = false
        end
    end

    local bodyClip = Runtime.BodyClip

    if not bodyClip
        or not bodyClip:IsA("BodyVelocity")
        or bodyClip.Parent ~= root then

        destroyLocalBodyClip()

        local foreignBodyClip = false

        for _, child in ipairs(root:GetChildren()) do
            if child.Name == "BodyClip" and child:GetAttribute("__AutoBountyOwned") == true then
                pcall(function()
                    child:Destroy()
                end)
            elseif child.Name == "BodyClip" then
                foreignBodyClip = true
                warnOnce(
                    "noclip:foreign-bodyclip:" .. tostring(Runtime.CharacterEpoch),
                    "A non-AutoBounty object named BodyClip already exists on the local HumanoidRootPart; leaving it unchanged and not creating a duplicate."
                )
            end
        end

        if foreignBodyClip then
            return
        end

        bodyClip = Instance.new("BodyVelocity")
        bodyClip.Name = "BodyClip"
        bodyClip.MaxForce = Vector3.new(100000, 100000, 100000)
        bodyClip.Velocity = Vector3.new(0, 0, 0)
        bodyClip:SetAttribute("__AutoBountyOwned", true)
        bodyClip.Parent = root
        Runtime.BodyClip = bodyClip
        Runtime.BodyClipRoot = root
    else
        bodyClip.MaxForce = Vector3.new(100000, 100000, 100000)
        bodyClip.Velocity = Vector3.new(0, 0, 0)
    end
end

local function readLevel(player)
    local data = player and player:FindFirstChild("Data")
    local level = data and data:FindFirstChild("Level")
    local value

    if level and level:IsA("ValueBase") then
        local success, result = pcall(function()
            return tonumber(level.Value)
        end)

        if success then
            value = result
        end
    end

    if not value then
        warnOnce(
            "level:" .. tostring(player and player.UserId or "missing"),
            "A valid Data.Level value is not available for " .. tostring(player and player.Name or "an unknown player") .. "."
        )
    end

    return value
end

local function getTeamObjects()
    local pirates = Teams:FindFirstChild("Pirates")
    local marines = Teams:FindFirstChild("Marines")

    if not pirates or not marines then
        warnOnce("teams:missing", "The Pirates or Marines Team object is missing; targeting is paused.")
    end

    return pirates, marines
end

local function isAllowedTeam(localTeam, targetTeam)
    local pirates, marines = getTeamObjects()

    if not pirates or not marines then
        return false
    end

    if localTeam == pirates then
        return targetTeam == pirates or targetTeam == marines
    end

    if localTeam == marines then
        return targetTeam == pirates
    end

    return false
end

local requestHop
local enterSafeMode
local exitSafeMode
local cancelFollowTimeoutHop
local determineHopReason

local function requestFriendCheck(player)
    if not player or player == LocalPlayer or player.Parent ~= Players then
        return
    end

    Runtime.FriendLookup = Runtime.FriendLookup or {}
    Runtime.FriendRetryAt = Runtime.FriendRetryAt or {}

    local retryAt = Runtime.FriendRetryAt[player.UserId]
    local cached = Runtime.FriendCache[player.UserId]
    local checkedAt = Runtime.FriendCheckedAt[player.UserId]

    if cached == true then
        return
    end

    if cached == false
        and checkedAt
        and os.clock() - checkedAt < INTERNAL.NonFriendCacheTTL then

        return
    end

    if cached == false then
        Runtime.FriendCache[player.UserId] = nil
    end

    if Runtime.FriendLookup[player.UserId]
        or (retryAt and os.clock() < retryAt) then

        return
    end

    Runtime.FriendLookup[player.UserId] = true
    Runtime.FriendAuditComplete = false

    task.spawn(function()
        local resolved

        for attempt = 1, 3 do
            if not Runtime.Running or player.Parent ~= Players then
                break
            end

            local success, isFriend = pcall(function()
                return LocalPlayer:IsFriendsWithAsync(player.UserId)
            end)

            if not success then
                success, isFriend = pcall(function()
                    return LocalPlayer:IsFriendsWith(player.UserId)
                end)
            end

            if success then
                resolved = isFriend == true
                break
            end

            task.wait(attempt * 0.5)
        end

        if Runtime.Running and player.Parent == Players then
            if resolved == nil then
                Runtime.FriendRetryAt[player.UserId] = os.clock() + 5
                warnOnce(
                    "friend-check:" .. tostring(player.UserId),
                    "Friend status could not be resolved for " .. player.Name .. "; targeting stays paused and the check will retry."
                )
            else
                Runtime.FriendRetryAt[player.UserId] = nil
                Runtime.FriendCache[player.UserId] = resolved
                Runtime.FriendCheckedAt[player.UserId] = os.clock()

                if resolved and requestHop then
                    requestHop("friend", player.Name)
                end
            end
        end

        Runtime.FriendLookup[player.UserId] = nil
    end)
end

local function findFriendInServer()
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and Runtime.FriendCache[player.UserId] == true then
            return player
        end
    end

    return nil
end

local function getTargetRoute(player, info)
    local localRoot = Runtime.Root
    local targetRoot = info and info.Root

    if not localRoot
        or not localRoot.Parent
        or not isFiniteVector3(localRoot.Position) then

        return nil, "local-position-pending"
    end

    if not targetRoot
        or not targetRoot.Parent
        or not isFiniteVector3(targetRoot.Position) then

        return nil, "invalid-position"
    end

    local directDistance = (targetRoot.Position - localRoot.Position).Magnitude

    if directDistance < MaxTargetDistance then
        return {
            Kind = "direct",
            Distance = directDistance,
        }
    end

    if not FastTPEnabled then
        return nil, "target-out-of-range"
    end

    local failedRoutes = Runtime.RouteFailures[player]
    local failedEntrances = failedRoutes
        and failedRoutes.Character == info.Character
        and failedRoutes.Entrances
    local selectedEntrance
    local selectedDistance = math.huge
    local hasFailedRoute = false

    for _, entrance in ipairs(ENTRANCES[game.PlaceId] or {}) do
        if isFiniteVector3(entrance) then
            local distance = (targetRoot.Position - entrance).Magnitude

            if distance < MaxTargetDistance then
                if failedEntrances and failedEntrances[entrance] then
                    hasFailedRoute = true
                elseif distance < selectedDistance then
                    selectedEntrance = entrance
                    selectedDistance = distance
                end
            end
        end
    end

    if selectedEntrance then
        return {
            Kind = "entrance",
            Distance = selectedDistance,
            Entrance = selectedEntrance,
        }
    end

    return nil, hasFailedRoute and "entrance-route-failed" or "target-out-of-range"
end

local function evaluateTarget(player)
    if not player or player == LocalPlayer or player.Parent ~= Players then
        return false, "self-or-left"
    end

    if SkipPreviousTargets and Runtime.PreviouslyTargeted[player.UserId] then
        return false, "previously-targeted"
    end

    requestFriendCheck(player)

    if Runtime.FriendCache[player.UserId] == nil then
        return false, "friend-pending"
    end

    if Runtime.FriendCache[player.UserId] == true then
        return false, "friend"
    end

    local localLevel = readLevel(LocalPlayer)
    local targetLevel = readLevel(player)

    if not localLevel or not targetLevel then
        return false, "level-pending"
    end

    if math.abs(localLevel - targetLevel) > INTERNAL.MaxLevelDifference then
        return false, "level-gap"
    end

    if not isAllowedTeam(LocalPlayer.Team, player.Team) then
        return false, "team"
    end

    local pvpDisabled = readBooleanAttribute(player, "PvpDisabled", false)

    if pvpDisabled == true then
        return false, "pvp-disabled"
    end

    local character, humanoid, root = getAliveCharacter(player)

    if not character then
        return false, "dead-or-respawning"
    end

    if not isFiniteVector3(root.Position) then
        return false, "invalid-position"
    end

    if root.Position.Y < INTERNAL.MinimumTweenY then
        return false, "below-sea-level"
    end

    local followTimeoutCharacter = Runtime.FollowTimeoutCharacters[player]

    if followTimeoutCharacter then
        if followTimeoutCharacter == character then
            return false, "follow-timeout-target"
        end

        Runtime.FollowTimeoutCharacters[player] = nil
    end

    local noProgressCharacter = Runtime.NoProgressCharacters[player]

    if noProgressCharacter then
        if noProgressCharacter == character then
            return false, "no-health-progress"
        end

        Runtime.NoProgressCharacters[player] = nil
    end

    local inSafeZone = isInsideSafeZone(root.Position)

    if inSafeZone == nil then
        return false, "safe-zones-pending"
    end

    if inSafeZone then
        return false, "safe-zone"
    end

    return true, {
        Player = player,
        Character = character,
        Humanoid = humanoid,
        Root = root,
        Level = targetLevel,
    }
end

local PENDING_TARGET_REASON = {
    ["friend-pending"] = true,
    ["level-pending"] = true,
    ["dead-or-respawning"] = true,
    ["safe-zones-pending"] = true,
    ["local-position-pending"] = true,
}

local function rebuildCandidates()
    local directCandidates = {}
    local entranceCandidates = {}
    local candidateInfo = {}
    local candidateReasons = {}
    local pendingCount = 0
    local now = os.clock()

    if Runtime.SafeZonesFolder and Runtime.SafeZonesFolder.Parent and Runtime.SafeZonesReady then
        for _, player in ipairs(Players:GetPlayers()) do
            local eligible, result = evaluateTarget(player)

            if eligible then
                local route, routeReason = getTargetRoute(player, result)

                if route then
                    result.Route = route
                    candidateInfo[player] = result
                    candidateReasons[player] = "eligible-" .. route.Kind
                    Runtime.PendingSince[player] = nil

                    if route.Kind == "direct" then
                        table.insert(directCandidates, player)
                    else
                        table.insert(entranceCandidates, player)
                    end
                else
                    eligible = false
                    result = routeReason
                end
            end

            if not eligible and player ~= LocalPlayer then
                candidateReasons[player] = result

                if PENDING_TARGET_REASON[result] then
                    local pending = Runtime.PendingSince[player]

                    if type(pending) ~= "table" or pending.Reason ~= result then
                        pending = {
                            Reason = result,
                            Since = now,
                        }
                        Runtime.PendingSince[player] = pending
                    end

                    if result == "local-position-pending"
                        or now - pending.Since < INTERNAL.PendingTargetGrace then

                        pendingCount = pendingCount + 1
                    end
                else
                    Runtime.PendingSince[player] = nil
                end
            end
        end
    end

    for player in pairs(Runtime.PendingSince) do
        if player.Parent ~= Players or candidateReasons[player] == nil then
            Runtime.PendingSince[player] = nil
        end
    end

    local candidates = #directCandidates > 0 and directCandidates or entranceCandidates

    table.sort(candidates, function(firstPlayer, secondPlayer)
        local firstInfo = candidateInfo[firstPlayer]
        local secondInfo = candidateInfo[secondPlayer]
        local firstDistance = firstInfo.Route.Distance
        local secondDistance = secondInfo.Route.Distance

        if firstDistance ~= secondDistance then
            return firstDistance < secondDistance
        end

        return firstPlayer.UserId < secondPlayer.UserId
    end)

    Runtime.Candidates = candidates
    Runtime.CandidateInfo = candidateInfo
    Runtime.CandidateReasons = candidateReasons
    Runtime.PendingCandidateCount = pendingCount
    updateTargetGUI()
    return candidates
end

local function stopSeaHeightMovement()
    local movement = Runtime.SeaHeightMove
    Runtime.SeaHeightMove = nil

    if not movement then
        return
    end

    if movement.Connection then
        movement.Connection:Disconnect()
        movement.Connection = nil
    end

    if movement.Tween then
        movement.Tween:Cancel()
        movement.Tween = nil
    end
end

local function stopSafeModeMovement()
    local movement = Runtime.SafeModeMovement
    Runtime.SafeModeMovement = nil

    if movement and movement.Tween then
        movement.Tween:Cancel()

        if Runtime.ActiveTween == movement.Tween then
            Runtime.ActiveTween = nil
        end
    end
end

local function resetTargetTimers()
    -- Hop requests may clear targets while recovery continues; keep its center.
    if not Runtime.Running or not Runtime.SafeMode then
        stopSafeModeMovement()
    end

    stopSeaHeightMovement()
    Runtime.ChaseMoveCycle = nil
    Runtime.ChaseTweenTimeMultiplier = nil
    Runtime.FollowNoCombatSince = nil
    Runtime.FollowTimerEpoch = nil
    Runtime.FollowTimerCharacterEpoch = nil
    Runtime.DamageCheckDeadline = nil
    Runtime.DamageCheckLastHealth = nil
    Runtime.DamageCheckEpoch = nil
    Runtime.DamageCheckCharacterEpoch = nil
    Runtime.DamageCheckExpired = false
    Runtime.DamageObserved = false
end

local function clearTarget(reason)
    if SkipPreviousTargets and Runtime.CurrentTarget then
        Runtime.PreviouslyTargeted[Runtime.CurrentTarget.UserId] = true
    end

    Runtime.TargetEpoch = Runtime.TargetEpoch + 1
    Runtime.AimActive = false
    Runtime.GunAimActive = false
    Runtime.AimPosition = nil
    Runtime.InsideHitbox = false
    Runtime.CurrentTool = nil
    resetTargetTimers()
    disconnectConnections(Runtime.TargetConnections)
    releaseAllKeys()
    restoreTargetHitbox()
    restoreLocalCollision()
    Runtime.CurrentTarget = nil
    Runtime.CurrentTargetInfo = nil

    if not Runtime.SafeMode and not Runtime.LocalDead and not Runtime.HopPending then
        Runtime.Mode = "SCAN"
    end

    if reason and Runtime.Running then
        setStatus(reason)
    end

    updateTargetGUI()
end

local function ensureCombatAttributes()
    setRequiredLocalAttribute("KenActive")
    setRequiredLocalAttribute("BusoEnabled")

    local character = Runtime.Character

    if character and character.Parent and not character:FindFirstChild("HasBuso") then
        local now = os.clock()

        if not Runtime.LastBusoAttempt or now - Runtime.LastBusoAttempt >= 1 then
            Runtime.LastBusoAttempt = now

            local success, result = pcall(function()
                return CommF:InvokeServer("Buso")
            end)

            if not success then
                warnOnce("buso:remote", "Buso activation failed: " .. tostring(result))
            end
        end
    end
end

local function startPvPEnable()
    if Runtime.PvPWorkerRunning or not Runtime.Running or Runtime.LocalDead then
        return
    end

    local disabled = readBooleanAttribute(LocalPlayer, "PvpDisabled", false)

    if disabled ~= true then
        return
    end

    Runtime.PvPWorkerRunning = true

    task.spawn(function()
        for attempt = 1, INTERNAL.PvPMaxAttempts do
            if not Runtime.Running or Runtime.LocalDead then
                break
            end

            local stillDisabled = readBooleanAttribute(LocalPlayer, "PvpDisabled", false)

            if stillDisabled ~= true then
                break
            end

            if not Runtime.SafeMode and not Runtime.HopPending then
                setStatus("Enabling PvP (attempt " .. tostring(attempt) .. ")")
            end

            local success, result = pcall(function()
                return CommF:InvokeServer("EnablePvp")
            end)

            if not success then
                warnOnce("pvp:enable-remote", "EnablePvp failed: " .. tostring(result))
            end

            task.wait(INTERNAL.PvPRetryDelay)
        end

        if Runtime.Running and LocalPlayer:GetAttribute("PvpDisabled") == true then
            warnOnce("pvp:still-disabled", "PvP is still disabled after the retry limit.")
        end

        Runtime.PvPWorkerRunning = false
    end)
end

local function invokeEntrance(position, purpose, targetEpoch, validityCheck)
    local function stillValid()
        if not validityCheck then
            return true
        end

        local success, result = pcall(validityCheck)
        return success and result == true
    end

    while Runtime.Running and Runtime.EntranceBusy do
        if (targetEpoch and Runtime.TargetEpoch ~= targetEpoch) or not stillValid() then
            return false
        end

        task.wait(0.05)
    end

    if not Runtime.Running
        or (targetEpoch and Runtime.TargetEpoch ~= targetEpoch)
        or not stillValid() then

        return false
    end

    if purpose == "FastTP" then
        local remaining = INTERNAL.FastTPCooldown - (os.clock() - Runtime.LastEntranceAt)

        while Runtime.Running and remaining > 0 do
            if (targetEpoch and Runtime.TargetEpoch ~= targetEpoch) or not stillValid() then
                return false
            end

            task.wait(math.min(remaining, 0.1))
            remaining = INTERNAL.FastTPCooldown - (os.clock() - Runtime.LastEntranceAt)
        end
    end

    if not stillValid() then
        return false
    end

    Runtime.EntranceBusy = true

    local success, result = pcall(function()
        return CommF:InvokeServer("requestEntrance", position)
    end)

    Runtime.LastEntranceAt = os.clock()
    Runtime.EntranceBusy = false

    if not success then
        warnOnce(
            "entrance:" .. purpose,
            purpose .. " requestEntrance failed: " .. tostring(result)
        )
    end

    return success
end

local function nearestEntrance(targetPosition)
    local entrances = ENTRANCES[game.PlaceId]

    if not entrances then
        warnOnce(
            "entrance:place:" .. tostring(game.PlaceId),
            "No FastTP entrance list is defined for PlaceId " .. tostring(game.PlaceId) .. "."
        )
        return nil
    end

    local selected
    local selectedDistance = math.huge

    for _, position in ipairs(entrances) do
        local distance = (position - targetPosition).Magnitude

        if distance < selectedDistance then
            selected = position
            selectedDistance = distance
        end
    end

    return selected, selectedDistance
end

local function fastTeleportForTarget(targetInfo, targetEpoch, targetPlayer, entrance)
    if not FastTPEnabled or not entrance or not isFiniteVector3(entrance) then
        return false, "unavailable"
    end

    local localRoot = Runtime.Root
    local targetRoot = targetInfo and targetInfo.Root
    local characterEpoch = Runtime.CharacterEpoch

    local function targetStillValid()
        local currentInfo = Runtime.CurrentTargetInfo

        return Runtime.Running
            and not Runtime.SafeMode
            and not Runtime.LocalDead
            and not Runtime.HopPending
            and Runtime.TargetEpoch == targetEpoch
            and Runtime.CharacterEpoch == characterEpoch
            and Runtime.CurrentTarget == targetPlayer
            and Runtime.Root == localRoot
            and localRoot ~= nil
            and localRoot.Parent ~= nil
            and isFiniteVector3(localRoot.Position)
            and currentInfo ~= nil
            and currentInfo.Character == targetInfo.Character
            and currentInfo.Humanoid == targetInfo.Humanoid
            and currentInfo.Root == targetRoot
            and targetPlayer.Parent == Players
            and targetPlayer.Character == targetInfo.Character
            and targetInfo.Character ~= nil
            and targetInfo.Humanoid ~= nil
            and targetInfo.Humanoid.Parent == targetInfo.Character
            and targetInfo.Humanoid.Health > 0
            and targetRoot ~= nil
            and targetRoot.Parent ~= nil
            and targetRoot:IsDescendantOf(targetInfo.Character)
            and isFiniteVector3(targetRoot.Position)
            and targetRoot.Position.Y >= INTERNAL.MinimumTweenY
            and targetPlayer:GetAttribute("PvpDisabled") ~= true
            and isInsideSafeZone(targetRoot.Position) == false
    end

    if not targetStillValid() then
        return false, "cancelled"
    end

    if (localRoot.Position - targetRoot.Position).Magnitude < MaxTargetDistance then
        return true
    end

    if (entrance - targetRoot.Position).Magnitude >= MaxTargetDistance then
        return false, "route-moved"
    end

    Runtime.Mode = "FAST_TP"
    setStatus("Entrance route toward " .. targetPlayer.Name)
    stopSeaHeightMovement()

    if Runtime.ActiveTween then
        Runtime.ActiveTween:Cancel()
        Runtime.ActiveTween = nil
    end

    local deadline = os.clock() + INTERNAL.FastTPCooldown + INTERNAL.FastTPArrivalTimeout
    local requestAllowed = true
    local requestFinished = false
    local requestSucceeded = false

    -- InvokeServer can yield; bound how long target preparation waits for this route.
    task.spawn(function()
        requestSucceeded = invokeEntrance(entrance, "FastTP", targetEpoch, function()
            return requestAllowed
                and os.clock() < deadline
                and targetStillValid()
                and (entrance - targetRoot.Position).Magnitude < MaxTargetDistance
                and (localRoot.Position - targetRoot.Position).Magnitude >= MaxTargetDistance
        end)
        requestFinished = true
    end)

    while os.clock() < deadline and targetStillValid() do
        -- Success means the target is actually in chase range, not just a 50-stud movement.
        if (localRoot.Position - targetRoot.Position).Magnitude < MaxTargetDistance then
            requestAllowed = false
            return true
        end

        if requestFinished and not requestSucceeded then
            requestAllowed = false

            if (entrance - targetRoot.Position).Magnitude >= MaxTargetDistance then
                return false, "route-moved"
            end

            return false, "request-failed"
        end

        task.wait(0.05)
    end

    requestAllowed = false

    if not targetStillValid() then
        return false, "cancelled"
    end

    if (localRoot.Position - targetRoot.Position).Magnitude < MaxTargetDistance then
        return true
    end

    if (entrance - targetRoot.Position).Magnitude >= MaxTargetDistance then
        return false, "route-moved"
    end

    return false, "arrival-timeout"
end

local function setTarget(player, targetInfo)
    if not Runtime.Running or Runtime.SafeMode or Runtime.LocalDead or Runtime.HopPending then
        return false
    end

    local eligible, refreshedInfo = evaluateTarget(player)

    if not eligible then
        return false
    end

    local route = getTargetRoute(player, refreshedInfo or targetInfo)

    if not route then
        return false
    end

    clearTarget()
    Runtime.CurrentTarget = player
    local preparedInfo = refreshedInfo or targetInfo
    preparedInfo.Route = route
    Runtime.CurrentTargetInfo = preparedInfo
    Runtime.Mode = "PREPARE"
    Runtime.TargetEpoch = Runtime.TargetEpoch + 1
    local targetEpoch = Runtime.TargetEpoch
    local preparationCharacterEpoch = Runtime.CharacterEpoch
    local preparationRoot = Runtime.Root
    local preparedHumanoid = preparedInfo and preparedInfo.Humanoid

    if preparedHumanoid and preparedHumanoid.Parent then
        local healthConnection = preparedHumanoid.HealthChanged:Connect(function(health)
            if not AttackEnabled
                or not Runtime.Running
                or Runtime.CurrentTarget ~= player
                or Runtime.TargetEpoch ~= targetEpoch
                or Runtime.DamageCheckEpoch ~= targetEpoch
                or Runtime.DamageObserved
                or not Runtime.DamageCheckDeadline then

                return
            end

            local previousHealth = Runtime.DamageCheckLastHealth

            if os.clock() >= Runtime.DamageCheckDeadline then
                Runtime.DamageCheckExpired = true
                return
            end

            if previousHealth and health < previousHealth then
                Runtime.DamageObserved = true
                Runtime.DamageCheckDeadline = nil
            else
                Runtime.DamageCheckLastHealth = health
            end
        end)
        table.insert(Runtime.TargetConnections, healthConnection)
    end

    updateTargetGUI()
    setStatus("Preparing " .. player.Name)

    task.spawn(function()
        if Runtime.TargetEpoch ~= targetEpoch or Runtime.CurrentTarget ~= player then
            return
        end

        local function preparationStillValid()
            return Runtime.Running
                and not Runtime.LocalDead
                and not Runtime.SafeMode
                and not Runtime.HopPending
                and Runtime.TargetEpoch == targetEpoch
                and Runtime.CurrentTarget == player
                and Runtime.CharacterEpoch == preparationCharacterEpoch
                and Runtime.Root == preparationRoot
                and preparationRoot ~= nil
                and preparationRoot.Parent ~= nil
                and Runtime.Humanoid ~= nil
                and Runtime.Humanoid.Health > 0
        end

        ensureCombatAttributes()

        if not preparationStillValid() then
            if Runtime.TargetEpoch == targetEpoch and Runtime.CurrentTarget == player then
                clearTarget("Local character changed during target preparation")
            end

            return
        end

        startPvPEnable()

        if route.Kind == "entrance" then
            local arrived, failure = fastTeleportForTarget(preparedInfo, targetEpoch, player, route.Entrance)

            if Runtime.TargetEpoch ~= targetEpoch or Runtime.CurrentTarget ~= player then
                return
            end

            if not arrived then
                if failure ~= "cancelled" and failure ~= "route-moved" then
                    local failures = Runtime.RouteFailures[player]

                    if not failures or failures.Character ~= preparedInfo.Character then
                        failures = {Character = preparedInfo.Character, Entrances = {}}
                        Runtime.RouteFailures[player] = failures
                    end

                    failures.Entrances[route.Entrance] = true
                end

                clearTarget("Entrance route unavailable; checking other targets or entrances")
                return
            end
        end

        if not preparationStillValid() then
            if Runtime.TargetEpoch == targetEpoch and Runtime.CurrentTarget == player then
                clearTarget("Local character changed during target preparation")
            end

            return
        end

        local stillEligible, latestInfo = evaluateTarget(player)

        if not stillEligible then
            clearTarget("Target became unavailable")
            return
        end

        if latestInfo.Character ~= preparedInfo.Character
            or latestInfo.Humanoid ~= preparedInfo.Humanoid
            or latestInfo.Root ~= preparedInfo.Root then

            clearTarget("Target character changed; reacquiring")
            return
        end

        local latestRoute = getTargetRoute(player, latestInfo)

        if not latestRoute or latestRoute.Kind ~= "direct" then
            clearTarget("Target is outside MaxTargetDistance; checking other routes")
            return
        end

        latestInfo.Route = latestRoute
        Runtime.CurrentTargetInfo = latestInfo
        applyTargetHitbox(latestInfo.Root)
        Runtime.Mode = "CHASE"
        setStatus("Chasing " .. player.Name)
    end)

    return true
end

local function canAttack(targetEpoch, attackMode, readOnly)
    local gunApproach = attackMode == "GunApproach"

    if not AttackEnabled
        or not Runtime.Running
        or Runtime.TargetEpoch ~= targetEpoch
        or not Runtime.CurrentTarget
        or Runtime.SafeMode
        or Runtime.LocalDead
        or Runtime.HopPending
        or not Runtime.FriendAuditComplete then

        return false
    end

    if gunApproach then
        local gunConfig = WeaponConfig.Gun

        if not GunOpenerEnabled
            or type(gunConfig) ~= "table"
            or gunConfig.Enabled ~= true
            or Runtime.Mode ~= "CHASE"
            or Runtime.InsideHitbox then

            return false
        end
    elseif Runtime.Mode ~= "ENGAGE" or not Runtime.InsideHitbox then
        return false
    end

    local localCharacter = Runtime.Character
    local localHumanoid = Runtime.Humanoid
    local localRoot = Runtime.Root
    local targetPlayer = Runtime.CurrentTarget
    local targetInfo = Runtime.CurrentTargetInfo
    local targetCharacter = targetInfo and targetInfo.Character
    local targetHumanoid = targetInfo and targetInfo.Humanoid
    local targetRoot = targetInfo and targetInfo.Root

    if not localCharacter
        or localCharacter ~= LocalPlayer.Character
        or not localHumanoid
        or not localHumanoid.Parent
        or localHumanoid.Parent ~= localCharacter
        or localHumanoid.Health <= 0
        or not targetInfo
        or targetInfo.Player ~= targetPlayer
        or not targetPlayer
        or targetPlayer.Parent ~= Players
        or targetPlayer.Character ~= targetCharacter
        or not targetCharacter
        or not targetCharacter.Parent
        or not targetHumanoid
        or targetHumanoid.Parent ~= targetCharacter
        or targetHumanoid.Health <= 0
        or not localRoot
        or not localRoot.Parent
        or not localRoot.IsDescendantOf(localRoot, localCharacter)
        or not isFiniteVector3(localRoot.Position)
        or localRoot.Position.Y < INTERNAL.MinimumTweenY
        or not targetRoot
        or not targetRoot.IsDescendantOf(targetRoot, targetCharacter)
        or not isFiniteVector3(targetRoot.Position)
        or targetRoot.Position.Y < INTERNAL.MinimumTweenY then

        return false
    end

    if gunApproach and (localRoot.Position - targetRoot.Position).Magnitude > GunEngageDistance then
        return false
    end

    if LocalPlayer.GetAttribute(LocalPlayer, "PvpDisabled") == true then
        if not readOnly then
            startPvPEnable()
        end
        return false
    end

    if Runtime.CurrentTarget.GetAttribute(Runtime.CurrentTarget, "PvpDisabled") == true then
        return false
    end

    return true
end

Runtime.IsGunAimAllowed = function()
    local tool = Runtime.CurrentTool
    local gunConfig = WeaponConfig.Gun

    if not Runtime.GunAimActive
        or not Runtime.AimActive
        or not tool or tool.Parent ~= Runtime.Character
        or type(gunConfig) ~= "table"
        or gunConfig.Enabled ~= true then

        return false
    end

    local configuredName = tostring(gunConfig.Name or "Auto")
    local matches = configuredName == "" or string.lower(configuredName) == "auto"

    if matches then
        matches = tool.ToolTip == "Gun"
    else
        matches = tool.Name == configuredName
    end

    return matches and canAttack(Runtime.TargetEpoch, "GunApproach", true)
end

local function getTargetTweenTimeMultiplier(localRoot, targetRoot)
    if not TweenHitboxEnabled
        or not localRoot or not localRoot.Parent
        or not targetRoot or not targetRoot.Parent
        or not isFiniteVector3(localRoot.Position)
        or not isFiniteVector3(targetRoot.Position) then

        return 1
    end

    local offset = targetRoot.CFrame:PointToObjectSpace(localRoot.Position)
    local halfSize = TweenHitboxSize * 0.5

    if math.abs(offset.X) <= halfSize.X
        and math.abs(offset.Y) <= halfSize.Y
        and math.abs(offset.Z) <= halfSize.Z then

        return TweenHitboxTimeMultiplier
    end

    return 1
end

local function AutoTween(goalCFrame, deltaTime, insideHitbox, timeMultiplier)
    stopSeaHeightMovement()
    local root = Runtime.Root

    if not root or not root.Parent or typeof(goalCFrame) ~= "CFrame" then
        return
    end

    local currentCFrame = clampCFrameAboveSea(root.CFrame)
    local safeGoalCFrame = clampCFrameAboveSea(goalCFrame)

    if not currentCFrame or not safeGoalCFrame then
        return
    end

    local distance = (safeGoalCFrame.Position - currentCFrame.Position).Magnitude
    local speed = insideHitbox
        and TweenSpeed * INTERNAL.InHitboxSpeedMultiplier
        or TweenSpeed

    if speed <= 0 then
        return
    end

    local duration = (distance / speed) * (timeMultiplier or 1)
    root.CFrame = currentCFrame

    Runtime.ActiveTween = game:GetService("TweenService"):Create(
        root,
        TweenInfo.new(duration, Enum.EasingStyle.Linear),
        { CFrame = safeGoalCFrame }
    )
    Runtime.ActiveTween:Play()
end

local function updateSeaHeightMovement(goalCFrame, now, targetEpoch, characterEpoch, localRoot)
    if not Runtime.Running
        or Runtime.SafeMode
        or Runtime.LocalDead
        or Runtime.HopPending
        or Runtime.TargetEpoch ~= targetEpoch
        or Runtime.CharacterEpoch ~= characterEpoch
        or not Runtime.CurrentTarget
        or Runtime.Root ~= localRoot
        or not localRoot
        or not localRoot.Parent
        or not isFiniteVector3(localRoot.Position)
        or typeof(goalCFrame) ~= "CFrame" then

        stopSeaHeightMovement()
        return
    end

    local movement = Runtime.SeaHeightMove

    if movement
        and (movement.TargetEpoch ~= targetEpoch
            or movement.CharacterEpoch ~= characterEpoch
            or movement.Root ~= localRoot) then

        stopSeaHeightMovement()
        movement = nil
    end

    if not movement then
        local stallTimeout = tonumber(Settings.SeaHeightStallTimeout)

        if not stallTimeout or stallTimeout ~= stallTimeout or stallTimeout <= 0 or stallTimeout == math.huge then
            stallTimeout = 3
        end

        movement = {
            TargetEpoch = targetEpoch,
            CharacterEpoch = characterEpoch,
            Root = localRoot,
            ResumeAt = now,
            StallTimeout = stallTimeout,
            LastProgressAt = now,
            ProgressDistance = nil,
            RetryCount = 0,
        }
        Runtime.SeaHeightMove = movement
        Runtime.ChaseMoveCycle = nil
    end

    local currentCFrame = clampCFrameAboveSea(localRoot.CFrame)
    local safeGoal = clampCFrameAboveSea(goalCFrame)

    if not currentCFrame or not safeGoal then
        stopSeaHeightMovement()
        return
    end

    local position = currentCFrame.Position
    local differenceY = safeGoal.Position.Y - position.Y
    local distance = math.abs(differenceY)

    if distance <= 0.001 then
        stopSeaHeightMovement()
        return
    end

    -- Check actual vertical progress even while a segment still owns a tween.
    -- Small oscillations cannot continually restart the timeout.
    if not movement.ProgressDistance or distance <= movement.ProgressDistance - 0.5 then
        movement.ProgressDistance = distance
        movement.LastProgressAt = now
    elseif now - movement.LastProgressAt >= movement.StallTimeout then
        if movement.Connection then
            movement.Connection:Disconnect()
            movement.Connection = nil
        end

        if movement.Tween then
            movement.Tween:Cancel()
            movement.Tween = nil
        end

        if movement.RetryCount >= 1 then
            clearTarget("Sea-height movement stalled after retry; finding another target")
            return
        end

        movement.RetryCount = movement.RetryCount + 1
        movement.ProgressDistance = distance
        movement.LastProgressAt = now
        movement.ResumeAt = now
        setStatus("Sea-height movement stalled; retrying")
    end

    if movement.Tween or now < movement.ResumeAt then
        return
    end

    -- A completed segment cannot continue moving during the following pause.
    local step = math.min(distance, INTERNAL.SeaHeightTweenSpeed * INTERNAL.SeaHeightMoveDuration)
    local nextY = position.Y + (differenceY < 0 and -step or step)
    local stepGoal = CFrame.new(position.X, nextY, position.Z) * currentCFrame.Rotation

    localRoot.CFrame = currentCFrame

    local tween = game:GetService("TweenService"):Create(
        localRoot,
        TweenInfo.new(step / INTERNAL.SeaHeightTweenSpeed, Enum.EasingStyle.Linear),
        { CFrame = stepGoal }
    )
    movement.Tween = tween
    movement.Connection = tween.Completed:Connect(function(playbackState)
        if Runtime.SeaHeightMove ~= movement or movement.Tween ~= tween then
            return
        end

        movement.Connection:Disconnect()
        movement.Connection = nil
        movement.Tween = nil

        if not Runtime.Running
            or Runtime.SafeMode
            or Runtime.LocalDead
            or Runtime.HopPending
            or Runtime.TargetEpoch ~= targetEpoch
            or Runtime.CharacterEpoch ~= characterEpoch
            or not Runtime.CurrentTarget
            or Runtime.Root ~= localRoot
            or not localRoot.Parent
            or not isFiniteVector3(localRoot.Position)
            or localRoot.Position.Y <= INTERNAL.MinimumTweenY + 0.001 then

            stopSeaHeightMovement()
            return
        end

        -- Cancellation must not erase the accumulated stall time or retry count.
        movement.ResumeAt = os.clock() + INTERNAL.SeaHeightPauseDuration
    end)
    tween:Play()
end

local function getSafeModeMovementGoal(root)
    local movement = Runtime.SafeModeMovement

    if not movement
        or movement.Root ~= root
        or movement.SafeEpoch ~= Runtime.SafeEpoch
        or movement.CharacterEpoch ~= Runtime.CharacterEpoch then

        stopSafeModeMovement()
        movement = {
            Root = root,
            SafeEpoch = Runtime.SafeEpoch,
            CharacterEpoch = Runtime.CharacterEpoch,
            Center = Vector3.new(root.Position.X, SafeModeY, root.Position.Z),
            Angle = math.random() * math.pi * 2,
        }
        Runtime.SafeModeMovement = movement
    end

    if not SafeModePanicEnabled then
        return CFrame.new(root.Position.X, SafeModeY, root.Position.Z)
            * root.CFrame.Rotation
    end

    -- Keep each destination until reached so rapid updates cannot stall ascent.
    if not movement.Goal or (root.Position - movement.Goal).Magnitude <= 3 then
        if movement.Goal then
            movement.Angle = movement.Angle + math.pi * (0.5 + math.random())
        end

        local radius = SafeModePanicRadius * (0.5 + math.random() * 0.5)
        movement.Goal = movement.Center + Vector3.new(
            math.cos(movement.Angle) * radius,
            0,
            math.sin(movement.Angle) * radius
        )
    end

    return CFrame.new(movement.Goal) * root.CFrame.Rotation
end

local function updateSafeModeMovement(deltaTime)
    local character = Runtime.Character
    local humanoid = Runtime.Humanoid
    local root = Runtime.Root

    if not Runtime.Running
        or not Runtime.SafeMode
        or Runtime.LocalDead
        or not character
        or character ~= LocalPlayer.Character
        or not character.Parent
        or not humanoid
        or humanoid.Parent ~= character
        or humanoid.Health <= 0 then

        stopSafeModeMovement()
        restoreLocalCollision()
        return false
    end

    if not root
        or not root.Parent
        or not root:IsA("BasePart")
        or not root:IsDescendantOf(character) then

        stopSafeModeMovement()
        restoreLocalCollision()

        local replacementRoot = character:FindFirstChild("HumanoidRootPart")

        if not replacementRoot or not replacementRoot:IsA("BasePart") then
            Runtime.SafeModeAtAltitude = false

            if Runtime.Status ~= "SafeMode: waiting for HumanoidRootPart" then
                setStatus("SafeMode: waiting for HumanoidRootPart")
            end

            return false
        end

        Runtime.Root = replacementRoot
        root = replacementRoot
    end

    if not isFiniteVector3(root.Position) then
        stopSafeModeMovement()
        restoreLocalCollision()
        Runtime.SafeModeAtAltitude = false
        return false
    end

    applyLocalNoClip()

    local safeGoal = getSafeModeMovementGoal(root)

    AutoTween(safeGoal, deltaTime, false)
    Runtime.SafeModeMovement.Tween = Runtime.ActiveTween

    if not Runtime.Running
        or not Runtime.SafeMode
        or Runtime.LocalDead
        or Runtime.Character ~= character
        or Runtime.Humanoid ~= humanoid
        or Runtime.Root ~= root
        or LocalPlayer.Character ~= character
        or not root.Parent
        or not root:IsDescendantOf(character) then

        stopSafeModeMovement()
        restoreLocalCollision()
        return false
    end

    local atAltitude = math.abs(root.Position.Y - SafeModeY) <= 0.5

    if atAltitude ~= Runtime.SafeModeAtAltitude then
        Runtime.SafeModeAtAltitude = atAltitude

        if atAltitude then
            setStatus(string.format(
                SafeModePanicEnabled
                    and "SafeMode: moving around at Y %.1f until MaxHealth"
                    or "SafeMode: holding at Y %.1f until MaxHealth",
                SafeModeY
            ))
        else
            setStatus(string.format(
                SafeModePanicEnabled
                    and "SafeMode: panic movement toward Y %.1f"
                    or "SafeMode: moving to Y %.1f",
                SafeModeY
            ))
        end
    end

    return true
end

local function shouldAdvancePlayerChase(
    now,
    targetEpoch,
    characterEpoch,
    player,
    targetCharacter,
    targetRoot,
    localRoot
)
    local cycle = Runtime.ChaseMoveCycle

    if not cycle
        or cycle.TargetEpoch ~= targetEpoch
        or cycle.CharacterEpoch ~= characterEpoch
        or cycle.Player ~= player
        or cycle.TargetCharacter ~= targetCharacter
        or cycle.TargetRoot ~= targetRoot
        or cycle.LocalRoot ~= localRoot then

        cycle = {
            TargetEpoch = targetEpoch,
            CharacterEpoch = characterEpoch,
            Player = player,
            TargetCharacter = targetCharacter,
            TargetRoot = targetRoot,
            LocalRoot = localRoot,
            MoveUntil = now + INTERNAL.ChaseMoveDuration,
            PauseUntil = nil,
        }
        Runtime.ChaseMoveCycle = cycle
    end

    if cycle.PauseUntil then
        if now < cycle.PauseUntil then
            return false
        end

        cycle.PauseUntil = nil
        cycle.MoveUntil = now + INTERNAL.ChaseMoveDuration
        return true
    end

    if now >= cycle.MoveUntil then
        cycle.PauseUntil = now + INTERNAL.ChasePauseDuration
        return false
    end

    return true
end

local function getPlayerChaseGoal(localRoot, targetRoot)
    if not localRoot
        or not localRoot.Parent
        or not targetRoot
        or not targetRoot.Parent
        or not isFiniteVector3(localRoot.Position)
        or not isFiniteVector3(targetRoot.Position) then

        return nil
    end

    local targetCFrame = targetRoot.CFrame

    if Settings.SeaHeightFirst ~= true then
        stopSeaHeightMovement()
        return targetCFrame, false
    end

    local targetPosition = targetCFrame.Position
    local localCFrame = localRoot.CFrame
    local localPosition = localCFrame.Position
    local seaMovement = Runtime.SeaHeightMove
    local finishingSeaHeight = seaMovement
        and seaMovement.TargetEpoch == Runtime.TargetEpoch
        and seaMovement.CharacterEpoch == Runtime.CharacterEpoch
        and seaMovement.Root == localRoot
        and localPosition.Y > INTERNAL.MinimumTweenY + 0.001
    local horizontalOffset = Vector3.new(
        targetPosition.X - localRoot.Position.X,
        0,
        targetPosition.Z - localRoot.Position.Z
    )

    if not finishingSeaHeight and horizontalOffset.Magnitude <= INTERNAL.VerticalChaseDistance then
        return targetCFrame
    end

    -- Finish an active descent precisely, but do not restart it for tiny physics drift.
    if finishingSeaHeight or localPosition.Y > INTERNAL.MinimumTweenY + 0.5 then
        return CFrame.new(
            localPosition.X,
            INTERNAL.MinimumTweenY,
            localPosition.Z
        ) * localCFrame.Rotation, true
    end

    return CFrame.new(
        targetPosition.X,
        INTERNAL.MinimumTweenY,
        targetPosition.Z
    ) * targetCFrame.Rotation
end

local function getHitboxMovementCFrame(localRoot, targetRoot, requestedPosition)
    local targetCFrame = targetRoot.CFrame
    local hitboxSize = HitboxEnabled and ConfiguredHitboxSize or targetRoot.Size
    -- Leave 10% of each half-extent as a margin against the hitbox boundary.
    local limit = hitboxSize * 0.45
    local requestedOffset = targetCFrame:PointToObjectSpace(requestedPosition)
    local boundedOffset = Vector3.new(
        math.clamp(requestedOffset.X, -limit.X, limit.X),
        math.clamp(requestedOffset.Y, -limit.Y, limit.Y),
        math.clamp(requestedOffset.Z, -limit.Z, limit.Z)
    )
    local position = targetCFrame:PointToWorldSpace(boundedOffset)
    local center = targetCFrame.Position

    if position.Y < INTERNAL.MinimumTweenY and center.Y >= INTERNAL.MinimumTweenY then
        -- Move along a segment inside the box, including for tilted targets.
        local alpha = (center.Y - INTERNAL.MinimumTweenY) / (center.Y - position.Y)
        position = center + (position - center) * math.clamp(alpha, 0, 1)
    end

    local flatTarget = Vector3.new(center.X, position.Y, center.Z)

    if (flatTarget - position).Magnitude > 0.001 then
        return CFrame.lookAt(position, flatTarget)
    end

    -- Directly above/below or at the center: keep the current facing direction.
    return CFrame.new(position) * localRoot.CFrame.Rotation
end

local function enforceLocalYFloor()
    local character = Runtime.Character
    local root = Runtime.Root

    if not character
        or character ~= LocalPlayer.Character
        or not root
        or not root.Parent
        or not root:IsDescendantOf(character)
        or not isFiniteVector3(root.Position) then

        return
    end

    if root.Position.Y <= INTERNAL.MinimumTweenY then
        if root.Position.Y < INTERNAL.MinimumTweenY then
            local safeCFrame = clampCFrameAboveSea(root.CFrame)

            if safeCFrame then
                root.CFrame = safeCFrame
            end
        end

        local velocity = root.AssemblyLinearVelocity

        if isFiniteVector3(velocity) and velocity.Y < 0 then
            pcall(function()
                root.AssemblyLinearVelocity = Vector3.new(velocity.X, 0, velocity.Z)
            end)
        end
    end
end

local function faceRootTowardTarget(localRoot, targetRoot)
    local targetPosition = targetRoot.Position
    local flatTarget = Vector3.new(targetPosition.X, localRoot.Position.Y, targetPosition.Z)

    if (flatTarget - localRoot.Position).Magnitude > 0.001 then
        localRoot.CFrame = CFrame.lookAt(localRoot.Position, flatTarget)
    end
end

local function updateEmptyCombatEntrance()
    local character = Runtime.Character
    local characterEpoch = Runtime.CharacterEpoch
    local root = Runtime.Root
    local humanoid = Runtime.Humanoid
    local inCombat, inCombatKnown = readLocalInCombat()

    if not Runtime.Running
        or not Runtime.HopPending
        or Runtime.SafeMode
        or Runtime.LocalDead
        or not isEmptyListHopReady()
        or not inCombatKnown
        or inCombat ~= true
        or Runtime.CurrentTarget ~= nil
        or not character
        or character ~= LocalPlayer.Character
        or not root
        or not root.Parent
        or not root:IsDescendantOf(character)
        or not isFiniteVector3(root.Position)
        or not humanoid
        or humanoid.Parent ~= character
        or humanoid.Health <= 0 then

        return false
    end

    local previousAttempt = Runtime.EmptyCombatEntranceAttempt

    if previousAttempt
        and previousAttempt.EmptySince == Runtime.EmptySince
        and previousAttempt.CharacterEpoch == characterEpoch then

        return true
    end

    -- Latch before spawning: Heartbeat must not issue duplicate requests.
    local attempt = {
        EmptySince = Runtime.EmptySince,
        CharacterEpoch = characterEpoch,
    }
    Runtime.EmptyCombatEntranceAttempt = attempt
    Runtime.Mode = "HOP_WAIT"

    -- An old chase tween must not pull us back after requestEntrance.
    stopSeaHeightMovement()

    if Runtime.ActiveTween then
        Runtime.ActiveTween:Cancel()
        Runtime.ActiveTween = nil
    end

    restoreLocalCollision()
    local entrance = nearestEntrance(root.Position)

    if not entrance then
        setStatus("No entrance available; waiting for InCombat to turn off before hopping")
        return false
    end

    local function stillValid()
        local currentInCombat, currentInCombatKnown = readLocalInCombat()

        return Runtime.Running
            and Runtime.HopPending
            and not Runtime.SafeMode
            and not Runtime.LocalDead
            and Runtime.EmptyCombatEntranceAttempt == attempt
            and Runtime.EmptySince == attempt.EmptySince
            and Runtime.CharacterEpoch == characterEpoch
            and Runtime.Character == character
            and LocalPlayer.Character == character
            and Runtime.Humanoid == humanoid
            and humanoid.Parent == character
            and humanoid.Health > 0
            and Runtime.Root == root
            and root.Parent ~= nil
            and root:IsDescendantOf(character)
            and isFiniteVector3(root.Position)
            and Runtime.CurrentTarget == nil
            and isEmptyListHopReady()
            and currentInCombatKnown
            and currentInCombat == true
    end

    setStatus("InCombat with no eligible targets; requesting nearest entrance")

    task.spawn(function()
        local success = invokeEntrance(entrance, "EmptyCombat", nil, stillValid)

        if not stillValid() then
            return
        end

        setStatus(success
            and "Entrance requested; waiting for InCombat to turn off before hopping"
            or "Entrance request failed; waiting for InCombat to turn off before hopping")
    end)

    return true
end

local function faceCameraTowardTarget()
    if not Runtime.Running
        or Runtime.LocalDead
        or Runtime.SafeMode
        or Runtime.HopPending then

        return
    end

    local aimingGun = Runtime.IsGunAimAllowed()

    if not aimingGun and (not Runtime.InsideHitbox or Runtime.Mode ~= "ENGAGE") then

        return
    end

    local targetPlayer = Runtime.CurrentTarget
    local targetInfo = Runtime.CurrentTargetInfo
    local targetCharacter = targetInfo and targetInfo.Character
    local targetHumanoid = targetInfo and targetInfo.Humanoid
    local targetRoot = targetInfo and targetInfo.Root
    local camera = Workspace.CurrentCamera

    if not targetPlayer
        or targetPlayer.Parent ~= Players
        or not targetInfo
        or targetInfo.Player ~= targetPlayer
        or targetPlayer.Character ~= targetCharacter
        or not targetCharacter
        or not targetCharacter.Parent
        or not targetHumanoid
        or targetHumanoid.Parent ~= targetCharacter
        or targetHumanoid.Health <= 0
        or not targetRoot
        or not targetRoot:IsA("BasePart")
        or not targetRoot:IsDescendantOf(targetCharacter)
        or targetRoot.Position.Y < INTERNAL.MinimumTweenY
        or not camera then

        return
    end

    local cameraPosition = camera.CFrame.Position

    if (targetRoot.Position - cameraPosition).Magnitude > 0.001 then
        camera.CFrame = CFrame.lookAt(cameraPosition, targetRoot.Position)
    end
end

local function installAimHook()
    if Environment.__AutoBountyAimHookInstalled
        and (tonumber(Environment.__AutoBountyAimHookVersion) or 0) >= 2 then

        return
    end

    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
        warnOnce("aimbot:unsupported", "Aimbot hook APIs are unavailable; skills will still cast without aim redirection.")
        return
    end

    local oldNamecall
    -- A pre-v2 hook can still handle inside-hitbox calls; this wrapper adds gun approach aim.
    local hasLegacyHook = Environment.__AutoBountyAimHookInstalled == true
    local unpackArguments = table.unpack or unpack
    local function handler(remote, ...)
        local runtime = Environment.__AutoBountyRuntime
        local method = getnamecallmethod()

        if runtime
            and runtime.Running
            and runtime.AttackEnabled
            and runtime.AimActive
            and not runtime.SafeMode
            and not runtime.LocalDead
            and not runtime.HopPending
            and runtime.AimPosition
            and runtime.CurrentTool
            and (method == "FireServer" or method == "InvokeServer")
            and typeof(remote) == "Instance" then

            local mayRedirect = runtime.InsideHitbox and not hasLegacyHook

            if not runtime.InsideHitbox
                and type(runtime.IsGunAimAllowed) == "function" then

                -- The validator uses direct method calls so namecall forwarding stays intact.
                local validCheck, allowed = pcall(runtime.IsGunAimAllowed)
                mayRedirect = validCheck and allowed == true
            end

            if not mayRedirect then
                return oldNamecall(remote, ...)
            end

            local arguments = table.pack(...)
            local aimArgumentIndex = nil
            local replacement = nil

            for index = 1, arguments.n do
                local argumentType = typeof(arguments[index])

                if argumentType == "Vector3" then
                    aimArgumentIndex = index
                    replacement = runtime.AimPosition
                    break
                elseif argumentType == "CFrame" then
                    aimArgumentIndex = index
                    replacement = CFrame.new(runtime.AimPosition) * arguments[index].Rotation
                    break
                end
            end

            -- Boolean-only activation/deactivation calls must pass through untouched.
            -- Use direct method invocation here so this check does not overwrite the
            -- FireServer/InvokeServer namecall that oldNamecall must forward.
            if aimArgumentIndex and typeof(runtime.CurrentTool) == "Instance" then
                local checkSucceeded, belongsToTool = pcall(
                    remote.IsDescendantOf,
                    remote,
                    runtime.CurrentTool
                )

                if checkSucceeded and belongsToTool == true then
                    arguments[aimArgumentIndex] = replacement
                    return oldNamecall(remote, unpackArguments(arguments, 1, arguments.n))
                end
            end
        end

        return oldNamecall(remote, ...)
    end

    local wrappedHandler = type(newcclosure) == "function" and newcclosure(handler) or handler
    local success, result = pcall(function()
        oldNamecall = hookmetamethod(game, "__namecall", wrappedHandler)
    end)

    if success and type(oldNamecall) == "function" then
        Environment.__AutoBountyAimHookInstalled = true
        Environment.__AutoBountyAimHookVersion = 2
    else
        warnOnce("aimbot:install", "Aimbot hook installation failed: " .. tostring(result))
    end
end

local DEFAULT_WEAPON_ORDER = {"Melee", "Blox Fruit", "Sword", "Gun"}
local SKILL_ORDER = {"Z", "X", "C", "V", "F"}
local VALID_WEAPON_CATEGORY = {
    Melee = true,
    ["Blox Fruit"] = true,
    Sword = true,
    Gun = true,
}

local function getWeaponOrder()
    local configuredOrder = WeaponConfig.Order
    local result = {}
    local included = {}

    if type(configuredOrder) == "table" then
        for _, category in ipairs(configuredOrder) do
            if VALID_WEAPON_CATEGORY[category] and not included[category] then
                included[category] = true
                table.insert(result, category)
            end
        end
    end

    if #result == 0 then
        for _, category in ipairs(DEFAULT_WEAPON_ORDER) do
            table.insert(result, category)
        end
    end

    return result
end

local function getSkillOrder(categoryConfig)
    local result = {}
    local included = {}
    local allowed = {}

    for _, keyName in ipairs(SKILL_ORDER) do
        allowed[keyName] = true
    end

    if type(categoryConfig.SkillOrder) == "table" then
        for _, keyName in ipairs(categoryConfig.SkillOrder) do
            if allowed[keyName] and not included[keyName] then
                included[keyName] = true
                table.insert(result, keyName)
            end
        end
    end

    -- An order override reorders keys; Enabled remains the switch for each skill.
    for _, keyName in ipairs(SKILL_ORDER) do
        if not included[keyName] then
            table.insert(result, keyName)
        end
    end

    return result
end

local function getComboNumberSetting(name, fallback)
    local value = tonumber(Settings[name])

    if isFiniteNumber(value) and value >= 0 then
        return value
    end

    return fallback
end

local function collectTools()
    local tools = {}
    local character = Runtime.Character
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack") or LocalPlayer:FindFirstChild("Backpack")

    local function addFrom(container)
        if not container then
            return
        end

        for _, child in ipairs(container:GetChildren()) do
            if child:IsA("Tool") then
                table.insert(tools, child)
            end
        end
    end

    addFrom(character)
    addFrom(backpack)

    table.sort(tools, function(left, right)
        return left.Name < right.Name
    end)

    return tools
end

local function resolveTool(category, categoryConfig)
    local tools = collectTools()
    local requestedName = tostring(categoryConfig.Name or "Auto")

    if requestedName ~= "" and string.lower(requestedName) ~= "auto" then
        for _, tool in ipairs(tools) do
            if tool.Name == requestedName then
                return tool
            end
        end

        warnOnce(
            "weapon:missing-exact:" .. tostring(Runtime.CharacterEpoch) .. ":" .. category .. ":" .. requestedName,
            "Configured " .. category .. " tool " .. requestedName .. " was not found; that category is skipped."
        )
        return nil
    end

    for _, tool in ipairs(tools) do
        if tool.ToolTip == category then
            return tool
        end
    end

    warnOnce(
        "weapon:missing:" .. tostring(Runtime.CharacterEpoch) .. ":" .. category,
        "No " .. category .. " tool matched weapon config Name=" .. requestedName .. "."
    )
    return nil
end

local function waitWhileAttackable(duration, targetEpoch, attackMode)
    local deadline = os.clock() + math.max(tonumber(duration) or 0, 0)
    local yielded = false

    repeat
        task.wait()
        yielded = true

        if not canAttack(targetEpoch, attackMode) then
            return false
        end
    until os.clock() >= deadline and yielded

    return true
end

local function equipTool(tool, targetEpoch, attackMode)
    if not tool or not tool.Parent or not canAttack(targetEpoch, attackMode) then
        return false
    end

    local character = Runtime.Character
    local humanoid = Runtime.Humanoid

    if not character or not humanoid or not humanoid.Parent then
        return false
    end

    if tool.Parent == character then
        Runtime.CurrentTool = tool
        return true
    end

    local success, result = pcall(function()
        humanoid:UnequipTools()
        RunService.Heartbeat:Wait()

        if canAttack(targetEpoch, attackMode) and tool.Parent then
            humanoid:EquipTool(tool)
        end
    end)

    if not success then
        warnOnce("weapon:equip:" .. tool.Name, "Could not equip " .. tool.Name .. ": " .. tostring(result))
        return false
    end

    local deadline = os.clock() + 1

    while Runtime.Running and canAttack(targetEpoch, attackMode) and os.clock() < deadline do
        if tool.Parent == character then
            Runtime.CurrentTool = tool
            return true
        end

        task.wait(0.03)
    end

    return false
end

local function castSkill(keyName, skillConfig, targetEpoch, attackMode)
    if not canAttack(targetEpoch, attackMode) then
        Runtime.AimActive = false
        Runtime.GunAimActive = false
        return false
    end

    local holdTime = getComboNumberSetting("ComboHold", nil)

    if holdTime == nil then
        local configuredHold = tonumber(skillConfig.Hold)
        holdTime = isFiniteNumber(configuredHold) and math.max(configuredHold, 0) or 0
    end
    Runtime.AimActive = true
    Runtime.GunAimActive = attackMode == "GunApproach"

    if Runtime.GunAimActive then
        -- An approach cast can begin between Heartbeats; aim its first input at
        -- the live target instead of waiting for the movement camera update.
        Runtime.AimPosition = Runtime.CurrentTargetInfo.Root.Position
        faceCameraTowardTarget()
    end

    if not pressKeyDown(keyName) then
        Runtime.AimActive = false
        Runtime.GunAimActive = false
        return false
    end

    local waitOk, completed = pcall(waitWhileAttackable, holdTime, targetEpoch, attackMode)
    releaseKey(keyName)
    Runtime.AimActive = false
    Runtime.GunAimActive = false

    if not waitOk then
        warnOnce("skill:hold:" .. keyName, "Skill hold for " .. keyName .. " failed: " .. tostring(completed))
        return false
    end

    return completed
end

-- Optional Settings.ReadSkillCooldown(tool, keyName) must return:
-- true = cooling down, false = ready, nil = unknown; it must not yield.
-- Default GUI adapter expects Main.Skills[tool.Name][keyName].Cooldown,
-- with a horizontal cooldown bar that shrinks to zero when ready.
-- This UI convention must match the live game; unknown data never enables M1.
local CombatActions = {
    NextNormalAttackAt = 0,
    NextRemoteLookupAt = 0,
    SkillAttempts = setmetatable({}, {__mode = "k"}),
}

function CombatActions.ReadCooldown(tool, keyName)
    if not tool or not tool.Parent then
        return nil
    end

    if type(Settings.ReadSkillCooldown) == "function" then
        local success, result = pcall(Settings.ReadSkillCooldown, tool, keyName)

        if success and type(result) == "boolean" then
            return result
        end

        if not success then
            warnOnce("skill:cooldown-reader", "ReadSkillCooldown failed: " .. tostring(result))
        end

        return nil
    end

    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local main = playerGui and playerGui:FindFirstChild("Main")
    local skills = main and main:FindFirstChild("Skills")
    local panel = skills and skills:FindFirstChild(tool.Name)
    local skill = panel and panel:FindFirstChild(keyName)
    local cooldown = skill and skill:FindFirstChild("Cooldown")

    if not skill
        or not skill:IsA("GuiObject")
        or skill.AbsoluteSize.X <= 0
        or not cooldown
        or not cooldown:IsA("GuiObject") then

        return nil
    end

    return cooldown.AbsoluteSize.X > 0
end

function CombatActions.ObserveCooldown(tool, keyName, cooling)
    local skills = CombatActions.SkillAttempts[tool]

    if not skills then
        skills = {}
        CombatActions.SkillAttempts[tool] = skills
    end

    local attempt = skills[keyName]

    if not attempt then
        attempt = {NextAttemptAt = 0}
        skills[keyName] = attempt
    end

    -- A confirmed cooldown finishing can resume immediately. Repeated false/nil
    -- readings still honor the retry interval when an activation was not observed.
    if attempt.LastKnownCooling == true and cooling == false then
        attempt.NextAttemptAt = 0
    end

    if cooling ~= nil then
        attempt.LastKnownCooling = cooling
    end

    return attempt
end

function CombatActions.CanAttempt(entry)
    local cooling = CombatActions.ReadCooldown(entry.Tool, entry.Key)
    local attempt = CombatActions.ObserveCooldown(entry.Tool, entry.Key, cooling)
    entry.Cooling = cooling

    return cooling ~= true and os.clock() >= attempt.NextAttemptAt
end

function CombatActions.MarkAttempt(entry)
    local attempt = CombatActions.ObserveCooldown(entry.Tool, entry.Key, entry.Cooling)
    attempt.NextAttemptAt = os.clock() + getComboNumberSetting("ComboRetryDelay", 1)
end

function CombatActions.GetSkills(weaponOrder)
    local entries = {}

    for _, category in ipairs(weaponOrder) do
        local categoryConfig = WeaponConfig[category]

        if type(categoryConfig) == "table" and categoryConfig.Enabled == true then
            local tool = resolveTool(category, categoryConfig)
            local skills = type(categoryConfig.Skills) == "table" and categoryConfig.Skills or {}

            if tool then
                for _, keyName in ipairs(getSkillOrder(categoryConfig)) do
                    local skillConfig = skills[keyName]

                    if type(skillConfig) == "table" and skillConfig.Enabled == true then
                        local cooling = CombatActions.ReadCooldown(tool, keyName)
                        CombatActions.ObserveCooldown(tool, keyName, cooling)
                        table.insert(entries, {
                            Tool = tool,
                            Category = category,
                            CategoryConfig = categoryConfig,
                            Key = keyName,
                            Config = skillConfig,
                            Cooling = cooling,
                        })
                    end
                end
            end
        end
    end

    return entries
end

function CombatActions.AllCooling(entries)
    if #entries == 0 then
        return false
    end

    for _, entry in ipairs(entries) do
        if entry.Cooling ~= true then
            return false
        end
    end

    return true
end

function CombatActions.SelectSkill(entries, cursor)
    -- A pass advances only forward. Ready and unknown skills share the same
    -- order, so one ready skill cannot repeatedly jump ahead of later skills.
    for index = cursor, #entries do
        local entry = entries[index]

        if entry.CategoryConfig.Enabled == true
            and entry.Config.Enabled == true
            and entry.Tool.Parent
            and CombatActions.CanAttempt(entry) then

            return entry, index
        end
    end

    return nil, #entries
end

function CombatActions.GetNormalTool(weaponOrder)
    local firstTool

    for _, category in ipairs(weaponOrder) do
        local categoryConfig = WeaponConfig[category]

        if (category == "Melee" or category == "Sword")
            and type(categoryConfig) == "table"
            and categoryConfig.Enabled == true then

            local tool = resolveTool(category, categoryConfig)

            if tool then
                if tool == Runtime.CurrentTool then
                    return tool
                end

                firstTool = firstTool or tool
            end
        end
    end

    return firstTool
end

function CombatActions.GetAttackRemotes()
    local attack = CombatActions.RegisterAttack
    local hit = CombatActions.RegisterHit

    if attack and hit
        and attack.Parent
        and attack.Parent == hit.Parent
        and attack:IsDescendantOf(ReplicatedStorage) then

        return attack, hit
    end

    if os.clock() < CombatActions.NextRemoteLookupAt then
        return nil
    end

    CombatActions.NextRemoteLookupAt = os.clock() + 1
    attack = ReplicatedStorage:FindFirstChild("RE/RegisterAttack", true)
    hit = attack and attack.Parent and attack.Parent:FindFirstChild("RE/RegisterHit")

    if not attack or not attack:IsA("RemoteEvent")
        or not hit or not hit:IsA("RemoteEvent") then

        warnOnce("normal-attack:remotes", "NormalAttack is waiting for RE/RegisterAttack and RE/RegisterHit under the same parent.")
        return nil
    end

    CombatActions.RegisterAttack = attack
    CombatActions.RegisterHit = hit
    return attack, hit
end

function CombatActions.NormalAttack(targetEpoch)
    if not ClickAttackEnabled or not canAttack(targetEpoch) or Runtime.AimActive then
        return false
    end

    local humanoid = Runtime.Humanoid

    if not humanoid or humanoid.MaxHealth <= 0
        or humanoid.Health < humanoid.MaxHealth * 0.20 then

        return false
    end

    local now = os.clock()

    if now < CombatActions.NextNormalAttackAt then
        return false
    end

    local info = Runtime.CurrentTargetInfo
    local targetRoot = info and info.Root
    local localRoot = Runtime.Root
    local tool = Runtime.CurrentTool

    if not info or info.Player ~= Runtime.CurrentTarget
        or not targetRoot or not targetRoot.Parent
        or not localRoot or not localRoot.Parent
        or not tool or tool.Parent ~= Runtime.Character
        or not isFiniteVector3(targetRoot.Position)
        or not isFiniteVector3(localRoot.Position)
        or (localRoot.Position - targetRoot.Position).Magnitude >= 60 then

        return false
    end

    local attack, hit = CombatActions.GetAttackRemotes()

    if not attack or not hit then
        return false
    end

    CombatActions.NextNormalAttackAt = now + 0.25

    local success, result = pcall(function()
        attack:FireServer(0)
        attack:FireServer(1)
        attack:FireServer(2)
        attack:FireServer(3)
        hit:FireServer(targetRoot, {})
    end)

    if not success then
        warnOnce("normal-attack:fire", "NormalAttack failed: " .. tostring(result))
    end

    return success
end

function CombatActions.GunOpener(tool, targetEpoch, characterEpoch)
    if Runtime.GunShotRequest
        or Runtime.CharacterEpoch ~= characterEpoch
        or not canAttack(targetEpoch, "GunApproach")
        or not tool or tool.Parent ~= Runtime.Character
        or Runtime.CurrentTool ~= tool then

        return false
    end

    local remote = tool:FindFirstChild("RemoteFunctionShoot")

    if not remote or not remote:IsA("RemoteFunction") then
        warnOnce("gun:remote:" .. tool.Name, "Gun " .. tool.Name .. " has no RemoteFunctionShoot; skipping its opener.")
        return false
    end

    local targetInfo = Runtime.CurrentTargetInfo
    local targetRoot = targetInfo.Root
    local request = {Finished = false, Success = false, Expired = false}
    local deadline = os.clock() + 1

    Runtime.GunShotRequest = request
    Runtime.GunShotOwner = request
    Runtime.AimActive = true
    Runtime.GunAimActive = true
    Runtime.AimPosition = targetRoot.Position
    faceCameraTowardTarget()

    local function stillValid()
        local currentInfo = Runtime.CurrentTargetInfo

        return not request.Expired
            and Runtime.GunShotOwner == request
            and Runtime.TargetEpoch == targetEpoch
            and Runtime.CharacterEpoch == characterEpoch
            and currentInfo ~= nil
            and currentInfo.Player == targetInfo.Player
            and currentInfo.Character == targetInfo.Character
            and currentInfo.Humanoid == targetInfo.Humanoid
            and currentInfo.Root == targetRoot
            and Runtime.CurrentTool == tool
            and tool.Parent == Runtime.Character
            and remote.Parent == tool
            and Runtime.IsGunAimAllowed()
    end

    -- Keep the weapon worker free to enter the combat combo even if this
    -- game-specific remote yields indefinitely. Only one request may be pending.
    task.spawn(function()
        local success, result = pcall(function()
            if not stillValid() or os.clock() >= deadline then
                return false
            end

            local args = {
                [1] = targetRoot.Position,
                [2] = targetRoot,
            }
            Runtime.AimPosition = args[1]
            remote:InvokeServer(table.unpack(args))
            return true
        end)

        request.Success = success and result == true
        request.Error = not success and tostring(result) or nil
        request.Finished = true

        if Runtime.GunShotRequest == request then
            Runtime.GunShotRequest = nil
        end
    end)

    local waitSucceeded, clicked = pcall(function()
        while not request.Finished and os.clock() < deadline and stillValid() do
            task.wait()
        end

        if not request.Finished or not request.Success
            or os.clock() >= deadline or not stillValid() then

            return false
        end

        Runtime.AimPosition = targetRoot.Position
        faceCameraTowardTarget()
        VirtualUser:CaptureController()

        if not stillValid() then
            return false
        end

        Runtime.GunMouseHeld = request
        VirtualUser:Button1Down(Vector2.new(1280, 672))
        waitWhileAttackable(0.05, targetEpoch, "GunApproach")
        return true
    end)

    request.Expired = true
    Runtime.ReleaseGunClick(request)

    if Runtime.GunShotOwner == request then
        Runtime.GunShotOwner = nil
        Runtime.AimActive = false
        Runtime.GunAimActive = false
    end

    if request.Error then
        warnOnce("gun:shoot:" .. tool.Name, "Gun opener failed: " .. request.Error)
    elseif not waitSucceeded then
        warnOnce("gun:click:" .. tool.Name, "Gun opener input failed: " .. tostring(clicked))
    elseif not request.Finished and os.clock() >= deadline then
        warnOnce("gun:timeout:" .. tool.Name, "Gun opener response timed out; continuing the combat combo when in range.")
    end

    return waitSucceeded and clicked == true
end

local function startWeaponWorker()
    task.spawn(function()
        local weaponOrder = getWeaponOrder()
        local combatWeaponOrder = {}

        for _, category in ipairs(weaponOrder) do
            if not GunOpenerEnabled or category ~= "Gun" then
                table.insert(combatWeaponOrder, category)
            end
        end

        local comboEntries = nil
        local skillCursor = 1
        local comboTargetEpoch = nil
        local comboCharacterEpoch = nil
        local gunPassFinished = false

        while Runtime.Running do
            local targetEpoch = Runtime.TargetEpoch

            if comboTargetEpoch ~= targetEpoch
                or comboCharacterEpoch ~= Runtime.CharacterEpoch then

                comboEntries = nil
                skillCursor = 1
                gunPassFinished = false
                comboTargetEpoch = targetEpoch
                comboCharacterEpoch = Runtime.CharacterEpoch
            end

            local attackMode = nil
            local attackable = canAttack(targetEpoch)

            if attackable and GunOpenerEnabled then
                -- Reaching the combat hitbox ends the opener for this acquisition.
                -- Leaving it again must not fire another opener.
                gunPassFinished = true
            elseif GunOpenerEnabled and not gunPassFinished
                and canAttack(targetEpoch, "GunApproach") then

                attackMode = "GunApproach"
                attackable = true
            end

            if not attackable then
                -- Keep the next step across a brief hitbox/safe-mode interruption.
                -- Target/character epoch changes reset the pass when attacks resume.
                Runtime.AimActive = false
                Runtime.GunAimActive = false
                Runtime.CurrentTool = nil
                releaseAllKeys()
                task.wait(0.05)
            elseif attackMode == "GunApproach" then
                -- One basic gun shot per acquisition, independent of Gun.Skills.
                -- Latch before equipping/invoking because both may yield.
                gunPassFinished = true
                local gunConfig = WeaponConfig.Gun
                local tool = resolveTool("Gun", gunConfig)

                if tool and equipTool(tool, targetEpoch, "GunApproach")
                    and Runtime.CharacterEpoch == comboCharacterEpoch then

                    CombatActions.GunOpener(tool, targetEpoch, comboCharacterEpoch)
                end

                Runtime.ReleaseGunClick()
                Runtime.AimActive = false
                Runtime.GunAimActive = false
                task.wait(0.01)
            else
                if not comboEntries then
                    comboEntries = CombatActions.GetSkills(combatWeaponOrder)
                    skillCursor = 1
                end

                local entry, entryIndex = CombatActions.SelectSkill(comboEntries, skillCursor)
                local castCompleted = false

                skillCursor = entryIndex + 1

                if entry then
                    if equipTool(entry.Tool, targetEpoch, attackMode)
                        and canAttack(targetEpoch, attackMode)
                        and Runtime.CharacterEpoch == comboCharacterEpoch
                        and entry.Tool.Parent == Runtime.Character
                        and entry.CategoryConfig.Enabled == true
                        and entry.Config.Enabled == true then

                        -- Equipping yields; recheck this exact combo step before
                        -- key-down, without restarting the order at the first skill.
                        if CombatActions.CanAttempt(entry) then
                            if entry.Cooling == nil then
                                warnOnce(
                                    "skill:cooldown-unknown:" .. entry.Tool.Name .. ":" .. entry.Key,
                                    "Cooldown unavailable for " .. entry.Tool.Name .. " " .. entry.Key
                                        .. "; using ordered, retry-limited attempts. NormalAttack requires known cooldowns for every enabled skill."
                                )
                            end

                            CombatActions.MarkAttempt(entry)
                            castCompleted = castSkill(entry.Key, entry.Config, targetEpoch, attackMode)

                            if castCompleted then
                                local delay = getComboNumberSetting("ComboDelay", 0.03)

                                if delay > 0 then
                                    waitWhileAttackable(delay, targetEpoch, attackMode)
                                end
                            end
                        end
                    end
                else
                    -- Rebuild only after the entire pass. Retry gates alone never
                    -- qualify as cooldowns for the normal-attack fallback.
                    comboEntries = nil
                    local latestEntries = CombatActions.GetSkills(combatWeaponOrder)

                    if ClickAttackEnabled and CombatActions.AllCooling(latestEntries)
                        and os.clock() >= CombatActions.NextNormalAttackAt then

                        local tool = CombatActions.GetNormalTool(combatWeaponOrder)

                        if not tool then
                            warnOnce("normal-attack:tool", "NormalAttack needs an available enabled Melee or Sword tool.")
                        elseif equipTool(tool, targetEpoch)
                            and canAttack(targetEpoch)
                            and Runtime.CharacterEpoch == comboCharacterEpoch
                            and tool.Parent == Runtime.Character then

                            -- Equipping may yield: check every skill again before firing.
                            latestEntries = CombatActions.GetSkills(combatWeaponOrder)

                            if CombatActions.AllCooling(latestEntries) then
                                CombatActions.NormalAttack(targetEpoch)
                            end
                        end
                    end
                end

                Runtime.AimActive = false
                Runtime.GunAimActive = false

                -- Successful casts already yield during Hold/ComboDelay. Cooling
                -- skills are skipped together without sleeping for each key.
                if not castCompleted then
                    task.wait(0.01)
                end
            end
        end

        Runtime.AimActive = false
        Runtime.GunAimActive = false
        releaseAllKeys()
    end)
end


local function startRaceWorker()
    local nextCheckAt = 0
    local heldRaceKey = nil

    -- Race transformation owns Y separately from the weapon skill keys.
    -- Runtime:Stop() must call this before disconnecting Runtime.Connections.
    local function releaseRaceKey()
        if not heldRaceKey then
            return
        end

        local success, result = pcall(function()
            VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Y, false, game)
        end)

        if success then
            heldRaceKey = nil
        else
            warnOnce("race:v4:key-up", "Could not release race transformation key: " .. tostring(result))
        end
    end

    Runtime.ReleaseRaceKey = releaseRaceKey

    local function getCombatCharacter()
        local character = Runtime.Character
        local humanoid = Runtime.Humanoid

        if not Runtime.Running
            or Environment.__AutoBountyRuntime ~= Runtime
            or Runtime.SafeMode
            or Runtime.LocalDead
            or Runtime.HopPending
            or Runtime.Teleporting
            or not character
            or character ~= LocalPlayer.Character
            or not character.Parent
            or not humanoid
            or humanoid.Parent ~= character
            or humanoid.Health <= 0 then

            return nil
        end

        local inCombat, inCombatKnown = readLocalInCombat()

        if not inCombatKnown or inCombat ~= true then
            return nil
        end

        return character
    end

    connect(RunService.Heartbeat, function()
        local now = os.clock()

        -- Key-up has its own deadline; no sleeping or blocking of V3 checks.
        if heldRaceKey then
            local character = getCombatCharacter()

            if now >= heldRaceKey.ReleaseAt
                or Settings.RaceV4 ~= true
                or character ~= heldRaceKey.Character
                or Runtime.CharacterEpoch ~= heldRaceKey.CharacterEpoch then

                releaseRaceKey()
            end
        end

        if not Runtime.Running or now < nextCheckAt then
            return
        end

        nextCheckAt = now + 0.2

        if Settings.RaceV3 ~= true and Settings.RaceV4 ~= true then
            return
        end

        local character = getCombatCharacter()

        if not character then
            return
        end

        if Settings.RaceV3 == true then
            local commE = Remotes:FindFirstChild("CommE")

            if commE and commE:IsA("RemoteEvent") then
                local success, result = pcall(function()
                    commE:FireServer("ActivateAbility")
                end)

                if not success then
                    warnOnce("race:v3:activate", "Could not activate Race V3: " .. tostring(result))
                end
            end
        end

        if Settings.RaceV4 == true and not heldRaceKey then
            local raceEnergy = character:FindFirstChild("RaceEnergy")
            local raceTransformed = character:FindFirstChild("RaceTransformed")

            if raceEnergy
                and (raceEnergy:IsA("NumberValue")
                    or raceEnergy:IsA("IntValue")
                    or raceEnergy:IsA("StringValue"))
                and tonumber(raceEnergy.Value) == 1
                and raceTransformed
                and raceTransformed:IsA("BoolValue")
                and raceTransformed.Value == false then

                local success, result = pcall(function()
                    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Y, false, game)
                end)

                if success then
                    heldRaceKey = {
                        Character = character,
                        CharacterEpoch = Runtime.CharacterEpoch,
                        ReleaseAt = os.clock() + 0.1,
                    }
                else
                    warnOnce("race:v4:key-down", "Could not activate Race V4: " .. tostring(result))
                end
            end
        end
    end)
end


enterSafeMode = function()
    local humanoid = Runtime.Humanoid

    if Runtime.SafeMode
        or Runtime.LocalDead
        or not humanoid
        or not humanoid.Parent
        or humanoid.Health <= 0 then

        return
    end

    Runtime.SafeMode = true
    Runtime.SafeEpoch = Runtime.SafeEpoch + 1
    Runtime.SafeModeAtAltitude = false

    if cancelFollowTimeoutHop then
        cancelFollowTimeoutHop("SafeMode reset PlayerFollowTime")
    end

    clearTarget()
    applyLocalNoClip()
    Runtime.Mode = "SAFE_MODE"
    setStatus(string.format(
        SafeModePanicEnabled
            and "SafeMode: panic movement toward Y %.1f"
            or "SafeMode: moving to Y %.1f",
        SafeModeY
    ))
end

exitSafeMode = function()
    if not Runtime.SafeMode or Runtime.LocalDead then
        return
    end

    Runtime.SafeMode = false
    Runtime.SafeEpoch = Runtime.SafeEpoch + 1
    Runtime.SafeModeAtAltitude = false
    stopSafeModeMovement()
    restoreLocalCollision()
    Runtime.Mode = Runtime.HopPending and "HOP_WAIT" or "SCAN"

    if not Runtime.HopPending then
        Runtime.EmptySince = nil
    end

    setStatus(Runtime.HopPending and "Recovered; resuming server hop" or "Recovered; returning to combat")
    ensureCombatAttributes()
    startPvPEnable()
end

local function handleHealthChanged(health, characterEpoch)
    if Runtime.CharacterEpoch ~= characterEpoch or Runtime.LocalDead then
        return
    end

    local humanoid = Runtime.Humanoid

    if not humanoid or not humanoid.Parent or health <= 0 then
        return
    end

    local effectiveLow = Runtime.EffectiveLowHealth or LowHealth
    local effectiveRecovery = Runtime.EffectiveRecoveryHealth or math.min(RecoveryHealth, humanoid.MaxHealth)

    if not Runtime.SafeMode and health <= effectiveLow then
        enterSafeMode()
        return
    end

    if Runtime.SafeMode then
        if health > effectiveLow and health >= effectiveRecovery then
            exitSafeMode()
        end
    end
end

local function updateEffectiveHealthThresholds(humanoid, characterEpoch)
    if Runtime.CharacterEpoch ~= characterEpoch or Runtime.Humanoid ~= humanoid then
        return
    end

    local maximum = math.max(tonumber(humanoid.MaxHealth) or 1, 1)
    local effectiveLow = math.min(LowHealth, math.max(maximum - 1, 0))
    local effectiveRecovery = math.min(RecoveryHealth, maximum)

    if effectiveRecovery <= effectiveLow then
        effectiveRecovery = maximum
    end

    Runtime.EffectiveLowHealth = effectiveLow
    Runtime.EffectiveRecoveryHealth = effectiveRecovery

    if effectiveLow ~= LowHealth or effectiveRecovery ~= RecoveryHealth then
        warnOnce(
            "health:threshold:" .. tostring(characterEpoch),
            string.format(
                "Health thresholds were clamped for MaxHealth %.0f (effective LowHealth %.0f, MaxHealth %.0f).",
                maximum,
                effectiveLow,
                effectiveRecovery
            )
        )
    end
end

local function handleLocalDeath(characterEpoch)
    if Runtime.CharacterEpoch ~= characterEpoch or Runtime.LocalDead then
        return
    end

    Runtime.LocalDead = true
    Runtime.SafeMode = false
    Runtime.SafeEpoch = Runtime.SafeEpoch + 1
    Runtime.SafeModeAtAltitude = false

    if cancelFollowTimeoutHop then
        cancelFollowTimeoutHop("Local death reset PlayerFollowTime")
    end

    clearTarget()
    Runtime.Mode = "RESPAWN"
    setStatus("Local player died; waiting for respawn")
    Runtime.Character = nil
    Runtime.Humanoid = nil
    Runtime.Root = nil
    Runtime.EffectiveLowHealth = nil
    Runtime.EffectiveRecoveryHealth = nil
end

local function bindCharacter(character)
    Runtime.CharacterEpoch = Runtime.CharacterEpoch + 1
    Runtime.SafeEpoch = Runtime.SafeEpoch + 1
    local characterEpoch = Runtime.CharacterEpoch
    disconnectConnections(Runtime.CharacterConnections)
    Runtime.LocalDead = true
    Runtime.SafeMode = false
    Runtime.SafeModeAtAltitude = false
    clearTarget()
    Runtime.Mode = "RESPAWN"
    setStatus("Binding character")

    task.spawn(function()
        local humanoid = character:WaitForChild("Humanoid", 10)
        local root = character:WaitForChild("HumanoidRootPart", 10)

        if not Runtime.Running
            or Runtime.CharacterEpoch ~= characterEpoch
            or LocalPlayer.Character ~= character then

            return
        end

        if not humanoid or not humanoid:IsA("Humanoid") or not root or not root:IsA("BasePart") then
            warnOnce("character:parts:" .. tostring(characterEpoch), "The respawned character did not provide Humanoid and HumanoidRootPart in time.")
            setStatus("Character parts missing")
            return
        end

        if humanoid.Health <= 0 then
            setStatus("Character was already dead; waiting for respawn")
            return
        end

        Runtime.Character = character
        Runtime.Humanoid = humanoid
        Runtime.Root = root
        updateEffectiveHealthThresholds(humanoid, characterEpoch)

        connect(humanoid.HealthChanged, function(health)
            handleHealthChanged(health, characterEpoch)
        end, true)

        connect(humanoid:GetPropertyChangedSignal("MaxHealth"), function()
            updateEffectiveHealthThresholds(humanoid, characterEpoch)
            handleHealthChanged(humanoid.Health, characterEpoch)
        end, true)

        connect(humanoid.Died, function()
            handleLocalDeath(characterEpoch)
        end, true)

        ensureCombatAttributes()

        local characterStillCurrent = Runtime.Running
            and Runtime.CharacterEpoch == characterEpoch
            and LocalPlayer.Character == character
            and character.Parent ~= nil
            and Runtime.Character == character
            and Runtime.Humanoid == humanoid
            and Runtime.Root == root
            and humanoid.Parent ~= nil
            and humanoid.Health > 0

        if not characterStillCurrent then
            if Runtime.CharacterEpoch == characterEpoch and Runtime.Character == character then
                Runtime.Character = nil
                Runtime.Humanoid = nil
                Runtime.Root = nil
                Runtime.EffectiveLowHealth = nil
                Runtime.EffectiveRecoveryHealth = nil
                setStatus("Character changed during setup; waiting for respawn")
            end

            return
        end

        Runtime.LocalDead = false
        readLocalInCombat()
        startPvPEnable()
        handleHealthChanged(humanoid.Health, characterEpoch)

        if not Runtime.SafeMode then
            Runtime.Mode = Runtime.HopPending and "HOP_WAIT" or "SCAN"
            setStatus(Runtime.HopPending and "Character ready; resuming server hop" or "Character ready; scanning")
        end
    end)
end

local function startMovementWorker()
    pcall(function()
        RunService:UnbindFromRenderStep(Runtime.CameraBindName)
    end)

    local cameraBindOk, cameraBindError = pcall(function()
        RunService:BindToRenderStep(
            Runtime.CameraBindName,
            Enum.RenderPriority.Camera.Value + 1,
            faceCameraTowardTarget
        )
    end)

    if cameraBindOk then
        Runtime.CameraBound = true
    else
        warnOnce(
            "camera:bind",
            "Could not bind camera target lock after CameraModule; using RenderStepped fallback: "
                .. tostring(cameraBindError)
        )
        connect(RunService.RenderStepped, faceCameraTowardTarget)
    end

    connect(RunService.Heartbeat, function(deltaTime)
        if not Runtime.Running then
            stopSeaHeightMovement()
            return
        end

        enforceLocalYFloor()

        if Runtime.LocalDead then
            stopSeaHeightMovement()
            return
        end

        local humanoid = Runtime.Humanoid

        if not humanoid or not humanoid.Parent or humanoid.Health <= 0 then
            handleLocalDeath(Runtime.CharacterEpoch)
            return
        end

        if Runtime.SafeMode then
            handleHealthChanged(humanoid.Health, Runtime.CharacterEpoch)

            if Runtime.SafeMode then
                updateSafeModeMovement(deltaTime)
            end

            return
        end

        if humanoid.Health <= (Runtime.EffectiveLowHealth or LowHealth) then
            enterSafeMode()

            if Runtime.SafeMode then
                updateSafeModeMovement(deltaTime)
            end

            return
        end

        if Runtime.HopPending then
            updateEmptyCombatEntrance()
            return
        end

        if not Runtime.FriendAuditComplete then
            if Runtime.CurrentTarget then
                clearTarget("Waiting for friend checks")
            end

            return
        end

        local player = Runtime.CurrentTarget

        if not player then
            stopSeaHeightMovement()
            return
        end

        local character, targetHumanoid, targetRoot = getAliveCharacter(player)

        if not character then
            clearTarget("Target defeated or respawning")
            return
        end

        if targetRoot.Position.Y < INTERNAL.MinimumTweenY then
            clearTarget("Target moved below sea level; switching target")
            return
        end

        local targetPvpDisabled = readBooleanAttribute(player, "PvpDisabled", false)

        if targetPvpDisabled == true then
            clearTarget("Target PvP is disabled")
            return
        end

        local inSafeZone = isInsideSafeZone(targetRoot.Position)

        if inSafeZone == nil then
            clearTarget("Waiting for SafeZones")
            return
        elseif inSafeZone then
            clearTarget("Target entered the safe-zone radius")
            return
        end

        local localRoot = Runtime.Root
        local localCharacter = Runtime.Character

        if not localCharacter
            or localCharacter ~= LocalPlayer.Character
            or not localRoot
            or not localRoot.Parent
            or not localRoot:IsDescendantOf(localCharacter) then

            stopSeaHeightMovement()
            return
        end

        local lockedInfo = Runtime.CurrentTargetInfo

        if lockedInfo
            and (lockedInfo.Character ~= character
                or lockedInfo.Humanoid ~= targetHumanoid
                or lockedInfo.Root ~= targetRoot) then

            clearTarget("Target character changed; reacquiring")
            return
        end

        Runtime.CurrentTargetInfo = {
            Player = player,
            Character = character,
            Humanoid = targetHumanoid,
            Root = targetRoot,
            Level = readLevel(player),
        }
        local now = os.clock()
        local targetEpoch = Runtime.TargetEpoch
        local characterEpoch = Runtime.CharacterEpoch
        local inCombat, inCombatKnown = readLocalInCombat()

        if inCombatKnown and inCombat == true then
            Runtime.FollowNoCombatSince = nil
            Runtime.FollowTimerEpoch = nil
            Runtime.FollowTimerCharacterEpoch = nil
        elseif inCombatKnown then
            if Runtime.FollowTimerEpoch ~= targetEpoch
                or Runtime.FollowTimerCharacterEpoch ~= characterEpoch
                or not Runtime.FollowNoCombatSince then

                Runtime.FollowNoCombatSince = now
                Runtime.FollowTimerEpoch = targetEpoch
                Runtime.FollowTimerCharacterEpoch = characterEpoch
            elseif now - Runtime.FollowNoCombatSince >= PlayerFollowTime then
                local finalInCombat, finalInCombatKnown = readLocalInCombat()

                if Runtime.Running
                    and Runtime.CurrentTarget == player
                    and Runtime.TargetEpoch == targetEpoch
                    and Runtime.CharacterEpoch == characterEpoch
                    and not Runtime.SafeMode
                    and not Runtime.LocalDead
                    and not Runtime.HopPending
                    and finalInCombatKnown
                    and finalInCombat == false then

                    Runtime.FollowTimeoutCharacters[player] = character
                    clearTarget("PlayerFollowTime expired; switching to nearest target")

                    local remainingCandidates = rebuildCandidates()

                    if #remainingCandidates > 0 then
                        local nearestPlayer = remainingCandidates[1]
                        setTarget(nearestPlayer, Runtime.CandidateInfo[nearestPlayer])
                    elseif Runtime.PendingCandidateCount > 0 then
                        setStatus("PlayerFollowTime expired; waiting for player data or respawn")
                    else
                        setStatus("PlayerFollowTime expired; no remaining eligible target")
                    end

                    return
                end

                Runtime.FollowNoCombatSince = nil
                Runtime.FollowTimerEpoch = nil
                Runtime.FollowTimerCharacterEpoch = nil
            end
        else
            Runtime.FollowNoCombatSince = nil
            Runtime.FollowTimerEpoch = nil
            Runtime.FollowTimerCharacterEpoch = nil
        end

        if Runtime.Mode ~= "CHASE" and Runtime.Mode ~= "ENGAGE" then
            stopSeaHeightMovement()
            return
        end

        Runtime.AimPosition = targetRoot.Position
        applyTargetHitbox(targetRoot)
        applyLocalNoClip()

        local insideHitbox = pointInsidePart(targetRoot, localRoot.Position, 0)

        if HitboxEnabled then
            local localPosition = targetRoot.CFrame:PointToObjectSpace(localRoot.Position)
            local halfSize = ConfiguredHitboxSize * 0.5
            insideHitbox = math.abs(localPosition.X) <= halfSize.X
                and math.abs(localPosition.Y) <= halfSize.Y
                and math.abs(localPosition.Z) <= halfSize.Z
        end

        local wasInsideHitbox = Runtime.InsideHitbox
        Runtime.InsideHitbox = insideHitbox

        if AttackEnabled
            and insideHitbox
            and not wasInsideHitbox
            and Runtime.DamageCheckEpoch ~= targetEpoch then

            Runtime.DamageCheckDeadline = now + NoDamageTimeout
            Runtime.DamageCheckLastHealth = targetHumanoid.Health
            Runtime.DamageCheckEpoch = targetEpoch
            Runtime.DamageCheckCharacterEpoch = characterEpoch
            Runtime.DamageCheckExpired = false
            Runtime.DamageObserved = false
        end

        if AttackEnabled
            and Runtime.DamageCheckEpoch == targetEpoch
            and Runtime.DamageCheckCharacterEpoch == characterEpoch
            and Runtime.DamageCheckDeadline
            and not Runtime.DamageObserved then

            local currentTargetHealth = targetHumanoid.Health
            local currentInCombat, currentInCombatKnown = readLocalInCombat()

            if currentInCombatKnown and currentInCombat == true then
                -- Keep the epoch so this check cannot rearm for the same acquisition.
                Runtime.DamageCheckDeadline = nil
                Runtime.DamageCheckExpired = false
            elseif not Runtime.DamageCheckExpired
                and now < Runtime.DamageCheckDeadline
                and Runtime.DamageCheckLastHealth
                and currentTargetHealth < Runtime.DamageCheckLastHealth then

                Runtime.DamageObserved = true
                Runtime.DamageCheckDeadline = nil
            else
                Runtime.DamageCheckLastHealth = currentTargetHealth

                if (Runtime.DamageCheckExpired or now >= Runtime.DamageCheckDeadline)
                    and Runtime.CurrentTarget == player
                    and Runtime.TargetEpoch == targetEpoch
                    and Runtime.CharacterEpoch == characterEpoch then

                    Runtime.NoProgressCharacters[player] = character
                    clearTarget("No target health decrease or confirmed local combat; switching target")
                    return
                end
            end
        end

        if insideHitbox then
            if Runtime.Mode ~= "ENGAGE" then
                Runtime.Mode = "ENGAGE"
                setStatus("Engaging " .. player.Name)
            end
        elseif Runtime.Mode ~= "CHASE" then
            Runtime.Mode = "CHASE"
            Runtime.AimActive = false
            Runtime.GunAimActive = false
            releaseAllKeys()
            setStatus("Chasing " .. player.Name)
        end
            
        local chaseTimeMultiplier = getTargetTweenTimeMultiplier(localRoot, targetRoot)

        if insideHitbox and OrbitEnabled then
    local center = getHitboxMovementCFrame(
        localRoot,
        targetRoot,
        targetRoot.CFrame:PointToWorldSpace(HitboxOffset)
    ).Position
    local hitboxSize = HitboxEnabled and ConfiguredHitboxSize or targetRoot.Size

    -- Maximum radius: 8 studs. Reduce it to fit smaller hitboxes.
    local radius = math.min(
        8,
        math.min(hitboxSize.X, hitboxSize.Y, hitboxSize.Z) * 0.4
    )

    local offset = localRoot.Position - center
    local angle = math.atan2(offset.Z, offset.X)

    -- Maximum rotation: 180 degrees/second, limited by your tween speed.
    local angularSpeed = math.min(
        math.rad(180),
        TweenSpeed * INTERNAL.InHitboxSpeedMultiplier * 0.8 / radius
    ) / chaseTimeMultiplier

    angle = angle + angularSpeed * math.clamp(deltaTime, 0, 0.1)

    local orbitPosition = center + Vector3.new(
        math.cos(angle) * radius,
        0,
        math.sin(angle) * radius
    )

    AutoTween(getHitboxMovementCFrame(localRoot, targetRoot, orbitPosition), deltaTime, true, chaseTimeMultiplier)
    Runtime.ChaseTweenTimeMultiplier = chaseTimeMultiplier
    faceRootTowardTarget(localRoot, targetRoot)
else
    local chaseGoal
    local movingToSeaHeight = false

    if insideHitbox then
        chaseGoal = getHitboxMovementCFrame(
            localRoot,
            targetRoot,
            targetRoot.CFrame:PointToWorldSpace(HitboxOffset)
        )
    else
        chaseGoal, movingToSeaHeight = getPlayerChaseGoal(localRoot, targetRoot)
    end

    if movingToSeaHeight and chaseGoal then
        updateSeaHeightMovement(chaseGoal, now, targetEpoch, characterEpoch, localRoot)
    else
        stopSeaHeightMovement()

        if chaseGoal then
            local shouldAdvance = shouldAdvancePlayerChase(
                now,
                targetEpoch,
                characterEpoch,
                player,
                character,
                targetRoot,
                localRoot
            )

            -- Entering/leaving the movement box must also retime an active tween during a pause.
            if shouldAdvance or Runtime.ChaseTweenTimeMultiplier ~= chaseTimeMultiplier then
                AutoTween(chaseGoal, deltaTime, insideHitbox, chaseTimeMultiplier)
                Runtime.ChaseTweenTimeMultiplier = chaseTimeMultiplier
            end
        end
    end

    if insideHitbox then
        faceRootTowardTarget(localRoot, targetRoot)
    end
end
    end)
end

local function destroyESP(player)
    local entry = Runtime.ESPObjects[player]

    if entry and entry.Gui then
        pcall(function()
            entry.Gui:Destroy()
        end)
    end

    Runtime.ESPObjects[player] = nil
end

local function destroyAllESP()
    for player in pairs(Runtime.ESPObjects) do
        destroyESP(player)
    end
end

local function getOrCreateESP(player, root)
    local entry = Runtime.ESPObjects[player]

    if entry and (entry.Root ~= root or not entry.Gui or not entry.Gui.Parent) then
        destroyESP(player)
        entry = nil
    end

    if entry then
        return entry
    end

    local existing = root:FindFirstChild("AutoBountyESP_" .. tostring(LocalPlayer.UserId))

    if existing then
        existing:Destroy()
    end

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "AutoBountyESP_" .. tostring(LocalPlayer.UserId)
    billboard.Adornee = root
    billboard.AlwaysOnTop = true
    billboard.LightInfluence = 0
    billboard.MaxDistance = 100000
    billboard.Size = UDim2.fromOffset(270, 82)
    billboard.StudsOffset = Vector3.new(0, 4, 0)
    billboard.Parent = root

    local label = Instance.new("TextLabel")
    label.Name = "Info"
    label.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
    label.BackgroundTransparency = 0.35
    label.BorderSizePixel = 0
    label.Font = Enum.Font.GothamBold
    label.Size = UDim2.fromScale(1, 1)
    label.TextColor3 = Color3.fromRGB(110, 210, 255)
    label.TextSize = 13
    label.TextStrokeTransparency = 0.35
    label.TextWrapped = true
    label.Parent = billboard

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 5)
    corner.Parent = label

    entry = {
        Gui = billboard,
        Label = label,
        Root = root,
    }
    Runtime.ESPObjects[player] = entry
    return entry
end

local function updateESP()
    if not ESPEnabled then
        destroyAllESP()
        return
    end

    local desired = {}

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            desired[player] = true
        end
    end

    for player in pairs(Runtime.ESPObjects) do
        if not desired[player] or player.Parent ~= Players then
            destroyESP(player)
        end
    end

    for player in pairs(desired) do
        local character, humanoid, root = getAliveCharacter(player)

        if character then
            local entry = getOrCreateESP(player, root)
            local localRoot = Runtime.Root
            local distance = localRoot and (localRoot.Position - root.Position).Magnitude or 0
            local level = readLevel(player) or 0
            local teamName = player.Team and player.Team.Name or "No Team"
            local healthPercent = humanoid.MaxHealth > 0 and math.floor((humanoid.Health / humanoid.MaxHealth) * 100) or 0
            local reason = Runtime.CandidateReasons[player] or "checking"
            local playerStatus = player == Runtime.CurrentTarget and "TARGET" or string.upper(reason:gsub("%-", " "))
            entry.Label.Text = string.format(
                "[%s] %s | Lv. %d | %s\nHP %d%% | %d studs",
                playerStatus,
                player.Name,
                level,
                teamName,
                healthPercent,
                math.floor(distance)
            )
            if player == Runtime.CurrentTarget then
                entry.Label.TextColor3 = Color3.fromRGB(255, 105, 105)
            elseif reason == "eligible" then
                entry.Label.TextColor3 = Color3.fromRGB(110, 210, 255)
            else
                entry.Label.TextColor3 = Color3.fromRGB(255, 195, 95)
            end
        else
            destroyESP(player)
        end
    end
end

local function startESPWorker()
    task.spawn(function()
        while Runtime.Running do
            local success, result = pcall(updateESP)

            if not success then
                warnOnce("esp:update", "ESP update failed: " .. tostring(result))
            end

            task.wait(0.2)
        end

        destroyAllESP()
    end)
end

determineHopReason = function()
    if not AutoHopEnabled then
        return nil
    end

    local friend = findFriendInServer()

    if friend then
        return "friend", friend.Name
    end

    if Runtime.FollowTimeoutHopDetail then
        return "follow-timeout", Runtime.FollowTimeoutHopDetail
    end

    if isEmptyListHopReady() then
        return "empty", "No eligible players"
    end

    return nil
end

local HOP_PRIORITY = {
    empty = 1,
    ["follow-timeout"] = 1,
    friend = 3,
}

local function stopHopPending(message)
    local externalLaunch = Runtime.ExternalHopLaunch

    if type(externalLaunch) == "table" and not externalLaunch.Executed then
        externalLaunch.Cancelled = true
    end

    Runtime.HopAttemptEpoch = Runtime.HopAttemptEpoch + 1
    Runtime.Teleporting = false
    Runtime.HopPending = false
    Runtime.EmptyCombatEntranceAttempt = nil
    Runtime.HopReason = nil
    Runtime.HopDetail = nil
    Runtime.FollowTimeoutHopDetail = nil

    if Runtime.Running and not Runtime.SafeMode and not Runtime.LocalDead then
        Runtime.Mode = "SCAN"
        setStatus(message or "Hop cancelled; scanning")
    end
end

cancelFollowTimeoutHop = function(message)
    if not Runtime.HopPending or not Runtime.FollowTimeoutHopDetail then
        return false
    end

    Runtime.FollowTimeoutHopDetail = nil

    local replacementReason, replacementDetail = determineHopReason()

    if replacementReason then
        Runtime.HopReason = replacementReason
        Runtime.HopDetail = replacementDetail
        return false
    end

    stopHopPending(message or "PlayerFollowTime reset")
    return true
end

local function validateExternalHopLaunch(launch)
    if type(launch) ~= "table"
        or not AutoHopEnabled
        or launch.Cancelled
        or launch.Executed
        or type(launch.DownloadDeadline) ~= "number"
        or os.clock() >= launch.DownloadDeadline
        or not Runtime.Running
        or not Runtime.HopPending
        or Runtime.SafeMode
        or Runtime.LocalDead
        or Runtime.HopAttemptEpoch ~= launch.HopAttemptEpoch
        or Runtime.CharacterEpoch ~= launch.CharacterEpoch
        or Runtime.Character ~= launch.Character
        or LocalPlayer.Character ~= launch.Character
        or Environment.__AutoBountyRuntime ~= Runtime
        or Environment.__AutoBountyExternalHopLaunch ~= launch then

        return false
    end

    local humanoid = Runtime.Humanoid

    if not humanoid or humanoid.Parent ~= launch.Character or humanoid.Health <= 0 then
        return false
    end

    rebuildCandidates()

    local reason, detail = determineHopReason()
    local inCombat, inCombatKnown = readLocalInCombat()

    if not reason or not inCombatKnown or inCombat ~= false then
        return false
    end

    Runtime.HopReason = reason
    Runtime.HopDetail = detail
    launch.Reason = reason
    launch.Detail = detail
    return true
end

local function recordExternalHopAbandonedDownload(launch)
    if launch.AbandonmentCounted then
        return
    end

    launch.AbandonmentCounted = true

    if launch.Runtime == Runtime then
        Runtime.ExternalHopAbandonedDownloads = Runtime.ExternalHopAbandonedDownloads + 1
    end
end

local function beginExternalHopLaunch(reason, detail)
    if not AutoHopEnabled then
        return nil, false, "auto-hop-disabled"
    end

    local existing = Environment.__AutoBountyExternalHopLaunch

    if type(existing) == "table"
        and existing.Active
        and existing.URL == INTERNAL.ExternalHopURL then

        local downloadExpired = not existing.Executed
            and type(existing.DownloadDeadline) == "number"
            and os.clock() >= existing.DownloadDeadline

        if existing.Executed then
            Runtime.ExternalHopLaunch = existing
            Runtime.ExternalHopLaunched = true
            return existing, false, "already-executing"
        end

        if not existing.Cancelled and not downloadExpired and existing.Runtime == Runtime then
            Runtime.ExternalHopLaunch = existing
            return existing, false, "already-loading"
        end

        -- A cancelled, expired, or superseded download cannot be stopped at
        -- the transport layer. Abandon its token; its final guard prevents a
        -- late response from executing.
        existing.Cancelled = true
        existing.Active = false
        recordExternalHopAbandonedDownload(existing)

        if downloadExpired then
            existing.Stage = "download-timeout"
            existing.Error = "External hop download exceeded "
                .. tostring(INTERNAL.ExternalHopDownloadTimeout)
                .. " seconds"
        end

        if Environment.__AutoBountyExternalHopLaunch == existing then
            Environment.__AutoBountyExternalHopLaunch = nil
        end
    end

    if Runtime.ExternalHopAbandonedDownloads
        >= INTERNAL.ExternalHopMaxAbandonedDownloads then

        Runtime.ExternalHopTerminalFailure = true
        return nil, false, "download-abandon-limit"
    end

    Runtime.HopAttemptEpoch = Runtime.HopAttemptEpoch + 1

    local launch = {
        URL = INTERNAL.ExternalHopURL,
        Runtime = Runtime,
        Character = Runtime.Character,
        CharacterEpoch = Runtime.CharacterEpoch,
        HopAttemptEpoch = Runtime.HopAttemptEpoch,
        Reason = reason,
        Detail = detail,
        Active = true,
        Cancelled = false,
        Executed = false,
        Finished = false,
        Success = nil,
        Error = nil,
        Stage = "downloading",
        DownloadDeadline = os.clock() + INTERNAL.ExternalHopDownloadTimeout,
    }

    Runtime.ExternalHopLaunch = launch
    Runtime.ExternalHopLaunched = false
    Environment.__AutoBountyExternalHopLaunch = launch

    local function finishBeforeExecution(stage, message)
        launch.Stage = stage
        launch.Error = message
        launch.Finished = true
        launch.Active = false

        if Environment.__AutoBountyExternalHopLaunch == launch then
            Environment.__AutoBountyExternalHopLaunch = nil
        end
    end

    task.spawn(function()
        local downloadOk, source = pcall(function()
            return game:HttpGet(launch.URL)
        end)

        if launch.Cancelled then
            finishBeforeExecution("cancelled", "External hop download was cancelled")
            return
        end

        if not downloadOk or type(source) ~= "string" or source == "" then
            finishBeforeExecution(
                "download-failed",
                downloadOk and "The external hop response was empty" or tostring(source)
            )
            return
        end

        if os.clock() >= launch.DownloadDeadline then
            launch.Cancelled = true
            recordExternalHopAbandonedDownload(launch)
            finishBeforeExecution(
                "download-timeout",
                "External hop download exceeded "
                    .. tostring(INTERNAL.ExternalHopDownloadTimeout)
                    .. " seconds"
            )
            return
        end

        if not validateExternalHopLaunch(launch) then
            launch.Cancelled = true
            finishBeforeExecution("cancelled", "Hop state changed after download")
            return
        end

        launch.Stage = "compiling"

        local chunk
        local compileError
        local compileOk, compileCallError = pcall(function()
            if type(loadstring) ~= "function" then
                error("loadstring is unavailable")
            end

            chunk, compileError = loadstring(source)
        end)

        if not compileOk or type(chunk) ~= "function" then
            finishBeforeExecution(
                "compile-failed",
                tostring(compileOk and compileError or compileCallError)
            )
            return
        end

        -- HttpGet yielded, so perform the full guard again immediately before
        -- giving control to the external script.
        if not validateExternalHopLaunch(launch) then
            launch.Cancelled = true
            finishBeforeExecution("cancelled", "Hop state changed before external execution")
            return
        end

        launch.Stage = "executing"
        launch.Executed = true
        Runtime.ExternalHopLaunched = true

        if Environment.__AutoBountyRuntime == Runtime then
            setStatus("External server-hop script loaded (" .. tostring(launch.Reason) .. ")")
        end

        local runOk, runResult = pcall(chunk)
        launch.Finished = true
        launch.Success = runOk
        launch.Result = runResult

        if runOk then
            -- A successful return may mean the external payload spawned its
            -- own workers. Keep the launch sticky so repeated friend/empty
            -- checks cannot execute another opaque copy.
            launch.Stage = "launched"
            return
        end

        launch.Stage = "runtime-failed"
        launch.Error = tostring(runResult)
        launch.Active = false

        if Environment.__AutoBountyExternalHopLaunch == launch then
            Environment.__AutoBountyExternalHopLaunch = nil
        end

        if Environment.__AutoBountyRuntime == Runtime and Runtime.Running then
            Runtime.ExternalHopTerminalFailure = true
            warnOnce(
                "external-hop:runtime",
                "External server-hop script failed after execution began: "
                    .. tostring(runResult)
            )
            setStatus("External server-hop script failed; reload to retry")
        end
    end)

    return launch, true, "started"
end

local function runHopWorker()
    if not AutoHopEnabled then
        if Runtime.HopPending then
            stopHopPending("AutoHop disabled; scanning")
        end

        return
    end

    if Runtime.HopWorkerRunning then
        return
    end

    Runtime.HopWorkerRunning = true

    task.spawn(function()
        while Runtime.Running and Runtime.HopPending do
            clearTarget()

            while Runtime.Running
                and Runtime.HopPending
                and (Runtime.SafeMode or Runtime.LocalDead) do

                if Runtime.SafeMode then
                    Runtime.Mode = "SAFE_MODE"
                    setStatus("SafeMode active; external server hop queued")
                else
                    Runtime.Mode = "RESPAWN"
                    setStatus("Waiting for respawn before external server hop")
                end

                task.wait(0.25)
            end

            if not Runtime.Running or not Runtime.HopPending then
                break
            end

            Runtime.Mode = "HOP_WAIT"

            while Runtime.Running and Runtime.HopPending do
                rebuildCandidates()

                local activeReason = determineHopReason()

                if not activeReason then
                    stopHopPending("Hop condition cleared; scanning")
                    break
                end

                local inCombat, inCombatKnown = readLocalInCombat()

                if activeReason == "follow-timeout"
                    and inCombatKnown
                    and inCombat == true then

                    stopHopPending("Combat started; PlayerFollowTime reset")
                    break
                end

                if inCombatKnown and inCombat == false then
                    break
                end

                local emptyWhileInCombat = isEmptyListHopReady()
                    and inCombatKnown
                    and inCombat == true

                if not emptyWhileInCombat then
                    setStatus(inCombatKnown
                        and "Waiting for InCombat to turn off before external hop"
                        or "Waiting for Character.InCombat before external hop")
                end

                task.wait(0.25)
            end

            if not Runtime.Running
                or not Runtime.HopPending
                or Runtime.SafeMode
                or Runtime.LocalDead then

                task.wait(0.1)
                continue
            end

            rebuildCandidates()

            local reason, detail = determineHopReason()
            local inCombat, inCombatKnown = readLocalInCombat()

            if not reason then
                stopHopPending("Hop condition cleared; scanning")
                break
            end

            if not inCombatKnown or inCombat ~= false then
                setStatus(inCombatKnown
                    and "Waiting for InCombat to turn off before external hop"
                    or "Waiting for Character.InCombat before external hop")
                task.wait(0.25)
                continue
            end

            if Runtime.ExternalHopTerminalFailure then
                setStatus("External server-hop script failed; reload to retry")
                break
            end

            Runtime.HopReason = reason
            Runtime.HopDetail = detail
            Runtime.Mode = "HOPPING"
            setStatus("Downloading external server-hop script (" .. reason .. ")")

            local launch, started, state = beginExternalHopLaunch(reason, detail)

            if not started then
                if state == "download-abandon-limit" then
                    setStatus("External server-hop downloads remain pending; reload to retry")
                    break
                end

                if state == "already-executing" then
                    if launch.Runtime ~= Runtime and not launch.Finished then
                        setStatus("Waiting for the previous external server-hop script")

                        while Runtime.Running
                            and Runtime.HopPending
                            and not launch.Finished do

                            task.wait(0.25)
                        end
                    end

                    if not Runtime.Running or not Runtime.HopPending then
                        break
                    end

                    if launch.Finished and launch.Success == false then
                        if Environment.__AutoBountyExternalHopLaunch == launch then
                            Environment.__AutoBountyExternalHopLaunch = nil
                        end

                        Runtime.ExternalHopLaunch = nil
                        Runtime.ExternalHopLaunched = false
                        setStatus("Previous external server-hop script failed; retrying")
                        task.wait(INTERNAL.ServerRetryDelay)
                        continue
                    end

                    setStatus("External server-hop script is already active")
                    break
                end

                setStatus("External server-hop script is still downloading")
                task.wait(0.25)
                continue
            end

            while Runtime.Running
                and Runtime.HopPending
                and not launch.Executed
                and not launch.Finished do

                rebuildCandidates()

                local currentReason = determineHopReason()
                local currentInCombat, currentInCombatKnown = readLocalInCombat()

                if launch.Stage == "downloading"
                    and os.clock() >= launch.DownloadDeadline then

                    launch.Cancelled = true
                    recordExternalHopAbandonedDownload(launch)
                    launch.Active = false
                    launch.Finished = true
                    launch.Stage = "download-timeout"
                    launch.Error = "External hop download exceeded "
                        .. tostring(INTERNAL.ExternalHopDownloadTimeout)
                        .. " seconds"

                    if Environment.__AutoBountyExternalHopLaunch == launch then
                        Environment.__AutoBountyExternalHopLaunch = nil
                    end

                    break
                end

                if not currentReason then
                    launch.Cancelled = true
                    stopHopPending("Hop condition cleared; scanning")
                    break
                end

                if currentReason == "follow-timeout"
                    and currentInCombatKnown
                    and currentInCombat == true then

                    launch.Cancelled = true
                    stopHopPending("Combat started; PlayerFollowTime reset")
                    break
                end

                if Runtime.SafeMode
                    or Runtime.LocalDead
                    or not currentInCombatKnown
                    or currentInCombat ~= false then

                    launch.Cancelled = true
                    setStatus(Runtime.SafeMode
                        and "SafeMode interrupted external hop download"
                        or "Combat/respawn interrupted external hop download")
                    break
                end

                task.wait(0.1)
            end

            if launch.Stage == "runtime-failed" then
                setStatus("External server-hop script failed; reload to retry")
                break
            end

            if launch.Stage == "download-timeout" then
                warnOnce(
                    "external-hop:download-timeout",
                    tostring(launch.Error) .. "; retrying."
                )
                setStatus("External server-hop download timed out; retrying")
                task.wait(INTERNAL.ServerRetryDelay)
                continue
            end

            if launch.Executed then
                setStatus("External server-hop script loaded (" .. tostring(launch.Reason) .. ")")
                break
            end

            if launch.Finished
                and not launch.Cancelled
                and launch.Stage ~= "runtime-failed" then

                warnOnce(
                    "external-hop:" .. tostring(launch.Stage),
                    "External server-hop script could not start: "
                        .. tostring(launch.Error)
                )
                setStatus("External server-hop load failed; retrying")
                task.wait(INTERNAL.ServerRetryDelay)
            else
                task.wait(0.1)
            end
        end

        Runtime.HopWorkerRunning = false
    end)
end

requestHop = function(reason, detail)
    if not Runtime.Running or not AutoHopEnabled then
        return false
    end

    local currentPriority = HOP_PRIORITY[Runtime.HopReason] or 0
    local requestedPriority = HOP_PRIORITY[reason] or 0

    if Runtime.HopPending and requestedPriority < currentPriority then
        return
    end

    if reason == "follow-timeout" then
        Runtime.FollowTimeoutHopDetail = detail or "PlayerFollowTime expired"
    end

    if not Runtime.HopPending then
        Runtime.EmptyCombatEntranceAttempt = nil
    end

    Runtime.HopPending = true
    Runtime.HopReason = reason
    Runtime.HopDetail = detail
    clearTarget()

    if Runtime.SafeMode then
        Runtime.Mode = "SAFE_MODE"
        setStatus("SafeMode active; server hop queued")
    elseif Runtime.LocalDead then
        Runtime.Mode = "RESPAWN"
        setStatus("Respawn pending; server hop queued")
    else
        Runtime.Mode = "HOP_WAIT"
        setStatus("Server hop pending: " .. reason .. (detail and " (" .. detail .. ")" or ""))
    end

    runHopWorker()
    return true
end

local function startFriendWorker()
    for _, player in ipairs(Players:GetPlayers()) do
        requestFriendCheck(player)
    end

    connect(Players.PlayerAdded, function(player)
        Runtime.FriendAuditComplete = false

        if Runtime.CurrentTarget then
            clearTarget("Checking newly joined player for friend status")
        end

        requestFriendCheck(player)
    end)

    connect(Players.PlayerRemoving, function(player)
        destroyESP(player)
        Runtime.FriendCache[player.UserId] = nil
        Runtime.FriendCheckedAt[player.UserId] = nil

        if Runtime.FriendRetryAt then
            Runtime.FriendRetryAt[player.UserId] = nil
        end

        Runtime.PendingSince[player] = nil
        Runtime.NoProgressCharacters[player] = nil
        Runtime.FollowTimeoutCharacters[player] = nil
        Runtime.RouteFailures[player] = nil

        if Runtime.CurrentTarget == player then
            clearTarget("Target left the server")
        end
    end)

    task.spawn(function()
        while Runtime.Running do
            local allResolved = true

            for _, player in ipairs(Players:GetPlayers()) do
                requestFriendCheck(player)

                if player ~= LocalPlayer then
                    readBooleanAttribute(player, "PvpDisabled", false)

                    if Runtime.FriendCache[player.UserId] == nil then
                        allResolved = false
                    end
                end
            end

            Runtime.FriendAuditComplete = allResolved

            local friend = findFriendInServer()

            if friend then
                requestHop("friend", friend.Name)
            end

            task.wait(allResolved and INTERNAL.FriendRefreshInterval or 0.1)
        end
    end)
end

local function startTargetWorker()
    task.spawn(function()
        while Runtime.Running do
            local candidates = rebuildCandidates()

            if Runtime.CurrentTarget then
                local currentInfo = Runtime.CandidateInfo[Runtime.CurrentTarget]

                if not Runtime.FriendAuditComplete then
                    clearTarget("Waiting for initial friend checks")
                elseif currentInfo then
                    local lockedInfo = Runtime.CurrentTargetInfo

                    if (Runtime.Mode == "CHASE" or Runtime.Mode == "ENGAGE")
                        and currentInfo.Route
                        and currentInfo.Route.Kind ~= "direct" then

                        clearTarget("Target moved outside MaxTargetDistance; checking other routes")
                    elseif lockedInfo
                        and (lockedInfo.Character ~= currentInfo.Character
                            or lockedInfo.Humanoid ~= currentInfo.Humanoid
                            or lockedInfo.Root ~= currentInfo.Root) then

                        clearTarget("Target character changed; reacquiring")
                    else
                        Runtime.CurrentTargetInfo = currentInfo
                    end
                else
                    clearTarget("Current target no longer qualifies")
                end
            end

            local emptyInputsReady = Runtime.FriendAuditComplete
                and Runtime.SafeZonesFolder ~= nil
                and Runtime.SafeZonesFolder.Parent ~= nil
                and Runtime.SafeZonesReady
            local listIsEmpty = #candidates == 0
                and Runtime.PendingCandidateCount == 0

            if not emptyInputsReady or not listIsEmpty then
                Runtime.EmptySince = nil
            elseif not Runtime.LocalDead
                and not Runtime.SafeMode
                and not Runtime.EmptySince then

                Runtime.EmptySince = os.clock()
            end

            if not Runtime.LocalDead and not Runtime.SafeMode and not Runtime.HopPending then
                if not Runtime.FriendAuditComplete then
                    setStatus("Checking players for friends")
                elseif not Runtime.SafeZonesFolder or not Runtime.SafeZonesReady then
                    setStatus("Waiting for workspace._WorldOrigin.SafeZones")
                elseif #candidates > 0 then
                    if not Runtime.CurrentTarget then
                        setTarget(candidates[1], Runtime.CandidateInfo[candidates[1]])
                    end
                elseif Runtime.PendingCandidateCount > 0 then
                    setStatus("Waiting for player data or respawn")
                elseif not AutoHopEnabled then
                    setStatus("No eligible players; AutoHop disabled")
                else
                    local elapsed = Runtime.EmptySince
                        and (os.clock() - Runtime.EmptySince)
                        or 0
                    setStatus(string.format("No eligible players; hop check in %.1fs", math.max(INTERNAL.EmptyListGrace - elapsed, 0)))

                    if isEmptyListHopReady() then
                        requestHop("empty", "No eligible players")
                    end
                end
            end

            task.wait(INTERNAL.TargetRefreshInterval)
        end
    end)
end

function Runtime:Stop(reason)
    if not self.Running then
        return
    end

    self.Running = false

    if type(self.ExternalHopLaunch) == "table"
        and not self.ExternalHopLaunch.Executed then

        self.ExternalHopLaunch.Cancelled = true
    end

    self.HopPending = false
    self.EmptyCombatEntranceAttempt = nil

    if self.ActiveTween then
        self.ActiveTween:Cancel()
        self.ActiveTween = nil
    end

    self.FollowTimeoutHopDetail = nil
    self.HopAttemptEpoch = self.HopAttemptEpoch + 1
    self.Teleporting = false
    self.TargetEpoch = self.TargetEpoch + 1
    self.CharacterEpoch = self.CharacterEpoch + 1
    self.SafeEpoch = self.SafeEpoch + 1
    self.SafeModeAtAltitude = false
    self.AimActive = false
    self.GunAimActive = false
    resetTargetTimers()
    table.clear(self.NoProgressCharacters)
    table.clear(self.FollowTimeoutCharacters)
    table.clear(self.RouteFailures)

    if self.CameraBindName then
        pcall(function()
            RunService:UnbindFromRenderStep(self.CameraBindName)
        end)
        self.CameraBound = false
    end

    if self.ReleaseRaceKey then
        self.ReleaseRaceKey()
    end

    releaseAllKeys()
    restoreTargetHitbox()
    restoreLocalCollision()
    destroyAllESP()
    disconnectConnections(self.TargetConnections)
    disconnectConnections(self.CharacterConnections)
    disconnectConnections(self.SafeZoneConnections)
    disconnectConnections(self.Connections)

    if self.BountyConnection then
        pcall(function()
            self.BountyConnection:Disconnect()
        end)
        self.BountyConnection = nil
    end

    if self.GUI then
        pcall(function()
            self.GUI:Destroy()
        end)
        self.GUI = nil
    end

    if Environment.__AutoBountyRuntime == self then
        Environment.__AutoBountyRuntime = nil
    end

    if reason ~= "reload" then
        print("[AutoBounty] Stopped: " .. tostring(reason or "requested"))
    end
end

createGUI()
startBountyValueBinder()
startSafeZoneBinder()
installAimHook()
startFriendWorker()
startMovementWorker()
startWeaponWorker()
startRaceWorker()
startESPWorker()
startTargetWorker()

connect(LocalPlayer.CharacterAdded, function(character)
    bindCharacter(character)
end)

connect(LocalPlayer.CharacterRemoving, function(character)
    if character == Runtime.Character then
        handleLocalDeath(Runtime.CharacterEpoch)
    end
end)

if LocalPlayer.Character then
    bindCharacter(LocalPlayer.Character)
end

return Runtime
