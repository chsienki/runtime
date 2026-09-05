// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System.Text.Json;
using Microsoft.Build.Framework;
using Microsoft.Build.Logging;

if (args.Length != 2)
{
    Console.Error.WriteLine("Usage: CoreCompileBinlogAnalyzer <binlog> <output-json>");
    return 1;
}

var result = Analyze(Path.GetFullPath(args[0]));
var outputPath = Path.GetFullPath(args[1]);
Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);
File.WriteAllText(
    outputPath,
    JsonSerializer.Serialize(
        result,
        new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            WriteIndented = true,
        }));

Console.WriteLine($"[binlog] CoreCompile targets started: {result.TargetsStarted}");
Console.WriteLine($"[binlog] CoreCompile ran completely: {result.RanCompletely}");
Console.WriteLine($"[binlog] CoreCompile ran partially: {result.RanPartially}");
Console.WriteLine($"[binlog] CoreCompile skipped up to date: {result.SkippedUpToDate}");
Console.WriteLine($"[binlog] CoreCompile executed without a build verdict: {result.ExecutedWithoutBuildVerdict}");
Console.WriteLine($"[binlog] wrote {outputPath}");
return 0;

static CoreCompileResult Analyze(string binlog)
{
    const string RunPrefix = "Building target \"CoreCompile\" completely";
    const string PartialPrefix = "Building target \"CoreCompile\" partially";

    var targetFrameworksByEvaluation = new Dictionary<int, string>();
    var projects = new Dictionary<int, ProjectInfo>();
    var activeTargets = new Dictionary<(int ProjectContextId, int TargetId), ActiveCoreCompile>();
    var result = new CoreCompileResult();
    var replay = new BinaryLogReplayEventSource();

    replay.AnyEventRaised += (_, e) =>
    {
        if (e is not ProjectEvaluationFinishedEventArgs evaluationFinished ||
            evaluationFinished.BuildEventContext is not { } context)
        {
            return;
        }

        var targetFramework = evaluationFinished.EnumerateProperties()
            .FirstOrDefault(property => property.Name.Equals("TargetFramework", StringComparison.OrdinalIgnoreCase))
            .Value;
        if (!string.IsNullOrEmpty(targetFramework))
        {
            targetFrameworksByEvaluation[context.EvaluationId] = targetFramework;
        }
    };

    replay.ProjectStarted += (_, e) =>
    {
        if (e.BuildEventContext is not { } context)
        {
            return;
        }

        var targetFramework = "";
        e.GlobalProperties?.TryGetValue("TargetFramework", out targetFramework);
        if (string.IsNullOrEmpty(targetFramework))
        {
            targetFramework = e.EnumerateProperties()
                .FirstOrDefault(property => property.Name.Equals("TargetFramework", StringComparison.OrdinalIgnoreCase))
                .Value;
        }
        if (string.IsNullOrEmpty(targetFramework))
        {
            targetFrameworksByEvaluation.TryGetValue(context.EvaluationId, out targetFramework);
        }

        projects[context.ProjectContextId] = new ProjectInfo(
            e.ProjectFile ?? "",
            targetFramework ?? "");
    };

    replay.TargetStarted += (_, e) =>
    {
        if (e.TargetName != "CoreCompile" || e.BuildEventContext is not { } context)
        {
            return;
        }

        result.TargetsStarted++;
        activeTargets[(context.ProjectContextId, context.TargetId)] = new ActiveCoreCompile(
            CreateEntry(e.ProjectFile, context.ProjectContextId, projects));
    };

    replay.MessageRaised += (_, e) =>
    {
        if (e is TargetSkippedEventArgs
            {
                TargetName: "CoreCompile",
                SkipReason: TargetSkipReason.OutputsUpToDate,
            } skippedEvent)
        {
            var skippedContext = skippedEvent.BuildEventContext;
            var skippedKey = skippedContext is null
                ? ((int ProjectContextId, int TargetId)?)null
                : (skippedContext.ProjectContextId, skippedContext.TargetId);
            var active = skippedKey is { } targetKey &&
                activeTargets.TryGetValue(targetKey, out var activeTarget)
                    ? activeTarget
                    : null;
            var skippedEntry = active is not null
                ? active.Entry
                : CreateEntry(
                    skippedEvent.ProjectFile,
                    skippedContext?.ProjectContextId,
                    projects);
            if (active is not null)
            {
                active.HasBuildVerdict = true;
            }

            result.SkippedUpToDate++;
            result.Skipped.Add(skippedEntry);
            return;
        }

        var message = e.Message ?? "";
        var ran = message.StartsWith(RunPrefix, StringComparison.Ordinal);
        var ranPartially = message.StartsWith(PartialPrefix, StringComparison.Ordinal);
        var context = e.BuildEventContext;
        var key = context is null
            ? ((int ProjectContextId, int TargetId)?)null
            : (context.ProjectContextId, context.TargetId);

        if (ran || ranPartially)
        {
            var active = key is { } targetKey && activeTargets.TryGetValue(targetKey, out var activeTarget)
                ? activeTarget
                : null;
            var entry = active is not null
                ? active.Entry
                : CreateEntry(e.ProjectFile, context?.ProjectContextId, projects);
            if (active is not null)
            {
                active.HasBuildVerdict = true;
            }

            if (ran)
            {
                result.RanCompletely++;
            }
            else
            {
                result.RanPartially++;
            }

            result.Compiled.Add(entry);
            return;
        }

        if (key is { } activeKey &&
            activeTargets.TryGetValue(activeKey, out var activeEntry) &&
            IsRebuildReason(message) &&
            !activeEntry.Entry.Reasons.Contains(message, StringComparer.Ordinal))
        {
            activeEntry.Entry.Reasons.Add(message);
        }
    };

    replay.TargetFinished += (_, e) =>
    {
        if (e.TargetName == "CoreCompile" && e.BuildEventContext is { } context)
        {
            var key = (context.ProjectContextId, context.TargetId);
            if (activeTargets.Remove(key, out var active) && !active.HasBuildVerdict)
            {
                result.ExecutedWithoutBuildVerdict++;
                result.ExecutedWithoutVerdict.Add(active.Entry);
            }
        }
    };

    replay.Replay(binlog);
    return result;
}

