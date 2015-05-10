%%
% From LSTM hidden state to loss: forward + backward passes.
%
% From the point of view of the model graph structure, this method handles
% all subgraphs from the LSTM hiddent state to the softmax predictions,
% i.e., there can be other intermediate layers for the case of positional
% models, attention functions, and softmax compression.
%
% Thang Luong @ 2015, <lmthang@stanford.edu>
%%
function [allCosts, allGrads, grad_tgt_ht] = hid2lossCostGrad(model, params, trainData, softmaxVecAll, h2sInfoAll) %topHidVecs)
  curBatchSize = params.curBatchSize;
  T = trainData.T;
  srcMaxLen = trainData.srcMaxLen;
  tgtMaxLen = trainData.tgtMaxLen;
  
  % init grads
  %[allGrads] = initSoftmaxGrad(model, params);
  if trainData.isTest == 0 && (params.epoch>=params.decodeUpdateEpoch || params.decodeUpdateOpt==2)
    if params.attnFunc || params.posModel==3
      allGrads.srcHidVecs = zeroMatrix([params.lstmSize, curBatchSize, params.numSrcHidVecs], params.isGPU, params.dataType);
    end
  else
    allGrads = 0;
  end
  grad_tgt_ht = cell(1, tgtMaxLen);
  
  % init costs
  allCosts.total = zeroMatrix([1, 1], params.isGPU, params.dataType);
  if params.posModel>=0
    allCosts.word = zeroMatrix([1, 1], params.isGPU, params.dataType);
    allCosts.pos = zeroMatrix([1, 1], params.isGPU, params.dataType);
  end
    
  % attention
  if params.attnFunc
    if params.attnRelativePos==0 % absolute position
      startAttnId = 1;
      endAttnId = params.numSrcHidVecs;
      startHidId = params.numAttnPositions-params.numSrcHidVecs+1;
      endHidId = params.numAttnPositions;
      trainData.absSrcHidVecs = zeroMatrix([params.lstmSize, params.curBatchSize, params.numAttnPositions], params.isGPU, params.dataType);
      trainData.absSrcHidVecs(:, :, startHidId:endHidId) = trainData.srcHidVecs;
    end
  end
  
  %% predict words from srcMaxLen to T
  for tt=srcMaxLen:T
    tgtPos = (tt-srcMaxLen+1);
    curMask = trainData.maskInfo{tt};
    
    % predicted words
    predWords = trainData.tgtOutput(:, tgtPos)';
    
    % predict
    if params.posModel>=1 && mod(tgtPos, 2)==1 % positions
      predWords = predWords - params.startPosId + 1;
      isPredictPos = 1;
      matrixName = 'W_softPos';
    else % words
      isPredictPos = 0;
      matrixName = 'W_soft';
    end
    
    softmax_h = softmaxVecAll{tgtPos};
    h2sInfo = h2sInfoAll{tgtPos};
    
    %% softmax_h -> loss
    [cost, probs, scores, scoreIndices] = softmaxLayerForward(model.(matrixName), softmax_h, predWords, curMask);
    
    % assert
    if params.assert
      assert(sum(sum(abs(scores(:, curMask.maskedIds))))==0);
    end
    
    %% costs
    allCosts.total = allCosts.total + cost;
    if params.posModel>=0 % separate out pos/word perplexities
      if mod(tgtPos, 2)==0
        allCosts.word = allCosts.word + cost;
      else
        allCosts.pos = allCosts.pos + cost;
      end
    end
    
    %% update grads
    if trainData.isTest==0
      % loss -> softmax_h
      [grad_W_soft, grad_softmax_h] = softmaxLayerBackprop(model.(matrixName), softmax_h, probs, scoreIndices);
      
      % update W_soft
      if params.epoch>=params.decodeUpdateEpoch || params.decodeUpdateOpt==2 
        if tt==srcMaxLen || (params.posModel>=1 && tt==(srcMaxLen+1))
          allGrads.(matrixName) = grad_W_soft;
        else
          allGrads.(matrixName) = allGrads.(matrixName) + grad_W_soft;
        end
      end
      
      % assert
      if params.assert
        assert(sum(sum(abs(grad_softmax_h(:, curMask.maskedIds))))==0);
      end
    
      % softmax_h -> h_t
      if params.attnFunc || params.softmaxDim>0 || (params.posModel==3 && isPredictPos==0) % position 3, predict words
        [grad_tgt_ht{tgtPos}, hid2softGrad, grad_srcHidVecs] = hid2softLayerBackprop(model, grad_softmax_h, trainData, h2sInfo, softmax_h, ...
          isPredictPos, params);
        
        fields = fieldnames(hid2softGrad);
        for ii=1:length(fields)
          field = fields{ii};
          if tt==srcMaxLen || (params.posModel==3 && tgtPos==2) % for posModel 3, this is the first position that we predict words
            allGrads.(field) = hid2softGrad.(field);
          else
            allGrads.(field) = allGrads.(field) + hid2softGrad.(field);
          end
        end

        % attention models: srcHidVecs
        if params.attnFunc
          if params.attnRelativePos % relative
            startAttnId = h2sInfo.startAttnId;
            endAttnId = h2sInfo.endAttnId;
            startHidId = h2sInfo.startHidId;
            endHidId = h2sInfo.endHidId;
          end
          allGrads.srcHidVecs(:, :, startAttnId:endAttnId) = allGrads.srcHidVecs(:, :, startAttnId:endAttnId) + grad_srcHidVecs(:, :, startHidId:endHidId);
        end

        % positional model 3, predict words
        if params.posModel==3 && isPredictPos==0
          allGrads.srcHidVecs(h2sInfo.linearIndices) = allGrads.srcHidVecs(h2sInfo.linearIndices) + reshape(grad_srcHidVecs(:, curMask.unmaskedIds), 1, []);
        end
      else
        grad_tgt_ht{tgtPos} = grad_softmax_h;
      end
      
      % assert
      if params.assert
        assert(sum(sum(abs(grad_tgt_ht{tgtPos}(:, curMask.maskedIds))))==0);
      end
    end
  end
