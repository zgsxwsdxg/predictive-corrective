local classic = require 'classic'
local lmdb = require 'lmdb'
local torch = require 'torch'
local __ = require 'moses'
require 'classic.torch'

local data_source = require 'data_source'
local DiskFramesHdf5LabelsDataSource =
    data_source.DiskFramesHdf5LabelsDataSource

local video_frame_proto = require 'video_util.video_frames_pb'

-- TODO(achald): Update these older data sources to use an options as input,
-- then update all callers to pass options instead of separate arguments. This
-- way we can specify the options generally in a config file.
local LabeledVideoFramesLmdbSource = classic.class(
    'LabeledVideoFramesLmdbSource', 'VideoDataSource')
function LabeledVideoFramesLmdbSource:_init(
        lmdb_path, lmdb_without_images_path, num_labels, _ --[[options]])
    --[[
    Data source for LabeledVideoFrame protobufs in LMDBs.

    Args:
       lmdb_path (str): Path to LMDB containing LabeledVideoFrames as values,
           and keys of the form "<video>-<frame_number>".
       lmdb_without_images_path (str): Path to LMDB of the same form as
           lmdb_path, but where the images have been stripped from the
           protobufs.
        num_labels (int)
    ]]--
    self.lmdb_path = lmdb_path
    self.lmdb_without_images_path = lmdb_without_images_path
    self.num_labels_ = num_labels

    self.num_keys = 0
    self.video_keys_ = {}
    local key_labels = self:key_label_map()
    for key, _ in pairs(key_labels) do
        local video, frame = self:frame_video_offset(key)
        if self.video_keys_[video] == nil then
            self.video_keys_[video] = {}
        end
        self.video_keys_[video][frame] = key
        self.num_keys = self.num_keys + 1
    end
end

function LabeledVideoFramesLmdbSource:num_samples()
    return self.num_keys
end

function LabeledVideoFramesLmdbSource:video_keys()
    return self.video_keys_
end

function LabeledVideoFramesLmdbSource:num_labels() return self.num_labels_ end

function LabeledVideoFramesLmdbSource:key_label_map(return_label_map)
    --[[
    Load mapping from frame keys to labels array.

    Note: This is a giant array, and should be destroyed as soon as it is no
    longer needed. If this array is stored permanently (e.g. globally or as an
    object attribute), it will slow down *all* future calls to collectgarbage().

    Args:
        return_label_map (bool): If true, return a map from label names to label
            id.

    Returns:
        key_labels: Table mapping frame keys to array of label indices.
        (optional) label_map: See doc for return_label_map arg.

    ]]--
    return_label_map = return_label_map == nil and false or return_label_map

    -- Get LMDB cursor.
    local db = lmdb.env { Path = self.lmdb_without_images_path }
    db:open()
    local transaction = db:txn(true --[[readonly]])
    local cursor = transaction:cursor()

    -- Create mapping from keys to labels.
    local key_label_map = {}

    local label_map = {}
    local num_keys = db:stat().entries
    for i = 1, num_keys do
        local key, value = cursor:get('MDB_GET_CURRENT')
        local video_frame = video_frame_proto.LabeledVideoFrame()
        video_frame:ParseFromString(value:storage():string())
        local num_frame_labels = #video_frame.label
        if num_frame_labels == 0 then
            -- Add frame to list of background frames.
            key_label_map[key] = {self.num_labels_ + 1}
        else
            local labels = {}
            for j, label in ipairs(video_frame.label) do
                -- Label ids start at 0.
                labels[j] = label.id + 1
                if label_map[label.name] == nil then
                    label_map[label.name] = label.id + 1
                end
            end
            key_label_map[key] = labels
        end
        if i ~= db:stat().entries then cursor:next() end
    end

    -- Cleanup.
    cursor:close()
    transaction:abort()
    db:close()

    if return_label_map then
        return key_label_map, label_map
    else
        return key_label_map
    end
end

-- luacheck: push no unused args
function LabeledVideoFramesLmdbSource:frame_video_offset(key)
    return DiskFramesHdf5LabelsDataSource.static.parse_frame_key(key)
end
-- luacheck: pop

