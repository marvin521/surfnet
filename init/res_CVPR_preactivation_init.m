function net = res_CVPR_preactivation_init(m)
switch m,
    case 20, n = 3; opts.bottleneck = false;
    case 32, n = 5; opts.bottleneck = false;
    case 44, n = 7; opts.bottleneck = false;
    case 56, n = 9; opts.bottleneck = false;
    case 110, n = 18; opts.bottleneck = false;
    case 164,  n = 18; opts.bottleneck = true;
    case 1001,  n = 111; opts.bottleneck = true;
    otherwise, error('No configuration found for n=%d', n);
end



nClasses = 1;
ninputs  = 3;
net = dagnn.DagNN();

% Meta parameters
net.meta.inputSize = [128 128 ninputs] ;
net.meta.trainOpts.weightDecay = 0.0001 ;
net.meta.trainOpts.momentum = 0.9;
if m > 200 ,
    net.meta.trainOpts.batchSize = 64 ;
else
    net.meta.trainOpts.batchSize = 24 ;
end

net.meta.trainOpts.learningRate = [0.01*ones(1,5) 0.001*ones(1,5) 0.0001*ones(1,5) 0.00005*ones(1,5) 0.00001*ones(1,5)] ;
net.meta.trainOpts.numEpochs = numel(net.meta.trainOpts.learningRate) ;

% First conv layer 
block = dagnn.Conv('size',  [3 3 ninputs 32], 'hasBias', true, ...
    'stride', 2, 'pad', [1 1 1 1]);
lName = 'conv0';
net.addLayer(lName, block, 'image', lName, {[lName '_f'], [lName '_b']});

info.lastNumChannel = 32;
info.lastIdx = 0;

% Three groups of layers
info = add_group(net, n, info, 3, 64, 2, opts);%32
info = add_group(net, n, info, 3, 96, 2, opts);
info = add_group(net, n, info, 3, 128, 2, opts);%8
info = add_group(net, n, info, 3, 256, 2, opts);
info = add_group(net, n, info, 3, 512, 2, opts);%2

info = add_groupT(net, n, info, 3, 512, 0.5, opts);%32
info = add_groupT(net, n, info, 3, 256, 0.5, opts);
info = add_groupT(net, n, info, 3, 128, 0.5, opts);%8
info = add_groupT(net, n, info, 3, 96, 0.5, opts);
info = add_groupT(net, n, info, 3, 64, 0.5, opts);%2
info = add_groupT(net, n, info, 3, 64, 0.5, opts);%2

% Prediction & loss layers
if opts.bottleneck
add_layer_bn(net, 4*64, sprintf('sum%d',info.lastIdx), 'bn_final', 0.1);
else
add_layer_bn(net, 64, sprintf('sum%d',info.lastIdx), 'bn_final', 0.1);    
end
block = dagnn.ReLU('leak',0.2);
net.addLayer('relu_final',  block, 'bn_final', 'relu_final');

block = dagnn.Conv('size', [1 1 info.lastNumChannel nClasses], 'hasBias', true, ...
                   'stride', 1, 'pad', 0);
lName = sprintf('fc%d', info.lastIdx+1);
net.addLayer(lName, block, 'relu_final', lName, {[lName '_f'], [lName '_b']});


block = dagnn.PdistLoss('p',2,'noRoot',true,'epsilon',1e-9) ;
net.addLayer('loss', block, {lName,'label'}, 'loss');

for l=1:length(net.layers)
    if isa(net.layers(l).block, 'dagnn.Loss') || isa(net.layers(l).block, 'dagnn.PdistLoss')
        net.renameVar(net.layers(l).outputs{1}, 'loss') ;
        if isempty(regexp(net.layers(l).inputs{1}, '^prob.*'))
            net.renameVar(net.layers(l).inputs{1}, ...
                getNewVarName(net, 'prediction')) ;
        end
    end
end

net.addLayer('error', dagnn.Loss('loss', 'reg'), {'prediction','label'}, 'error') ;
net.initParams();







% Add a group of layers containing 2n/3n conv layers
function info = add_group( net, n, info, w, ch, stride, opts)

info = add_block_res(net, info, [w w info.lastNumChannel ch], stride, true, opts);
for i=2:n,
    if opts.bottleneck,
        info = add_block_res(net, info, [w w 4*ch ch], 1, false, opts);
    else
        info = add_block_res(net, info, [w w ch ch], 1, false, opts);
    end
