// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

//#define LAUNCH_DEBUGGER
using System.Collections.Generic;
using System.Collections.Immutable;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using System.Text.Json.Reflection;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.CodeAnalysis.Text;

namespace System.Text.Json.SourceGeneration
{
    /// <summary>
    /// Generates source code to optimize serialization and deserialization with JsonSerializer.
    /// </summary>
    [Generator]
    public sealed partial class JsonSourceGenerator : ISourceGenerator
    {
        /// <summary>
        /// Registers a syntax resolver to receive compilation units.
        /// </summary>
        /// <param name="context"></param>
        public void Initialize(GeneratorInitializationContext context)
        {
            //  context.RegisterForSyntaxNotifications(() => new SyntaxContextReceiver());
        }

        /// <summary>
        /// A <see langword="static"/> cache of syntax trees that we generated data for previously.
        /// </summary>
        static Dictionary<WeakReference<SyntaxTree>, List<ClassDeclarationSyntax>> s_classesPerTree = new Dictionary<WeakReference<SyntaxTree>, List<ClassDeclarationSyntax>>();

        /// <summary>
        /// Generates source code to optimize serialization and deserialization with JsonSerializer.
        /// </summary>
        /// <param name="executionContext"></param>
        public void Execute(GeneratorExecutionContext executionContext)
        {
#if LAUNCH_DEBUGGER
            if (!Diagnostics.Debugger.IsAttached)
            {
                Diagnostics.Debugger.Launch();
            }
#endif
            // re-walk any syntax trees that have been modified
            Dictionary<WeakReference<SyntaxTree>, List<ClassDeclarationSyntax>> updatedClassesPerTree = new Dictionary<WeakReference<SyntaxTree>, List<ClassDeclarationSyntax>>();
            foreach (var tree in executionContext.Compilation.SyntaxTrees)
            {
                bool usedCache = false;
                foreach (var key in s_classesPerTree.Keys)
                {
                    if (key.TryGetTarget(out var oldTree) && oldTree == tree)
                    {
                        updatedClassesPerTree.Add(key, s_classesPerTree[key]);
                        usedCache = true;
                        break;
                    }
                }

                if (!usedCache)
                {
                    // we need to visit this tree
                    JsonSyntaxWalker rx = new JsonSyntaxWalker(executionContext.Compilation.GetSemanticModel(tree));
                    rx.Visit(tree.GetRoot());

                    updatedClassesPerTree.Add(new WeakReference<SyntaxTree>(tree), rx.ClassDeclarationSyntaxList);
                }
            }
            s_classesPerTree = updatedClassesPerTree;

            var classDeclarationSyntaxList = s_classesPerTree.Where(kvp => kvp.Value is not null).SelectMany(kvp => kvp.Value).ToList();
            if (classDeclarationSyntaxList.Count == 0)
            {
                // nothing to do yet
                return;
            }

            JsonSourceGenerationContext context = new JsonSourceGenerationContext(executionContext);
            Parser parser = new(executionContext.Compilation, context);
            SourceGenerationSpec? spec = parser.GetGenerationSpec(classDeclarationSyntaxList);
            if (spec != null)
            {
                _rootTypes = spec.ContextGenerationSpecList[0].RootSerializableTypes;

                Emitter emitter = new(context, spec);
                emitter.Emit();
            }
        }

        private sealed class JsonSyntaxWalker : SyntaxWalker
        {
            private readonly SemanticModel _model;

            public List<ClassDeclarationSyntax>? ClassDeclarationSyntaxList { get; private set; }

            public JsonSyntaxWalker(SemanticModel model)
            {
                _model = model;
            }

            public override void Visit(SyntaxNode node)
            {
                if (Parser.IsSyntaxTargetForGeneration(node))
                {
                    ClassDeclarationSyntax classSyntax = Parser.GetSemanticTargetForGeneration(node, _model);
                    if (classSyntax != null)
                    {
                        (ClassDeclarationSyntaxList ??= new List<ClassDeclarationSyntax>()).Add(classSyntax);
                    }
                }

                base.Visit(node);
            }
        }

        /// <summary>
        /// Helper for unit tests.
        /// </summary>
        public Dictionary<string, Type>? GetSerializableTypes() => _rootTypes?.ToDictionary(p => p.Type.FullName, p => p.Type);
        private List<TypeGenerationSpec>? _rootTypes;
    }

    internal readonly struct JsonSourceGenerationContext
    {
        private readonly GeneratorExecutionContext _context;

        public JsonSourceGenerationContext(GeneratorExecutionContext context)
        {
            _context = context;
        }

        public void ReportDiagnostic(Diagnostic diagnostic)
        {
            _context.ReportDiagnostic(diagnostic);
        }

        public void AddSource(string hintName, SourceText sourceText)
        {
            _context.AddSource(hintName, sourceText);
        }
    }
}