function LabeledVideoFramesLmdbSource:load_data(keys, load_images)
    --[[
    Load images and labels for a set of keys from the LMDB.

    Args:
        keys (array): Array of array of string keys. Each element must be
            an array of the same length as every element, and contains keys for
            one step of the image sequence.
        load_images (bool): Defaults to true. If false, load only labels,
            not images. The ByteTensors in batch_images will simply be empty.

    Returns:
        batch_images: Array of array of ByteTensors
        batch_labels: ByteTensor of shape (num_steps, batch_size, num_labels)
    ]]--
    load_images = load_images == nil and true or load_images
    local db = lmdb.env {
        Path = load_images and self.lmdb_path or self.lmdb_without_images_path}
    db:open()
    local transaction = db:txn(true --[[readonly]])

    local num_steps = #keys
    local batch_size = #keys[1]
    local batch_labels = torch.ByteTensor(
        num_steps, batch_size, self.num_labels_)
    local batch_images = {}
    for step = 1, num_steps do
        batch_images[step] = {}
    end
    for i = 1, batch_size do
        for step = 1, num_steps do
            if keys[step][i] == VideoDataSource.END_OF_SEQUENCE then
                table.insert(batch_images[step],
                             VideoDataSource.END_OF_SEQUENCE)
                batch_labels[{step, i}]:zero()
            else
                -- Load LabeledVideoFrame.
                local video_frame = video_frame_proto.LabeledVideoFrame()
                video_frame:ParseFromString(
                    transaction:get(keys[step][i]):storage():string())

                -- Load image and labels.
                local img, labels =
                    LabeledVideoFramesLmdbSource._load_image_labels_from_proto(
                        video_frame)
                labels = LabeledVideoFramesLmdbSource._labels_to_tensor(
                    labels, self.num_labels_)
                table.insert(batch_images[step], img)
                batch_labels[{step, i}] = labels
            end
        end
    end

    transaction:abort()
    db:close()

    return batch_images, batch_labels
end

function LabeledVideoFramesLmdbSource.static._labels_to_tensor(
    labels, num_labels)
    --[[
    Convert an array of label ids into a 1-hot encoding in a binary Tensor.
    ]]--
    local labels_tensor = torch.ByteTensor(num_labels):zero()
    for _, label in ipairs(labels) do
        labels_tensor[label + 1] = 1 -- Label ids start at 0.
    end
    return labels_tensor
end

function LabeledVideoFramesLmdbSource.static._image_proto_to_tensor(image_proto)
    local image_storage = torch.ByteStorage()
    if image_proto.data:len() == 0 then
        return torch.ByteTensor()
    end
    image_storage:string(image_proto.data)
    return torch.ByteTensor(image_storage):reshape(
        image_proto.channels, image_proto.height, image_proto.width)
end

function LabeledVideoFramesLmdbSource.static._load_image_labels_from_proto(
        frame_proto)
    --[[
    Loads an image tensor and labels for a given key.

    Returns:
        img (ByteTensor): Image of size (num_channels, height, width).
        labels (Array): Contains numeric id for each label.
    ]]

    local img = LabeledVideoFramesLmdbSource._image_proto_to_tensor(
        frame_proto.frame.image)

    -- Load labels in an array.
    local labels = __.pluck(frame_proto.label, 'id')
    return img, labels
end

local PositiveVideosLmdbSource, PositiveVideosLmdbSourceSuper = classic.class(
    'PositiveVideosLmdbSource', 'LabeledVideoFramesLmdbSource')
function PositiveVideosLmdbSource:_init(
        lmdb_path, lmdb_without_images_path, num_labels, options)
    --[[
    Like LabeledVideoFramesLmdbSource, but only use 'positive' videos.

    A 'positive' video is a video containing at least one frame that has one of
    the options.labels labels assigned to it.

    Args:
       lmdb_path (str): Path to LMDB containing LabeledVideoFrames as values,
           and keys of the form "<video>-<frame_number>".
       lmdb_without_images_path (str): Path to LMDB of the same form as
           lmdb_path, but where the images have been stripped from the
           protobufs.
        num_labels (int): Total number of labels in the dataset.
        options:
            labels (table of strings): List of labels to consider as positive.
            output_all_labels (bool): If true, still output the groundtruth
                for all labels in the dataset - just limit the frames to be
                from positive videos. By default, this is false, and we only
                output the groundtruth for labels in options.labels.
    ]]--
    self.lmdb_path = lmdb_path
    self.lmdb_without_images_path = lmdb_without_images_path
    self.positive_label_names = options.labels
    self.output_all_labels =
        options.output_all_labels == nil and false or options.output_all_labels
    self.num_labels_ = num_labels

    self.num_keys = 0
    self.video_keys_ = {}
    local key_labels, label_map = self:_unfiltered_key_label_map()
    self.label_map = label_map -- Maps label names to ids

    for key, _ in pairs(key_labels) do
        local video, frame = DiskFramesHdf5LabelsDataSource.parse_frame_key(key)
        if self.video_keys_[video] == nil then
            self.video_keys_[video] = {}
        end
        self.video_keys_[video][frame] = key
        self.num_keys = self.num_keys + 1
    end

    self.positive_label_ids  = {}
    local positive_label_ids_set = {}
    for i, label in ipairs(self.positive_label_names) do
        positive_label_ids_set[self.label_map[label]] = true
        self.positive_label_ids[i] = self.label_map[label]
    end
    table.sort(self.positive_label_ids)

    for video, keys in pairs(self.video_keys_) do
        local positive_video = false
        for _, key in ipairs(keys) do
            for _, label_id in ipairs(key_labels[key]) do
                if positive_label_ids_set[label_id] then
                    positive_video = true
                    break
                end
            end
            if positive_video then break end
        end
        if not positive_video then self.video_keys_[video] = nil end
    end
