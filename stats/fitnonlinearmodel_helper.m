function results = fitnonlinearmodel_helper(opt,stimulus,tmatrix,smatrix,trainfun,testfun)

% This is a helper function for fitnonlinearmodel.m.  Not for external use!
%
% Notes:
% - opt.data is always a cell vector and contains only one voxel
% - the seed to use has been hacked into model{1}{1} and may have multiple rows

% calc
ismultipleseeds = size(opt.model{1}{1},1) > 1;
ismultiplemodels = length(opt.model) > 1;

% init
results                  = struct;
results.params           = zeros(length(trainfun),size(opt.model{end}{2},2));
results.testdata         = cell(1,length(trainfun));  % but converted to a matrix at the end
results.modelpred        = cell(1,length(trainfun));  % but converted to a matrix at the end
results.trainperformance = zeros(1,length(trainfun));
results.testperformance  = zeros(1,length(trainfun));
results.aggregatedtestperformance = [];
results.numiters         = zeros(length(trainfun),size(opt.model{1}{1},1),length(opt.model));
results.resnorms         = zeros(length(trainfun),size(opt.model{1}{1},1));

% loop over resampling cases
for rr=1:length(trainfun)
  fprintf('  starting resampling case %d of %d.\n',rr,length(trainfun));

  % deal with resampling
  trainstim = feval(trainfun{rr},stimulus);
  traindata = feval(trainfun{rr},opt.data);  % result is a column vector
  trainT    = projectionmatrix(feval(trainfun{rr},tmatrix));   % NOTE: potentially slow step. make sparse? [or CACHE]
  trainS    = projectionmatrix(feval(trainfun{rr},smatrix));   % NOTE: potentially slow step. make sparse? [or CACHE]
  teststim  = feval(testfun{rr},stimulus);
  testdata  = feval(testfun{rr},opt.data);   % result is a column vector
  testT     = projectionmatrix(feval(testfun{rr},tmatrix));    % NOTE: potentially slow step. make sparse? [or CACHE]
  testS     = projectionmatrix(feval(testfun{rr},smatrix));    % NOTE: potentially slow step. make sparse? [or CACHE]

  % precompute
  traindataT = trainT*traindata;  % remove regressors from data (fitting)
  
  % deal with last-minute data division
  datastd = std(traindataT);
  if datastd == 0
    datastd = 1;
  end
  traindataT = traindataT / datastd;

  % deal with options
  options = opt.optimoptions;
  if ~isempty(opt.outputfcn)
    if nargin(opt.outputfcn) == 4
      options.OutputFcn = @(a,b,c) feval(opt.outputfcn,a,b,c,traindataT);
    else
      options.OutputFcn = opt.outputfcn;
    end
  end

  % loop over seeds
  params = [];
  for ss=1:size(opt.model{1}{1},1)
    if ismultipleseeds
      fprintf('    trying seed %d of %d.\n',ss,size(opt.model{1}{1},1));
    end
  
    % loop through models
    for mm=1:length(opt.model)
    
      % which parameters are we actually fitting?
      ix = ~isnan(opt.model{mm}{2}(1,:));

      % calculate seed, model, and transform
      if mm==1
        seed = opt.model{mm}{1}(ss,:);
        model = opt.model{mm}{3};
        transform = opt.model{mm}{4};
      else
        seed = feval(opt.model{mm}{1},params0);
        model = feval(opt.model{mm}{3},params0);
        transform = feval(opt.model{mm}{4},params0);
      end

      % in the special case that the stimulus consists of multiple frames,
      % then we have to modify model so that it averages across the
      % predicted response associated with each frame.  this is magical voodoo here.
      if size(trainstim,3) > 1
        nums = repmat(size(trainstim,3),[1 size(trainstim,1)]);
        model = @(pp,dd) chunkfun(feval(model,pp,squish(permute(dd,[3 1 2]),2)),nums,@(x) mean(x,1)).';
      end

      % figure out bounds to use
      if isequal(options.Algorithm,'levenberg-marquardt')
        lb = [];
        ub = [];
      else
        lb = opt.model{mm}{2}(1,ix);
        ub = opt.model{mm}{2}(2,ix);
      end
      
      % precompute
      trainstimTRANSFORM = feval(transform,trainstim);

      % define the final model function
      fun = @(pp) trainT*feval(model,copymatrix(seed,ix,pp),trainstimTRANSFORM);

      % report
      if ismultiplemodels
        fprintf('      for model %d of %d, the seed is [', ...
                mm,length(opt.model)); fprintf('%.3f ',seed); fprintf('].\n');
      else
        fprintf('      the seed is ['); fprintf('%.3f ',seed); fprintf('].\n');
      end

      % perform the fit (NOTICE THE DIVISION BY DATASTD AND THE NAN PROTECTION)
      % TODO: add here 
      % lsqcurvefit(FUN,X0,XDATA,YDATA,lowerBound, upperBound)
      [params0,resnorm,residual,exitflag,output] = ...
          lsqcurvefit(@(x,y) nanreplace(feval(fun,x) / datastd,0,2), ...
                      seed(ix), ...
                      [],...
                      traindataT,...
                      lb, ...
                      ub, ...
                      options);
      params0 = copymatrix(seed,ix,params0);

      % report
      fprintf('      the estimated parameters are ['); ...
        fprintf('%.3f ',params0); fprintf('].\n');
      
      % record
      results.numiters(rr,ss,mm) = output.iterations;

    end
    
    % record
    results.resnorms(rr,ss) = resnorm;  % final resnorm
    params(ss,:) = params0;             % final parameters

  end

  % which seed produced the best results?
  [d,mnix] = min(results.resnorms(rr,:));
  finalparams = params(mnix,:);
  
  % record the results
  results.params(rr,:) = finalparams;

  % report
  if ismultipleseeds
    fprintf('    seed %d was best. final estimated parameters are [',mnix); ...
      fprintf('%.3f ',finalparams); fprintf('].\n');
  end

  % prepare data and model fits 
  %   [NOTE: this inherits model, transform, and trainstimTRANSFORM from above!!]
  traindatatemp = trainS*traindata;
  modelfittemp  = nanreplace(trainS*feval(model,finalparams,trainstimTRANSFORM),0,2);
  
 
    if isempty(testdata)  % handle this case explicitly, just to avoid problems
        results.testdata{rr}  = [];
        results.modelpred{rr} = [];
    else
        results.testdata{rr}  = testS*testdata;
        results.modelpred{rr} = nanreplace(testS*feval(model,finalparams,feval(transform,teststim)),0,2);
    end
  
  
  
  
  % compute metrics
  results.trainperformance(rr) = feval(opt.metric,modelfittemp,traindatatemp);
  if isempty(results.testdata{rr})  % handle this case explicitly, just to avoid problems
    results.testperformance(rr) = NaN;
  else
    results.testperformance(rr) = feval(opt.metric,results.modelpred{rr},results.testdata{rr});
  end

end

% compute aggregated metrics
results.testdata  = catcell(1,results.testdata);
results.modelpred = catcell(1,results.modelpred);
if isempty(results.testdata)
  results.aggregatedtestperformance = NaN;
else
  results.aggregatedtestperformance = feval(opt.metric,results.modelpred,results.testdata);
end
