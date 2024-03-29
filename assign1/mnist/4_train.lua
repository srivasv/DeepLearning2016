----------------------------------------------------------------------
-- This script demonstrates how to define a training procedure,
-- irrespective of the model/loss functions chosen.
--
-- It shows how to:
--   + construct mini-batches on the fly
--   + define a closure to estimate (a noisy) loss
--     function, as well as its derivatives wrt the parameters of the
--     model to be trained
--   + optimize the function, according to several optmization
--     methods: SGD, L-BFGS.
--
-- Clement Farabet
----------------------------------------------------------------------

require 'torch'   -- torch
require 'xlua'    -- xlua provides useful tools, like progress bars
require 'optim'   -- an optimization package, for online and batch methods
require 'image'

----------------------------------------------------------------------
-- parse command line arguments
if not opt then
   print '==> processing options'
   cmd = torch.CmdLine()
   cmd:text()
   cmd:text('MNIST Training/Optimization')
   cmd:text()
   cmd:text('Options:')
   cmd:option('-save', 'results', 'subdirectory to save/log experiments in')
   cmd:option('-visualize', false, 'visualize input data and weights during training')
   cmd:option('-plot', false, 'live plot')
   cmd:option('-optimization', 'ADAM', 'optimization method: SGD | ASGD | CG | LBFGS | ADAM | ADAGRAD | ADADELTA')
   cmd:option('-learningRate', 1e-3, 'learning rate at t=0')
   cmd:option('-beta1', 0.9, 'beta1 (for Adam)')
   cmd:option('-beta2', 0.999, 'beta2 (for Adam)')
   cmd:option('-epsilon', 1e-8, 'epsilon (for Adam)')
   cmd:option('-batchSize', 1, 'mini-batch size (1 = pure stochastic)')
   cmd:option('-weightDecay', 0, 'weight decay (SGD only)')
   cmd:option('-momentum', 0, 'momentum (SGD only)')
   cmd:option('-t0', 1, 'start averaging at t0 (ASGD only), in nb of epochs')
   cmd:option('-maxIter', 2, 'maximum nb of iterations for CG and LBFGS')
   cmd:text()
   opt = cmd:parse(arg or {})
end

----------------------------------------------------------------------
-- CUDA?
if opt.type == 'cuda' then
   model:cuda()
   criterion:cuda()
end

----------------------------------------------------------------------
print '==> defining some tools'

-- classes
classes = {'1','2','3','4','5','6','7','8','9','0'}

-- This matrix records the current confusion across classes
confusion = optim.ConfusionMatrix(classes)

-- Log results to files
trainLogger = optim.Logger(paths.concat(opt.save, 'train.log'))
testLogger = optim.Logger(paths.concat(opt.save, 'test.log'))

-- Retrieve parameters and gradients:
-- this extracts and flattens all the trainable parameters of the mode
-- into a 1-dim vector
if model then
   parameters,gradParameters = model:getParameters()
end

----------------------------------------------------------------------
print '==> configuring optimizer'

if opt.optimization == 'CG' then
   optimState = {
      maxIter = opt.maxIter
   }
   optimMethod = optim.cg

elseif opt.optimization == 'LBFGS' then
   optimState = {
      learningRate = opt.learningRate,
      maxIter = opt.maxIter,
      nCorrection = 10
   }
   optimMethod = optim.lbfgs

elseif opt.optimization == 'SGD' then
   optimState = {
      learningRate = opt.learningRate,
      weightDecay = opt.weightDecay,
      momentum = opt.momentum,
      learningRateDecay = 1e-7
   }
   optimMethod = optim.sgd

elseif opt.optimization == 'ASGD' then
   optimState = {
      eta0 = opt.learningRate,
      t0 = trsize * opt.t0
   }
   optimMethod = optim.asgd

elseif opt.optimization == 'ADAM' then
   optimState = {
      learningRate = opt.learningRate,
      beta1 = opt.beta1,
      beta2 = opt.beta2,
      epsilon = opt.epsilon
   }
   optimMethod = optim.adam

elseif opt.optimization == 'ADAGRAD' then
   optimState = {
      learningRate = opt.learningRate,
   }
   optimMethod = optim.adagrad

elseif opt.optimization == 'ADADELTA' then
   optimState = {
      -- rho = ... interpolation parameter, add if needed
      -- eps = ... for numerical stability, add if needed
   }
   optimMethod = optim.adadelta

else
   error('unknown optimization method')
end

----------------------------------------------------------------------
print '==> defining training procedure'

