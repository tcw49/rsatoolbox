% [glmMeshPaths, lagSTCMetadata] = ...
%     searchlightGLM(averageRDMPaths, models, dataSTCMetadata, userOptions ...
%                   ['lag', <lag_in_ms>])
%
% models: Is a nTimepoints x nModels struct with field .RDM
%
% dataSTCMetadata: Contains info about timing and vertices for the data, 
%                  it's necessary for applying appropriate lags to the
%                  models.
%
% lag: The lag offset for the model time courses in ms. Must be
%      non-negative.
%
% Based on scripts written by Li Su and Isma Zulfiqar.
%
% Cai Wingfield 2015-03 -- 2015-04
function [glmMeshPaths, lagSTCMetadatas] = searchlight_dynamicGLM_source(averageRDMPaths, models, slSTCMetadatas, userOptions, varargin)

    import rsa.*
    import rsa.rdm.*
    import rsa.stat.*
    import rsa.util.*
    
    %% Parse inputs
    
    % 'lag'
    nameLag = 'lag';
    checkLag = @(x) (isnumeric(x) && (x >= 0));
    defaultLag = 0;
    
    % Set up parser
    ip = inputParser;
    ip.CaseSensitive = false;
    ip.StructExpand  = false;
    
    % Parameters
    addParameter(ip, nameLag, defaultLag, checkLag);
    
    % Parse the inputs
    parse(ip, varargin{:});
    
    % Get some nicer variable names
    % The lag in ms
    lag_in_ms = ip.Results.(nameLag);
    
    [nTimepoints_models, nModels] = size(models);
    
    
    %% Begin
    
    for chi = 'LR'
    
    
        %% Prepare lag for the models

        prints('Computing appropriate lag for dynamic model GLM...');

        % The models are assumed to have the same number of timepoints as the
        % data, and the timepoints are assumed to be corresponding.

        % The timepoints in the model timelines and the timepoints in the data
        % timelines are assumed to be corresponding at 0 lag, though the models
        % will be  offset by the specified lag.

        % Remember that STCmetadata.tstep measures lag in SECONDS!
        timestep_in_ms = slSTCMetadatas.(chi).tstep * 1000;

        % Check if this lag is doable
        if mod(lag_in_ms, timestep_in_ms) ~= 0
            warns('The requested lag of %dms cannot be achieved, as the timestep is %dms.', lag_in_ms, timestep_in_ms);

            % If it's not achievable, we adjust it until it is
            desired_lag_in_steps = lag_in_ms / timestep_in_ms;
            % TODO: this takes the floor, but should really take the nearest?
            achievable_lag_in_steps = floor(desired_lag_in_steps);
            achievable_lag_in_ms = achievable_lag_in_steps * timestep_in_ms;
            warns('Using a lag of %dms instead.', achievable_lag_in_ms);
            lag_in_ms = achievable_lag_in_ms;
        end

        lag_in_timepoints = lag_in_ms / timestep_in_ms;
    
    
        %% Prepare lag STC metadata

        lagSTCMetadatas.(chi).tstep = slSTCMetadatas.(chi).tstep;
        lagSTCMetadatas.(chi).vertices = slSTCMetadatas.(chi).vertices;
        lagSTCMetadatas.(chi).tmax = slSTCMetadatas.(chi).tmax;
        lagSTCMetadatas.(chi).tmin = slSTCMetadatas.(chi).tmin + (lagSTCMetadatas.(chi).tstep * lag_in_timepoints);
        
        prints('Loading average RDM mesh from "%s"...', averageRDMPaths.(chi));
        
        average_slRDMs = directLoad(averageRDMPaths.(chi), 'average_slRDMs');
        
        prints('Applying lag to dynamic model timelines...');
    
        [nVertices, nTimepoints_data] = size(average_slRDMs);
        [modelStack, nTimepoints_overlap] = stack_and_offset_models(models, lag_in_timepoints, nTimepoints_data);
    
        prints('Working at a lag of %dms, which corresponds to %d timepoints at this resolution.', lag_in_ms, lag_in_timepoints);
        
        % Preallocate.
        glm_mesh_betas = nan(1:nVertices, 1:nTimepoints_overlap, nModels + 1);
        glm_mesh_deviances = nan(1:Vertices, 1:nTimepoints_overlap);
        
        % Tell the user what's going on.
        prints('Performing dynamic GLM in %sh hemisphere...', lower(chi));
        
        parfor t = 1:nTimepoints_overlap
            
            % The timelines for the data and the models are offset.
            t_relative_to_data = t + lag_in_timepoints;
    
            % Temporarily disable this warning
            warning_id = 'stats:glmfit:IllConditioned';
            warning('off', warning_id);

            prints('Working on timepoint %d/%d...', t, nTimepoints_overlap);
            
            for v = 1:nVertices
                % Fit the GLM at this point
                % TODO: In case the models are all zeros, this will merrily
                % TODO: produce meaningless betas along with a warning.
                % TODO: We should probably check for this first.
                [ ...
                      glm_mesh_betas(v, t, :), ...
                      glm_mesh_deviances(v, t) ...
                    ] = glmfit( ...
                        modelStack{t}', ...
                        average_slRDMs(v, t_relative_to_data).RDM', ...
                        ...% TODO: Why are we making this assumption?
                        ...% TODO: What are the implications of this?
                        'normal');
            end%for:v
            
            % Re-enable warning
            warning('on', warning_id);
            
        end%for:t
        
        % Calculate max betas and max beta indices.
        % Matlab may say that these variables aren't being used, but 
        % actually they are saved later.
        [glm_mesh_max_betas, glm_mesh_max_beta_is] = max(glm_mesh_betas(:, :, 2:end), [], 3); %#ok<ASGLU>
        
        
        %% Median
        
        % Calculate median betas over time window
        % (vertices, models)
        glm_mesh_betas_median = squeeze(median(glm_mesh_betas, 2));
        
        % Calculate the maximum betas.
        % Matlab may say that these variables aren't being used, but 
        % actually they are saved later.
        [glm_mesh_max_betas_median, glm_mesh_max_beta_is_median] = max(glm_mesh_betas_median(:, 2:end), [], 2); %#ok<ASGLU>

        
        %% Save results in mat format
        
        % Directory
        glmMeshDir = fullfile(userOptions.rootPath, 'Meshes');
        gotoDir(glmMeshDir);
        
        % Paths
        path_betas.(chi) = fullfile(glmMeshDir, ...
            ['GLM_mesh_betas-', lower(chi), 'h.mat']);
        path_deviances.(chi) = fullfile(glmMeshDir, ...
            ['GLM_mesh_deviances-', lower(chi), 'h.mat']);
        path_max_betas.(chi) = fullfile(glmMeshDir, ...
            ['GLM_mesh_max_betas-', lower(chi), 'h.mat']);
        path_max_beta_is.(chi) = fullfile(glmMeshDir, ...
            ['GLM_mesh_max_beta_is-', lower(chi), 'h.mat']);
        
        % Paths median
        path_betas_median.(chi) = fullfile(glmMeshDir, ...
            ['GLM_mesh_betas_median-', lower(chi), 'h.mat']);
        path_max_betas_median.(chi) = fullfile(glmMeshDir, ...
            ['GLM_mesh_max_betas_median-', lower(chi), 'h.mat']);
        path_max_beta_is_median.(chi) = fullfile(glmMeshDir, ...
            ['GLM_mesh_max_beta_is_median-', lower(chi), 'h.mat']);
        
        % Paths model template
        path_betas_model.(chi) = fullfile(glmMeshDir, ...
            ['GLM_mesh_betas_model_%d-', lower(chi), 'h.mat']);
        path_betas_model_median.(chi) = fullfile(glmMeshDir, ...
            ['GLM_mesh_betas_model_%d_median-', lower(chi), 'h.mat']);
        
        
        prints('Saving GLM results for %sh hemisphere to "%s"...', lower(chi), glmMeshDir);
        
        % Save results
        save('-v7.3', path_betas.(chi), 'glm_mesh_betas');
        save('-v7.3', path_deviances.(chi), 'glm_mesh_deviances');
        save('-v7.3', path_max_betas.(chi), 'glm_mesh_max_betas');
        save('-v7.3', path_max_beta_is.(chi), 'glm_mesh_max_beta_is');
        
        % Save median results
        save('-v7.3', path_betas_median.(chi), 'glm_mesh_betas_median');
        save('-v7.3', path_max_betas_median.(chi), 'glm_mesh_max_betas_median');
        save('-v7.3', path_max_beta_is_median.(chi), 'glm_mesh_max_beta_is_median');
        
        
        %% Save results in STC format
        
        % Individual models
        
        prints('Saving individual model GLM results for %sh hemisphere to STC files...', lower(chi));
        
        for model_i = 1:nModels
            write_stc_file( ...
                lagSTCMetadata.(chi), ...
                squeeze(glm_mesh_betas(:, :, m + 1), ...
                sprintf(path_betas_model.(chi), model_i)));
        end
        
        % Summaries
        
        prints('Saving summary GLM results for %sh hemisphere to STC files...', lower(chi));
        
        write_stc_file( ...
            lagSTCMetadata.(chi), ...
            glm_mesh_max_betas, ...
            path_max_betas);
        write_stc_file( ...
            lagSTCMetadata.(chi), ...
            glm_mesh_max_beta_is, ...
            path_max_beta_is);
        
        % Individual models median
        
        prints('Saving individual model median GLM results for %sh hemisphere to STC files...', lower(chi));
        
        medianSTCMetadata = lagSTCMetadata.(chi);
        medianSTCMetadata.tmin = 0;
        medianSTCMetadata.tmax = 0;
        medianSTCMetadata.tstep = 0;
        for model_i = 1:nModels
            write_stc_file( ...
                medianSTCMetadata, ...
                squeeze(glm_mesh_betas_median(:, m + 1), ...
                sprintf(path_betas_model_median.(chi), model_i)));
        end
        
        % Summaries median
        
        prints('Saving summary median GLM results for %sh hemisphere to STC files...', lower(chi));
        
        write_stc_file( ...
            medianSTCMetadata, ...
            glm_mesh_max_betas_median, ...
            path_max_betas_median);
        write_stc_file( ...
            medianSTCMetadata, ...
            glm_mesh_max_beta_is_median, ...
            path_max_beta_is_median);
        
    end%for:chi
    
end%function


%%%%%%%%%%%%%%%%%%
%% Subfunctions %%
%%%%%%%%%%%%%%%%%%

% write_stc_file(metadata, mesh, file_path)
%
% Writes data as an stc file using the specified metadata struct.
%
% CW 2015-04
function write_stc_file(metadata, mesh, file_path)
    metadata.data = mesh;
    mne_write_stc_file1(file_path, metadata);
end%function
