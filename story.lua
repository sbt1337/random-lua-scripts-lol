-- StoryFarm — rewritten from decompile analysis
-- Patterns lifted from working infinity.lua + gairo.lua:
--   - M1 fire every 0.42s (decompile: u302=0.4 in MB1 handler)
--   - Direct workspace.Zombies:GetChildren() — zombies are direct children
--   - Health.Value > 0 = ALIVE (LiveRadar/Handler.lua:190)
--   - All 5 ability slots (Z=1, X=2, C=3, V=4, G=5)
--   - Gadget (E) + Special (Q) fired alongside
--   - TP onto target, no underground hiding (kills throughput)
--   - GateHit for section advance (SetupGate at _LocalFX.lua:17418)

if game.PlaceId == 140409475718339 then return end

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local HttpService       = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer

-- ─── SESSION TOKEN ───────────────────────────────────────────────────────────
-- Increment global on each load. Old loops detect mismatch and break, so
-- reload doesn't leave zombies of itself running.
_G.StoryFarmSession = (_G.StoryFarmSession or 0) + 1
local MySession = _G.StoryFarmSession
local function Alive() return _G.StoryFarmSession == MySession end

-- ─── CHARACTER ───────────────────────────────────────────────────────────────
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local Humanoid  = Character:WaitForChild("Humanoid")
local HRP       = Character:WaitForChild("HumanoidRootPart")

local function IsCharValid()
    return Character and Character.Parent
        and Humanoid and Humanoid.Parent and Humanoid.Health > 0
        and HRP and HRP.Parent
end

-- ─── CONFIG ──────────────────────────────────────────────────────────────────
local WEBHOOK     = "https://discord.com/api/webhooks/1503857688118034662/H3y9e9EUyyZyRnKCQ-X_eIdRpejU8OwStg22dzEoycfGt__iAhRTYmnumIenbFWEckS7"
local LOG_WEBHOOK = "https://discord.com/api/webhooks/1504232139749720074/D_Oe_5gwVDguw2eUeqZbKvpmxBLeajcEZxClzS4tvyAyS80zlL3iOLHsrpOTXUsh_gdu"
local RAW_URL     = "https://raw.githubusercontent.com/sbt1337/random-lua-scripts-lol/refs/heads/main/story.lua"

local M1_CD              = 0.42   -- decompile says 0.4 + small buffer
local SLOT_SOFT_CD       = 0.4    -- until UsedAbility event confirms real CD
local GADGET_CD          = 0.5
local SPECIAL_SOFT_CD    = 1
local SLOT_COUNT         = 5
local TP_RANGE_MAX       = 8      -- TP onto target if further than this
local NO_DAMAGE_TIMEOUT  = 10     -- skip target after this many seconds of no HP change
local SKIP_DURATION      = 30
local HEARTBEAT_INTERVAL = 30
local STATS_INTERVAL     = 1800
local IDLE_GATE_THRESHOLD = 3     -- zombies=0 for this long → fire gates

local BLOCKING_STATES = { "LightAttack", "NoAttack", "Action", "Stun", "UsingMove" }

local REBIRTH_STEPS = {
    { RequiredLevel = 50, CoinsRequired = 2500000  },
    { RequiredLevel = 50, CoinsRequired = 5000000  },
    { RequiredLevel = 50, CoinsRequired = 7500000  },
    { RequiredLevel = 50, CoinsRequired = 10000000 },
    { RequiredLevel = 50, CoinsRequired = 12500000 },
}

local CARD_PRIORITY = { "DMG", "GadgetMastery", "Wealth", "ExtraLife", "Agility" }

-- ─── STATE ───────────────────────────────────────────────────────────────────
local Running              = true
local CurrentTarget        = nil

local ShowcasingSlot, ShowcasingAbility
local GadgetSlotKey, GadgetName
local SpecialSlotKey, SpecialName

local SlotCooldownEnd   = { 0, 0, 0, 0, 0 }
local GadgetCooldownEnd = 0
local SpecialCooldownEnd = 0
local LastM1            = 0
local LastAttackAt      = tick()
local LastDamageAt      = 0
local LastSeenHP        = nil

-- Per-target no-damage tracking
local ActiveTargetHPBaseline = nil
local ActiveTargetBaselineAt = nil
local SkipUntil = setmetatable({}, { __mode = "k" })

local Stats = {
    M1               = 0,
    AbilitiesFired   = 0,
    GadgetsFired     = 0,
    SpecialsFired    = 0,
    MatchesCompleted = 0,
    Rebirths         = 0,
    Revives          = 0,
    Cards            = 0,
    GatesFired       = 0,
    StartTime        = tick(),
}

