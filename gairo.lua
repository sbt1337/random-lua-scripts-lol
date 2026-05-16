-- gairo_atf.lua — Gairo boss autofarm
-- Locks to workspace.Zombies.Gairo's left leg, spams all 5 ability slots + gadget,
-- auto-revives via CanRevive, auto-restarts the match (PlayAgain) and auto-skips
-- the raid lobby vote.
--
-- Assumes Saiyan (or any ability that auto-sets CanRevive on death) is equipped.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

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
        print("[GairoFarm] Anti-AFK: simulated input")
    end)
end

-- Config
local WEBHOOK     = "https://discord.com/api/webhooks/1503857688118034662/H3y9e9EUyyZyRnKCQ-X_eIdRpejU8OwStg22dzEoycfGt__iAhRTYmnumIenbFWEckS7"
local LOG_WEBHOOK = "https://discord.com/api/webhooks/1504232139749720074/D_Oe_5gwVDguw2eUeqZbKvpmxBLeajcEZxClzS4tvyAyS80zlL3iOLHsrpOTXUsh_gdu"
local RAW_URL     = "https://raw.githubusercontent.com/sbt1337/random-lua-scripts-lol/refs/heads/main/gairo.lua"

local TP_INTERVAL        = 0.05   -- how often we re-stick to the leg (handles boss movement)
local LEG_Y_OFFSET       = 0      -- vertical offset from leg part center; tune up/down if abilities miss
local SLOT_COUNT         = 5      -- ability slots 1..5 (Z, X, C, V, G keys per decompile)
local GADGET_COOLDOWN    = 0.5    -- minimum delay between gadget spams
local SOFT_SLOT_COOLDOWN = 0.4    -- pending server confirmation via UsedAbility event
local HEARTBEAT_INTERVAL = 60
local STATS_INTERVAL     = 1800   -- 30 min

-- Try these part names in order to find the boss's left leg. Covers R15 (most modern
-- enemies) and R6 (legacy). If none match we fall back to HumanoidRootPart.
local LEG_PART_NAMES = { "LeftLowerLeg", "LeftFoot", "LeftUpperLeg", "LeftLeg" }
local BLOCKING_STATES = { "LightAttack", "NoAttack", "Action", "Stun", "UsingMove" }

-- State
local Running = true
local ClearingForceField = false   -- true while walking off spawn FF; pauses TPs
local SlotCooldownEnd = { 0, 0, 0, 0, 0 }
local GadgetCooldownEnd = 0
local LastAttackAt = tick()

local Stats = {
    AbilitiesFired   = 0,
    GadgetsFired     = 0,
    Revives          = 0,
    MatchesCompleted = 0,
    Deaths           = 0,
    StartTime        = tick(),
}

-- Forward declarations so closures parsed earlier (heartbeat, error catcher) resolve
-- these as upvalues instead of nil globals.
local SendWebhook
local SendError

-- Log webhook: batches print() output and flushes every 3s so we can read it on mobile.
local LogBuffer = {}
local RawPrint = print
local LogStats = { Sent = 0, Failed = 0, Dropped = 0 }

local function FlushLogs()
    if #LogBuffer == 0 then return end

    local Snapshot = LogBuffer
    LogBuffer = {}

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
            username = "GairoFarm Logs",
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

print = function(...)
    local n = select("#", ...)
    local Parts = {}
    for i = 1, n do Parts[i] = tostring((select(i, ...))) end
    local Msg = table.concat(Parts, " ")
    pcall(RawPrint, Msg)
    if #LogBuffer >= 300 then table.remove(LogBuffer, 1) end
    table.insert(LogBuffer, os.date("%H:%M:%S") .. " " .. Msg)
end

task.spawn(function()
    while true do
        task.wait(3)
        pcall(FlushLogs)
    end
end)

-- Webhook helpers (assigned to the forward-declared locals above)
SendWebhook = function(Title, Fields, Color)
    pcall(function()
        local Body = HttpService:JSONEncode({
            username = "GairoFarm",
            embeds = {{
                title = Title,
                color = Color or 3066993,
                fields = Fields,
            }},
        })
        local RequestFunc = (syn and syn.request) or request or http_request
        if not RequestFunc then return end
        RequestFunc({
            Url = WEBHOOK,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = Body,
        })
    end)
end

SendError = function(Label, Err, Trace)
    local Msg = "[GairoFarm] ERROR in " .. Label .. ": " .. tostring(Err)
    print(Msg)
    if Trace then print(Trace) end
    SendWebhook("Error: " .. Label, {
        { name = "Details", value = "```" .. tostring(Err) .. "```", inline = false },
        { name = "Trace",   value = "```" .. tostring(Trace or "no trace"):sub(1, 1000) .. "```", inline = false },
    }, 15158332)
