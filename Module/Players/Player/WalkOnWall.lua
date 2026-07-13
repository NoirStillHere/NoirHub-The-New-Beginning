local GravityController = {}
GravityController.__index = GravityController

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local LocalPlayer = Players.LocalPlayer

local ZERO_VECTOR = Vector3.new(0, 0, 0)
local UNIT_Y = Vector3.new(0, 1, 0)
local IDENTITY_CFRAME = CFrame.new()

local JUMP_MODIFIER = 1.2
local TRANSITION_SPEED = 0.15
local WALK_FORCE = 200 / 3

local LOWER_RADIUS_OFFSET = 3
local NUM_DOWN_RAYS = 24
local ODD_DOWN_RAY_START_RADIUS = 3
local EVEN_DOWN_RAY_START_RADIUS = 2
local ODD_DOWN_RAY_END_RADIUS = 1.66666
local EVEN_DOWN_RAY_END_RADIUS = 1

local NUM_FEELER_RAYS = 9
local FEELER_LENGTH = 2
local FEELER_START_OFFSET = 2
local FEELER_RADIUS = 3.5
local FEELER_APEX_OFFSET = 1
local FEELER_WEIGHTING = 8

local PI2 = math.pi * 2

local function getRotationBetween(u, v, axis)
    local dot, uxv = u:Dot(v), u:Cross(v)
    if dot < -0.99999 then
        return CFrame.fromAxisAngle(axis, math.pi)
    end
    return CFrame.new(0, 0, 0, uxv.x, uxv.y, uxv.z, 1 + dot)
end

local function lookAt(pos, forward, up)
    local r = forward:Cross(up)
    local u = r:Cross(forward)
    return CFrame.fromMatrix(pos, r.Unit, u.Unit)
end

local function getMass(array)
    local mass = 0
    for _, part in ipairs(array) do
        if part:IsA("BasePart") then
            mass = mass + part:GetMass()
        end
    end
    return mass
end

local StateTracker = {}
StateTracker.__index = StateTracker

function StateTracker.new(humanoid)
    local self = setmetatable({}, StateTracker)
    
    self.Humanoid = humanoid
    self.HRP = humanoid.RootPart
    self.Speed = 0
    self.State = "onRunning"
    self.Jumped = false
    self.JumpTick = tick()
    
    self._ChangedEvent = Instance.new("BindableEvent")
    self.Changed = self._ChangedEvent.Event
    
    return self
end

function StateTracker:Destroy()
    self._ChangedEvent:Destroy()
end

function StateTracker:RequestedJump()
    self.Jumped = true
    self.JumpTick = tick()
end

function StateTracker:OnStep(gravityUp, grounded, isMoving)
    local cVelocity = self.HRP.Velocity
    local gVelocity = cVelocity:Dot(gravityUp) * gravityUp
    
    local oldState = self.State
    local newState
    local newSpeed = cVelocity.Magnitude
    
    if not grounded then
        if gVelocity.Y > 0 then
            if self.Jumped then
                newState = "onJumping"
            else
                newState = "onFreeFall"
            end
        else
            if self.Jumped then
                self.Jumped = false
            end
            newState = "onFreeFall"
        end
    else
        if self.Jumped and tick() - self.JumpTick > 0.1 then
            self.Jumped = false
        end
        newSpeed = (cVelocity - gVelocity).Magnitude
        newState = "onRunning"
    end
    
    newSpeed = isMoving and newSpeed or 0
    
    if oldState ~= newState then
        self.State = newState
        self.Speed = newSpeed
        self._ChangedEvent:Fire(self.State, self.Speed)
    end
end

local AnimationHandler = {}
AnimationHandler.__index = AnimationHandler

function AnimationHandler.new(humanoid)
    local self = setmetatable({}, AnimationHandler)
    self.Humanoid = humanoid
    return self
end

function AnimationHandler:Run(name, speed)
    -- Xử lý animation dựa trên trạng thái
    local humanoid = self.Humanoid
    if not humanoid then return end
    
    if name == "onRunning" then
        if speed > 0.5 then
            humanoid.WalkSpeed = 16
        end
    elseif name == "onJumping" then
        -- Jump animation
    elseif name == "onFreeFall" then
        -- Fall animation
    end
end