end

%[cost, grad_W_soft, grad_softmax_h] = soft2lossCostGrad(model.(matrixName), softmax_h, predWords, params, trainData.isTest, curMask);
% function [cost, grad_W, inGrad] = soft2lossCostGrad(W, inVec, predLabels, params, isTest, curMask) %
% %%%
% %
% % Perform softmax prediction and backprop.
% %   matrixName: 'W_soft' for predicting words (mostly used), and
% %               'W_softPos' for predicting positions.
% % When param.numClasses>0: perform class-based softmax. origPredLabels are class
% %   labels. Predicting class labels is like predicting words in the regular
% %   softmax. Besides, we need to predict the inclass word indices.
% %
% %%%
%   mask = curMask.mask;
%   unmaskedIds = curMask.unmaskedIds;
%   maskedIds = curMask.maskedIds;  
%   
%   %% softmax_h -> predictions
%   [probs, scores, norms] = softmax(W*inVec, mask);
%   % cost
%   predLabels = predLabels(unmaskedIds);
%   
%   scoreIndices = sub2ind(size(scores), predLabels, unmaskedIds); % 1 * length(tgtPredictedWords)
%   cost = - sum(scores(scoreIndices)) + sum(log(norms).*mask);
%   
%   %% grad
%   if isTest==0 % compute grad
%     %% loss -> grad_softmax_h
%     probs(scoreIndices) = probs(scoreIndices) - 1; % minus one at predicted words
% 
%     % softmax_h
%     inGrad = W'* probs;
%     
%     % W_soft
%     grad_W = probs*inVec';
%     
%     % assert
%     if params.assert
%       assert(sum(sum(abs(scores(:, maskedIds))))==0);
%       assert(sum(sum(abs(inGrad(:, maskedIds))))==0);
%     end
%   else
%     grad_W = [];
%     inGrad = [];
%   end % end isTest
% end

% function [softmaxGrad] = initSoftmaxGrad(model, params)
%   for ii=1:length(params.softmaxVars)
%     field = params.softmaxVars{ii};
%     softmaxGrad.(field) = zeroMatrix(size(model.(field)), params.isGPU, params.dataType);
%   end
% end

