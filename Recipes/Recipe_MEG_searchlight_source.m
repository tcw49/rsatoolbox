%
% Cai Wingfield 2010-05, 2010-08, 2015-03
% update by Li Su 3-2012, 11-2012
% updated Fawad 12-2013, 02-2014, 10-2014

% TODO: Documentation

%%%%%%%%%%%%%%%%%%%%
%% Initialisation %%
%%%%%%%%%%%%%%%%%%%%
toolboxRoot = 'C:\Users\cai\code\rsagroup-rsatoolbox\'; 
addpath(genpath(toolboxRoot));
userOptions = defineUserOptions();

%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Model RDM calculation %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%
userOptions.modelNumber = which_model;
models = rsa.constructModelRDMs(userOptions);

%%%%%%%%%%%%%%%%%%
%% Set metadata %%
%%%%%%%%%%%%%%%%%%
% TODO: This is bad
userOptions = rsa.meg.setMetadata_MEG(models, userOptions);

%%%%%%%%%%%%%%%%%%%%%%
%% Mask preparation %% 
%%%%%%%%%%%%%%%%%%%%%%
usingMasks = ~isempty(userOptions.maskNames);
if usingMasks
    indexMasks = rsa.meg.MEGMaskPreparation_source(userOptions);
    % For this searchlight analysis, we combine all masks into one
    indexMasks = rsa.meg.combineVertexMasks_source(indexMasks, 'combined_mask', userOptions);  
else
    indexMasks = rsa.meg.allBrainMask(userOptions);
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Calculate adjacency matrix %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
nSubjects = numel(userOptions.subjectNames);
adjacencyMatrix = rsa.meg.calculateMeshAdjacency(userOptions.nVertices, userOptions.sourceSearchlightRadius, userOptions);

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Starting parallel toolbox %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
if userOptions.flush_Queue
    rsa.par.flushQ();
end

if userOptions.run_in_parallel
    p = rsa.par.initialise_CBU_Queue(userOptions);
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Searchlight - Brain RDM calculation %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
rsa.util.prints('Stage 1 - Searchlight Brain RDM Calculation:');
parfor subject_i = 1:nSubjects
    [status, hostname] = system('hostname');
    
    % Work on each hemisphere separately
    for chi = 'LR'
        rsa.util.prints('%s: Working on subject %d, %s side', hostname, subject_i, chi);
    
        % Get subject source data
        sourceMeshesThisSubjectThisHemi = rsa.meg.MEGDataPreparation_source(subject_i, chi, betaCorrespondence(), userOptions);

        % TODO: This should return a cell array of filenames of where data is
        % TODO: saved, or something.
        rsa.meg.MEGSearchlight_source( ...
            subject_i, ...
            chi, ...
            sourceMeshesThisSubjectThisHemi, ...
            ...% Use the mask for this hemisphere only
            indexMasks([indexMasks.chirality] == chi), ...
            models, ...
            adjacencyMatrix, ...
            userOptions ...
        );
    end
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Smoothing and upsampling %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% TODO: What is `stages`?
%if stages == 2
%    interpolate_MEG_source(Models, userOptions);
%end

%%%%%%%%%%%%%%%%%%%%%%%%
%% Random permutation %%
%%%%%%%%%%%%%%%%%%%%%%%%
if strcmp(userOptions.groupStats, 'FFX')
    tic
    % fixed effect test
    rsa.util.prints('Averaging RDMs across subjects and performing permutation tests to calculate r-values.');
    indexMasks = rsa.meg.combineVertexMasks_source(indexMasks, 'combined_mask', userOptions);  
    rsa.meg.FFX_permutation(models, indexMasks, userOptions)
    rsa.util.prints('Stage 2 - Fixed Effects Analysis: ');
    toc
else
    % random effect test
    rsa.util.prints('Performing permutation tests over all subjects (random effect) to calculate p-values.');
    tic
    rsa.meg.RFX_permutation(models,userOptions);
    rsa.util.prints('Stage 2 - Random Effects Analysis: ');
    toc 
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Sptiotemporal clustering %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
jobSize = userOptions.jobSize;
number_of_permutations = userOptions.significanceTestPermutations;

tic
parfor j = 1:number_of_permutations/jobSize
    range = (j-1)*jobSize+1:j*jobSize;
    rsa.meg.MEGFindCluster_source(models, range, indexMasks, userOptions);
end
rsa.util.prints('Stage 3 - Spatiotemporal Clustering: ' );
toc

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Compute cluster level p-values %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
tic
rsa.meg.get_cluster_p_value(models,userOptions);
rsa.util.prints('Stage 4 - Computing cluster level p values: ');
toc

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Stopping parallel toolbox %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
if userOptions.run_in_parallel
    % Close the parpool
    delete(p);
end

%%%%%%%%%%%%%%%%%%%%
%% Delete Selected Directories%%
%%%%%%%%%%%%%%%%%%%%
if (userOptions.deleteTMaps_Dir || userOptions.deleteImageData_Dir || userOptions.deletePerm)
    rsa.util.deleteDir(userOptions, models);
end

%%%%%%%%%%%%%%%%%%%%
%% Sending an email %%
%%%%%%%%%%%%%%%%%%%%
if userOptions.recieveEmail
    rsa.par.setupInternet();
    rsa.par.setupEmail(userOptions.mailto);
end