function GravityController.new(player)
    local self = setmetatable({}, GravityController)
    
    -- Player and character
    self.Player = player or LocalPlayer
    self.Character = self.Player.Character
    if not self.Character then
        self.Player.CharacterAdded:Wait()
        self.Character = self.Player.Character
    end
    
    self.Humanoid = self.Character:WaitForChild("Humanoid")
    self.HRP = self.Character:WaitForChild("HumanoidRootPart")
    
    -- Camera smoothness
    self.CameraSmoothness = 0.15
    
    -- Animation
    self.AnimationHandler = AnimationHandler.new(self.Humanoid)
    
    -- State tracker
    self.StateTracker = StateTracker.new(self.Humanoid)
    self.StateTracker.Changed:Connect(function(name, speed)
        self.AnimationHandler:Run(name, speed)
    end)
    
    -- Collider và forces
    local collider, gyro, vForce, floor = self:CreateObjects()
    self.Collider = collider
    self.VForce = vForce
    self.Gyro = gyro
    self.Floor = floor
    
    -- Attachment to parts
    self.LastPart = Workspace.Terrain
    self.LastPartCFrame = IDENTITY_CFRAME
    
    -- Gravity properties
    self.GravityUp = UNIT_Y
    self.Ignores = {self.Character}
    
    -- Mass
    self.CharacterMass = getMass(self.Character:GetDescendants())
    self.Character.AncestryChanged:Connect(function()
        self.CharacterMass = getMass(self.Character:GetDescendants())
    end)
    
    -- Events
    self.Humanoid.PlatformStand = true
    
    self.JumpCon = RunService.RenderStepped:Connect(function(dt)
        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
            self:OnJumpRequest()
        end
    end)
    
    self.DeathCon = self.Humanoid.Died:Connect(function()
        self:Destroy()
    end)
    
    self.SeatCon = self.Humanoid.Seated:Connect(function(active)
        if active then
            self:Destroy()
        end
    end)
    
    self.HeartCon = RunService.Heartbeat:Connect(function(dt)
        self:OnHeartbeatStep(dt)
    end)
    
    RunService:BindToRenderStep("GravityStep", Enum.RenderPriority.Input.Value + 1, function(dt)
        self:OnGravityStep(dt)
    end)
    
    -- Register hotkey để bật/tắt
    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if input.KeyCode == Enum.KeyCode.Z then
            self:Destroy()
            return
        end
    end)
    
    return self
end

function GravityController:CreateObjects()
    local hrp = self.HRP
    local humanoid = self.Humanoid
    local isR15 = (humanoid.RigType == Enum.HumanoidRigType.R15)
    local height = isR15 and (humanoid.HipHeight + 0.05) or 2
    
    -- Sphere (collider)
    local sphere = Instance.new("Part")
    sphere.Size = Vector3.new(2, 2, 2)
    sphere.Anchored = false
    sphere.CanCollide = true
    sphere.Material = Enum.Material.SmoothPlastic
    sphere.Transparency = 1
    
    local weld1 = Instance.new("Weld")
    weld1.C0 = CFrame.new(0, -height, 0.1)
    weld1.Part0 = hrp
    weld1.Part1 = sphere
    weld1.Parent = sphere
    
    -- Floor (ground detector)
    local floor = Instance.new("Part")
    floor.Size = Vector3.new(1, 1, 1)
    floor.Anchored = false
    floor.CanCollide = true
    floor.Material = Enum.Material.SmoothPlastic
    floor.Transparency = 1
    
    local weld2 = Instance.new("Weld")
    weld2.C0 = CFrame.new(0, -(height + 1.5), 0)
    weld2.Part0 = hrp
    weld2.Part1 = floor
    weld2.Parent = floor
    
    -- BodyGyro
    local gyro = Instance.new("BodyGyro")
    gyro.CFrame = hrp.CFrame
    gyro.MaxTorque = Vector3.new(1e5, 1e5, 1e5)
    gyro.D = 1000
    gyro.P = 10000
    gyro.Parent = hrp
    
    -- VectorForce
    local vForce = Instance.new("VectorForce")
    vForce.ApplyAtCenterOfMass = false
    vForce.RelativeTo = Enum.ActuatorRelativeTo.World
    
    local attachment = isR15 and hrp:FindFirstChild("RootRigAttachment") or hrp:FindFirstChild("RootAttachment")
    if not attachment then
        attachment = Instance.new("Attachment")
        attachment.Parent = hrp
    end
    vForce.Attachment0 = attachment
    vForce.Parent = hrp
    
    sphere.Parent = self.Character
    floor.Parent = self.Character
    
    return sphere, gyro, vForce, floor
end

