function tt = wf2timetable(wf, seriesNames)
% WF2TIMETABLE Convert wfread output to a MATLAB(R) timetable
%
%   tt = wf2timetable(wf)
%   tt = wf2timetable(wf, seriesNames)
%
%   Converts series from a workfile struct (returned by wfread) into a
%   MATLAB timetable with datetime row times.
%
%   Inputs:
%       wf          - Struct returned by wfread()
%       seriesNames - (Optional) String array or cell array of series names
%                     to include. If omitted, all series are included.
%
%   Output:
%       tt - Timetable with:
%            - RowTimes as datetime values
%            - One variable column per series
%
%   Notes:
%       - Series with mismatched lengths are skipped with a warning
%       - Non-numeric series are skipped with a warning
%       - Undated workfiles use sequential dates (warning issued)
%
%   Examples:
%       % Convert all series to timetable
%       wf = wfread("stocks.wf1");
%       tt = wf2timetable(wf);
%       plot(tt.Time, tt.AAPL_CLOSE);
%
%       % Convert specific series only
%       tt = wf2timetable(wf, ["AAPL_CLOSE", "MSFT_CLOSE"]);
%
%       % Use with retime for resampling
%       ttQuarterly = retime(tt, "quarterly", "mean");
%
%   See also: WFREAD, WF2TABLE, WF2MAT, TIMETABLE, RETIME

    arguments
        wf (1,1) struct
        seriesNames string = string.empty
    end

    % Validate workfile has Metadata
    if ~isfield(wf, 'Metadata')
        error('wf2timetable:InvalidInput', ...
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
                warning('wf2timetable:SeriesNotFound', ...
                    'Series "%s" not found in workfile, skipping.', seriesNames(i));
                validMask(i) = false;
            end
        end
        seriesNames = seriesNames(validMask);
    end

    if isempty(seriesNames)
        warning('wf2timetable:NoSeries', 'No valid series to convert.');
        tt = timetable();
        return;
    end

    % Generate datetime row times from workfile properties
    rowTimes = generateDatetimes(props.StartYear, props.StartPeriod, ...
        props.Frequency, props.NumObs);

    % Collect series data, skipping problematic ones
    validNames = string.empty(0,1);
    dataCell = {};
    skippedSeries = string.empty(0,1);

    for i = 1:numel(seriesNames)
        seriesTable = wf.(seriesNames(i));
        seriesData = seriesTable{:, 2};  % Second column is data

        % Check length match
        if length(seriesData) ~= props.NumObs
            skippedSeries(end+1) = sprintf("%s (length %d vs expected %d)", ...
                seriesNames(i), length(seriesData), props.NumObs);
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
        warning('wf2timetable:SeriesSkipped', ...
            'Skipped %d series: %s', length(skippedSeries), join(skippedSeries, ", "));
    end

    if isempty(dataCell)
        warning('wf2timetable:NoValidSeries', 'No series could be converted.');
        tt = timetable();
        return;
    end

    % Build the timetable with all data at once
    tt = timetable(rowTimes, dataCell{:}, 'VariableNames', validNames);

    % Add metadata
    tt.Properties.Description = sprintf('EViews workfile (v%s)', props.Version);
    tt.Properties.UserData = props;
end

function dt = generateDatetimes(startYear, startPeriod, frequency, numObs)
% GENERATEDATETIMES Generate datetime array for time series observations
%
%   Handles annual, quarterly, monthly, and undated workfiles.

    switch frequency
        case 1  % Annual
            dt = datetime(startYear + (0:numObs-1)', 1, 1);

        case 4  % Quarterly
            totalPeriods = (startPeriod - 1) + (0:numObs-1)';
            yrs = startYear + floor(totalPeriods / 4);
            qtrs = mod(totalPeriods, 4) + 1;
            dt = datetime(yrs, (qtrs - 1)*3 + 1, 1);

        case 12  % Monthly
            totalPeriods = (startPeriod - 1) + (0:numObs-1)';
            yrs = startYear + floor(totalPeriods / 12);
            mos = mod(totalPeriods, 12) + 1;
            dt = datetime(yrs, mos, 1);

        otherwise
            % Undated or irregular - use sequential days from a base date
            % This allows timetable functionality but dates are meaningless
            dt = datetime(startYear, 1, 1) + days(0:numObs-1)';
            warning('wf2timetable:UndatedWorkfile', ...
                'Workfile has non-standard frequency (%d). Using sequential dates.', ...
                frequency);
    end
end
