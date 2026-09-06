-- GitHub-side Auto Bounty module.
-- External options are intentionally limited to Team, Weapon, FastTP, ESP,
-- health thresholds, and hitbox settings.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Teams = game:GetService("Teams")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local Workspace = game:GetService("Workspace")

local Environment = getgenv and getgenv() or _G
local Config = Environment.AutoBountyConfig

assert(type(Config) == "table", "AutoBountyConfig must be configured before loading AutoBounty.lua")
assert(
    Config.Team == "Pirates" or Config.Team == "Marines",
    'AutoBountyConfig.Team must be either "Pirates" or "Marines"'
)

local Settings = type(Config.Settings) == "table" and Config.Settings or {}
local WeaponConfig = type(Config.Weapon) == "table" and Config.Weapon or {}
local HitboxConfig = type(Settings.Hitbox) == "table" and Settings.Hitbox or {}

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local FastTPEnabled = Settings.FastTP ~= false
local ESPEnabled = Settings.ESPPlayer ~= false
local LowHealth = tonumber(Settings.LowHealth) or 8000
local RecoveryHealth = tonumber(Settings.MaxHealth) or 10000

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
    TweenTime = 0.10,
    InHitboxTweenTime = 0.35,
    FastTPArrivalTimeout = 3,
    FastTPCooldown = 2,
    ServerRetryDelay = 3,
    ServerPageDelay = 0.03,
    TeleportStartTimeout = 8,
    FailedServerCooldown = 30,
    MaxServerPages = 100,
    MaxServerPlayers = 12,
    TargetRegion = "Singapore",
    SafeEntrance = Vector3.new(
        -5083.26025390625,
        314.6056823730469,
        -3175.673095703125
    ),
}

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
    },
}

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local LocalPlayer = Players.LocalPlayer

while not LocalPlayer do
    Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
    LocalPlayer = Players.LocalPlayer
end

local DataLoaded = LocalPlayer:WaitForChild("DataLoaded", 60)

assert(DataLoaded, "[AutoBounty] LocalPlayer.DataLoaded was not found within 60 seconds")
assert(DataLoaded:IsA("BoolValue"), "[AutoBounty] LocalPlayer.DataLoaded must be a BoolValue")

while not DataLoaded.Value do
    DataLoaded:GetPropertyChangedSignal("Value"):Wait()
end

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local CommF = Remotes:WaitForChild("CommF_")
local ServerBrowser = ReplicatedStorage:FindFirstChild("__ServerBrowser")

local PreviousRuntime = Environment.__AutoBountyRuntime

if PreviousRuntime and type(PreviousRuntime.Stop) == "function" then
    pcall(function()
        PreviousRuntime:Stop("reload")
    end)
end

-- This is deliberately the module's first gameplay mutation.
local TeamRequestOk, TeamRequestResult = pcall(function()
    return CommF:InvokeServer("SetTeam", Config.Team)
end)

assert(
    TeamRequestOk,
    "[AutoBounty] SetTeam failed: " .. tostring(TeamRequestResult)
)

local TeamDeadline = os.clock() + 15

while os.clock() < TeamDeadline do
    if LocalPlayer.Team and LocalPlayer.Team.Name == Config.Team then
        break
    end

    task.wait(0.1)
end

assert(
    LocalPlayer.Team and LocalPlayer.Team.Name == Config.Team,
    "[AutoBounty] The requested team was not confirmed within 15 seconds"
)

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
    AimActive = false,
    SafeMode = false,
    LocalDead = true,
    Teleporting = false,
    EntranceBusy = false,
    LastEntranceAt = 0,
    HopPending = false,
    HopReason = nil,
    HopWorkerRunning = false,
    CurrentRegion = nil,
    EmptySince = nil,
    Candidates = {},
    CandidateInfo = {},
    CandidateReasons = {},
    PendingSince = {},
    PendingCandidateCount = 0,
    Connections = {},
    CharacterConnections = {},
    PressedKeys = {},
    HitboxSnapshot = nil,
    LocalCollisionSnapshot = {},
    FriendCache = {},
    FriendCheckedAt = {},
    FriendAuditComplete = false,
    ServerAuditComplete = false,
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

