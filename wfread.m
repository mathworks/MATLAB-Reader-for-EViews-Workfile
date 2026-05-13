function workfile = wfread(filepath, options)
% WFREAD Read an EViews(TM) workfile (.wf1 or .wf2) and return series data
%
%   workfile = wfread(filepath)
%   workfile = wfread(filepath, OutputType=type)
%
%   Reads an EViews workfile, automatically detecting the format based on
%   file extension and content. Supports both binary WF1 format (MicroTSP/
%   EViews 1-6) and JSON-based WF2 format (EViews 12+). Requires MATLAB(R)
%   R2021a or later.
%
%   Input:
%       filepath   - Path to the .wf1 or .wf2 file
%       OutputType - (Optional) Output format, one of:
%                      "struct"    - (default) struct with series tables
%                      "timetable" - MATLAB timetable (via wf2timetable)
%                      "table"     - MATLAB table (via wf2table)
%                      "matrix"    - numeric matrix only (via wf2mat)
%
%   Output:
%       When OutputType is "struct" (default):
%         workfile - Struct with fields:
%           .<SeriesName> - Table for each series with columns:
%                           obs (observation label, e.g., "2005M01")
%                           <SeriesName> (the data values)
%                           Table has Description property if available
%           .Groups       - Struct with group objects (if present)
%           .Equations    - Struct with equation objects (if present)
%           .VARs         - Struct with VAR objects (if present)
%           .Tables       - Struct with table objects (if present)
%           .Graphs       - Struct with graph objects (if present)
%           .Metadata     - Struct with workfile metadata:
%                           .Frequency, .StartYear, .StartPeriod, .NumObs,
%                           .Version, .Series, .ObservedSeries, .DerivedSeries,
%                           .FailedSeries, .SeriesDescriptions
%
%       When OutputType is "timetable": a timetable (see wf2timetable)
%       When OutputType is "table": a table (see wf2table)
%       When OutputType is "matrix": a numeric matrix (N x M). Use wf2mat
%           directly if you also need variable names and observation labels.
%
%   Example:
%       % Read any workfile format
%       wf = wfread("stocks.wf1");
%       wf = wfread("stocks.wf2");
%
%       % Access series data
%       plot(wf.AAPL_CLOSE.AAPL_CLOSE);
%
%       % Convert to other formats
%       tt = wf2timetable(wf);
%       T = wf2table(wf);
%       [M, names] = wf2mat(wf);
%
%       % Read directly into a timetable
%       tt = wfread("stocks.wf1", OutputType="timetable");
%
%       % Read directly into a table
%       T = wfread("stocks.wf1", OutputType="table");
%
%       % Read directly into a numeric matrix
%       M = wfread("stocks.wf1", OutputType="matrix");
%
%   Notes:
%       - Format is auto-detected by extension and file content
%       - Missing values are converted to NaN
%       - Series names are converted to valid MATLAB identifiers
%       - WF1: Series, Groups (with members), Equations/VARs/Tables/Graphs (names only)
%       - WF2: Full support for all object types with detailed parsing
%       - OutputType "timetable" on undated workfiles uses synthetic dates
%
%   See also: WF2TABLE, WF2TIMETABLE, WF2MAT

    arguments
        filepath (1,1) string {mustBeFile}
        options.OutputType (1,1) string {mustBeMember(options.OutputType, ...
            ["struct", "timetable", "table", "matrix"])} = "struct"
    end

    % Detect format and dispatch to appropriate reader
    format = detectFormat(filepath);

    switch format
        case 'wf1'
            workfile = readWf1(filepath);
        case 'wf2'
            workfile = readWf2(filepath);
        otherwise
            error('wfread:UnknownFormat', ...
                'Unable to determine workfile format for "%s".', filepath);
    end

    % Convert output format if requested
    switch options.OutputType
        case "struct"
            % Default — return the struct as-is
        case "timetable"
            workfile = wf2timetable(workfile);
        case "table"
            workfile = wf2table(workfile);
        case "matrix"
            workfile = wf2mat(workfile);
    end
end

%% ========================================================================
%  FORMAT DETECTION
%  ========================================================================

function format = detectFormat(filepath)
% DETECTFORMAT Detect workfile format from extension and content

    % First try extension
    [~, ~, ext] = fileparts(filepath);
    ext = lower(ext);

    if strcmp(ext, '.wf1')
        format = 'wf1';
        return;
    elseif strcmp(ext, '.wf2')
        format = 'wf2';
        return;
    end

    % Unknown extension - try to detect from file content
    fid = fopen(filepath, 'rb');
    if fid == -1
        error('wfread:FileOpenError', 'Cannot open file: %s', filepath);
    end
    cleanup = onCleanup(@() fclose(fid));

    % Read first bytes to detect format
    header = fread(fid, 32, '*uint8')';

    if length(header) < 2
        error('wfread:FileTooSmall', 'File is too small to be a valid workfile.');
    end

    % Check for gzip magic (WF2 compressed)
    if header(1) == 0x1F && header(2) == 0x8B
        format = 'wf2';
        return;
    end

    % Check for JSON start (WF2 uncompressed)
    if header(1) == uint8('{')
        format = 'wf2';
        return;
    end

    % Check for WF1 signatures
    headerStr = char(header);
    if startsWith(headerStr, 'New MicroTSP') || startsWith(headerStr, 'EViews File')
        format = 'wf1';
        return;
    end

    % Default to WF1 for unknown binary files (legacy behavior)
    warning('wfread:UnknownFormat', ...
        'Could not detect format from content. Assuming WF1 based on binary content.');
    format = 'wf1';
end

%% ========================================================================
%  SHARED UTILITIES
%  ========================================================================