end

function PositiveVideosLmdbSource:num_labels()
    if self.output_all_labels then
        return self.num_labels_
    else
        return #self.positive_label_ids
    end
end

function PositiveVideosLmdbSource:_unfiltered_key_label_map()
    return PositiveVideosLmdbSourceSuper.key_label_map(
        self, true --[[return_label_map]])
end

function PositiveVideosLmdbSource:key_label_map(return_label_map)
    -- Remove keys that are not in positive videos.
    local key_label_map = PositiveVideosLmdbSourceSuper.key_label_map(
        self, return_label_map)
    for key, _ in pairs(key_label_map) do
        local video, _ = self:frame_video_offset(key)
        if self.video_keys_[video] == nil then
            key_label_map[key] = nil
        end
    end
end

function PositiveVideosLmdbSource:load_data(keys, load_images)
    local batch_images, batch_labels = PositiveVideosLmdbSourceSuper.load_data(
        self, keys, load_images)
    if not self.output_all_labels then
        batch_labels = batch_labels[{{}, {}, self.positive_label_ids}]
    end
    return batch_images, batch_labels
end

local SubsampledLmdbSource, SubsampledLmdbSourceSuper = classic.class(
    'SubsampledLmdbSource', 'LabeledVideoFramesLmdbSource')
function SubsampledLmdbSource:_init(
        lmdb_path, lmdb_without_images_path, num_labels, options)
    --[[
    Subsample video to reduce the frame rate.

    Args:
       lmdb_path (str): Path to LMDB containing LabeledVideoFrames as values,
           and keys of the form "<video>-<frame_number>".
       lmdb_without_images_path (str): Path to LMDB of the same form as
           lmdb_path, but where the images have been stripped from the
           protobufs.
        num_labels (int): Total number of labels in the dataset.
        options:
            subsample_rate (int): How much to subsample the frames by.
    ]]--
    self.lmdb_path = lmdb_path
    self.lmdb_without_images_path = lmdb_without_images_path
    self.num_labels_ = num_labels
    -- The whole point is to set a subsample rate, we should mandate that it is
    -- specified.
    assert(options ~= nil and options.subsample_rate ~= nil)
    self.subsample_rate = options.subsample_rate

    self.num_keys = 0
    self.video_keys_ = {}
    local key_labels = self:key_label_map()

    for key, _ in pairs(key_labels) do
        local video, frame = self:frame_video_offset(key)
        if self.video_keys_[video] == nil then
            self.video_keys_[video] = {}
        end
        self.video_keys_[video][frame] = key
        self.num_keys = self.num_keys + 1
    end
end

function SubsampledLmdbSource:use_frame_q(frame_key)
    local _, frame_index = DiskFramesHdf5LabelsDataSource.parse_frame_key(
        frame_key)
    return ((frame_index - 1) % self.subsample_rate) == 0
end

function SubsampledLmdbSource:frame_video_offset(frame_key)
    assert(self:use_frame_q(frame_key))
    local video, frame_index = DiskFramesHdf5LabelsDataSource.parse_frame_key(
        frame_key)
    return video, (frame_index - 1) / self.subsample_rate + 1
end

function SubsampledLmdbSource:key_label_map(return_label_map)
    --[[
    Load mapping from frame keys to labels array.

    Args:
        return_label_map (bool): See LabeledVideoFramesLmdbSource:key_label_map.

    Returns:
        key_labels: See LabeledVideoFramesLmdbSource:key_label_map.
    ]]--
    local key_label_map, label_map = SubsampledLmdbSourceSuper.key_label_map(
        self, return_label_map)

    for key, _ in pairs(key_label_map) do
        if not self:use_frame_q(key) then
            key_label_map[key] = nil
        end
    end

    if return_label_map then
        return key_label_map, label_map
    else
        return key_label_map
    end
end

data_source.LabeledVideoFramesLmdbSource = LabeledVideoFramesLmdbSource
data_source.PositiveVideosLmdbSource = PositiveVideosLmdbSource
data_source.SubsampledLmdbSource = SubsampledLmdbSource