end

local function Safe(Label, Fn, ...)
    local Args = { ... }
    local ok, Err = xpcall(function()
        return Fn(table.unpack(Args))
    end, function(E)
        return tostring(E) .. "\n" .. debug.traceback("", 2)
    end)
    if not ok then SendError(Label, Err, nil) end
    return ok
end

-- Catch errors that escape Safe (Connect callbacks registered outside Safe, etc.)
do
    local LastReported = 0
    pcall(function()
        game:GetService("ScriptContext").Error:Connect(function(Msg, Trace, _)
            if tick() - LastReported < 2 then return end
            LastReported = tick()
            SendError("UncaughtScriptError", Msg, Trace)
        end)
    end)
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

-- Validity checks
local function IsCharValid()
    return Character and Character.Parent
        and Humanoid and Humanoid.Parent and Humanoid.Health > 0
        and HRP and HRP.Parent
end

-- Mirror of game's Utils.ActionCheck — true if we can't act
local function IsActionBlocked()
    if not IsCharValid() then return true end
    for _, Name in ipairs(BLOCKING_STATES) do
        if Character:FindFirstChild(Name) then return true end
    end
    if workspace:FindFirstChild("Cutscene") then return true end
    if workspace:FindFirstChild("GameFinished") then return true end
    return false
end

-- Gairo location
local function GetGairo()
    local Zombies = workspace:FindFirstChild("Zombies")
    if not Zombies then return nil end
    return Zombies:FindFirstChild("Sorcerer")
end

-- True while the boss is in a ForceField / invincibility phase.
-- Covers both Roblox ForceField instances and common game attribute flags.
local function GairoIsShielded(Gairo)
    if not Gairo then return false end
    -- Instance-based ForceField (most common pattern)
    for _, d in Gairo:GetDescendants() do
        if d:IsA("ForceField") then return true end
    end
    -- Attribute-based invincibility flags
    local InvincAttrs = { "Invincible", "Shielded", "ForceField", "Immune", "Untargetable" }
    for _, attr in ipairs(InvincAttrs) do
        local v = Gairo:GetAttribute(attr)
        if v == true or v == 1 then return true end
    end
    -- Config value approach (some games put an Invincible BoolValue under Config)
    local Config = Gairo:FindFirstChild("Config")
    if Config then
        for _, attr in ipairs(InvincAttrs) do
            local val = Config:FindFirstChild(attr)
            if val and (val:IsA("BoolValue") or val:IsA("IntValue")) and val.Value ~= false and val.Value ~= 0 then
                return true
            end
        end
    end
    return false
end

-- Locate the left-leg part. Returns (Part, UseFallback). UseFallback=true means we
-- only found HRP and the caller should offset us downward toward floor level.
local function GetGairoLeg(Gairo)
    if not Gairo then return nil end
    for _, Name in ipairs(LEG_PART_NAMES) do
        local Part = Gairo:FindFirstChild(Name)
        if Part and Part:IsA("BasePart") then return Part, false end
    end
    local Root = Gairo:FindFirstChild("HumanoidRootPart") or Gairo.PrimaryPart
    if Root and Root:IsA("BasePart") then return Root, true end
    return nil
end

local function GetGairoHealth(Gairo)
    if not Gairo then return nil end
    local Config = Gairo:FindFirstChild("Config")
    if Config then
        local H = Config:FindFirstChild("Health")
        if H and (H:IsA("IntValue") or H:IsA("NumberValue")) then return H.Value end
    end
    local Hum = Gairo:FindFirstChildOfClass("Humanoid")
    if Hum then return Hum.Health end
    return nil
end

-- Remote accessors
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

local function GetGadgetInfo()
    local Data = LocalPlayer:FindFirstChild("Data")
    if not Data then return nil, nil end
    local GadgetSlots = Data:FindFirstChild("GadgetSlots")
    if not GadgetSlots then return nil, nil end
    local ok, Decoded = pcall(HttpService.JSONDecode, HttpService, GadgetSlots.Value)
    if not ok or not Decoded then return nil, nil end
    for SlotName, SlotData in pairs(Decoded) do
        if SlotData and SlotData.Equipped then
            return SlotName, SlotData.Name
        end
    end
    return nil, nil
end