function GravityController:GetGravityUp(oldGravityUp)
    local ignoreList = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= self.Player then
            table.insert(ignoreList, player.Character)
        end
    end
    
    -- Get the normal
    local hrpCF = self.HRP.CFrame
    local isR15 = (self.Humanoid.RigType == Enum.HumanoidRigType.R15)
    
    local origin = isR15 and hrpCF.p or hrpCF.p + 0.35 * oldGravityUp
    local radialVector = math.abs(hrpCF.LookVector:Dot(oldGravityUp)) < 0.999 and 
        hrpCF.LookVector:Cross(oldGravityUp) or hrpCF.RightVector:Cross(oldGravityUp)
    
    local centerRayLength = 25
    local centerRay = Ray.new(origin, -centerRayLength * oldGravityUp)
    local centerHit, _, centerHitNormal = Workspace:FindPartOnRayWithIgnoreList(centerRay, ignoreList)
    
    local downHitCount = 0
    local centerRayHitCount = 0
    local mainDownNormal = ZERO_VECTOR
    
    if centerHit then
        mainDownNormal = centerHitNormal
        centerRayHitCount = 1
    end
    
    local downRaySum = ZERO_VECTOR
    for i = 1, NUM_DOWN_RAYS do
        local dtheta = PI2 * ((i - 1) / NUM_DOWN_RAYS)
        
        local angleWeight = 0.25 + 0.75 * math.abs(math.cos(dtheta))
        local isEvenRay = (i % 2 == 0)
        local startRadius = isEvenRay and EVEN_DOWN_RAY_START_RADIUS or ODD_DOWN_RAY_START_RADIUS
        local endRadius = isEvenRay and EVEN_DOWN_RAY_END_RADIUS or ODD_DOWN_RAY_END_RADIUS
        local downRayLength = centerRayLength
        
        local offset = CFrame.fromAxisAngle(oldGravityUp, dtheta) * radialVector
        local dir = (LOWER_RADIUS_OFFSET * -oldGravityUp + (endRadius - startRadius) * offset)
        local ray = Ray.new(origin + startRadius * offset, downRayLength * dir.unit)
        local hit, _, hitNormal = Workspace:FindPartOnRayWithIgnoreList(ray, ignoreList)
        
        if hit then
            downRaySum = downRaySum + angleWeight * hitNormal
            downHitCount = downHitCount + 1
        end
    end
    
    local feelerHitCount = 0
    local feelerNormalSum = ZERO_VECTOR
    
    for i = 1, NUM_FEELER_RAYS do
        local dtheta = PI2 * ((i - 1) / NUM_FEELER_RAYS)
        local angleWeight = 0.25 + 0.75 * math.abs(math.cos(dtheta))
        local offset = CFrame.fromAxisAngle(oldGravityUp, dtheta) * radialVector
        local dir = (FEELER_RADIUS * offset + LOWER_RADIUS_OFFSET * -oldGravityUp).unit
        local feelerOrigin = origin - FEELER_APEX_OFFSET * -oldGravityUp + FEELER_START_OFFSET * dir
        local ray = Ray.new(feelerOrigin, FEELER_LENGTH * dir)
        local hit, _, hitNormal = Workspace:FindPartOnRayWithIgnoreList(ray, ignoreList)
        
        if hit then
            feelerNormalSum = feelerNormalSum + FEELER_WEIGHTING * angleWeight * hitNormal
            feelerHitCount = feelerHitCount + 1
        end
    end
    
    if centerRayHitCount + downHitCount + feelerHitCount > 0 then
        local normalSum = mainDownNormal + downRaySum + feelerNormalSum
        if normalSum ~= ZERO_VECTOR then
            return normalSum.unit
        end
    end
    
    return oldGravityUp
end

function GravityController:OnJumpRequest()
    if not self.StateTracker.Jumped and self:IsGrounded(true) then
        local hrpVel = self.HRP.Velocity
        self.HRP.Velocity = hrpVel + self.GravityUp * self.Humanoid.JumpPower * JUMP_MODIFIER
        self.StateTracker:RequestedJump()
    end
end

function GravityController:IsGrounded(isJumpCheck)
    if not isJumpCheck then
        local parts = self.Floor:GetTouchingParts()
        for _, part in ipairs(parts) do
            if not part:IsDescendantOf(self.Character) then
                return true
            end
        end
    else
        if self.StateTracker.Jumped then
            return false
        end
        
        local valid = {}
        local parts = self.Collider:GetTouchingParts()
        for _, part in ipairs(parts) do
            if not part:IsDescendantOf(self.Character) then
                table.insert(valid, part)
            end
        end
        
        if #valid > 0 then
            local max = math.cos(self.Humanoid.MaxSlopeAngle)
            local ray = Ray.new(self.Collider.Position, -10 * self.GravityUp)
            local hit, _, normal = Workspace:FindPartOnRayWithWhitelist(ray, valid, true)
            
            if hit and max <= self.GravityUp:Dot(normal) then
                return true
            end
        end
    end
    return false
end

function GravityController:OnHeartbeatStep(dt)
    local ray = Ray.new(self.Collider.Position, -1.1 * self.GravityUp)
    local hit, _, _ = Workspace:FindPartOnRayWithIgnoreList(ray, self.Ignores)
    local lastPart = self.LastPart
    
    if hit and lastPart and lastPart == hit then
        local offset = self.LastPartCFrame:ToObjectSpace(self.HRP.CFrame)
        self.HRP.CFrame = hit.CFrame:ToWorldSpace(offset)
    end
    
    self.LastPart = hit
    self.LastPartCFrame = hit and hit.CFrame
