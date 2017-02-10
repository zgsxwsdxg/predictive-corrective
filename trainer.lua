local classic = require 'classic'
local cudnn = require 'cudnn'
local cunn = require 'cunn'
local cutorch = require 'cutorch'
local optim = require 'optim'
local paths = require 'paths'
local torch = require 'torch'

local evaluator = require 'evaluator'
local image_util = require 'util/image_util'
local END_OF_SEQUENCE = require('data_loader').END_OF_SEQUENCE

local Trainer = classic.class('Trainer')

function Trainer:_init(args)
    --[[
    Args:
        model
        criterion
        train_data_loader
        val_data_loader
        input_dimension_permutation: Array, default nil.
            Specifies what each dimension in the input tensor corresponds to.
            By default, the input dimension order is
              (sequence_length, batch_size, num_channels, width, height)
            A permutation of [2, 3, 1, 4, 5], for example, results in
              (batch_size, num_channels, seuquence_length, width, height)
        pixel_mean
        batch_size
        computational_batch_size
        crop_size
        learning_rates: Array of tables containing keys 'start_epoch',
            'learning_rate'. E.g.
                [{start_epoch: 1, learning_rate: 1e-2},
                 {start_epoch: 6, learning_rate: 1e-3}]
            will use a learning rate of 1e-2 for the first 5 epochs, then switch
            to a learning rate of 1e-3.
        num_labels
        momentum
        weight_decay
        optim_config: Optional
        optim_state: Optional
    ]]--
    self.model = args.model
    self.criterion = args.criterion
    self.train_data_loader = args.train_data_loader
    self.val_data_loader = args.val_data_loader
    -- Only use input permutation if it is not the identity.
    for i = 1, 5 do
        if args.input_dimension_permutation ~= nil
                and args.input_dimension_permutation[i] ~= i then
            self.input_dimension_permutation = args.input_dimension_permutation
            break
        end
    end
    self.pixel_mean = torch.Tensor(args.pixel_mean)
    self.batch_size = args.batch_size
    self.computational_batch_size = args.computational_batch_size
    self.crop_size = args.crop_size
    self.num_labels = args.num_labels
    self.weight_decay = args.weight_decay
    self.learning_rates = args.learning_rates

    -- Preallocate GPU inputs.
    self.gpu_inputs = torch.CudaTensor()
    self.gpu_labels = torch.CudaTensor()

    if args.optim_config then
        self.optimization_config = args.optim_config
    else
        self.optimization_config = {
            learningRateDecay = 0.0,
            momentum = args.momentum,
            dampening = 0.0,
            learningRate = nil, -- set by update_optim_config
            weightDecay = nil -- set by update_optim_config
        }
    end
    if args.optim_state then
        self.optimization_state = args.optim_state
    else
        self.optimization_state = {}
    end
    -- These variables view into the model's parameters, so that changes to the
    -- model's parameters are automatically reflected in them, and vice versa.
    self.model_parameters, self.model_grad_parameters =
        self.model:getParameters()

    -- Prefetch the next batch.
    self.train_data_loader:fetch_batch_async(self.batch_size)
    self.val_data_loader:fetch_batch_async(self.batch_size)
end

function Trainer:update_optim_config(epoch)
    local learning_rate, regime_was_updated = self:_epoch_learning_rate(epoch)
    self.epoch_base_learning_rate = learning_rate
    if regime_was_updated then
        self.optimization_config.learningRate = learning_rate
        self.optimization_config.weightDecay = self.weight_decay
        self.optimization_state = nil
        collectgarbage()
        collectgarbage()
        self.optimization_state = {}
    end
    return regime_was_updated
end

function Trainer:train_epoch(epoch, num_batches)
    self:_train_or_evaluate_epoch(epoch, num_batches, true --[[train_mode]])
end

function Trainer:evaluate_epoch(epoch, num_batches)
    self:_train_or_evaluate_epoch(epoch, num_batches, false --[[train_mode]])
end