local function isInsideSafeZone(worldPosition)
    if not Runtime.SafeZonesFolder
        or not Runtime.SafeZonesFolder.Parent
        or not Runtime.SafeZonesReady then

        return nil
    end

    for part in pairs(Runtime.SafeZoneParts) do
        if part.Parent and pointInsidePart(part, worldPosition, 0.5) then
            return true
        end
    end

    return false
end

local function releaseAllKeys()
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
            root.Massless = true
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
        root.Massless = true
        root.Transparency = ConfiguredHitboxTransparency
    end)
end

local function restoreLocalCollision()
    for part, canCollide in pairs(Runtime.LocalCollisionSnapshot) do
        if part.Parent and part.CanCollide == false then
            pcall(function()
                part.CanCollide = canCollide
            end)
        end
    end

    table.clear(Runtime.LocalCollisionSnapshot)
end

local function applyLocalNoClip()
    local root = Runtime.Root

    if not root or not root.Parent then
        return
    end

    if Runtime.LocalCollisionSnapshot[root] == nil then
        Runtime.LocalCollisionSnapshot[root] = root.CanCollide
    end

    root.CanCollide = false
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

local function evaluateTarget(player)
    if not player or player == LocalPlayer or player.Parent ~= Players then
        return false, "self-or-left"
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
}

local function rebuildCandidates()
    local candidates = {}
    local candidateInfo = {}
    local candidateReasons = {}
    local pendingCount = 0
    local now = os.clock()

    if Runtime.SafeZonesFolder and Runtime.SafeZonesFolder.Parent and Runtime.SafeZonesReady then
        for _, player in ipairs(Players:GetPlayers()) do
            local eligible, result = evaluateTarget(player)

            if eligible then
                table.insert(candidates, player)
                candidateInfo[player] = result
                candidateReasons[player] = "eligible"
                Runtime.PendingSince[player] = nil
            elseif player ~= LocalPlayer then
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

                    if now - pending.Since < INTERNAL.PendingTargetGrace then
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

    Runtime.Candidates = candidates
    Runtime.CandidateInfo = candidateInfo
    Runtime.CandidateReasons = candidateReasons
    Runtime.PendingCandidateCount = pendingCount
    updateTargetGUI()
    return candidates
end

local function clearTarget(reason)
    Runtime.TargetEpoch = Runtime.TargetEpoch + 1
    Runtime.AimActive = false
    Runtime.AimPosition = nil
    Runtime.InsideHitbox = false
    Runtime.CurrentTool = nil
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

local function fastTeleportForTarget(targetInfo, targetEpoch, targetPlayer)
    if not FastTPEnabled then
        return false
    end

    if Runtime.TargetEpoch ~= targetEpoch or Runtime.CurrentTarget ~= targetPlayer then
        return false
    end

    local localRoot = Runtime.Root
    local targetRoot = targetInfo and targetInfo.Root

    if not localRoot or not localRoot.Parent or not targetRoot or not targetRoot.Parent then
        return false
    end

    local entrance = nearestEntrance(targetRoot.Position)

    if not entrance then
        return false
    end

    if Runtime.TargetEpoch ~= targetEpoch or Runtime.CurrentTarget ~= targetPlayer then
        return false
    end

    Runtime.Mode = "FAST_TP"
    setStatus("FastTP toward " .. targetPlayer.Name)

    local startPosition = localRoot.Position
    local success = invokeEntrance(entrance, "FastTP", targetEpoch)

    if not success then
        return false
    end

    local deadline = os.clock() + INTERNAL.FastTPArrivalTimeout

    while Runtime.Running and Runtime.TargetEpoch == targetEpoch and os.clock() < deadline do
        local currentRoot = Runtime.Root

        if currentRoot and currentRoot.Parent and (currentRoot.Position - startPosition).Magnitude >= 50 then
            break
        end

        task.wait(0.05)
    end

    return true
end

