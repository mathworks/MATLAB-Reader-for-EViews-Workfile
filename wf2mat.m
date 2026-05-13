function [M, varNames, obsLabels] = wf2mat(wf, seriesNames)
% WF2MAT Convert wfread output to a MATLAB(R) numeric matrix
%
%   M = wf2mat(wf)
%   M = wf2mat(wf, seriesNames)
%   [M, varNames] = wf2mat(...)
%   [M, varNames, obsLabels] = wf2mat(...)
%
%   Converts series from a workfile struct (returned by wfread) into a
%   numeric matrix suitable for matrix operations.
%
%   Inputs:
%       wf          - Struct returned by wfread()
%       seriesNames - (Optional) String array or cell array of series names
%                     to include. If omitted, all series are included.
%
%   Outputs:
%       M         - Numeric matrix (numObs x numSeries) containing data
%       varNames  - String array of variable names (column headers)
%       obsLabels - String array of observation labels (row labels)
%
%   Notes:
%       - Series with mismatched lengths are skipped with a warning
%       - Non-numeric series are skipped with a warning
%       - NaN values are preserved in the matrix
%
%   Examples:
%       % Convert all series to matrix
%       wf = wfread("stocks.wf1");
%       [M, names] = wf2mat(wf);
%
%       % Compute correlation matrix
%       R = corrcoef(M, Rows="complete");
%
%       % Convert specific series only
%       M = wf2mat(wf, ["AAPL_CLOSE", "MSFT_CLOSE"]);
%
%       % Use with regression
%       y = M(:, 1);
%       X = [ones(size(M,1), 1), M(:, 2:end)];
%       beta = X \ y;
%
%   See also: WFREAD, WF2TIMETABLE, WF2TABLE

    arguments
        wf (1,1) struct
        seriesNames string = string.empty
    end

    % Validate workfile has Metadata
    if ~isfield(wf, 'Metadata')
        error('wf2mat:InvalidInput', ...
            'Input must be a workfile struct from wfread()');
    end

    props = wf.Metadata;

    % Get all series names if not specified
    % Exclude non-series fields: Metadata, Groups, Equations, VARs, Tables, Graphs
    nonSeriesFields = ["Metadata", "Groups", "Equations", "VARs", "Tables", "Graphs"];
    allFields = string(fieldnames(wf));
    allSeries = allFields(~ismember(allFields, nonSeriesFields));

    if isempty(seriesNames)
        seriesNames = string(allSeries);
    else
        % Validate requested series exist (warn for missing, don't error)
        seriesNames = string(seriesNames);
        validMask = true(size(seriesNames));
        for i = 1:numel(seriesNames)
            if ~isfield(wf, seriesNames(i))
                warning('wf2mat:SeriesNotFound', ...
                    'Series "%s" not found in workfile, skipping.', seriesNames(i));
                validMask(i) = false;
            end
        end
        seriesNames = seriesNames(validMask);
    end

    if isempty(seriesNames)
        warning('wf2mat:NoSeries', 'No valid series to convert.');
        M = [];
        varNames = string.empty(0,1);
        obsLabels = string.empty(0,1);
        return;
    end

    % Get expected length and observation labels from first valid series
    obsLabels = string.empty(0,1);
    expectedLength = props.NumObs;

    % Collect series data, skipping problematic ones
    varNames = string.empty(0,1);
    dataColumns = {};
    skippedSeries = string.empty(0,1);

    for i = 1:numel(seriesNames)
        seriesTable = wf.(seriesNames(i));
        seriesData = seriesTable{:, 2};  % Second column is data

        % Get obs labels from first series
        if isempty(obsLabels) && height(seriesTable) > 0
            obsLabels = string(seriesTable{:, 1});
            obsLabels = obsLabels(:);
            expectedLength = length(obsLabels);
        end

        % Check length match
        if length(seriesData) ~= expectedLength
            skippedSeries(end+1) = sprintf("%s (length %d vs expected %d)", ...
                seriesNames(i), length(seriesData), expectedLength);
            continue;
        end

        % Check numeric
        if ~isnumeric(seriesData)
            skippedSeries(end+1) = sprintf("%s (non-numeric)", seriesNames(i));
            continue;
        end

        varNames(end+1) = seriesNames(i);
        dataColumns{end+1} = seriesData(:);
    end

    % Warn about skipped series
    if ~isempty(skippedSeries)
        warning('wf2mat:SeriesSkipped', ...
            'Skipped %d series: %s', length(skippedSeries), join(skippedSeries, ", "));
    end

    if isempty(dataColumns)
        warning('wf2mat:NoValidSeries', 'No series could be converted.');
        M = [];
        varNames = string.empty(0,1);
        obsLabels = string.empty(0,1);
        return;
    end

    % Build the matrix (numObs x numSeries)
    M = [dataColumns{:}];
end