function Trainer:train_batch()
    --[[
    Train on a batch of data

    Returns:
        loss: Output of criterion:forward on this batch.
        outputs (Tensor): Output of model:forward on this batch. The tensor
            size should be either (sequence_length, batch_size, num_labels) or
            (batch_size, num_labels), depending on the model.
        labels (Tensor): True labels. Same size as the outputs.
    ]]--
    local images, labels = self:_load_batch(
        self.train_data_loader, true --[[train_mode]])

    local loss = 0
    local outputs
    local function forward_backward()
        self.model:zeroGradParameters()
        for i = 1, math.ceil(self.batch_size / self.computational_batch_size) do
            local start_index = (i - 1) * self.computational_batch_size + 1
            local end_index = math.min(
                i * self.computational_batch_size, self.batch_size)
            local current_loss, current_outputs =
                self:_forward_backward(
                    images[{{}, {start_index, end_index}}],
                    labels[{{}, {start_index, end_index}}],
                    true --[[train_mode]])
            -- The loss is averaged by the computational batch size; we want to
            -- average by the actual batch size.
            loss = loss + current_loss
            if outputs == nil then
                outputs = current_outputs:clone()
            else
                -- If the outputs are 3D, then they must be (sequence_length,
                -- batch_size, num_labels). Otherwise, they are 2D and of shape
                -- (batch_size, num_labels).
                local batch_dimension = current_outputs:dim() == 3 and 2 or 1
                outputs = torch.cat(outputs, current_outputs, batch_dimension)
            end
        end
        return loss, self.model_grad_parameters
    end
    -- Updates self.model_parameters (and, in turn, the parameters of
    -- self.model) in place.
    optim.sgd(forward_backward, self.model_parameters,
              self.optimization_config, self.optimization_state)
    return loss, outputs, labels
end

function Trainer:evaluate_batch()
    --[[
    Returns:
        loss: Output of criterion:forward on this batch.
        outputs (Tensor): Output of model:forward on this batch. The tensor
            size is (sequence_length, batch_size, num_labels)
        labels (Tensor): True labels. Same size as the outputs.
    ]]--
    local images, labels = self:_load_batch(
        self.val_data_loader, false --[[train_mode]])
    local loss, outputs = self:_forward_backward(
        images, labels, false --[[train_mode]])
    self.gpu_inputs:resize(0)
    self.gpu_labels:resize(0)
    return loss, outputs, labels
end

function Trainer:save(directory, epoch)
    --[[
    Save model, optimization config, and optimization config to a directory.
    ]]--
    -- Clear intermediate states in the model before saving to disk to minimize
    -- disk space usage.
    self.model:clearState()
    local model = self.model
    if torch.isTypeOf(self.model, 'nn.DataParallelTable') then
        model = model:get(1)
    end
    torch.save(paths.concat(directory, 'model_' .. epoch .. '.t7'), model)
    torch.save(paths.concat(directory, 'optim_config_' .. epoch .. '.t7'),
               self.optimization_config)
    torch.save(paths.concat(directory, 'optim_state_' .. epoch .. '.t7'),
               self.optimization_state)
    collectgarbage()
    collectgarbage()
end

