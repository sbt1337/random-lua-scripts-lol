if game.PlaceId == 140409475718339 then return end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local Humanoid = Character:WaitForChild("Humanoid")
local HRP = Character:WaitForChild("HumanoidRootPart")

-- Anti-AFK: Roblox kicks after ~20 minutes of no input. Hook Idled and simulate a click.
do
    local VirtualUser = game:GetService("VirtualUser")
    LocalPlayer.Idled:Connect(function()
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
        print("[StoryFarm] Anti-AFK: simulated input")
    end)
end

local Running = true
local Attacking = false
local AttackStartTime = 0
local CurrentTarget = nil
local CurrentTargetIsBoss = false
local SlotCooldownEnd = { 0, 0, 0, 0 } -- per-slot cooldown end time, set by UsedAbility event
local LastDamageAt = 0
local LastSeenHP = nil

local Stats = {
    AttacksAttempted = 0,
    AttacksAborted = 0,
    MatchesCompleted = 0,
    Rebirths = 0,
    TotalKills = 0,
    TotalDamage = 0,
    StartTime = tick(),
}

local WEBHOOK = "https://discord.com/api/webhooks/1503857688118034662/H3y9e9EUyyZyRnKCQ-X_eIdRpejU8OwStg22dzEoycfGt__iAhRTYmnumIenbFWEckS7"
local LOG_WEBHOOK = "https://discord.com/api/webhooks/1504232139749720074/D_Oe_5gwVDguw2eUeqZbKvpmxBLeajcEZxClzS4tvyAyS80zlL3iOLHsrpOTXUsh_gdu"
local UNDERGROUND_Y = 10
local ATTACK_HEIGHT = 5
local MAX_ZOMBIE_RANGE = 10000 -- effectively uncapped so we follow zombies into new sections
local ATTACK_COOLDOWN_PER_ZOMBIE = 0.3 -- just enough for death events to propagate
local ATTACK_TIMEOUT = 4
local STATS_INTERVAL = 1800
local AOE_RADIUS = 12 -- assumed melee/AOE hitbox radius for cluster-picking
local ATTACK_WINDOW = 0.8 -- shorter surface window = less exposure
local POST_DAMAGE_LOCKOUT = 1.5 -- stay underground this long after taking any hit
local DAMAGE_ABORT_THRESHOLD = 0.15 -- fraction of MaxHealth lost during a swing that triggers retreat (was 1 HP literal — chip-hits in dense groups stalled us forever)
local DAMAGE_GRACE_PERIOD    = 0.15 -- seconds after surfacing where damage doesn't abort the swing (lets the first ability actually fire)

-- Live caches updated by events (not polling)
-- [Model] = { Root = HRP, Health = IntValue, Conns = {connections} }
local AliveZombies = {}
local AliveBosses = {}
local RecentlyAttacked = {}
local LastAttackAt = tick() -- updated each time we fire an ability; used by stuck-recovery + heartbeat

-- Game's blocking state child names (from Utils.ActionCheck)
local BLOCKING_STATES = { "LightAttack", "NoAttack", "Action", "Stun", "UsingMove" }

local REBIRTH_STEPS = {
    { RequiredLevel = 50, CoinsRequired = 2500000 },
    { RequiredLevel = 50, CoinsRequired = 5000000 },
    { RequiredLevel = 50, CoinsRequired = 7500000 },
    { RequiredLevel = 50, CoinsRequired = 10000000 },
    { RequiredLevel = 50, CoinsRequired = 12500000 },
}

print("[StoryFarm] Loaded")

-- Log webhook: batches print() output and flushes every 3s so we can read it on mobile.
-- Discord allows ~30 req/min/webhook; batching keeps us well under that.
local LogBuffer = {}
local RawPrint = print
local LogStats = { Sent = 0, Failed = 0, Dropped = 0 }

local function FlushLogs()
    if #LogBuffer == 0 then return end

    -- Snapshot then clear, so the lock can never deadlock
    local Snapshot = LogBuffer
    LogBuffer = {}

    -- Pull lines that fit in ~1800 chars; re-queue the rest at front
    local Lines, TotalLen = {}, 0
    for i, Line in ipairs(Snapshot) do
        if TotalLen + #Line + 1 > 1800 then
            for j = i, #Snapshot do
                table.insert(LogBuffer, j - i + 1, Snapshot[j])
            end
            break
        end
        table.insert(Lines, Line)
        TotalLen = TotalLen + #Line + 1
    end

    local Payload = table.concat(Lines, "\n")
    if #Payload == 0 then return end

    local RequestFunc = (syn and syn.request) or request or http_request
    if not RequestFunc then
        LogStats.Dropped = LogStats.Dropped + #Lines
        return
    end

    local ok = pcall(function()
        local Body = HttpService:JSONEncode({
            username = "StoryFarm Logs",
            content = "```" .. Payload .. "```",
        })
        RequestFunc({
            Url = LOG_WEBHOOK,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = Body,
        })
    end)
    if ok then LogStats.Sent = LogStats.Sent + #Lines
    else LogStats.Failed = LogStats.Failed + #Lines end
end

-- Override print so any existing print() call also goes to the log webhook.
print = function(...)
    local n = select("#", ...)
    local Parts = {}
    for i = 1, n do Parts[i] = tostring((select(i, ...))) end
    local Msg = table.concat(Parts, " ")
    pcall(RawPrint, Msg) -- still goes to F9; pcall so a print error can't propagate
    if #LogBuffer >= 300 then table.remove(LogBuffer, 1) end -- cap buffer to prevent runaway memory
    table.insert(LogBuffer, os.date("%H:%M:%S") .. " " .. Msg)
end

task.spawn(function()
    while true do
        task.wait(3)
        pcall(FlushLogs)
    end
end)

-- Forward declarations. The heartbeat (below) and other early closures reference
-- SendWebhook + LooksLikeZombie, but their `local function` decls live much later in
-- the file. Without these forward `local`s, the closures resolve them as globals at
-- parse time, get nil at call time, and the pcall silently eats the error every 30s.
-- That's why the "Script Stalled" alarm webhook never fires when zombies are present.
local SendWebhook
local LooksLikeZombie