print("[StoryFarm] Loaded (session " .. MySession .. ")")

-- ─── LOG WEBHOOK ─────────────────────────────────────────────────────────────
local LogBuffer = {}
local RawPrint  = print

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
    if not RequestFunc then return end
    pcall(function()
        RequestFunc({
            Url     = LOG_WEBHOOK,
            Method  = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body    = HttpService:JSONEncode({
                username = "StoryFarm Logs",
                content  = "```" .. Payload .. "```",
            }),
        })
    end)
end

print = function(...)
    local n     = select("#", ...)
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
        if not Alive() then break end
        pcall(FlushLogs)
    end
end)

-- ─── ERROR HANDLING + WEBHOOK ────────────────────────────────────────────────
local SendWebhook

local function SendError(Label, Err, Trace)
    print("[StoryFarm] ERROR " .. Label .. ": " .. tostring(Err))
    if Trace then print(Trace) end
    if SendWebhook then
        SendWebhook("Error: " .. Label, {
            { name = "Details", value = "```" .. tostring(Err):sub(1, 800) .. "```", inline = false },
            { name = "Trace",   value = "```" .. tostring(Trace or "no trace"):sub(1, 800) .. "```", inline = false },
        }, 15158332)
    end
end

local function Safe(Label, Fn, ...)
    local Args = { ... }
    local ok, errOrResult = xpcall(function()
        return Fn(table.unpack(Args))
    end, function(Err)
        return tostring(Err) .. "\n" .. debug.traceback("", 2)
    end)
    if not ok then SendError(Label, errOrResult) end
    return ok, errOrResult
end

SendWebhook = function(Title, Fields, Color)
    pcall(function()
        local RequestFunc = (syn and syn.request) or request or http_request
        if not RequestFunc then return end
        RequestFunc({
            Url     = WEBHOOK,
            Method  = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body    = HttpService:JSONEncode({
                username = "StoryFarm",
                embeds = {{
                    title  = Title,
                    color  = Color or 3066993,
                    fields = Fields,
                }},
            }),
        })
    end)
end

do
    local LastReported = 0
    pcall(function()
        game:GetService("ScriptContext").Error:Connect(function(Msg, Trace)
            if not Alive() then return end
            if tick() - LastReported < 2 then return end
            LastReported = tick()
            SendError("UncaughtScriptError", Msg, Trace)
        end)
    end)
end

-- ─── ANTI-AFK + INPUT ────────────────────────────────────────────────────────
do
    local VirtualUser = game:GetService("VirtualUser")
    LocalPlayer.Idled:Connect(function()
        if not Alive() then return end
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
        print("[StoryFarm] Anti-AFK fired")
    end)
end

UserInputService.InputBegan:Connect(function(Input, GameProcessed)
    if not Alive() then return end
    if GameProcessed then return end
    if Input.KeyCode == Enum.KeyCode.PageDown then
        Running = not Running
        print("[StoryFarm] " .. (Running and "Enabled" or "Disabled"))
    end
end)

-- ─── REMOTES + DATA ──────────────────────────────────────────────────────────
local Assets, Remotes, Interact, UsedAbility, DrawCardRemote, FuncInteract

local function ResolveRemotes()
    if not Assets then Assets = ReplicatedStorage:WaitForChild("Assets", 30) end
    if not Assets then return end
    if not Remotes then Remotes = Assets:WaitForChild("Remotes", 30) end
    if not Remotes then return end
    Interact        = Interact        or Remotes:FindFirstChild("Interact")
    UsedAbility     = UsedAbility     or Remotes:FindFirstChild("UsedAbility")
    DrawCardRemote  = DrawCardRemote  or Remotes:FindFirstChild("DrawCard")
    if not FuncInteract then
        local Requests = Assets:FindFirstChild("Requests")
        FuncInteract = Requests and Requests:FindFirstChild("FuncInteract")
    end
end

ResolveRemotes()

local function GetInteract()
    if not Interact then ResolveRemotes() end
    return Interact
end

-- ─── ABILITY / GADGET / SPECIAL REFRESH ──────────────────────────────────────
local function DecodeSlot(StringValue)
    if not StringValue then return nil end
    local ok, Decoded = pcall(HttpService.JSONDecode, HttpService, StringValue.Value)
    if not ok then return nil end
    return Decoded
end

local function RefreshAbility()
    local Data = LocalPlayer:FindFirstChild("Data")
    if not Data then return end
    local Decoded = DecodeSlot(Data:FindFirstChild("AbilitySlots"))
    if not Decoded then return end
    for SlotKey, Slot in pairs(Decoded) do
        if Slot and Slot.Showcasing then
            ShowcasingSlot, ShowcasingAbility = SlotKey, Slot.Name
            return
        end
    end
