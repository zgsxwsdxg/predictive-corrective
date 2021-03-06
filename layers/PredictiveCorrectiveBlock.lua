local log = require 'util/log'
local nn = require 'nn'
local torch = require 'torch'
require 'dpnn'

local PredictiveCorrectiveBlock, parent = torch.class(
    'nn.PredictiveCorrectiveBlock', 'nn.Sequential')

function PredictiveCorrectiveBlock:__init(
        init, update, init_threshold, max_update, ignore_threshold)
    --[[
    -- PredictiveCorrectiveBlock implements the following logic. Let x_1, x_2,
    -- ..., x_t be the inputs. Then, the outputs will be y_1, ..., y_t, defined
    -- by
    --     if x_t - x{t-1} > init_threshold
    --         y_t = init(x_t)
    --     else
    --         y_t = y_{t-1} + update(x_t - x_{t-1})
    --
    -- This is implemented by using a combination of nn.Sequential and
    -- nn.ConcatTable layers. A PredictiveCorrectiveBlock is a Sequential
    -- containing of 2 ConcatTable blocks and a ParallelTable block:
    -- a "differencer block" (ConcatTable), a "function block" (ParallelTable),
    -- and a "cumulative sum block" (ConcatTable).
    --
    -- The differencer implements:
    --     if reinit
    --         y_t = x_t
    --     else
    --         y_t = x_t - x_{t-1}
    --
    -- The function block takes the output of the differencer as input, and
 h   -- implements:
    --     if reinit
    --         y_t = init(x_t)
    --     else
    --         y_t = update(x_t)
    --     end
    --
    -- Finally, the cumulative sum block takes the output of the function block
    -- as input, and implements:
    --      if reinit:
    --          y_t = x_t
    --      else:
    --          y_t = y_{t-1} + x_t
    --
    -- TODO(achald): Make a periodic version of this that reinitializes every k
    -- frames, so we no longer need to use CRollingDiffTable,
    -- PeriodicResidualTable, and CCumSumTable.
    --
    -- TODO(achald): Document the parameters better!
    --
    -- ignore_threshold: If the mean squared distance between the two images is
    -- less than this, ignore the new frame and don't run our network.
    --]]
    parent.__init(self)

    self.init = init
    self.update = update
    -- We actually want this to be a pure zero-ing operation, but it's easier to
    -- implement it this way as a proof of concept.
    self.ignore = nn.Sequential()
    local init_zeroed = init:clone()
    init_zeroed:reset(0)
    self.ignore:add(init_zeroed)
    self.ignore:add(nn.MulConstant(0))

    self.init_threshold = init_threshold
    self.max_update = max_update == nil and math.huge or max_update
    self.ignore_threshold = ignore_threshold == nil and -1 or ignore_threshold

    self.differencer_blocks = nn.ConcatTable()
    self.function_blocks = nn.ParallelTable()
    self.cumulative_sum_blocks = nn.ConcatTable()
    self.modules = {self.differencer_blocks,
                    self.function_blocks,
                    self.cumulative_sum_blocks}

    self:_reset_modules()
end

function PredictiveCorrectiveBlock:_reset_clone_usability()
    for i = 1, #self.init_clones_usable do
        self.init_clones_usable[i] = true
    end
    for i = 1, #self.update_clones_usable do
        self.update_clones_usable[i] = true
    end
end

function PredictiveCorrectiveBlock:_reset_modules()
    -- Keep track of shared clones of self.init and self.residual so we can
    -- re-use them.
    self.init_clones = {self.init}
    self.init_clones_usable = {true}
    self.update_clones = {self.update}
    self.update_clones_usable = {true}
    self.is_init = {}

    self.differencer_blocks.modules = {}
    self.function_blocks.modules = {}
    self.cumulative_sum_blocks.modules = {}

    self:_add_init(1)
    -- TODO(achald): Make sure this is the correct thing to do. I added this
    -- because we want one init and update clone to be in the self.modules
    -- array, but I'm not sure if it has any unwanted side effects.
    self:_add_update(2)
end