end

% Add a group of layers containing 2n/3n conv layers
function info = add_groupT( net, n, info, w, ch, stride, opts)

info = add_block_resT(net, info, [w w info.lastNumChannel ch], stride, true, opts);
for i=2:n,
    if opts.bottleneck,
        info = add_block_res(net, info, [w w 4*ch ch], 1, false, opts);
    else
        info = add_block_res(net, info, [w w ch ch], 1, false, opts);
    end
end

% Add a smallest residual unit (2/3 conv layers)
function info = add_block_res(net, info, f_size, stride, isFirst, opts)
if isfield(info, 'lastName'),
    lName0 = info.lastName;
    info = rmfield(info, 'lastName');
elseif info.lastIdx == 0,
    lName0 = sprintf('conv0');
else
    lName0 = sprintf('sum%d',info.lastIdx);
end

lName01 = lName0;
if isFirst,
    if opts.bottleneck,
        ch = 4*f_size(4);
    else
        ch = f_size(4);
    end
    % bn & relu
    add_layer_bn(net, f_size(3), lName0, [lName0 '_bn'], 0.1);
    block = dagnn.ReLU('leak',0);
    net.addLayer([lName0 '_relu'],  block, [lName0 '_bn'], [lName0 '_relu']);
    lName0 = [lName0 '_relu'];

    % change featuremap size and chanels
    block = dagnn.Conv('size',[1 1 f_size(3) ch], 'hasBias', false,'stride',stride, ...
        'pad', 0);
    lName_tmp = lName0;
    lName0 = [lName_tmp '_down2'];
    net.addLayer(lName0, block, lName_tmp, lName0, [lName0 '_f']);
    
    pidx = net.getParamIndex([lName0 '_f']);
    net.params(pidx).learningRate = 0;
end

if opts.bottleneck,
    add_block_conv(net, sprintf('%d',info.lastIdx+1), lName01, [1 1 f_size(3) f_size(4)], stride);
    info.lastIdx = info.lastIdx + 1;
    info.lastNumChannel = f_size(4);
    add_block_conv(net, sprintf('%d',info.lastIdx+1), sprintf('conv%d',info.lastIdx), ...
        [f_size(1) f_size(2) info.lastNumChannel info.lastNumChannel], 1);
    info.lastIdx = info.lastIdx + 1;
    add_block_conv(net, sprintf('%d',info.lastIdx+1), sprintf('conv%d',info.lastIdx), ...
        [1 1 info.lastNumChannel info.lastNumChannel*4], 1);
    info.lastIdx = info.lastIdx + 1;
    info.lastNumChannel = info.lastNumChannel*4;
else
    add_block_conv(net, sprintf('%d',info.lastIdx+1), lName01, f_size, stride);
    info.lastIdx = info.lastIdx + 1;
    info.lastNumChannel = f_size(4);
    add_block_conv(net, sprintf('%d',info.lastIdx+1), sprintf('conv%d',info.lastIdx), ...
        [f_size(1) f_size(2) info.lastNumChannel info.lastNumChannel], 1);
    info.lastIdx = info.lastIdx + 1;
end

lName1 = sprintf('conv%d', info.lastIdx);

net.addLayer(sprintf('sum%d',info.lastIdx), dagnn.Sum(), {lName0,lName1}, ...
    sprintf('sum%d',info.lastIdx));

function info = add_block_resT(net, info, f_size, stride, isFirst, opts)
if isfield(info, 'lastName'),
    lName0 = info.lastName;
    info = rmfield(info, 'lastName');
elseif info.lastIdx == 0,
    lName0 = sprintf('conv0');
else
    lName0 = sprintf('sum%d',info.lastIdx);
end

lName01 = lName0;
if isFirst,
    if opts.bottleneck,
        ch = 4*f_size(4);
    else
        ch = f_size(4);
    end
    % bn & relu
    add_layer_bn(net, f_size(3), lName0, [lName0 '_bn'], 0.1);
    block = dagnn.ReLU('leak',0);
    net.addLayer([lName0 '_relu'],  block, [lName0 '_bn'], [lName0 '_relu']);
    lName0 = [lName0 '_relu'];

    % change featuremap size and chanels
    block = dagnn.ConvTranspose('size',[2 2 ch f_size(3)], 'hasBias', false,'upsample',round(1/stride), ...
        'crop', 0);

    lName_tmp = lName0;
    lName0 = [lName_tmp '_up2'];
    net.addLayer(lName0, block, lName_tmp, lName0, [lName0 '_f']);
    
    pidx = net.getParamIndex([lName0 '_f']);
    net.params(pidx).learningRate = 0;