end

local function RefreshGadget()
    local Data = LocalPlayer:FindFirstChild("Data")
    if not Data then return end
    local Decoded = DecodeSlot(Data:FindFirstChild("GadgetSlots"))
    if not Decoded then return end
    for SlotKey, Slot in pairs(Decoded) do
        if Slot and Slot.Equipped then
            GadgetSlotKey, GadgetName = SlotKey, Slot.Name
            return
        end
    end
end

local function RefreshSpecial()
    local Data = LocalPlayer:FindFirstChild("Data")
    if not Data then return end
    local Decoded = DecodeSlot(Data:FindFirstChild("SpecialSlot"))
    if not Decoded then return end
    for SlotKey, Slot in pairs(Decoded) do
        if Slot and Slot.Equipped then
            SpecialSlotKey, SpecialName = SlotKey, Slot.Name
            return
        end
    end
end

RefreshAbility()
RefreshGadget()
RefreshSpecial()

task.spawn(function()
    local Data = LocalPlayer:WaitForChild("Data", 30)
    if not Data then return end
    local AS = Data:WaitForChild("AbilitySlots", 30)
    local GS = Data:WaitForChild("GadgetSlots", 30)
    local SS = Data:FindFirstChild("SpecialSlot")
    if AS then AS:GetPropertyChangedSignal("Value"):Connect(RefreshAbility) end
    if GS then GS:GetPropertyChangedSignal("Value"):Connect(RefreshGadget) end
    if SS then SS:GetPropertyChangedSignal("Value"):Connect(RefreshSpecial) end
end)

local function GetData()
    local Data = LocalPlayer:FindFirstChild("Data")
    if not Data then return nil end
    local Level    = Data:FindFirstChild("BattlepassLevel")
    local Rebirths = Data:FindFirstChild("Rebirths")
    local Coins    = Data:FindFirstChild("Coins")
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

-- ─── COOLDOWN HOOK ───────────────────────────────────────────────────────────
task.spawn(function()
    Safe("CooldownHook", function()
        local UA
        for _ = 1, 30 do
            ResolveRemotes()
            UA = UsedAbility
            if UA then break end
            task.wait(1)
        end
        if not UA then print("[StoryFarm] UsedAbility never appeared"); return end

        UA.OnClientEvent:Connect(function(_, Duration, _AbilityName, KeyIndex)
            if not Alive() then return end
            if type(Duration) ~= "number" then return end
            if type(KeyIndex) == "number" and KeyIndex >= 1 and KeyIndex <= SLOT_COUNT then
                SlotCooldownEnd[KeyIndex] = tick() + Duration
            elseif KeyIndex == "Special" or KeyIndex == "Q" then
                SpecialCooldownEnd = tick() + Duration
            end
        end)
        print("[StoryFarm] Cooldown hook armed")
    end)
end)

-- ─── ZOMBIE PICKING ──────────────────────────────────────────────────────────
local function GetHP(Model)
    local Config = Model:FindFirstChild("Config")
    if Config then
        local H = Config:FindFirstChild("Health")
        if H and (H:IsA("IntValue") or H:IsA("NumberValue")) then return H.Value end
    end
    local Hum = Model:FindFirstChildOfClass("Humanoid")
    if Hum then return Hum.Health end
    return nil
end

local function IsAlive(Model)
    if not Model or not Model.Parent then return false end
    if Model:GetAttribute("Died") then return false end
    local HP = GetHP(Model)
    return HP ~= nil and HP > 0
end

local function PickTarget()
    if not IsCharValid() then return nil end
    local ZF = workspace:FindFirstChild("Zombies")
    if not ZF then return nil end

    local Now = tick()
    local Best, BestDist = nil, math.huge
    local MyPos = HRP.Position

    for _, Model in ipairs(ZF:GetChildren()) do
        if not Model:IsA("Model") then continue end
        if SkipUntil[Model] and SkipUntil[Model] > Now then continue end
        if not IsAlive(Model) then continue end
        local Root = Model:FindFirstChild("HumanoidRootPart")
        if not Root then continue end
        local Dist = (Root.Position - MyPos).Magnitude
        if Dist < BestDist then
            Best, BestDist = Model, Dist
        end
    end
    return Best
end

