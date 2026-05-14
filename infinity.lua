-- InfinityFarm v1.0
-- Targets: workspace.Zombies, M1 spam + ability rotation, auto-revive, wave skip
-- Executor: Delta (100% UNC)

local Players        = game:GetService("Players")
local RunService     = game:GetService("RunService")
local HttpService    = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local VirtualUser    = game:GetService("VirtualUser")

local LocalPlayer    = Players.LocalPlayer
local Mouse          = LocalPlayer:GetMouse()

-- ── Webhooks ──────────────────────────────────────────────────────────────────
local WEBHOOK     = "https://discord.com/api/webhooks/1371564289376366592/CrY0XxM93cxB2jC0iUPimz0VBPt3VNRHRqBqbQBkaDhLvs9kl1KNg88OaqujCxEF6OXV"
local LOG_WEBHOOK = "https://discord.com/api/webhooks/1504232139749720074/D_Oe_5gwVDguw2eUeqZbKvpmxBLeajcEZxClzS4tvyAyS80zlL3iOLHsrpOTXUsh_gdu"

-- ── Constants ─────────────────────────────────────────────────────────────────
local UNDERGROUND_Y      = 12       -- how far below zombie Y to TP
local M1_CD              = 0.42     -- conservative M1 cooldown (server enforces ~0.4s)
local ABILITY_WINDOW     = 0.08     -- gap between Began and Released
local ATTACK_RANGE       = 8        -- max distance from zombie before re-TP
local STATS_INTERVAL     = 1800     -- 30 min periodic stats webhook
local LOG_FLUSH_INTERVAL = 3        -- seconds between log webhook flushes

-- ── Services / Remotes ────────────────────────────────────────────────────────
local Assets  = game:GetService("ReplicatedStorage"):WaitForChild("Assets")
local Remotes = Assets:WaitForChild("Remotes")
local Interact = Remotes:WaitForChild("Interact")
local UsedAbilityEvent = Remotes:WaitForChild("UsedAbility")
local Utils   = require(Assets:WaitForChild("Modules"):WaitForChild("Utils"))

-- ── Character refs (refreshed on respawn) ─────────────────────────────────────
local Character, HRP, Humanoid

local function RefreshChar()
    Character = LocalPlayer.Character
    if not Character then return false end
    HRP      = Character:FindFirstChild("HumanoidRootPart")
    Humanoid = Character:FindFirstChildOfClass("Humanoid")
    return HRP ~= nil and Humanoid ~= nil
end

RefreshChar()
LocalPlayer.CharacterAdded:Connect(function(Char)
    Character = Char
    HRP       = Char:WaitForChild("HumanoidRootPart")
    Humanoid  = Char:WaitForChild("Humanoid")
end)

local function IsCharValid()
    return Character and Character.Parent
        and HRP and HRP.Parent
        and Humanoid and Humanoid.Health > 0
end

-- ── Ability info (from Player.Data.AbilitySlots JSON) ────────────────────────
local ShowcasingSlot = nil     -- e.g. "Slot1"
local ShowcasingAbility = nil  -- e.g. "Gojo"

local function RefreshAbilityInfo()
    local Data = LocalPlayer:FindFirstChild("Data")
    if not Data then return end
    local AbilitySlots = Data:FindFirstChild("AbilitySlots")
    if not AbilitySlots then return end
    local ok, Decoded = pcall(function() return Utils.Decode(AbilitySlots.Value) end)
    if not ok or not Decoded then return end
    for SlotKey, SlotData in pairs(Decoded) do
        if SlotData and SlotData.Showcasing then
            ShowcasingSlot    = SlotKey          -- e.g. "Slot1"
            ShowcasingAbility = SlotData.Name    -- e.g. "Gojo"
            return
        end
    end
end

RefreshAbilityInfo()
do
    local Data = LocalPlayer:FindFirstChild("Data")
    if Data then
        local AS = Data:FindFirstChild("AbilitySlots")
        if AS then AS:GetPropertyChangedSignal("Value"):Connect(RefreshAbilityInfo) end
    end