function Trainer:_train_or_evaluate_epoch(epoch, num_batches, train_mode)
    if train_mode then
        self.model:clearState()
        self.model:training()
        self:update_optim_config(epoch)
    else
        self.model:evaluate()
    end

    local epoch_timer = torch.Timer()
    local batch_timer = torch.Timer()

    local predictions = torch.Tensor(
        num_batches * self.batch_size, self.num_labels)
    local groundtruth = torch.ByteTensor(
        num_batches * self.batch_size, self.num_labels)

    local process_batch = train_mode and self.train_batch or self.evaluate_batch
    local loss_epoch = 0
    for batch_index = 1, num_batches do
        batch_timer:reset()
        collectgarbage()
        collectgarbage()
        local loss, curr_predictions, curr_groundtruth = process_batch(self)
        loss_epoch = loss_epoch + loss

        -- We only care about the predictions and groundtruth in the last step
        -- of the sequence.
        if curr_predictions:dim() == 3 and curr_predictions:size(1) > 1 then
            curr_predictions = curr_predictions[curr_predictions:size(1)]
        end
        if curr_groundtruth:dim() == 3 and curr_groundtruth:size(1) > 1 then
            curr_groundtruth = curr_groundtruth[curr_groundtruth:size(1)]
        end

        -- Collect current predictions and groundtruth.
        local epoch_index_start = (batch_index - 1) * self.batch_size + 1
        predictions[{{epoch_index_start,
                      epoch_index_start + self.batch_size - 1},
                      {}}] = curr_predictions:type(predictions:type())
        groundtruth[{{epoch_index_start,
                      epoch_index_start + self.batch_size - 1},
                      {}}] = curr_groundtruth

        if train_mode then
            local log_string = string.format(
                '%s: Epoch: [%d] [%d/%d] \t Time %.3f Loss %.4f',
                os.date('%X'), epoch, batch_index, num_batches,
                batch_timer:time().real, loss)
            if batch_index % 10 == 0 then
                local current_mean_average_precision =
                    evaluator.compute_mean_average_precision(
                        predictions[{{1, epoch_index_start + self.batch_size - 1}}],
                        groundtruth[{{1, epoch_index_start + self.batch_size - 1}}])
                log_string = log_string .. string.format(
                    ' epoch mAP %.4f', current_mean_average_precision)
            end
            log_string = log_string .. string.format(
                ' LR %.0e', self.epoch_base_learning_rate)
            print(log_string)
        end
    end

    local mean_average_precision = evaluator.compute_mean_average_precision(
        predictions, groundtruth)
    predictions = nil
    groundtruth = nil
    collectgarbage()
    collectgarbage()

    local mode_str = train_mode and 'TRAINING' or 'EVALUATION'

    print(string.format(
        '%s: Epoch: [%d][%s SUMMARY] Total Time(s): %.2f\t' ..
        'average loss (per batch): %.5f \t mAP: %.5f',
        os.date('%X'), epoch, mode_str, epoch_timer:time().real, loss_epoch /
        num_batches, mean_average_precision))
end

function Trainer:_load_batch(data_loader, train_mode)
    local images_table, labels = data_loader:load_batch(self.batch_size)
    -- Prefetch the next batch.
    data_loader:fetch_batch_async(self.batch_size)

    local num_steps = #images_table
    local num_channels = images_table[1][1]:size(1)
    local images = torch.Tensor(num_steps, self.batch_size, num_channels,
                                self.crop_size, self.crop_size)
    local augment = train_mode and image_util.augment_image_train
                               or image_util.augment_image_eval
    for step, step_images in ipairs(images_table) do
        for sequence, img in ipairs(step_images) do
            -- Process image after converting to the default Tensor type.
            -- (Originally, it is a ByteTensor).
            images[{step, sequence}] = augment(img:typeAs(images),
                                               self.crop_size,
                                               self.crop_size,
                                               self.pixel_mean)
        end
    end
    return images, labels
end

function Trainer:_forward_backward(images, labels, train_mode)
    --[[
    Run forward (and possibly backward) pass on images.

    Args:
        images ((sequence_length, batch_size, num_channels, width, height))
        labels: Subset of output of data_loader:load_batch()
        train_mode (bool): If true, perform backward pass as well.
    ]]--
    local num_images = images:size(2)
    if self.input_dimension_permutation then
        images = images:permute(unpack(self.input_dimension_permutation))
    end

    self.gpu_inputs:resize(images:size()):copy(images)
    self.gpu_labels:resize(labels:size()):copy(labels)

    local outputs = self.model:forward(self.gpu_inputs)
    -- If the output of the network is a single prediction for the sequence,
    -- compare it to the label of the last frame.
    if (outputs:size(1) == 1 or outputs:dim() == 2) and
            self.gpu_labels:size(1) ~= 1 then
        self.gpu_labels = self.gpu_labels[self.gpu_labels:size(1)]
    end
    local loss = self.criterion:forward(outputs, self.gpu_labels) * (
        num_images / self.batch_size)

    if train_mode then
        local criterion_gradients = self.criterion:backward(
            outputs, self.gpu_labels)
        self.model:backward(
            self.gpu_inputs, criterion_gradients, num_images / self.batch_size)
        self.gpu_inputs:resize(0)
    end
    return loss, outputs
end