function PredictiveCorrectiveBlock:_get_init_clone()
    for i = 1, #self.init_clones do
        if self.init_clones_usable[i] then
            self.init_clones_usable[i] = false
            return self.init_clones[i]
        end
    end
    table.insert(self.init_clones, self.init:sharedClone())
    self.init_clones_usable[#self.init_clones] = false
    return self.init_clones[#self.init_clones]
end

function PredictiveCorrectiveBlock:_get_update_clone()
    for i = 1, #self.update_clones do
        if self.update_clones_usable[i] then
            self.update_clones_usable[i] = false
            return self.update_clones[i]
        end
    end
    table.insert(self.update_clones, self.update:sharedClone())
    self.update_clones_usable[#self.update_clones] = false
    return self.update_clones[#self.update_clones]
end

function PredictiveCorrectiveBlock:_last_init(i)
    for j = i, 1, -1 do
        if self.is_init[j] then
            return j
        end
    end
    error('No init module found!')
end

function PredictiveCorrectiveBlock:_add_init(i)
    self.is_init[i] = true
    self.differencer_blocks.modules[i] = nn.SelectTable(i)
    self.function_blocks.modules[i] = self:_get_init_clone()
    self.cumulative_sum_blocks.modules[i] = nn.SelectTable(i)
end

function PredictiveCorrectiveBlock:_add_update(i)
    self.is_init[i] = false

    local differencer = nn.Sequential()
    -- Select x_{t-1}, x_t.
    differencer:add(nn.NarrowTable(i - 1, 2))
    -- Compute x_{t-1} - x_t, then multiply by -1.
    differencer:add(nn.CSubTable())
    differencer:add(nn.MulConstant(-1))

    local last_init = self:_last_init(i)
    local sum = nn.Sequential()
    sum:add(nn.NarrowTable(last_init, i - last_init + 1))
    sum:add(nn.CAddTable())

    self.differencer_blocks.modules[i] = differencer
    self.function_blocks.modules[i] = self:_get_update_clone()
    self.cumulative_sum_blocks.modules[i] = sum
end

function PredictiveCorrectiveBlock:_add_ignore(i)
    self.is_init[i] = false

    local last_init = self:_last_init(i)
    local sum = nn.Sequential()
    sum:add(nn.NarrowTable(last_init, i - last_init + 1))
    sum:add(nn.CAddTable())

    self.differencer_blocks.modules[i] = nn.Sequential():add(nn.SelectTable(i))
    self.function_blocks.modules[i] = self.ignore
    self.cumulative_sum_blocks.modules[i] = sum
end

function PredictiveCorrectiveBlock:updateOutput(input)
    self:_reset_clone_usability()
    self.differencer_blocks.modules = {}
    self.function_blocks.modules = {}
    self.cumulative_sum_blocks.modules = {}
    self.is_init = {}

    local ignored = 0
    self:_add_init(1)
    for i = 2, #input do
        local pixel_difference = (
            (input[i] - input[i-1]):norm() / input[i]:nElement())
        if pixel_difference > self.init_threshold or
                (i - self:_last_init(i) == self.max_update) then
            self:_add_init(i)
        elseif pixel_difference > self.ignore_threshold then
            self:_add_update(i)
        else
            ignored = ignored + 1
            self:_add_ignore(i)
        end
    end

    local num_init = 0
    for i = 1, #input do
        if self.is_init[i] then
            num_init = num_init + 1
        end
    end
    if ignored > 0 then
        log.info(string.format('Ignored %d out of %d times.', ignored, #input))
    end
    log.info(string.format(
        'Reinitialized %d out of %d times.', num_init, #input))
    self:type(self._type)
    if self._training then self:training() else self:evaluate() end

    return parent.updateOutput(self, input)
end

function PredictiveCorrectiveBlock:updateGradInput(input, gradOutput)
    return parent.updateGradInput(self, input, gradOutput)
end

function PredictiveCorrectiveBlock:accGradParameters(input, gradOutput, scale)
    return parent.accGradParameters(self, input, gradOutput, scale)
end

function PredictiveCorrectiveBlock:accUpdateGradParameters(input, gradOutput, lr)
    return parent.accUpdateGradParameters(self, input, gradOutput, lr)
end

function PredictiveCorrectiveBlock:type(type, tensorCache)
    self._type = type
    return parent.type(self, type, tensorCache)
end

function PredictiveCorrectiveBlock:training()
    parent.training(self)
    self._training = true
end

function PredictiveCorrectiveBlock:evaluate()
    parent.evaluate(self)
    self._training = false
end

function PredictiveCorrectiveBlock:clearState()
    self:_reset_modules()
    parent.clearState(self)
end

function PredictiveCorrectiveBlock:__tostring__()
    local str = torch.type(self)
    str = str .. ' { reinitialize_threshold: ' .. self.init_threshold .. ' }'
    return str
end

function PredictiveCorrectiveBlock:read(file, versionNumber)
    parent.read(self, file, versionNumber)
    if self.ignore_threshold == nil then
        self.ignore_threshold = -1
    end
    if self.ignore == nil then
        -- We actually want this to be a pure zero-ing operation, but it's easier to
        -- implement it this way as a proof of concept.
        self.ignore = nn.Sequential()
        local init_zeroed = self.init:clone()
        init_zeroed:reset(0)
        self.ignore:add(init_zeroed)
        self.ignore:add(nn.MulConstant(0))
    end
    if self.max_update == nil then
        self.max_update = math.huge
    end
end