-- ─── ACTION CHECK (mirrors game's Utils.ActionCheck) ─────────────────────────
local function IsActionBlocked()
    if not IsCharValid() then return true end
    for _, Name in ipairs(BLOCKING_STATES) do
        if Character:FindFirstChild(Name) then return true end
    end
    if workspace:FindFirstChild("Cutscene")         then return true end
    if workspace:FindFirstChild("GameFinished")     then return true end
    if workspace:FindFirstChild("SwitchingSection") then return true end
    return false
end

-- ─── NOCLIP ──────────────────────────────────────────────────────────────────
RunService.Stepped:Connect(function()
    if not Alive() then return end
    if not Running then return end
    if not Character or not Character.Parent then return end
    pcall(function()
        for _, Part in ipairs(Character:GetDescendants()) do
            if Part:IsA("BasePart") then Part.CanCollide = false end
        end
    end)
end)

-- ─── ATTACK LOOP ─────────────────────────────────────────────────────────────
-- Infinity-style: TP onto target, fire M1 + ability + gadget + special continuously.
-- No underground dance. Lost throughput >> lost HP.
task.spawn(function()
    while true do
        task.wait(0.05)
        if not Alive() then break end
        if not Running then continue end
        if not IsCharValid() then task.wait(0.5) continue end

        Safe("AttackLoop", function()
            if IsActionBlocked() then return end

            local Inter = GetInteract()
            if not Inter then return end

            if not ShowcasingAbility then RefreshAbility() end
            if not ShowcasingAbility then return end

            local Target = PickTarget()
            if not Target then
                CurrentTarget          = nil
                ActiveTargetHPBaseline = nil
                ActiveTargetBaselineAt = nil
                return
            end

            local Root = Target:FindFirstChild("HumanoidRootPart")
            if not Root then return end

            -- HP baseline for no-damage skip
            if Target ~= CurrentTarget then
                CurrentTarget          = Target
                ActiveTargetHPBaseline = GetHP(Target)
                ActiveTargetBaselineAt = tick()
            else
                local Now = GetHP(Target)
                if Now ~= nil and Now ~= ActiveTargetHPBaseline then
                    ActiveTargetHPBaseline = Now
                    ActiveTargetBaselineAt = tick()
                elseif ActiveTargetBaselineAt and tick() - ActiveTargetBaselineAt >= NO_DAMAGE_TIMEOUT then
                    SkipUntil[Target] = tick() + SKIP_DURATION
                    print("[StoryFarm] No damage on " .. Target.Name
                        .. " for " .. NO_DAMAGE_TIMEOUT .. "s — skipping " .. SKIP_DURATION .. "s")
                    CurrentTarget = nil
                    return
                end
            end

            -- TP onto target if too far
            if (HRP.Position - Root.Position).Magnitude > TP_RANGE_MAX then
                HRP.CFrame = CFrame.new(Root.Position)
                HRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                task.wait(0.05)
                if not IsCharValid() then return end
            end

            local Now = tick()

            -- M1 — basic attack, ~0.4s server CD per decompile
            if Now - LastM1 >= M1_CD then
                Inter:FireServer("M1", ShowcasingAbility, workspace:GetServerTimeNow())
                LastM1 = Now
                Stats.M1 += 1
                LastAttackAt = Now
            end

            -- Ability rotation — pick the first off-CD slot of 1..5 each tick
            for i = 1, SLOT_COUNT do
                if SlotCooldownEnd[i] <= Now then
                    Inter:FireServer("Ability", i, ShowcasingSlot, ShowcasingAbility, "Began")
                    task.wait(0.03)
                    Inter:FireServer("Ability", i, ShowcasingSlot, ShowcasingAbility, "Released")
                    if SlotCooldownEnd[i] <= tick() then
                        SlotCooldownEnd[i] = tick() + SLOT_SOFT_CD
                    end
                    Stats.AbilitiesFired += 1
                    LastAttackAt = tick()
                    break -- one per tick keeps M1 tight
                end
            end

            -- Gadget (E)
            if tick() >= GadgetCooldownEnd and GadgetSlotKey and GadgetName then
                Inter:FireServer("Gadget", GadgetSlotKey, GadgetName, "Began")
                task.wait(0.03)
                Inter:FireServer("Gadget", GadgetSlotKey, GadgetName, "Released")
                GadgetCooldownEnd = tick() + GADGET_CD
                Stats.GadgetsFired += 1
                LastAttackAt = tick()
            end

            -- Special (Q)
            if tick() >= SpecialCooldownEnd and SpecialSlotKey and SpecialName then
                Inter:FireServer("Special", SpecialSlotKey, SpecialName, "Began")
                task.wait(0.03)
                Inter:FireServer("Special", SpecialSlotKey, SpecialName, "Released")
                SpecialCooldownEnd = tick() + SPECIAL_SOFT_CD
                Stats.SpecialsFired += 1
                LastAttackAt = tick()
            end
        end)
    end
end)

-- ─── CARD PICKER ─────────────────────────────────────────────────────────────
-- Story mode drops cards between sections. Pick by priority then click via
-- FuncInteract:InvokeServer("DrawCard", CardName) — matches CardsPanel.lua:100
local CardPicking = false

local function PickFromCards(Cards)
    if CardPicking or not Cards or #Cards == 0 then return end
    if not FuncInteract then return end
    CardPicking = true
    task.spawn(function()
        task.wait(0.5)
        local Offered = {}
        for _, C in ipairs(Cards) do
            if C.CardName then Offered[C.CardName] = true end
        end
        local Pick
        for _, Want in ipairs(CARD_PRIORITY) do
            if Offered[Want] then Pick = Want break end
        end
        if not Pick then Pick = Cards[1].CardName end
        print("[StoryFarm] Picking card: " .. tostring(Pick))
        pcall(function() FuncInteract:InvokeServer("DrawCard", Pick) end)
        Stats.Cards += 1
        task.wait(5)
        CardPicking = false
    end)
end

task.spawn(function()
    Safe("CardRemoteHook", function()
        for _ = 1, 30 do
            ResolveRemotes()
            if DrawCardRemote then break end
            task.wait(1)
        end
        if not DrawCardRemote then return end
        DrawCardRemote.OnClientEvent:Connect(function(Action, Cards)
            if not Alive() then return end
            if Action == "Draw" then PickFromCards(Cards) end
        end)
        print("[StoryFarm] Card remote hook armed")
    end)
end)

-- UI poller fallback: read CardsFrame.Container children directly
task.spawn(function()
    local ok, Container = pcall(function()
        return LocalPlayer.PlayerGui:WaitForChild("HUD", 30)
            :WaitForChild("Main", 10)
            :WaitForChild("Cards", 10)
            :WaitForChild("CardsFrame", 10)
            :WaitForChild("Container", 10)
    end)
    if not ok or not Container then return end
    while true do
        task.wait(0.3)
        if not Alive() then break end
        if not Running then continue end
        local Btns = {}
        for _, C in ipairs(Container:GetChildren()) do
            if C:IsA("GuiObject") and C:GetAttribute("CardName") then
                table.insert(Btns, { CardName = C:GetAttribute("CardName") })
            end
        end
        if #Btns > 0 then PickFromCards(Btns) end
    end
end)

-- ─── GATE OPENER ─────────────────────────────────────────────────────────────
-- _LocalFX.lua:17418 — SetupGate connects Touched → fires GateHit. We have noclip
-- so Touched might not fire reliably; bypass by firing GateHit directly when
-- zombies are cleared and un-opened gates exist.
task.spawn(function()
    while true do
        task.wait(1)
        if not Alive() then break end
        if not Running then continue end
        if not IsCharValid() then continue end
        if workspace:FindFirstChild("GameFinished")     then continue end
        if workspace:FindFirstChild("Cutscene")         then continue end
        if workspace:FindFirstChild("SwitchingSection") then continue end

        -- Only when there are no live zombies in the area
        local ZF = workspace:FindFirstChild("Zombies")
        local LiveCount = 0
        if ZF then
            for _, M in ipairs(ZF:GetChildren()) do
                if IsAlive(M) then LiveCount += 1 end
            end
        end
        if LiveCount > 0 then continue end
        if tick() - LastAttackAt < IDLE_GATE_THRESHOLD then continue end

        Safe("GateOpener", function()
            local Inter = GetInteract()
            if not Inter then return end
            local Gates = CollectionService:GetTagged("GateHitbox")
            if #Gates == 0 then return end

            for _, Gate in ipairs(Gates) do
                if not Gate or not Gate.Parent then continue end
                if Gate.Parent:GetAttribute("Opened") then continue end

                local GatePart = Gate:IsA("BasePart") and Gate
                    or Gate:FindFirstChildWhichIsA("BasePart")
                if GatePart and IsCharValid() then
                    HRP.CFrame = CFrame.new(GatePart.Position + Vector3.new(0, 3, 0))
                    HRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                    task.wait(0.3)
                end
                Inter:FireServer("GateHit", Gate.Parent)
                Stats.GatesFired += 1
                print("[StoryFarm] GateHit → " .. Gate.Parent.Name)
            end
        end)
    end
end)

-- ─── FINAL ESCAPE (Shibuya Train / Impel Down Door) ─────────────────────────
-- When the "Escape ..." objective appears, TP to the map exit so the server
-- detects proximity and fires the Escaped event (_LocalFX.lua:15892).
-- Separate from GateHitbox which handles between-section gates.

local function GetEscapePart()
    local Map = workspace:FindFirstChild("Map")
    if not Map then return nil, nil end

    local Train = Map:FindFirstChild("Train")
    if Train then
        local Model = Train:FindFirstChild("Model")
        if Model then
            return Model.PrimaryPart or Model:FindFirstChildWhichIsA("BasePart"), "Train"
        end
    end

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

    return nil, nil
end

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
        task.wait(0.5)
        if not Alive() then break end
        if not Running then continue end
        if not IsCharValid() then continue end
        if workspace:FindFirstChild("GameFinished") then continue end
        if workspace:FindFirstChild("Cutscene")     then continue end

        local Active, ObjName = HasEscapeObjective()
        if not Active then continue end

        Safe("AutoEscape", function()
            local Part, Kind = GetEscapePart()
            if not Part then return end
            HRP.CFrame = Part.CFrame + Vector3.new(0, 3, 0)
            HRP.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            print("[StoryFarm] Escaping via " .. Kind .. " (" .. ObjName .. ")")
        end)
    end
end)

