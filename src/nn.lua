
totem.nn = {}

local isTensor = totem._isTensor

local function inputType(t)
    return type(t) == 'table' and t[1]:type() or t:type()
end


local function appendParamPairs(paramPairs, input, gradInput, namePrefix)
    if input == nil then
        return
    end
    if gradInput == nil or gradInput == false then
        print("\nWARNING: ignored gradInput: %s", namePrefix)
        return
    end

    if isTensor(input) then
        table.insert(paramPairs, {input, gradInput, namePrefix})
        return
    end

    for i = 1, #input do
        local subname = string.format("%s[%s]", namePrefix, i)
        appendParamPairs(paramPairs, input[i], gradInput[i], subname)
    end
end

-- Returns a list of {params, gradParams} pairs.
local function extractParamTensors(module, input)
    local paramPairs = {}
    local paramTensors = module:parameters()
    if paramTensors ~= nil and #paramTensors > 0 then
        local params, gradParams = module:getParameters()
        table.insert(paramPairs, {params, gradParams, "params"})
    end

    appendParamPairs(paramPairs, input, module.gradInput, "input")
    return paramPairs
end



-- Produce random gradOutput for the given output.
-- The output can be a table of tensors.
local function produceRandomGradOutput(output)
    if isTensor(output) then
        return torch.randn(output:size()):typeAs(output)
    end

    local gradOutput = {}
    for i = 1, #output do
        table.insert(gradOutput, produceRandomGradOutput(output[i]))
    end
    return gradOutput
end



local function calcLoss(output, gradOutput)
    if isTensor(output) then
        return output.dot(output, gradOutput)
    end

    local loss = 0
    for i = 1, #output do
        loss = loss + calcLoss(output[i], gradOutput[i])
    end
    return loss
end



local function appendTensors(list, input)
    if input == nil or input == false then
        return
    end
    if isTensor(input) then
        table.insert(list, input)
        return
    end

    -- We allow an input child to be null.
    -- ipairs() is not used for the iteration.
    for i = 1, #input do
        appendTensors(list, input[i])
    end
end



-- Evaluate the module to prepare a non-null module.gradInput.
local function ensureGradInput(module, input)
    local output = module:forward(input)
    assert(module.output == output, "module.output should be returned")
    local gradOutput = produceRandomGradOutput(output)
    local gradInput = module:backward(input, gradOutput)
    assert(module.gradInput == gradInput, "module.gradInput should be returned")
end



-- Compute the numeric gradient of the loss function
-- with respect to the parameters.
local function computeNumGradParams(feval, params)
    local flatParams = params.new(params:storage())
    assert(flatParams:nElement() == params:nElement(),
        "shared storage of params is not supported")

    local numGradParams = torch.Tensor(params:nElement())
    local small = (params:type() == 'torch.DoubleTensor') and 1e-6 or 1e-3
    for i = 1, flatParams:nElement() do
        local origVal = flatParams[i]
        flatParams[i] = origVal - small
        local loss1 = feval(flatParams)
        flatParams[i] = origVal + small
        local loss2 = feval(flatParams)
        flatParams[i] = origVal

        numGradParams[i] = (loss2 - loss1) / (2 * small)
    end
    return numGradParams:reshape(params:size()):typeAs(params)
end



local function checkGrad(tester, feval, params, paramName)
    paramName = paramName or "params"
    -- feval() should return the (loss, gradParams) pair
    local _, gradParams = feval(params)
    local numGradParams = computeNumGradParams(feval, params)
    local msg = 'wrong grad w.r.t. ' .. paramName
    local precision = (params:type() == 'torch.DoubleTensor') and 1e-4 or 1e-2
    tester:assertTensorEq(gradParams, numGradParams, precision, msg)
end



-- The CopyModule is used in totem.nn.checkGradients to get
-- non-shared inputs and non-reassigned module.gradInput.
local nesting = require 'nngraph/nesting'
require 'nn'
local CopyModule, CopyModuleParent = torch.class('totem.nn.CopyModule', 'nn.Module')

function CopyModule:__init()
    CopyModuleParent.__init(self)
    self.output = nil
    self.gradInput = nil
end
    
function CopyModule:updateOutput(input)
    self.output = self.output or nesting.cloneNested(input)
    nesting.resizeNestedAs(self.output, input)
    nesting.fillNested(self.output, 0)
    nesting.addNestedTo(self.output, input)
    return self.output
end

function CopyModule:updateGradInput(input, gradOutput)
    self.gradInput = self.gradInput or nesting.cloneNested(input)
    nesting.resizeNestedAs(self.gradInput, input)
    nesting.fillNested(self.gradInput, 0)
    nesting.addNestedTo(self.gradInput, gradOutput)
    return self.gradInput
end



