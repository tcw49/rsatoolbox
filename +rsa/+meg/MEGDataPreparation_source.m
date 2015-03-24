% MEGDataPreparation_source is a function designed to take MEG data and load it
% into the correct format for the rest of the toolbox to use.
%
% It is based on Su Li's code
%
% [meshPaths, STCMetadata] = MEGDataPreparation_source(
%                                          betas,
%                                          userOptions,
%                                         ['mask', indexMask,]
%                                         ['subject_i', subject_i,]
%                                         ['chi', 'L'|'R'])
%
%       betaCorrespondence --- The array of beta filenames.
%               betas(condition, session).identifier is a string which referrs
%               to the filename (not including path) of the SPM beta image.
%
%       userOptions --- The options struct.
%                userOptions.analysisName
%                        A string which is prepended to the saved files.
%                userOptions.rootPath
%                        A string describing the root path where files will be
%                        saved (inside created directories).
%                userOptions.subjectNames
%                        A cell array containing strings identifying the subject
%                        names. Defaults to the fieldnames in fullBrainVols.
%                userOptions.betaPath
%                        A string which contains the absolute path to the
%                        location of the beta images. It can contain the
%                        following wildcards which would be replaced as
%                        indicated:
%                                [[subjectName]]
%                                        To be replaced with the name of each
%                                        subject where appropriate.
%                                [[betaIdentifier]]
%                                        To be replaced by filenames as provided
%                                        by betaCorrespondence.
%
%       indexMask --- a struct containing at least:
%                indexMask.vertices
%                        A vector of integers which represent the vertices
%                        inside the mask.
%
%       sourceMeshes
%                sourceMeshes(vertices, timepoints, condition, session)
%                This data is downsampled, as per userOptions preferences.
%
% REQUIRES MATLAB VERSION 7.3 OR LATER
%
% Cai Wingfield 2010-05, 2010-06, 2015-03
% updated by Li Su 2-2012
% updated by Fawad 3-12014

function [meshPaths, STCMetadata] = MEGDataPreparation_source(betas, userOptions, varargin)

import rsa.*
import rsa.fig.*
import rsa.meg.*
import rsa.rdm.*
import rsa.sim.*
import rsa.spm.*
import rsa.stat.*
import rsa.util.*

%% Parse inputs

% 'masks'
nameMask = 'mask';
% We don't do any validation checks on the mask
checkMask = @(x) (true);
defaultMask = {};

% Set up parser
ip = inputParser;
ip.CaseSensitive = false;
ip.StructExpand = false;

% Parameters
addParameter(ip, nameMask, defaultMask, checkMask);

% Parse the inputs
parse(ip, varargin{:});

% If masks was given a default value, we're not going to do any masking.
usingMask = ~isempty(ip.Results.mask);

%% Begin

% We'll return to the pwd when the function has finished
returnHere = pwd;

[nSessions, nConditions] = size(betas);

% Some conditions will have been rejected, and we'll record those in
% this text file.
imageDataPath = fullfile(userOptions.rootPath, 'ImageData');
missingFilesLog = fullfile(imageDataPath, 'missingFilesLog.txt');

% Save a separate file for each subject and each hemisphere
file_i = 1;
for subject_i = 1:numel(userOptions.subjectNames)
    for chi = 'LR'
       meshPaths(subject_i).(chi) = fullfile(imageDataPath, [userOptions.analysisName, '_', userOptions.subjectNames{subject_i}, '_', lower(chi), 'h_CorticalMeshes.mat']); 
       promptOptions.checkFiles(file_i).address = meshPaths(subject_i).(chi);
       file_i = file_i + 1;
    end 
end

% Where data will be saved
gotoDir(imageDataPath);

% Make this available outside.
STCMetadatas = struct();

promptOptions.functionCaller = 'MEGDataPreparation_source';
promptOptions.defaultResponse = 'S';

% We check for any existing files before the loop.
% If the user says "skip", then we skip any files which exist and continue
% to load others.
overwriteFlag = overwritePrompt(userOptions, promptOptions);