-- ─── AUTO REVIVE ─────────────────────────────────────────────────────────────
local LastReviveAt = 0
local function FireRevive(Source)
    if tick() - LastReviveAt < 2 then return end
    LastReviveAt = tick()
    Safe("Revive_" .. Source, function()
        local Inter = GetInteract()
        if not Inter then return end
        print("[StoryFarm] [" .. Source .. "] CanRevive → firing Revive")
        Inter:FireServer("Revive")
        Stats.Revives += 1
    end)
end

local ReviveConn = nil
local function HookRevive(Char)
    if ReviveConn then pcall(function() ReviveConn:Disconnect() end) end
    if not Char then return end
    local function Try()
        if not Alive() then return end
        if not Running then return end
        if not Char.Parent then return end
        if Char:GetAttribute("CanRevive") then FireRevive("signal") end
    end
    ReviveConn = Char:GetAttributeChangedSignal("CanRevive"):Connect(Try)
    Try()
end

task.spawn(function()
    while true do
        task.wait(0.5)
        if not Alive() then break end
        if not Running then continue end
        local Char = LocalPlayer.Character
        if not Char then continue end
        if not Char:GetAttribute("CanRevive") then continue end
        FireRevive("poll")
    end
end)

-- ─── MATCH END / PLAY AGAIN ──────────────────────────────────────────────────
local LastEndAt = 0
local function HandleMatchEnd()
    if tick() - LastEndAt < 5 then return end
    LastEndAt = tick()

    Safe("MatchEnd", function()
        Stats.MatchesCompleted += 1
        local Data = GetData()
        SendWebhook("Match Over", {
            { name = "Match #",  value = tostring(Stats.MatchesCompleted),       inline = true },
            { name = "Coins",    value = Data and tostring(Data.Coins)    or "?", inline = true },
            { name = "Level",    value = Data and tostring(Data.Level)    or "?", inline = true },
            { name = "Rebirths", value = Data and tostring(Data.Rebirths) or "?", inline = true },
            { name = "M1",       value = tostring(Stats.M1),              inline = true },
            { name = "Abilities", value = tostring(Stats.AbilitiesFired), inline = true },
            { name = "Gates",     value = tostring(Stats.GatesFired),     inline = true },
        }, 3066993)

        if not Running then return end
        local Deadline = tick() + 20
        while tick() < Deadline do
            if not Alive() then break end
            if not workspace:FindFirstChild("GameFinished") then break end
            local Inter = GetInteract()
            if Inter then Safe("PlayAgain", function() Inter:FireServer("PlayAgain") end) end
            task.wait(1)
        end
    end)