local function setTarget(player, targetInfo)
    if not Runtime.Running or Runtime.SafeMode or Runtime.LocalDead or Runtime.HopPending then
        return false
    end

    local eligible, refreshedInfo = evaluateTarget(player)

    if not eligible then
        return false
    end

    clearTarget()
    Runtime.CurrentTarget = player
    local preparedInfo = refreshedInfo or targetInfo
    Runtime.CurrentTargetInfo = preparedInfo
    Runtime.Mode = "PREPARE"
    Runtime.TargetEpoch = Runtime.TargetEpoch + 1
    local targetEpoch = Runtime.TargetEpoch
    updateTargetGUI()
    setStatus("Preparing " .. player.Name)

    task.spawn(function()
        if Runtime.TargetEpoch ~= targetEpoch or Runtime.CurrentTarget ~= player then
            return
        end

        ensureCombatAttributes()

        if Runtime.TargetEpoch ~= targetEpoch or Runtime.CurrentTarget ~= player then
            return
        end

        startPvPEnable()
        fastTeleportForTarget(preparedInfo, targetEpoch, player)

        if not Runtime.Running
            or Runtime.TargetEpoch ~= targetEpoch
            or Runtime.CurrentTarget ~= player
            or Runtime.SafeMode
            or Runtime.HopPending then

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

        Runtime.CurrentTargetInfo = latestInfo
        applyTargetHitbox(latestInfo.Root)
        Runtime.Mode = "CHASE"
        setStatus("Chasing " .. player.Name)
    end)

    return true
end

local function canAttack(targetEpoch)
    if not Runtime.Running
        or Runtime.TargetEpoch ~= targetEpoch
        or not Runtime.CurrentTarget
        or Runtime.SafeMode
        or Runtime.LocalDead
        or Runtime.HopPending
        or not Runtime.FriendAuditComplete
        or not Runtime.ServerAuditComplete
        or Runtime.Mode ~= "ENGAGE"
        or not Runtime.InsideHitbox then

        return false
    end

    local localHumanoid = Runtime.Humanoid
    local targetInfo = Runtime.CurrentTargetInfo
    local targetHumanoid = targetInfo and targetInfo.Humanoid

    if not localHumanoid
        or not localHumanoid.Parent
        or localHumanoid.Health <= 0
        or not targetHumanoid
        or not targetHumanoid.Parent
        or targetHumanoid.Health <= 0 then

        return false
    end

    if LocalPlayer:GetAttribute("PvpDisabled") == true then
        startPvPEnable()
        return false
    end

    if Runtime.CurrentTarget:GetAttribute("PvpDisabled") == true then
        return false
    end

    return true
end

local function AutoTween(goalCFrame, deltaTime, insideHitbox)
    local root = Runtime.Root

    if not root or not root.Parent then
        return
    end

    local tweenTime = insideHitbox and INTERNAL.InHitboxTweenTime or INTERNAL.TweenTime
    local alpha = tweenTime <= 0 and 1 or (1 - math.exp(-deltaTime / tweenTime))
    root.CFrame = root.CFrame:Lerp(goalCFrame, math.clamp(alpha, 0, 1))
end

local function faceRootTowardTarget(localRoot, targetRoot)
    local targetPosition = targetRoot.Position
    local flatTarget = Vector3.new(targetPosition.X, localRoot.Position.Y, targetPosition.Z)

    if (flatTarget - localRoot.Position).Magnitude > 0.001 then
        localRoot.CFrame = CFrame.lookAt(localRoot.Position, flatTarget)
    end
end

local function faceCameraTowardTarget()
    if not Runtime.Running
        or Runtime.LocalDead
        or Runtime.SafeMode
        or Runtime.HopPending
        or not Runtime.InsideHitbox
        or Runtime.Mode ~= "ENGAGE" then

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
        or not camera then

        return
    end

    local cameraPosition = camera.CFrame.Position

    if (targetRoot.Position - cameraPosition).Magnitude > 0.001 then
        camera.CFrame = CFrame.lookAt(cameraPosition, targetRoot.Position)
    end
end