-- Authoritative per-slot cooldown from server
task.spawn(function()
    Safe("CooldownHook", function()
        local Assets = ReplicatedStorage:WaitForChild("Assets", 30)
        local Remotes = Assets:WaitForChild("Remotes", 30)
        local UsedAbility = Remotes:WaitForChild("UsedAbility", 30)

        UsedAbility.OnClientEvent:Connect(function(_, Duration, _Name, KeyIndex)
            if type(Duration) ~= "number" then return end
            if type(KeyIndex) ~= "number" or KeyIndex < 1 or KeyIndex > SLOT_COUNT then return end
            SlotCooldownEnd[KeyIndex] = tick() + Duration
        end)
        print("[GairoFarm] Cooldown hook armed")
    end)
end)

-- Noclip
RunService.Stepped:Connect(function()
    if not Running then return end
    if not Character or not Character.Parent then return end
    pcall(function()
        for _, Part in ipairs(Character:GetDescendants()) do
            if Part:IsA("BasePart") then Part.CanCollide = false end
        end
    end)
end)

-- Main loop: re-stick to Gairo's left leg every TP_INTERVAL, then fire every
-- off-cooldown ability slot + the gadget. We sit in his hitbox; abilities radiate
-- out from us and clip him every cycle.
task.spawn(function()
    while true do
        task.wait(TP_INTERVAL)
        if not Running then continue end
        if not IsCharValid() then continue end

        Safe("AttackLoop", function()
            local Gairo = GetGairo()
            if not Gairo then return end

            local Leg, UseFallback = GetGairoLeg(Gairo)
            if not Leg then return end

            -- Pause TPs while walking off spawn ForceField
            if ClearingForceField then return end

            local Pos = Leg.Position
            local TargetY = Pos.Y + LEG_Y_OFFSET + (UseFallback and -3 or 0)
            HRP.CFrame = CFrame.new(Pos.X, TargetY, Pos.Z)
            HRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)

            if IsActionBlocked() then return end

            -- Skip ability spam while boss is shielded / invulnerable
            if GairoIsShielded(Gairo) then return end

            local Interact = GetInteract()
            if not Interact then return end

            -- Spam every ability slot that's off cooldown
            local SlotName, AbilityName = GetAbilityInfo()
            if SlotName and AbilityName then
                local Now = tick()
                for i = 1, SLOT_COUNT do
                    if SlotCooldownEnd[i] <= Now then
                        Interact:FireServer("Ability", i, SlotName, AbilityName, "Began")
                        Interact:FireServer("Ability", i, SlotName, AbilityName, "Released")
                        if SlotCooldownEnd[i] <= Now then
                            SlotCooldownEnd[i] = Now + SOFT_SLOT_COOLDOWN
                        end
                        Stats.AbilitiesFired = Stats.AbilitiesFired + 1
                        LastAttackAt = Now
                    end
                end
            end

            -- Spam gadget (E key) too
            if tick() >= GadgetCooldownEnd then
                local GadgetSlot, GadgetName = GetGadgetInfo()
                if GadgetSlot and GadgetName then
                    Interact:FireServer("Gadget", GadgetSlot, GadgetName, "Began")
                    Interact:FireServer("Gadget", GadgetSlot, GadgetName, "Released")
                    GadgetCooldownEnd = tick() + GADGET_COOLDOWN
                    Stats.GadgetsFired = Stats.GadgetsFired + 1
                end
            end
        end)
    end
end)

-- Auto-revive: server sets CanRevive=true on Character (matches ClientUI.lua:1330
-- and CharacterHandler/Client.lua:1756). Saiyan ult's revive phase triggers this.
--
-- Two layers:
--   1. GetAttributeChangedSignal on the current Character (same as story_auto).
--   2. A 0.5s polling fallback that re-resolves LocalPlayer.Character each tick.
-- The poll catches cases where (a) CanRevive is set before our connect lands,
-- (b) the character gets destroyed and replaced before the signal can fire, or
-- (c) the captured Char goes stale after a respawn.
local LastReviveAt = 0
local function FireRevive(Source)
    if tick() - LastReviveAt < 2 then return end
    LastReviveAt = tick()
    Safe("AutoRevive_" .. Source, function()
        local Interact = GetInteract()
        if not Interact then return end
        print("[GairoFarm] [" .. Source .. "] CanRevive=true, firing Revive")
        Interact:FireServer("Revive")
        Stats.Revives = Stats.Revives + 1
    end)