-- Heartbeat: prints script state every 30s so we know it's still alive even if nothing else logs
local LastStuckAlarm = 0
task.spawn(function()
    while true do
        task.wait(30)
        pcall(function()
            local Z = 0
            for _ in pairs(AliveZombies) do Z = Z + 1 end
            local Folder = workspace:FindFirstChild("Zombies")
            local InFolder = 0
            local ZombiesFolderDump = "(no Zombies)"
            if Folder then
                for _, Desc in ipairs(Folder:GetDescendants()) do
                    if LooksLikeZombie(Desc) then InFolder = InFolder + 1 end
                end
                -- Raw dump of direct children (unfiltered)
                local Raw = {}
                for _, C in ipairs(Folder:GetChildren()) do
                    table.insert(Raw, C.ClassName .. ":" .. C.Name)
                    if #Raw >= 10 then table.insert(Raw, "...") break end
                end
                ZombiesFolderDump = #Raw > 0 and table.concat(Raw, ", ") or "(empty)"
            end
            local SinceAttack = math.floor(tick() - LastAttackAt)
            local GF = workspace:FindFirstChild("GameFinished") and "Y" or "N"
            local SS = workspace:FindFirstChild("SwitchingSection") and "Y" or "N"
            local CS = workspace:FindFirstChild("Cutscene") and "Y" or "N"

            -- Scan workspace direct children for any folder/model containing zombie-like models.
            local Locations = {}
            local AllChildren = {}
            for _, Child in ipairs(workspace:GetChildren()) do
                table.insert(AllChildren, Child.Name .. ":" .. Child.ClassName)
                local Count = 0
                if Child:IsA("Folder") or Child:IsA("Model") then
                    for _, Sub in ipairs(Child:GetChildren()) do
                        if Sub:IsA("Model")
                            and (Sub:FindFirstChild("Config") or Sub:FindFirstChild("HumanoidRootPart")) then
                            Count = Count + 1
                        end
                    end
                end
                if Count > 0 then
                    table.insert(Locations, Child.Name .. "=" .. Count)
                end
            end

            -- Also scan CollectionService for any tag that has tagged models (revealing alt tracking systems)
            local TagCounts = {}
            for _, Tag in ipairs({ "RaidBoss", "Boss", "Zombie", "Enemy", "Mob", "EnemyMob" }) do
                local Found = #CollectionService:GetTagged(Tag)
                if Found > 0 then table.insert(TagCounts, Tag .. "=" .. Found) end
            end

            print("[Heartbeat] running=" .. tostring(Running)
                .. " cached=" .. Z
                .. " folder=" .. InFolder
                .. " attacks=" .. Stats.AttacksAttempted
                .. " matches=" .. Stats.MatchesCompleted
                .. " sinceAttack=" .. SinceAttack .. "s"
                .. " GF=" .. GF .. " SS=" .. SS .. " CS=" .. CS)
            -- Dump child counts for all non-trivial workspace folders/models
            local FolderDumps = {}
            local ScanTargets = { "Zombies", "NPCs", "ZombieData", "Zones", "Platforms" }
            for _, FName in ipairs(ScanTargets) do
                local F = workspace:FindFirstChild(FName)
                if F then
                    local Count = 0
                    local Sample = {}
                    for _, C in ipairs(F:GetChildren()) do
                        Count = Count + 1
                        if #Sample < 4 then table.insert(Sample, C.ClassName .. ":" .. C.Name) end
                    end
                    if Count > 0 then
                        table.insert(FolderDumps, FName .. "=" .. Count .. "[" .. table.concat(Sample, ",") .. "]")
                    end
                end
            end
            -- Also count models directly in workspace (like "marine zombie:Model")
            local TopModels = {}
            for _, C in ipairs(workspace:GetChildren()) do
                if C:IsA("Model") and C.Name ~= "Map" then
                    local Sub = 0
                    for _ in ipairs(C:GetChildren()) do Sub = Sub + 1 end
                    table.insert(TopModels, C.Name .. "(" .. Sub .. ")")
                end
            end

            print("[Heartbeat] locations=[" .. table.concat(Locations, ",") .. "]"
                .. " tags=[" .. table.concat(TagCounts, ",") .. "]"
                .. " zombiesFolder=[" .. ZombiesFolderDump .. "]")
            if #FolderDumps > 0 or #TopModels > 0 then
                print("[Heartbeat] folders=[" .. table.concat(FolderDumps, " | ") .. "]"
                    .. " topModels=[" .. table.concat(TopModels, ",") .. "]")
            end
            print("[Heartbeat] workspace=[" .. table.concat(AllChildren, ",") .. "]")

            -- Escalated alarm: if we've gone >2 min with no attack AND zombies are visible, webhook it
            if SinceAttack > 120 and InFolder > 0 and Running
                and (tick() - LastStuckAlarm) > 300 then
                LastStuckAlarm = tick()
                SendWebhook("Script Stalled", {
                    { name = "SinceAttack", value = SinceAttack .. "s", inline = true },
                    { name = "Cached",      value = tostring(Z),        inline = true },
                    { name = "Folder",      value = tostring(InFolder), inline = true },
                    { name = "GameFinished",     value = GF, inline = true },
                    { name = "SwitchingSection", value = SS, inline = true },
                    { name = "Cutscene",         value = CS, inline = true },
                    { name = "CurrentTarget",
                      value = (CurrentTarget and CurrentTarget.Parent) and CurrentTarget.Name or "(none)",
                      inline = false },
                }, 15158332)
            end
        end)
    end
end)

-- Webhook (forward-declared at top so heartbeat can call it)
SendWebhook = function(Title, Fields, Color)
    pcall(function()
        local Body = HttpService:JSONEncode({
            username = "StoryFarm",
            embeds = {{
                title = Title,
                color = Color or 3066993,
                fields = Fields
            }}
        })
        local RequestFunc = (syn and syn.request) or request or http_request
        RequestFunc({
            Url = WEBHOOK,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = Body
        })
    end)
end

local function SendError(Label, Err, Trace)
    local Msg = "[StoryFarm] ERROR in " .. Label .. ": " .. tostring(Err)
    print(Msg)
    if Trace then print(Trace) end
    SendWebhook("Error: " .. Label, {
        { name = "Details", value = "```" .. tostring(Err) .. "```", inline = false },
        { name = "Trace",   value = "```" .. tostring(Trace or "no trace"):sub(1, 1000) .. "```", inline = false },
    }, 15158332)
end