function labels = generateObsLabels(startYear, startPeriod, frequency, numObs)
% GENERATEOBSLABELS Generate EViews-style observation labels

    if frequency > 0
        totalPeriods = (startPeriod - 1) + (0:numObs-1)';
        years = startYear + floor(totalPeriods / frequency);
        periods = mod(totalPeriods, frequency) + 1;

        switch frequency
            case 1
                labels = compose("%d", years);
            case 4
                labels = compose("%dQ%d", years, periods);
            case 12
                labels = compose("%dM%02d", years, periods);
            otherwise
                labels = compose("%d", (1:numObs)');
        end
    else
        labels = compose("%d", (1:numObs)');
    end
end

%% ========================================================================
%  WF1 BINARY FORMAT READER
%  ========================================================================
%
%  WF1 Binary File Layout (MicroTSP / EViews)
%  ------------------------------------------------
%  Bytes 0-20:    File signature string (21 chars)
%                   "New MicroTSP Workfile" = MicroTSP / EViews 1-6
%                   "EViews File V01"       = EViews 7+
%  Bytes 80-83:   Header size (uint32) — end of header region
%  Bytes 114-117: Number of variables (int32)
%  Bytes 124-125: Frequency code (int16): 1=Annual, 4=Quarterly, 12=Monthly
%  Bytes 128-131: Start year (int32)
%  Bytes 132-133: Start period within year (int16)
%  Bytes 140-143: Number of observations (int32)
%
%  After the header, there is a 26-byte gap (purpose undocumented, possibly
%  reserved for future header fields or alignment padding).
%
%  Variable Record Directory (70 bytes per record):
%    +0:  (4 bytes) record flags
%    +4:  storage type (int16) — 11=standard (raw doubles), 60=compressed
%    +14: data pointer (uint32) — absolute byte offset to series data
%    +22: variable name (32 bytes, null-terminated ASCII)
%    +54: history pointer (uint32) — offset to description/history text block
%    +62: object type code (int16) — identifies the EViews object kind
%
%  Data Region:
%    Standard series: 4-byte obs count + 18 bytes header + N×8 IEEE doubles
%    Compressed series: 4-byte obs count + header with bit-packing parameters
%
%  Object Type Codes (from EViews internal format):
%    44 = Series     38 = Group       3 = Equation
%    10 = VAR         5 = Table       4 = Graph (type 1)   19 = Graph (type 2)
%  ========================================================================

function workfile = readWf1(filepath)
% READWF1 Read an EViews workfile in WF1 binary format

    % Object type codes from the WF1 variable record directory.
    % These identify what kind of EViews object each record represents.
    WF1_NA = 1e-37;            % EViews sentinel for missing values
    SERIES_TYPE = 44;          % Numeric series object
    GROUP_TYPE = 38;           % Named group of series
    EQUATION_TYPE = 3;         % Estimated equation
    VAR_TYPE = 10;             % Vector autoregression model
    TABLE_TYPE = 5;            % Tabular display object
    GRAPH_TYPE_1 = 4;          % Graph object (variant 1)
    GRAPH_TYPE_2 = 19;         % Graph object (variant 2)
    STANDARD_STORAGE = 11;     % Uncompressed: raw IEEE 754 doubles
    COMPRESSED_STORAGE = 60;   % Bit-packed delta compression
    RECORD_SIZE = 70;          % Fixed size of each variable record in bytes

    [~, fileName, fileExt] = fileparts(filepath);

    % Open file
    fid = fopen(filepath, 'rb');
    if fid == -1
        error('wfread:FileOpenError', 'Cannot open file: %s', filepath);
    end
    cleanup = onCleanup(@() fclose(fid));

    % Get file size — minimum 150 bytes required to contain the signature
    % (bytes 0-20) plus all header fields through numObs (byte 143)
    fileSize = wf1_getFileSize(fid);
    if fileSize < 150
        error('wfread:FileTooSmall', ...
            'File "%s" is too small (%d bytes) to be a valid workfile.', ...
            fileName + fileExt, fileSize);
    end

    % Read and validate file signature (21 chars at offset 0)
    % "New MicroTSP Workfile" = legacy MicroTSP/EViews 1-6
    % "EViews File V01"       = EViews 7+ binary format
    signature = fread(fid, 21, '*char')';

    if startsWith(signature, 'New MicroTSP Workfile')
        version = 'MicroTSP';
    elseif startsWith(signature, 'EViews File V01')
        version = 'EViews7+';
    else
        error('wfread:InvalidFormat', ...
            'File does not appear to be a valid EViews workfile.');
    end

    % Read header fields
    header = wf1_readHeader(fid, fileSize);

    % Validate header size
    if header.headerSize > fileSize
        error('wfread:InvalidHeaderSize', ...
            'Header size (%d) exceeds file size (%d).', ...
            header.headerSize, fileSize);
    end

    % Calculate variable records offset — 26-byte gap after the header
    % region separates it from the variable record directory. This gap is
    % present in all known WF1 files (purpose undocumented).
    recordsOffset = header.headerSize + 26;
    recordsEnd = recordsOffset + header.numVars * RECORD_SIZE;
    if recordsEnd > fileSize
        error('wfread:TruncatedFile', ...
            'Variable records extend beyond file size. File may be truncated.');
    end

    % Generate observation labels
    obsLabels = generateObsLabels(header.startYear, header.startPeriod, ...
        header.frequency, header.numObs);

    % Initialize output
    workfile = struct();
    seriesDescriptions = struct();
    failedSeries = string.empty(0,1);
    seriesCount = 0;
    groups = struct();
    equations = struct();
    vars = struct();
    tables = struct();
    graphs = struct();

    % Read all variable records
    for i = 1:header.numVars
        recordOffset = recordsOffset + (i - 1) * RECORD_SIZE;
        record = wf1_readVariableRecord(fid, recordOffset);

        % Skip internal/invalid records:
        % - RESID is EViews' built-in residuals series (auto-generated, not user data)
        % - Empty names indicate malformed or padding records in legacy files
        if strcmpi(record.name, 'RESID') || isempty(record.name)
            continue;
        end

        fieldName = matlab.lang.makeValidName(record.name);

        % Handle different object types
        if record.objectType == GROUP_TYPE
            try
                groupData = wf1_readGroupData(fid, record.dataPointer, fileSize);
                if ~isempty(groupData)
                    groups.(fieldName) = groupData;
                end
            catch
            end
            continue;
        elseif record.objectType == EQUATION_TYPE
            try
                eqData = wf1_readEquationData(fid, record.dataPointer, fileSize);
                eqData.Name = record.name;
                equations.(fieldName) = eqData;
            catch
                equations.(fieldName) = struct('Name', record.name);
            end
            continue;
        elseif record.objectType == VAR_TYPE
            try
                varData = wf1_readVarData(fid, record.dataPointer, fileSize);
                varData.Name = record.name;
                vars.(fieldName) = varData;
            catch
                vars.(fieldName) = struct('Name', record.name);
            end
            continue;
        elseif record.objectType == TABLE_TYPE
            tables.(fieldName) = struct('Name', record.name);
            continue;
        elseif record.objectType == GRAPH_TYPE_1 || record.objectType == GRAPH_TYPE_2
            graphs.(fieldName) = struct('Name', record.name);
            continue;
        elseif record.objectType ~= SERIES_TYPE
            continue;
        end

        % Series object
        try
            if record.dataPointer == 0 || record.dataPointer >= fileSize
                continue;
            end

            if record.storageType == STANDARD_STORAGE
                values = wf1_readSeriesData(fid, record.dataPointer, header.numObs, WF1_NA);
            elseif record.storageType == COMPRESSED_STORAGE
                values = wf1_readCompressedData(fid, record.dataPointer, header.numObs, WF1_NA);
            else
                continue;
            end

            description = '';
            if record.historyPointer > 0 && record.historyPointer < fileSize
                try
                    description = wf1_readHistoryBlock(fid, record.historyPointer);
                catch
                end
            end

            seriesTable = table(obsLabels, values, 'VariableNames', ["obs", fieldName]);

            if ~isempty(description)
                seriesTable.Properties.Description = description;
                seriesTable.Properties.VariableDescriptions = {'Observation', description};
                seriesDescriptions.(fieldName) = description;
            else
                seriesDescriptions.(fieldName) = fieldName;
            end

            workfile.(fieldName) = seriesTable;
            seriesCount = seriesCount + 1;

        catch ME
            failedSeries(end+1) = string(record.name); %#ok<AGROW>
        end
    end

    % Add non-series containers
    if ~isempty(fieldnames(groups)), workfile.Groups = groups; end
    if ~isempty(fieldnames(equations)), workfile.Equations = equations; end
    if ~isempty(fieldnames(vars)), workfile.VARs = vars; end
    if ~isempty(fieldnames(tables)), workfile.Tables = tables; end
    if ~isempty(fieldnames(graphs)), workfile.Graphs = graphs; end

    % Identify all series, observed (raw) vs derived series
    [allSeries, observedSeries, derivedSeries] = classifySeries(workfile, seriesDescriptions);

    % Add properties
    workfile.Metadata = struct(...
        'Frequency', header.frequency, ...
        'StartYear', header.startYear, ...
        'StartPeriod', header.startPeriod, ...
        'NumObs', header.numObs, ...
        'Version', version, ...
        'Series', allSeries, ...
        'ObservedSeries', observedSeries, ...
        'DerivedSeries', derivedSeries, ...
        'FailedSeries', failedSeries, ...
        'SeriesDescriptions', seriesDescriptions);
end

function header = wf1_readHeader(fid, fileSize)
% WF1_READHEADER Parse fixed-offset header fields from the WF1 binary file
%   See file layout diagram at top of readWf1 for byte offset documentation.

    wf1_validateSeek(fid, 80, 'header size');          % Byte 80: header size (uint32)
    header.headerSize = wf1_validateRead(fid, 1, 'uint32', 'header size');

    if header.headerSize < 100 || header.headerSize > min(fileSize, 10485760)
        error('wfread:InvalidHeaderSize', 'Header size %d is invalid.', header.headerSize);
    end

    wf1_validateSeek(fid, 114, 'numVars');             % Byte 114: variable count (int32)
    header.numVars = wf1_validateRead(fid, 1, 'int32', 'numVars');

    wf1_validateSeek(fid, 124, 'frequency');           % Byte 124: frequency code (int16)
    header.frequency = wf1_validateRead(fid, 1, 'int16', 'frequency');

    wf1_validateSeek(fid, 128, 'startYear');           % Byte 128: start year (int32)
    header.startYear = wf1_validateRead(fid, 1, 'int32', 'startYear');

    wf1_validateSeek(fid, 132, 'startPeriod');         % Byte 132: start period (int16)
    header.startPeriod = wf1_validateRead(fid, 1, 'int16', 'startPeriod');

    wf1_validateSeek(fid, 140, 'numObs');              % Byte 140: observation count (int32)
    header.numObs = wf1_validateRead(fid, 1, 'int32', 'numObs');

    if header.numVars <= 0
        error('wfread:InvalidHeader', 'Invalid number of variables: %d', header.numVars);
    end
    if header.numObs <= 0
        error('wfread:InvalidHeader', 'Invalid number of observations: %d', header.numObs);
    end
    if header.frequency <= 0
        error('wfread:InvalidFrequency', 'Invalid frequency: %d', header.frequency);
    end

    % For undated/cross-sectional workfiles (frequency=1), the startPeriod and
    % startYear fields in the binary header are not meaningful and often contain
    % garbage values. Only validate these fields for actual time series data.
    if header.frequency > 1
        if header.startPeriod < 1 || header.startPeriod > header.frequency
            warning('wfread:InvalidStartPeriod', ...
                'Start period %d is outside valid range [1, %d].', ...
                header.startPeriod, header.frequency);
            header.startPeriod = max(1, min(header.startPeriod, header.frequency));
        end

        if header.startYear < 1800 || header.startYear > 2200
            warning('wfread:UnusualYear', 'Start year %d is outside typical range.', header.startYear);
        end
    end
end

function record = wf1_readVariableRecord(fid, offset)
% WF1_READVARIABLERECORD Parse a 70-byte variable record from the directory
%   Each field is at a fixed offset within the record. See file layout
%   diagram at top of readWf1 for the full record structure.

    fseek(fid, offset + 4, 'bof');                     % +4:  storage type (int16)
    record.storageType = fread(fid, 1, 'int16', 'l');

    fseek(fid, offset + 14, 'bof');                    % +14: data pointer (uint32)
    record.dataPointer = fread(fid, 1, 'uint32', 'l');

    fseek(fid, offset + 22, 'bof');                    % +22: name (32 bytes, null-terminated)
    nameBytes = fread(fid, 32, 'uint8=>uint8');
    nullIdx = find(nameBytes == 0, 1);
    if isempty(nullIdx), nullIdx = 33; end
    record.name = char(nameBytes(1:nullIdx-1)');

    fseek(fid, offset + 54, 'bof');                    % +54: history/description pointer (uint32)
    record.historyPointer = fread(fid, 1, 'uint32', 'l');

    fseek(fid, offset + 62, 'bof');                    % +62: object type code (int16)
    record.objectType = fread(fid, 1, 'int16', 'l');
end

function description = wf1_readHistoryBlock(fid, historyPointer)
    description = '';
    fseek(fid, historyPointer + 2, 'bof');
    textLength = fread(fid, 1, 'int32', 'l');

    if textLength <= 0 || textLength > 10000
        return;
    end

    fseek(fid, historyPointer + 10, 'bof');
    textPointer = fread(fid, 1, 'uint32', 'l');

    if textPointer == 0
        return;
    end

    fseek(fid, textPointer, 'bof');
    textBytes = fread(fid, textLength, 'uint8=>uint8');
    description = char(textBytes');
    description = strtrim(description);
    description = description(description >= 32 | description == 9 | description == 10);
end

function values = wf1_readSeriesData(fid, dataPointer, expectedObs, naValue)
    fseek(fid, dataPointer, 'bof');
    numObs = fread(fid, 1, 'int32', 'l');
    fread(fid, 1, 'int32', 'l');
    fread(fid, 8, 'uint8');
    fread(fid, 1, 'int32', 'l');
    fread(fid, 2, 'uint8');

    values = fread(fid, numObs, 'double', 'l');
    values(abs(values - naValue) < 1e-40) = NaN;
end

function values = wf1_readCompressedData(fid, dataPointer, expectedObs, naValue)
    fseek(fid, dataPointer, 'bof');

    numObs = fread(fid, 1, 'int32', 'l');
    fread(fid, 18, 'uint8');

    mode = double(fread(fid, 1, 'int16', 'l'));
    h2_raw = double(fread(fid, 1, 'uint16', 'l'));
    base = double(fread(fid, 1, 'uint32', 'l'));

    hasLookupTable = bitand(uint16(h2_raw), uint16(0x4000)) > 0;
    hasRLE = bitand(uint16(h2_raw), uint16(0x0080)) > 0;
    hasNAFlag = bitand(uint16(h2_raw), uint16(0x8000)) > 0;

    if hasRLE || hasLookupTable
        bitWidth = double(bitand(uint16(h2_raw), uint16(0x003F)));
    elseif hasNAFlag
        lowerByte = bitand(uint16(h2_raw), uint16(0x00FF));
        if bitand(lowerByte, uint16(0x00C0)) > 0
            bitWidth = double(bitand(uint16(h2_raw), uint16(0x003F)));
        else
            bitWidth = double(lowerByte);
        end
    else
        bitWidth = double(bitand(uint16(h2_raw), uint16(0x3FFF)));
    end

    if bitWidth == 0 || h2_raw == 0x8000
        values = repmat(base, numObs, 1);
        if mode < 0
            values = values / (10^abs(mode));
        end
        return;
    end

    if bitWidth > 32
        bitWidth = double(bitand(uint16(h2_raw), uint16(0x003F)));
        if bitWidth == 0 || bitWidth > 32
            values = NaN(numObs, 1);
            return;
        end
    end

    totalBits = numObs * bitWidth;
    dataBytes = ceil(totalBits / 8);
    if hasRLE
        dataBytes = dataBytes * 2;
    end

    compData = double(fread(fid, dataBytes + 16, '*uint8'));

    allBits = zeros(1, length(compData) * 8);
    for i = 1:length(compData)
        b = compData(i);
        for bit = 0:7
            allBits((i-1)*8 + bit + 1) = mod(floor(b / (2^bit)), 2);
        end
    end

    values = zeros(numObs, 1);

    if hasLookupTable
        indices = zeros(numObs, 1);
        for j = 1:numObs
            startBit = (j-1) * bitWidth + 1;
            if startBit + bitWidth - 1 > length(allBits)
                indices(j:end) = -1;
                break;
            end
            delta = 0;
            for k = 0:bitWidth-1
                delta = delta + allBits(startBit + k) * (2^k);
            end
            indices(j) = delta;
        end

        nUnique = max(indices) + 1;
        dataEnd = dataPointer + 30 + dataBytes;

        lookupTable = [];
        for searchOffset = dataEnd:dataEnd+16
            fseek(fid, searchOffset, 'bof');
            testVals = fread(fid, nUnique, 'double', 'l');
            if length(testVals) == nUnique && all(isfinite(testVals))
                nonZero = testVals(testVals ~= 0);
                if isempty(nonZero) || (all(abs(nonZero) >= 1e-300) && all(abs(nonZero) < 1e15))
                    lookupTable = testVals;
                    break;
                end
            end
        end

        if isempty(lookupTable)
            lookupTable = NaN(nUnique, 1);
        end

        for j = 1:numObs
            if indices(j) < 0
                values(j) = NaN;
            else
                idx = indices(j) + 1;
                if idx <= length(lookupTable)
                    values(j) = lookupTable(idx);
                else
                    values(j) = NaN;
                end
            end
        end
    elseif hasRLE
        scaleFactor = 1;
        if mode < 0
            scaleFactor = 10^abs(mode);
        end

        maxDelta = 2^bitWidth - 1;
        valIdx = 0;
        bitPos = 1;
        prevValue = base;

        while valIdx < numObs && bitPos + bitWidth - 1 <= length(allBits)
            delta = 0;
            for k = 0:bitWidth-1
                delta = delta + allBits(bitPos + k) * (2^k);
            end
            bitPos = bitPos + bitWidth;

            if delta == maxDelta
                count = 0;
                for k = 0:5
                    if bitPos + k <= length(allBits)
                        count = count + allBits(bitPos + k) * (2^k);
                    end
                end
                bitPos = bitPos + 6;

                for r = 1:count
                    if valIdx < numObs
                        valIdx = valIdx + 1;
                        values(valIdx) = prevValue;
                    end
                end
            else
                valIdx = valIdx + 1;
                values(valIdx) = (base + delta) / scaleFactor;
                prevValue = values(valIdx);
            end
        end
    else
        scaleFactor = 1;
        if mode < 0
            scaleFactor = 10^abs(mode);
        end

        maxDelta = 2^bitWidth - 1;

        for j = 1:numObs
            startBit = (j-1) * bitWidth + 1;
            if startBit + bitWidth - 1 > length(allBits)
                values(j:end) = NaN;
                break;
            end
            delta = 0;
            for k = 0:bitWidth-1
                delta = delta + allBits(startBit + k) * (2^k);
            end
            if hasNAFlag && delta == maxDelta
                values(j) = NaN;
            else
                values(j) = (base + delta) / scaleFactor;
            end
        end
    end

    values(abs(values - naValue) < 1e-40) = NaN;
end

function fileSize = wf1_getFileSize(fid)
    currentPos = ftell(fid);
    fseek(fid, 0, 'eof');
    fileSize = ftell(fid);
    fseek(fid, currentPos, 'bof');
end

function wf1_validateSeek(fid, offset, ~)
    status = fseek(fid, offset, 'bof');
    if status ~= 0
        error('wfread:SeekError', 'Failed to seek to offset %d', offset);
    end
end

function data = wf1_validateRead(fid, count, precision, ~)
    [data, actualCount] = fread(fid, count, precision, 'l');
    if actualCount ~= count
        error('wfread:ReadError', 'Expected %d elements, got %d', count, actualCount);
    end
end

function groupData = wf1_readGroupData(fid, dataPointer, fileSize)
    groupData = [];

    if dataPointer == 0 || dataPointer >= fileSize
        return;
    end

    fseek(fid, dataPointer, 'bof');
    dataBytes = fread(fid, 512, '*uint8');

    if length(dataBytes) < 200
        return;
    end

    bestStr = '';

    for searchOffset = 150:200
        if searchOffset >= length(dataBytes)
            break;
        end

        nullIdx = find(dataBytes(searchOffset+1:end) == 0, 1);
        if isempty(nullIdx) || nullIdx < 4
            continue;
        end

        strBytes = dataBytes(searchOffset+1 : searchOffset+nullIdx-1);
        str = char(strBytes');

        if contains(str, ' ') && ~isempty(regexp(str, '^[A-Z0-9_() *+-]+$', 'once'))
            if length(str) > length(bestStr)
                bestStr = str;
            end
        end
    end

    if ~isempty(bestStr)
        members = split(strtrim(bestStr))';
        members = members(members ~= "");

        if ~isempty(members)
            groupData = struct();
            groupData.Members = members(:);
            groupData.ListString = bestStr;
        end
    end
end

function eqData = wf1_readEquationData(fid, dataPointer, fileSize)
% WF1_READEQUATIONDATA Parse equation sub-blocks to extract metadata
%
%   Equations use 18-byte block descriptors with nested structure.
%   Block type 8 = strings (spec, variables, sample)
%   Block type 3 = estimation options

    eqData = struct();

    if dataPointer == 0 || dataPointer >= fileSize
        return;
    end

    % Parse sub-blocks
    blocks = wf1_parseSubBlocks(fid, dataPointer, fileSize);

    % Extract information from type 8 (string) blocks
    stringBlocks = string.empty(0,1);
    options = string.empty(0,1);

    for i = 1:length(blocks)
        b = blocks{i};
        if b.type == 8 && ~isempty(b.str)
            stringBlocks(end+1) = string(b.str); %#ok<AGROW>
        elseif b.type == 3 && ~isempty(b.str)
            options(end+1) = string(b.str); %#ok<AGROW>
        end
    end

    % Identify block content by pattern matching
    for i = 1:length(stringBlocks)
        str = stringBlocks(i);

        % Equation specification (contains = and C()
        if contains(str, '=') && contains(str, 'C(')
            if ~isfield(eqData, 'Specification')
                eqData.Specification = str;

                % Extract dependent variable (left of =)
                eqParts = split(str, "=")';
                if ~isempty(eqParts)
                    eqData.Dependent = strtrim(eqParts(1));
                end
            end

        % Coefficient names (starts with C( but no =)
        elseif startsWith(str, 'C(') && ~contains(str, '=')
            eqData.CoefficientNames = split(strtrim(str))';

        % Sample range (year or obs numbers)
        elseif ~isempty(regexp(str, '^\d{4}[MQ]?\d*\s+\d{4}[MQ]?\d*', 'once')) || ...
               ~isempty(regexp(str, '^\d+\s+\d+\s*(IF|$)', 'once'))
            if ~isfield(eqData, 'Sample')
                eqData.Sample = str;
            end

        % Instrument list (for GMM/IV)
        elseif ~contains(str, '=') && ~contains(str, 'C(') && ...
               ~isempty(regexp(str, '^[A-Z]', 'once')) && ...
               (contains(str, '(-') || numel(split(str)) > 3)
            if ~isfield(eqData, 'Instruments') && ~isfield(eqData, 'Variables')
                % First such block is usually variables, second is instruments
                if isfield(eqData, 'Regressors')
                    eqData.Instruments = str;
                else
                    eqData.Regressors = str;
                end
            end
        end
    end

    % Store estimation options
    if ~isempty(options)
        eqData.Options = options;

        % Parse some common options
        for i = 1:length(options)
            opt = options(i);
            if startsWith(opt, 'METHOD=')
                eqData.Method = strrep(opt, 'METHOD=', '');
            elseif startsWith(opt, 'CX=')
                eqData.CrossSection = strrep(opt, 'CX=', '');
            elseif startsWith(opt, 'COV=')
                eqData.CovarianceMethod = strrep(opt, 'COV=', '');
            end
        end
    end

    % Extract coefficient VALUES from type 15 block (within type 17 results)
    coefValues = wf1_extractCoefValues(fid, dataPointer, fileSize);
    if ~isempty(coefValues)
        eqData.CoefficientValues = coefValues;

        % Create coefficients table if we have names
        if isfield(eqData, 'CoefficientNames') && ...
           length(eqData.CoefficientNames) == length(coefValues)
            eqData.Coefficients = table(eqData.CoefficientNames(:), coefValues(:), ...
                'VariableNames', ["Name", "Value"]);
        end
    end

    % Extract regression statistics from type 18 block
    stats = wf1_extractStatistics(fid, dataPointer, fileSize);
    if ~isempty(fieldnames(stats))
        eqData.Statistics = stats;
    end
end

function coefValues = wf1_extractCoefValues(fid, dataPointer, fileSize)
% WF1_EXTRACTCOEFVALUES Extract coefficient values from type 15 block
%
%   Type 15 format:
%   - Bytes 0-3: numCoefs (int32)
%   - Bytes 22+: coefficient values as doubles

    coefValues = [];

    % Find type 17 (results container)
    blocks = wf1_parseSubBlocks(fid, dataPointer, fileSize);

    for i = 1:length(blocks)
        b = blocks{i};
        if b.type == 17 && b.ptr > 0 && b.ptr < fileSize
            % Parse sub-blocks within type 17
            resultsBlocks = wf1_parseSubBlocks(fid, b.ptr, fileSize);

            for j = 1:length(resultsBlocks)
                rb = resultsBlocks{j};
                if rb.type == 15 && rb.ptr > 0 && rb.ptr < fileSize && rb.size >= 30
                    % Read type 15 block
                    fseek(fid, rb.ptr, 'bof');
                    type15Data = fread(fid, min(rb.size, 512), '*uint8');

                    if length(type15Data) >= 30
                        % Header: bytes 0-3 = number of coefficients
                        numCoefs = typecast(uint8(type15Data(1:4)), 'int32');

                        if numCoefs > 0 && numCoefs < 100
                            % Coefficient values start at offset 22 (1-indexed: 23)
                            dataStart = 23;
                            coefValues = zeros(numCoefs, 1);

                            for k = 1:numCoefs
                                idx = dataStart + (k-1)*8;
                                if idx + 7 <= length(type15Data)
                                    coefValues(k) = typecast(uint8(type15Data(idx:idx+7)), 'double');
                                end
                            end

                            % Validate - coefficients should be finite
                            if all(isfinite(coefValues))
                                return;
                            else
                                coefValues = [];
                            end
                        end
                    end
                end
            end
        end
    end
end

function stats = wf1_extractStatistics(fid, dataPointer, fileSize)
% WF1_EXTRACTSTATISTICS Extract regression statistics from type 18 block
%
%   Type 18 format:
%   - Nested sub-block descriptors at start
%   - Statistics as doubles starting after descriptors
%   - Layout: R², SumSqResid, AdjR², SE_regression, ..., numCoefs, numObs
%   - 1e-37 = NA/missing marker

    stats = struct();

    % Find type 17 (results container)
    blocks = wf1_parseSubBlocks(fid, dataPointer, fileSize);

    for i = 1:length(blocks)
        b = blocks{i};
        if b.type == 17 && b.ptr > 0 && b.ptr < fileSize
            % Parse sub-blocks within type 17
            resultsBlocks = wf1_parseSubBlocks(fid, b.ptr, fileSize);

            for j = 1:length(resultsBlocks)
                rb = resultsBlocks{j};
                if rb.type == 18 && rb.ptr > 0 && rb.ptr < fileSize && rb.size >= 40
                    % Read type 18 block
                    fseek(fid, rb.ptr, 'bof');
                    t18Data = fread(fid, min(rb.size, 512), '*uint8');

                    % Find R² by scanning from known starting points
                    startPoints = [18, 26, 34, 52, 54, 60];

                    for startOffset = startPoints
                        if startOffset + 8 > length(t18Data)
                            continue;
                        end

                        % Scan from this starting point
                        numDoubles = floor((length(t18Data) - startOffset) / 8);

                        for k = 1:min(10, numDoubles)
                            idx = startOffset + (k-1)*8 + 1;
                            if idx + 7 > length(t18Data)
                                break;
                            end
                            val = typecast(uint8(t18Data(idx:idx+7)), 'double');

                            % Check if this looks like R² (between 0.1 and 0.9999)
                            if val > 0.1 && val < 0.9999
                                % Found R² - extract statistics
                                statsData = t18Data(idx:end);
                                numStatsDoubles = floor(length(statsData) / 8);
                                allStats = zeros(numStatsDoubles, 1);

                                for m = 1:numStatsDoubles
                                    mdx = (m-1)*8 + 1;
                                    if mdx + 7 <= length(statsData)
                                        allStats(m) = typecast(uint8(statsData(mdx:mdx+7)), 'double');
                                    end
                                end

                                % Convert 1e-37 (NA marker) to NaN
                                allStats(abs(allStats - 1e-37) < 1e-38) = NaN;

                                % Assign known statistics
                                if length(allStats) >= 1
                                    stats.Rsquared = allStats(1);
                                end
                                if length(allStats) >= 2
                                    stats.SumSquaredResid = allStats(2);
                                end
                                if length(allStats) >= 3
                                    stats.AdjustedRsquared = allStats(3);
                                end
                                if length(allStats) >= 4
                                    stats.SEofRegression = allStats(4);
                                end

                                % Look for integer values (numCoefs, numObs)
                                for m = 1:length(allStats)
                                    if allStats(m) == round(allStats(m)) && ...
                                       allStats(m) > 0 && allStats(m) < 1000
                                        intVal = round(allStats(m));
                                        if intVal < 20 && ~isfield(stats, 'NumCoefficients')
                                            stats.NumCoefficients = intVal;
                                        elseif intVal >= 20 && ~isfield(stats, 'NumObservations')
                                            stats.NumObservations = intVal;
                                        end
                                    end
                                end

                                return;
                            end
                        end
                    end
                end
            end
        end
    end
end

function varData = wf1_readVarData(fid, dataPointer, fileSize)
% WF1_READVARDATA Parse VAR sub-blocks to extract metadata

    varData = struct();

    if dataPointer == 0 || dataPointer >= fileSize
        return;
    end

    % Parse sub-blocks
    blocks = wf1_parseSubBlocks(fid, dataPointer, fileSize);

    % Extract information from string blocks
    stringBlocks = string.empty(0,1);
    options = string.empty(0,1);

    for i = 1:length(blocks)
        b = blocks{i};
        if b.type == 8 && ~isempty(b.str)
            stringBlocks(end+1) = string(b.str); %#ok<AGROW>
        elseif b.type == 3 && ~isempty(b.str)
            options(end+1) = string(b.str); %#ok<AGROW>
        end
    end

    % First string block often contains endogenous variables
    if ~isempty(stringBlocks)
        varData.Endogenous = split(strtrim(stringBlocks(1)))';
    end

    % Look for sample range
    for i = 1:length(stringBlocks)
        str = stringBlocks(i);
        if ~isempty(regexp(str, '^\d{4}\s+\d{4}', 'once'))
            varData.Sample = str;
            break;
        end
    end

    if ~isempty(options)
        varData.Options = options;
    end
end

function blocks = wf1_parseSubBlocks(fid, startPtr, fileSize)
% WF1_PARSESUBBLOCKS Parse 18-byte block descriptors and extract content

    blocks = {};
    offset = 0;
    maxBlocks = 50;

    while offset < 1000 && length(blocks) < maxBlocks
        if startPtr + offset + 18 > fileSize
            break;
        end

        fseek(fid, startPtr + offset, 'bof');
        descBytes = fread(fid, 18, '*uint8');
        if length(descBytes) < 18
            break;
        end

        blockType = typecast(uint8(descBytes(1:2)), 'int16');
        size1 = typecast(uint8(descBytes(3:6)), 'uint32');
        blockPtr = typecast(uint8(descBytes(11:14)), 'uint32');

        % End condition
        if blockType == 0 && size1 == 0 && blockPtr == 0
            break;
        end

        % Validate
        if blockType < 0 || blockType > 100 || size1 > 50000
            offset = offset + 2;
            continue;
        end

        if blockPtr > 0 && blockPtr < fileSize && size1 > 0
            % Read block content
            fseek(fid, blockPtr, 'bof');
            contentBytes = fread(fid, min(size1, 1024), '*uint8');

            % Try to extract string
            str = '';
            nullIdx = find(contentBytes == 0, 1);
            if ~isempty(nullIdx)
                strBytes = contentBytes(1:nullIdx-1);
            else
                strBytes = contentBytes;
            end

            isPrintable = (strBytes >= 32 & strBytes < 127);
            if sum(isPrintable) >= 0.7 * length(strBytes) && length(strBytes) >= 1
                str = strtrim(char(strBytes'));
            end

            blocks{end+1} = struct('type', blockType, 'size', size1, ...
                'ptr', blockPtr, 'str', str); %#ok<AGROW>
            offset = offset + 18;
        else
            offset = offset + 2;
        end
    end
end

%% ========================================================================
%  WF2 JSON FORMAT READER
%  ========================================================================

function workfile = readWf2(filepath)
% READWF2 Read an EViews workfile in WF2 JSON format

    jsonStr = wf2_readFile(filepath);

    try
        data = jsondecode(jsonStr);
    catch ME
        error('wfread:JSONParseError', 'Failed to parse JSON: %s', ME.message);
    end

    if ~isfield(data, 'x_pages') && ~isfield(data, '_pages')
        error('wfread:InvalidFormat', 'File does not appear to be a valid EViews WF2 workfile.');
    end

    if isfield(data, '_pages')
        pages = data.('_pages');
    else
        pages = data.x_pages;
    end

    if isempty(pages)
        error('wfread:EmptyWorkfile', 'Workfile contains no pages.');
    end

    page = pages(1);
    [frequency, startYear, startPeriod, numObs] = wf2_extractMetadata(page);
    obsLabels = generateObsLabels(startYear, startPeriod, frequency, numObs);

    workfile = struct();
    seriesDescriptions = struct();
    groups = struct();
    equations = struct();
    vars = struct();
    tables = struct();
    graphs = struct();

    if isfield(page, 'x_objects')
        objects = page.x_objects;
    elseif isfield(page, '_objects')
        objects = page.('_objects');
    else
        objects = [];
    end

    for i = 1:numel(objects)
        if iscell(objects)
            obj = objects{i};
        else
            obj = objects(i);
        end

        if isfield(obj, 'x_name')
            objName = obj.x_name;
        elseif isfield(obj, '_name')
            objName = obj.('_name');
        else
            continue;
        end

        if startsWith(objName, '@') || strcmpi(objName, 'RESID')
            continue;
        end

        baseType = wf2_getFieldValue(obj, 'x_basetype', '_basetype', '');
        fieldName = matlab.lang.makeValidName(objName);

        switch lower(baseType)
            case 'series_list'
                groupData = wf2_readGroupObject(obj);
                if ~isempty(groupData)
                    groups.(fieldName) = groupData;
                end

            case 'equation'
                eqData = wf2_readEquationObject(obj);
                if ~isempty(eqData)
                    equations.(fieldName) = eqData;
                end

            case 'var'
                varData = wf2_readVarObject(obj);
                if ~isempty(varData)
                    vars.(fieldName) = varData;
                end

            case 'table'
                tableData = wf2_readTableObject(obj);
                if ~isempty(tableData)
                    tables.(fieldName) = tableData;
                end

            case 'graph'
                graphData = wf2_readGraphObject(obj);
                if ~isempty(graphData)
                    graphs.(fieldName) = graphData;
                end

            case 'series'
                if ~wf2_isNumericSeries(obj)
                    continue;
                end

                if ~isfield(obj, 'data')
                    continue;
                end
                values = obj.data;

                if iscell(values)
                    values = cellfun(@(x) wf2_convertToDouble(x), values);
                end
                values = double(values(:));

                if length(values) ~= numObs
                    continue;
                end

                description = wf2_getSeriesDescription(obj);

                seriesTable = table(obsLabels, values, 'VariableNames', ["obs", fieldName]);

                if ~isempty(description)
                    seriesTable.Properties.Description = description;
                    seriesTable.Properties.VariableDescriptions = {'Observation', description};
                    seriesDescriptions.(fieldName) = description;
                else
                    seriesDescriptions.(fieldName) = fieldName;
                end

                workfile.(fieldName) = seriesTable;

            otherwise
                if wf2_isNumericSeries(obj) && isfield(obj, 'data')
                    values = obj.data;
                    if iscell(values)
                        values = cellfun(@(x) wf2_convertToDouble(x), values);
                    end
                    values = double(values(:));

                    if length(values) == numObs
                        description = wf2_getSeriesDescription(obj);
                        seriesTable = table(obsLabels, values, 'VariableNames', ["obs", fieldName]);
                        if ~isempty(description)
                            seriesTable.Properties.Description = description;
                            seriesTable.Properties.VariableDescriptions = {'Observation', description};
                            seriesDescriptions.(fieldName) = description;
                        else
                            seriesDescriptions.(fieldName) = fieldName;
                        end
                        workfile.(fieldName) = seriesTable;
                    end
                end
        end
    end

    if ~isempty(fieldnames(groups)), workfile.Groups = groups; end
    if ~isempty(fieldnames(equations)), workfile.Equations = equations; end
    if ~isempty(fieldnames(vars)), workfile.VARs = vars; end
    if ~isempty(fieldnames(tables)), workfile.Tables = tables; end
    if ~isempty(fieldnames(graphs)), workfile.Graphs = graphs; end

    % Identify all series, observed (raw) vs derived series
    [allSeries, observedSeries, derivedSeries] = classifySeries(workfile, seriesDescriptions);

    workfile.Metadata = struct(...
        'Frequency', frequency, ...
        'StartYear', startYear, ...
        'StartPeriod', startPeriod, ...
        'NumObs', numObs, ...
        'Version', 'WF2', ...
        'Series', allSeries, ...
        'ObservedSeries', observedSeries, ...
        'DerivedSeries', derivedSeries, ...
        'FailedSeries', string.empty(0,1), ...
        'SeriesDescriptions', seriesDescriptions);
end

function jsonStr = wf2_readFile(filepath)
    fid = fopen(filepath, 'rb');
    if fid == -1
        error('wfread:FileOpenError', 'Cannot open file: %s', filepath);
    end
    magic = fread(fid, 2, '*uint8');
    fclose(fid);

    isGzipped = (length(magic) >= 2 && magic(1) == 0x1F && magic(2) == 0x8B);

    if isGzipped
        jsonStr = wf2_decompressGzip(filepath);
    else
        jsonStr = fileread(filepath);
    end
end

function jsonStr = wf2_decompressGzip(filepath)
    fid = fopen(filepath, 'rb');
    compressedData = fread(fid, '*uint8');
    fclose(fid);

    try
        byteStream = java.io.ByteArrayInputStream(compressedData);
        gzipStream = java.util.zip.GZIPInputStream(byteStream);
        reader = java.io.InputStreamReader(gzipStream, 'UTF-8');
        bufferedReader = java.io.BufferedReader(reader);

        stringBuilder = java.lang.StringBuilder();
        line = bufferedReader.readLine();
        while ~isempty(line)
            stringBuilder.append(line);
            line = bufferedReader.readLine();
        end
        bufferedReader.close();

        jsonStr = char(stringBuilder.toString());
    catch ME
        error('wfread:DecompressError', 'Failed to decompress gzip file: %s', ME.message);
    end
end

function [frequency, startYear, startPeriod, numObs] = wf2_extractMetadata(page)
    if isfield(page, 'range')
        numObs = double(page.range);
    else
        error('wfread:MissingRange', 'Page missing range field.');
    end

    if isfield(page, 'frequency')
        freqInfo = page.frequency;
    else
        error('wfread:MissingFrequency', 'Page missing frequency field.');
    end

    freqCode = '';
    if isfield(freqInfo, 'value')
        freqCode = freqInfo.value;
    end

    switch upper(freqCode)
        case 'A'
            frequency = 1;
        case 'Q'
            frequency = 4;
        case 'M'
            frequency = 12;
        case {'U', ''}
            frequency = 0;
        otherwise
            frequency = 0;
    end

    startYear = 1;
    startPeriod = 1;

    if isfield(freqInfo, 'start')
        startStr = freqInfo.start;
        if isnumeric(startStr)
            startYear = double(startStr);
        elseif ischar(startStr) || isstring(startStr)
            startStr = char(startStr);
            try
                parts = regexp(startStr, '(\d{4})-(\d{2})-(\d{2})', 'tokens', 'once');
                if ~isempty(parts)
                    startYear = str2double(parts{1});
                    month = str2double(parts{2});

                    switch frequency
                        case 1
                            startPeriod = 1;
                        case 4
                            startPeriod = ceil(month / 3);
                        case 12
                            startPeriod = month;
                        otherwise
                            startPeriod = 1;
                    end
                end
            catch
            end
        end
    end
end

function isSeries = wf2_isNumericSeries(obj)
    isSeries = false;

    baseType = '';
    if isfield(obj, 'x_basetype')
        baseType = obj.x_basetype;
    elseif isfield(obj, '_basetype')
        baseType = obj.('_basetype');
    end

    objType = '';
    if isfield(obj, 'x_type')
        objType = obj.x_type;
    elseif isfield(obj, '_type')
        objType = obj.('_type');
    end

    seriesType = '';
    if isfield(obj, 'seriesType')
        seriesType = obj.seriesType;
    elseif isfield(obj, 'seriestype')
        seriesType = obj.seriestype;
    elseif isfield(obj, 'series_type')
        seriesType = obj.series_type;
    end

    if strcmpi(baseType, 'series')
        if isempty(seriesType) || strcmpi(seriesType, 'numeric')
            isSeries = true;
        end
    elseif contains(lower(objType), 'series_double')
        isSeries = true;
    end
end

function val = wf2_convertToDouble(x)
    if isnumeric(x)
        val = double(x);
    elseif ischar(x) || isstring(x)
        x = char(x);
        if strcmpi(x, 'nan') || strcmpi(x, 'na')
            val = NaN;
        else
            val = str2double(x);
            if isnan(val)
                try
                    parts = regexp(x, '(\d{4})-(\d{2})-(\d{2})', 'tokens', 'once');
                    if ~isempty(parts)
                        yr = str2double(parts{1});
                        mo = str2double(parts{2});
                        dy = str2double(parts{3});
                        val = datenum(yr, mo, dy);
                    end
                catch
                end
            end
        end
    else
        val = NaN;
    end
end

function value = wf2_getFieldValue(obj, fieldName1, fieldName2, defaultValue)
    if isfield(obj, fieldName1)
        value = obj.(fieldName1);
    elseif isfield(obj, fieldName2)
        value = obj.(fieldName2);
    else
        value = defaultValue;
    end
end

function description = wf2_getSeriesDescription(obj)
    description = '';
    if isfield(obj, 'x_labels')
        labels = obj.x_labels;
        if isfield(labels, 'description')
            description = labels.description;
        end
    elseif isfield(obj, '_labels')
        labels = obj.('_labels');
        if isfield(labels, 'description')
            description = labels.description;
        end
    end
end

function groupData = wf2_readGroupObject(obj)
    groupData = struct();

    listStr = wf2_getFieldValue(obj, 'listString', 'list_string', '');
    if isempty(listStr)
        return;
    end

    groupData.ListString = listStr;

    members = split(strtrim(listStr))';
    members = members(members ~= "");
    groupData.Members = members(:);

    deps = wf2_getFieldValue(obj, 'dependencies', 'deps', '');
    if ~isempty(deps)
        groupData.Dependencies = split(strtrim(deps))';
    end
end

function eqData = wf2_readEquationObject(obj)
    eqData = struct();

    eqData.Specification = wf2_getFieldValue(obj, 'specification', 'spec', '');
    eqData.Dependent = wf2_getFieldValue(obj, 'dependent', 'depvar', '');
    eqData.EstimatedSpec = wf2_getFieldValue(obj, 'estString', 'est_string', '');

    coefStr = wf2_getFieldValue(obj, 'coefString', 'coef_string', '');
    altLabels = wf2_getFieldValue(obj, 'altCoefLabels', 'alt_coef_labels', '');

    if ~isempty(altLabels)
        coefNames = split(strtrim(altLabels))';
        coefNames = coefNames(coefNames ~= "");
    elseif ~isempty(coefStr)
        coefNames = split(strtrim(coefStr))';
        coefNames = coefNames(coefNames ~= "");
    else
        coefNames = string.empty(0,1);
    end

    if isfield(obj, 'results')
        results = obj.results;

        if isfield(results, 'data')
            coefValues = double(results.data(:));
            nCoefs = length(coefValues);

            if isempty(coefNames)
                coefNames = compose("C(%d)", 1:nCoefs);
            end

            if length(coefNames) > nCoefs
                coefNames = coefNames(1:nCoefs);
            elseif length(coefNames) < nCoefs
                for k = length(coefNames)+1:nCoefs
                    coefNames(k) = compose("C(%d)", k);
                end
            end

            eqData.Coefficients = table(coefNames(:), coefValues, 'VariableNames', ["Name", "Value"]);
        end

        if isfield(results, 'summary') && isfield(results.summary, 'summaryStats')
            stats = results.summary.summaryStats;
            eqData.Statistics = struct();

            if iscell(stats)
                for k = 1:length(stats)
                    if isstruct(stats{k})
                        if isfield(stats{k}, 'name') && isfield(stats{k}, 'value')
                            statName = matlab.lang.makeValidName(stats{k}.name);
                            eqData.Statistics.(statName) = stats{k}.value;
                        end
                    end
                end
            end
        end

        if isfield(results, 'covariance')
            cov = results.covariance;
            if isfield(cov, 'data') && isfield(cov, 'columns')
                nCols = double(cov.columns);
                covData = double(cov.data(:));
                covMat = zeros(nCols);
                idx = 1;
                for row = 1:nCols
                    for col = 1:row
                        if idx <= length(covData)
                            covMat(row, col) = covData(idx);
                            covMat(col, row) = covData(idx);
                            idx = idx + 1;
                        end
                    end
                end
                eqData.CovarianceMatrix = covMat;
            end
        end
    end
end

function varData = wf2_readVarObject(obj)
    varData = struct();

    endogStr = wf2_getFieldValue(obj, 'endogVariables', 'endog_variables', '');
    exogStr = wf2_getFieldValue(obj, 'exogVariables', 'exog_variables', '');
    lagSpec = wf2_getFieldValue(obj, 'lagSpec', 'lag_spec', '');

    if ~isempty(endogStr)
        varData.Endogenous = split(strtrim(endogStr))';
    else
        varData.Endogenous = string.empty(0,1);
    end

    if ~isempty(exogStr)
        varData.Exogenous = split(strtrim(exogStr))';
    else
        varData.Exogenous = string.empty(0,1);
    end

    if ~isempty(lagSpec)
        lagParts = str2double(split(strtrim(lagSpec))');
        lagParts = lagParts(~isnan(lagParts));
        if length(lagParts) >= 2
            varData.LagMin = lagParts(1);
            varData.LagMax = lagParts(2);
        elseif length(lagParts) == 1
            varData.LagMin = 1;
            varData.LagMax = lagParts(1);
        end
    end

    varData.SampleString = wf2_getFieldValue(obj, 'sampleString', 'sample_string', '');
    varData.Dependent = wf2_getFieldValue(obj, 'dependent', 'dep', '');
    varData.Regressors = wf2_getFieldValue(obj, 'regressors', 'regs', '');

    if isfield(obj, 'obsCount')
        varData.NumObs = double(obj.obsCount);
    end

    if isfield(obj, 'coefficients')
        coefStruct = obj.coefficients;
        if isfield(coefStruct, 'data')
            varData.CoefficientData = double(coefStruct.data(:));
        end
        if isfield(coefStruct, 'columns')
            varData.CoefficientCols = double(coefStruct.columns);
        end
    end

    if isfield(obj, 'equationSummaryStatistics')
        eqStats = obj.equationSummaryStatistics;
        if isfield(eqStats, 'data')
            varData.EquationStats = double(eqStats.data(:));
        end
    end
end

function tableData = wf2_readTableObject(obj)
    tableData = [];

    nRows = 0;
    nCols = 0;
    if isfield(obj, 'rows')
        nRows = double(obj.rows);
    end
    if isfield(obj, 'columns')
        nCols = double(obj.columns);
    end

    if nRows == 0 || nCols == 0
        return;
    end

    if ~isfield(obj, 'cells')
        return;
    end
    cells = obj.cells;

    if ~iscell(cells)
        return;
    end

    outputCells = cell(nRows, nCols);

    for k = 1:min(numel(cells), nRows * nCols)
        cellData = cells{k};
        row = floor((k-1) / nCols) + 1;
        col = mod(k-1, nCols) + 1;

        if row <= nRows && col <= nCols
            if isfield(cellData, 'string')
                outputCells{row, col} = cellData.string;
            elseif isfield(cellData, 'value')
                outputCells{row, col} = cellData.value;
            else
                outputCells{row, col} = '';
            end
        end
    end

    firstRowIsHeader = true;
    for col = 1:nCols
        val = outputCells{1, col};
        if isnumeric(val) && ~isnan(val)
            firstRowIsHeader = false;
            break;
        end
    end

    if firstRowIsHeader && nRows > 1
        varNames = strings(1, nCols);
        for col = 1:nCols
            val = outputCells{1, col};
            if ischar(val) || isstring(val)
                varNames(col) = matlab.lang.makeValidName(string(val));
            else
                varNames(col) = compose("Var%d", col);
            end
        end
        varNames = matlab.lang.makeUniqueStrings(varNames);
        tableData = cell2table(outputCells(2:end, :), 'VariableNames', varNames);
    else
        varNames = compose("Var%d", 1:nCols);
        tableData = cell2table(outputCells, 'VariableNames', varNames);
    end
end

function graphData = wf2_readGraphObject(obj)
    graphData = struct();

    graphData.Name = wf2_getFieldValue(obj, 'x_name', '_name', '');

    axisSeries = wf2_getFieldValue(obj, 'axisSeries', 'axis_series', '');
    if ~isempty(axisSeries) && (ischar(axisSeries) || isstring(axisSeries))
        graphData.Series = split(strtrim(string(axisSeries)))';
    else
        graphData.Series = string.empty(0,1);
    end

    if isfield(obj, 'seriesCount')
        graphData.SeriesCount = double(obj.seriesCount);
    end

    if isfield(obj, 'graphType')
        graphData.GraphType = obj.graphType;
    end

    if isfield(obj, 'x'), graphData.X = double(obj.x); end
    if isfield(obj, 'y'), graphData.Y = double(obj.y); end
    if isfield(obj, 'w'), graphData.Width = double(obj.w); end
    if isfield(obj, 'h'), graphData.Height = double(obj.h); end
end

%% ========================================================================
%  UTILITY FUNCTIONS
%  ========================================================================

function [allSeries, observedSeries, derivedSeries] = classifySeries(workfile, seriesDescriptions)
%CLASSIFYSERIES Classify series as observed (raw) or derived
%   Returns three string arrays:
%     allSeries      - all series names
%     observedSeries - series that appear to be raw/observed data
%     derivedSeries  - series that were calculated/derived
%
%   A series is considered "derived" if its description text (from the WF1
%   history block or WF2 metadata) contains a formula pattern:
%     - "//" substring: EViews convention for generated-series comments
%     - " = " substring: indicates an assignment/transformation formula
%
%   This is a text-based heuristic — the WF1 binary format does not store
%   an explicit observed/derived flag. False positives are possible if a
%   user's description text happens to contain these patterns.

    % Get all series names (exclude non-series fields)
    excludeFields = ["Metadata", "Groups", "Equations", "VARs", "Tables", "Graphs"];
    allFields = string(fieldnames(workfile));
    allSeries = setdiff(allFields, excludeFields);
    allSeries = allSeries(:);

    % Get names of series with descriptions
    if isempty(fieldnames(seriesDescriptions))
        descNames = string.empty(0,1);
    else
        descNames = string(fieldnames(seriesDescriptions));
    end

    % Classify each series
    observedSeries = string.empty(0,1);
    derivedSeries = string.empty(0,1);
    for i = 1:numel(allSeries)
        name = allSeries(i);
        isDerived = false;

        % Check if this series has a description indicating derivation
        if ismember(name, descNames)
            desc = seriesDescriptions.(name);
            % Look for formula patterns: "// name = ..." or just " = "
            if contains(desc, '//') || contains(desc, ' = ')
                isDerived = true;
            end
        end

        if isDerived
            derivedSeries(end+1) = name; %#ok<AGROW>
        else
            observedSeries(end+1) = name; %#ok<AGROW>
        end
    end

    observedSeries = observedSeries(:);
    derivedSeries = derivedSeries(:);
end