end

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
        FireRevive("signal")
    end

    ReviveAttrConn = Char:GetAttributeChangedSignal("CanRevive"):Connect(function()
        local Val = Char:GetAttribute("CanRevive")
        print("[GairoFarm] CanRevive signal -> " .. tostring(Val))
        TryRevive()
    end)
    print("[GairoFarm] Revive listener armed on " .. Char.Name)
    TryRevive()
end

-- Polling fallback. Re-fetches LocalPlayer.Character each tick so it survives
-- character swaps (downed -> spectator -> revived) that would orphan the captured
-- Char in HookReviveListener.
task.spawn(function()
    while true do
        task.wait(0.5)
        if not Running then continue end
        local Char = LocalPlayer.Character
        if not Char or not Char.Parent then continue end
        if not Char:GetAttribute("CanRevive") then continue end
        FireRevive("poll")
    end
end)

-- End-of-match: workspace.GameFinished folder appears when match ends
-- (Create("GameFinished", "Folder", workspace) at _LocalFX.lua:15994).
-- Spam PlayAgain until the folder is gone.
local LastEndAt = 0
local function HandleMatchEnd()
    if tick() - LastEndAt < 5 then return end
    LastEndAt = tick()

    Safe("MatchEnd", function()
        Stats.MatchesCompleted = Stats.MatchesCompleted + 1

        local Data = LocalPlayer:FindFirstChild("Data")
        local Coins    = Data and Data:FindFirstChild("Coins")
        local Level    = Data and Data:FindFirstChild("BattlepassLevel")
        local Rebirths = Data and Data:FindFirstChild("Rebirths")

        SendWebhook("Match Over", {
            { name = "Match #",   value = tostring(Stats.MatchesCompleted),         inline = true },
            { name = "Coins",     value = Coins    and tostring(Coins.Value)    or "?", inline = true },
            { name = "Level",     value = Level    and tostring(Level.Value)    or "?", inline = true },
            { name = "Rebirths",  value = Rebirths and tostring(Rebirths.Value) or "?", inline = true },
            { name = "Deaths",    value = tostring(Stats.Deaths),                   inline = true },
            { name = "Revives",   value = tostring(Stats.Revives),                  inline = true },
        }, 3066993)

        if not Running then return end

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
        if workspace:FindFirstChild("GameFinished") then HandleMatchEnd() end
        workspace.ChildAdded:Connect(function(Child)
            if Child.Name == "GameFinished" then HandleMatchEnd() end
        end)
        print("[GairoFarm] End-screen watcher armed")
    end)
end)

-- Auto-skip raid lobby vote
task.spawn(function()
    Safe("RaidStartWatcher", function()
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
        print("[GairoFarm] Raid-start watcher armed")
    end)
end)

-- Heartbeat: prints script state + Gairo HP so we can confirm it's alive
task.spawn(function()
    while true do
        task.wait(HEARTBEAT_INTERVAL)
        pcall(function()
            local Gairo = GetGairo()
            local GHP = Gairo and tostring(GetGairoHealth(Gairo) or "?") or "no-gairo"
            local SinceAttack = math.floor(tick() - LastAttackAt)
            local GF = workspace:FindFirstChild("GameFinished") and "Y" or "N"
            local CS = workspace:FindFirstChild("Cutscene") and "Y" or "N"

            print("[Heartbeat] running=" .. tostring(Running)
                .. " gairo=" .. (Gairo and "Y" or "N")
                .. " GHP=" .. GHP
                .. " sinceAttack=" .. SinceAttack .. "s"
                .. " GF=" .. GF .. " CS=" .. CS
                .. " ab=" .. Stats.AbilitiesFired
                .. " gad=" .. Stats.GadgetsFired
                .. " matches=" .. Stats.MatchesCompleted
                .. " deaths=" .. Stats.Deaths
                .. " revives=" .. Stats.Revives)
        end)
    end
end)

-- Periodic stats
task.spawn(function()
    while true do
        task.wait(STATS_INTERVAL)
        if not Running then continue end
        Safe("StatsReport", function()
            local Runtime = math.floor((tick() - Stats.StartTime) / 60)
            local Data = LocalPlayer:FindFirstChild("Data")
            local Coins    = Data and Data:FindFirstChild("Coins")
            local Level    = Data and Data:FindFirstChild("BattlepassLevel")
            local Rebirths = Data and Data:FindFirstChild("Rebirths")

            SendWebhook("Status Report", {
                { name = "Runtime",   value = Runtime .. " min",                        inline = true },
                { name = "Matches",   value = tostring(Stats.MatchesCompleted),         inline = true },
                { name = "Abilities", value = tostring(Stats.AbilitiesFired),           inline = true },
                { name = "Gadgets",   value = tostring(Stats.GadgetsFired),             inline = true },
                { name = "Revives",   value = tostring(Stats.Revives),                  inline = true },
                { name = "Deaths",    value = tostring(Stats.Deaths),                   inline = true },
                { name = "Coins",     value = Coins    and tostring(Coins.Value)    or "?", inline = true },
                { name = "Level",     value = Level    and tostring(Level.Value)    or "?", inline = true },
                { name = "Rebirths",  value = Rebirths and tostring(Rebirths.Value) or "?", inline = true },
            }, 7506394)
        end)
    end
end)