function train()

   -- epoch tracker
   epoch = epoch or 1

   -- local vars
   local time = sys.clock()

   -- set model to training mode (for modules that differ in training and testing, like Dropout)
   model:training()

   -- shuffle at each epoch
   shuffle = torch.randperm(trsize)

   -- do one epoch
   print('==> doing epoch on training data:')
   print("==> online epoch # " .. epoch .. ' [batchSize = ' .. opt.batchSize .. ']')
   for t = 1,trainData:size(),opt.batchSize do
      -- disp progress
      xlua.progress(t, trainData:size())

      -- create mini batch
      local inputs = {}
      local targets = {}
      for i = t,math.min(t+opt.batchSize-1,trainData:size()) do
         -- load new sample
         local input = trainData.data[shuffle[i]]:clone()
         local height = input:size(2)
         local width = input:size(3)

         input[{1,{},{}}]:mul(std)
         input[{1,{},{}}]:add(mean)

         -- elastic distortion sigma =4.5-6.5 alpha=[0-36]
         local warpfield = torch.Tensor(2,height,width)
         local grid_y = torch.ger(torch.linspace(0,height,height),torch.ones(width))
         local grid_x = torch.ger(torch.ones(height),torch.linspace(0,width,width))
         local displacement_x = torch.Tensor(height,width):randn(height,width)
         local displacement_y = torch.Tensor(height,width):randn(height,width)
         local sigma = torch.randn(1):add(5.5)[1]
         local gauss = image.gaussian(5,sigma,1)
         displacement_x = image.convolve(displacement_x,gauss,"same")
         displacement_y = image.convolve(displacement_y,gauss,"same")
         local alpha = torch.random(0,6)^2
         -- normalize the displacements to 1
         displacement_x:mul(alpha/displacement_x:norm());
         displacement_y:mul(alpha/displacement_y:norm());
         grid_x:add(displacement_x);
         grid_y:add(displacement_y);
         warpfield[1] = grid_y
         warpfield[2] = grid_x
         input = image.warp(input,warpfield,'bilinear',false)
         -- Rotate between -15 and 15 degrees
         input = image.rotate(input, torch.rand(1):mul(math.pi/8):add(-math.pi/16)[1])
         -- Shear by tan(-15) and tan(15) degrees
         warpfield = torch.Tensor(2,height,width)
         grid_y = torch.ger(torch.linspace(0,height,height),torch.ones(width))
         grid_x = torch.ger(torch.ones(height),torch.linspace(0,width,width))
         local beta = torch.rand(1):mul(math.pi/6):add(-math.pi/12)[1]
         local displacement = torch.mul(grid_y,math.tan(beta))
         displacement:add(-height*math.tan(beta)/2);
         grid_x:add(displacement);
         warpfield[1] = grid_y
         warpfield[2] = grid_x
         input = image.warp(input,warpfield,'bilinear',false)
         -- translate +/- 3 pixels
         input = image.translate(input, torch.random(-2,2), torch.random(-2,2))

         input[{1,{},{}}]:add(-mean)
         input[{1,{},{}}]:div(std)

         local target = trainData.labels[shuffle[i]]
         if opt.type == 'double' then input = input:double()
         elseif opt.type == 'cuda' then input = input:cuda() end
         table.insert(inputs, input)
         table.insert(targets, target)
      end

      -- create closure to evaluate f(X) and df/dX
      local feval = function(x)
                       -- get new parameters
                       if x ~= parameters then
                          parameters:copy(x)
                       end

                       -- reset gradients
                       gradParameters:zero()

                       -- f is the average of all criterions
                       local f = 0

                       -- evaluate function for complete mini batch
                       for i = 1,#inputs do
                          -- estimate f
                          local output = model:forward(inputs[i])
                          local err = criterion:forward(output, targets[i])
                          f = f + err

                          -- estimate df/dW
                          local df_do = criterion:backward(output, targets[i])
                          model:backward(inputs[i], df_do)

                          -- update confusion
                          confusion:add(output, targets[i])
                       end

                       -- normalize gradients and f(X)
                       gradParameters:div(#inputs)
                       f = f/#inputs

                       -- return f and df/dX
                       return f,gradParameters
                    end

      -- optimize on current mini-batch
      if optimMethod == optim.asgd then
         _,_,average = optimMethod(feval, parameters, optimState)
      else
         optimMethod(feval, parameters, optimState)
      end
   end

   -- time taken
   time = sys.clock() - time
   time = time / trainData:size()
   print("\n==> time to learn 1 sample = " .. (time*1000) .. 'ms')

   -- print confusion matrix
   print(confusion)

   -- update logger/plot
   trainLogger:add{['% mean class accuracy (train set)'] = confusion.totalValid * 100}
   if opt.plot then
      trainLogger:style{['% mean class accuracy (train set)'] = '-'}
      trainLogger:plot()
   end

   saveModel = model:clone()
   local obj = {
           model = saveModel:float(),
           mean = mean,
           std = std
   }
   -- save/log current net
   local filename = paths.concat(opt.save, 'tempmodel.net')
   os.execute('mkdir -p ' .. sys.dirname(filename))
   print('==> saving model to '..filename)
   torch.save(filename, obj)

   -- next epoch
   confusion:zero()
   epoch = epoch + 1
end