end

if opts.bottleneck,
    add_block_convT(net, sprintf('%d',info.lastIdx+1), lName01, [2 2 f_size(4) f_size(3)], round(1/stride));
    info.lastIdx = info.lastIdx + 1;
    info.lastNumChannel = f_size(3);
    add_block_conv(net, sprintf('%d',info.lastIdx+1), sprintf('conv%d',info.lastIdx), ...
        [f_size(1) f_size(2) info.lastNumChannel info.lastNumChannel], 1);
    info.lastIdx = info.lastIdx + 1;
    add_block_conv(net, sprintf('%d',info.lastIdx+1), sprintf('conv%d',info.lastIdx), ...
        [1 1 info.lastNumChannel info.lastNumChannel*4], 1);
    info.lastIdx = info.lastIdx + 1;
    info.lastNumChannel = info.lastNumChannel*4;
else
    add_block_convT(net, sprintf('%d',info.lastIdx+1), lName01,[f_size(1)-1 f_size(2)-1 f_size(4) f_size(3)],round(1/stride));
    info.lastIdx = info.lastIdx + 1;
    info.lastNumChannel = f_size(4);
    add_block_convT(net, sprintf('%d',info.lastIdx+1), sprintf('convT%d',info.lastIdx), ...
        [f_size(1) f_size(2) info.lastNumChannel info.lastNumChannel], 1);
    info.lastIdx = info.lastIdx + 1;
end

lName1 = sprintf('convT%d', info.lastIdx);

net.addLayer(sprintf('sum%d',info.lastIdx), dagnn.Sum(), {lName0,lName1}, ...
    sprintf('sum%d',info.lastIdx));


% Add a conv layer (followed by optional batch normalization & relu)
function net = add_block_conv(net, out_suffix, in_name, f_size, stride)

lName = ['bn' out_suffix];
add_layer_bn(net, f_size(3), in_name, lName, 0.1);

block = dagnn.ReLU('leak',0);
net.addLayer(['relu' out_suffix], block, lName, ['relu' out_suffix]);

block = dagnn.Conv('size',f_size, 'hasBias',false, 'stride', stride, ...
    'pad',[ceil(f_size(1)/2-0.5) floor(f_size(1)/2-0.5) ...
    ]);
lName = ['conv' out_suffix];
net.addLayer(lName, block, ['relu' out_suffix], lName, {[lName '_f']});


% Add a conv layer (followed by optional batch normalization & relu)
function net = add_block_convT(net, out_suffix, in_name, f_size, upsample)

lName = ['bn' out_suffix];
add_layer_bn(net, f_size(4), in_name, lName, 0.1);

block = dagnn.ReLU('leak',0.2);
net.addLayer(['relu' out_suffix], block, lName, ['relu' out_suffix]);

block = dagnn.ConvTranspose('size',f_size, 'hasBias',false, 'upsample', upsample, ...
    'crop',[floor(f_size(1)/2-0.5) floor(f_size(1)/2-0.5) ...
    ]);

lName = ['convT' out_suffix];
net.addLayer(lName, block, ['relu' out_suffix], lName, {[lName '_f']});




% Add a batch normalization layer
function net = add_layer_bn(net, n_ch, in_name, out_name, lr)
block = dagnn.BatchNorm('numChannels', n_ch);
net.addLayer(out_name, block, in_name, out_name, ...
    {[out_name '_g'], [out_name '_b'], [out_name '_m']});
pidx = net.getParamIndex({[out_name '_g'], [out_name '_b'], [out_name '_m']});
net.params(pidx(1)).weightDecay = 0;
net.params(pidx(2)).weightDecay = 0;
net.params(pidx(3)).learningRate = lr;
net.params(pidx(3)).trainMethod = 'average';

function name = getNewVarName(obj, prefix)
% --------------------------------------------------------------------
t = 0 ;
name = prefix ;
while any(strcmp(name, {obj.vars.name}))
    t = t + 1 ;
    name = sprintf('%s%d', prefix, t) ;
end