static CoreCompileProject CreateEntry(
    string? projectFile,
    int? projectContextId,
    Dictionary<int, ProjectInfo> projects)
{
    var project = projectFile ?? "";
    var targetFramework = "";
    if (projectContextId is { } contextId && projects.TryGetValue(contextId, out var info))
    {
        project = info.Project;
        targetFramework = info.TargetFramework;
    }

    return new CoreCompileProject
    {
        Project = project,
        TargetFramework = targetFramework,
    };
}

static bool IsRebuildReason(string message) =>
    message.StartsWith("Input file ", StringComparison.Ordinal) ||
    message.StartsWith("Output file ", StringComparison.Ordinal) ||
    message.Equals("No input files were specified.", StringComparison.Ordinal) ||
    message.Contains("Input file is newer than output file.", StringComparison.Ordinal) ||
    message.EndsWith(" does not exist.", StringComparison.Ordinal);

internal sealed record ProjectInfo(string Project, string TargetFramework);

internal sealed class ActiveCoreCompile(CoreCompileProject entry)
{
    public CoreCompileProject Entry { get; } = entry;

    public bool HasBuildVerdict { get; set; }
}

internal sealed class CoreCompileProject
{
    public string Project { get; set; } = "";

    public string TargetFramework { get; set; } = "";

    public List<string> Reasons { get; } = [];
}

internal sealed class CoreCompileResult
{
    public int TargetsStarted { get; set; }

    public int RanCompletely { get; set; }

    public int RanPartially { get; set; }

    public int SkippedUpToDate { get; set; }

    public int ExecutedWithoutBuildVerdict { get; set; }

    public List<CoreCompileProject> Compiled { get; } = [];

    public List<CoreCompileProject> Skipped { get; } = [];

    public List<CoreCompileProject> ExecutedWithoutVerdict { get; } = [];
}