local function installAimHook()
    if Environment.__AutoBountyAimHookInstalled then
        return
    end

    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
        warnOnce("aimbot:unsupported", "Aimbot hook APIs are unavailable; skills will still cast without aim redirection.")
        return
    end

    local oldNamecall
    local unpackArguments = table.unpack or unpack
    local function handler(remote, ...)
        local runtime = Environment.__AutoBountyRuntime
        local method = getnamecallmethod()

        if runtime
            and runtime.Running
            and runtime.AimActive
            and runtime.InsideHitbox
            and runtime.AimPosition
            and runtime.CurrentTool
            and (method == "FireServer" or method == "InvokeServer")
            and typeof(remote) == "Instance" then

            local belongsToTool = false
            pcall(function()
                belongsToTool = remote:IsDescendantOf(runtime.CurrentTool)
            end)

            if belongsToTool then
                local arguments = table.pack(...)

                for index = 1, arguments.n do
                    local argumentType = typeof(arguments[index])

                    if argumentType == "Vector3" then
                        arguments[index] = runtime.AimPosition
                        break
                    elseif argumentType == "CFrame" then
                        arguments[index] = CFrame.new(runtime.AimPosition) * arguments[index].Rotation
                        break
                    end
                end

                return oldNamecall(remote, unpackArguments(arguments, 1, arguments.n))
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

local function waitWhileAttackable(duration, targetEpoch)
    local deadline = os.clock() + math.max(tonumber(duration) or 0, 0)
    local yielded = false

    repeat
        task.wait()
        yielded = true

        if not canAttack(targetEpoch) then
            return false
        end
    until os.clock() >= deadline and yielded

    return true
end

local function equipTool(tool, targetEpoch)
    if not tool or not tool.Parent or not canAttack(targetEpoch) then
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

        if canAttack(targetEpoch) and tool.Parent then
            humanoid:EquipTool(tool)
        end
    end)

    if not success then
        warnOnce("weapon:equip:" .. tool.Name, "Could not equip " .. tool.Name .. ": " .. tostring(result))
        return false
    end

    local deadline = os.clock() + 1

    while Runtime.Running and canAttack(targetEpoch) and os.clock() < deadline do
        if tool.Parent == character then
            Runtime.CurrentTool = tool
            return true
        end

        task.wait(0.03)
    end

    return false
end

local function castSkill(keyName, skillConfig, targetEpoch)
    if not canAttack(targetEpoch) then
        return false
    end

    local holdTime = math.max(tonumber(skillConfig.Hold) or 0, 0)
    Runtime.AimActive = true

    if not pressKeyDown(keyName) then
        Runtime.AimActive = false
        return false
    end

    local waitOk, completed = pcall(waitWhileAttackable, holdTime, targetEpoch)
    releaseKey(keyName)
    Runtime.AimActive = false

    if not waitOk then
        warnOnce("skill:hold:" .. keyName, "Skill hold for " .. keyName .. " failed: " .. tostring(completed))
        return false
    end

    return completed
end

