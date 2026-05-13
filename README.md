# MATLAB Reader for EViews Workfile

[![Open in MATLAB Online](https://www.mathworks.com/images/responsive/global/open-in-matlab-online.svg)](https://matlab.mathworks.com/open/github/v1?repo=mathworks/MATLAB-Reader-for-EViews-Workfile)

Read EViews&trade; workfiles (.wf1 binary and .wf2 JSON) directly into MATLAB&reg; for econometric analysis, time series modeling, and quantitative research — no EViews installation required.

## Features

- **Dual format support**: Reads both legacy WF1 binary and modern WF2 JSON formats
- **Auto-detection**: Automatically determines file format from extension and content
- **Full series extraction**: Parses all series data including compressed formats
- **Equation support**: Extracts specifications, coefficients, and regression statistics
- **Multiple output formats**: Convert to MATLAB tables, timetables, or matrices
- **No dependencies**: Pure MATLAB implementation with no external toolboxes required

## System Requirements

- MATLAB R2021a or later
- No additional toolboxes required

## Getting Started

Add the folder to your MATLAB path:

```matlab
addpath("/path/to/matlab-workfile-reader");
```

Or add to your MATLAB `startup.m` for permanent access.

## Examples

### Read a Workfile and Plot Series Data

```matlab
% Read any EViews workfile (format auto-detected)
wf = wfread("mydata.wf1");

% Access series data
plot(wf.GDP.GDP);
disp(wf.Metadata.Frequency);  % 4 = quarterly

% Inspect workfile metadata
disp(wf.Metadata.Series);           % All series names
disp(wf.Metadata.ObservedSeries);   % Raw/observed data series
```

### Read Directly into a Timetable for Time Series Analysis

```matlab
% Read directly into a timetable
tt = wfread("quarterly_data.wf1", OutputType="timetable");
plot(tt.Time, tt.GDP);

% Or convert after reading
wf = wfread("quarterly_data.wf1");
tt = wf2timetable(wf, ["GDP", "CPI"]);  % Specific series only
```

### Export to Table or Matrix for Econometric Analysis

```matlab
% Export to CSV via table
T = wfread("data.wf1", OutputType="table");
writetable(T, "output.csv");

% Get numeric matrix for regression
[M, varNames, obsLabels] = wf2mat(wf);
y = M(:, 1);
X = [ones(size(M,1), 1), M(:, 2:end)];
beta = X \ y;
```

### Work with Equations and Groups

```matlab
% Access equation results
eq = wf.Equations.EQ1;
disp(eq.Specification);       % "Y = C(1) + C(2)*X + C(3)*Z"
disp(eq.Coefficients);        % Table with Name and Value columns
disp(eq.Statistics.Rsquared); % 0.95

% Access group members
grp = wf.Groups.MYGROUP;
disp(grp.Members);            % ["GDP", "CPI", "UNEMP"]
```

## Supported Formats

### WF1 (Binary)

The legacy MicroTSP/EViews binary format:

| Object Type | Support Level |
|-------------|---------------|
| Series | Full data extraction |
| Groups | Member names |
| Equations | Specification, coefficients, statistics (R&sup2;, Adj R&sup2;, SE) |
| VARs | Endogenous variables, sample, options |

### WF2 (JSON)

The modern EViews 12+ JSON format:

| Object Type | Support Level |
|-------------|---------------|
| Series | Full data extraction |
| Groups | Full (members + data) |
| Equations | Full (specification, coefficients, all statistics) |
| VARs | Full (endogenous, exogenous, lags, coefficients) |

## API Reference

| Function | Description |
|----------|-------------|
| `wfread(filepath)` | Read workfile, auto-detect format |
| `wfread(filepath, OutputType=type)` | Read and convert (`"struct"` (default), `"timetable"`, `"table"`, `"matrix"`) |
| `wf2timetable(wf)` | Convert to timetable |
| `wf2timetable(wf, series)` | Convert specific series to timetable |
| `wf2table(wf)` | Convert to table |
| `wf2table(wf, series)` | Convert specific series to table |
| `wf2mat(wf)` | Convert to numeric matrix |
| `wf2mat(wf, series)` | Convert specific series to matrix |

### Output Structure

```matlab
wf.SERIES_NAME                   % Table with Obs and value columns
wf.Metadata.Frequency          % 1=Annual, 4=Quarterly, 12=Monthly
wf.Metadata.StartYear          % First observation year
wf.Metadata.StartPeriod        % First observation period within year
wf.Metadata.NumObs             % Number of observations
wf.Metadata.Version            % "WF1" or "WF2"
wf.Metadata.Series             % String array of all series names
wf.Metadata.ObservedSeries     % String array of raw/observed series
wf.Metadata.DerivedSeries      % String array of calculated/derived series
wf.Metadata.FailedSeries       % String array of series that failed to read
wf.Metadata.SeriesDescriptions % Struct mapping series names to descriptions
wf.Groups.GROUP_NAME             % Struct with Members field
wf.Equations.EQ_NAME             % Struct with Specification, Coefficients, Statistics
wf.VARs.VAR_NAME                 % Struct with Endogenous, Sample, Options
```

## Limitations

- **WF1 coefficient standard errors**: Individual coefficient standard errors not extracted
- **WF1 Tables/Graphs**: Only names detected, cell data not parsed
- **Panel data**: Cross-section dimension not fully supported

## License

See [LICENSE.txt](LICENSE.txt).