function Trainer:_epoch_learning_rate(epoch)
    --[[
    Compute learning rate and weight decay regime for a given epoch.

    Args:
        epoch (num)
    Returns:
        params: Contains params.learning_rate and params.weight_decay
        is_new_regime: True if this marks the beginning of new parameters.
    --]]

    local regime
    for i = 1, #self.learning_rates - 1 do
        local start_epoch = self.learning_rates[i].start_epoch
        local end_epoch = self.learning_rates[i+1].start_epoch
        if epoch >= start_epoch and epoch < end_epoch then
            regime = self.learning_rates[i]
            break
        end
    end
    if regime == nil then
        regime = self.learning_rates[#self.learning_rates]
    end
    local is_new_regime = epoch == regime.start_epoch
    return regime.learning_rate, is_new_regime
end

local SequentialTrainer, SequentialTrainerSuper = classic.class(
    'SequentialTrainer', Trainer)
function SequentialTrainer:_init(args)
    if args.input_dimension_permutation ~= nil then
        for i = 1, #args do
            if args.input_dimension_permutation[i] ~= i then
                error('SequentialTrainer does not support ' ..
                      'input_dimension_permutation')
            end
        end
    end
    SequentialTrainerSuper._init(self, args)
    assert(self.batch_size == 1,
          'Currently, SequentialTrainer only supports batch size = 1. ' ..
          'See the "recurrent_batched_training" branch for some WIP on ' ..
          'allowing the batch size to be greater than 1.')
    assert(self.model:findModules('nn.Sequencer') ~= nil,
           'SequentialTrainer requires that the input model be decorated ' ..
           'with nn.Sequencer.')
    assert(torch.isTypeOf(self.criterion, 'nn.SequencerCriterion'),
           'SequentialTrainer expects SequencerCriterion.')
    self.model:remember('both')
end

function SequentialTrainer:_train_or_evaluate_batch(train_mode)
    --[[
    Train or evaluate on a batch of data.

    Returns:
        loss: Output of criterion:forward on this batch.
        outputs (Tensor): Output of model:forward on this batch. The tensor
            size should be either (sequence_length, 1, num_labels). The
            sequence_length may be shorter at the end of the sequence (if the
            sequence ends before we get enough frames).
        labels (Tensor): True labels. Same size as the outputs.
        sequence_ended (bool): If true, specifies that this batch ends the
            sequence.
    ]]--
    local data_loader
    if train_mode then
        self.model:zeroGradParameters()
        data_loader = self.train_data_loader
    else
        data_loader = self.val_data_loader
    end

    local images_table, labels, keys = data_loader:load_batch(
        1 --[[batch size]], true)
    if images_table[1][1] == END_OF_SEQUENCE then
        -- The sequence ended at the end of the last batch; reset the model and
        -- start loading the next sequence in the next batch.
        for step = 1, #images_table do
            -- The rest of the batch should be filled with END_OF_SEQUENCe.
            assert(images_table[step][1] == END_OF_SEQUENCE)
        end
        self.model:forget()
        return nil, nil, nil, true --[[sequence_ended]]
    end
    -- Prefetch the next batch.
    data_loader:fetch_batch_async(1 --[[batch size]])

    local num_steps = #images_table
    local num_channels = images_table[1][1]:size(1)
    local images = torch.Tensor(num_steps, 1 --[[batch size]], num_channels,
                                self.crop_size, self.crop_size)
    local num_valid_steps = num_steps
    for step, step_images in ipairs(images_table) do
        local img = step_images[1]
        if img == END_OF_SEQUENCE then
            -- We're out of frames for this sequence.
            num_valid_steps = step - 1
            break
        else
            -- Process image after converting to the default Tensor type.
            -- (Originally, it is a ByteTensor).
            images[step] = image_util.augment_image_train(
                img:typeAs(images), self.crop_size, self.crop_size,
                self.pixel_mean)
        end
    end
    local sequence_ended = num_valid_steps ~= num_steps
    if sequence_ended then
        labels = labels[{{1, num_valid_steps}}]
        images = images[{{1, num_valid_steps}}]
        for step = num_valid_steps + 1, #images_table do
            -- The rest of the batch should be filled with END_OF_SEQUENCe.
            assert(images_table[step][1] == END_OF_SEQUENCE)
        end
    end

    self.gpu_inputs:resize(images:size()):copy(images)
    self.gpu_labels:resize(labels:size()):copy(labels)

    local loss, outputs
    if train_mode then
        local function model_forward_backward(_)
            -- Should be of shape (sequence_length, batch_size, num_classes)
            outputs = self.model:forward(self.gpu_inputs)
            loss = self.criterion:forward(outputs, self.gpu_labels)
            local criterion_gradients = self.criterion:backward(
                outputs, self.gpu_labels)
            if criterion_gradients:norm() <= 1e-5 then
                print('Criterion gradients small:', criterion_gradients:norm())
            end
            self.model:backward(self.gpu_inputs, criterion_gradients)
            return loss, self.model_grad_parameters
        end

        -- Updates self.model_parameters (and, in turn, the parameters of
        -- self.model) in place.
        optim.sgd(model_forward_backward, self.model_parameters,
                self.optimization_config, self.optimization_state)
    else
        -- Should be of shape (sequence_length, batch_size, num_classes)
        outputs = self.model:forward(self.gpu_inputs)
        loss = self.criterion:forward(outputs, self.gpu_labels)
    end
    if sequence_ended then
        self.model:forget()
    end
    return loss, outputs, labels, sequence_ended
end

function SequentialTrainer:_train_or_evaluate_epoch(
    epoch, num_sequences, train_mode)
    if train_mode then
        self.model:clearState()
        self.model:training()
        self:update_optim_config(epoch)
    else
        self.model:evaluate()
    end
    local epoch_timer = torch.Timer()
    local batch_timer = torch.Timer()

    local predictions, groundtruth

    local epoch_loss = 0
    for sequence = 1, num_sequences do
        batch_timer:reset()
        collectgarbage()
        local sequence_ended = false
        local sequence_predictions, sequence_groundtruth
        local sequence_loss = 0
        local num_steps_in_sequence = 0
        io.write(sequence)
        while not sequence_ended do
            local loss, batch_predictions, batch_groundtruth, sequence_ended_ =
                self:_train_or_evaluate_batch(train_mode)
            -- HACK: Assign to definition outside of while loop.
            sequence_ended = sequence_ended_
            if loss == nil then
                assert(sequence_ended)
                break
            end
            sequence_loss = sequence_loss + loss

            assert(torch.isTensor(batch_predictions))
            -- Remove sequence dimension.
            num_steps_in_sequence = num_steps_in_sequence +
                batch_predictions:size(1)
            batch_predictions = batch_predictions[{{}, 1}]
            batch_groundtruth = batch_groundtruth[{{}, 1}]
            if sequence_predictions == nil then
                sequence_predictions = batch_predictions
                sequence_groundtruth = batch_groundtruth
            else
                sequence_predictions = torch.cat(
                    sequence_predictions, batch_predictions, 1)
                sequence_groundtruth = torch.cat(
                    sequence_groundtruth, batch_groundtruth, 1)
            end
            io.write('>')
        end
        io.write('x\n')
        epoch_loss = epoch_loss + sequence_loss
        if train_mode then
            local sequence_mean_average_precision =
                evaluator.compute_mean_average_precision(
                    sequence_predictions, sequence_groundtruth)
            print(string.format(
                '%s: Epoch: [%d] [%d/%d] \t Time %.3f Loss %.4f ' ..
                'seq mAP %.4f LR %.0e',
                os.date('%X'), epoch, sequence, num_sequences,
                batch_timer:time().real, sequence_loss,
                sequence_mean_average_precision, self.epoch_base_learning_rate))
        end
        if predictions == nil then
            predictions = sequence_predictions
            groundtruth = sequence_groundtruth
        else
            predictions = torch.cat(predictions, sequence_predictions, 1)
            groundtruth = torch.cat(groundtruth, sequence_groundtruth, 1)
        end
        collectgarbage()
        collectgarbage()
    end

    local mean_average_precision = evaluator.compute_mean_average_precision(
        predictions, groundtruth)

    local mode_str = train_mode and 'TRAINING' or 'EVALUATION'
    print(string.format(
        '%s: Epoch: [%d][%s SUMMARY] Total Time(s): %.2f\t' ..
        'average loss (per batch): %.5f \t mAP: %.5f',
        os.date('%X'), epoch, mode_str, epoch_timer:time().real,
        epoch_loss / num_sequences, mean_average_precision))
    collectgarbage()
    collectgarbage()
end

return {Trainer = Trainer, SequentialTrainer = SequentialTrainer}