end

function GravityController:OnGravityStep(dt)
    -- Update gravity up vector
    local oldGravity = self.GravityUp
    local newGravity = self:GetGravityUp(oldGravity)
    
    local rotation = getRotationBetween(oldGravity, newGravity, Workspace.CurrentCamera.CFrame.RightVector)
    rotation = IDENTITY_CFRAME:Lerp(rotation, self.CameraSmoothness)
    
    self.GravityUp = rotation * oldGravity
    
    -- Get world move vector
    local camCF = Workspace.CurrentCamera.CFrame
    local fDot = camCF.LookVector:Dot(newGravity)
    local cForward = math.abs(fDot) > 0.5 and -math.sign(fDot) * camCF.UpVector or camCF.LookVector
    
    local left = cForward:Cross(-newGravity).Unit
    local forward = -left:Cross(newGravity).Unit
    
    -- Get move vector từ input
    local moveVector = self:GetMoveVector()
    local worldMove = forward * moveVector.Z - left * moveVector.X
    worldMove = worldMove:Dot(worldMove) > 1 and worldMove.Unit or worldMove
    
    local isInputMoving = worldMove:Dot(worldMove) > 0
    
    -- Get the desired character CFrame
    local hrpCFLook = self.HRP.CFrame.LookVector
    local charF = hrpCFLook:Dot(forward) * forward + hrpCFLook:Dot(left) * left
    local charR = charF:Cross(newGravity).Unit
    local newCharCF = CFrame.fromMatrix(ZERO_VECTOR, charR, newGravity, -charF)
    
    local newCharRotation = IDENTITY_CFRAME
    if isInputMoving then
        newCharRotation = IDENTITY_CFRAME:Lerp(getRotationBetween(charF, worldMove, newGravity), 0.7)
    end
    
    -- Calculate forces
    local g = Workspace.Gravity
    local gForce = g * self.CharacterMass * (UNIT_Y - newGravity)
    
    local cVelocity = self.HRP.Velocity
    local tVelocity = self.Humanoid.WalkSpeed * worldMove
    local gVelocity = cVelocity:Dot(newGravity) * newGravity
    local hVelocity = cVelocity - gVelocity
    
    if hVelocity:Dot(hVelocity) < 1 then
        hVelocity = ZERO_VECTOR
    end
    
    local dVelocity = tVelocity - hVelocity
    local walkForceM = math.min(10000, WALK_FORCE * self.CharacterMass * dVelocity.Magnitude / (dt * 60))
    local walkForce = walkForceM > 0 and dVelocity.Unit * walkForceM or ZERO_VECTOR
    
    -- Mouse lock
    local charRotation = newCharRotation * newCharCF
    
    -- Get state
    self.StateTracker:OnStep(self.GravityUp, self:IsGrounded(), isInputMoving)
    
    -- Update values
    self.VForce.Force = walkForce + gForce
    self.Gyro.CFrame = charRotation
end

function GravityController:GetMoveVector()
    local moveVector = ZERO_VECTOR
    
    if UserInputService:IsKeyDown(Enum.KeyCode.W) then
        moveVector = moveVector + Vector3.new(0, 0, -1)
    end
    if UserInputService:IsKeyDown(Enum.KeyCode.S) then
        moveVector = moveVector + Vector3.new(0, 0, 1)
    end
    if UserInputService:IsKeyDown(Enum.KeyCode.A) then
        moveVector = moveVector + Vector3.new(-1, 0, 0)
    end
    if UserInputService:IsKeyDown(Enum.KeyCode.D) then
        moveVector = moveVector + Vector3.new(1, 0, 0)
    end
    
    return moveVector
end

function GravityController:Destroy()
    if self.JumpCon then
        self.JumpCon:Disconnect()
        self.JumpCon = nil
    end
    if self.DeathCon then
        self.DeathCon:Disconnect()
        self.DeathCon = nil
    end
    if self.SeatCon then
        self.SeatCon:Disconnect()
        self.SeatCon = nil
    end
    if self.HeartCon then
        self.HeartCon:Disconnect()
        self.HeartCon = nil
    end
    
    RunService:UnbindFromRenderStep("GravityStep")
    
    if self.Collider then
        self.Collider:Destroy()
        self.Collider = nil
    end
    if self.VForce then
        self.VForce:Destroy()
        self.VForce = nil
    end
    if self.Gyro then
        self.Gyro:Destroy()
        self.Gyro = nil
    end
    if self.Floor then
        self.Floor:Destroy()
        self.Floor = nil
    end
    if self.StateTracker then
        self.StateTracker:Destroy()
        self.StateTracker = nil
    end
    
    self.Humanoid.PlatformStand = false
    self.GravityUp = UNIT_Y
end

return GravityController