end

-- ── Cooldown tracking (server-authoritative via UsedAbility event) ─────────────
-- Key: slot key string ("Z","X","C","V") → EndTime (tick())
local SlotEndTime = { Z = 0, X = 0, C = 0, V = 0 }

UsedAbilityEvent.OnClientEvent:Connect(function(_, Duration, AbilityName, SlotKey)
    if SlotKey and SlotEndTime[SlotKey] ~= nil then
        SlotEndTime[SlotKey] = tick() + (Duration or 0)
    end
end)

local SlotKeys = { "Z", "X", "C", "V" }
-- Slot number the game uses for each key (Z=1, X=2, C=3, V=4 per Client.lua)
local SlotNumbers = { Z = 1, X = 2, C = 3, V = 4 }

local function AnyAbilityReady()
    for _, K in ipairs(SlotKeys) do
        if K ~= "V" and tick() >= SlotEndTime[K] then return true end
    end
    return false
end

local function FireAbility(SlotKey)
    if not ShowcasingSlot or not ShowcasingAbility then return end
    local Num = SlotNumbers[SlotKey]
    Interact:FireServer("Ability", Num, ShowcasingSlot, ShowcasingAbility, "Began")
    task.wait(ABILITY_WINDOW)
    Interact:FireServer("Ability", Num, ShowcasingSlot, ShowcasingAbility, "Released")
    -- Soft-lock until server confirms; prevents double-fire on same slot
    SlotEndTime[SlotKey] = tick() + 0.3
end

-- ── Stats ─────────────────────────────────────────────────────────────────────
local Stats = {
    M1Fired       = 0,
    AbilitiesFired = 0,
    Revives       = 0,
    WavesCleared  = 0,
    StartTime     = tick(),
}

local LastWave = workspace:GetAttribute("WavesPassed") or 0
workspace:GetAttributeChangedSignal("WavesPassed"):Connect(function()
    local W = workspace:GetAttribute("WavesPassed") or 0
    if W > LastWave then
        Stats.WavesCleared = Stats.WavesCleared + (W - LastWave)
        LastWave = W
    end
end)

-- ── Logging ───────────────────────────────────────────────────────────────────
local LogBuffer  = {}
local LogLock    = false

local OrigPrint  = print
print = function(...)
    OrigPrint(...)
    local Parts = {}
    for _, v in ipairs({...}) do table.insert(Parts, tostring(v)) end
    local Line = os.date("%H:%M:%S") .. " " .. table.concat(Parts, " ")
    table.insert(LogBuffer, Line)
    if #LogBuffer > 200 then table.remove(LogBuffer, 1) end
end

task.spawn(function()
    while true do
        task.wait(LOG_FLUSH_INTERVAL)
        if LogLock or #LogBuffer == 0 then continue end
        LogLock = true
        local Snapshot = LogBuffer
        LogBuffer = {}
        LogLock = false
        pcall(function()
            HttpService:RequestAsync({
                Url    = LOG_WEBHOOK,
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body   = HttpService:JSONEncode({
                    username = "InfinityFarm",
                    content  = "```\n" .. table.concat(Snapshot, "\n"):sub(1, 1900) .. "\n```"
                })
            })
        end)
    end
end)

-- ── Webhook ───────────────────────────────────────────────────────────────────
local WebhookThrottle = {}
local function SendWebhook(Title, Fields, Color)
    pcall(function()
        HttpService:RequestAsync({
            Url    = WEBHOOK,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body   = HttpService:JSONEncode({
                username = "InfinityFarm",
                embeds = {{ title = Title, color = Color or 3066993, fields = Fields }}
            })
        })
    end)
end