-- Walk off the spawn ForceField so it drops immediately.
-- Roblox's FF persists until the character physically moves; the TP loop keeps
-- repositioning us every 0.05s so we never actually move and the FF never clears.
-- Solution: pause TPs, use Humanoid:MoveTo to physically walk forward for 2s, then resume.
local function ClearSpawnForceField(Char, Hum, Hrp)
    task.wait(0.15)  -- brief wait for FF instance to be added by server
    if not Char or not Char.Parent then return end
    local FF = Char:FindFirstChildOfClass("ForceField")
    if not FF then return end  -- no FF on this spawn, skip

    ClearingForceField = true
    print("[GairoFarm] ForceField detected — walking to clear it")

    -- Walk forward 20 studs; MoveTo lets Humanoid engine drive movement naturally
    local WalkTarget = Hrp.Position + Hrp.CFrame.LookVector * 20
    Hum:MoveTo(WalkTarget)
    task.wait(2)

    -- Stop in place
    Hum:MoveTo(Hrp.Position)
    ClearingForceField = false
    print("[GairoFarm] ForceField cleared — resuming farm")
end

-- Character setup (initial + every respawn)
local DiedConn = nil
local function SetupCharacter(NewCharacter)
    Safe("SetupCharacter", function()
        print("[GairoFarm] Character ready")
        Character = NewCharacter
        Humanoid = NewCharacter:WaitForChild("Humanoid", 10)
        HRP = NewCharacter:WaitForChild("HumanoidRootPart", 10)
        SlotCooldownEnd = { 0, 0, 0, 0, 0 }
        GadgetCooldownEnd = 0

        if not Humanoid or not HRP then
            print("[GairoFarm] Missing Humanoid/HRP after spawn")
            return
        end

        if DiedConn then
            pcall(function() DiedConn:Disconnect() end)
        end
        DiedConn = Humanoid.Died:Connect(function()
            Stats.Deaths = Stats.Deaths + 1
            print("[GairoFarm] Died (#" .. Stats.Deaths .. ")")
        end)

        HookReviveListener(NewCharacter)
        task.spawn(ClearSpawnForceField, NewCharacter, Humanoid, HRP)
    end)
end

LocalPlayer.CharacterAdded:Connect(SetupCharacter)
if Character and Character.Parent then
    task.spawn(SetupCharacter, Character)
end

-- Reload GUI
local function MakeReloadButton()
    local old = LocalPlayer.PlayerGui:FindFirstChild("GairoFarmGUI")
    if old then old:Destroy() end

    local sg = Instance.new("ScreenGui")
    sg.Name           = "GairoFarmGUI"
    sg.ResetOnSpawn   = false
    sg.IgnoreGuiInset = true
    sg.Parent         = LocalPlayer.PlayerGui

    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(0, 150, 0, 38)
    btn.Position         = UDim2.new(0.5, -75, 0.5, -19)
    btn.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
    btn.TextColor3       = Color3.fromRGB(255, 75, 75)
    btn.Font             = Enum.Font.GothamBold
    btn.TextSize         = 14
    btn.Text             = "⟳  RELOAD FARM"
    btn.BorderSizePixel  = 0
    btn.Parent           = sg
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)

    local stroke = Instance.new("UIStroke", btn)
    stroke.Color     = Color3.fromRGB(255, 75, 75)
    stroke.Thickness = 1.2

    btn.MouseButton1Click:Connect(function()
        Running = false
        print("[GairoFarm] Reloading...")
        sg:Destroy()
        task.wait(0.3)
        loadstring(game:HttpGet(RAW_URL))()
    end)
end

MakeReloadButton()

-- Boot ping
task.spawn(function()
    pcall(function()
        SendWebhook("GairoFarm Started", {
            { name = "Time",     value = os.date("%Y-%m-%d %H:%M:%S"), inline = true },
            { name = "PlaceId",  value = tostring(game.PlaceId),       inline = true },
        }, 3447003)
    end)
end)

print("[GairoFarm] Loaded")