--[[ Checks all computed gradients, i.e., the gradient w.r.t. input and the gradient w.r.t. parameters.

Parameters:

- `module` (nn.Module instance)
- `input` input to `module`, either a tensor or a table of tensors

The module can output either a tensor or a table of tensors.
]]
function totem.nn.checkGradients(tester, module, input)
    module = nn.Sequential()
        :add(CopyModule:new())
        :add(module)

    -- A fixed seed is used for the gradient checking.
    -- The forward() pass is free to have a stochastic output.
    local rngState = torch.getRNGState()
    ensureGradInput(module, input)

    local gradOutput = produceRandomGradOutput(module.output)
    for _, pair in ipairs(extractParamTensors(module, input)) do
        local params, gradParams, paramName = unpack(pair)
        -- The gradient with respect to the parameters
        -- will be accumulated to non-zero initial gradParams.
        local initialGradParams = gradParams:clone():uniform()
        if paramName ~= "params" then
            initialGradParams:zero()
        end
        local function feval()
            torch.setRNGState(rngState)
            gradParams:copy(initialGradParams)
            module:forward(input)
            local loss = calcLoss(module.output, gradOutput)
            module:backward(input, gradOutput)
            gradParams:add(-1, initialGradParams)
            return loss, gradParams
        end

        checkGrad(tester, feval, params, paramName)
    end
end



local function debatchTensor(batchInput)
    local inputs = {}
    for rowIndex = 1, batchInput:size(1) do
        inputs[rowIndex] = batchInput[rowIndex]:clone()
    end
    return inputs
end



local function debatch(batchInput)
    if isTensor(batchInput) then
        return debatchTensor(batchInput)
    end

    -- The input can contain multiple arguments.
    -- Each argument is debatched.
    local debatched = {}
    for i, item in ipairs(batchInput) do
        debatched[i] = debatch(item)
    end

    local inputs = {}
    for rowIndex = 1, #debatched[1] do
        inputs[rowIndex] = {}
        for i, debatchedItem in ipairs(debatched) do
            inputs[rowIndex][i] = debatchedItem[rowIndex]
        end
    end
    return inputs
end



--[[ Check that minibatch and non-minibatch outputs are the same

-Parameters:

- `tester` (totem.Tester instance)
- `module` (nn.Module instance)
- `batchInput` (tensor) a batch of inputs to `module`

]]
function totem.nn.checkMinibatch(tester, module, batchInput, precision)
    precision = precision or 1e-14
    local inputs = debatch(batchInput)
    local batchOutput = module:forward(batchInput)
    local outputs = debatch(batchOutput)
    local batchGradOutput = produceRandomGradOutput(batchOutput)
    local gradOutputs = debatch(batchGradOutput)
    local batchGradInput = module:updateGradInput(batchInput, batchGradOutput)
    local gradInputs = debatch(batchGradInput)

    for i = 1, #inputs do
        local output = module:forward(inputs[i])
        tester:eq(outputs[i], output, "wrong minibatch output", precision)
        local gradInput = module:updateGradInput(inputs[i], gradOutputs[i])
        tester:eq(gradInputs[i], gradInput, "wrong minibatch gradInput", precision)
    end
end



--[[ Check that a module can be cast to another type

Parameters:

- `tester` (totem.Tester instance)
- `module` (nn.Module instance)
- `input` (tensor or table of tensors) inputs to `module`
- `toType` (optional string, default 'torch.FloatTensor') type to which module should be cast

This test fails if either the cast operation itself fails (i.e.
`module.type()`) or if the result of a forward update of the module differs
significantly before and after having been cast to `toType` and back again to
the original type.

--]]
function totem.nn.checkTypeCastable(tester, module, input, toType)
    local precision = 1e-6
    origType = inputType(input)
    toType = toType or 'torch.FloatTensor'
    local rngState = torch.getRNGState()
    local preOutput = module:updateOutput(input)
    local gradOutput = produceRandomGradOutput(preOutput)
    local preGradInput = module:updateGradInput(input, gradOutput)
    tester:assertNoError(function() module:type(toType) end, "module cannot be cast to " .. toType)
    tester:assertNoError(function() module:type(origType) end, "module cannot be base back to " .. origType)
    torch.setRNGState(rngState)
    local postOutput = module:updateOutput(input)
    local postGradInput = module:updateGradInput(input, gradOutput)
    tester:eq(preOutput, postOutput, "module output differs before and after typecast", precision)
    tester:eq(preGradInput, postGradInput, "module gradInput differs before and after typecast", precision)
end



--[[ Check that a module can be serialized and deserialized to disk

Parameters:

- `tester` (totem.Tester instance)
- `module` (nn.Module instance)
- `input` (tensor) inputs to `module`
- `gradOutput` (tensor) gradOutput to `module`

This test fails if either the serialization operation itself fails (using
`torch.save`) or if the result of a forward update of the module differs
significantly before and after a roundtrip to disk.

--]]
function totem.nn.checkSerializable(tester, module, input)
    local precision = 1e-6
    local rngState = torch.getRNGState()
    local preOutput = module:updateOutput(input)
    local gradOutput = produceRandomGradOutput(preOutput)
    local preGradInput = module:updateGradInput(input, gradOutput)
    local filename = paths.tmpname()
    tester:assertNoError(function() torch.save(filename, module) end, "module cannot be serialized")
    local module = torch.load(filename)
    torch.setRNGState(rngState)
    local postOutput = module:updateOutput(input)
    local postGradInput = module:updateGradInput(input, gradOutput)
    tester:eq(preOutput, postOutput, "module output differs before and after serialization", precision)
    tester:eq(preGradInput, postGradInput, "module gradInput differs before and after serialization", precision)
end