local function SendError(Label, Err)
    local Now = tick()
    if WebhookThrottle[Label] and Now - WebhookThrottle[Label] < 30 then return end
    WebhookThrottle[Label] = Now
    SendWebhook("Error: " .. Label, {
        { name = "Error", value = "```" .. tostring(Err):sub(1, 900) .. "```", inline = false }
    }, 15158332)
end

-- ── Safe wrapper ──────────────────────────────────────────────────────────────
local function Safe(Label, Fn)
    local ok, err = xpcall(Fn, function(e) return e .. "\n" .. debug.traceback() end)
    if not ok then
        print("[InfinityFarm] Error in " .. Label .. ": " .. tostring(err))
        SendError(Label, err)
    end
end

-- ── Anti-AFK ──────────────────────────────────────────────────────────────────
LocalPlayer.Idled:Connect(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
    print("[InfinityFarm] Anti-AFK: simulated input")
end)

-- ── Zombie picker ─────────────────────────────────────────────────────────────
local function IsZombieAlive(Model)
    if not Model or not Model.Parent then return false end
    local Config = Model:FindFirstChild("Config")
    if not Config then return false end
    local Health = Config:FindFirstChild("Health")
    if not Health then return false end
    return Health.Value > 0
end

local function PickNearestZombie()
    if not IsCharValid() then return nil end
    local ZombiesFolder = workspace:FindFirstChild("Zombies")
    if not ZombiesFolder then return nil end

    local Best, BestDist = nil, math.huge
    local MyPos = HRP.Position

    for _, Model in ipairs(ZombiesFolder:GetChildren()) do
        if IsZombieAlive(Model) then
            local Root = Model:FindFirstChild("HumanoidRootPart")
            if Root then
                local Dist = (Root.Position - MyPos).Magnitude
                if Dist < BestDist then
                    Best, BestDist = Model, Dist
                end
            end
        end
    end

    return Best
end

local function CountAliveZombies()
    local ZombiesFolder = workspace:FindFirstChild("Zombies")
    if not ZombiesFolder then return 0 end
    local Count = 0
    for _, Model in ipairs(ZombiesFolder:GetChildren()) do
        if IsZombieAlive(Model) then Count = Count + 1 end
    end
    return Count
end

-- ── Underground TP ────────────────────────────────────────────────────────────
local function GoUnderZombie(Target)
    if not IsCharValid() then return end
    local Root = Target and Target:FindFirstChild("HumanoidRootPart")
    if Root then
        local Pos = Root.Position
        HRP.CFrame = CFrame.new(Pos.X, Pos.Y - UNDERGROUND_Y, Pos.Z)
    else
        HRP.CFrame = CFrame.new(HRP.Position.X, HRP.Position.Y - UNDERGROUND_Y, HRP.Position.Z)
    end
    HRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
end

-- ── Wave skip voter ───────────────────────────────────────────────────────────
task.spawn(function()
    while true do
        task.wait(0.5)
        Safe("WaveSkip", function()
            if workspace:GetAttribute("InfiniteStarting") then
                Interact:FireServer("VoteSkipInfinite")
            end
        end)
    end
end)

-- ── Auto-revive ───────────────────────────────────────────────────────────────
task.spawn(function()
    while true do
        task.wait(0.5)
        Safe("AutoRevive", function()
            local Char = LocalPlayer.Character
            if Char and Char:GetAttribute("CanRevive") then
                Interact:FireServer("Revive")
                Stats.Revives = Stats.Revives + 1
                print("[InfinityFarm] Revived")
            end
        end)
    end
end)

-- ── Main attack loop ──────────────────────────────────────────────────────────
local LastM1At = 0
local Running  = true