%% Loop over all subjects under consideration
parfor subject_i = 1:numel(userOptions.subjectNames);
    
    % Figure out the subject's name
    thisSubjectName = userOptions.subjectNames{subject_i};
    
    %% Loop over all hemispheres under consideration
    for chi = 'LR'
        
        % We only load the data if we haven't already done so, unless we've
        % been told to overwrite.
        if exist(meshPaths(subject_i).(chi), 'file') && ~overwriteFlag
            prints('Subject %d (%s) %sh data already loaded. Skipping.', subject_i, thisSubjectName, chi);
        else
            prints('Loading on subject %d (%s), %s side', subject_i, thisSubjectName, chi);
        
            % For god knows what reason, this is necessary when using a parfor
            % loop, even though this variable ought to be scoped within the
            % loop body.
            sourceMeshes = [];

            % Loop over sessions and conditions
            for session_i = 1:nSessions
                for condition_i = 1:nConditions

                    % Then read the brain data (for this session, condition)
                    readPath = replaceWildcards(userOptions.betaPath, '[[betaIdentifier]]', betas(session_i, condition_i).identifier, '[[subjectName]]', thisSubjectName, '[[LR]]', lower(chi));

                    dataReadSuccessfully = false;
                    try
                        MEGData_stc = mne_read_stc_file1(readPath);
                        dataReadSuccessfully = true;
                    catch ex
                        % when a trial is rejected due to artifact, this item
                        % is replaced by NaNs. Li Su 3-2012
                        prints('Failed to read data for condition %d. Using NaNs instead.', condition_i);
                        % Log the missing file
                        dlmwrite(missingFilesLog, str2mat(replaceWildcards(betas(session_i, condition_i).identifier, '[[subjectName]]', thisSubjectName)), 'delimiter', '', '-append');
                    end

                    if dataReadSuccessfully

                        % Raw data sizes, before downsampling

                        % The number of vertices and timepoints in the
                        % raw data
                        [nVertices_raw, nTimepoints_raw] = size(MEGData_stc.data);
                        % The time index of the first datapoint, in
                        % seconds.
                        firstDatapointTime_raw = MEGData_stc.tmin;
                        % The interval between successive datapoints in
                        % the raw data, in seconds.
                        timeStep_raw = MEGData_stc.tstep;

                        %% Downsampling constants

                        % Sanity checks for downsampling
                        if nVertices_raw < userOptions.targetResolution
                            error('MEGDataPreparation_source:InsufficientSpatialResolution', 'There aren''t enough vertices in the raw data to meet the target resolution.');
                        end

                        % Now the actual downsampling targets can be
                        % calculated

                        % We will be downsampling in space and time, so
                        % we calculate some useful things here.
                        % The number of timepoints in the downsampled
                        % data
                        nTimepoints_downsampled = numel(1:userOptions.temporalDownsampleRate:nTimepoints_raw);
                        timeStep_downsampled = timeStep_raw * userOptions.temporalDownsampleRate;

                        % Time time index of the first datapoint
                        % doesn't change in the downsampled data
                        firstDatapointTime_downsampled = firstDatapointTime_raw;

                        % The time index of the last datapoint may
                        % change in the downsampled data, so should be
                        % recalculated
                        lastDatapointTime_downsampled = firstDatapointTime_downsampled + (nTimepoints_downsampled * timeStep_downsampled);

                        % This metadata struct will be useful for
                        % writing appropriate files in future. This new
                        % metadata should reflect the resolution and
                        % specifices of the data which
                        % MEGDataPreparation_source produces.
                        STCMetadatas(subject_i).(chi).tmin     = firstDatapointTime_downsampled;
                        STCMetadatas(subject_i).(chi).tmax     = lastDatapointTime_downsampled;
                        STCMetadatas(subject_i).(chi).tstep    = timeStep_downsampled;

                        %% Apply mask

                        % If we're using masks, we only want to include
                        % those vertices which are inside the mask.
                        if usingMask
                            % Make sure we're using the vertices of the
                            % mask on the correct hemisphere.
                            STCMetadatas(subject_i).(chi).vertices = sort(ip.Results.mask([ip.Results.mask.chi] == chi).vertices);
                        else
                            % If we're not using a mask, we still need to
                            % downsample the mesh to the target resolution.
                            % Luckily, downsampling is just a matter of
                            % taking low-numbered vertices, due to the way
                            % they are laid out.
                            STCMetadatas(subject_i).(chi).vertices = 1:userOptions.targetResolution;
                        end%if

                        %% Every time data is read

                        % Store the data in the mesh, masking and downsampling
                        % as we go.
                        sourceMeshes(:, :, condition_i, session_i) = ...
                            MEGData_stc.data( ...
                                ...% Downsample and mask space
                                STCMetadatas(subject_i).(chi).vertices, ...
                                ...% Downsample time by subsampling the timepoints
                                1:userOptions.temporalDownsampleRate:end); % (vertices, time, condition, session)
                    else
                        % Make sure it actually has NaNs in if there was an
                        % error for this condition
                        sourceMeshes(:, :, condition_i, session_i) = NaN(numel(STCMetadatas(subject_i).(chi).vertices), nTimepoints_downsampled);
                    end
                end%for:condition
            end%for:session

            gotoDir(imageDataPath);
            parsave('-v7.3', meshPaths(subject_i).(chi), 'sourceMeshes');

            prints('Subject %s''s %s-hemisphere data read successfully!', thisSubjectName, chi);
            dlmwrite(missingFilesLog, '', '-append');
        end%if: proceed with load
    end%for:chi
end%for:subjects

%% Prepare outputs

% These should all be the same, so we can just take the first one
STCMetadata = STCMetadatas(1).L;

cd(returnHere); % Go back

end%function


%%%%%%%%%%%%%%%%%%
%% Subfunctions %%
%%%%%%%%%%%%%%%%%%

% For some unknown reason this is necessary if using parfor
function parsave(varargin)
    save(varargin{:});
end%function
