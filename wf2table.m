function T = wf2table(wf, seriesNames)
% WF2TABLE Convert wfread output to a MATLAB(R) table
%
%   T = wf2table(wf)
%   T = wf2table(wf, seriesNames)
%
%   Converts series from a workfile struct (returned by wfread) into a
%   MATLAB table with observation labels and data columns.
%
%   Inputs:
%       wf          - Struct returned by wfread()
%       seriesNames - (Optional) String array or cell array of series names
%                     to include. If omitted, all series are included.
%
%   Output:
%       T - Table with:
%            - Obs column containing observation labels (from workfile)
%            - One variable column per series
%
%   Notes:
%       - Series with mismatched lengths are skipped with a warning
%       - Non-numeric series are skipped with a warning
%       - Observation labels come from the first column of series tables
%
%   Examples:
%       % Convert all series to table
%       wf = wfread("stocks.wf1");
%       T = wf2table(wf);
%
%       % Convert specific series only
%       T = wf2table(wf, ["AAPL_CLOSE", "MSFT_CLOSE"]);
%
%       % Write to CSV
%       writetable(T, "output.csv");
%
%   See also: WFREAD, WF2TIMETABLE, WF2MAT, TABLE

    arguments
        wf (1,1) struct
        seriesNames string = string.empty
    end

    % Validate workfile has Metadata
    if ~isfield(wf, 'Metadata')
        error('wf2table:InvalidInput', ...
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
                warning('wf2table:SeriesNotFound', ...
                    'Series "%s" not found in workfile, skipping.', seriesNames(i));
                validMask(i) = false;
            end
        end
        seriesNames = seriesNames(validMask);
    end

    if isempty(seriesNames)
        warning('wf2table:NoSeries', 'No valid series to convert.');
        T = table();
        return;
    end

    % Get observation labels from first valid series
    obsLabels = string.empty(0,1);
    expectedLength = props.NumObs;

    % Collect series data, skipping problematic ones
    validNames = string.empty(0,1);
    dataCell = {};
    skippedSeries = string.empty(0,1);

    for i = 1:numel(seriesNames)
        seriesTable = wf.(seriesNames(i));
        seriesData = seriesTable{:, 2};  % Second column is data

        % Get obs labels from first series
        if isempty(obsLabels) && height(seriesTable) > 0
            obsLabels = string(seriesTable{:, 1});
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

        validNames(end+1) = seriesNames(i);
        dataCell{end+1} = seriesData;
    end

    % Warn about skipped series
    if ~isempty(skippedSeries)
        warning('wf2table:SeriesSkipped', ...
            'Skipped %d series: %s', length(skippedSeries), join(skippedSeries, ", "));
    end

    if isempty(dataCell)
        warning('wf2table:NoValidSeries', 'No series could be converted.');
        T = table();
        return;
    end

    % Build the table
    obsCol = obsLabels(:);

    % Create table with Obs column first
    T = table(obsCol, 'VariableNames', "Obs");

    % Add data columns
    for i = 1:length(validNames)
        T.(validNames(i)) = dataCell{i};
    end

    % Add metadata
    T.Properties.Description = sprintf('EViews workfile (v%s)', props.Version);
    T.Properties.UserData = props;
end