task.spawn(function()
    while Running do
        task.wait(0.05)
        Safe("AttackLoop", function()
            -- Skip during intermission (between waves)
            if workspace:GetAttribute("Intermission") then
                task.wait(0.2)
                return
            end

            if not IsCharValid() then task.wait(0.5) return end
            if not ShowcasingAbility then
                RefreshAbilityInfo()
                task.wait(0.5)
                return
            end

            local Target = PickNearestZombie()
            if not Target then
                task.wait(0.3)
                return
            end

            local TargetRoot = Target:FindFirstChild("HumanoidRootPart")
            if not TargetRoot then return end

            -- Re-TP if drifted too far from target
            if (HRP.Position - TargetRoot.Position).Magnitude > ATTACK_RANGE then
                GoUnderZombie(Target)
                task.wait(0.05)
            end

            -- M1 spam (server enforces ~0.4s; we track locally to avoid flooding)
            local Now = tick()
            if Now - LastM1At >= M1_CD then
                local ServerTime = workspace:GetServerTimeNow()
                Interact:FireServer("M1", ShowcasingAbility, ServerTime)
                LastM1At = Now
                Stats.M1Fired = Stats.M1Fired + 1
            end

            -- Ability rotation: Z → X → C (skip V = move 4, often reserved or high CD)
            for _, Key in ipairs({ "Z", "X", "C" }) do
                if tick() >= SlotEndTime[Key] then
                    FireAbility(Key)
                    Stats.AbilitiesFired = Stats.AbilitiesFired + 1
                    task.wait(0.05)
                    break -- fire one per loop tick so M1 stays tight
                end
            end
        end)
    end
end)

-- ── Heartbeat (every 30s) ──────────────────────────────────────────────────────
task.spawn(function()
    while true do
        task.wait(30)
        Safe("Heartbeat", function()
            local Wave    = workspace:GetAttribute("WavesPassed") or 0
            local Alive   = CountAliveZombies()
            local Interm  = workspace:GetAttribute("Intermission")
            local Elapsed = math.floor(tick() - Stats.StartTime)
            local H       = math.floor(Elapsed / 3600)
            local M       = math.floor((Elapsed % 3600) / 60)
            print(string.format("[Heartbeat] wave=%d alive=%d interm=%s m1=%d abil=%d revives=%d up=%dh%dm",
                Wave, Alive, tostring(Interm), Stats.M1Fired, Stats.AbilitiesFired, Stats.Revives, H, M))
        end)
    end
end)

-- ── Periodic stats webhook (every 30 min) ─────────────────────────────────────
task.spawn(function()
    while true do
        task.wait(STATS_INTERVAL)
        Safe("StatsWebhook", function()
            local Wave    = workspace:GetAttribute("WavesPassed") or 0
            local Elapsed = math.floor(tick() - Stats.StartTime)
            local H       = math.floor(Elapsed / 3600)
            local M       = math.floor((Elapsed % 3600) / 60)
            SendWebhook("Infinity Stats", {
                { name = "Wave",       value = tostring(Wave),               inline = true },
                { name = "Uptime",     value = H .. "h " .. M .. "m",       inline = true },
                { name = "M1 Fired",   value = tostring(Stats.M1Fired),      inline = true },
                { name = "Abilities",  value = tostring(Stats.AbilitiesFired), inline = true },
                { name = "Revives",    value = tostring(Stats.Revives),       inline = true },
                { name = "Ability",    value = tostring(ShowcasingAbility),   inline = true },
            }, 3066993)
        end)
    end
end)

-- ── Startup ping ──────────────────────────────────────────────────────────────
task.spawn(function()
    task.wait(2)
    RefreshAbilityInfo()
    local Wave = workspace:GetAttribute("WavesPassed") or 0
    SendWebhook("InfinityFarm Started", {
        { name = "Wave",    value = tostring(Wave),                  inline = true },
        { name = "Ability", value = tostring(ShowcasingAbility),     inline = true },
        { name = "Slot",    value = tostring(ShowcasingSlot),        inline = true },
        { name = "Target",  value = "Wave 1300+",                    inline = true },
    }, 3066993)
    print("[InfinityFarm] Started — ability: " .. tostring(ShowcasingAbility) .. " slot: " .. tostring(ShowcasingSlot))
end)