end

task.spawn(function()
    Safe("EndWatcher", function()
        if workspace:FindFirstChild("GameFinished") then HandleMatchEnd() end
        workspace.ChildAdded:Connect(function(Child)
            if not Alive() then return end
            if Child.Name == "GameFinished" then HandleMatchEnd() end
        end)
    end)
end)

-- ─── AUTO REBIRTH ────────────────────────────────────────────────────────────
task.spawn(function()
    while true do
        task.wait(10)
        if not Alive() then break end
        if not Running then continue end

        Safe("AutoRebirth", function()
            if not CanRebirth() then return end
            local Data = GetData()
            if not Data then return end
            local Inter = GetInteract()
            if not Inter then return end
            print("[StoryFarm] Rebirthing! Rebirths=" .. Data.Rebirths .. " Level=" .. Data.Level)
            Inter:FireServer("Rebirth")
            Stats.Rebirths += 1
            SendWebhook("Rebirth Performed", {
                { name = "Rebirths", value = tostring(Data.Rebirths + 1), inline = true },
                { name = "Level",    value = tostring(Data.Level),        inline = true },
                { name = "Coins",    value = tostring(Data.Coins),        inline = true },
            }, 15844367)
        end)
    end
end)

-- ─── AUTO START RAID ─────────────────────────────────────────────────────────
task.spawn(function()
    Safe("StartWatcher", function()
        local function FireStart()
            if not Alive() then return end
            if not Running then return end
            if not workspace:GetAttribute("RaidStarting") then return end
            local Inter = GetInteract()
            if not Inter then return end
            task.wait(0.5)
            Safe("VoteSkipRaid", function() Inter:FireServer("VoteSkipRaid") end)
        end
        workspace:GetAttributeChangedSignal("RaidStarting"):Connect(FireStart)
        task.wait(0.5)
        FireStart()
        print("[StoryFarm] Raid-start watcher armed")
    end)
end)