-- xpcall handler captures stack trace at the point of the error (vs pcall which doesn't)
local function TraceHandler(Err)
    return tostring(Err), debug.traceback(nil, 2)
end

local function Safe(Label, Fn, ...)
    local Args = { ... }
    local ok, errOrResult, trace = xpcall(function()
        return Fn(table.unpack(Args))
    end, function(Err)
        return tostring(Err) .. "\n" .. debug.traceback("", 2)
    end)
    if not ok then
        SendError(Label, errOrResult, nil)
    end
    return ok, errOrResult
end

-- Wrap any function so it self-reports errors when called as a callback
local function SafeWrap(Label, Fn)
    return function(...)
        local args = { ... }
        local ok, err = xpcall(function() return Fn(table.unpack(args)) end, function(e)
            return tostring(e) .. "\n" .. debug.traceback("", 2)
        end)
        if not ok then SendError(Label, err, nil) end
    end
end

-- Global uncaught-error catcher: anything that escapes our Safe wrappers (Connect callbacks
-- registered outside Safe, errors in deeply nested coroutines) lands here and gets webhooked.
do
    local LastReported = 0
    local function OnGlobalError(Msg, Trace, _Script)
        -- Throttle to one webhook per 2s so a tight error loop can't flood Discord
        if tick() - LastReported < 2 then return end
        LastReported = tick()
        SendError("UncaughtScriptError", Msg, Trace)
    end
    pcall(function()
        game:GetService("ScriptContext").Error:Connect(OnGlobalError)
    end)
    -- Roblox loadstring'd scripts may not get ScriptContext events; LogService is a fallback
    pcall(function()
        game:GetService("LogService").MessageOut:Connect(function(Msg, Type)
            if Type == Enum.MessageType.MessageError then
                if tick() - LastReported < 2 then return end
                LastReported = tick()
                SendError("LogServiceError", Msg, nil)
            end
        end)
    end)
end

-- Startup ping so we can confirm error pipeline is alive
task.spawn(function()
    pcall(function()
        SendWebhook("StoryFarm Started", {
            { name = "Time",     value = os.date("%Y-%m-%d %H:%M:%S"), inline = true },
            { name = "PlaceId",  value = tostring(game.PlaceId),       inline = true },
        }, 3447003)
    end)
end)

-- PgDn toggle
UserInputService.InputBegan:Connect(function(Input, GameProcessed)
    if GameProcessed then return end
    if Input.KeyCode == Enum.KeyCode.PageDown then
        Running = not Running
        print("[StoryFarm] " .. (Running and "Enabled" or "Disabled"))
    end
end)

-- Character validity
local function IsCharValid()
    return Character and Character.Parent
        and Humanoid and Humanoid.Parent and Humanoid.Health > 0
        and HRP and HRP.Parent
end

-- Game's ActionCheck mirror - returns true if we CAN'T act
local function IsActionBlocked()
    if not IsCharValid() then return true end
    for _, Name in ipairs(BLOCKING_STATES) do
        if Character:FindFirstChild(Name) then return true end
    end
    if workspace:FindFirstChild("Cutscene") then return true end
    if workspace:FindFirstChild("GameFinished") then return true end
    return false
end

-- Read our current-match stats from workspace.MatchConfig.PlayersStats (JSON StringValue).
-- Per _LocalFX.lua:16002 the value is HttpService:JSONDecode'd; entries look like
-- { Kills = N, DamageDealt = N, Drops = {...} }
local function GetMatchStats()
    local MatchConfig = workspace:FindFirstChild("MatchConfig")
    if not MatchConfig then return nil end
    local PlayersStats = MatchConfig:FindFirstChild("PlayersStats")
    if not PlayersStats then return nil end

    local ok, Decoded = pcall(HttpService.JSONDecode, HttpService, PlayersStats.Value)
    if not ok or type(Decoded) ~= "table" then return nil end
    return Decoded[LocalPlayer.Name]
end

local function GetData()
    local Data = LocalPlayer:FindFirstChild("Data")
    if not Data then return nil end
    local Level = Data:FindFirstChild("BattlepassLevel")
    local Rebirths = Data:FindFirstChild("Rebirths")
    local Coins = Data:FindFirstChild("Coins")
    if not Level or not Rebirths or not Coins then return nil end
    return { Level = Level.Value, Rebirths = Rebirths.Value, Coins = Coins.Value }
end

local function CanRebirth()
    local Data = GetData()
    if not Data then return false end
    if Data.Rebirths >= 5 then return false end
    local Step = REBIRTH_STEPS[Data.Rebirths + 1]
    if not Step then return false end
    return Data.Level >= Step.RequiredLevel and Data.Coins >= Step.CoinsRequired
end

local function GetInteract()
    local Assets = ReplicatedStorage:FindFirstChild("Assets")
    if not Assets then return nil end
    local Remotes = Assets:FindFirstChild("Remotes")
    if not Remotes then return nil end
    return Remotes:FindFirstChild("Interact")
end

local function GetAbilityInfo()
    local Data = LocalPlayer:FindFirstChild("Data")
    if not Data then return nil, nil end
    local AbilitySlots = Data:FindFirstChild("AbilitySlots")
    if not AbilitySlots then return nil, nil end
    local ok, Decoded = pcall(HttpService.JSONDecode, HttpService, AbilitySlots.Value)
    if not ok or not Decoded then return nil, nil end
    for SlotName, SlotData in pairs(Decoded) do
        if SlotData and SlotData.Showcasing then
            return SlotName, SlotData.Name
        end
    end
    return nil, nil
end

-- Generic unregister - removes from whichever cache holds it
local function Unregister(Cache, Model)
    local Entry = Cache[Model]
    if not Entry then return end
    for _, Conn in ipairs(Entry.Conns) do
        pcall(function() Conn:Disconnect() end)
    end
    Cache[Model] = nil
end

local function UnregisterZombie(Model) Unregister(AliveZombies, Model) end
local function UnregisterBoss(Model) Unregister(AliveBosses, Model) end

-- Generic register - works for both zombies (in workspace.Zombies) and bosses (CollectionService tagged)
local function ResolveRoot(Model)
    return Model:FindFirstChild("HumanoidRootPart")
        or Model.PrimaryPart
        or Model:FindFirstChild("Torso")
        or Model:FindFirstChild("UpperTorso")
        or Model:FindFirstChild("Head")
        or Model:FindFirstChildWhichIsA("BasePart")
end

-- Find a Health value anywhere in the model. Most zombies use Config.Health (IntValue/NumberValue).
-- Bosses (e.g. "Upper Moon 3") have different layouts — check Model.Health, Configuration children,
-- and Humanoid.Health as fallbacks.
local function ResolveHealth(Model)
    local Config = Model:FindFirstChild("Config")
    if Config then
        local H = Config:FindFirstChild("Health")
        if H and (H:IsA("IntValue") or H:IsA("NumberValue")) then return H, "Config.Health" end
    end

    local Direct = Model:FindFirstChild("Health")
    if Direct and (Direct:IsA("IntValue") or Direct:IsA("NumberValue")) then return Direct, "Health" end

    -- Search shallow descendants for any IntValue/NumberValue named Health
    for _, Child in ipairs(Model:GetDescendants()) do
        if (Child:IsA("IntValue") or Child:IsA("NumberValue")) and Child.Name == "Health" then
            return Child, Child:GetFullName()
        end
    end

    -- Fall back to Humanoid.Health (standard Roblox)
    local Hum = Model:FindFirstChildOfClass("Humanoid")
    if Hum then return Hum, "Humanoid.Health" end

    return nil
end

-- Models we've tried to register and failed on — don't re-spam every rescan tick.
-- Stores tick() at failure. Retry after FAILED_REGISTER_TTL so we recover from
-- transient registration races (zombie spawned but Config.Health not populated yet).
local FailedRegister = setmetatable({}, { __mode = "k" })
local FAILED_REGISTER_TTL = 30
-- Models currently being processed (15s health wait in flight) — dedup concurrent attempts.
local RegisterInProgress = setmetatable({}, { __mode = "k" })

local function Register(Cache, Model, OnDeath)
    if not Model:IsA("Model") then return end
    if Cache[Model] then return end
    if FailedRegister[Model] and tick() - FailedRegister[Model] < FAILED_REGISTER_TTL then return end
    if RegisterInProgress[Model] then return end -- another rescan tick is already trying

    -- Boss tag check (called repeatedly inside the retry loop since the server tags bosses a few seconds after parenting)
    local function IsTaggedBoss()
        if Cache ~= AliveZombies then return false end
        if AliveBosses[Model] then return true end
        if CollectionService:HasTag(Model, "RaidBoss") then return true end
        if CollectionService:HasTag(Model, "Boss") and Model:GetAttribute("IsRaidBoss") then return true end
        return false
    end

    if IsTaggedBoss() then return end

    RegisterInProgress[Model] = true
    task.spawn(function()
        Safe("Register", function()
            -- Wait up to 15s for descendants to populate (game's own UI uses 10s; we go a bit higher).
            -- Re-check boss tags every poll cycle so we bail the moment the server tags this as a boss.
            local Health, HealthPath = ResolveHealth(Model)
            if not Health then
                local Deadline = tick() + 15
                while not Health and tick() < Deadline and Model.Parent do
                    if IsTaggedBoss() then return end -- boss tracker will take it from here
                    task.wait(0.1)
                    Health, HealthPath = ResolveHealth(Model)
                end
            end

            if not Health then
                FailedRegister[Model] = tick()
                -- Silence the log if the model is gone (server briefly spawned/removed it) or it's now tagged as boss
                if Model.Parent and not IsTaggedBoss() then
                    print("[StoryFarm] Register: no Health on " .. Model.Name .. " (blacklisted)")
                end
                return
            end

            local Root = ResolveRoot(Model)
            if not Root then
                local Deadline = tick() + 5
                while not Root and tick() < Deadline and Model.Parent do
                    task.wait(0.05)
                    Root = ResolveRoot(Model)
                end
                if not Root then
                    print("[StoryFarm] Register: no root part on " .. Model.Name)
                    return
                end
            end

            -- Critical: game uses INVERTED health semantics for zombies.
            -- _LocalFX.lua:16505 destroys/death-SFXes when Config.Health.Value > 0,
            -- so Health.Value <= 0 = ALIVE, > 0 = DEAD. Humanoid (standard) is normal.
            local Conns = {}
            local IsHumanoid = Health:IsA("Humanoid")
            local IsAlive, GetHealth
            if IsHumanoid then
                IsAlive   = function() return Health.Health > 0 end
                GetHealth = function() return Health.Health end
            else
                IsAlive   = function() return Health.Value <= 0 end
                GetHealth = function() return Health.Value end
            end

            if IsHumanoid then
                table.insert(Conns, Health.HealthChanged:Connect(function(NewHP)
                    if NewHP <= 0 then OnDeath(Model) end
                end))
            else
                table.insert(Conns, Health:GetPropertyChangedSignal("Value"):Connect(function()
                    if Health.Value > 0 then OnDeath(Model) end -- inverted
                end))
            end

            table.insert(Conns, Model:GetAttributeChangedSignal("Died"):Connect(function()
                if Model:GetAttribute("Died") then OnDeath(Model) end
            end))

            table.insert(Conns, Model.ChildRemoved:Connect(function(Child)
                if Child == Root then OnDeath(Model) end
            end))

            table.insert(Conns, Model.AncestryChanged:Connect(function()
                if not Model.Parent then OnDeath(Model) end
            end))

            Cache[Model] = { Model = Model, Root = Root, Health = Health, GetHealth = GetHealth, IsAlive = IsAlive, Conns = Conns }
        end)
        RegisterInProgress[Model] = nil
    end)
end

-- Liveness check. Health semantics vary per enemy type (Phantom/Samurai alive at negative HP,
-- Titan alive at positive HP), so we can't gate on the value. Rely on physical/attribute state +
-- StaleTargets blacklist (populated when HP never moves across multiple attacks).
local StaleTargets = setmetatable({}, { __mode = "k" })
local StaleHits    = setmetatable({}, { __mode = "k" })
local function IsZombieDataLive(Data)
    if not Data or not Data.Model then return false end
    if not Data.Model.Parent then return false end
    if Data.Model:GetAttribute("Died") then return false end
    if StaleTargets[Data.Model] then return false end

    -- Cached Root can go orphaned when HRP gets replaced on respawn — re-resolve from Model.
    if not Data.Root or not Data.Root.Parent then
        local Fresh = ResolveRoot(Data.Model)
        if not Fresh then return false end
        Data.Root = Fresh
    end

    return true
end

-- Bootstrap zombies (survives Zombies folder being destroyed/replaced between matches)
local ZombieFolderConns = {}
local CurrentZombieFolder = nil

-- Quick check: does this model look like a zombie (has Config.Health)?
-- Forward-declared at the top of the file so earlier closures (heartbeat) resolve it.
LooksLikeZombie = function(Inst)
    if not Inst:IsA("Model") then return false end
    if Players:GetPlayerFromCharacter(Inst) then return false end
    -- Belt-and-braces: name match against any current player (covers race condition where
    -- Character is parented before Player.Character property is set).
    for _, Plr in ipairs(Players:GetPlayers()) do
        if Inst.Name == Plr.Name then return false end
    end
    if CollectionService:HasTag(Inst, "RaidBoss") then return false end
    if CollectionService:HasTag(Inst, "Boss") and Inst:GetAttribute("IsRaidBoss") then return false end
    local Pets  = workspace:FindFirstChild("Pets")
    local Alive = workspace:FindFirstChild("Alive")
    if Pets  and Inst:IsDescendantOf(Pets)  then return false end
    if Alive and Inst:IsDescendantOf(Alive) then return false end

    local Config = Inst:FindFirstChild("Config")
    if Config and Config:FindFirstChild("Health") then return true end
    -- Fallback: section variants without Config.Health but with a Humanoid + HRP still kill-able
    if Inst:FindFirstChildOfClass("Humanoid") and Inst:FindFirstChild("HumanoidRootPart") then
        return true
    end
    return false
end

local function AttachZombieFolder(Folder)
    if CurrentZombieFolder == Folder then return end

    for _, Conn in ipairs(ZombieFolderConns) do
        pcall(function() Conn:Disconnect() end)
    end
    ZombieFolderConns = {}
    CurrentZombieFolder = Folder

    -- workspace.Zombies is a Model. Zombies can be direct children OR nested in sub-models.
    -- Use GetDescendants + LooksLikeZombie filter to catch them at any depth.
    for _, Desc in ipairs(Folder:GetDescendants()) do
        if LooksLikeZombie(Desc) then
            Register(AliveZombies, Desc, UnregisterZombie)
        end
    end

    table.insert(ZombieFolderConns, Folder.DescendantAdded:Connect(function(Desc)
        if LooksLikeZombie(Desc) then
            Register(AliveZombies, Desc, UnregisterZombie)
        end
    end))
    table.insert(ZombieFolderConns, Folder.DescendantRemoving:Connect(function(Desc)
        if AliveZombies[Desc] then UnregisterZombie(Desc) end
    end))
    table.insert(ZombieFolderConns, Folder.AncestryChanged:Connect(function()
        if not Folder.Parent then CurrentZombieFolder = nil end
    end))

    print("[StoryFarm] Attached to Zombies (Model). Initial descendants: " .. #Folder:GetDescendants())
end

-- Workspace-wide watcher: catches zombies parented to ANYWHERE in workspace, not just workspace.Zombies.
-- This is the safety net when sections reparent zombies to a different folder.
task.spawn(function()
    Safe("WorkspaceWideZombieWatcher", function()
        local function Try(Inst)
            if LooksLikeZombie(Inst) and not AliveZombies[Inst] then
                Register(AliveZombies, Inst, UnregisterZombie)
            end
        end

        for _, Inst in ipairs(workspace:GetDescendants()) do Try(Inst) end
        workspace.DescendantAdded:Connect(Try)

        print("[StoryFarm] Workspace-wide zombie watcher armed")
    end)
end)

task.spawn(function()
    Safe("ZombieBootstrap", function()
        local Existing = workspace:FindFirstChild("Zombies")
        if Existing then AttachZombieFolder(Existing) end

        workspace.ChildAdded:Connect(function(Child)
            if Child.Name == "Zombies" then AttachZombieFolder(Child) end
        end)

        -- Aggressive periodic rescan + hard-reset if stuck
        local StuckSince = nil
        while true do
            task.wait(1.5)
            local Folder = workspace:FindFirstChild("Zombies")
            if Folder and Folder ~= CurrentZombieFolder then
                AttachZombieFolder(Folder)
            end
            if not Folder then continue end

            local InFolder, Tracked = 0, 0
            -- workspace.Zombies is a Model — zombies can be at any descendant depth
            for _, Desc in ipairs(Folder:GetDescendants()) do
                if LooksLikeZombie(Desc) then
                    InFolder = InFolder + 1
                    if not AliveZombies[Desc] then
                        Register(AliveZombies, Desc, UnregisterZombie)
                    end
                end
            end
            for _ in pairs(AliveZombies) do Tracked = Tracked + 1 end

            -- Diagnose: count how many cached entries are passing IsZombieDataLive
            local LiveTracked = 0
            for _, Data in pairs(AliveZombies) do
                if IsZombieDataLive(Data) then LiveTracked = LiveTracked + 1 end
            end

            -- Count Humanoid-bearing models anywhere in workspace (excl. players/pets/alive)
            -- so we can detect "stuck with 0 tracked" even when zombies aren't in workspace.Zombies.
            local PetsF  = workspace:FindFirstChild("Pets")
            local AliveF = workspace:FindFirstChild("Alive")
            local InWorld = 0
            for _, Inst in ipairs(workspace:GetDescendants()) do
                if Inst:IsA("Model")
                    and Inst:FindFirstChildOfClass("Humanoid")
                    and not Players:GetPlayerFromCharacter(Inst)
                    and not (PetsF  and Inst:IsDescendantOf(PetsF))
                    and not (AliveF and Inst:IsDescendantOf(AliveF))
                then
                    local IsPlayer = false
                    for _, Plr in ipairs(Players:GetPlayers()) do
                        if Inst.Name == Plr.Name then IsPlayer = true break end
                    end
                    if not IsPlayer then InWorld = InWorld + 1 end
                end
            end

            -- Hard-reset: if anything kill-able exists in world but we can't track any live ones for 10s+, dump + wipe
            if (InFolder > 0 or InWorld > 0) and LiveTracked == 0 then
                StuckSince = StuckSince or tick()
                local StuckFor = math.floor(tick() - StuckSince)
                print("[StoryFarm] Stuck: " .. InFolder .. " in folder, " .. Tracked
                    .. " cached, " .. LiveTracked .. " live (" .. StuckFor .. "s)")

                -- Sample the first zombie so we can see what's wrong
                local First = Folder:FindFirstChildOfClass("Model")
                local CfgStr, HpStr, RootStr, DiedStr, ChildList = "?", "?", "?", "?", "?"
                if First then
                    local Config = First:FindFirstChild("Config")
                    local Health = Config and Config:FindFirstChild("Health")
                    local Root = ResolveRoot(First)
                    CfgStr  = tostring(Config ~= nil)
                    HpStr   = Health and tostring(Health.Value) or "nil"
                    RootStr = Root and Root.Name or "nil"
                    DiedStr = tostring(First:GetAttribute("Died"))

                    -- List first-level children so we can see actual model structure
                    local Names = {}
                    for _, C in ipairs(First:GetChildren()) do
                        table.insert(Names, C.ClassName .. ":" .. C.Name)
                        if #Names >= 8 then break end
                    end
                    ChildList = table.concat(Names, ", ")
                end

                -- Throttle webhook to once per 30s when stuck so we don't flood
                if StuckFor % 30 == 0 then
                    -- Discovery: scan workspace for ANY Model with a Humanoid (excluding players/pets/alive)
                    -- and report parent path so we can see where section variants actually live.
                    local Found, FoundCount = {}, 0
                    local PetsF  = workspace:FindFirstChild("Pets")
                    local AliveF = workspace:FindFirstChild("Alive")
                    for _, Inst in ipairs(workspace:GetDescendants()) do
                        if FoundCount >= 12 then break end
                        if Inst:IsA("Model")
                            and Inst:FindFirstChildOfClass("Humanoid")
                            and not Players:GetPlayerFromCharacter(Inst)
                            and not (PetsF  and Inst:IsDescendantOf(PetsF))
                            and not (AliveF and Inst:IsDescendantOf(AliveF))
                        then
                            local ParentPath = Inst.Parent and Inst.Parent:GetFullName() or "?"
                            FoundCount = FoundCount + 1
                            table.insert(Found, Inst.Name .. " <- " .. ParentPath)
                        end
                    end
                    local Discovery = #Found > 0 and table.concat(Found, "\n") or "(none with Humanoid)"

                    SendWebhook("Tracker Stuck", {
                        { name = "Folder",   value = tostring(InFolder),    inline = true },
                        { name = "InWorld",  value = tostring(InWorld),     inline = true },
                        { name = "Cached",   value = tostring(Tracked),     inline = true },
                        { name = "Live",     value = tostring(LiveTracked), inline = true },
                        { name = "StuckFor", value = StuckFor .. "s",       inline = true },
                        { name = "Sample",   value = First and First.Name or "(none)", inline = false },
                        { name = "Config",   value = CfgStr,  inline = true },
                        { name = "Health",   value = HpStr,   inline = true },
                        { name = "Root",     value = RootStr, inline = true },
                        { name = "Died",     value = DiedStr, inline = true },
                        { name = "Children", value = "```" .. ChildList .. "```", inline = false },
                        { name = "Discovery (Models w/ Humanoid)", value = "```" .. Discovery .. "```", inline = false },
                    }, 15158332)
                end

                if tick() - StuckSince >= 10 then
                    print("[StoryFarm] HARD RESET zombie tracker (clearing blacklists too)")
                    for _, Conn in ipairs(ZombieFolderConns) do
                        pcall(function() Conn:Disconnect() end)
                    end
                    ZombieFolderConns = {}
                    for Model, Entry in pairs(AliveZombies) do
                        for _, Conn in ipairs(Entry.Conns) do
                            pcall(function() Conn:Disconnect() end)
                        end
                        AliveZombies[Model] = nil
                    end
                    -- Wipe blacklists too: a hard reset that doesn't clear FailedRegister
                    -- just slams into the same wall it was supposed to break.
                    for Model in pairs(FailedRegister) do FailedRegister[Model] = nil end
                    for Model in pairs(StaleTargets)   do StaleTargets[Model]   = nil end
                    for Model in pairs(StaleHits)      do StaleHits[Model]      = nil end
                    CurrentZombieFolder = nil
                    AttachZombieFolder(Folder)
                    StuckSince = nil
                end
            else
                StuckSince = nil
            end
        end
    end)
end)

-- Boss tracker disabled - bosses (Yuji, Upper Moon 3, Akaza) caused instability.
-- AliveBosses stays empty so all iterations over it are no-ops. The tag-skip in
-- Register() still rejects tagged bosses from the zombie tracker, so they're just ignored.
print("[StoryFarm] Boss tracker disabled")

-- Scan a cache for the nearest valid target
-- IgnoreCooldown=true forces selection even from recently-attacked (used as fallback when nothing else available)
local function ScanCache(Cache, Unregister, IgnoreCooldown)
    local Best, BestDist = nil, math.huge
    local Now = tick()

    for Model, Data in pairs(Cache) do
        if not Model.Parent then Unregister(Model) continue end
        if not Data.Root or not Data.Root.Parent then Unregister(Model) continue end
        if Model:GetAttribute("Died") then Unregister(Model) continue end
        -- NOTE: Frozen attribute removed — game's own attacks still hit Frozen zombies.
        if not IgnoreCooldown and RecentlyAttacked[Model] and RecentlyAttacked[Model] > Now then continue end

        local Dx = Data.Root.Position.X - HRP.Position.X
        local Dz = Data.Root.Position.Z - HRP.Position.Z
        local Dist = math.sqrt(Dx * Dx + Dz * Dz)
        if Dist > MAX_ZOMBIE_RANGE then continue end

        if Dist < BestDist then
            Best = Model
            BestDist = Dist
        end
    end

    return Best
end

-- Boss first, then zombies. If nothing passes cooldown, retry ignoring cooldown so we don't stall on the last enemy
local function PickNearestZombie()
    if not IsCharValid() then return nil end

    local Boss = ScanCache(AliveBosses, UnregisterBoss, false)
    if Boss then return Boss, true end

    local Z = ScanCache(AliveZombies, UnregisterZombie, false)
    if Z then return Z, false end

    -- Fallback: nothing passed the cooldown - try again ignoring it
    Boss = ScanCache(AliveBosses, UnregisterBoss, true)
    if Boss then return Boss, true end

    return ScanCache(AliveZombies, UnregisterZombie, true), false
end

-- Lookup entry from either cache
local function GetTargetEntry(Model)
    return AliveBosses[Model] or AliveZombies[Model]
end

local function IsZombieStillAlive(Model)
    if not Model then return false end
    local Data = GetTargetEntry(Model)
    if not Data then return false end
    return IsZombieDataLive(Data)
end

-- Movement
local function GoUnderground()
    if not IsCharValid() then return end
    HRP.CFrame = CFrame.new(HRP.Position.X, HRP.Position.Y - UNDERGROUND_Y, HRP.Position.Z)
    HRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
end

-- Cached raycast params so we don't build a new one each tick
local UnderRaycastParams = RaycastParams.new()
UnderRaycastParams.FilterType = Enum.RaycastFilterType.Exclude

local function RefreshRaycastFilter()
    local Filter = {}
    if Character then table.insert(Filter, Character) end
    -- Alive = players, Zombies/Thrown = enemies & projectiles, Pets/PET_ANCHORS = our pet system
    -- (paths per PetClient.lua:14 + :47-49). Filtering pets out so they can't break our floor cast.
    for _, Name in ipairs({ "Alive", "Zombies", "Thrown", "Pets", "PET_ANCHORS" }) do
        local F = workspace:FindFirstChild(Name)
        if F then table.insert(Filter, F) end
    end
    UnderRaycastParams.FilterDescendantsInstances = Filter
end

-- Pick the LOWEST-Y live zombie/boss as our underground anchor.
-- Picking the lowest one ensures we end up beneath actual ground geometry, not
-- suspended mid-air below a zombie spawning from above (the section 6 spawn room
-- problem where ground zombies could still hit us).
local function GoUnderZombie()
    if not IsCharValid() then return false end

    local BestRoot, BestY = nil, math.huge
    for _, Cache in ipairs({ AliveBosses, AliveZombies }) do
        for _, Data in pairs(Cache) do
            if IsZombieDataLive(Data) then
                local Y = Data.Root.Position.Y
                if Y < BestY then
                    BestRoot, BestY = Data.Root, Y
                end
            end
        end
    end

    if not BestRoot then
        GoUnderground()
        return false
    end

    local Pos = BestRoot.Position

    -- Raycast straight down (filtering out alive entities) to find real ground.
    -- Then go UNDERGROUND_Y below ground level, not just below the zombie.
    RefreshRaycastFilter()
    local Hit = workspace:Raycast(Pos + Vector3.new(0, 50, 0), Vector3.new(0, -2000, 0), UnderRaycastParams)
    local TargetY
    if Hit then
        TargetY = Hit.Position.Y - UNDERGROUND_Y
    else
        TargetY = Pos.Y - UNDERGROUND_Y -- fallback: zombie-relative
    end

    HRP.CFrame = CFrame.new(Pos.X, TargetY, Pos.Z)
    HRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
    return true
end

local function GoToZombie(Root)
    if not IsCharValid() then return end
    if not Root or not Root.Parent then return end
    HRP.CFrame = CFrame.new(Root.Position + Vector3.new(0, ATTACK_HEIGHT, 0))
end

-- Noclip
RunService.Stepped:Connect(function()
    if not Running then return end
    if not Character or not Character.Parent then return end
    Safe("Noclip", function()
        for _, Part in ipairs(Character:GetDescendants()) do
            if Part:IsA("BasePart") then
                Part.CanCollide = false
            end
        end
    end)
end)

-- Watchdog + cleanup
task.spawn(function()
    while true do
        task.wait(1)
        local Now = tick()

        for Model, Expiry in pairs(RecentlyAttacked) do
            if not Model.Parent or Expiry < Now then
                RecentlyAttacked[Model] = nil
            end
        end

        if Attacking and (Now - AttackStartTime) > ATTACK_TIMEOUT then
            print("[StoryFarm] Stuck for " .. math.floor(Now - AttackStartTime) .. "s, force release")
            Attacking = false
            Safe("WatchdogUnstick", GoUnderground)
        end
    end
end)

-- Authoritative per-slot cooldown from server (already accounts for CD reduction cosmetics)
task.spawn(function()
    Safe("CooldownHook", function()
        local Assets = ReplicatedStorage:WaitForChild("Assets", 30)
        local Remotes = Assets:WaitForChild("Remotes", 30)
        local UsedAbility = Remotes:WaitForChild("UsedAbility", 30)

        UsedAbility.OnClientEvent:Connect(function(_, Duration, _AbilityName, KeyIndex)
            if type(Duration) ~= "number" then return end
            if type(KeyIndex) ~= "number" or KeyIndex < 1 or KeyIndex > 4 then return end
            SlotCooldownEnd[KeyIndex] = tick() + Duration
        end)

        print("[StoryFarm] Cooldown hook armed")
    end)
end)

local function PickReadySlot()
    local Now = tick()
    for i = 1, 3 do -- skip V (slot 4)
        if SlotCooldownEnd[i] <= Now then return i end
    end
    return nil
end

local function AnySlotReady()
    local Now = tick()
    for i = 1, 3 do
        if SlotCooldownEnd[i] <= Now then return true end
    end
    return false
end

-- Pick a TP center that maximizes zombies inside AOE_RADIUS
local function PickAttackCenter(Target)
    local TargetData = GetTargetEntry(Target)
    if not IsZombieDataLive(TargetData) then return nil, 0 end

    local Best = TargetData.Root.Position
    local BestCount = 1
    local Search = (AOE_RADIUS * 2) * (AOE_RADIUS * 2)

    local Candidates = { Best }
    for _, Data in pairs(AliveZombies) do
        if IsZombieDataLive(Data) then
            local Pos = Data.Root.Position
            local Dx = Pos.X - Best.X
            local Dz = Pos.Z - Best.Z
            if (Dx * Dx + Dz * Dz) < Search then
                table.insert(Candidates, Pos)
            end
        end
    end

    local Radius2 = AOE_RADIUS * AOE_RADIUS
    for _, Center in ipairs(Candidates) do
        local Count = 0
        for _, Data in pairs(AliveZombies) do
            if IsZombieDataLive(Data) then
                local Pos = Data.Root.Position
                local Dx = Pos.X - Center.X
                local Dz = Pos.Z - Center.Z
                if (Dx * Dx + Dz * Dz) <= Radius2 then
                    Count = Count + 1
                end
            end
        end
        if Count > BestCount then
            BestCount = Count
            Best = Center
        end
    end

    return Best, BestCount
end

-- Main attack loop
task.spawn(function()
    while true do
        task.wait(0.05)
        if not Running then continue end
        if Attacking then continue end
        if not IsCharValid() then task.wait(0.5) continue end

        Safe("AttackLoop", function()
            -- Game finished / cutscene / section transition = wait it out
            if workspace:FindFirstChild("GameFinished")
                or workspace:FindFirstChild("Cutscene")
                or workspace:FindFirstChild("SwitchingSection") then
                GoUnderZombie()
                task.wait(1)
                return
            end

            local Interact = GetInteract()
            if not Interact then return end

            local SlotName, AbilityName = GetAbilityInfo()
            if not SlotName or not AbilityName then task.wait(0.5) return end

            -- Wait underground until abilities are off cooldown / state clears
            if IsActionBlocked() then
                GoUnderZombie()
                task.wait(0.1)
                return
            end
            if not AnySlotReady() then
                GoUnderZombie()
                task.wait(0.1)
                return
            end
            -- Damage lockout: if we recently took a hit, stay underground
            if tick() - LastDamageAt < POST_DAMAGE_LOCKOUT then
                GoUnderZombie()
                task.wait(0.1)
                return
            end

            local Target, IsBoss = PickNearestZombie()
            if not Target then
                GoUnderZombie()
                task.wait(0.3)
                return
            end

            Attacking = true
            AttackStartTime = tick()
            Stats.AttacksAttempted = Stats.AttacksAttempted + 1

            -- Final check before TP
            if not IsZombieStillAlive(Target) then
                Stats.AttacksAborted = Stats.AttacksAborted + 1
                Attacking = false
                return
            end

            local Data = GetTargetEntry(Target)
            local Root = Data and Data.Root
            if not Root or not Root.Parent then
                Stats.AttacksAborted = Stats.AttacksAborted + 1
                Attacking = false
                return
            end

            if IsBoss then print("[StoryFarm] Boss target acquired: " .. Target.Name) end

            CurrentTarget = Target
            CurrentTargetIsBoss = IsBoss
            RecentlyAttacked[Target] = tick() + ATTACK_COOLDOWN_PER_ZOMBIE

            -- Pick the densest cluster around the target so one swing hits the most zombies
            local Center, Hits = PickAttackCenter(Target)
            if not Center then
                Stats.AttacksAborted = Stats.AttacksAborted + 1
                GoUnderground()
                CurrentTarget = nil
                CurrentTargetIsBoss = false
                Attacking = false
                return
            end

            -- Surface AT the cluster center's Y (zombie level, not above them).
            -- This ensures abilities actually reach zombies — purely underground attacks miss.
            HRP.CFrame = CFrame.new(Center.X, Center.Y, Center.Z)
            HRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            task.wait(0.03)

            if not IsZombieStillAlive(Target) and Hits <= 1 then
                Stats.AttacksAborted = Stats.AttacksAborted + 1
                GoUnderground()
                CurrentTarget = nil
                CurrentTargetIsBoss = false
                Attacking = false
                return
            end

            -- Snapshot HP before surfacing. Damage abort is now scaled by MaxHP and gated by
            -- a grace period — chip-damage on the first frame can no longer kill the swing.
            local HPBefore   = Humanoid and Humanoid.Health or 0
            local MaxHP      = (Humanoid and Humanoid.MaxHealth and Humanoid.MaxHealth > 0) and Humanoid.MaxHealth or 100
            local DamageCap  = MaxHP * DAMAGE_ABORT_THRESHOLD
            local GraceEnd   = tick() + DAMAGE_GRACE_PERIOD

            -- Stale-target detection: sample target's Config.Health before the swing.
            -- If it doesn't change after the window, it's a corpse — blacklist after a few tries.
            local TargetData = GetTargetEntry(Target)
            local TargetHPBefore = TargetData and TargetData.GetHealth and TargetData.GetHealth() or nil

            -- Cycle through ready slots (1..3) until window closes or all on CD
            local Deadline = tick() + ATTACK_WINDOW
            local Fired = 0
            while tick() < Deadline do
                if not IsCharValid() then break end

                -- Mid-attack damage abort: only after the grace period, and only on cumulative
                -- damage that exceeds MaxHP * DAMAGE_ABORT_THRESHOLD. The old check bailed on
                -- a single 1-HP chip, leaving Fired=0 and the stale-target detector blind.
                if tick() > GraceEnd then
                    if Humanoid and (HPBefore - Humanoid.Health) >= DamageCap then
                        LastDamageAt = tick()
                        break
                    end
                end

                if IsActionBlocked() then
                    task.wait(0.03)
                    continue
                end

                local Slot = PickReadySlot()
                if not Slot then break end

                Interact:FireServer("Ability", Slot, SlotName, AbilityName, "Began")
                task.wait(0.03)
                Interact:FireServer("Ability", Slot, SlotName, AbilityName, "Released")
                LastAttackAt = tick()

                -- Soft cooldown until server confirms via UsedAbility (prevents same-slot spam if event is late)
                if SlotCooldownEnd[Slot] <= tick() then
                    SlotCooldownEnd[Slot] = tick() + 0.4
                end
                Fired = Fired + 1
                task.wait(0.08)
            end

            -- Stale check: did the target's HP move during the swing window?
            if Fired > 0 and TargetHPBefore and TargetData and TargetData.GetHealth then
                local TargetHPAfter = TargetData.GetHealth()
                if typeof(TargetHPAfter) == "number" and TargetHPAfter == TargetHPBefore then
                    StaleHits[Target] = (StaleHits[Target] or 0) + 1
                    if StaleHits[Target] >= 4 then
                        StaleTargets[Target] = true
                        UnregisterZombie(Target)
                        print("[StoryFarm] Blacklisted stale target: " .. Target.Name .. " (HP " .. tostring(TargetHPAfter) .. " unchanged across 4 swings)")
                    end
                else
                    StaleHits[Target] = nil
                end
            end

            GoUnderZombie() -- back under the next target, not the (now-dead) cluster center
            CurrentTarget = nil
            CurrentTargetIsBoss = false
            task.wait(0.05)
            Attacking = false
        end)
    end
end)

-- Auto rebirth
task.spawn(function()
    while true do
        task.wait(10)
        if not Running then continue end

        Safe("AutoRebirth", function()
            if not CanRebirth() then return end
            local Data = GetData()
            if not Data then return end
            local Interact = GetInteract()
            if not Interact then return end

            print("[StoryFarm] Rebirthing! Rebirths: " .. Data.Rebirths .. " Level: " .. Data.Level)
            Interact:FireServer("Rebirth")
            Stats.Rebirths = Stats.Rebirths + 1

            SendWebhook("Rebirth Performed!", {
                { name = "Rebirths", value = tostring(Data.Rebirths + 1), inline = true },
                { name = "Level",    value = tostring(Data.Level),        inline = true },
                { name = "Coins",    value = tostring(Data.Coins),        inline = true },
            }, 15844367)
        end)
    end
end)

-- End-of-match: triggered when the server creates workspace.GameFinished
-- (Create("GameFinished", "Folder", workspace) at _LocalFX.lua:15994).
-- More reliable than watching UI properties since the folder is server-authoritative.
local LastEndAt = 0
local function HandleMatchEnd()
    if tick() - LastEndAt < 5 then return end -- dedupe rapid double-fires
    LastEndAt = tick()

    Safe("EndScreenFired", function()
        local Data = GetData()
        local Match = GetMatchStats()
        Stats.MatchesCompleted = Stats.MatchesCompleted + 1

        local MatchKills  = (Match and type(Match.Kills)       == "number") and Match.Kills       or 0
        local MatchDamage = (Match and type(Match.DamageDealt) == "number") and Match.DamageDealt or 0
        Stats.TotalKills  = Stats.TotalKills  + MatchKills
        Stats.TotalDamage = Stats.TotalDamage + MatchDamage

        SendWebhook("Match Over", {
            { name = "Coins",       value = Data and tostring(Data.Coins)    or "?", inline = true },
            { name = "Level",       value = Data and tostring(Data.Level)    or "?", inline = true },
            { name = "Rebirths",    value = Data and tostring(Data.Rebirths) or "?", inline = true },
            { name = "Match Kills", value = tostring(MatchKills),                    inline = true },
            { name = "Match Dmg",   value = tostring(MatchDamage),                   inline = true },
            { name = "Total Kills", value = tostring(Stats.TotalKills),              inline = true },
        }, 3066993)

        if not Running then return end

        -- Retry until the server actually accepts PlayAgain. We can't fully tell when the
        -- new match has started, so just keep firing until GameFinished is gone.
        local Deadline = tick() + 20
        while tick() < Deadline do
            if not workspace:FindFirstChild("GameFinished") then break end
            local Interact = GetInteract()
            if Interact then
                Safe("FirePlayAgain", function() Interact:FireServer("PlayAgain") end)
            end
            task.wait(1)
        end
    end)
end

task.spawn(function()
    Safe("EndScreenWatcher", function()
        local Existing = workspace:FindFirstChild("GameFinished")
        if Existing then HandleMatchEnd() end

        workspace.ChildAdded:Connect(function(Child)
            if Child.Name == "GameFinished" then HandleMatchEnd() end
        end)

        print("[StoryFarm] Watching workspace.GameFinished...")
    end)
end)

-- Auto-escape: TP to the Train (Shibuya) or Door (Impel Down) once enemies are clear.
-- Server then fires the Escaped remote (_LocalFX.lua:15892) which teleports us out.
local function GetEscapePart()
    local Map = workspace:FindFirstChild("Map")
    if not Map then return nil end

    -- Shibuya: workspace.Map.Train.Model
    local Train = Map:FindFirstChild("Train")
    if Train then
        local Model = Train:FindFirstChild("Model")
        if Model then
            return Model.PrimaryPart or Model:FindFirstChildWhichIsA("BasePart"), "Train"
        end
    end

    -- Impel Down: workspace.Map.Objective.Entries.Model.Door
    local Objective = Map:FindFirstChild("Objective")
    if Objective then
        local Entries = Objective:FindFirstChild("Entries")
        if Entries then
            local Model = Entries:FindFirstChild("Model")
            if Model then
                local Door = Model:FindFirstChild("Door")
                if Door then
                    if Door:IsA("BasePart") then return Door, "Door" end
                    return Door.PrimaryPart or Door:FindFirstChildWhichIsA("BasePart"), "Door"
                end
            end
        end
    end

    return nil
end

-- Escape ProximityPrompt scanner. Decompile has no ProximityPrompt scripts but the prompt
-- may be authored directly in workspace.Map as a static instance — scan workspace descendants
-- for any ProximityPrompt whose Name/ActionText/ObjectText contains "escape".
local FireProx = fireproximityprompt
    or (syn and syn.fireproximityprompt)
    or (getgenv and getgenv().fireproximityprompt)

local FiredEscapePrompts = setmetatable({}, { __mode = "k" }) -- weak keys so GC'd prompts drop

local function IsEscapePrompt(Prompt)
    if not Prompt:IsA("ProximityPrompt") then return false end
    if not Prompt.Enabled then return false end
    local Combined = string.lower(
        (Prompt.Name       or "") .. " " ..
        (Prompt.ActionText or "") .. " " ..
        (Prompt.ObjectText or "")
    )
    return string.find(Combined, "escape", 1, true) ~= nil
end

-- Walk up the prompt's ancestry to find the first BasePart we can stand on.
local function ResolvePromptPart(Prompt)
    local Node = Prompt.Parent
    while Node and Node ~= workspace do
        if Node:IsA("BasePart") then return Node end
        if Node:IsA("Model") then
            local Pivot = Node.PrimaryPart or Node:FindFirstChildWhichIsA("BasePart")
            if Pivot then return Pivot end
        end
        Node = Node.Parent
    end
    return nil
end

local function FindEscapePrompt()
    -- Per user: prompt lives under workspace.Objectives. Check there first.
    local Objectives = workspace:FindFirstChild("Objectives")
    if Objectives then
        for _, Inst in ipairs(Objectives:GetDescendants()) do
            if IsEscapePrompt(Inst) then return Inst end
        end
    end
    -- Fallback to full workspace scan
    for _, Inst in ipairs(workspace:GetDescendants()) do
        if IsEscapePrompt(Inst) then return Inst end
    end
    return nil
end

-- Spam-TP to the prompt's parent part and fire the prompt every tick while one exists.
-- Potassium's fireproximityprompt takes ONE arg (the prompt) and bypasses distance,
-- but TPing on top of it is harmless and protects against server-side distance checks.
task.spawn(function()
    Safe("EscapePromptSpammer", function()
        while true do
            task.wait(0.1)
            if not Running then continue end
            if not IsCharValid() then continue end

            local Prompt = FindEscapePrompt()
            if not Prompt then continue end

            local Part = ResolvePromptPart(Prompt)
            if Part then
                HRP.CFrame = Part.CFrame + Vector3.new(0, 3, 0)
                HRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            end

            if FireProx then
                Safe("FireProx", function() FireProx(Prompt) end)
            end

            if not FiredEscapePrompts[Prompt] then
                FiredEscapePrompts[Prompt] = tick()
                print("[StoryFarm] Escape prompt: " .. Prompt:GetFullName()
                    .. " | action='" .. (Prompt.ActionText or "")
                    .. "' object='" .. (Prompt.ObjectText or "") .. "'"
                    .. " | tp=" .. (Part and Part:GetFullName() or "(no part)"))
            end
        end
    end)
end)

-- Objective gate: only escape when workspace.Objectives has a visible child
-- whose Name starts with "Escape" (e.g. "Escape Shibuya!", "Escape Impel Down!").
-- Per ObjectivesPanel.lua:50 the objective name IS the displayed text.
local function HasEscapeObjective()
    local Folder = workspace:FindFirstChild("Objectives")
    if not Folder then return false end
    for _, Obj in ipairs(Folder:GetChildren()) do
        if not Obj:GetAttribute("Hidden") then
            if string.sub(Obj.Name, 1, 6):lower() == "escape" then
                return true, Obj.Name
            end
        end
    end
    return false
end

task.spawn(function()
    while true do
        task.wait(1)
        if not Running then continue end
        if workspace:FindFirstChild("GameFinished") then continue end
        if workspace:FindFirstChild("Cutscene") then continue end
        if not IsCharValid() then continue end

        local Active, ObjName = HasEscapeObjective()
        if not Active then continue end

        Safe("AutoEscape", function()
            local Part, Kind = GetEscapePart()
            if not Part then return end

            print("[StoryFarm] Objective '" .. ObjName .. "' active, TPing to " .. Kind)
            HRP.CFrame = Part.CFrame + Vector3.new(0, 3, 0)
            HRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
        end)
    end
end)

-- Auto-revive (Ultra Instinct / standard revive). Server sets CanRevive=true on Character;
-- fire Interact:FireServer("Revive") to consume it. Matches ClientUI.lua:1330 and CharacterHandler/Client.lua:1756.
local ReviveAttrConn = nil
local function HookReviveListener(Char)
    if ReviveAttrConn then
        pcall(function() ReviveAttrConn:Disconnect() end)
        ReviveAttrConn = nil
    end
    if not Char then return end

    local function TryRevive()
        if not Running then return end
        if not Char or not Char.Parent then return end
        if not Char:GetAttribute("CanRevive") then return end
        Safe("AutoRevive", function()
            local Interact = GetInteract()
            if not Interact then return end
            print("[StoryFarm] CanRevive=true, firing Revive")
            Interact:FireServer("Revive")
        end)
    end

    ReviveAttrConn = Char:GetAttributeChangedSignal("CanRevive"):Connect(TryRevive)
    TryRevive() -- in case it's already true at hook time
end

-- Auto start raid
task.spawn(function()
    Safe("StartWatcher", function()
        local function FireStart()
            if not Running then return end
            if not workspace:GetAttribute("RaidStarting") then return end
            Safe("FireVoteSkipRaid", function()
                local Interact = GetInteract()
                if not Interact then return end
                task.wait(0.5)
                Interact:FireServer("VoteSkipRaid")
            end)
        end

        workspace:GetAttributeChangedSignal("RaidStarting"):Connect(FireStart)
        task.wait(0.5)
        FireStart()
        print("[StoryFarm] Watching for RaidStarting...")
    end)
end)

-- Periodic stats
task.spawn(function()
    while true do
        task.wait(STATS_INTERVAL)
        if not Running then continue end

        Safe("StatsReport", function()
            local Data = GetData()
            local Runtime = math.floor((tick() - Stats.StartTime) / 60)

            local LiveMatch = GetMatchStats()
            local LiveKills = (LiveMatch and type(LiveMatch.Kills) == "number") and LiveMatch.Kills or 0
            local SessionKills = Stats.TotalKills + LiveKills -- include current in-progress match

            SendWebhook("Status Report", {
                { name = "Runtime",         value = Runtime .. " min",                       inline = true },
                { name = "Matches",         value = tostring(Stats.MatchesCompleted),        inline = true },
                { name = "Rebirths Done",   value = tostring(Stats.Rebirths),                inline = true },
                { name = "Total Kills",     value = tostring(SessionKills),                  inline = true },
                { name = "Total Damage",    value = tostring(Stats.TotalDamage),             inline = true },
                { name = "Attacks",         value = tostring(Stats.AttacksAttempted),        inline = true },
                { name = "Aborted",         value = tostring(Stats.AttacksAborted),          inline = true },
                { name = "Zombies Tracked", value = tostring((function()
                    local n = 0; for _ in pairs(AliveZombies) do n = n + 1 end; return n
                end)()), inline = true },
                { name = "Bosses Tracked",  value = tostring((function()
                    local n = 0; for _ in pairs(AliveBosses) do n = n + 1 end; return n
                end)()), inline = true },
                { name = "Coins",           value = Data and tostring(Data.Coins)    or "?", inline = true },
                { name = "Level",           value = Data and tostring(Data.Level)    or "?", inline = true },
                { name = "Current Rebirth", value = Data and tostring(Data.Rebirths) or "?", inline = true },
            }, 7506394)
        end)
    end
end)

-- Current target ping (every 5s)
task.spawn(function()
    while true do
        task.wait(5)
        if not Running then continue end

        Safe("CurrentTargetPing", function()
            local Target = CurrentTarget
            if not Target or not Target.Parent then
                SendWebhook("Current Target", {
                    { name = "Target", value = "(none)", inline = true },
                }, 10070709)
                return
            end

            local Data = GetTargetEntry(Target)
            local HP = (Data and Data.GetHealth) and tostring(Data.GetHealth()) or "?"
            local Dist = "?"
            if Data and Data.Root and Data.Root.Parent and HRP and HRP.Parent then
                Dist = tostring(math.floor((Data.Root.Position - HRP.Position).Magnitude))
            end

            SendWebhook("Current Target", {
                { name = "Name",     value = Target.Name,                      inline = true },
                { name = "Type",     value = CurrentTargetIsBoss and "BOSS" or "Zombie", inline = true },
                { name = "HP",       value = tostring(HP),                     inline = true },
                { name = "Distance", value = Dist,                             inline = true },
            }, CurrentTargetIsBoss and 15158332 or 3447003)
        end)
    end
end)

-- Wait for the ForceField on the character to be destroyed (or timeout)
local function WaitForForceField(Char, Timeout)
    local Deadline = tick() + (Timeout or 5)
    while tick() < Deadline do
        if not Char or not Char.Parent then return end
        local FF = Char:FindFirstChildOfClass("ForceField")
        if not FF then return end
        task.wait(0.1)
    end
end

-- Apply to initial character too
local HealthChangedConn = nil
local function SetupCharacter(NewCharacter)
    Safe("SetupCharacter", function()
        print("[StoryFarm] Character ready")
        Character = NewCharacter
        Humanoid = NewCharacter:WaitForChild("Humanoid", 10)
        HRP = NewCharacter:WaitForChild("HumanoidRootPart", 10)
        Attacking = false
        CurrentTarget = nil
        SlotCooldownEnd = { 0, 0, 0, 0 }
        LastDamageAt = 0
        LastSeenHP = nil

        if not Humanoid or not HRP then
            print("[StoryFarm] Missing Humanoid/HRP after spawn")
            return
        end

        -- Damage tracker: any HP drop = mark damage, force retreat
        if HealthChangedConn then
            pcall(function() HealthChangedConn:Disconnect() end)
        end
        LastSeenHP = Humanoid.Health
        HealthChangedConn = Humanoid.HealthChanged:Connect(function(NewHP)
            if LastSeenHP and NewHP < LastSeenHP - 0.01 then
                LastDamageAt = tick()
            end
            LastSeenHP = NewHP
        end)

        -- Arm auto-revive (CanRevive attribute on Character)
        HookReviveListener(NewCharacter)

        -- Walk 20 studs forward to break forcefield / unstick from spawn
        Safe("WalkOutOfSpawn", function()
            local Target = HRP.Position + HRP.CFrame.LookVector * 20
            Humanoid:MoveTo(Target)

            local Done = false
            local Conn = Humanoid.MoveToFinished:Connect(function() Done = true end)
            local Deadline = tick() + 3
            while not Done and tick() < Deadline do
                if not IsCharValid() then break end
                task.wait(0.1)
            end
            pcall(function() Conn:Disconnect() end)
        end)

        -- Wait out any remaining forcefield invuln
        WaitForForceField(NewCharacter, 5)

        if not IsCharValid() then return end
        Safe("InitialUnderground", GoUnderground)
        print("[StoryFarm] Underground, hunting")
    end)
end

LocalPlayer.CharacterAdded:Connect(SetupCharacter)

-- Run setup for the character we already had at script load
if Character and Character.Parent then
    task.spawn(SetupCharacter, Character)
end

-- Stuck-floating recovery: if we go >15s without a successful attack while a raid
-- is active and zombies exist, TP to workspace.Map.SpawnPoint to unstick.
task.spawn(function()
    while true do
        task.wait(2)
        if not Running then continue end
        if not IsCharValid() then continue end
        if workspace:FindFirstChild("GameFinished") then continue end
        if workspace:FindFirstChild("Cutscene") then continue end
        if tick() - LastAttackAt < 15 then continue end

        local Folder = workspace:FindFirstChild("Zombies")
        if not Folder or #Folder:GetChildren() == 0 then continue end

        Safe("StuckRecovery", function()
            local Map = workspace:FindFirstChild("Map")
            local Spawn = Map and Map:FindFirstChild("SpawnPoint")
            if Spawn and Spawn:IsA("BasePart") then
                print("[StoryFarm] Stuck floating for " .. math.floor(tick() - LastAttackAt)
                    .. "s, TPing to SpawnPoint")
                HRP.CFrame = Spawn.CFrame + Vector3.new(0, 3, 0)
                HRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                LastAttackAt = tick() -- give us time to recover before re-triggering
            end
        end)
    end
end)

-- Last-resort target watchdog: if cache is empty and a raid is active, force a folder rescan
task.spawn(function()
    while true do
        task.wait(3)
        if not Running then continue end

        local HaveAny = false
        for _ in pairs(AliveZombies) do HaveAny = true break end
        if HaveAny then continue end
        for _ in pairs(AliveBosses) do HaveAny = true break end
        if HaveAny then continue end

        -- No tracked enemies — try to recover
        Safe("TargetWatchdog", function()
            local Folder = workspace:FindFirstChild("Zombies")
            if Folder then
                if Folder ~= CurrentZombieFolder then AttachZombieFolder(Folder) end
                for _, Child in ipairs(Folder:GetChildren()) do
                    if Child:IsA("Model") and not AliveZombies[Child] then
                        Register(AliveZombies, Child, UnregisterZombie)
                    end
                end
            end
            for _, Tag in ipairs({ "RaidBoss", "Boss" }) do
                for _, Boss in ipairs(CollectionService:GetTagged(Tag)) do
                    if not AliveBosses[Boss] then
                        if Tag == "Boss" and not Boss:GetAttribute("IsRaidBoss") then continue end
                        Register(AliveBosses, Boss, UnregisterBoss)
                    end
                end
            end
        end)
    end
end)