%% class-based softmax %%
% after forward prediction and before cost
%     if params.numClasses>0 % class-based
%       predClasses = mod(predWords, params.numClasses) + 1;
%       predInClasses = floor((predWords-1)/params.numClasses + 1e-9) + 1;
%       [word_cost, word_softmaxGrad, grad_ht , otherBatchGrads] = batchSoftmax('W_soft_class', h_t, predClasses, model, params, trainData, batchData, 0, curMask, predInClasses);
%     else % normal softmax
%     end
% backprop, before grad_ht
%       % class-based softmax
%       if params.numClasses>0 
%         otherGrads.W_soft_inclass(:, :, otherBatchGrads.indices) = otherGrads.W_soft_inclass(:, :, otherBatchGrads.indices) + otherBatchGrads.W_soft_inclass;
%         otherGrads.classIndices = unique([otherGrads.classIndices otherBatchGrads.indices]);
%       end
% in initSoftmaxGrad()
%   if params.numClasses == 0 % normal
%   else % class-based
%     otherGrads.W_soft_inclass = zeroMatrix(size(model.W_soft_inclass), params.isGPU, params.dataType);
%     otherGrads.classIndices = [];
%   end
% in batchSoftmax(), right after cost
%   % class-based softmax
%   if params.numClasses > 0
%     predInClass = varargin{1};
%     predInClass = predInClass(unmaskedIds);
%     
%     % in class loss
%     % model.W_soft_inclass(:,:,curClasses): classSize * softmaxSize * batchSize
%     % softmax_h: softmaxSize * batchSize
%     % inClassRaw: classSize * batchSize (sum across softmaxSize, dim 2)
%     curClasses = origPredLabels;
%     inClassRaw = reshape(sum(bsxfun(@times, model.W_soft_inclass(:,:,curClasses), permute(softmax_h, [3 1 2])), 2), params.classSize, params.curBatchSize);
%     [inClassProbs, inClassScores, inClassNorms] = softmax(inClassRaw, mask);
%     
%     inClassScoreIndices = sub2ind(size(inClassScores), predInClass, unmaskedIds);
%     inClassCost = - sum(inClassScores(inClassScoreIndices)) + sum(log(inClassNorms).*mask);
%     
%     cost = cost + inClassCost;
%   end
% in batchSoftmax(), grad_softmax_h
%     % class-based softmax
%     if params.numClasses > 0 
%       inClassProbs(inClassScoreIndices) = inClassProbs(inClassScoreIndices) - 1;
% 
%       % W_soft_inclass(:,:,curClasses): classSize * softmaxSize * batchSize
%       % inClassProbs: classSize * batchSize
%       % grad_softmax_h: softmaxSize * batchSize (sum across classSize, dim 1)
%       grad_softmax_h = grad_softmax_h + squeeze(sum(bsxfun(@times, model.W_soft_inclass(:,:,curClasses), permute(inClassProbs, [1 3 2])), 1));
%     end
% in batchSoftmax(), after computing softmaxGrad.(matrixName)
%     if params.numClasses>0 % class-based softmax
%       numWords = length(unmaskedIds);
%       % inClassProbs(:, unmaskedIds): classSize * numWords
%       % softmax_h(:, unmaskedIds): softmaxSize * numWords
%       % W_soft_inclass: classSize * softmaxSize * numWords
%       W_soft_inclass_grads = bsxfun(@times, permute(inClassProbs(:, unmaskedIds),[1 3 2]), permute(softmax_h(:, unmaskedIds),[3 1 2]));
%       
%       % grad.W_soft_inclass: (classSize * softmaxSize) * numWords
%       W_soft_inclass_grads = reshape(W_soft_inclass_grads, [params.classSize*params.softmaxSize numWords]);
%       
%       % accumulate
%       [otherBatchGrads.W_soft_inclass, otherBatchGrads.indices] = aggregateMatrix(W_soft_inclass_grads, curClasses(unmaskedIds), params.isGPU, params.dataType);
%       otherBatchGrads.W_soft_inclass = reshape(otherBatchGrads.W_soft_inclass, [params.classSize params.softmaxSize length(otherBatchGrads.indices)]);
%     end
% assert    
%     if params.numClasses > 0
%         assert(sum(sum(abs(inClassScores(:, maskedIds))))==0);
%     end