local function startWeaponWorker()
    task.spawn(function()
        local weaponOrder = getWeaponOrder()

        while Runtime.Running do
            if not Runtime.CurrentTarget or not Runtime.InsideHitbox then
                Runtime.AimActive = false
                Runtime.CurrentTool = nil
                releaseAllKeys()
                task.wait(0.05)
            else
                local targetEpoch = Runtime.TargetEpoch

                if not canAttack(targetEpoch) then
                    Runtime.AimActive = false
                    releaseAllKeys()
                    task.wait(0.05)
                else
                    for _, category in ipairs(weaponOrder) do
                        if not canAttack(targetEpoch) then
                            break
                        end

                        local categoryConfig = WeaponConfig[category]

                        if type(categoryConfig) == "table" and categoryConfig.Enabled == true then
                            local tool = resolveTool(category, categoryConfig)

                            if tool and equipTool(tool, targetEpoch) then
                                Runtime.CurrentTool = tool

                                local skills = type(categoryConfig.Skills) == "table" and categoryConfig.Skills or {}

                                for _, keyName in ipairs(SKILL_ORDER) do
                                    local skillConfig = skills[keyName]

                                    if type(skillConfig) == "table" and skillConfig.Enabled == true then
                                        if not castSkill(keyName, skillConfig, targetEpoch) then
                                            break
                                        end

                                        if not waitWhileAttackable(categoryConfig.Delay or 0.1, targetEpoch) then
                                            break
                                        end
                                    end
                                end
                            end
                        end
                    end

                    Runtime.AimActive = false
                    task.wait(0.03)
                end
            end
        end

        Runtime.AimActive = false
        releaseAllKeys()
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
    local safeEpoch = Runtime.SafeEpoch
    local characterEpoch = Runtime.CharacterEpoch
    clearTarget()
    Runtime.Mode = "SAFE_MODE"
    setStatus("SafeMode: low health")

    task.spawn(function()
        invokeEntrance(INTERNAL.SafeEntrance, "SafeMode", nil, function()
            return Runtime.SafeMode
                and not Runtime.LocalDead
                and Runtime.SafeEpoch == safeEpoch
                and Runtime.CharacterEpoch == characterEpoch
        end)
    end)
end

exitSafeMode = function()
    if not Runtime.SafeMode or Runtime.LocalDead then
        return
    end

    Runtime.SafeMode = false
    Runtime.SafeEpoch = Runtime.SafeEpoch + 1
    Runtime.Mode = Runtime.HopPending and "HOP_WAIT" or "SCAN"
    Runtime.EmptySince = nil
    setStatus(Runtime.HopPending and "Recovered; resuming server hop" or "Recovered; scanning")
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
        if not Runtime.Running or Runtime.LocalDead or Runtime.SafeMode or Runtime.HopPending then
            return
        end

        if not Runtime.FriendAuditComplete or not Runtime.ServerAuditComplete then
            if Runtime.CurrentTarget then
                clearTarget("Waiting for server safety checks")
            end

            return
        end

        local humanoid = Runtime.Humanoid

        if not humanoid or not humanoid.Parent or humanoid.Health <= 0 then
            handleLocalDeath(Runtime.CharacterEpoch)
            return
        end

        if humanoid.Health <= (Runtime.EffectiveLowHealth or LowHealth) then
            enterSafeMode()
            return
        end

        local player = Runtime.CurrentTarget

        if not player or (Runtime.Mode ~= "CHASE" and Runtime.Mode ~= "ENGAGE") then
            return
        end

        local character, targetHumanoid, targetRoot = getAliveCharacter(player)

        if not character then
            clearTarget("Target defeated or respawning")
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
            clearTarget("Target entered a safe zone")
            return
        end

        local localRoot = Runtime.Root

        if not localRoot or not localRoot.Parent then
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

        Runtime.InsideHitbox = insideHitbox

        if insideHitbox then
            if Runtime.Mode ~= "ENGAGE" then
                Runtime.Mode = "ENGAGE"
                setStatus("Engaging " .. player.Name)
            end
        elseif Runtime.Mode ~= "CHASE" then
            Runtime.Mode = "CHASE"
            Runtime.AimActive = false
            releaseAllKeys()
            setStatus("Chasing " .. player.Name)
        end

        AutoTween(targetRoot.CFrame, deltaTime, insideHitbox)

        if insideHitbox then
            faceRootTowardTarget(localRoot, targetRoot)
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

local function isTargetRegion(region)
    return type(region) == "string"
        and string.find(string.lower(region), string.lower(INTERNAL.TargetRegion), 1, true) ~= nil
end

local function getCurrentJob()
    local browser = ServerBrowser

    if not browser or not browser.Parent then
        browser = ReplicatedStorage:FindFirstChild("__ServerBrowser")
        ServerBrowser = browser
    end

    if not browser then
        return game.JobId
    end

    local success, jobId = pcall(function()
        return browser:InvokeServer("getjob")
    end)

    if success and type(jobId) == "string" and jobId ~= "" then
        return jobId
    end

    return game.JobId
end

local function scanServers()
    while Runtime.Running and Runtime.ServerScanBusy do
        task.wait(0.1)
    end

    if not Runtime.Running then
        return nil, {}
    end

    local browser = ServerBrowser

    if not browser or not browser.Parent then
        browser = ReplicatedStorage:FindFirstChild("__ServerBrowser")
        ServerBrowser = browser
    end

    if not browser then
        warnOnce("server-browser:missing", "ReplicatedStorage.__ServerBrowser is missing; server hopping will keep retrying.")
        return nil, {}
    end

    Runtime.ServerScanBusy = true
    local currentJob = tostring(getCurrentJob())
    local currentRegion
    local available = {}
    Runtime.FailedServers = Runtime.FailedServers or {}

    for jobId, failedUntil in pairs(Runtime.FailedServers) do
        if type(failedUntil) ~= "number" or failedUntil <= os.clock() then
            Runtime.FailedServers[jobId] = nil
        end
    end

    for page = 1, INTERNAL.MaxServerPages do
        if not Runtime.Running then
            break
        end

        local success, servers = pcall(function()
            return browser:InvokeServer(page)
        end)

        if not success then
            warnOnce("server-browser:page", "A server-browser page request failed: " .. tostring(servers))
        elseif type(servers) ~= "table" then
            warnOnce("server-browser:schema", "The server browser returned an unexpected page format.")
        else
            local pageHadEntries = false

            for key, info in pairs(servers) do
                if type(info) == "table" then
                    pageHadEntries = true
                    local jobId = tostring(info.JobId or info.Id or key)
                    local region = type(info.Region) == "string" and info.Region or ""
                    local count = tonumber(info.Count or info.Playing or info.Players)

                    if jobId == currentJob or jobId == tostring(game.JobId) then
                        currentRegion = region ~= "" and region or currentRegion
                    elseif jobId ~= ""
                        and isTargetRegion(region)
                        and count
                        and count < INTERNAL.MaxServerPlayers
                        and not Runtime.FailedServers[jobId] then

                        table.insert(available, {
                            JobId = jobId,
                            Count = count,
                            Region = region,
                        })
                    end
                end
            end

            if not pageHadEntries then
                break
            end
        end

        task.wait(INTERNAL.ServerPageDelay)
    end

    table.sort(available, function(left, right)
        if left.Count == right.Count then
            return left.JobId < right.JobId
        end

        return left.Count < right.Count
    end)

    Runtime.CurrentRegion = currentRegion
    Runtime.RegionChecked = true
    Runtime.ServerScanBusy = false
    return currentRegion, available
end

local function determineHopReason()
    local friend = findFriendInServer()

    if friend then
        return "friend", friend.Name
    end

    if Runtime.RegionChecked and not isTargetRegion(Runtime.CurrentRegion) then
        return "region", Runtime.CurrentRegion or "Unknown"
    end

    if Runtime.SafeZonesReady
        and Runtime.FriendAuditComplete
        and Runtime.ServerAuditComplete
        and Runtime.EmptySince
        and os.clock() - Runtime.EmptySince >= INTERNAL.EmptyListGrace
        and #Runtime.Candidates == 0
        and Runtime.PendingCandidateCount == 0 then

        return "empty", "No eligible players"
    end

    return nil
end

local HOP_PRIORITY = {
    empty = 1,
    region = 2,
    friend = 3,
}

local function stopHopPending(message)
    Runtime.HopPending = false
    Runtime.HopReason = nil
    Runtime.HopDetail = nil

    if Runtime.Running and not Runtime.SafeMode and not Runtime.LocalDead then
        Runtime.Mode = "SCAN"
        setStatus(message or "Hop cancelled; scanning")
    end
end

local function runHopWorker()
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
                    setStatus("SafeMode active; server hop queued")
                else
                    Runtime.Mode = "RESPAWN"
                    setStatus("Waiting for respawn before server hop")
                end

                task.wait(0.25)
            end

            if not Runtime.Running or not Runtime.HopPending then
                break
            end

            Runtime.Mode = "HOP_WAIT"

            while Runtime.Running and Runtime.HopPending do
                local inCombat = readBooleanAttribute(LocalPlayer, "InCombat", false)

                if inCombat ~= true then
                    break
                end

                setStatus("Waiting for InCombat to turn off before hopping")
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

            if not reason then
                stopHopPending("Hop condition cleared; scanning")
                break
            end

            Runtime.HopReason = reason
            Runtime.HopDetail = detail
            setStatus("Scanning Singapore servers (" .. reason .. ")")
            local _, servers = scanServers()

            if not Runtime.Running or not Runtime.HopPending then
                break
            end

            if Runtime.SafeMode or Runtime.LocalDead then
                task.wait(0.1)
                continue
            end

            rebuildCandidates()
            reason, detail = determineHopReason()

            if not reason then
                stopHopPending("Hop condition cleared; scanning")
                break
            end

            Runtime.HopReason = reason
            Runtime.HopDetail = detail

            if Runtime.SafeMode or Runtime.LocalDead then
                task.wait(0.1)
            elseif LocalPlayer:GetAttribute("InCombat") == true then
                setStatus("Combat restarted; delaying server hop")
                task.wait(0.25)
            elseif #servers == 0 then
                setStatus("No Singapore server available; retrying")
                task.wait(INTERNAL.ServerRetryDelay)
            else
                local selectionLimit = math.min(5, #servers)
                local chosen = servers[math.random(1, selectionLimit)]
                local teleportStarted = false
                local teleportFailed = false
                local teleportFailureMessage
                local teleportConnection = LocalPlayer.OnTeleport:Connect(function(state)
                    if state == Enum.TeleportState.Failed then
                        teleportFailed = true
                        teleportFailureMessage = "OnTeleport reported Failed"
                    elseif state == Enum.TeleportState.Started
                        or state == Enum.TeleportState.WaitingForServer
                        or state == Enum.TeleportState.InProgress then

                        teleportStarted = true
                    end
                end)
                local initFailedConnection = TeleportService.TeleportInitFailed:Connect(function(player, _, errorMessage)
                    if player == LocalPlayer then
                        teleportFailed = true
                        teleportFailureMessage = tostring(errorMessage)
                    end
                end)

                -- Final race check immediately before the teleport remote.
                local finalInCombat = readBooleanAttribute(LocalPlayer, "InCombat", false)

                if finalInCombat == true or Runtime.SafeMode or Runtime.LocalDead then
                    teleportConnection:Disconnect()
                    initFailedConnection:Disconnect()
                    setStatus(Runtime.SafeMode and "SafeMode active; server hop queued" or "Combat/respawn interrupted server hop")
                    task.wait(0.25)
                else
                    Runtime.Mode = "HOPPING"
                    setStatus(string.format("Joining Singapore server (%d/%d)", chosen.Count, INTERNAL.MaxServerPlayers))
                    Runtime.Teleporting = true

                    local deadline = os.clock() + INTERNAL.TeleportStartTimeout
                    local invokeFinished = false
                    local success
                    local result

                    task.spawn(function()
                        success, result = pcall(function()
                            return ServerBrowser:InvokeServer("teleport", chosen.JobId)
                        end)
                        invokeFinished = true
                    end)

                    while Runtime.Running
                        and not teleportFailed
                        and not Runtime.SafeMode
                        and not Runtime.LocalDead
                        and os.clock() < deadline do

                        if invokeFinished and success == false then
                            break
                        end

                        task.wait(0.1)
                    end

                    Runtime.Teleporting = false
                    teleportConnection:Disconnect()
                    initFailedConnection:Disconnect()

                    local interrupted = Runtime.SafeMode or Runtime.LocalDead

                    if interrupted then
                        setStatus(Runtime.SafeMode and "SafeMode active; server hop queued" or "Respawn interrupted server hop")
                    else
                        Runtime.FailedServers[chosen.JobId] = os.clock() + INTERNAL.FailedServerCooldown
                    end

                    if interrupted then
                        -- The queued hop resumes after SafeMode/respawn.
                    elseif not invokeFinished then
                        warnOnce("server-browser:invoke-timeout:" .. chosen.JobId, "The server teleport remote did not return before timeout; trying another server.")
                    elseif not success then
                        warnOnce("server-browser:teleport:" .. chosen.JobId, "Server teleport failed: " .. tostring(result))
                    elseif teleportFailed then
                        warnOnce("server-browser:teleport-state:" .. chosen.JobId, "Server teleport failed after starting: " .. tostring(teleportFailureMessage))
                    elseif teleportStarted then
                        warnOnce("server-browser:stalled:" .. chosen.JobId, "Teleport started but this client did not leave within the timeout; trying another server.")
                    else
                        warnOnce("server-browser:no-start:" .. chosen.JobId, "Server teleport did not start; another server will be tried.")
                    end

                    task.wait(INTERNAL.ServerRetryDelay)
                end
            end
        end

        Runtime.HopWorkerRunning = false
    end)
end

requestHop = function(reason, detail)
    if not Runtime.Running then
        return
    end

    local currentPriority = HOP_PRIORITY[Runtime.HopReason] or 0
    local requestedPriority = HOP_PRIORITY[reason] or 0

    if Runtime.HopPending and requestedPriority < currentPriority then
        return
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

                if not Runtime.FriendAuditComplete or not Runtime.ServerAuditComplete then
                    clearTarget("Waiting for initial server safety checks")
                elseif currentInfo then
                    local lockedInfo = Runtime.CurrentTargetInfo

                    if lockedInfo
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

            if not Runtime.LocalDead and not Runtime.SafeMode and not Runtime.HopPending then
                if not Runtime.ServerAuditComplete then
                    Runtime.EmptySince = nil
                    setStatus("Waiting for server-region check")
                elseif not Runtime.FriendAuditComplete then
                    Runtime.EmptySince = nil
                    setStatus("Checking players for friends")
                elseif not Runtime.SafeZonesFolder or not Runtime.SafeZonesReady then
                    Runtime.EmptySince = nil
                    setStatus("Waiting for workspace._WorldOrigin.SafeZones")
                elseif #candidates > 0 then
                    Runtime.EmptySince = nil

                    if not Runtime.CurrentTarget then
                        setTarget(candidates[1], Runtime.CandidateInfo[candidates[1]])
                    end
                elseif Runtime.PendingCandidateCount > 0 then
                    Runtime.EmptySince = nil
                    setStatus("Waiting for player data or respawn")
                else
                    if not Runtime.EmptySince then
                        Runtime.EmptySince = os.clock()
                    end

                    local elapsed = os.clock() - Runtime.EmptySince
                    setStatus(string.format("No eligible players; hop check in %.1fs", math.max(INTERNAL.EmptyListGrace - elapsed, 0)))

                    if elapsed >= INTERNAL.EmptyListGrace then
                        requestHop("empty", "No eligible players")
                    end
                end
            end

            task.wait(INTERNAL.TargetRefreshInterval)
        end
    end)
