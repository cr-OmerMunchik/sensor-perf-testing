using Microsoft.Windows.EventTracing;
using Microsoft.Windows.EventTracing.Cpu;
using Microsoft.Windows.EventTracing.Symbols;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;

string? traceDir = null;
bool useSymbols = false;
string? symbolPath = null;
int traceLimit = 0;
int topProcessesLimit = 10;
string? scenarioFilter = null;

for (int i = 0; i < args.Length; i++)
{
    if (args[i].Equals("--symbols", StringComparison.OrdinalIgnoreCase))
        useSymbols = true;
    else if (args[i].Equals("--symbol-path", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
        symbolPath = args[++i];
    else if (args[i].Equals("--limit", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length && int.TryParse(args[i + 1], out var limit))
    {
        traceLimit = limit;
        i++;
    }
    else if (args[i].Equals("--top-processes", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length && int.TryParse(args[i + 1], out var topProc))
    {
        topProcessesLimit = topProc;
        i++;
    }
    else if (args[i].Equals("--scenario", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
    {
        scenarioFilter = args[++i];
    }
    else if (string.IsNullOrEmpty(traceDir))
        traceDir = args[i];
}

if (string.IsNullOrEmpty(traceDir) || !Directory.Exists(traceDir))
{
    Console.Error.WriteLine("Usage: EtlAnalyzer.exe <trace-directory> [--symbols] [--symbol-path PATH] [--limit N] [--top-processes N] [--scenario NAME]");
    Console.Error.WriteLine("  trace-directory: Path containing .etl files");
    Console.Error.WriteLine("  --symbols: Load symbols for function names (slower, requires network)");
    Console.Error.WriteLine("  --symbol-path PATH: Symbol path (e.g. SRV*cache*\\\\server\\symbols). Sets _NT_SYMBOL_PATH.");
    Console.Error.WriteLine("  --limit N: Process only first N trace files");
    Console.Error.WriteLine("  --top-processes N: Return top N processes (default 10). Use 0 for all.");
    Console.Error.WriteLine("  --scenario NAME: Process only traces whose filename contains NAME (e.g. combined_high_density)");
    Environment.Exit(1);
}

var etlFiles = Directory.GetFiles(traceDir, "*.etl").OrderBy(f => f).ToList();
if (!string.IsNullOrEmpty(scenarioFilter))
    etlFiles = etlFiles.Where(f => Path.GetFileName(f).Contains(scenarioFilter, StringComparison.OrdinalIgnoreCase)).ToList();
if (traceLimit > 0)
    etlFiles = etlFiles.Take(traceLimit).ToList();
if (etlFiles.Count == 0)
{
    Console.Error.WriteLine($"No .etl files found in {traceDir}");
    Environment.Exit(2);
}

var sensorProcessNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
{
    "minionhost", "ActiveConsole", "CrsSvc", "PylumLoader", "AmSvc", "WscIfSvc",
    "ExecutionPreventionSvc", "ActiveCLIAgent", "CrAmTray", "Nnx", "CrEX3",
    "CybereasonAV", "CrDrvCtrl", "CrScanTool"
};

var allResults = new List<object>();

foreach (var etlPath in etlFiles)
{
    var baseName = Path.GetFileNameWithoutExtension(etlPath);
    var scenarioName = baseName
        .Replace("_TEST-PERF-3_", "_")
        .Replace("_TEST-PERF-4_", "_");
    var parts = scenarioName.Split('_');
    if (parts.Length >= 2 && parts[^2].Length == 8 && parts[^1].Length == 6 && int.TryParse(parts[^2], out _) && int.TryParse(parts[^1], out _))
    {
        scenarioName = string.Join("_", parts.Take(parts.Length - 2));
    }

    Console.Error.WriteLine($"Processing: {Path.GetFileName(etlPath)}...");

    try
    {
        var result = ProcessTrace(etlPath, scenarioName, sensorProcessNames, useSymbols, symbolPath, topProcessesLimit);
        allResults.Add(result);
    }
    catch (Exception ex)
    {
        Console.Error.WriteLine($"  Error: {ex.Message}");
        allResults.Add(new
        {
            traceFile = Path.GetFileName(etlPath),
            scenario = scenarioName,
            error = ex.Message
        });
    }
}

var output = JsonSerializer.Serialize(new { traces = allResults }, new JsonSerializerOptions { WriteIndented = true });
Console.WriteLine(output);

static object ProcessTrace(string tracePath, string scenarioName, HashSet<string> sensorProcessNames, bool useSymbols, string? symbolPath, int topProcessesLimit = 10)
{
    var processWeights = new Dictionary<string, double>(StringComparer.OrdinalIgnoreCase);
    var functionWeights = new Dictionary<string, double>(StringComparer.OrdinalIgnoreCase);
    double totalWeight = 0;
    int sampleCount = 0;

    var settings = new TraceProcessorSettings { AllowLostEvents = true };

    using (var trace = TraceProcessor.Create(tracePath, settings))
    {
        var pendingCpu = trace.UseCpuSamplingData();
        IPendingResult<ISymbolDataSource>? pendingSymbols = useSymbols ? trace.UseSymbols() : null;

        trace.Process();

        var cpuData = pendingCpu.Result;
        if (pendingSymbols != null)
        {
            var symbolData = pendingSymbols.Result;
            if (!string.IsNullOrEmpty(symbolPath))
                Environment.SetEnvironmentVariable("_NT_SYMBOL_PATH", symbolPath, EnvironmentVariableTarget.Process);
            symbolData.LoadSymbolsForConsoleAsync(SymCachePath.Automatic, SymbolPath.Automatic).GetAwaiter().GetResult();
        }

        foreach (var sample in cpuData.Samples)
        {
            if (sample.IsExecutingDeferredProcedureCall == true || sample.IsExecutingInterruptServicingRoutine == true)
                continue;

            var weight = (double)sample.Weight.TotalMilliseconds;
            totalWeight += weight;
            sampleCount++;

            var processName = sample.Process?.ImageName ?? sample.Image?.FileName ?? "Unknown";
            var processBase = Path.GetFileNameWithoutExtension(processName);
            if (string.IsNullOrEmpty(processBase)) processBase = processName;

            processWeights.TryGetValue(processBase, out var pWeight);
            processWeights[processBase] = pWeight + weight;

            if (sensorProcessNames.Contains(processBase))
            {
                var funcKey = GetFunctionKey(sample, sensorProcessNames);
                if (funcKey != null)
                {
                    var topKey = GetTopFrameKey(sample);
                    var useKey = funcKey;
                    if (topKey != null && topKey.Contains('!') && funcKey.Contains('+'))
                        useKey = topKey;
                    functionWeights.TryGetValue(useKey, out var fWeight);
                    functionWeights[useKey] = fWeight + weight;
                }
            }
        }
    }

    var processQuery = processWeights
        .Where(kv => !string.Equals(kv.Key, "Idle", StringComparison.OrdinalIgnoreCase))
        .OrderByDescending(kv => kv.Value);
    var topProcesses = (topProcessesLimit > 0 ? processQuery.Take(topProcessesLimit) : processQuery)
        .Select(kv => new { process = kv.Key, weightMs = Math.Round(kv.Value, 1), percent = totalWeight > 0 ? Math.Round(100 * kv.Value / totalWeight, 2) : 0 })
        .ToList();

    var topFunctions = functionWeights
        .OrderByDescending(kv => kv.Value)
        .Take(15)
        .Select(kv =>
        {
            var (module, func) = SplitModuleFunction(kv.Key);
            return new
            {
                module,
                function = func,
                weightMs = Math.Round(kv.Value, 1),
                percent = totalWeight > 0 ? Math.Round(100 * kv.Value / totalWeight, 2) : 0
            };
        })
        .ToList();

    return new
    {
        traceFile = Path.GetFileName(tracePath),
        scenario = scenarioName,
        sampleCount,
        totalWeightMs = Math.Round(totalWeight, 1),
        topProcesses,
        topFunctions
    };
}

static string? GetFunctionKey(ICpuSample sample, HashSet<string> sensorProcessNames)
{
    // Prefer first frame in sensor module (our code); fall back to top frame (often OS)
    var stack = sample.Stack;
    if (stack != null)
    {
        foreach (var frame in stack.Frames)
        {
            var frameImage = frame.Image?.FileName;
            if (string.IsNullOrEmpty(frameImage)) continue;
            var frameModule = Path.GetFileNameWithoutExtension(frameImage);
            if (string.IsNullOrEmpty(frameModule)) frameModule = frameImage;

            if (sensorProcessNames.Contains(frameModule))
            {
                return FormatFrame(frame, frameModule);
            }
        }
    }

    // Fallback: use top frame (may be OS/infra)
    return GetTopFrameKey(sample);
}

static string? GetTopFrameKey(ICpuSample sample)
{
    var topFrame = sample.TopStackFrame;
    var topImage = sample.Image?.FileName ?? sample.Process?.ImageName ?? "unknown";
    var topModule = Path.GetFileNameWithoutExtension(topImage);
    if (string.IsNullOrEmpty(topModule)) topModule = topImage;
    return FormatFrame(topFrame, topModule);
}

static string FormatFrame(Microsoft.Windows.EventTracing.Symbols.StackFrame frame, string module)
{
    if (frame.Symbol != null)
    {
        var funcName = frame.Symbol.FunctionName ?? frame.Symbol.ToString() ?? "?";
        return $"{module}!{funcName}";
    }
    var hex = $"{frame.Address:X}";
    var addr = hex.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ? hex : "0x" + hex;
    return $"{module}+{addr}";
}

static (string module, string function) SplitModuleFunction(string key)
{
    var idx = key.IndexOf('!');
    if (idx >= 0)
        return (key.Substring(0, idx), key.Substring(idx + 1));
    idx = key.IndexOf('+');
    if (idx >= 0)
        return (key.Substring(0, idx), key.Substring(idx + 1));
    return (key, "");
}