-- ─── HEARTBEAT ───────────────────────────────────────────────────────────────
task.spawn(function()
    while true do
        task.wait(HEARTBEAT_INTERVAL)
        if not Alive() then break end
        pcall(function()
            local ZF = workspace:FindFirstChild("Zombies")
            local Total, Live = 0, 0
            if ZF then
                for _, M in ipairs(ZF:GetChildren()) do
                    if M:IsA("Model") then
                        Total += 1
                        if IsAlive(M) then Live += 1 end
                    end
                end
            end

            local Section = "?"
            local MC = workspace:FindFirstChild("MatchConfig")
            if MC then
                local CS = MC:FindFirstChild("CurrentSection")
                if CS then Section = tostring(CS.Value) end
            end

            local Gates = CollectionService:GetTagged("GateHitbox")
            local GateOpen, GateClosed = 0, 0
            for _, G in ipairs(Gates) do
                if G and G.Parent then
                    if G.Parent:GetAttribute("Opened") then GateOpen += 1
                    else GateClosed += 1 end
                end
            end

            local ObjStrs = {}
            local OF = workspace:FindFirstChild("Objectives")
            if OF then
                for _, O in ipairs(OF:GetChildren()) do
                    if O.Name ~= "Template" and O.Name ~= "Title" then
                        local M = O:GetAttribute("MaxValue")
                        local V = (pcall(function() return O.Value end) and O.Value) or "?"
                        table.insert(ObjStrs, O.Name .. "[" .. tostring(V) .. (M and ("/" .. M) or "") .. "]")
                    end
                end
            end

            local SinceAttack = math.floor(tick() - LastAttackAt)
            print("[Heartbeat] live=" .. Live .. "/" .. Total
                .. " section=" .. Section
                .. " M1=" .. Stats.M1
                .. " ab=" .. Stats.AbilitiesFired
                .. " gad=" .. Stats.GadgetsFired
                .. " spec=" .. Stats.SpecialsFired
                .. " gates=" .. Stats.GatesFired
                .. " idle=" .. SinceAttack .. "s")
            print("[Heartbeat] gates(closed=" .. GateClosed .. " open=" .. GateOpen .. ")"
                .. " objectives=[" .. (#ObjStrs > 0 and table.concat(ObjStrs, ", ") or "none") .. "]")
        end)
    end
end)

-- ─── STATS ───────────────────────────────────────────────────────────────────
task.spawn(function()
    while true do
        task.wait(STATS_INTERVAL)
        if not Alive() then break end
        if not Running then continue end
        Safe("StatsReport", function()
            local Data = GetData()
            local Runtime = math.floor((tick() - Stats.StartTime) / 60)
            SendWebhook("Status Report", {
                { name = "Runtime",  value = Runtime .. " min",                 inline = true },
                { name = "Matches",  value = tostring(Stats.MatchesCompleted),  inline = true },
                { name = "Rebirths", value = tostring(Stats.Rebirths),          inline = true },
                { name = "M1",       value = tostring(Stats.M1),                inline = true },
                { name = "Abilities", value = tostring(Stats.AbilitiesFired),   inline = true },
                { name = "Gadgets",  value = tostring(Stats.GadgetsFired),      inline = true },
                { name = "Specials", value = tostring(Stats.SpecialsFired),     inline = true },
                { name = "Revives",  value = tostring(Stats.Revives),           inline = true },
                { name = "Cards",    value = tostring(Stats.Cards),             inline = true },
                { name = "Gates",    value = tostring(Stats.GatesFired),        inline = true },
                { name = "Coins",    value = Data and tostring(Data.Coins)    or "?", inline = true },
                { name = "Level",    value = Data and tostring(Data.Level)    or "?", inline = true },
                { name = "Rebirth",  value = Data and tostring(Data.Rebirths) or "?", inline = true },
            }, 7506394)
        end)
    end
end)

-- ─── CHARACTER SETUP (ForceField walk-off) ───────────────────────────────────
local function WaitForFF(Char, Timeout)
    local Deadline = tick() + (Timeout or 5)
    while tick() < Deadline do
        if not Alive() then return end
        if not Char or not Char.Parent then return end
        if not Char:FindFirstChildOfClass("ForceField") then return end
        task.wait(0.1)
    end
end

local HealthConn = nil
local function SetupCharacter(NewCharacter)
    Safe("SetupCharacter", function()
        Character = NewCharacter
        Humanoid  = NewCharacter:WaitForChild("Humanoid", 10)
        HRP       = NewCharacter:WaitForChild("HumanoidRootPart", 10)
        SlotCooldownEnd        = { 0, 0, 0, 0, 0 }
        GadgetCooldownEnd      = 0
        SpecialCooldownEnd     = 0
        LastM1                 = 0
        CurrentTarget          = nil
        ActiveTargetHPBaseline = nil
        ActiveTargetBaselineAt = nil
        LastDamageAt           = 0
        LastSeenHP             = Humanoid and Humanoid.Health

        if HealthConn then pcall(function() HealthConn:Disconnect() end) end
        if Humanoid then
            HealthConn = Humanoid.HealthChanged:Connect(function(NewHP)
                if LastSeenHP and NewHP < LastSeenHP - 0.01 then LastDamageAt = tick() end
                LastSeenHP = NewHP
            end)
        end

        HookRevive(NewCharacter)

        -- Walk forward 20 studs to break ForceField (CFrame TPs alone don't trigger it)
        Safe("WalkOutOfSpawn", function()
            if not IsCharValid() then return end
            local Target = HRP.Position + HRP.CFrame.LookVector * 20
            Humanoid:MoveTo(Target)
            local Done = false
            local Conn = Humanoid.MoveToFinished:Connect(function() Done = true end)
            local Deadline = tick() + 3
            while not Done and tick() < Deadline do
                if not Alive() then break end
                if not IsCharValid() then break end
                task.wait(0.1)
            end
            pcall(function() Conn:Disconnect() end)
        end)
        WaitForFF(NewCharacter, 5)
        print("[StoryFarm] Character ready, hunting")
    end)
end

LocalPlayer.CharacterAdded:Connect(SetupCharacter)
if Character and Character.Parent then task.spawn(SetupCharacter, Character) end

-- ─── RELOAD BUTTON (cyan) ────────────────────────────────────────────────────
local function MakeReloadButton()
    local old = LocalPlayer.PlayerGui:FindFirstChild("StoryFarmGUI")
    if old then old:Destroy() end

    local sg = Instance.new("ScreenGui")
    sg.Name           = "StoryFarmGUI"
    sg.ResetOnSpawn   = false
    sg.IgnoreGuiInset = true
    sg.Parent         = LocalPlayer.PlayerGui

    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(0, 160, 0, 38)
    btn.Position         = UDim2.new(0.5, -80, 0.5, -19)
    btn.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
    btn.TextColor3       = Color3.fromRGB(80, 220, 255)
    btn.Font             = Enum.Font.GothamBold
    btn.TextSize         = 14
    btn.Text             = "⟳  RELOAD STORY"
    btn.BorderSizePixel  = 0
    btn.Parent           = sg

    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
    local stroke = Instance.new("UIStroke", btn)
    stroke.Color     = Color3.fromRGB(80, 220, 255)
    stroke.Thickness = 1.2

    btn.MouseButton1Click:Connect(function()
        Running = false
        print("[StoryFarm] Reloading...")
        sg:Destroy()
        task.wait(0.3)
        loadstring(game:HttpGet(RAW_URL))()
    end)
end

MakeReloadButton()

-- ─── BOOT PING ───────────────────────────────────────────────────────────────
task.spawn(function()
    task.wait(2)
    pcall(function()
        SendWebhook("StoryFarm Started", {
            { name = "Session", value = tostring(MySession),         inline = true },
            { name = "Time",    value = os.date("%Y-%m-%d %H:%M:%S"), inline = true },
            { name = "Ability", value = tostring(ShowcasingAbility), inline = true },
            { name = "Gadget",  value = tostring(GadgetName),        inline = true },
            { name = "Special", value = tostring(SpecialName),       inline = true },
        }, 3447003)
    end)
end)