end

local function startServerAudit()
    task.spawn(function()
        while Runtime.Running and not Runtime.ServerAuditComplete do
            setStatus("Checking server region")
            local region = scanServers()

            if not Runtime.Running then
                return
            end

            Runtime.ServerAuditComplete = Runtime.RegionChecked == true

            if Runtime.ServerAuditComplete then
                if not isTargetRegion(region) then
                    requestHop("region", region or "Unknown")
                elseif not Runtime.CurrentTarget and not Runtime.HopPending then
                    setStatus("Singapore server confirmed; scanning")
                end

                return
            end

            setStatus("Server browser unavailable; retrying region check")
            task.wait(INTERNAL.ServerRetryDelay)
        end
    end)
end

function Runtime:Stop(reason)
    if not self.Running then
        return
    end

    self.Running = false
    self.HopPending = false
    self.TargetEpoch = self.TargetEpoch + 1
    self.CharacterEpoch = self.CharacterEpoch + 1
    self.SafeEpoch = self.SafeEpoch + 1
    self.AimActive = false

    if self.CameraBindName then
        pcall(function()
            RunService:UnbindFromRenderStep(self.CameraBindName)
        end)
        self.CameraBound = false
    end

    releaseAllKeys()
    restoreTargetHitbox()
    restoreLocalCollision()
    destroyAllESP()
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

readBooleanAttribute(LocalPlayer, "InCombat", false)
startServerAudit()

return Runtime