%% Unused
  
%   if params.attnFunc>0 % attention mechanism
%     [softmax_h, interSoftInput, attn_h_concat, alignWeights] = lstm2softHid(h_t, params, model, batchData.srcHidVecs, curMask);
%     if params.assert && ~isempty(maskedIds)
%       assert(sum(sum(abs(attn_h_concat(:, maskedIds))))==0);
%     end
%   elseif params.posModel==3 % positional model
%     [softmax_h, interSoftInput] = lstm2softHid(h_t, params, model, isPredictPos, batchData.srcPosVecs); %, curMask);
%   else
%     [softmax_h, interSoftInput] = lstm2softHid(h_t, params, model);
%   end


%         % f'(softmax_h).*grad_softmax_h
%         tmpResult = params.nonlinear_f_prime(softmax_h).*grad_softmax_h;
% 
%         % grad.W_h
%         softmaxGrad.W_h = tmpResult*interSoftInput';
% 
%         if params.softmaxDim>0
%           % grad_ht
%           grad_ht = model.W_h'*tmpResult;
%         else
%           % grad_srcPosH: [srcPosVecs; h_t]
%           grad_srcPosH = model.W_h'*tmpResult;
%           
%           % grad_ht
%           grad_ht = grad_srcPosH(params.lstmSize+1:end, :);
%           
%           % grad srcPosVecs
%           otherBatchGrads.srcPosVecs = grad_srcPosH(1:params.lstmSize, :);
%         end

    
    %% loss -> W_soft. 
    % Note: do not move this part up; otherwise, the case attnFunc>0 will
    % fail because softmaxGrad is only created after calling attnBackprop,
    % which means anything touches softmaxGrad before will be lost.
    %softmaxGrad.(matrixName) = probs*softmax_h';
    

%     % note params.numAttnPositions>=params.numSrcHidVecs
%     batchData.srcHidVecs = zeroMatrix([params.lstmSize, params.curBatchSize, params.numAttnPositions], params.isGPU, params.dataType);
%     if params.attnFunc==1
%       if params.isReverse % reverse
% %         startAttnId = 1;
% %         endAttnId = params.numSrcHidVecs;
%         startAttnId = params.numAttnPositions-params.numSrcHidVecs+1;
%         endAttnId = params.numAttnPositions;
%         startHidId = params.numAttnPositions-params.numSrcHidVecs+1;
%         endHidId = params.numAttnPositions;
%       else % normal
%         startAttnId = 1;
%         endAttnId = params.numSrcHidVecs;
%         startHidId = 1;
%         endHidId = params.numSrcHidVecs;
%       end
%       batchData.srcHidVecs(:, :, startHidId:endHidId) = trainData.srcHidVecs;
%     end
  
%   if params.posModel==2
%     otherGrads.allEmbIndices(wordCount+1:end) = [];
%     otherGrads.allEmbGrads(:, wordCount+1:end) = [];  
%     otherGrads.wordCount = wordCount;
%   end

  % positional
%   if params.posModel==2
%     wordCount = 0;
%     otherGrads.allEmbGrads = zeroMatrix([params.lstmSize, trainData.numInputWords], params.isGPU, params.dataType);
%     otherGrads.allEmbIndices = zeros(trainData.numInputWords, 1);
%   end
    
%         if params.posModel==3 % hidden states
%           [linearIndices] = getTensorLinearIndices(srcHidVecs, curMask.unmaskedIds, batchData.colIndices);
%           softmaxGrad.srcHidVecs(batchData.linearIndices) = softmaxGrad.srcHidVecs(batchData.linearIndices) + reshape(otherBatchGrads.srcPosVecs(:, curMask.unmaskedIds), 1, []);
%         elseif params.posModel==2 % embeddings
%           numWords = length(batchData.srcEmbIndices);
%           otherGrads.allEmbIndices(wordCount+1:wordCount+numWords) = batchData.srcEmbIndices;
%           otherGrads.allEmbGrads(:, wordCount+1:wordCount+numWords) = otherBatchGrads.srcPosVecs(:, curMask.unmaskedIds);        
%           wordCount = wordCount + numWords;
%         end
